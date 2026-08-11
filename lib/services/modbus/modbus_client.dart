import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 寄存器数据类型：把连续的 16 位寄存器按字节序组合成更高精度的值。
///
/// 该枚举与 [lib/models/modbus_models.dart] 中的同名类型相互独立——后者服务于
/// 基于 `modbus_client` pub 包的 [ModbusTcpProtocol]；本枚举服务于 `modbus_page`
/// 的原始 TCP 调试客户端，覆盖更全（含 64 位 / 浮点 / 位），且自带解析所需的
/// [registerCount] 与 [label]。
enum ModbusDataType {
  bool8('布尔 (1 位)', 1),
  int16('Int16', 1),
  uint16('UInt16', 1),
  int32('Int32', 2),
  uint32('UInt32', 2),
  float32('Float32', 2),
  int64('Int64', 4),
  uint64('UInt64', 4),
  double64('Double', 4);

  const ModbusDataType(this.label, this.registerCount);

  /// 下拉/展示用中文标签。
  final String label;

  /// 该类型占用的 16 位寄存器数量。
  final int registerCount;
}

/// 多寄存器数据的字节序控制。
///
/// - [wordSwap]：交换相邻寄存器（字）的顺序，例如 ABCD → CDAB。
/// - [byteSwap]：交换每个寄存器内部两个字节的顺序，例如 AB → BA。
/// 两者可组合，覆盖常见的 4 种 32 位排列（ABCD / DCBA / BADC / CDAB）。
class ModbusByteOrder {
  const ModbusByteOrder({this.wordSwap = false, this.byteSwap = false});

  final bool wordSwap;
  final bool byteSwap;
}

/// 原始 Modbus TCP 客户端（基于 [Socket]，不依赖任何第三方库）。
///
/// 提供与 `modbus_page` 调试页一一对应的极简读写接口：连接管理、保持/输入
/// 寄存器读取、单点/多点寄存器与线圈写入，并记录最近一次的收发原始报文
/// （[lastRequest] / [lastResponse]）供页面展示。所有请求在单条 TCP 连接上
/// 串行化执行，避免监控轮询与手动操作并发时服务端丢弃请求。
class ModbusTcpClient {
  ModbusTcpClient(this.host, this.port);

  /// 设备 IP 地址。
  final String host;

  /// 设备端口，默认 502。
  final int port;

  Socket? _socket;
  StreamSubscription<Uint8List>? _sub;

  /// 请求串行化队列：任意时刻仅一个事务在链路上。
  Future<void> _queue = Future.value();

  /// 当前挂起事务的响应 completer。
  Completer<List<int>>? _pending;

  /// 期望响应的事务 ID（用于丢弃陈旧帧）。
  int _expectedTid = 0;
  int _tidCounter = 0;

  /// 最近一次发出的完整 MBAP 帧（含 7 字节头）。
  List<int>? lastRequest;

  /// 最近一次收到的完整 MBAP 帧。
  List<int>? lastResponse;

  /// 是否已连接（底层 socket 存在）。
  bool get isConnected => _socket != null;

