import 'package:flutter/material.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/device_session.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/protocol_registry.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/services/settings_service.dart';

/// 添加设备流程：先选协议类型，再填写设备名称与连接参数，保存后【不会自动
/// 连接】——由用户在设备详情页手动连接 / 断开。地址字段允许留空，保存时不会
/// 因空值而报错。
Future<DeviceSession?> showAddDeviceSheet(BuildContext context) async {
  return showModalBottomSheet<DeviceSession>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _AddDeviceSheet(),
  );
}

class _AddDeviceSheet extends StatefulWidget {
  const _AddDeviceSheet();

  @override
  State<_AddDeviceSheet> createState() => _AddDeviceSheetState();
}

class _AddDeviceSheetState extends State<_AddDeviceSheet> {
  int _step = 0;
  ProtocolType? _type;

  final _nameCtl = TextEditingController();
  final _hostCtl = TextEditingController();
  final _portCtl = TextEditingController();
  final _unitCtl = TextEditingController();
  final _clientIdCtl = TextEditingController();
  final _userCtl = TextEditingController();
  final _passCtl = TextEditingController();
  final _keepAliveCtl = TextEditingController(text: '60');
  final _willTopicCtl = TextEditingController();
  final _willPayloadCtl = TextEditingController();
  final _protoCtl = TextEditingController();
  final _timeoutCtl = TextEditingController(text: '8');
  final _defaultHeadersCtl = TextEditingController();
  bool _useTls = false;
  bool _cleanSession = true;
  String? _nameError;

  @override
  void dispose() {
    _nameCtl.dispose();
    _hostCtl.dispose();
    _portCtl.dispose();
    _unitCtl.dispose();
    _clientIdCtl.dispose();
    _userCtl.dispose();
    _passCtl.dispose();
    _keepAliveCtl.dispose();
    _willTopicCtl.dispose();
    _willPayloadCtl.dispose();
    _protoCtl.dispose();
    _timeoutCtl.dispose();
    _defaultHeadersCtl.dispose();
    super.dispose();
  }

  void _pickType(ProtocolType t) {
    _type = t;
    _portCtl.clear();
    _unitCtl.text = '1';
    _clientIdCtl.text = 'everlink_${DateTime.now().millisecondsSinceEpoch}';
    _hostCtl.text = '';
    switch (t) {
      case ProtocolType.modbusTcp:
        _portCtl.text = '502';
        _unitCtl.text = '1';
      case ProtocolType.mqtt:
        _portCtl.text = '1883';
        _clientIdCtl.text = 'everlink_${DateTime.now().millisecondsSinceEpoch}';
      case ProtocolType.webSocket:
        _hostCtl.text = 'ws://';
      case ProtocolType.http:
        _hostCtl.text = 'http://';
      case ProtocolType.opcUa:
        _hostCtl.text = 'opc.tcp://';
      case ProtocolType.tcpRaw:
        _portCtl.text = '502';
    }
    setState(() => _step = 1);
  }

  void _back() => setState(() => _step = 0);

