import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/device_session.dart';
import 'package:everlink/models/mqtt_models.dart';
import 'package:everlink/protocols/mqtt_protocol.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/mqtt_message_store.dart';
import 'package:everlink/services/mqtt_topic_store.dart';
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

  /// 全局默认 payload 展示格式，持久化记忆。
  MqttPayloadFormat _defaultFormat = MqttPayloadFormat.plain;
  static const String _kDefaultFormat = 'mqtt_default_format_v1';
  bool _loadingHistory = true;

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
    _sub = (_manager.protocol as MqttProtocol).messageStream.listen(_onMessage);
    _loadHistory();
    _loadTopics();
  }

  /// 页面进入时加载该会话已保存的订阅主题（退出界面后仍可恢复）。
  Future<void> _loadTopics() async {
    final topics = await MqttTopicStore.load(widget.session.id);
    if (!mounted) return;
    setState(() {
      for (final t in topics) {
        if (!_subscribedTopics.contains(t)) _subscribedTopics.add(t);
      }
    });
  }

  /// 收到新消息：插入内存列表、持久化、写入全局历史。
  void _onMessage(MqttMessageRecord m) {
    setState(() => _messages.insert(0, m));
    MqttMessageStore.append(widget.session.id, m);
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
  }

  /// 页面进入时加载该会话的已保存消息（最新在前）。
  Future<void> _loadHistory() async {
    final list = await MqttMessageStore.load(widget.session.id);
    final prefs = await SharedPreferences.getInstance();
    final savedFormat = prefs.getString(_kDefaultFormat);
    if (!mounted) return;
    setState(() {
      _messages.addAll(list);
      _defaultFormat = MqttPayloadFormat.fromName(savedFormat);
      _loadingHistory = false;
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
      if (ok) await _resubscribeAll();
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

  /// 连接成功后，按本地保存的订阅列表自动恢复订阅（退出界面 / 重连不丢失）。
  Future<void> _resubscribeAll() async {
    if (_subscribedTopics.isEmpty) return;
    final proto = _manager.protocol as MqttProtocol;
    for (final t in List.of(_subscribedTopics)) {
      try {
        proto.subscribe(t, qos: _subQos);
      } catch (_) {
        // 个别主题订阅失败不影响其余主题恢复。
      }
    }
  }

  /// 把逗号 / 空白分隔的主题串拆成去空白、去空的主题列表。
  List<String> _splitTopics(String raw) => raw
      .split(RegExp(r'[,\s]+'))
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();

  Future<void> _subscribe() async {
    final raw = _subTopicCtl.text.trim();
    if (raw.isEmpty) return;
    final topics = _splitTopics(raw);
    try {
      (_manager.protocol as MqttProtocol).subscribe(raw, qos: _subQos);
      for (final t in topics) {
        if (!_subscribedTopics.contains(t)) _subscribedTopics.add(t);
      }
      await MqttTopicStore.save(widget.session.id, _subscribedTopics);
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
    MqttTopicStore.save(widget.session.id, _subscribedTopics);
  }

  void _unsubscribeAll() {
    (_manager.protocol as MqttProtocol).unsubscribeAll();
    setState(() {
      _subscribedTopics.clear();
      _subFilter = null;
    });
    MqttTopicStore.clear(widget.session.id);
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
      _messages.where((m) => _topicMatches(topic, m.topic)).length;

  /// 判断消息主题 [topic] 是否匹配订阅 [pattern]（支持 MQTT 通配符 # 与 +）。
  /// - `#` 只能作为最后一段，匹配父层级及所有子层级（如 `test/#` 匹配 `test`、`test/abc`）。
  /// - `+` 匹配单层级任意值（如 `test/+/x` 匹配 `test/abc/x`）。
  /// - 无通配符则为精确相等。
  bool _topicMatches(String pattern, String topic) {
    if (pattern == '#') return true;
    if (pattern == topic) return true;
    final pLevels = pattern.split('/');
    final tLevels = topic.split('/');
    // # 必须出现在末尾：去掉末尾 # 后，前面层级需逐段匹配（+ 通配单层）。
    if (pLevels.last == '#') {
      final head = pLevels.sublist(0, pLevels.length - 1);
      if (head.length > tLevels.length) return false;
      for (var i = 0; i < head.length; i++) {
        final h = head[i];
        if (h != '+' && h != tLevels[i]) return false;
      }
      return true;
    }
    if (pLevels.length != tLevels.length) return false;
    for (var i = 0; i < pLevels.length; i++) {
      final p = pLevels[i];
      if (p == '+') continue;
      if (p != tLevels[i]) return false;
    }
    return true;
  }

  /// 清空当前会话的已保存消息（内存 + 持久化）。
  Future<void> _clearMessages() async {
    setState(() => _messages.clear());
    await MqttMessageStore.clear(widget.session.id);
  }

  /// 切换全局默认展示格式并持久化。
  void _setDefaultFormat(MqttPayloadFormat format) {
    if (_defaultFormat == format) return;
    setState(() => _defaultFormat = format);
    SharedPreferences.getInstance()
        .then((p) => p.setString(_kDefaultFormat, format.name));
  }

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
          const SizedBox(height: 16),
          _buildConnectionForm(),
          const SizedBox(height: 16),
          _buildSubscribeCard(connected),
          const SizedBox(height: 16),
          _buildPublishCard(connected),
          const SizedBox(height: 16),
          _buildMessagesCard(),
        ],
      ),
    );
  }

  Widget _buildConnectionForm() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('连接配置',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: _hostCtl,
                      decoration: const InputDecoration(labelText: 'Broker 地址'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _portCtl,
                      decoration: const InputDecoration(labelText: '端口'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _clientIdCtl,
                decoration: const InputDecoration(labelText: '客户端 ID'),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _userCtl,
                      decoration: const InputDecoration(labelText: '用户名（可选）'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _passCtl,
                      decoration: const InputDecoration(labelText: '密码（可选）'),
                      obscureText: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _keepAliveCtl,
                decoration: const InputDecoration(labelText: '保活间隔（秒）'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 4),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  initiallyExpanded: _useTls || _willTopicCtl.text.isNotEmpty,
                  title: const Text('高级选项',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  children: [
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _cleanSession,
                      onChanged: (v) => setState(() => _cleanSession = v ?? true),
                      title: const Text('干净会话（Clean Session）',
                          style: TextStyle(fontSize: 13)),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _useTls,
                      onChanged: (v) => setState(() => _useTls = v ?? false),
                      title: const Text('使用 TLS/SSL 加密'),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _willTopicCtl,
                            decoration:
                                const InputDecoration(labelText: '遗嘱主题（可选）'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _willPayloadCtl,
                            decoration:
                                const InputDecoration(labelText: '遗嘱内容（可选）'),
                          ),
                        ),
                      ],
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _willRetain,
                      onChanged: (v) => setState(() => _willRetain = v ?? false),
                      title: const Text('遗嘱消息保留（Retain）'),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                    ),
                  ],
                ),
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
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('订阅',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                if (_subscribedTopics.isNotEmpty)
                  TextButton(
                    onPressed: connected ? _unsubscribeAll : null,
                    child: const Text('取消全部'),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _subTopicCtl,
              decoration: const InputDecoration(
                labelText: '主题（支持 # + 通配符，多主题逗号分隔）',
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: connected ? _subscribe : null,
                icon: const Icon(Icons.add),
                label: const Text('订阅'),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('QoS',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                const SizedBox(width: 8),
                DropdownButton<MqttQosLevel>(
                  value: _subQos,
                  items: MqttQosLevel.values
                      .map((q) =>
                          DropdownMenuItem(value: q, child: Text(q.label)))
                      .toList(),
                  onChanged: (v) => setState(() => _subQos = v!),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text('订阅后按主题分组接收消息',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            if (_subscribedTopics.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
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
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('发布',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 14),
            TextFormField(
              controller: _pubTopicCtl,
              decoration: const InputDecoration(labelText: '主题'),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _payloadCtl,
              decoration: const InputDecoration(labelText: '消息内容'),
              maxLines: 3,
              minLines: 2,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      const Text('QoS',
                          style: TextStyle(fontSize: 13, color: Colors.grey)),
                      const SizedBox(width: 8),
                      DropdownButton<MqttQosLevel>(
                        value: _pubQos,
                        items: MqttQosLevel.values
                            .map((q) =>
                                DropdownMenuItem(value: q, child: Text(q.label)))
                            .toList(),
                        onChanged: (v) => setState(() => _pubQos = v!),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _retain = !_retain),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Checkbox(
                          value: _retain,
                          onChanged: (v) => setState(() => _retain = v!),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        const Text('保留(Retain)'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: connected ? _publish : null,
                icon: const Icon(Icons.send),
                label: const Text('发布'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessagesCard() {
    // 按主题分组；消息优先归属到“第一个匹配的订阅主题”（支持 #/+ 通配符），
    // 若不匹配任何订阅则按真实主题分组。实现“按 topic 分类”且通配订阅可用。
    final Map<String, List<MqttMessageRecord>> groups = {};
    for (final m in _messages) {
      final key = _subscribedTopics.firstWhere(
        (s) => _topicMatches(s, m.topic),
        orElse: () => m.topic,
      );
      (groups[key] ??= []).add(m);
    }
    final topics = groups.keys
        .where((t) => _subFilter == null || _topicMatches(_subFilter!, t))
        .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text('接收到的消息 (${_messages.length})',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                _FormatDropdown(
                  value: _defaultFormat,
                  onChanged: (v) {
                    if (v == null) return;
                    _setDefaultFormat(v);
                  },
                ),
                const SizedBox(width: 8),
                if (_messages.isNotEmpty)
                  TextButton(
                    onPressed: _clearMessages,
                    child: const Text('清空'),
                  ),
              ],
            ),
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
            if (_loadingHistory)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (_messages.isEmpty)
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
                children: items
                    .map((m) => _MessageTile(
                          record: m,
                          format: _defaultFormat,
                        ))
                    .toList(),
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
    MqttMessageStore.flushNow();
    super.dispose();
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.record, required this.format});

  final MqttMessageRecord record;
  final MqttPayloadFormat format;

  List<int> get _bytes =>
      record.bytes.isNotEmpty ? record.bytes : utf8.encode(record.payload);

  String get _displayText {
    switch (format) {
      case MqttPayloadFormat.plain:
        return record.payload;
      case MqttPayloadFormat.json:
        try {
          final decoded = jsonDecode(record.payload);
          return const JsonEncoder.withIndent('  ').convert(decoded);
        } catch (_) {
          return record.payload;
        }
      case MqttPayloadFormat.base64:
        return base64Encode(_bytes);
      case MqttPayloadFormat.hex:
        return _bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(' ');
    }
  }

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay.fromDateTime(record.receivedAt).format(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(record.topic,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                        fontSize: 13)),
              ),
              Text(time,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('QoS ${record.qos}',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary)),
              ),
              if (record.retain) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('RETAIN',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.amber)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            _displayText,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 单条消息的格式切换下拉框（MQTTX 风格）。
class _FormatDropdown extends StatelessWidget {
  const _FormatDropdown({required this.value, required this.onChanged});

  final MqttPayloadFormat value;
  final ValueChanged<MqttPayloadFormat?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<MqttPayloadFormat>(
          value: value,
          isDense: true,
          icon: Icon(Icons.expand_more, size: 16, color: scheme.primary),
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.primary),
          items: MqttPayloadFormat.values
              .map((f) => DropdownMenuItem(
                    value: f,
                    child: Text(f.label),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
