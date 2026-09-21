import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:everlink/models/device_session.dart';
import 'package:everlink/models/mqtt_models.dart';
import 'package:everlink/protocols/mqtt_protocol.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/services/mqtt_messages_cache.dart';
import 'package:everlink/services/mqtt_topic_store.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/ui/widgets/mqtt_message_tile.dart';

/// MQTT 全屏消息页。
///
/// 从 MQTT 主调试页点“全屏查看”进入，独立占满一屏浏览订阅收到的消息：
/// - 消息由共享的 [MqttMessagesCache] 驱动，与主调试页数据完全一致、实时同步；
/// - 按主题分组（支持 # / + 通配订阅归组），顶部可搜索主题筛选；
/// - 支持 payload 格式切换（Plaintext / JSON / Base64 / Hex）、清空、单条复制。
///
/// 注意：本页只做“看”，不负责持久化写入；落盘由主调试页经 cache 完成，
/// 避免两个页面同时监听消息流导致重复落盘。
class MqttMessagesPage extends StatefulWidget {
  const MqttMessagesPage({super.key, required this.session});

  final DeviceSession session;

  @override
  State<MqttMessagesPage> createState() => _MqttMessagesPageState();
}

class _MqttMessagesPageState extends State<MqttMessagesPage> {
  late final ConnectionManager _manager;
  late final MqttMessagesCache _cache;

  final List<String> _subscribedTopics = [];
  String? _subFilter;
  MqttPayloadFormat _format = MqttPayloadFormat.plain;
  bool _loading = true;

  /// 主题搜索关键字（顶部搜索框）。
  final TextEditingController _searchCtl = TextEditingController();
  String _search = '';

  static const String _kDefaultFormat = 'mqtt_default_format_v1';

  @override
  void initState() {
    super.initState();
    _manager = SessionManager.instance.ensureManager(widget.session);
    _cache = MqttMessagesCache.of(widget.session.id);
    _cache.addListener(_onCacheChanged);
    // 幂等绑定消息流：确保有新消息时 cache 持续更新（即使主调试页已不在栈顶）。
    // bind 内部只产生一个订阅，多页面重复调用不会重复落盘。
    _cache.bind((_manager.protocol as MqttProtocol).messageStream);
    _loadTopics();
    _loadFormat();
    _cache.ensureLoaded().then((_) {
      if (mounted) setState(() => _loading = false);
    });
    _searchCtl.addListener(
        () => setState(() => _search = _searchCtl.text.trim().toLowerCase()));
  }

  /// 页面进入时恢复已订阅主题（用于按主题分组）。
  Future<void> _loadTopics() async {
    final topics = await MqttTopicStore.load(widget.session.id);
    if (!mounted) return;
    setState(() => _subscribedTopics.addAll(topics));
  }

  Future<void> _loadFormat() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() =>
        _format = MqttPayloadFormat.fromName(prefs.getString(_kDefaultFormat)));
  }

  void _onCacheChanged() {
    if (mounted) setState(() {});
  }

  void _setFormat(MqttPayloadFormat f) {
    if (_format == f) return;
    setState(() => _format = f);
    SharedPreferences.getInstance()
        .then((p) => p.setString(_kDefaultFormat, f.name));
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空消息'),
        content: const Text('将清除当前会话已接收的全部消息（内存与本地记录），确定？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) await _cache.clear();
  }

  List<String> _groupedTopics() {
    final Map<String, List<MqttMessageRecord>> groups = {};
    for (final m in _cache.messages) {
      final key = _subscribedTopics.firstWhere(
        (s) => mqttTopicMatches(s, m.topic),
        orElse: () => m.topic,
      );
      (groups[key] ??= []).add(m);
    }
    return groups.keys.where((t) {
      if (_subFilter != null && !mqttTopicMatches(_subFilter!, t)) return false;
      if (_search.isNotEmpty && !t.toLowerCase().contains(_search)) return false;
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _manager.state == DeviceConnectionState.connected;
    final topics = _groupedTopics();
    final total = _cache.messages.length;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('消息'),
            Text(widget.session.name,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          MqttFormatDropdown(
            value: _format,
            onChanged: (v) {
              if (v != null) _setFormat(v);
            },
          ),
          const SizedBox(width: 8),
          if (total > 0)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空消息',
              onPressed: _clear,
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchCtl,
              decoration: InputDecoration(
                hintText: '搜索主题…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          if (_subscribedTopics.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
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
                    onDeleted: connected ? () => _unsubscribeQuick(t) : null,
                  );
                }).toList(),
              ),
            ),
          if (_subFilter != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Chip(
                label: Text('筛选：$_subFilter'),
                deleteIcon: const Icon(Icons.close, size: 16),
                onDeleted: () => setState(() => _subFilter = null),
              ),
            ),
          Expanded(
            child: _buildContent(total, topics),
          ),
        ],
      ),
    );
  }

  /// 根据加载状态 / 数量 / 筛选结果，构建消息区主体。
  Widget _buildContent(int total, List<String> topics) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (total == 0) {
      return const Center(
        child: Text('订阅主题后，收到的消息会显示在这里',
            style: TextStyle(color: Colors.grey)),
      );
    }
    if (topics.isEmpty) {
      return const Center(
        child: Text('当前筛选条件下没有消息',
            style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: topics.map((t) {
        final items = _cache.messages
            .where((m) => _topicKeyOf(m) == t)
            .toList();
        return ExpansionTile(
          tilePadding: EdgeInsets.zero,
          initiallyExpanded: true,
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
              .map((m) => MqttMessageTile(
                    record: m,
                    format: _format,
                  ))
              .toList(),
        );
      }).toList(),
    );
  }

  String _topicKeyOf(MqttMessageRecord m) => _subscribedTopics.firstWhere(
        (s) => mqttTopicMatches(s, m.topic),
        orElse: () => m.topic,
      );

  int _countFor(String topic) =>
      _cache.messages.where((m) => mqttTopicMatches(topic, m.topic)).length;

  void _unsubscribeQuick(String topic) {
    (_manager.protocol as MqttProtocol).unsubscribe(topic);
    setState(() {
      _subscribedTopics.remove(topic);
      if (_subFilter == topic) _subFilter = null;
    });
    MqttTopicStore.save(widget.session.id, _subscribedTopics);
  }

  @override
  void dispose() {
    _cache.removeListener(_onCacheChanged);
    _searchCtl.dispose();
    super.dispose();
  }
}
