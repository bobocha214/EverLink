import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Modbus TCP 从站（Slave）模拟服务事件，供 UI 订阅以更新界面。
sealed class ModbusSlaveEvent {
  const ModbusSlaveEvent();
}

/// 监听状态变化。
class ModbusSlaveStateEvent extends ModbusSlaveEvent {
  const ModbusSlaveStateEvent(this.listening, [this.port]);
  final bool listening;
  final int? port;
}

/// 客户端上下线。
class ModbusSlaveClientEvent extends ModbusSlaveEvent {
  const ModbusSlaveClientEvent(this.clientId, this.address, this.connected);
  final String clientId;
  final String address;
  final bool connected;
}

/// 收发报文：[direction]=true 表示从站回送（TX），false 表示收到请求（RX）。
class ModbusSlaveDataEvent extends ModbusSlaveEvent {
  const ModbusSlaveDataEvent(this.direction, this.bytes, [this.clientId]);
  final bool direction;
  final Uint8List bytes;
  final String? clientId;
}

/// 寄存器 / 线圈数值被（客户端写入或本地编辑）改变，UI 据此刷新显示。
class ModbusSlaveRegistersEvent extends ModbusSlaveEvent {
  const ModbusSlaveRegistersEvent();
}

class ModbusSlaveErrorEvent extends ModbusSlaveEvent {
  const ModbusSlaveErrorEvent(this.message);
  final String message;
}

/// 轻量 Modbus TCP 从站模拟。
///
/// 在指定端口监听 TCP，按 MBAP + PDU 解析 Modbus TCP 报文，维护四类内存数据区：
/// 线圈（Coils / 0x 区）、离散输入（Discrete Inputs / 1x 区）、
/// 输入寄存器（Input Registers / 3x 区）、保持寄存器（Holding Registers / 4x 区）。
/// 支持常用功能码：0x01/0x02 读、0x03/0x04 读、0x05/0x06 写单点、0x0F/0x10 写多点。
///
/// 通过事件流上报状态、客户端上下线、收发报文与数值变化，页面据此刷新。
class ModbusTcpSlaveServer {
  ModbusTcpSlaveServer();

  final _events = StreamController<ModbusSlaveEvent>.broadcast();
  Stream<ModbusSlaveEvent> get events => _events.stream;

  ServerSocket? _server;
  int _slaveId = 1;

  // —— 四类数据区（索引 0 对应地址 0，即 Modbus 地址 1）——
  List<bool> coils = List.filled(200, false);
  List<bool> discreteInputs = List.filled(200, false);
  List<int> inputRegisters = List.filled(100, 0); // 16 位无符号
  List<int> holdingRegisters = List.filled(100, 0); // 16 位无符号

  final _clients = <String, Socket>{};
  var _seq = 0;

  /// 当前监听端口（未监听为 null）。
  int? get port => _server?.port;

  bool get isListening => _server != null;

  /// 当前已连接客户端列表（id + 地址），供 UI 展示与状态恢复。
  List<Map<String, String>> get clientList => _clients.entries
      .map((e) => {
            'id': e.key,
            'address': '${e.value.remoteAddress.address}:${e.value.remotePort}',
          })
      .toList();

  int get slaveId => _slaveId;

  /// 调整从站 ID 与各数据区容量，保留既有重叠部分的值。
  ///
  /// 服务运行中调用会即时生效并重置越界数据；建议启动前配置。
  void configure({
    int? slaveId,
    int? coilCount,
    int? discreteCount,
    int? inputCount,
    int? holdingCount,
  }) {
    if (slaveId != null && slaveId >= 0 && slaveId <= 247) _slaveId = slaveId;
    if (coilCount != null) coils = _resizeBool(coils, coilCount);
    if (discreteCount != null) discreteInputs = _resizeBool(discreteInputs, discreteCount);
    if (inputCount != null) inputRegisters = _resizeInt(inputRegisters, inputCount);
    if (holdingCount != null) holdingRegisters = _resizeInt(holdingRegisters, holdingCount);
  }

  static List<bool> _resizeBool(List<bool> old, int n) {
    final out = List.filled(n.clamp(0, 65535), false);
    for (var i = 0; i < old.length && i < out.length; i++) {
      out[i] = old[i];
    }
    return out;
  }

