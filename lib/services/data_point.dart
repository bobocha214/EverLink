import 'dart:async';

/// 标准化数据点事件：各协议采集层产出，记录仪(模块五)/可视化(模块九)消费。
class DataPoint {
  final String source; // 'modbus' / 'mqtt' / 'opcua'
  final String tag; // 点位标识（地址 / 主题 / 节点）
  final num value; // 数值型点位值
  final DateTime time;
  final String? unit;

  DataPoint({
    required this.source,
    required this.tag,
    required this.value,
    required this.time,
    this.unit,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'source': source,
        'tag': tag,
        'value': value,
        'time': time.toIso8601String(),
        'unit': unit,
      };
}

/// 全局数据点广播流，解耦采集端（Modbus/MQTT/OPC UA）与消费端（记录仪/曲线）。
class DataPointBus {
  DataPointBus._();

  static final DataPointBus instance = DataPointBus._();

  final StreamController<DataPoint> _controller =
      StreamController<DataPoint>.broadcast();

  Stream<DataPoint> get stream => _controller.stream;

  void emit(DataPoint p) => _controller.add(p);

  void dispose() => _controller.close();
}
