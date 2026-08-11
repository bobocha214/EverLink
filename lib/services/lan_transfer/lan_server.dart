import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:everlink/services/lan_transfer/lan_models.dart';
import 'package:everlink/services/lan_transfer/lan_web.dart';
import 'package:path_provider/path_provider.dart';

/// 一次发送的结果。
class SendResult {
  final bool ok;
  final String detail;
  const SendResult(this.ok, this.detail);
}

/// 通过网页连接到本机的对端（扫码打开网页、未安装 App）。
class _WebClient {
  String name;
  final String address;
  DateTime lastSeen;

  _WebClient({
    required this.name,
    required this.address,
    required this.lastSeen,
  });
}

/// 本地 HTTP 服务器：托管快传网页、提供聊天消息轮询与文件下载，并负责
/// 消息的落盘与向局域网内其它设备转发。
///
/// 发送语义：
///  - 带 `target`（设备地址） → 点对点，仅对方接收；
///  - 带 `channel` → 频道广播：向所有已发现设备转发，对端仅在已加入该频道时
///    才接收（私有频道还需本地密码 XOR 还原）；
///  - 报文里的 `relayed` / `p2p` 标记用于区分"本机发起"与"他人送达"，
///    避免消息在设备间无限循环转发。
class LanServer {
  LanServer({
    required this.port,
    required this.selfId,
    required this.selfNameProvider,
    required this.selfAddressProvider,
    required this.allAddressesProvider,
    required this.networkInfoProvider,
    required this.devicesProvider,
    required this.channelsProvider,
    required this.messagesProvider,
    required this.fileFinder,
    required this.onMessage,
    this.onDevicesChanged,
  });

  final int port;
  final String selfId;
  final String Function() selfNameProvider;
  final String Function() selfAddressProvider;
  final List<Map<String, dynamic>> Function() allAddressesProvider;
  final Map<String, dynamic> Function() networkInfoProvider;
  final List<DiscoveredDevice> Function() devicesProvider;

  /// 频道名 -> 本地密码（公共频道密码为空）。决定是否接收某频道的消息。
  final Map<String, String> Function() channelsProvider;
  final List<LanMessage> Function() messagesProvider;
  final LanFileItem? Function(String id) fileFinder;
  final void Function(LanMessage) onMessage;

  /// 网页端连接列表发生变化时回调（用于刷新设备列表 UI）。
  final void Function()? onDevicesChanged;

  HttpServer? _server;
  var _seq = 0;

  /// 通过网页（HTTP）连接到本机的对端：key 为对端 IP。
  /// 这些设备没装 App，不会响应 UDP 发现，因此由 HTTP 连接反向登记。
  final Map<String, _WebClient> _webClients = {};

  void _touchWebClient(String ip, String name) {
    if (ip.isEmpty || ip.startsWith('127.')) return;
    final address = '$ip:$port';
    final clean = name.trim().isNotEmpty ? name.trim() : '网页访客';
    final existing = _webClients[ip];
    if (existing == null) {
      _webClients[ip] = _WebClient(
        name: clean,
        address: address,
        lastSeen: DateTime.now(),
      );
      onDevicesChanged?.call();
      return;
    }
    existing.lastSeen = DateTime.now();
    if (existing.name != clean) {
      existing.name = clean;
      onDevicesChanged?.call();
    }
  }

  /// 网页端主动断开连接（beforeunload 触发），立即从设备列表移除。
  void _touchDisconnect(HttpRequest req) {
    final ip = req.connectionInfo?.remoteAddress.address ?? '';
    if (ip.isEmpty || ip.startsWith('127.')) {
      req.response.statusCode = 200;
      req.response.close();
      return;
    }
    if (_webClients.remove(ip) != null) {
      onDevicesChanged?.call();
    }
    req.response.statusCode = 200;
    req.response.close();
  }

