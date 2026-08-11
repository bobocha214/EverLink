import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:everlink/services/lan_transfer/device_discovery.dart';
import 'package:everlink/services/lan_transfer/lan_models.dart';
import 'package:everlink/services/lan_transfer/lan_server.dart';
import 'package:everlink/services/network_info_service.dart';

/// 局域网快传统筹：启动本地服务器与设备发现，维护本机昵称、已加入频道、
/// 聊天消息与文件索引，并对外提供发送 / 扫描能力。
///
/// 继承 [ChangeNotifier]，UI 直接监听即可随消息与设备变化刷新。
class LanTransferManager extends ChangeNotifier {
  LanTransferManager._();
  static final LanTransferManager instance = LanTransferManager._();

  static const _kNameKey = 'lan_self_name';
  static const _kChannelsKey = 'lan_channels';
  static const _kMessagesKey = 'lan_messages';
  static const _kPortKey = 'lan_transfer_port';
  static const int _kMaxStoredMessages = 200;

  final StreamController<LanMessage> _controller =
      StreamController<LanMessage>.broadcast();
  Stream<LanMessage> get receivedStream => _controller.stream;

  LanServer? _server;
  DeviceDiscovery? _discovery;

  final List<LanMessage> _messages = [];
  final Map<String, LanFileItem> _fileIndex = {};

  bool _running = false;
  int _port = 5321;
  late final String _selfId = DeviceDiscovery.genId();
  String _selfName = '';
  String _selfAddress = '';

  /// 所有本机局域网 IP（含接口名），供 UI / API 展示。
  List<Map<String, dynamic>> _allAddresses = const [];
  /// 详细网络信息（WiFi 名、子网掩码、网关、DNS、信号强度等）。
  Map<String, dynamic> _networkInfo = const {};
  /// 定时刷新网络信息（WiFi 信号强度会变化）。
  Timer? _networkTimer;

  /// 已加入的频道：频道名 -> 密码（公共频道密码为空）。
  final Map<String, String> _channels = {kPublicChannel: ''};

  bool get isRunning => _running;
  String get selfId => _selfId;
  String get selfName => _selfName;
  String get selfAddress => _selfAddress;
  int get port => _port;
  bool get isScanning => _discovery?.isScanning ?? false;

  /// 所有本机局域网 IP（含接口名、是否主地址）。
  List<Map<String, dynamic>> get allAddresses => _allAddresses;
  /// 详细网络信息。
  Map<String, dynamic> get networkInfo => _networkInfo;

  /// 是否拿到了真实的局域网地址（未连 WiFi 时为 false）。
  bool get hasLanAddress =>
      _selfAddress.isNotEmpty && !_selfAddress.startsWith('127.0.0.1');

  List<LanMessage> get messages => List.unmodifiable(_messages);
  /// 所有可见设备：App 发现的设备 + 通过网页连接到本机的访客。
  /// 网页访客不响应 UDP 广播，由 HTTP 请求反向登记，单独合并在此。
  List<DiscoveredDevice> get devices {
    final appDevices = _discovery?.devices ?? const [];
    final webDevices = _server?.webClients ?? const [];
    if (webDevices.isEmpty) return appDevices;
    return [...appDevices, ...webDevices];
  }

  /// 已加入频道（公共频道恒在首位）。
  List<LanChannel> get channels {
    final list = _channels.entries
        .map((e) => LanChannel(name: e.key, password: e.value))
        .toList();
    list.sort((a, b) {
      if (a.name == kPublicChannel) return -1;
      if (b.name == kPublicChannel) return 1;
      return a.name.compareTo(b.name);
    });
    return list;
  }

  /// 某个频道（或点对点，channel 传空串）的消息，按时间正序。
  List<LanMessage> messagesOf(String channel) => _messages
      .where((m) => m.channel == channel)
      .toList()
    ..sort((a, b) => a.time.compareTo(b.time));

  /// 点对点消息（不属于任何频道）。
  List<LanMessage> get p2pMessages => messagesOf('');

  LanFileItem? findFile(String id) => _fileIndex[id];

  // ------------------------------------------------------------ 生命周期