  /// 建立 TCP 连接。
  Future<void> connect({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (isConnected) return;
    final socket = await Socket.connect(host, port, timeout: timeout);
    _socket = socket;
    _sub = socket.listen(
      _onData,
      onError: (Object e) => _failPending(e),
      onDone: () {
        _socket = null;
        _failPending(const SocketException('Modbus 连接已断开'));
      },
    );
  }

  /// 关闭连接。
  void disconnect() {
    _sub?.cancel();
    _sub = null;
    _socket?.destroy();
    _socket = null;
    _failPending(const SocketException('Modbus 连接已断开'));
  }

  void _onData(List<int> data) {
    lastResponse = null;
    _buffer.addAll(data);
    _tryDeliver();
  }

  final List<int> _buffer = <int>[];

  void _tryDeliver() {
    if (_pending == null || _pending!.isCompleted) return;
    while (_buffer.length >= 6) {
      // MBAP：事务ID(2) + 协议ID(2) + 长度(2) + 单元ID(1)；长度 = 单元ID + PDU。
      final len = (_buffer[4] << 8) | _buffer[5];
      final total = 6 + len;
      if (_buffer.length < total) return;
      final frame = _buffer.sublist(0, total);
      final tid = (frame[0] << 8) | frame[1];
      _buffer.removeRange(0, total);
      if (tid != _expectedTid) {
        // 陈旧帧（例如上一个已超时的请求迟到的响应），丢弃后继续尝试。
        continue;
      }
      lastResponse = frame;
      final completer = _pending!;
      _pending = null;
      completer.complete(frame);
      return;
    }
  }

  void _failPending(Object error) {
    final completer = _pending;
    _pending = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  /// 在单条连接上串行执行一次服务调用。
  Future<T> _run<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }, onError: (_, _) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// 发送一个 PDU 并等待完整响应帧。
  Future<List<int>> _transaction(List<int> pdu, int unitId,
      {Duration? timeout}) {
    if (_socket == null) throw StateError('Modbus 未连接');
    final tid = (++_tidCounter) & 0xFFFF;
    _expectedTid = tid;
    final frame = <int>[
      (tid >> 8) & 0xFF,
      tid & 0xFF, // 事务 ID
      0x00,
      0x00, // 协议 ID（Modbus TCP 固定 0）
      ((pdu.length + 1) >> 8) & 0xFF,
      (pdu.length + 1) & 0xFF, // 长度 = 单元ID + PDU
      unitId & 0xFF, // 单元 ID（从站）
      ...pdu,
    ];
    lastRequest = frame;
    final completer = Completer<List<int>>();
    _pending = completer;
    _buffer.clear();
    _socket!.add(frame);
    return completer.future.timeout(timeout ?? const Duration(seconds: 3));
  }

  /// 检查响应帧是否为异常响应，是则抛出可读异常。
  void _checkException(List<int> resp, int funcCode) {
    if (resp.length < 8) {
      throw Exception('Modbus 响应过短（${resp.length} 字节）');
    }
    final code = resp[7];
    if ((code & 0x80) != 0) {
      final exc = resp.length > 8 ? resp[8] : 0;
      throw Exception(
          'Modbus 异常：功能码 0x${funcCode.toRadixString(16)} → 异常码 0x${exc.toRadixString(16)}');
    }
    if (code != funcCode) {
      throw Exception(
          'Modbus 功能码不匹配：期望 0x${funcCode.toRadixString(16)}，收到 0x${code.toRadixString(16)}');
    }
  }

  /// 读取保持/输入寄存器，返回原始 16 位寄存器值列表。
  Future<List<int>> readRegisters(
    int slave,
    int funcCode,
    int addr,
    int count,
  ) {
    return _run(() async {
      final pdu = <int>[
        funcCode & 0xFF,
        (addr >> 8) & 0xFF,
        addr & 0xFF,
        (count >> 8) & 0xFF,
        count & 0xFF,
      ];
      final resp = await _transaction(pdu, slave);
      _checkException(resp, funcCode);
      final byteCount = resp[8];
      final data = resp.sublist(9, 9 + byteCount);
      final regs = <int>[];
      for (var i = 0; i + 1 < data.length; i += 2) {
        regs.add((data[i] << 8) | data[i + 1]);
      }
      return regs;
    });
  }

  /// 写单个保持寄存器（功能码 0x06）。
  Future<void> writeRegister(int slave, int addr, int value) {
    return _run(() async {
      final pdu = <int>[
        0x06,
        (addr >> 8) & 0xFF,
        addr & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];
      final resp = await _transaction(pdu, slave);
      _checkException(resp, 0x06);
    });
  }

  /// 写多个保持寄存器（功能码 0x10）。
  Future<void> writeRegisters(int slave, int addr, List<int> values) {
    return _run(() async {
      final byteCount = values.length * 2;
      final pdu = <int>[
        0x10,
        (addr >> 8) & 0xFF,
        addr & 0xFF,
        (values.length >> 8) & 0xFF,
        values.length & 0xFF,
        byteCount & 0xFF,
      ];
      for (final v in values) {
        pdu.add((v >> 8) & 0xFF);
        pdu.add(v & 0xFF);
      }
      final resp = await _transaction(pdu, slave);
      _checkException(resp, 0x10);
    });
  }

  /// 写单个线圈（功能码 0x05）。
  Future<void> writeCoil(int slave, int addr, bool on) {
    return _run(() async {
      final val = on ? 0xFF00 : 0x0000;
      final pdu = <int>[
        0x05,
        (addr >> 8) & 0xFF,
        addr & 0xFF,
        (val >> 8) & 0xFF,
        val & 0xFF,
      ];
      final resp = await _transaction(pdu, slave);
      _checkException(resp, 0x05);
    });
  }

  /// 写多个线圈（功能码 0x0F）。
  Future<void> writeCoils(int slave, int addr, List<bool> states) {
    return _run(() async {
      final qty = states.length;
      final byteCount = (qty + 7) ~/ 8;
      final bits = List<int>.filled(byteCount, 0);
      for (var i = 0; i < qty; i++) {
        if (states[i]) bits[i >> 3] |= 0x80 >> (i & 7);
      }
      final pdu = <int>[
        0x0F,
        (addr >> 8) & 0xFF,
        addr & 0xFF,
        (qty >> 8) & 0xFF,
        qty & 0xFF,
        byteCount & 0xFF,
        ...bits,
      ];
      final resp = await _transaction(pdu, slave);
      _checkException(resp, 0x0F);
    });
  }
}
