import 'dart:async';

import 'package:flutter/material.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/device_session.dart';
import 'package:everlink/models/mqtt_models.dart';
import 'package:everlink/protocols/mqtt_protocol.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/ui/widgets/connection_panel.dart';

/// MQTT 调试页：连接 Broker、管理订阅、发布消息，并把收发过程沉淀到历史。
///
/// 支持一次订阅多个主题（逗号分隔、支持 # + 通配符）；已订阅主题以可移除的
/// 标签展示，并按主题筛选收到的消息；连接配置支持干净会话与遗嘱消息等高级项。
class MqttPage extends StatefulWidget {
  const MqttPage({super.key, required this.session});

  final DeviceSession session;

  @override
  State<MqttPage> createState() => _MqttPageState();
}

class _MqttPageState extends State<MqttPage> {
  late final ConnectionManager _manager;
  final _formKey = GlobalKey<FormState>();

  final _hostCtl = TextEditingController();
  final _portCtl = TextEditingController();
  final _clientIdCtl = TextEditingController();
  final _userCtl = TextEditingController();
  final _passCtl = TextEditingController();
  final _keepAliveCtl = TextEditingController();
  final _willTopicCtl = TextEditingController();
  final _willPayloadCtl = TextEditingController();
  bool _useTls = false;
  bool _cleanSession = true;
  bool _willRetain = false;

  final _subTopicCtl = TextEditingController(text: 'test/topic');
  MqttQosLevel _subQos = MqttQosLevel.atMostOnce;

  final _pubTopicCtl = TextEditingController(text: 'test/topic');
  final _payloadCtl = TextEditingController(text: 'hello');
  MqttQosLevel _pubQos = MqttQosLevel.atMostOnce;
  bool _retain = false;

  final List<String> _subscribedTopics = [];
  String? _subFilter;
  final List<MqttMessageRecord> _messages = [];
  String? _error;
  StreamSubscription<MqttMessageRecord>? _sub;

  @override
  void initState() {
    super.initState();
    final c = widget.session.config as MqttConnectionConfig;
    _hostCtl.text = c.host;
    _portCtl.text = '${c.port}';
    _clientIdCtl.text = c.clientId;
    _userCtl.text = c.username ?? '';
    _passCtl.text = c.password ?? '';
    _useTls = c.useTls;
    _keepAliveCtl.text = '${c.keepAlive}';
    _cleanSession = c.cleanSession;
    _willTopicCtl.text = c.willTopic ?? '';
    _willPayloadCtl.text = c.willPayload ?? '';
    _willRetain = c.willRetain;
    _manager = SessionManager.instance.ensureManager(widget.session);
    _manager.addListener(_onManagerChanged);
    _sub = (_manager.protocol as MqttProtocol).messageStream.listen((m) {
      setState(() => _messages.insert(0, m));
      HistoryService.instance.add(
        HistoryRecord(
          time: m.receivedAt,
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.receive,
          success: true,
          summary: '收到消息：${m.topic}',
          detail: m.payload,
        ),
      );
    });
  }

  void _onManagerChanged() {
    if (mounted) setState(() {});
  }