  Map<String, String>? _parseHeaders(String raw) {
    final map = <String, String>{};
    for (final line in raw.split('\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final k = line.substring(0, idx).trim();
      final v = line.substring(idx + 1).trim();
      if (k.isNotEmpty) map[k] = v;
    }
    return map.isEmpty ? null : map;
  }

  Future<void> _save() async {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = '请填写设备名称');
      return;
    }
    final host = _hostCtl.text.trim();
    final protos = _protoCtl.text
        .split(RegExp(r'[,\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final defaultHeaders = _parseHeaders(_defaultHeadersCtl.text);
    ConnectionConfig config;
    switch (_type!) {
      case ProtocolType.modbusTcp:
        config = ModbusConnectionConfig(
          host: host,
          port: int.tryParse(_portCtl.text) ?? 502,
          unitId: int.tryParse(_unitCtl.text) ?? 1,
        );
      case ProtocolType.mqtt:
        final clientId = _clientIdCtl.text.trim().isEmpty
            ? 'everlink_${DateTime.now().millisecondsSinceEpoch}'
            : _clientIdCtl.text.trim();
        config = MqttConnectionConfig(
          host: host,
          port: int.tryParse(_portCtl.text) ?? 1883,
          clientId: clientId,
          username: _userCtl.text.trim().isEmpty ? null : _userCtl.text.trim(),
          password: _passCtl.text.isEmpty ? null : _passCtl.text,
          useTls: _useTls,
          keepAlive: int.tryParse(_keepAliveCtl.text) ?? 60,
          cleanSession: _cleanSession,
          willTopic: _willTopicCtl.text.trim().isEmpty
              ? null
              : _willTopicCtl.text.trim(),
          willPayload:
              _willPayloadCtl.text.isEmpty ? null : _willPayloadCtl.text,
        );
      case ProtocolType.webSocket:
        config = WebSocketConnectionConfig(url: host, protocols: protos);
      case ProtocolType.http:
        config = HttpConnectionConfig(
          baseUrl: host,
          timeout: Duration(seconds: int.tryParse(_timeoutCtl.text) ?? 8),
          defaultHeaders: defaultHeaders,
        );
      case ProtocolType.opcUa:
        config = OpcUaConnectionConfig(endpoint: host);
      case ProtocolType.tcpRaw:
        config = TcpRawConnectionConfig(
          host: host,
          port: int.tryParse(_portCtl.text) ?? 502,
        );
    }
    final session =
        DeviceSession.create(name: name, type: _type!, config: config);
    await SessionManager.instance.addSession(session);
    if (mounted) Navigator.of(context).pop(session);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: _step == 0 ? _buildTypePicker() : _buildForm(),
      ),
    );
  }

  Widget _buildTypePicker() {
    final descriptors = SettingsService.instance.enabledDescriptors;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('选择协议类型',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 12),
          if (descriptors.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('所有协议均已停用，请在“设置”中启用。',
                    style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            ...descriptors.map(
              (d) => ListTile(
                leading: Icon(d.icon, color: Colors.teal),
                title: Text(d.name),
                subtitle: Text(d.description),
                onTap: () => _pickType(d.type),
              ),
            ),
        ],
      ),
    );
  }

  String get _title {
    final name = _type == null ? '' : ProtocolRegistry.get(_type!).name;
    return '添加$name设备';
  }

  String get _addressLabel {
    switch (_type) {
      case ProtocolType.modbusTcp:
        return 'IP 地址（可留空，连接时再填）';
      case ProtocolType.mqtt:
        return 'Broker 地址（可留空）';
      case ProtocolType.webSocket:
        return 'WebSocket 地址（可留空）';
      case ProtocolType.http:
        return 'Base URL（可留空）';
      case ProtocolType.opcUa:
        return 'OPC UA 端点（可留空）';
      case ProtocolType.tcpRaw:
        return 'IP 或域名（可留空，连接时再填）';
      default:
        return '地址';
    }
  }

  String get _addressHint {
    switch (_type) {
      case ProtocolType.modbusTcp:
        return '请输入 IP 地址';
      case ProtocolType.mqtt:
        return '如 broker.emqx.io';
      case ProtocolType.webSocket:
        return 'ws://host:port/path 或 wss://...';
      case ProtocolType.http:
        return 'https://api.example.com';
      case ProtocolType.opcUa:
        return 'opc.tcp://host:4840';
      case ProtocolType.tcpRaw:
        return '如 192.168.1.10';
      default:
        return '';
    }
  }

  Widget _buildForm() {
    final isModbus = _type == ProtocolType.modbusTcp;
    final isMqtt = _type == ProtocolType.mqtt;
    final isWs = _type == ProtocolType.webSocket;
    final isHttp = _type == ProtocolType.http;
    final isTcpRaw = _type == ProtocolType.tcpRaw;
    final showPort = isModbus || isMqtt || isTcpRaw;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(onPressed: _back, icon: const Icon(Icons.arrow_back)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtl,
            decoration: InputDecoration(
              labelText: '设备名称',
              errorText: _nameError,
              hintText: '如：1号车间PLC',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _hostCtl,
            decoration: InputDecoration(
              labelText: _addressLabel,
              hintText: _addressHint,
            ),
          ),
          const SizedBox(height: 12),
          if (showPort)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _portCtl,
                    decoration: const InputDecoration(labelText: '端口'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                if (isModbus) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _unitCtl,
                      decoration: const InputDecoration(labelText: '从站 ID'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
                if (isMqtt) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _clientIdCtl,
                      decoration: const InputDecoration(labelText: '客户端 ID'),
                    ),
                  ),
                ],
              ],
            ),
          if (isMqtt) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _userCtl,
              decoration: const InputDecoration(labelText: '用户名（可选）'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passCtl,
              decoration: const InputDecoration(labelText: '密码（可选）'),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _keepAliveCtl,
                    decoration: const InputDecoration(labelText: '保活间隔(秒)'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _cleanSession,
                    onChanged: (v) => setState(() => _cleanSession = v ?? true),
                    title: const Text('干净会话', style: TextStyle(fontSize: 13)),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ),
              ],
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _useTls,
              onChanged: (v) => setState(() => _useTls = v ?? false),
              title: const Text('使用 TLS/SSL 加密'),
            ),
            const SizedBox(height: 4),
            const Text('遗嘱消息（可选，连接异常断开时由 Broker 自动发布）',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _willTopicCtl,
                    decoration: const InputDecoration(labelText: '遗嘱主题'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _willPayloadCtl,
                    decoration: const InputDecoration(labelText: '遗嘱内容'),
                  ),
                ),
              ],
            ),
          ],
          if (isWs) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _protoCtl,
              decoration: const InputDecoration(
                labelText: '子协议（可选，逗号分隔）',
                hintText: '如 chat, superchat',
              ),
            ),
          ],
          if (isHttp) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _timeoutCtl,
              decoration: const InputDecoration(labelText: '超时(秒)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _defaultHeadersCtl,
              decoration: const InputDecoration(
                labelText: '默认请求头（可选，每行 Key: Value）',
                alignLabelWithHint: true,
              ),
              maxLines: 3,
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _save,
              child: const Text('保存设备'),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '保存后不会自动连接，请在设备页手动连接 / 断开。',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