  Future<void> start() async {
    if (_running) return;
    await _loadPrefs();
    await _loadMessages();
    await _loadPort();

    final net = await NetworkInfoService.instance.collect(port: _port);
    _selfAddress = '${net.primaryIp}:$_port';
    _allAddresses = net.addresses.map((a) => a.toMap()).toList();
    _networkInfo = net.toInfoMap(_port);

    _discovery = DeviceDiscovery(
      port: _port,
      selfId: _selfId,
      selfName: _selfName,
      onChanged: notifyListeners,
    );
    _server = LanServer(
      port: _port,
      selfId: _selfId,
      selfNameProvider: () => _selfName,
      selfAddressProvider: () => _selfAddress,
      allAddressesProvider: () => _allAddresses,
      networkInfoProvider: () => _networkInfo,
      devicesProvider: () => devices,
      channelsProvider: () => _channels,
      messagesProvider: () => _messages,
      fileFinder: findFile,
      onMessage: _onMessage,
      onDevicesChanged: notifyListeners,
    );

    await _server!.start();
    await _discovery!.start();
    _running = true;
    // 每 30 秒刷新一次网络信息（信号强度等会变化）。
    _networkTimer?.cancel();
    _networkTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshNetworkInfo();
    });
    notifyListeners();
  }

  Future<void> stop() async {
    _networkTimer?.cancel();
    _networkTimer = null;
    await _server?.stop();
    await _discovery?.stop();
    _server = null;
    _discovery = null;
    _running = false;
    notifyListeners();
  }

  /// 修改快传服务端口：持久化后重启服务（HTTP 服务器与 UDP 发现都会重新绑定到新端口）。
  /// 返回是否成功（端口被占用时回退到原端口）。
  Future<({bool ok, String detail})> changePort(int newPort) async {
    if (newPort <= 0 || newPort > 65535) {
      return (ok: false, detail: '端口需为 1-65535 之间的整数');
    }
    if (newPort == _port && _running) {
      return (ok: true, detail: '端口未变化');
    }
    final old = _port;
    final wasRunning = _running;
    if (wasRunning) await stop();
    _port = newPort;
    try {
      await _savePort();
      if (wasRunning) await start();
      return (ok: true, detail: '端口已切换为 $newPort');
    } catch (e) {
      // 绑定失败：回退到旧端口
      _port = old;
      try {
        await _savePort();
        if (wasRunning) await start();
      } catch (_) {}
      return (ok: false, detail: '端口 $newPort 不可用，已回退到 $old');
    }
  }

  Future<void> _loadPort() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final p = sp.getInt(_kPortKey);
      if (p != null && p > 0 && p <= 65535) _port = p;
    } catch (_) {}
  }

  Future<void> _savePort() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_kPortKey, _port);
    } catch (_) {}
  }

  /// 网络切换后重新获取地址（例如从移动数据切到 WiFi）。
  Future<void> refreshAddress() async {
    final net = await NetworkInfoService.instance.collect(port: _port);
    _selfAddress = '${net.primaryIp}:$_port';
    _allAddresses = net.addresses.map((a) => a.toMap()).toList();
    _networkInfo = net.toInfoMap(_port);
    notifyListeners();
  }

  /// 刷新网络信息（WiFi 信号强度、IP 变化等）。
  Future<void> _refreshNetworkInfo() async {
    final net = await NetworkInfoService.instance.collect(port: _port);
    _selfAddress = '${net.primaryIp}:$_port';
    _allAddresses = net.addresses.map((a) => a.toMap()).toList();
    _networkInfo = net.toInfoMap(_port);
    notifyListeners();
  }

  // -------------------------------------------------------------- 本机昵称

  Future<void> setSelfName(String name) async {
    final v = name.trim();
    if (v.isEmpty || v == _selfName) return;
    _selfName = v;
    _discovery?.selfName = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kNameKey, v);
    notifyListeners();
  }

  // ---------------------------------------------------------------- 频道

  /// 加入 / 创建频道（密码为空即公共频道）。仅 App 端可调用。
  Future<void> joinChannel(String name, String password) async {
    final key = name.trim();
    if (key.isEmpty) return;
    _channels[key] = password;
    await _saveChannels();
    notifyListeners();
  }

  /// 退出频道（默认公共频道不可退出）。
  Future<void> leaveChannel(String name) async {
    if (name == kPublicChannel) return;
    if (_channels.remove(name) == null) return;
    await _saveChannels();
    notifyListeners();
  }

  String? channelPassword(String name) => _channels[name];

  /// 频道对应的网页地址：带频道名与私有频道密码，供二维码使用。
  /// 对方扫码后直接进入该频道，无需（也无法）在网页端自行设置频道。
  String urlForChannel(String channel) {
    final base = 'http://$_selfAddress/';
    if (channel.isEmpty) return base;
    // 私有频道的密码不再嵌入 URL，扫码后对方需手动输入密码才能加入。
    return '$base?ch=${Uri.encodeComponent(channel)}';
  }

  // ---------------------------------------------------------------- 收发

  void _onMessage(LanMessage m) {
    _messages.add(m);
    for (final f in m.files) {
      _fileIndex[f.id] = f;
    }
    _controller.add(m);
    notifyListeners();
    _saveMessages();
  }

  /// 发送消息：指定 [channel] 走频道广播，指定 [target] 走点对点。
  Future<SendResult> send({
    String text = '',
    List<Map<String, dynamic>> files = const [],
    String channel = '',
    String? target,
  }) async {
    final server = _server;
    if (server == null) return const SendResult(false, '服务未启动');
    return server.sendLocal(
      text: text,
      rawFiles: files,
      channel: channel,
      target: target,
    );
  }

  /// 主动扫描本网段，兜底 UDP 广播被路由器拦截的情况。
  /// 返回一个记录：[发现设备数, 说明文字]。
  Future<({int count, String detail})> scanDevices() async {
    final d = _discovery;
    if (d == null) return (count: 0, detail: '服务未启动');
    final n = await d.scanSubnet();
    final webCount = (_server?.webClients.length ?? 0);
    notifyListeners();
    if (n == 0 && webCount == 0) {
      return (count: 0, detail: '扫描完成，未发现任何设备');
    }
    final parts = <String>[];
    if (n > 0) parts.add('$n 台 App 设备');
    if (webCount > 0) parts.add('$webCount 位网页访客');
    return (count: n + webCount, detail: '扫描完成，发现 ${parts.join('、')}');
  }

  /// 手动添加一台设备（直接输入对方 IP）。
  Future<String?> addDeviceManually(String host) async {
    final d = _discovery;
    if (d == null) return null;
    final name = await d.addManually(host);
    notifyListeners();
    return name;
  }

  void clearMessages() {
    _messages.clear();
    _fileIndex.clear();
    _saveMessages();
    notifyListeners();
  }

  // ---------------------------------------------------------------- 内部

  Future<void> _loadPrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _selfName = sp.getString(_kNameKey) ?? '';
      final raw = sp.getString(_kChannelsKey);
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        _channels
          ..clear()
          ..[kPublicChannel] = '';
        m.forEach((k, v) => _channels[k] = v as String? ?? '');
        _channels[kPublicChannel] = '';
      }
    } catch (_) {}
    if (_selfName.isEmpty) {
      _selfName = '${_defaultNamePrefix()}-${_shortId()}';
    }
  }

  Future<void> _saveChannels() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kChannelsKey, jsonEncode(_channels));
    } catch (_) {}
  }

  Future<void> _saveMessages() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final start = _messages.length > _kMaxStoredMessages
          ? _messages.length - _kMaxStoredMessages
          : 0;
      final list = _messages.sublist(start).map((m) => m.toJson()).toList();
      await sp.setString(_kMessagesKey, jsonEncode(list));
    } catch (_) {}
  }

  Future<void> _loadMessages() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kMessagesKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List;
      for (final e in list) {
        if (e is! Map<String, dynamic>) continue;
        final m = LanMessage.fromJson(e);
        _messages.add(m);
        for (final f in m.files) {
          _fileIndex[f.id] = f;
        }
      }
    } catch (_) {}
  }

  String _defaultNamePrefix() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isLinux) return 'Linux';
    return 'EverLink';
  }

  String _shortId() {
    final r = Random();
    return List.generate(4, (_) => r.nextInt(16).toRadixString(16)).join();
  }

}