  /// 当前通过网页连接到本机的对端，作为"网页访客"设备对外暴露，
  /// 使其在设备列表里与 App 设备一同显示（5 分钟无活动即视为离线）。
  List<DiscoveredDevice> get webClients {
    final now = DateTime.now();
    return _webClients.values
        .where((c) => now.difference(c.lastSeen).inMinutes < 5)
        .map((c) => DiscoveredDevice(
              id: c.address,
              name: c.name,
              address: c.address,
              lastSeen: c.lastSeen,
              pinned: true,
              isWeb: true,
            ))
        .toList();
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  // ---------------------------------------------------------------- 路由

  Future<void> _handle(HttpRequest req) async {
    req.response.headers.add('Access-Control-Allow-Origin', '*');
    req.response.headers
        .add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    req.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method == 'OPTIONS') {
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    try {
      switch (req.uri.path) {
        case '/':
        case '/index.html':
          await _serveHtml(req);
          return;
        case '/api/info':
          _touchWebClient(
            req.connectionInfo?.remoteAddress.address ?? '',
            req.uri.queryParameters['name'] ?? '',
          );
          await _json(req, {
            'id': selfId,
            'name': selfNameProvider(),
            'address': selfAddressProvider(),
            'addresses': allAddressesProvider(),
            'port': port,
          });
          return;
        case '/api/network':
          _touchWebClient(
            req.connectionInfo?.remoteAddress.address ?? '',
            req.uri.queryParameters['name'] ?? '',
          );
          await _json(req, networkInfoProvider());
          return;
        case '/api/devices':
          // 网页端也能看到当前通过网页连接的其它访客。
          final all = <DiscoveredDevice>[...devicesProvider(), ...webClients];
          await _json(req, all.map((d) => d.toJson()).toList());
          return;
        case '/api/messages':
          _touchWebClient(
            req.connectionInfo?.remoteAddress.address ?? '',
            req.uri.queryParameters['name'] ?? '',
          );
          await _handleMessages(req);
          return;
        case '/api/file':
          await _handleFile(req);
          return;
        case '/api/auth':
          await _handleAuth(req);
          return;
        case '/api/channels':
          await _handleChannels(req);
          return;
        case '/api/send':
          await _handleSendRequest(req);
          return;
        case '/api/disconnect':
          _touchDisconnect(req);
          return;
        default:
          req.response.statusCode = 404;
          await req.response.close();
          return;
      }
    } catch (e) {
      try {
        req.response.statusCode = 500;
        req.response.write('error: $e');
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serveHtml(HttpRequest req) async {
    req.response.headers.contentType = ContentType.html;
    req.response.write(kLanWebHtml);
    await req.response.close();
  }

  Future<void> _json(HttpRequest req, dynamic data) async {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    await req.response.close();
  }

  /// 频道列表：`GET /api/channels`。
  /// 返回 `{channels:[{name, private}]}`，供网页端直接在浏览器里选择频道，
  /// 无需先扫二维码。公共频道 `private=false`，可直接进入；私有频道需密码。
  Future<void> _handleChannels(HttpRequest req) async {
    final list = channelsProvider()
        .entries
        .map((e) => {'name': e.key, 'private': e.value.isNotEmpty})
        .toList();
    await _json(req, {'channels': list});
  }

  /// 频道密码验证：`GET /api/auth?ch=<频道>&k=<密码>`。
  /// 返回 `{ok, channel}` 或 `{ok:false, error}`，用于网页端扫码后提示输入密码。
  Future<void> _handleAuth(HttpRequest req) async {
    final ch = req.uri.queryParameters['ch'] ?? '';
    final k = req.uri.queryParameters['k'] ?? '';
    if (ch.isEmpty) {
      await _json(req, {'ok': false, 'error': '缺少频道参数'});
      return;
    }
    final pwd = channelsProvider()[ch];
    // 频道未加入（App 端不存在该频道）→ 明确报错，便于网页端区分，
    // 避免与“公共频道无需密码”混为一谈。
    if (pwd == null) {
      await _json(req, {'ok': false, 'error': '频道不存在或未加入'});
      return;
    }
    // 公共频道（密码为空）→ 无需密码，直接进入。
    if (pwd.isEmpty) {
      await _json(req, {'ok': true, 'needPassword': false, 'channel': ch});
      return;
    }
    // 私有频道：密码正确才放行，否则提示输入密码。
    if (k == pwd) {
      await _json(req, {'ok': true, 'needPassword': true, 'channel': ch});
    } else {
      await _json(
          req, {'ok': false, 'needPassword': true, 'error': '密码不正确'});
    }
  }

  /// 网页轮询聊天记录：`/api/messages?ch=<频道>&since=<毫秒时间戳>&k=<密码>`。
  /// 频道为空表示取点对点消息。
  Future<void> _handleMessages(HttpRequest req) async {
    final ch = req.uri.queryParameters['ch'] ?? '';
    if (!_authorized(ch, req.uri.queryParameters['k'])) {
      req.response.statusCode = 403;
      req.response.write('{"messages":[],"error":"频道密码不正确"}');
      await req.response.close();
      return;
    }
    final since =
        int.tryParse(req.uri.queryParameters['since'] ?? '0') ?? 0;
    final list = messagesProvider()
        .where((m) => m.channel == ch)
        .where((m) => m.time.millisecondsSinceEpoch > since)
        .map((m) => m.toJson())
        .toList();
    await _json(req, {'name': selfNameProvider(), 'messages': list});
  }

  /// 私有频道鉴权：网页端必须携带二维码里的密码才能读写该频道，
  /// 避免同网段其他人猜到频道名后直接窥探或插话。
  bool _authorized(String channel, String? key) {
    if (channel.isEmpty) return true; // 点对点消息不涉及频道密码
    final pwd = channelsProvider()[channel];
    if (pwd == null || pwd.isEmpty) return true; // 未加入或公共频道
    return key == pwd;
  }

  /// 文件下载：`/api/file?id=<文件 id>`；图片带 `&inline=1` 时内联显示。
  Future<void> _handleFile(HttpRequest req) async {
    final id = req.uri.queryParameters['id'] ?? '';
    final item = fileFinder(id);
    if (item == null) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final file = File(item.savedPath);
    if (!await file.exists()) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    req.response.headers.contentType = ContentType.parse(item.mime);
    final inline = req.uri.queryParameters['inline'] == '1';
    if (!inline) {
      final encoded = Uri.encodeComponent(item.name);
      req.response.headers.add(
        'Content-Disposition',
        "attachment; filename*=UTF-8''$encoded",
      );
    }
    await req.response.addStream(file.openRead());
    await req.response.close();
  }

  // ------------------------------------------------------------ 发送/接收

  Future<void> _handleSendRequest(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    final map = jsonDecode(body) as Map<String, dynamic>;
    final relayed = map['relayed'] == true;
    final p2p = map['p2p'] == true;

    // 网页端发起（非 App 转发、非点对点直达）：记录对端 IP 和昵称，
    // 使其以"网页访客"身份出现在 App 端的设备列表中。
    if (!relayed && !p2p) {
      _touchWebClient(
        req.connectionInfo?.remoteAddress.address ?? '',
        (map['from'] as String?) ?? '',
      );
    }

    // A) 他人送达（对端 App 转发的频道消息，或点对点直达）→ 仅本机留存。
    if (relayed || p2p) {      final msg = await _receiveFromPeer(map, isP2P: p2p);
      await _json(req, msg != null
          ? {'ok': true, 'detail': '已接收'}
          : {'ok': true, 'detail': '未加入该频道，已忽略'});
      return;
    }

    // B) 网页端发起：由本机代为落盘并向局域网扇出。
    final ch = (map['channel'] as String?)?.trim() ?? '';
    if (!_authorized(ch, map['k'] as String?)) {
      await _json(req, {'ok': false, 'error': '频道密码不正确，请重新扫码进入'});
      return;
    }
    final result = await sendLocal(
      text: map['text'] as String? ?? '',
      rawFiles: ((map['files'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      channel: (map['channel'] as String?)?.trim() ?? '',
      target: map['target'] as String?,
      fromName: (map['from'] as String?)?.trim().isNotEmpty == true
          ? (map['from'] as String).trim()
          : '${selfNameProvider()} 的网页访客',
      isSelf: false, // 网页访客发出，非本机用户
    );
    await _json(req, {'ok': result.ok, 'detail': result.detail, 'error': result.detail});
  }

  /// 本机（App 或本机网页）发起一次发送。
  ///
  /// [isSelf] 为 true 表示本机 App 用户发出；网页访客代发时传 false，
  /// 避免对方的消息在 App 端被标为己方泡泡显示在右侧。
  ///
  /// [rawFiles] 每项为 `{name, size, mime, data(dataURL)}`。
  Future<SendResult> sendLocal({
    required String text,
    required List<Map<String, dynamic>> rawFiles,
    String channel = '',
    String? target,
    String? fromName,
    bool isSelf = true,
  }) async {
    if (text.trim().isEmpty && rawFiles.isEmpty) {
      return const SendResult(false, '内容为空');
    }
    final from = fromName ?? selfNameProvider();
    final isP2P = target != null && target.isNotEmpty;
    if (!isP2P && channel.isEmpty) {
      return const SendResult(false, '请选择频道或接收设备');
    }

    // 1) 本地落盘 + 留存一条消息（自己发出或网页访客发出）。
    final files = await _persistFiles(rawFiles);
    final msg = LanMessage(
      id: _nextId(),
      channel: isP2P ? '' : channel,
      fromName: from,
      fromAddress: selfAddressProvider(),
      text: text,
      files: files,
      time: DateTime.now(),
      isSelf: isSelf,
      isP2P: isP2P,
      peer: isP2P ? target : '',
    );
    onMessage(msg);

    // 2) 组装外发报文。
    final payload = <String, dynamic>{
      'from': from,
      'fromAddress': selfAddressProvider(),
      'text': text,
      'files': rawFiles,
    };

    if (isP2P) {
      payload['p2p'] = true;
      // 若目标为本机 web 客户端（扫码打开、无 HTTP 服务端），
      // _forward 必定超时（对方浏览器不监听端口），跳过即可。
      // 消息已通过 onMessage 落盘，web 客户端轮询 /api/messages?ch= 即可收到。
      final targetIp = target.split(':').first;
      final isWeb = _webClients.containsKey(targetIp);
      // 也跳过发给本机自身的转发：web 私聊发给主机 App 时目标就是本服务器，
      // 消息已落盘，再 self-forward 会产生重复。
      final isSelf = target == selfAddressProvider();
      if (!isWeb && !isSelf) {
        final ok = await _forward(target, payload);
        return SendResult(ok, ok ? '已发送' : '无法连接 $target');
      }
      return const SendResult(true, '已发送');
    }

    final password = channelsProvider()[channel] ?? '';
    final out = _obfuscate(payload, password);
    out['channel'] = channel;
    out['private'] = password.isNotEmpty;
    out['relayed'] = true;

    final devices = devicesProvider();
    var delivered = 0;
    for (final dev in devices) {
      if (await _forward(dev.address, out)) delivered++;
    }
    if (devices.isEmpty) {
      return const SendResult(true, '已发送（当前未发现其它设备）');
    }
    return SendResult(true, '已发送至 $delivered/${devices.length} 台设备');
  }

  Future<bool> _forward(String target, Map<String, dynamic> map) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await client.postUrl(Uri.parse('http://$target/api/send'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(map));
      final resp = await req.close().timeout(const Duration(seconds: 30));
      final code = resp.statusCode;
      await resp.drain<void>();
      return code == 200;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// 接收他人送达的消息：频道消息需已加入该频道，私有频道用本地密码还原。
  Future<LanMessage?> _receiveFromPeer(
    Map<String, dynamic> map, {
    required bool isP2P,
  }) async {
    var data = map;
    var channel = '';
    if (!isP2P) {
      channel = (map['channel'] as String?)?.trim() ?? '';
      if (channel.isEmpty) return null;
      final localPwd = channelsProvider()[channel];
      if (localPwd == null) return null; // 未加入该频道，忽略
      final private = (map['private'] as bool?) ?? false;
      data = _deobfuscate(map, private ? localPwd : '');
    }

    final files = await _persistFiles(
      ((data['files'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
    );
    final msg = LanMessage(
      id: _nextId(),
      channel: channel,
      fromName: data['from'] as String? ?? '对方',
      fromAddress: data['fromAddress'] as String? ?? '',
      text: data['text'] as String? ?? '',
      files: files,
      time: DateTime.now(),
      isSelf: false,
      isP2P: isP2P,
      peer: isP2P ? (data['fromAddress'] as String? ?? '') : '',
    );
    onMessage(msg);
    return msg;
  }

  /// 把报文中的文件写入应用文档目录，返回可供展示与下载的条目。
  Future<List<LanFileItem>> _persistFiles(
    List<Map<String, dynamic>> rawFiles,
  ) async {
    if (rawFiles.isEmpty) return const [];
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final folder = Directory('${dir.path}/EverLink/Received/$ts');
    await folder.create(recursive: true);

    final out = <LanFileItem>[];
    for (var i = 0; i < rawFiles.length; i++) {
      final fm = rawFiles[i];
      final name = (fm['name'] as String?) ?? 'file_$i';
      final bytes = _decodeData(fm['data'] as String? ?? '');
      final path = '${folder.path}/$name';
      try {
        await File(path).writeAsBytes(bytes);
      } catch (_) {
        continue;
      }
      out.add(LanFileItem(
        id: '${ts}_$i',
        name: name,
        size: bytes.length,
        mime: (fm['mime'] as String?) ?? 'application/octet-stream',
        savedPath: path,
      ));
    }
    return out;
  }

  String _nextId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${_seq++}';

  // -------------------------------------------------------------- XOR 混淆

  /// 用密码对文字与文件数据做 XOR 混淆（密码为空则原样返回）。
  /// 注意：这是轻量混淆而非强加密，仅防止局域网内明文泄露；密码不外发。
  Map<String, dynamic> _obfuscate(Map<String, dynamic> map, String password) {
    if (password.isEmpty) return Map<String, dynamic>.from(map);
    final key = utf8.encode(password);
    return _mapWith(map, (text) => _obfuscateText(text, key),
        (data) => _xorData(data, key));
  }

  /// 还原：与 _obfuscate 对称。
  Map<String, dynamic> _deobfuscate(Map<String, dynamic> map, String password) {
    if (password.isEmpty) return Map<String, dynamic>.from(map);
    final key = utf8.encode(password);
    return _mapWith(map, (text) => _deobfuscateText(text, key),
        (data) => _xorData(data, key));
  }

  Map<String, dynamic> _mapWith(
    Map<String, dynamic> map,
    String Function(String) onText,
    String Function(String) onData,
  ) {
    final out = <String, dynamic>{};
    for (final e in map.entries) {
      if (e.key == 'text' && e.value is String) {
        out[e.key] = onText(e.value as String);
      } else if (e.key == 'files' && e.value is List) {
        out[e.key] = (e.value as List).map((f) {
          final fm = Map<String, dynamic>.from(f as Map);
          if (fm['data'] is String) fm['data'] = onData(fm['data'] as String);
          return fm;
        }).toList();
      } else {
        out[e.key] = e.value;
      }
    }
    return out;
  }

  String _obfuscateText(String s, List<int> key) =>
      base64Encode(_xorBytes(Uint8List.fromList(utf8.encode(s)), key));

  String _deobfuscateText(String s, List<int> key) {
    try {
      return utf8.decode(_xorBytes(base64Decode(s), key));
    } catch (_) {
      return s;
    }
  }

  String _xorData(String dataUrl, List<int> key) {
    final idx = dataUrl.indexOf(',');
    final header = idx >= 0 ? dataUrl.substring(0, idx + 1) : '';
    final b64 = idx >= 0 ? dataUrl.substring(idx + 1) : dataUrl;
    Uint8List bytes;
    try {
      bytes = base64Decode(b64);
    } catch (_) {
      return dataUrl;
    }
    return '$header${base64Encode(_xorBytes(bytes, key))}';
  }

  Uint8List _xorBytes(Uint8List data, List<int> key) {
    final out = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      out[i] = data[i] ^ key[i % key.length];
    }
    return out;
  }

  List<int> _decodeData(String data) {
    final idx = data.indexOf(',');
    final b64 = idx >= 0 ? data.substring(idx + 1) : data;
    try {
      return base64Decode(b64);
    } catch (_) {
      return const [];
    }
  }
}
