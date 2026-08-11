import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'package:everlink/services/lan_transfer/lan_models.dart';

/// 局域网设备发现。
///
/// 之所以做得这么"重"，是因为在真实 Wi-Fi 环境里单一手段几乎必然失败：
///
///  1. **Android 多播锁**：Wi-Fi 驱动为省电会在链路层直接丢弃目的地非本机的
///     多播/广播帧，不持有 `WifiManager.MulticastLock` 时 Dart 侧永远收不到
///     对端心跳。这是"搜索不到设备"最常见的根因，通过原生 MethodChannel 解决。
///  2. **逐网卡加入多播组**：`joinMulticast` 不指定 interface 时，多网卡设备
///     （Wi-Fi + 移动数据 + 虚拟网卡）常常加错网卡而收不到包。
///  3. **三重发送**：多播（239.252.100.100）+ 受限广播（255.255.255.255）+
///     子网定向广播（x.x.x.255），任一条通路可达即可发现。
///  4. **主动子网扫描兜底**：不少路由器开启了 AP 隔离或禁用广播转发，此时
///     UDP 全部失效。改用 TCP 直连探测整个 /24 网段的快传端口，只要设备间
///     能互通 TCP 就一定能发现，是最可靠的兜底手段。
class DeviceDiscovery {
  DeviceDiscovery({
    required this.port,
    required this.selfId,
    required this.selfName,
    this.onChanged,
  });

  final int port;
  final String selfId;
  String selfName;

  /// 设备列表发生变化时回调（用于刷新 UI）。
  final VoidCallback? onChanged;

  /// 多播组地址（管理作用域，TTL=1 不跨子网）。
  static final InternetAddress _multicastGroup =
      InternetAddress('239.252.100.100');

  /// 与原生层通信的通道（目前仅 Android 需要多播锁）。
  static const MethodChannel _nativeChannel = MethodChannel('everlink/lan');

  RawDatagramSocket? _socket;
  final Map<String, DiscoveredDevice> _devices = {};
  Timer? _broadcastTimer;
  final List<InternetAddress> _localAddrs = [];
  bool _multicastLockHeld = false;
  bool _scanning = false;

  bool get isScanning => _scanning;

  /// 生成一个设备 id（同一次运行内保持不变）。
  static String genId() =>
      DateTime.now().millisecondsSinceEpoch.toRadixString(16) +
      (_randomInstance.nextInt(0xffff)).toRadixString(16);

  static final Random _randomInstance = Random();

  Future<void> start() async {
    await _acquireMulticastLock();
    await _collectLocalAddresses();

    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    _socket!.broadcastEnabled = true;
    _socket!.readEventsEnabled = true;
    _socket!.multicastHops = 1;

    // 逐网卡加入多播组：多网卡设备不指定 interface 时经常加错网卡。
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      var joined = false;
      for (final iface in ifaces) {
        try {
          _socket!.joinMulticast(_multicastGroup, iface);
          joined = true;
        } catch (_) {}
      }
      if (!joined) {
        try {
          _socket!.joinMulticast(_multicastGroup);
        } catch (_) {}
      }
    } catch (_) {}

    _socket!.listen(_onEvent);

