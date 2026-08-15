import 'dart:async';
import 'dart:math';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'package:everlink/models/mqtt_models.dart';

/// MQTT 发布模拟器：连接到一个外部 Broker，按配置的主题模板、数量、间隔
/// 循环发布模拟数据（设备上行数据模拟）。支持 QoS、用户名/密码（可选）。
class MqttPublisher {
  MqttPublisher();

  final _events = StreamController<MqttPublisherEvent>.broadcast();
  Stream<MqttPublisherEvent> get events => _events.stream;

  MqttServerClient? _client;
  Timer? _timer;
  bool _running = false;

  // 保存最近一次 start 的配置，供页面重新进入时恢复输入框。
  String? _host;
  int? _port;
  String? _topicTemplate;
  int? _count;
  int? _intervalMs;
  MqttQosLevel? _qos;
  String? _username;
  String? _clientId;

  bool get running => _running;

  String? get host => _host;
  int? get port => _port;
  String? get topicTemplate => _topicTemplate;
  int? get count => _count;
  int? get intervalMs => _intervalMs;
  MqttQosLevel? get qos => _qos;
  String? get username => _username;
  String? get clientId => _clientId;

  /// 配置并启动发布循环。
  ///
  /// [host] 含协议（如 tcp://10.0.0.1 或 ssl://...），[port] 端口，
  /// [topicTemplate] 主题模板，支持 `{i}` 占位（被替换为序号），
  /// [count] 生成的主题数量，[intervalMs] 发布间隔，
  /// [qos] 服务质量，[username]/[password] 可选认证。
  Future<void> start({
    required String host,
    required int port,
    required String topicTemplate,
    required int count,
    required int intervalMs,
    required MqttQosLevel qos,
    String? username,
    String? password,
    String? clientId,
  }) async {
    if (_running) return;
    final id = clientId?.isNotEmpty == true
        ? clientId!
        : 'everlink-pub-${DateTime.now().millisecondsSinceEpoch % 100000}';
    final client = MqttServerClient.withPort(host, id, port)
      ..logging(on: false)
      ..keepAlivePeriod = 60
      ..onDisconnected = () {
        _events.add(MqttPublisherStateEvent(false));
      }
      ..onConnected = () {
        _events.add(MqttPublisherStateEvent(true));
      };
    client.onSubscribed = (_) {};

    final conn = MqttConnectMessage()
        .withClientIdentifier(id)
        .withWillQos(MqttQos.atMostOnce);
    if (username?.isNotEmpty == true) {
      conn.authenticateAs(username!, password ?? '');
    }
    client.connectionMessage = conn;

    try {
      await client.connect();
    } on Object catch (e) {
      _events.add(MqttPublisherErrorEvent('连接失败：$e'));
      client.disconnect();
      return;
    }
    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      _events.add(MqttPublisherErrorEvent('连接未建立'));
      client.disconnect();
      return;
    }

    _client = client;
    _running = true;
    _host = host;
    _port = port;
    _topicTemplate = topicTemplate;
    _count = count;
    _intervalMs = intervalMs;
    _qos = qos;
    _username = username;
    _clientId = clientId;

    final rng = Random();
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      for (var i = 0; i < count; i++) {
        final topic = topicTemplate.replaceAll('{i}', (i + 1).toString());
        final value = _simulatedValue(rng);
        final builder = MqttClientPayloadBuilder();
        builder.addString(value);
        try {
          client.publishMessage(topic, qos.toMqttQos(), builder.payload!);
          _events.add(MqttPublisherDataEvent(topic, value));
        } catch (e) {
          _events.add(MqttPublisherErrorEvent('发布 $topic 失败：$e'));
        }
      }
    });
    _events.add(MqttPublisherStateEvent(true));
  }

  String _simulatedValue(Random rng) {
    switch (rng.nextInt(4)) {
      case 0:
        return (20 + rng.nextDouble() * 10).toStringAsFixed(2); // 温度
      case 1:
        return (rng.nextInt(100)).toString(); // 计数
      case 2:
        return (rng.nextDouble() * 100).toStringAsFixed(1); // 湿度/压力
      default:
        return rng.nextBool() ? 'ON' : 'OFF';
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    try {
      _client?.disconnect();
    } catch (_) {
      // 忽略。
    }
    _client = null;
    _events.add(MqttPublisherStateEvent(false));
  }

  void dispose() {
    stop();
    _events.close();
  }
}

sealed class MqttPublisherEvent {}

class MqttPublisherStateEvent extends MqttPublisherEvent {
  MqttPublisherStateEvent(this.connected);
  final bool connected;
}

class MqttPublisherDataEvent extends MqttPublisherEvent {
  MqttPublisherDataEvent(this.topic, this.value);
  final String topic;
  final String value;
}

class MqttPublisherErrorEvent extends MqttPublisherEvent {
  MqttPublisherErrorEvent(this.message);
  final String message;
}