  static List<int> _resizeInt(List<int> old, int n) {
    final out = List.filled(n.clamp(0, 65535), 0);
    for (var i = 0; i < old.length && i < out.length; i++) {
      out[i] = old[i] & 0xFFFF;
    }
    return out;
  }

  Future<void> start(int port, {String? bindAddress}) async {
    if (_server != null) return;
    try {
      final addr = (bindAddress != null &&
              bindAddress.isNotEmpty &&
              bindAddress != '0.0.0.0')
          ? InternetAddress(bindAddress)
          : InternetAddress.anyIPv4;
      _server = await ServerSocket.bind(addr, port);
    } on SocketException catch (e) {
      _events.add(ModbusSlaveErrorEvent('监听失败：$e'));
      return;
    }
    _events.add(ModbusSlaveStateEvent(true, port));
    _server!.listen(_onConnection,
        onError: (e) => _events.add(ModbusSlaveErrorEvent('监听异常：$e')));
  }

  void _onConnection(Socket socket) {
    final id = 'm${++_seq}';
    _clients[id] = socket;
    final address = '${socket.remoteAddress.address}:${socket.remotePort}';
    _events.add(ModbusSlaveClientEvent(id, address, true));

    final buf = <int>[];
    socket.listen(
      (data) {
        buf.addAll(data);
        // 按 MBAP 长度字段逐帧解析（长度 = 单元 ID + PDU）。
        while (buf.length >= 6) {
          final len = (buf[4] << 8) | buf[5];
          final total = 6 + len;
          if (buf.length < total) break;
          final frame = buf.sublist(0, total);
          buf.removeRange(0, total);
          _processFrame(id, socket, frame);
        }
      },
      onError: (e) {
        _events.add(ModbusSlaveErrorEvent('客户端 $id 异常：$e'));
        _removeClient(id);
      },
      onDone: () => _removeClient(id),
      cancelOnError: false,
    );
  }

  void _processFrame(String id, Socket socket, List<int> frame) {
    if (frame.length < 8) return;
    final unitId = frame[6];
    final pdu = frame.sublist(7);
    _events.add(
        ModbusSlaveDataEvent(false, Uint8List.fromList(frame), id));
    final respPdu = _handlePdu(pdu);
    final resp = <int>[
      frame[0], frame[1], // 事务 ID 回显
      0, 0, // 协议 ID（Modbus TCP 固定 0）
      ((respPdu.length + 1) >> 8) & 0xFF,
      (respPdu.length + 1) & 0xFF,
      unitId,
      ...respPdu,
    ];
    try {
      socket.add(resp);
    } catch (_) {
      // 发送失败忽略单条。
    }
    _events.add(ModbusSlaveDataEvent(true, Uint8List.fromList(resp), id));
  }

