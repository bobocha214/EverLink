import 'dart:convert';

import 'package:mcp_io_opcua/mcp_io_opcua.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:everlink/services/opcua_server.dart';

/// OPC UA 服务端自定义节点的本地持久化。
///
/// 用户增删/编辑的节点列表存到 SharedPreferences（JSON），App 重启后自动恢复，
/// 避免每次进入页面都回到默认示例。无记录时返回 `null`，由页面回退到
/// [defaultOpcUaNodes] 默认示例。
class OpcUaNodesStore {
  static const String _key = 'opcua_nodes_v1';

  /// 读取已保存的节点列表；无记录或解析失败返回 `null`。
  static Future<List<OpcUaNode>?> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return null;
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return [
        for (final m in list)
          OpcUaNode(
            namespaceIndex: m['ns'] as int,
            identifier: m['id'] as String,
            name: m['name'] as String,
            builtInType: OpcUaBuiltInType.values.byName(m['type'] as String),
            valueText: m['val'] as String,
          )
      ];
    } catch (_) {
      return null;
    }
  }

  /// 保存当前节点列表（覆盖式）。
  static Future<void> save(List<OpcUaNode> nodes) async {
    final p = await SharedPreferences.getInstance();
    final list = [
      for (final n in nodes)
        {
          'ns': n.namespaceIndex,
          'id': n.identifier,
          'name': n.name,
          'type': n.builtInType.name,
          'val': n.valueText,
        }
    ];
    await p.setString(_key, jsonEncode(list));
  }
}
