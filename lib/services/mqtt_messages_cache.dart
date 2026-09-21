import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:everlink/models/mqtt_models.dart';
import 'package:everlink/services/mqtt_message_store.dart';

/// 每个 MQTT 会话的“接收到的消息”内存缓存（单例，按 [sessionId] 维度）。
///
/// 它是 MQTT 主调试页与“全屏消息”页共享的**唯一数据源**：
/// - 内存列表即 UI 直接读取的消息；
/// - 收到消息时统一写入 [MqttMessageStore] 持久化（约 400ms 批量落盘）；
/// - 通过 [ChangeNotifier] 通知所有监听页面刷新，保证多页数据一致；
/// - [bind] 幂等绑定消息流，无论多少页面调用都只产生一个订阅，杜绝重复落盘。
///
/// 由此，主调试页只负责“把消息喂进来 + 写全局历史”，全屏消息页只负责“看”，
/// 两页看到的消息永远一致，清空操作也全局生效。
class MqttMessagesCache extends ChangeNotifier {
  MqttMessagesCache._(this.sessionId);

  static final Map<String, MqttMessagesCache> _instances = {};

  /// 取（或创建）指定会话的消息缓存。
  static MqttMessagesCache of(String sessionId) =>
      _instances.putIfAbsent(sessionId, () => MqttMessagesCache._(sessionId));

  final String sessionId;

  /// 收到的消息（最新在前）。
  final List<MqttMessageRecord> messages = [];

  bool _loaded = false;

  /// 是否已从持久化载入历史（避免重复 load / 重复触发重建）。
  bool get loaded => _loaded;

  StreamSubscription<MqttMessageRecord>? _streamSub;

  /// 绑定消息流（幂等）：只会产生一个订阅。
  ///
  /// 该订阅负责“收消息 → 写内存 → 持久化 → 通知监听者”的完整链路。
  /// 多个页面可各自调用，但只生效一次。
  void bind(Stream<MqttMessageRecord> stream) {
    _streamSub ??= stream.listen((m) {
      messages.insert(0, m);
      if (messages.length > MqttMessageStore.max) {
        messages.length = MqttMessageStore.max;
      }
      MqttMessageStore.append(sessionId, m);
      notifyListeners();
    });
  }

  /// 从持久化载入历史消息（仅首次调用有效）。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final list = await MqttMessageStore.load(sessionId);
    if (list.isNotEmpty) {
      messages.addAll(list);
      notifyListeners();
    }
    _loaded = true;
  }

  /// 清空本会话全部消息（内存 + 持久化），并通知所有监听页面。
  Future<void> clear() async {
    messages.clear();
    await MqttMessageStore.clear(sessionId);
    notifyListeners();
  }
}