  /// 处理 PDU，返回响应 PDU（不含单元 ID）。异常时返回 [func|0x80, code]。
  Uint8List _handlePdu(List<int> pdu) {
    if (pdu.isEmpty) return _exc(0, 0x01);
    final func = pdu[0];
    switch (func) {
      case 0x01: // 读线圈
      case 0x02: // 读离散输入
        {
          final addr = (pdu[1] << 8) | pdu[2];
          final qty = (pdu[3] << 8) | pdu[4];
          final table = func == 0x01 ? coils : discreteInputs;
          if (qty < 1 || qty > 2000 || addr + qty > table.length) {
            return _exc(func, 0x02);
          }
          final byteCount = (qty + 7) ~/ 8;
          final out = List<int>.filled(byteCount, 0);
          for (var i = 0; i < qty; i++) {
            if (table[addr + i]) out[i >> 3] |= 0x80 >> (i & 7);
          }
          return Uint8List.fromList([func, byteCount, ...out]);
        }
      case 0x03: // 读保持寄存器
      case 0x04: // 读输入寄存器
        {
          final addr = (pdu[1] << 8) | pdu[2];
          final qty = (pdu[3] << 8) | pdu[4];
          final table = func == 0x03 ? holdingRegisters : inputRegisters;
          if (qty < 1 || qty > 125 || addr + qty > table.length) {
            return _exc(func, 0x02);
          }
          final out = <int>[func, qty * 2];
          for (var i = 0; i < qty; i++) {
            final v = table[addr + i] & 0xFFFF;
            out.add((v >> 8) & 0xFF);
            out.add(v & 0xFF);
          }
          return Uint8List.fromList(out);
        }
      case 0x05: // 写单个线圈
        {
          final addr = (pdu[1] << 8) | pdu[2];
          final val = (pdu[3] << 8) | pdu[4];
          if (addr >= coils.length) return _exc(func, 0x02);
          coils[addr] = val == 0xFF00;
          _events.add(const ModbusSlaveRegistersEvent());
          return Uint8List.fromList(pdu);
        }
      case 0x06: // 写单个保持寄存器
        {
          final addr = (pdu[1] << 8) | pdu[2];
          final val = (pdu[3] << 8) | pdu[4];
          if (addr >= holdingRegisters.length) return _exc(func, 0x02);
          holdingRegisters[addr] = val & 0xFFFF;
          _events.add(const ModbusSlaveRegistersEvent());
          return Uint8List.fromList(pdu);
        }
      case 0x0F: // 写多个线圈
        {
          final addr = (pdu[1] << 8) | pdu[2];
          final qty = (pdu[3] << 8) | pdu[4];
          final bc = pdu[5];
          final data = pdu.sublist(6, 6 + bc);
          if (qty < 1 || addr + qty > coils.length) return _exc(func, 0x02);
          for (var i = 0; i < qty; i++) {
            coils[addr + i] = (data[i >> 3] & (0x80 >> (i & 7))) != 0;
          }
          _events.add(const ModbusSlaveRegistersEvent());
          return Uint8List.fromList(
              [func, (addr >> 8) & 0xFF, addr & 0xFF, (qty >> 8) & 0xFF, qty & 0xFF]);
        }
      case 0x10: // 写多个保持寄存器
        {
          final addr = (pdu[1] << 8) | pdu[2];
          final qty = (pdu[3] << 8) | pdu[4];
          final bc = pdu[5];
          final data = pdu.sublist(6, 6 + bc);
          if (qty < 1 || bc != qty * 2 || addr + qty > holdingRegisters.length) {
            return _exc(func, 0x02);
          }
          for (var i = 0; i < qty; i++) {
            holdingRegisters[addr + i] =
                ((data[2 * i] << 8) | data[2 * i + 1]) & 0xFFFF;
          }
          _events.add(const ModbusSlaveRegistersEvent());
          return Uint8List.fromList(
              [func, (addr >> 8) & 0xFF, addr & 0xFF, (qty >> 8) & 0xFF, qty & 0xFF]);
        }
      default:
        return _exc(func, 0x01); // 非法功能码
    }
  }

  static Uint8List _exc(int func, int code) =>
      Uint8List.fromList([func | 0x80, code]);

  void _removeClient(String id) {
    final socket = _clients.remove(id);
    if (socket != null) {
      try {
        socket.destroy();
      } catch (_) {
        // 忽略关闭异常。
      }
      _events.add(ModbusSlaveClientEvent(id, '', false));
    }
  }

  // —— UI 编辑接口（本地直接修改数据区，供模拟设备状态）——
  void setHolding(int index, int value) {
    if (index < 0 || index >= holdingRegisters.length) return;
    holdingRegisters[index] = value & 0xFFFF;
    _events.add(const ModbusSlaveRegistersEvent());
  }

  void setInput(int index, int value) {
    if (index < 0 || index >= inputRegisters.length) return;
    inputRegisters[index] = value & 0xFFFF;
    _events.add(const ModbusSlaveRegistersEvent());
  }

  void setCoil(int index, bool value) {
    if (index < 0 || index >= coils.length) return;
    coils[index] = value;
    _events.add(const ModbusSlaveRegistersEvent());
  }

  void setDiscrete(int index, bool value) {
    if (index < 0 || index >= discreteInputs.length) return;
    discreteInputs[index] = value;
    _events.add(const ModbusSlaveRegistersEvent());
  }

  void stop() {
    for (final s in _clients.values) {
      try {
        s.destroy();
      } catch (_) {
        // 忽略。
      }
    }
    _clients.clear();
    try {
      _server?.close();
    } catch (_) {
      // 忽略。
    }
    _server = null;
    _events.add(const ModbusSlaveStateEvent(false));
  }

  void dispose() {
    stop();
    if (!_events.isClosed) _events.close();
  }
}
