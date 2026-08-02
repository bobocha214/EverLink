import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/modbus_models.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/device_protocol.dart';

/// 把 UI 的 [ByteOrder] 映射为库内部的 [ModbusEndianness]。
ModbusEndianness _toEndianness(ByteOrder order) {
  switch (order) {
    case ByteOrder.abcd:
      return ModbusEndianness.ABCD;
    case ByteOrder.cdab:
      return ModbusEndianness.CDAB;
    case ByteOrder.badc:
      return ModbusEndianness.BADC;
    case ByteOrder.dcba:
      return ModbusEndianness.DCBA;
  }
}

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
        final detail = await _probeError(config);
        _setState(DeviceConnectionState.error, 'Modbus 连接失败：$detail');
        _client = null;
      }
    } on SocketException catch (e) {
      _setState(DeviceConnectionState.error,
          'Modbus 连接失败：${_humanizeSocketError(e, config)}');
      _client = null;
      rethrow;
    } catch (e) {
      _setState(DeviceConnectionState.error, e.toString());
      _client = null;
      rethrow;
    }
  }

  /// 连接失败后做一次裸 TCP 探活，拿到底层 [SocketException] 的真实原因，
  /// 转换成用户可理解的中文提示。库本身的 connect() 在失败时会吞掉异常
  /// 只返回 false，因此这里单独探测以暴露真正错误。
  Future<String> _probeError(ModbusConnectionConfig c) async {
    try {
      final s = await Socket.connect(c.host, c.port, timeout: c.timeout);
      await s.close();
      return 'TCP 端口可达，但 Modbus 客户端建立连接失败（请检查从站 ID 或设备兼容性）';
    } on SocketException catch (e) {
      return _humanizeSocketError(e, c);
    } catch (e) {
      return e.toString();
    }
  }

  /// 将底层 SocketException 映射为可操作的中文错误描述。
  String _humanizeSocketError(SocketException e, ModbusConnectionConfig c) {
    final msg = e.message.toLowerCase();
    final os = (e.osError?.message ?? '').toLowerCase();
    final target = '${c.host}:${c.port}';
    if (msg.contains('refused') || os.contains('refused')) {
      return '目标 $target 拒绝连接：请确认设备上的 Modbus 服务已启动，且端口 ${c.port} 正在监听';
    }
    if (msg.contains('timed out') || os.contains('timed out') || os.contains('timeout')) {
      return '连接 $target 超时：请检查设备 IP 是否正确、手机与设备是否在同一局域网';
    }
    if (msg.contains('unreachable') || os.contains('unreachable')) {
      return '网络不可达：请检查 Wi-Fi / 移动数据是否正常';
    }
    if (msg.contains('no route') || os.contains('no route')) {
      return '无法路由到主机 $target：请检查网络或网关';
    }
    if (msg.contains('permission') || os.contains('permission')) {
      return '权限被拒绝：$target（Android 需 INTERNET 权限，已在 Manifest 声明）';
    }
    if (msg.contains('failed host lookup') ||
        os.contains('nodename') ||
        os.contains('getaddrinfo')) {
      return '无法解析主机名「${c.host}」：请填写正确的 IP 或域名';
    }
    return '连接 $target 失败：${e.message}${e.osError != null ? ' (${e.osError})' : ''}';
  }

  @override
  Future<void> disconnect() async {
    await _client?.disconnect();
    _client = null;
    _setState(DeviceConnectionState.disconnected);
  }

  /// 取可读写的客户端。
  ///
  /// 注意：以协议自身 [_state] 作为“是否已连接”的权威判断，而不是底层
  /// socket 的 [ModbusClientTcp.isConnected]。原因：底层 socket 可能在
  /// 无握手的情况下被对端静默关闭（库内部把 `_socket` 置空），但我们的
  /// [_state] 仍是 connected，若用 `isConnected` 判断就会出现“状态显示已
  /// 连接、读写却报未连接”的不一致。库的 [ModbusClientTcp.send] 在连接断开
  /// 时会自动重连，因此这里放行后大概率能正常工作；若设备真的不可达，
  /// [send] 会返回 [ModbusResponseCode.connectionFailed]，由 [_check] 统一
  /// 把状态同步为断开并给出清晰提示。
  ModbusClientTcp get _requireClient {
    final client = _client;
    if (_state != DeviceConnectionState.connected || client == null) {
      throw StateError('Modbus 未连接');
    }
    return client;
  }

  Future<void> _check(ModbusResponseCode code, String action) async {
    if (code == ModbusResponseCode.connectionFailed) {
      _setState(DeviceConnectionState.disconnected);
      throw StateError('Modbus 连接已断开，请重新连接');
    }
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
    final values = await readTypedRegisters(
      type: type,
      address: address,
      count: quantity,
      dataType: ModbusDataType.uint16,
      byteOrder: ByteOrder.abcd,
    );
    return values.map((v) => v.toInt()).toList();
  }

  /// 按数据类型读取寄存器。
  ///
  /// [count] 表示“值的个数”（不是寄存器个数）；多寄存器类型（Uint32/Int32/
  /// Float32）每个值占用 [ModbusDataType.registerCount] 个寄存器。[byteOrder]
  /// 控制 32 位 / 浮点值的字节序。返回解析后的工程值列表（16 位为整数，
  /// 浮点为 double）。
  ///
  /// 注意：库把寄存器值以 [double] 形式存储（multiplier/offset 为 double，
  /// 算术表达式会把 int 提升为 double），因此这里统一以 [num] 接收，避免
  /// “double is not a subtype of type int” 的类型转换异常。
  Future<List<num>> readTypedRegisters({
    required ModbusElementType type,
    required int address,
    required int count,
    required ModbusDataType dataType,
    required ByteOrder byteOrder,
  }) async {
    final regCount = dataType.registerCount;
    final total = count * regCount;
    if (count <= 0 || total > 125) {
      throw ArgumentError('寄存器数量超出范围（共 $total 个，上限 125）');
    }
    final client = _requireClient;
    final endianness = _toEndianness(byteOrder);
    final group = ModbusElementsGroup();
    for (var i = 0; i < count; i++) {
      final addr = address + i * regCount;
      switch (dataType) {
        case ModbusDataType.uint16:
          group.add(ModbusUint16Register(
            name: 'r$i',
            address: addr,
            type: type,
            endianness: endianness,
          ));
        case ModbusDataType.int16:
          group.add(ModbusInt16Register(
            name: 'r$i',
            address: addr,
            type: type,
            endianness: endianness,
          ));
        case ModbusDataType.uint32:
          group.add(ModbusUint32Register(
            name: 'r$i',
            address: addr,
            type: type,
            endianness: endianness,
          ));
        case ModbusDataType.int32:
          group.add(ModbusInt32Register(
            name: 'r$i',
            address: addr,
            type: type,
            endianness: endianness,
          ));
        case ModbusDataType.float32:
          group.add(ModbusFloatRegister(
            name: 'r$i',
            address: addr,
            type: type,
            endianness: endianness,
          ));
      }
    }
    final code = await client.send(group.getReadRequest(unitId: _config!.unitId));
    await _check(code, '读寄存器');
    return group.map((e) => e.value as num? ?? 0).toList();
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

  /// 按数据类型把单个“值”写回保持寄存器。
  ///
  /// 16 位类型走单寄存器写（0x06）；32 位 / 浮点类型走多寄存器写（0x10）。
  /// [byteOrder] 与读取时保持一致即可正确还原字节序。
  Future<void> writeTypedRegister({
    required int address,
    required num value,
    required ModbusDataType dataType,
    required ByteOrder byteOrder,
    ModbusElementType type = ModbusElementType.holdingRegister,
  }) async {
    final client = _requireClient;
    final endianness = _toEndianness(byteOrder);
    ModbusElement el;
    switch (dataType) {
      case ModbusDataType.uint16:
        el = ModbusUint16Register(
          name: 'w',
          address: address,
          type: type,
          endianness: endianness,
        );
      case ModbusDataType.int16:
        el = ModbusInt16Register(
          name: 'w',
          address: address,
          type: type,
          endianness: endianness,
        );
      case ModbusDataType.uint32:
        el = ModbusUint32Register(
          name: 'w',
          address: address,
          type: type,
          endianness: endianness,
        );
      case ModbusDataType.int32:
        el = ModbusInt32Register(
          name: 'w',
          address: address,
          type: type,
          endianness: endianness,
        );
      case ModbusDataType.float32:
        el = ModbusFloatRegister(
          name: 'w',
          address: address,
          type: type,
          endianness: endianness,
        );
    }
    final code = await client.send(
      el.getWriteRequest(value, unitId: _config!.unitId, endianness: endianness),
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
