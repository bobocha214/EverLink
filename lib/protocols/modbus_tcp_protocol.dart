import 'dart:async';
import 'dart:typed_data';

import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/device_protocol.dart';

/// Modbus TCP 协议实现。
///
/// 基于 [modbus_client] + [modbus_client_tcp] 封装，对外提供面向调试工具
/// 的简洁读写接口。支持线圈、离散输入、保持寄存器、输入寄存器的读取，
/// 以及单点/多点线圈与保持寄存器的写入。
class ModbusTcpProtocol extends DeviceProtocol {
  ModbusTcpProtocol()
      : super(
          type: ProtocolType.modbusTcp,
          name: 'Modbus TCP',
          description: '通过 TCP 读写 Modbus 设备的线圈与寄存器（默认端口 502）。',
        );

  ModbusClientTcp? _client;
  ModbusConnectionConfig? _config;

  final StreamController<DeviceConnectionState> _stateController =
      StreamController<DeviceConnectionState>.broadcast();

  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  @override
  String? lastError;

  @override
  DeviceConnectionState get connectionState => _state;

  @override
  Stream<DeviceConnectionState> get connectionStateStream => _stateController.stream;

  @override
  bool get supportsRead => true;

  @override
  bool get supportsWrite => true;

  void _setState(DeviceConnectionState state, [String? error]) {
    _state = state;
    lastError = error;
    _stateController.add(state);
  }

  @override
  Future<void> connect(ConnectionConfig config) async {
    if (config is! ModbusConnectionConfig) {
      throw ArgumentError('ModbusTcpProtocol 需要 ModbusConnectionConfig');
    }
    _config = config;
    _setState(DeviceConnectionState.connecting);
    try {
      _client = ModbusClientTcp(
        config.host,
        serverPort: config.port,
        unitId: config.unitId,
        responseTimeout: config.timeout,
        connectionTimeout: config.timeout,
      );
      final ok = await _client!.connect();
      if (ok) {
        _setState(DeviceConnectionState.connected);
      } else {
        _setState(DeviceConnectionState.error, '无法连接到 ${config.host}:${config.port}');
        _client = null;
      }
    } catch (e) {
      _setState(DeviceConnectionState.error, e.toString());
      _client = null;
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    await _client?.disconnect();
    _client = null;
    _setState(DeviceConnectionState.disconnected);
  }

  ModbusClientTcp get _requireClient {
    final client = _client;
    if (client == null || !client.isConnected) {
      throw StateError('Modbus 未连接');
    }
    return client;
  }

  Future<void> _check(ModbusResponseCode code, String action) async {
    if (code != ModbusResponseCode.requestSucceed) {
      throw ModbusException(context: action, msg: '操作失败：${code.name}');
    }
  }

  /// 读取线圈 / 离散输入，返回布尔列表。
  Future<List<bool>> readBits(
    ModbusElementType type,
    int address,
    int quantity,
  ) async {
    if (quantity <= 0 || quantity > 2000) {
      throw ArgumentError('线圈/离散输入数量需在 1~2000 之间');
    }
    final client = _requireClient;
    final group = ModbusElementsGroup();
    for (var i = 0; i < quantity; i++) {
      group.add(
        type == ModbusElementType.coil
            ? ModbusCoil(name: 'c$i', address: address + i)
            : ModbusDiscreteInput(name: 'd$i', address: address + i),
      );
    }
    final code = await client.send(group.getReadRequest(unitId: _config!.unitId));
    await _check(code, '读${type == ModbusElementType.coil ? "线圈" : "离散输入"}');
    return group.map((e) => e.value as bool? ?? false).toList();
  }

  /// 读取保持寄存器 / 输入寄存器，返回原始 16 位无符号整数列表。
  Future<List<int>> readRegisters(
    ModbusElementType type,
    int address,
    int quantity,
  ) async {
    if (quantity <= 0 || quantity > 125) {
      throw ArgumentError('寄存器数量需在 1~125 之间');
    }
    final client = _requireClient;
    final group = ModbusElementsGroup();
    for (var i = 0; i < quantity; i++) {
      group.add(
        ModbusUint16Register(name: 'r$i', address: address + i, type: type),
      );
    }
    final code = await client.send(group.getReadRequest(unitId: _config!.unitId));
    await _check(code, '读寄存器');
    return group.map((e) => (e.value as int?) ?? 0).toList();
  }

  /// 写单个线圈。
  Future<void> writeSingleCoil(int address, bool value) async {
    final client = _requireClient;
    final coil = ModbusCoil(name: 'coil', address: address);
    final code = await client.send(
      coil.getWriteRequest(value, unitId: _config!.unitId),
    );
    await _check(code, '写线圈');
  }

  /// 写单个保持寄存器（16 位）。
  Future<void> writeSingleRegister(int address, int value) async {
    final client = _requireClient;
    final reg = ModbusUint16Register(
      name: 'reg',
      address: address,
      type: ModbusElementType.holdingRegister,
    );
    final code = await client.send(
      reg.getWriteRequest(value, unitId: _config!.unitId),
    );
    await _check(code, '写寄存器');
  }

  /// 写多个保持寄存器（连续的 16 位值）。
  Future<void> writeMultipleRegisters(int address, List<int> values) async {
    if (values.isEmpty || values.length > 123) {
      throw ArgumentError('寄存器值数量需在 1~123 之间');
    }
    final client = _requireClient;
    final reg = ModbusUint16Register(
      name: 'reg',
      address: address,
      type: ModbusElementType.holdingRegister,
    );
    final bytes = Uint8List(values.length * 2);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < values.length; i++) {
      bd.setUint16(i * 2, values[i] & 0xFFFF);
    }
    final code = await client.send(
      reg.getMultipleWriteRequest(bytes, unitId: _config!.unitId),
    );
    await _check(code, '写多个寄存器');
  }

  /// 写多个线圈。采用逐点写入以保证兼容性（modbus_client 对位写多点的
  /// PDU 长度处理存在偏差，逐点写入更稳妥）。
  Future<void> writeMultipleCoils(int address, List<bool> values) async {
    for (var i = 0; i < values.length; i++) {
      await writeSingleCoil(address + i, values[i]);
    }
  }

  @override
  void dispose() {
    _client?.disconnect();
    _client = null;
    _stateController.close();
  }
}
