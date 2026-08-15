import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// TCP 服务端事件（server 页订阅以更新 UI）。
sealed class TcpServerEvent {
  const TcpServerEvent();
}

/// 监听状态变化。
class TcpServerStateEvent extends TcpServerEvent {
  const TcpServerStateEvent(this.listening, [this.port]);
  final bool listening;
  final int? port;
}

/// 客户端上下线。
class TcpServerClientEvent extends TcpServerEvent {
  const TcpServerClientEvent(this.clientId, this.address, this.connected);
  final String clientId;
  final String address;
  final bool connected;
}

/// 收发数据（[tx]=true 表示服务端发出，false 表示某客户端发来）。
class TcpServerDataEvent extends TcpServerEvent {
  const TcpServerDataEvent(this.tx, this.bytes, [this.clientId]);
  final bool tx;
  final Uint8List bytes;
  final String? clientId;
}

class TcpServerErrorEvent extends TcpServerEvent {
  const TcpServerErrorEvent(this.message);
  final String message;
}

class _Client {
  _Client(this.id, this.socket);
  final String id;
  final Socket socket;
  String get address =>
      '${socket.remoteAddress.address}:${socket.remotePort}';
}

/// 轻量 TCP 服务端：监听端口、接受多客户端、支持广播/定向发送。
///
/// 收到某客户端的数据后，若 [forwardToOthers] 为真则转发给其他客户端
/// （适合做简单的回显/透传调试）；无论是否转发，都会通过事件流上报，供 UI 记录。
class TcpServer {
  TcpServer({this.forwardToOthers = false});

  bool forwardToOthers;

  final _events = StreamController<TcpServerEvent>.broadcast();
  Stream<TcpServerEvent> get events => _events.stream;

  ServerSocket? _server;
  String? _bindAddress;
  final _clients = <String, _Client>{};
  var _seq = 0;

  /// 当前监听端口（未监听时为 null）。
  int? get port => _server?.port;

  /// 当前监听网卡地址：null/空/'0.0.0.0' 表示全部接口。
  String get bindAddress => _bindAddress ?? '0.0.0.0';

  bool get isListening => _server != null;
  List<Map<String, String>> get clientList =>
      _clients.values
          .map((c) => {'id': c.id, 'address': c.address})
          .toList();

  Future<void> start(int port, {String? bindAddress}) async {
    if (_server != null) return;
    try {
      // 指定具体 IP 时只在该网卡监听；空或 0.0.0.0 表示监听全部接口。
      final addr = (bindAddress != null &&
              bindAddress.isNotEmpty &&
              bindAddress != '0.0.0.0')
          ? InternetAddress(bindAddress)
          : InternetAddress.anyIPv4;
      _server = await ServerSocket.bind(addr, port);
      _bindAddress = bindAddress;
    } on SocketException catch (e) {
      _events.add(TcpServerErrorEvent('监听失败：$e'));
      return;
    }
    _events.add(TcpServerStateEvent(true, port));
    _server!.listen(_onConnection,
        onError: (e) =>
            _events.add(TcpServerErrorEvent('监听异常：$e')));
  }

  /// 枚举本机 IPv4 地址（不含回环/链路本地），供 UI 选择监听网卡。
  static Future<List<String>> localAddresses() async {
    final out = <String>[];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (!out.contains(a.address)) out.add(a.address);
        }
      }
    } catch (_) {
      // 枚举失败回退空列表，UI 仍可用「全部接口」。
    }
    return out;
  }

  void _onConnection(Socket socket) {
    final id = 'c${++_seq}';
    final client = _Client(id, socket);
    _clients[id] = client;
    _events.add(TcpServerClientEvent(id, client.address, true));

    socket.listen(
      (data) {
        final bytes = Uint8List.fromList(data);
        // 转发给其他客户端（回显/透传调试）。
        if (forwardToOthers) {
          for (final other in _clients.values) {
            if (other.id != id) {
              try {
                other.socket.add(bytes);
              } catch (_) {
                // 转发失败忽略单条。
              }
            }
          }
        }
        _events.add(TcpServerDataEvent(false, bytes, id));
      },
      onError: (e) {
        _events.add(TcpServerErrorEvent('客户端 $id 异常：$e'));
        _removeClient(id);
      },
      onDone: () => _removeClient(id),
      cancelOnError: false,
    );
  }

  void _removeClient(String id) {
    final client = _clients.remove(id);
    if (client != null) {
      _events.add(TcpServerClientEvent(id, client.address, false));
      try {
        client.socket.destroy();
      } catch (_) {
        // 忽略关闭异常。
      }
    }
  }

  /// 向所有已连接客户端广播。
  void broadcast(Uint8List bytes) {
    if (_clients.isEmpty) return;
    for (final c in _clients.values) {
      try {
        c.socket.add(bytes);
      } catch (_) {
        // 单条失败忽略。
      }
    }
    _events.add(TcpServerDataEvent(true, bytes, null));
  }

  /// 向指定客户端发送。
  void sendTo(String clientId, Uint8List bytes) {
    final client = _clients[clientId];
    if (client == null) return;
    try {
      client.socket.add(bytes);
      _events.add(TcpServerDataEvent(true, bytes, clientId));
    } catch (_) {
      // 发送失败忽略。
    }
  }

  void disconnectClient(String clientId) => _removeClient(clientId);

  void stop() {
    for (final c in _clients.values) {
      try {
        c.socket.destroy();
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
    _events.add(const TcpServerStateEvent(false));
  }

  void dispose() {
    stop();
    if (!_events.isClosed) _events.close();
  }
}
