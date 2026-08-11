import 'dart:typed_data';

import 'package:mcp_io_opcua/mcp_io_opcua.dart';

/// OPC UA 写入时的目标数据类型。
///
/// 用于在调试页提供“数据类型”下拉，并把用户输入的字符串解析为对应
/// 的 OPC UA BuiltInType 变体值。
enum OpcUaWriteType {
  int32('Int32', OpcUaBuiltInType.int32),
  uint32('UInt32', OpcUaBuiltInType.uInt32),
  int16('Int16', OpcUaBuiltInType.int16),
  uint16('UInt16', OpcUaBuiltInType.uInt16),
  int64('Int64', OpcUaBuiltInType.int64),
  uint64('UInt64', OpcUaBuiltInType.uInt64),
  float('Float', OpcUaBuiltInType.float),
  double('Double', OpcUaBuiltInType.double_),
  boolean('Boolean', OpcUaBuiltInType.boolean),
  string('String', OpcUaBuiltInType.string);

  const OpcUaWriteType(this.label, this.builtInType);

  final String label;
  final OpcUaBuiltInType builtInType;

  /// 把用户输入的原始字符串解析为本类型对应的 Dart 值。
  Object parse(String raw) {
    final text = raw.trim();
    switch (this) {
      case int32:
      case uint32:
      case int16:
      case uint16:
      case int64:
      case uint64:
        return int.parse(text);
      case float:
      case double:
        return double.parse(text);
      case boolean:
        return text.toLowerCase() == 'true' || text == '1';
      case string:
        return text;
    }
  }
}

/// 一次 OPC UA 读操作的友好结果（剥离底层库类型，便于 UI 展示）。
class OpcUaReadResult {
  const OpcUaReadResult({
    required this.nodeId,
    required this.value,
    required this.typeName,
    required this.statusCode,
    required this.good,
    this.sourceTimestamp,
  });

  final String nodeId;
  final Object? value;
  final String typeName;
  final int statusCode;
  final bool good;
  final DateTime? sourceTimestamp;
}

/// 浏览（Browse）得到的单个节点条目。
class OpcUaNodeEntry {
  const OpcUaNodeEntry({
    required this.nodeId,
    required this.browseName,
    required this.displayName,
    required this.nodeClass,
  });

  final String nodeId;
  final String browseName;
  final String displayName;
  final int nodeClass;

  /// 是否为变量节点（通常可读写其值）。
  bool get isVariable => nodeClass == 2;
}

/// 树形浏览中的一个节点：在 [OpcUaNodeEntry] 之外保存子节点与展开状态，
/// 用于把地址空间以「可展开/收起」的树呈现，而非逐层平铺。
class OpcUaBrowseNode {
  OpcUaBrowseNode(this.entry);

  /// 本节点对应的浏览条目。
  final OpcUaNodeEntry entry;

  /// 子节点（懒加载，展开时填充）。
  final List<OpcUaBrowseNode> children = [];

  /// 是否已展开（展示子节点）。
  bool expanded = false;

  /// 子节点是否已成功加载过（避免重复请求）。
  bool loaded = false;

  /// 是否正在加载子节点。
  bool loading = false;

  /// 加载失败时的错误信息（null 表示无错误）。
  String? loadError;
}

/// 监控列表中的一项：一个被用户“加入监控”的变量节点。
///
/// 页面会以固定间隔对其调用 [OpcUaProtocol.read]，把最新值写入 [latest]，
/// 从而在“监控”页实时展示。监控状态是会话级的（随页面存在），连接断开即停止轮询。
class OpcUaMonitorItem {
  OpcUaMonitorItem({
    required this.nodeId,
    required this.displayName,
    this.latest,
    this.updatedAt,
  });

  /// 节点 ID（如 ns=2;i=1001）。
  final String nodeId;

  /// 展示名（优先用浏览得到的 displayName / browseName）。
  final String displayName;

  /// 最近一次读取结果（可能为 null，表示尚未读到）。
  OpcUaReadResult? latest;

  /// 最近一次成功更新的时间。
  DateTime? updatedAt;