  void _syncConfigFromFields() {
    final cfg = MqttConnectionConfig(
      host: _hostCtl.text.trim(),
      port: int.tryParse(_portCtl.text) ?? 1883,
      clientId: _clientIdCtl.text.trim(),
      username: _userCtl.text.trim().isEmpty ? null : _userCtl.text.trim(),
      password: _passCtl.text.isEmpty ? null : _passCtl.text,
      useTls: _useTls,
      keepAlive: int.tryParse(_keepAliveCtl.text) ?? 60,
      cleanSession: _cleanSession,
      willTopic: _willTopicCtl.text.trim().isEmpty
          ? null
          : _willTopicCtl.text.trim(),
      willPayload: _willPayloadCtl.text.isEmpty ? null : _willPayloadCtl.text,
      willRetain: _willRetain,
    );
    _manager.updateConfig(cfg);
    widget.session.config = cfg;
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;
    _syncConfigFromFields();
    try {
      await _manager.connect();
      final ok = _manager.state == DeviceConnectionState.connected;
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.connect,
          success: ok,
          summary: ok
              ? '连接成功：${widget.session.name}'
              : '连接失败：${widget.session.name}',
          error: ok ? null : _manager.lastError,
        ),
      );
    } catch (e) {
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.connect,
          success: false,
          summary: '连接失败：${widget.session.name}',
          error: e.toString(),
        ),
      );
    }
  }

  Future<void> _disconnect() async {
    await _manager.disconnect();
    setState(() => _subscribedTopics.clear());
    HistoryService.instance.add(
      HistoryRecord(
        time: DateTime.now(),
        type: widget.session.type,
        deviceName: widget.session.name,
        op: HistoryOp.disconnect,
        success: true,
        summary: '断开连接：${widget.session.name}',
      ),
    );
  }

  /// 把逗号 / 空白分隔的主题串拆成去空白、去空的主题列表。
  List<String> _splitTopics(String raw) => raw
      .split(RegExp(r'[,\s]+'))
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();

  void _subscribe() {
    final raw = _subTopicCtl.text.trim();
    if (raw.isEmpty) return;
    final topics = _splitTopics(raw);
    try {
      (_manager.protocol as MqttProtocol).subscribe(raw, qos: _subQos);
      for (final t in topics) {
        if (!_subscribedTopics.contains(t)) _subscribedTopics.add(t);
      }
      setState(() => _error = null);
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.subscribe,
          success: true,
          summary: '订阅主题：${topics.join(', ')}',
        ),
      );
    } catch (e) {
      setState(() => _error = e.toString());
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.subscribe,
          success: false,
          summary: '订阅主题失败：${topics.join(', ')}',
          error: e.toString(),
        ),
      );
    }
  }

  void _unsubscribe(String topic) {
    (_manager.protocol as MqttProtocol).unsubscribe(topic);
    setState(() {
      _subscribedTopics.remove(topic);
      if (_subFilter == topic) _subFilter = null;
    });
  }

  void _unsubscribeAll() {
    (_manager.protocol as MqttProtocol).unsubscribeAll();
    setState(() {
      _subscribedTopics.clear();
      _subFilter = null;
    });
  }

  void _publish() {
    final topic = _pubTopicCtl.text.trim();
    if (topic.isEmpty) return;
    final payload = _payloadCtl.text;
    try {
      (_manager.protocol as MqttProtocol).publish(
        topic,
        payload,
        qos: _pubQos,
        retain: _retain,
      );
      setState(() => _error = null);
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.publish,
          success: true,
          summary: '发布到 $topic',
          detail: payload,
        ),
      );
    } catch (e) {
      setState(() => _error = e.toString());
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.publish,
          success: false,
          summary: '发布失败：$topic',
          error: e.toString(),
        ),
      );
    }
  }

  int _countFor(String topic) =>
      _messages.where((m) => m.topic == topic).length;

  @override
  Widget build(BuildContext context) {
    final connected = _manager.state == DeviceConnectionState.connected;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.name),
        actions: [
          IconButton(
            icon: Icon(connected ? Icons.link_off : Icons.link),
            tooltip: connected ? '断开' : '连接',
            onPressed: _manager.state == DeviceConnectionState.connecting
                ? null
                : (connected ? _disconnect : _connect),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ConnectionPanel(manager: _manager, onConnectPressed: _connect),
          const SizedBox(height: 12),
          _buildConnectionForm(),
          const SizedBox(height: 12),
          _buildSubscribeCard(connected),
          const SizedBox(height: 12),
          _buildPublishCard(connected),
          const SizedBox(height: 12),
          _buildMessagesCard(),
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
              const Text('连接配置',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: _hostCtl,
                      decoration: const InputDecoration(labelText: 'Broker 地址'),
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
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _userCtl,
                      decoration: const InputDecoration(labelText: '用户名（可选）'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _passCtl,
                      decoration: const InputDecoration(labelText: '密码（可选）'),
                      obscureText: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _keepAliveCtl,
                      decoration: const InputDecoration(labelText: '保活间隔(秒)'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
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
              const Divider(),
              const Text('遗嘱消息（异常断开时 Broker 自动发布）',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _willTopicCtl,
                      decoration: const InputDecoration(labelText: '主题（可选）'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _willPayloadCtl,
                      decoration: const InputDecoration(labelText: '内容（可选）'),
                    ),
                  ),
                ],
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _willRetain,
                onChanged: (v) => setState(() => _willRetain = v ?? false),
                title: const Text('遗嘱消息保留(Retain)'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubscribeCard(bool connected) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('订阅',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                if (_subscribedTopics.isNotEmpty)
                  TextButton(
                    onPressed: connected ? _unsubscribeAll : null,
                    child: const Text('取消全部'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _subTopicCtl,
                    decoration: const InputDecoration(
                      labelText: '主题（支持逗号分隔多个 / # + 通配符）',
                    ),
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
                runSpacing: 4,
                children: _subscribedTopics.map((t) {
                  final active = _subFilter == t;
                  return FilterChip(
                    label: Text('$t (${_countFor(t)})'),
                    selected: active,
                    onSelected: (_) =>
                        setState(() => _subFilter = active ? null : t),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onDeleted: connected ? () => _unsubscribe(t) : null,
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPublishCard(bool connected) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('发布',
                style: TextStyle(fontWeight: FontWeight.bold)),
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
                    const Text('保留'),
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
    );
  }

  Widget _buildMessagesCard() {
    // 按主题分组，每组以可展开的区块呈现，实现“按 topic 分类”。
    final Map<String, List<MqttMessageRecord>> groups = {};
    for (final m in _messages) {
      (groups[m.topic] ??= []).add(m);
    }
    final topics = groups.keys
        .where((t) => _subFilter == null || t == _subFilter)
        .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('接收到的消息 (${_messages.length})',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.red)),
              ),
            if (_messages.isEmpty)
              const Text('订阅主题后，收到的消息会按主题分组显示在这里',
                  style: TextStyle(color: Colors.grey)),
            if (_subFilter != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Chip(
                  label: Text('筛选：$_subFilter'),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () => setState(() => _subFilter = null),
                ),
              ),
            if (topics.isEmpty && _messages.isNotEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('当前筛选条件下没有消息',
                    style: TextStyle(color: Colors.grey)),
              ),
            ...topics.map((t) {
              final items = groups[t]!;
              return ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Row(
                  children: [
                    Expanded(
                      child: Text(t,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.teal,
                              fontSize: 13)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.teal.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('${items.length}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.teal)),
                    ),
                  ],
                ),
                children:
                    items.map((m) => _MessageTile(record: m)).toList(),
              );
            }),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _manager.removeListener(_onManagerChanged);
    _hostCtl.dispose();
    _portCtl.dispose();
    _clientIdCtl.dispose();
    _userCtl.dispose();
    _passCtl.dispose();
    _keepAliveCtl.dispose();
    _willTopicCtl.dispose();
    _willPayloadCtl.dispose();
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
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: Colors.teal)),
              ),
              Text(time,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(record.payload,
              style: const TextStyle(fontFamily: 'monospace')),
        ],
      ),
    );
  }
}
