/// 局域网内发现的设备。
class DiscoveredDevice {
  final String id;
  final String name;
  final String address; // host:port
  final DateTime lastSeen;

  /// 由主动扫描或手动添加确认存在的设备：不依赖 UDP 心跳保活，
  /// 避免在广播被路由器拦截的网络里刚扫到就被判定离线。
  final bool pinned;

  /// 是否为通过网页（HTTP）连接到本机的对端（仅扫码打开网页、未安装 App）。
  final bool isWeb;

  DiscoveredDevice({
    required this.id,
    required this.name,
    required this.address,
    required this.lastSeen,
    this.pinned = false,
    this.isWeb = false,
  });

  String get host => address.split(':').first;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'addr': address,
        'web': isWeb,
      };
}

/// 一个已落盘的文件（收到的或自己发出的）。
class LanFileItem {
  final String id;
  final String name;
  final int size;
  final String mime;
  final String savedPath;

  LanFileItem({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.savedPath,
  });

  factory LanFileItem.fromJson(Map<String, dynamic> m) => LanFileItem(
        id: m['id'] as String,
        name: m['name'] as String,
        size: m['size'] as int,
        mime: m['mime'] as String? ?? 'application/octet-stream',
        savedPath: m['savedPath'] as String? ?? '',
      );

  bool get isImage => mime.startsWith('image/');

  String get sizeText {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'size': size,
        'mime': mime,
        'savedPath': savedPath,
        'url': '/api/file?id=$id',
      };
}

/// 一条聊天消息（文字 + 若干文件）。
///
/// 无论是自己发出的、频道里收到的，还是点对点收到的，统一用这一个模型，
/// 便于以聊天流的形式呈现。
class LanMessage {
  final String id;

  /// 所属频道；点对点消息为空字符串。
  final String channel;
  final String fromName;
  final String fromAddress;
  final String text;
  final List<LanFileItem> files;
  final DateTime time;

  /// 是否为本机发出（聊天气泡靠右显示）。
  final bool isSelf;

  /// 是否为点对点消息（非频道广播）。
  final bool isP2P;

  /// 点对点会话的对端地址：自己发出时为目标设备，收到时为发送方。
  /// 用于把点对点消息按设备分组成一个个独立会话。
  final String peer;

  LanMessage({
    required this.id,
    required this.channel,
    required this.fromName,
    required this.fromAddress,
    required this.text,
    required this.files,
    required this.time,
    this.isSelf = false,
    this.isP2P = false,
    this.peer = '',
  });

  factory LanMessage.fromJson(Map<String, dynamic> m) => LanMessage(
        id: m['id'] as String,
        channel: m['channel'] as String? ?? '',
        fromName: m['from'] as String? ?? '',
        fromAddress: m['fromAddress'] as String? ?? '',
        text: m['text'] as String? ?? '',
        files: ((m['files'] as List?) ?? [])
            .map((e) => LanFileItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        time: DateTime.fromMillisecondsSinceEpoch(m['time'] as int),
        isSelf: m['self'] as bool? ?? false,
        isP2P: m['p2p'] as bool? ?? false,
        peer: m['peer'] as String? ?? '',
      );

  String get summary {
    final parts = <String>[];
    if (text.isNotEmpty) parts.add(text);
    if (files.isNotEmpty) parts.add('${files.length} 个文件');
    return parts.isEmpty ? '空消息' : parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'channel': channel,
        'from': fromName,
        'fromAddress': fromAddress,
        'text': text,
        'files': files.map((f) => f.toJson()).toList(),
        'time': time.millisecondsSinceEpoch,
        'self': isSelf,
        'p2p': isP2P,
        'peer': peer,
      };
}

/// 频道：公共频道（password 为空）或私有频道（password 非空）。
///
/// 仅已加入某频道的设备才会收到该频道的消息；私有频道内容以密码做 XOR 混淆，
/// 不知密码者即使截获报文也无法还原内容。频道只能在 App 端创建/加入，
/// 网页端只能通过二维码（URL 参数）进入指定频道。
class LanChannel {
  final String name;
  final String password; // 空字符串表示公共频道

  const LanChannel({required this.name, this.password = ''});

  bool get isPrivate => password.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'name': name,
        'private': isPrivate,
      };
}

/// 默认公共频道名。
const String kPublicChannel = '公共频道';