  /// 序列化为可持久化的 JSON（仅保存节点标识与展示名，最新值随连接重新读取）。
  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'displayName': displayName,
      };

  factory OpcUaMonitorItem.fromJson(Map<String, dynamic> j) => OpcUaMonitorItem(
        nodeId: j['nodeId'] as String,
        displayName: j['displayName'] as String,
      );

  /// 节点 ID 相同即视为同一项，用于去重。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpcUaMonitorItem && other.nodeId == nodeId;

  @override
  int get hashCode => nodeId.hashCode;
}

/// OPC UA 认证方式。
///
/// 说明：当前底层 `mcp_io_opcua 0.2.1` 仅在 [activateSession] 实现了
/// `OpcUaAnonymousIdentityToken`（匿名），`userName` / `certificate` 在 UI 与
/// 连接配置中可录入并持久化，但连接时若选中非匿名方式会被协议层以明确的
/// [UnsupportedError] 拒绝（能力降级，待底层库升级）。
enum OpcUaAuthMode {
  anonymous('anonymous', '匿名'),
  userName('userName', '用户名密码'),
  certificate('certificate', 'X.509 证书');

  const OpcUaAuthMode(this.id, this.label);

  /// 配置 JSON 中使用的稳定标识。
  final String id;

  /// 展示名。
  final String label;

  /// 由 [id] 反查枚举，未知值回退到匿名。
  static OpcUaAuthMode fromId(String? id) =>
      OpcUaAuthMode.values.firstWhere((e) => e.id == id,
          orElse: () => OpcUaAuthMode.anonymous);
}

/// OPC UA 安全策略枚举（用于 UI 选择与配置持久化）。
///
/// `uri` 使用 OPC UA 规范定义的权威 URI（见 Part 7）。其中只有 `None`
/// 在底层库被完整握手；`basic256Sha256` / `basic128Rsa15` 在 UI 可选、配置
/// 可存，但底层库尚未在 SecureChannel 握手阶段完成对称密钥派生与绑定，连接
/// 时会被协议层以明确的 [UnsupportedError] 拒绝（能力降级）。
enum OpcUaSecurityPolicyKind {
  none(
    'http://opcfoundation.org/UA/SecurityPolicy#None',
    'None（无安全）',
  ),
  basic256Sha256(
    'http://opcfoundation.org/UA/SecurityPolicy#Basic256Sha256',
    'Basic256Sha256',
  ),
  basic128Rsa15(
    'http://opcfoundation.org/UA/SecurityPolicy#Basic128Rsa15',
    'Basic128Rsa15',
  );

  const OpcUaSecurityPolicyKind(this.uri, this.label);

  /// 规范定义的 SecurityPolicy URI。
  final String uri;

  /// 展示名。
  final String label;

  /// 是否为底层库当前完整支持的策略。
  bool get supported => this == OpcUaSecurityPolicyKind.none;

  /// 由 URI 反查枚举，未知值回退到 None。
  static OpcUaSecurityPolicyKind fromUri(String? uri) =>
      OpcUaSecurityPolicyKind.values.firstWhere((e) => e.uri == uri,
          orElse: () => OpcUaSecurityPolicyKind.none);
}

/// 链路收发方向（用于原始报文视图）。
enum OpcUaTrafficDirection { tx, rx }

/// 一次 OPC UA 链路收发的原始字节记录（用于“报文”视图）。
///
/// 注意：这不是 pcap 级抓包，仅记录本应用经 TCP 套接字实际收发的字节流。
/// 在 `None` 安全策略下这些字节是明文 OPC UA 二进制；在签名/加密策略下则是
/// 链路密文。
class OpcUaTrafficRecord {
  OpcUaTrafficRecord({
    required this.direction,
    required this.bytes,
    required this.time,
  });

  /// 方向：tx = 本端发出，rx = 本端收到。
  final OpcUaTrafficDirection direction;

  /// 原始字节（按收到的分块记录，不构成完整帧边界）。
  final Uint8List bytes;

  /// 收发时间。
  final DateTime time;

  /// 字节长度。
  int get length => bytes.length;
}
