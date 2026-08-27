import 'dart:async';
import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/mqtt_models.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/device_protocol.dart';

/// MQTT 协议实现。
///
/// 基于 [mqtt_client] 封装。支持连接 Broker（含用户名密码 / TLS）、订阅主题
/// 接收消息、向主题发布消息。订阅到的消息通过 [messageStream] 暴露给 UI。
class MqttProtocol extends DeviceProtocol {
  MqttProtocol()
      : super(
          type: ProtocolType.mqtt,
          name: 'MQTT',
          description: '连接 Broker，订阅主题接收消息并向主题发布消息。',
        );

  MqttServerClient? _client;

  final StreamController<DeviceConnectionState> _stateController =
      StreamController<DeviceConnectionState>.broadcast();
  final StreamController<MqttMessageRecord> _messageController =
      StreamController<MqttMessageRecord>.broadcast();

  /// 当前已订阅的主题集合。
  final Set<String> _subscribedTopics = {};

  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  @override
  String? lastError;

  /// 接收到的消息流。
  Stream<MqttMessageRecord> get messageStream => _messageController.stream;

  /// 当前已订阅的主题列表。
  List<String> get subscribedTopics => _subscribedTopics.toList();

  @override
  DeviceConnectionState get connectionState => _state;

  @override
  Stream<DeviceConnectionState> get connectionStateStream => _stateController.stream;

  @override
  bool get supportsWrite => true;

  @override
  bool get supportsSubscribe => true;

  void _setState(DeviceConnectionState state, [String? error]) {
    _state = state;
    lastError = error;
    _stateController.add(state);
  }

  @override
  Future<void> connect(ConnectionConfig config) async {
    if (config is! MqttConnectionConfig) {
      throw ArgumentError('MqttProtocol 需要 MqttConnectionConfig');
    }
    _setState(DeviceConnectionState.connecting);
    try {
      _client = MqttServerClient.withPort(
        config.host,
        config.clientId,
        config.port,
      );
      final client = _client!;
      client.secure = config.useTls;
      client.keepAlivePeriod = config.keepAlive;
      client.logging(on: false);
      client.autoReconnect = true;
      client.onConnected = () => _setState(DeviceConnectionState.connected);
      client.onDisconnected = () {
        if (_state != DeviceConnectionState.disconnected) {
          _setState(DeviceConnectionState.disconnected);
        }
      };
      client.onSubscribed = (topic) {
        _subscribedTopics.add(topic);
      };
      client.onSubscribeFail = (topic) {
        _subscribedTopics.remove(topic);
      };
      var message = MqttConnectMessage()
          .withClientIdentifier(config.clientId)
          .authenticateAs(config.username, config.password);
      // startClean 与 keepAlivePeriod 控制会话行为；cleanSession=false 时
      // 不调用 startClean，断开后 Broker 保留订阅与离线消息。
      if (config.cleanSession) message = message.startClean();
      if (config.willTopic != null && config.willTopic!.isNotEmpty) {
        message = message
            .withWillTopic(config.willTopic!)
            .withWillMessage(config.willPayload ?? '')
            .withWillQos(MqttQos.atLeastOnce);
        if (config.willRetain) message = message.withWillRetain();
      }
      client.connectionMessage = message;

      await client.connect();
      // connect() 在成功时不会抛异常；通过连接状态再次确认。
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        _setState(DeviceConnectionState.error, 'MQTT 连接未成功建立');
        client.disconnect();
        return;
      }
      client.updates!.listen(_onMessages);
    } catch (e) {
      _setState(DeviceConnectionState.error, e.toString());
      _client?.disconnect();
      _client = null;
      rethrow;
    }
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final event in events) {
      final msg = event.payload;
      if (msg is! MqttPublishMessage) continue;
      final raw = msg.payload.message;
      final bytes = raw.toList();
      String payload;
      try {
        payload = utf8.decode(bytes);
      } catch (_) {
        payload = MqttPublishPayload.bytesToStringAsString(raw);
      }
      _messageController.add(
        MqttMessageRecord(
          topic: event.topic,
          payload: payload,
          bytes: bytes,
          receivedAt: DateTime.now(),
          qos: msg.header?.qos.index ?? 0,
          retain: msg.header?.retain ?? false,
        ),
      );
    }
  }

  /// 订阅主题（支持一次传入多个，用逗号分隔；忽略空白项）。
  void subscribe(String topics, {MqttQosLevel qos = MqttQosLevel.atMostOnce}) {
    if (_client == null || _client!.connectionStatus?.state != MqttConnectionState.connected) {
      throw StateError('MQTT 未连接');
    }
    for (final t in _splitTopics(topics)) {
      _client!.subscribe(t, qos.toMqttQos());
    }
  }

  /// 取消订阅主题（同样支持逗号分隔的多个主题）。
  void unsubscribe(String topics) {
    for (final t in _splitTopics(topics)) {
      _client?.unsubscribe(t);
      _subscribedTopics.remove(t);
    }
  }

  /// 取消全部已订阅主题。
  void unsubscribeAll() {
    for (final t in List.of(_subscribedTopics)) {
      _client?.unsubscribe(t);
    }
    _subscribedTopics.clear();
  }

  /// 把逗号 / 空白分隔的主题串拆成去空白、去空的主题列表。
  static List<String> _splitTopics(String raw) => raw
      .split(RegExp(r'[,\s]+'))
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();

  /// 发布消息到主题。
  void publish(
    String topic,
    String payload, {
    MqttQosLevel qos = MqttQosLevel.atMostOnce,
    bool retain = false,
  }) {
    if (_client == null || _client!.connectionStatus?.state != MqttConnectionState.connected) {
      throw StateError('MQTT 未连接');
    }
    final builder = MqttClientPayloadBuilder();
    builder.addString(payload);
    _client!.publishMessage(topic, qos.toMqttQos(), builder.payload!,
        retain: retain);
  }

  @override
  Future<void> disconnect() async {
    _client?.disconnect();
    _client = null;
    _subscribedTopics.clear();
    _setState(DeviceConnectionState.disconnected);
  }

  @override
  void dispose() {
    _client?.disconnect();
    _client = null;
    _stateController.close();
    _messageController.close();
  }
}
