import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/device_protocol.dart';

/// TCP 原始协议：建立一个裸 TCP 连接，收发任意字节流，不解析任何应用层语义。
///
/// 与 [ModbusTcpProtocol] 不同，本协议不面向寄存器 / 报文结构，仅提供
/// `send(Uint8List)` 与 `received` 字节流，供调试页做 hex dump / ASCII 展示。
/// 它作为正式协议注册进 [ProtocolRegistry]，使“添加设备 / 连接”流程可选
/// TCP 原始连接，并复用 [ConnectionManager] 的统一状态与历史管理。
class TcpRawProtocol extends DeviceProtocol {
  TcpRawProtocol()
      : super(
          type: ProtocolType.tcpRaw,
          name: 'TCP Client',
          description: '建立裸 TCP 连接，收发任意字节流（hex / ASCII 调试）',
        );

  Socket? _socket;
  final _stateCtl = StreamController<DeviceConnectionState>.broadcast();
  final _rxCtl = StreamController<Uint8List>.broadcast();
  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  String? _error;

  @override
  DeviceConnectionState get connectionState => _state;

  @override
  Stream<DeviceConnectionState> get connectionStateStream => _stateCtl.stream;

  @override
  String? get lastError => _error;

  /// 收到的字节流（RX）。
  Stream<Uint8List> get received => _rxCtl.stream;

  @override
  Future<void> connect(ConnectionConfig config) async {
    if (config is! TcpRawConnectionConfig) {
      throw ArgumentError('TCP 原始协议需要 TcpRawConnectionConfig');
    }
    if (config.host.trim().isEmpty) {
      _error = '请填写主机地址';
      _setState(DeviceConnectionState.error);
      throw StateError('主机地址为空');
    }
    _setState(DeviceConnectionState.connecting);
    _error = null;
    try {
      final socket = await Socket.connect(
        config.host.trim(),
        config.port,
        timeout: config.timeout,
      );
      _socket = socket;
      socket.listen(
        (data) {
          if (!_rxCtl.isClosed) {
            _rxCtl.add(Uint8List.fromList(data));
          }
        },
        onError: (e) {
          _error = e.toString();
          _close();
          _setState(DeviceConnectionState.error);
        },
        onDone: () {
          _close();
          if (_state != DeviceConnectionState.disconnected) {
            _setState(DeviceConnectionState.disconnected);
          }
        },
        cancelOnError: false,
      );
      _setState(DeviceConnectionState.connected);
    } on SocketException catch (e) {
      _error = '连接失败：$e';
      _setState(DeviceConnectionState.error);
      rethrow;
    } on TimeoutException {
      _error = '连接超时（${config.timeout.inSeconds}s）';
      _setState(DeviceConnectionState.error);
      rethrow;
    }
  }

  /// 发送字节流（TX）。未连接时抛出 [StateError]。
  void send(Uint8List bytes) {
    final s = _socket;
    if (s == null) throw StateError('未连接，无法发送');
    s.add(bytes);
  }

  @override
  Future<void> disconnect() async {
    _close();
    _setState(DeviceConnectionState.disconnected);
  }

  void _setState(DeviceConnectionState s) {
    _state = s;
    if (!_stateCtl.isClosed) _stateCtl.add(s);
  }

  void _close() {
    try {
      _socket?.destroy();
    } catch (_) {
      // 忽略关闭异常。
    }
    _socket = null;
  }

  @override
  void dispose() {
    _close();
    _stateCtl.close();
    _rxCtl.close();
  }
}
