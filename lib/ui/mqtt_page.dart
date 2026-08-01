import 'package:flutter/material.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/mqtt_models.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/mqtt_protocol.dart';
import 'package:everlink/protocols/protocol_registry.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/ui/widgets/connection_panel.dart';

/// MQTT 调试页：支持连接 Broker、订阅主题、发布消息。
class MqttPage extends StatefulWidget {
  const MqttPage({super.key});

  @override
  State<MqttPage> createState() => _MqttPageState();
}

class _MqttPageState extends State<MqttPage> {
  late final ConnectionManager _manager;
  final _formKey = GlobalKey<FormState>();

  final _hostCtl = TextEditingController(text: 'broker.emqx.io');
  final _portCtl = TextEditingController(text: '1883');
  final _clientIdCtl = TextEditingController();
  final _userCtl = TextEditingController();
  final _passCtl = TextEditingController();
  bool _useTls = false;

  final _subTopicCtl = TextEditingController(text: 'test/topic');
  MqttQosLevel _subQos = MqttQosLevel.atMostOnce;

  final _pubTopicCtl = TextEditingController(text: 'test/topic');
  final _payloadCtl = TextEditingController(text: 'hello');
  MqttQosLevel _pubQos = MqttQosLevel.atMostOnce;
  bool _retain = false;

  final List<String> _subscribedTopics = [];
  final List<MqttMessageRecord> _messages = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _manager = ConnectionManager(ProtocolRegistry.get(ProtocolType.mqtt));
    _clientIdCtl.text = 'everlink_${DateTime.now().millisecondsSinceEpoch}';
    _syncConfigFromFields();
    (_manager.protocol as MqttProtocol)
        .messageStream
        .listen((m) => setState(() => _messages.insert(0, m)));
  }

  void _syncConfigFromFields() {
    _manager.updateConfig(
      MqttConnectionConfig(
        host: _hostCtl.text.trim(),
        port: int.tryParse(_portCtl.text) ?? 1883,
        clientId: _clientIdCtl.text.trim(),
        username: _userCtl.text.trim().isEmpty ? null : _userCtl.text.trim(),
        password: _passCtl.text.isEmpty ? null : _passCtl.text,
        useTls: _useTls,
      ),
    );
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;
    _syncConfigFromFields();
    try {
      await _manager.connect();
    } catch (_) {
      // 错误已在面板展示
    }
  }

  void _subscribe() {
    final topic = _subTopicCtl.text.trim();
    if (topic.isEmpty) return;
    try {
      (_manager.protocol as MqttProtocol).subscribe(topic, qos: _subQos);
      if (!_subscribedTopics.contains(topic)) {
        setState(() => _subscribedTopics.add(topic));
      }
      setState(() => _error = null);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _unsubscribe(String topic) {
    (_manager.protocol as MqttProtocol).unsubscribe(topic);
    setState(() => _subscribedTopics.remove(topic));
  }

  void _publish() {
    final topic = _pubTopicCtl.text.trim();
    if (topic.isEmpty) return;
    try {
      (_manager.protocol as MqttProtocol).publish(
        topic,
        _payloadCtl.text,
        qos: _pubQos,
        retain: _retain,
      );
      setState(() => _error = null);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _manager.state == DeviceConnectionState.connected;
    return Scaffold(
      appBar: AppBar(title: const Text('MQTT')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ConnectionPanel(manager: _manager, onConnectPressed: _connect),
          const SizedBox(height: 12),
          _buildConnectionForm(),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('订阅', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _subTopicCtl,
                          decoration: const InputDecoration(labelText: '主题'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      DropdownButton<MqttQosLevel>(
                        value: _subQos,
                        items: MqttQosLevel.values
                            .map((q) => DropdownMenuItem(value: q, child: Text(q.label)))
                            .toList(),
                        onChanged: (v) => setState(() => _subQos = v!),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: connected ? _subscribe : null,
                        icon: const Icon(Icons.add),
                        tooltip: '订阅',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_subscribedTopics.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      children: _subscribedTopics
                          .map(
                            (t) => Chip(
                              label: Text(t),
                              deleteIcon: const Icon(Icons.close, size: 16),
                              onDeleted: () => _unsubscribe(t),
                            ),
                          )
                          .toList(),
                    ),
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 8),
                  const Text('发布', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _pubTopicCtl,
                    decoration: const InputDecoration(labelText: '主题'),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _payloadCtl,
                    decoration: const InputDecoration(labelText: '消息内容'),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      DropdownButton<MqttQosLevel>(
                        value: _pubQos,
                        items: MqttQosLevel.values
                            .map((q) => DropdownMenuItem(value: q, child: Text(q.label)))
                            .toList(),
                        onChanged: (v) => setState(() => _pubQos = v!),
                      ),
                      const SizedBox(width: 8),
                      Row(
                        children: [
                          Checkbox(
                            value: _retain,
                            onChanged: (v) => setState(() => _retain = v!),
                          ),
                          const Text('保留消息'),
                        ],
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: connected ? _publish : null,
                        icon: const Icon(Icons.send),
                        label: const Text('发布'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('接收到的消息', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  if (_error != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(_error!, style: const TextStyle(color: Colors.red)),
                    ),
                  if (_messages.isEmpty)
                    const Text('订阅主题后，收到的消息会显示在这里',
                        style: TextStyle(color: Colors.grey)),
                  ..._messages.map((m) => _MessageTile(record: m)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionForm() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('连接配置', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: _hostCtl,
                      decoration: const InputDecoration(labelText: 'Broker 地址'),
                      validator: (v) => v!.isEmpty ? '必填' : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _portCtl,
                      decoration: const InputDecoration(labelText: '端口'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _clientIdCtl,
                decoration: const InputDecoration(labelText: '客户端 ID'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _userCtl,
                decoration: const InputDecoration(labelText: '用户名（可选）'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _passCtl,
                decoration: const InputDecoration(labelText: '密码（可选）'),
                obscureText: true,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Checkbox(
                    value: _useTls,
                    onChanged: (v) => setState(() => _useTls = v!),
                  ),
                  const Text('使用 TLS/SSL 加密'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _manager.dispose();
    _hostCtl.dispose();
    _portCtl.dispose();
    _clientIdCtl.dispose();
    _userCtl.dispose();
    _passCtl.dispose();
    _subTopicCtl.dispose();
    _pubTopicCtl.dispose();
    _payloadCtl.dispose();
    super.dispose();
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.record});

  final MqttMessageRecord record;

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay.fromDateTime(record.receivedAt).format(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.teal.shade50,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(record.topic,
                    style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.teal)),
              ),
              Text(time, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(record.payload, style: const TextStyle(fontFamily: 'monospace')),
        ],
      ),
    );
  }
}
