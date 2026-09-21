import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/device_session.dart';
import 'package:everlink/models/mqtt_models.dart';
import 'package:everlink/protocols/mqtt_protocol.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/mqtt_message_store.dart';
import 'package:everlink/services/mqtt_messages_cache.dart';
import 'package:everlink/services/mqtt_topic_store.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/ui/widgets/connection_panel.dart';
import 'package:everlink/ui/widgets/mqtt_message_tile.dart';
import 'package:everlink/ui/mqtt_messages_page.dart';
import 'package:everlink/utils/app_routes.dart';

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
  late final MqttMessagesCache _cache;
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
    _cache = MqttMessagesCache.of(widget.session.id);
    _cache.addListener(_onCacheChanged);
    // 幂等绑定消息流：负责“收消息 → 写内存 → 持久化”。本页只额外写全局历史。
    _cache.bind((_manager.protocol as MqttProtocol).messageStream);
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

  /// 收到新消息：持久化与内存更新已由 [MqttMessagesCache]（经 bind）统一处理，
  /// 本页只负责把“接收”事件写入全局历史。
  void _onMessage(MqttMessageRecord m) {
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

  /// 页面进入时从共享缓存载入该会话的已保存消息（最新在前）。
  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final savedFormat = prefs.getString(_kDefaultFormat);
    await _cache.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _defaultFormat = MqttPayloadFormat.fromName(savedFormat);
      _loadingHistory = false;
    });
  }

  void _onCacheChanged() {
    if (mounted) setState(() {});
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
      _cache.messages.where((m) => mqttTopicMatches(topic, m.topic)).length;

  /// 清空当前会话的已保存消息（内存 + 持久化）。
  Future<void> _clearMessages() async {
    await _cache.clear();
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
    // 主调试页底部只放一个精简摘要卡：显示总数、最新几条预览，并提供
    // “全屏查看”入口，跳到独立消息页浏览（避免长页面滚到底才能看消息）。
    final total = _cache.messages.length;
    final preview = _cache.messages.take(3).toList();
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
                  child: Text('接收到的消息 ($total)',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.open_in_full, size: 16),
                  label: const Text('全屏查看'),
                  onPressed: () => AppRoutes.push(
                    context,
                    MqttMessagesPage(session: widget.session),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(bottom: 8),
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
            else if (total == 0)
              const Text('订阅主题后，收到的消息会按主题分组显示；点“全屏查看”可独立浏览。',
                  style: TextStyle(color: Colors.grey))
            else ...[
              ...preview
                  .map((m) => MqttMessageTile(record: m, format: _defaultFormat)),
              if (total > 3)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => AppRoutes.push(
                      context,
                      MqttMessagesPage(session: widget.session),
                    ),
                    child: Text('查看全部 $total 条'),
                  ),
                ),
              if (total > 0)
                TextButton(
                  onPressed: _clearMessages,
                  child: const Text('清空'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _cache.removeListener(_onCacheChanged);
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

