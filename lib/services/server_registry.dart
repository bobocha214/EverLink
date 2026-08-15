import 'package:everlink/services/tcp_server.dart';
import 'package:everlink/services/opcua_server.dart';
import 'package:everlink/services/mqtt_broker.dart';
import 'package:everlink/services/mqtt_publisher.dart';

/// 常驻服务实例容器。
///
/// 服务模拟（TCP 服务端 / OPC UA 服务端 / MQTT Broker / MQTT 发布模拟）在
/// 应用生命周期内常驻，页面退出时【不会】停止，仍可后台运行。页面从
/// [instance] 获取同一个服务实例并订阅其事件流；需要停止时由页面「停止」
/// 按钮调用对应服务的 [stop()]。
///
/// 服务层不反向依赖本类，避免循环依赖。
class ServerRegistry {
  ServerRegistry._();

  static final ServerRegistry instance = ServerRegistry._();

  TcpServer? _tcp;
  OpcUaServer? _opcua;
  MqttBroker? _broker;
  MqttPublisher? _publisher;

  TcpServer get tcp {
    _tcp ??= TcpServer();
    return _tcp!;
  }

  OpcUaServer get opcua {
    _opcua ??= OpcUaServer();
    return _opcua!;
  }

  MqttBroker get broker {
    _broker ??= MqttBroker();
    return _broker!;
  }

  MqttPublisher get publisher {
    _publisher ??= MqttPublisher();
    return _publisher!;
  }

  /// 全部停止并释放资源（如应用退出时调用）。
  ///
  /// 日常由各自页面按需停止单个服务，通常无需调用本方法。
  void disposeAll() {
    _tcp?.dispose();
    _tcp = null;
    _opcua?.dispose();
    _opcua = null;
    _broker?.dispose();
    _broker = null;
    _publisher?.dispose();
    _publisher = null;
  }
}