    _broadcast();
    _broadcastTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _broadcast());
  }

  /// Android：申请多播锁，否则收不到任何多播/广播报文。
  Future<void> _acquireMulticastLock() async {
    if (!Platform.isAndroid || _multicastLockHeld) return;
    try {
      final ok = await _nativeChannel.invokeMethod<bool>(
        'acquireMulticastLock',
      );
      _multicastLockHeld = ok ?? false;
    } catch (_) {
      _multicastLockHeld = false;
    }
  }

  Future<void> _releaseMulticastLock() async {
    if (!Platform.isAndroid || !_multicastLockHeld) return;
    try {
      await _nativeChannel.invokeMethod<bool>('releaseMulticastLock');
    } catch (_) {}
    _multicastLockHeld = false;
  }

  Future<void> _collectLocalAddresses() async {
    _localAddrs.clear();
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in ifaces) {
        _localAddrs.addAll(iface.addresses);
      }
    } catch (_) {}
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket!.receive();
    if (dg == null) return;
    try {
      final map = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      final id = map['id'] as String?;
      if (id == null || id == selfId) return;
      final name = map['name'] as String? ?? '未知设备';
      final p = (map['port'] as int?) ?? port;
      _upsert(DiscoveredDevice(
        id: id,
        name: name,
        address: '${dg.address.address}:$p',
        lastSeen: DateTime.now(),
      ));
    } catch (_) {
      // 忽略非法报文
    }
  }

  void _upsert(DiscoveredDevice d) {
    final existed = _devices[d.id];
    _devices[d.id] = d;
    // 仅在新增或名称/地址变化时通知，避免每 2 秒心跳都触发重建。
    if (existed == null ||
        existed.name != d.name ||
        existed.address != d.address) {
      onChanged?.call();
    }
  }

  void _broadcast() {
    if (_socket == null) return;
    final data = utf8.encode(jsonEncode({
      'id': selfId,
      'name': selfName,
      'port': port,
    }));
    // 1) 多播（首选，多数家用路由默认放行）
    _trySend(data, _multicastGroup);
    // 2) 受限广播
    _trySend(data, InternetAddress('255.255.255.255'));
    // 3) 子网定向广播（覆盖常见 /24）
    for (final a in _localAddrs) {
      final parts = a.address.split('.');
      if (parts.length == 4) {
        _trySend(data, InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
      }
    }
  }

  void _trySend(List<int> data, InternetAddress addr) {
    try {
      _socket!.send(data, addr, port);
    } catch (_) {}
  }

  /// 主动扫描本机所在 /24 网段（TCP 直连探测），兜底 UDP 被拦截的网络环境。
  ///
  /// 返回本次扫描新发现的设备数量。分批并发，避免一次开 254 个 socket 触发
  /// 移动端的文件描述符上限。
  Future<int> scanSubnet({
    Duration timeout = const Duration(milliseconds: 600),
    int batchSize = 24,
  }) async {
    if (_scanning) return 0;
    _scanning = true;
    onChanged?.call();
    var found = 0;
    try {
      await _collectLocalAddresses();
      final bases = <String>{};
      final selfIps = <String>{};
      for (final a in _localAddrs) {
        final parts = a.address.split('.');
        if (parts.length == 4) {
          bases.add('${parts[0]}.${parts[1]}.${parts[2]}');
          selfIps.add(a.address);
        }
      }
      for (final base in bases) {
        for (var start = 1; start <= 254; start += batchSize) {
          final futures = <Future<bool>>[];
          for (var i = start; i < start + batchSize && i <= 254; i++) {
            final ip = '$base.$i';
            if (selfIps.contains(ip)) continue;
            futures.add(_probe(ip, timeout));
          }
          final results = await Future.wait(futures);
          found += results.where((e) => e).length;
        }
      }
    } catch (_) {
    } finally {
      _scanning = false;
      onChanged?.call();
    }
    return found;
  }

  /// 探测单个 IP 是否运行着快传服务：先 TCP 连通性，再取 /api/info。
  Future<bool> _probe(String ip, Duration timeout) async {
    Socket? sock;
    try {
      sock = await Socket.connect(ip, port, timeout: timeout);
    } catch (_) {
      return false;
    } finally {
      try {
        sock?.destroy();
      } catch (_) {}
    }

    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = timeout;
      final req = await client.getUrl(Uri.parse('http://$ip:$port/api/info'));
      final resp = await req.close().timeout(const Duration(seconds: 3));
      final body = await utf8.decoder.bind(resp).join();
      final m = jsonDecode(body) as Map<String, dynamic>;
      final id = m['id'] as String?;
      if (id == null || id == selfId) return false;
      final isNew = !_devices.containsKey(id);
      _upsert(DiscoveredDevice(
        id: id,
        name: m['name'] as String? ?? ip,
        address: '$ip:$port',
        lastSeen: DateTime.now(),
        // 扫描发现的设备不依赖心跳保活，避免 10 秒后被判定离线。
        pinned: true,
      ));
      return isNew;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// 手动添加一台设备（用户直接输入对方 IP，终极兜底）。
  /// 成功返回设备名，失败返回 null。
  Future<String?> addManually(String host) async {
    final ip = host.trim().split(':').first;
    if (ip.isEmpty) return null;
    final ok = await _probe(ip, const Duration(seconds: 2));
    if (ok) return _devices.values.firstWhere((d) => d.address.startsWith('$ip:')).name;
    // 已存在也算成功
    final existing = _devices.values.where((d) => d.address.startsWith('$ip:'));
    return existing.isEmpty ? null : existing.first.name;
  }

  /// 在线设备：UDP 心跳 10 秒内，或由扫描/手动添加固定住的设备。
  List<DiscoveredDevice> get devices {
    final now = DateTime.now();
    return _devices.values
        .where((d) => d.pinned || now.difference(d.lastSeen).inSeconds < 10)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    try {
      _socket?.leaveMulticast(_multicastGroup);
    } catch (_) {}
    _socket?.close();
    _socket = null;
    await _releaseMulticastLock();
  }
}
