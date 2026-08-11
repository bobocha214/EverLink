import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/device_protocol.dart';

/// 一条 WebSocket 消息记录（可用于收发两方向）。
class WsMessageRecord {
  WsMessageRecord({
    required this.data,
    required this.isBinary,
    required this.outgoing,
    required this.time,
  });

  /// 文本为原始字符串；二进制为 base64 编码后的字符串。
  final String data;

  /// 是否为二进制消息。
  final bool isBinary;

  /// 是否为本地发出的消息（true）还是对端收到的消息（false）。
  final bool outgoing;

  /// 产生时间。
  final DateTime time;
}

/// WebSocket 协议实现。
///
/// 基于 [dart:io] 的 [WebSocket] 封装，支持连接 / 断开、发送文本消息、接收
/// 对端消息。消息通过 [messageStream] 暴露给 UI，收发都进入同一条流以便统一
/// 展示（用 [WsMessageRecord.outgoing] 区分方向）。
class WebSocketProtocol extends DeviceProtocol {
  WebSocketProtocol()
      : super(
          type: ProtocolType.webSocket,
          name: 'WebSocket',
          description: '全双工长连接，向服务端收发文本 / 二进制消息。',
        );

  WebSocket? _socket;

  final StreamController<DeviceConnectionState> _stateController =
      StreamController<DeviceConnectionState>.broadcast();
  final StreamController<WsMessageRecord> _messageController =
      StreamController<WsMessageRecord>.broadcast();

  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  @override
  String? lastError;

  /// 接收到的消息流（含本地发出的消息，方向见 [WsMessageRecord.outgoing]）。
  Stream<WsMessageRecord> get messageStream => _messageController.stream;

  @override
  DeviceConnectionState get connectionState => _state;

  @override
  Stream<DeviceConnectionState> get connectionStateStream =>
      _stateController.stream;

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
    if (config is! WebSocketConnectionConfig) {
      throw ArgumentError('WebSocketProtocol 需要 WebSocketConnectionConfig');
    }
    _setState(DeviceConnectionState.connecting);
    try {
      final socket = await WebSocket.connect(
        config.url,
        protocols: config.protocols,
        headers: config.headers == null
            ? null
            : Map<String, dynamic>.from(config.headers!),
      );
      _socket = socket;
      socket.listen(
        (data) {
          final record = WsMessageRecord(
            data: data is String ? data : base64Encode(data as List<int>),
            isBinary: data is! String,
            outgoing: false,
            time: DateTime.now(),
          );
          _messageController.add(record);
        },
        onDone: () {
          if (_state != DeviceConnectionState.disconnected) {
            _setState(DeviceConnectionState.disconnected);
          }
        },
        onError: (e) {
          _setState(DeviceConnectionState.error, e.toString());
        },
        cancelOnError: false,
      );
      _setState(DeviceConnectionState.connected);
    } catch (e) {
      _setState(DeviceConnectionState.error, e.toString());
      _socket = null;
      rethrow;
    }
  }

  /// 发送一条文本消息。
  void send(String message) {
    if (_socket == null) {
      throw StateError('WebSocket 未连接');
    }
    _socket!.add(message);
    _messageController.add(
      WsMessageRecord(
        data: message,
        isBinary: false,
        outgoing: true,
        time: DateTime.now(),
      ),
    );
  }

  @override
  Future<void> disconnect() async {
    await _socket?.close();
    _socket = null;
    _setState(DeviceConnectionState.disconnected);
  }

  @override
  void dispose() {
    _socket?.close();
    _socket = null;
    _stateController.close();
    _messageController.close();
  }
}
