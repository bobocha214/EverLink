import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 最小 MQTT 3.1.1 Broker 模拟（单进程内存实现）。
///
/// 支持：CONNECT/CONNACK、SUBSCRIBE/SUBACK、PUBLISH（QoS0/1，支持通配符
/// `+/#` 主题匹配）、PUBACK、UNSUBSCRIBE/UNSUBACK、PINGREQ/PINGRESP、
/// DISCONNECT、Retained 消息。用于本地联调其它 MQTT 客户端 / 发布模拟器。
class MqttBroker {
  MqttBroker();

  final _events = StreamController<MqttBrokerEvent>.broadcast();
  Stream<MqttBrokerEvent> get events => _events.stream;

  ServerSocket? _server;
  String? _bindAddress;
  final _clients = <String, _MqttClientConn>{};

  /// 当前监听端口（未监听时为 null）。
  int? get port => _server?.port;

  /// 当前监听网卡地址：null/空/'0.0.0.0' 表示全部接口。
  String get bindAddress => _bindAddress ?? '0.0.0.0';

  bool get listening => _server != null;

  /// 主题 -> 订阅者（clientId 列表）。
  final Map<String, Set<String>> _subscriptions = {};

  /// 订阅者 -> 其订阅的主题。
  final Map<String, Set<String>> _clientTopics = {};

  /// Retained 消息：topic -> (payload, qos)。
  final Map<String, (_MqttQos, Uint8List)> _retained = {};

  Future<void> start(int port, {String? bindAddress}) async {
    if (_server != null) return;
    // 指定具体 IP 时只在该网卡监听；空或 0.0.0.0 表示监听全部接口。
    final addr = (bindAddress != null &&
            bindAddress.isNotEmpty &&
            bindAddress != '0.0.0.0')
        ? InternetAddress(bindAddress)
        : InternetAddress.anyIPv4;
    _server = await ServerSocket.bind(addr, port);
    _bindAddress = bindAddress;
    _events.add(MqttBrokerStateEvent(true));
    _server!.listen(_onAccept, onError: (e) {
      _events.add(MqttBrokerErrorEvent('监听错误：$e'));
    });
  }

  void stop() {
    final snapshot = List.of(_clients.values);
    for (final c in snapshot) {
      try {
        c.socket.destroy();
      } catch (_) {
        // 忽略。
      }
    }
    _clients.clear();
    _subscriptions.clear();
    _clientTopics.clear();
    _retained.clear();
    _server?.close();
    _server = null;
    _events.add(MqttBrokerStateEvent(false));
  }

  void dispose() {
    stop();
    _events.close();
  }

  int get clientCount => _clients.length;

  /// 当前已连接的客户端列表（供页面重新进入时恢复显示）。
  List<Map<String, String>> get clientList =>
      _clients.values
          .map((c) => {'id': c.id, 'address': c.address})
          .toList();

  void _onAccept(Socket socket) {
    final id = '${socket.remoteAddress.address}:${socket.remotePort}';
    final conn = _MqttClientConn(id, socket);
    _clients[id] = conn;
    _events.add(MqttBrokerClientEvent(id, conn.address, true));
    socket.listen(
      (data) {
        conn.buf.addAll(data);
        _drain(conn);
      },
      onDone: () => _removeClient(id),
      onError: (e) {
        _events.add(MqttBrokerErrorEvent('连接 $id 出错：$e'));
        _removeClient(id);
      },
    );
  }

  void _removeClient(String id) {
    final c = _clients.remove(id);
    if (c != null) {
      // 清理该客户端的订阅。
      final topics = _clientTopics.remove(id);
      if (topics != null) {
        for (final t in topics) {
          _subscriptions[t]?.remove(id);
          if (_subscriptions[t]?.isEmpty ?? false) {
            _subscriptions.remove(t);
          }
        }
      }
      try {
        c.socket.destroy();
      } catch (_) {
        // 忽略。
      }
      _events.add(MqttBrokerClientEvent(id, c.address, false));
    }
  }

  void _drain(_MqttClientConn conn) {
    // MQTT 包：1 字节固定头 + 剩余长度（变长编码），剩余长度后才是 payload。
    while (true) {
      if (conn.buf.isEmpty) return;
      // 计算剩余长度字段占用的字节数。
      int multiplier = 1;
      int remainingLength = 0;
      int pos = 1;
      bool complete = false;
      int lenBytes = 0;
      while (pos < conn.buf.length) {
        final encByte = conn.buf[pos];
        lenBytes++;
        remainingLength += (encByte & 0x7F) * multiplier;
        multiplier *= 128;
        pos++;
        if ((encByte & 0x80) == 0) {
          complete = true;
          break;
        }
        if (lenBytes >= 4) break; // 非法。
      }
      if (!complete) return; // 剩余长度字段未收全。
      final headerLen = 1 + lenBytes;
      final total = headerLen + remainingLength;
      if (conn.buf.length < total) return; // 包未收全。
      final packet = Uint8List.fromList(conn.buf.sublist(0, total));
      conn.buf.removeRange(0, total);
      _handlePacket(conn, packet);
    }
  }

  void _handlePacket(_MqttClientConn conn, Uint8List packet) {
    final fixed = packet[0];
    final type = (fixed >> 4) & 0x0F;
    final flags = fixed & 0x0F;
    switch (type) {
      case 1: // CONNECT
        _handleConnect(conn, packet, flags);
      case 8: // SUBSCRIBE
        _handleSubscribe(conn, packet);
      case 10: // UNSUBSCRIBE
        _handleUnsubscribe(conn, packet);
      case 3: // PUBLISH
        _handlePublish(conn, packet, flags);
      case 12: // PINGREQ
        final pingresp = Uint8List.fromList([0xD0, 0x00]); // PINGRESP 固定头
        _send(conn, pingresp);
        _events.add(MqttBrokerDataEvent(conn.id, true, pingresp, 'PINGRESP'));
      case 14: // DISCONNECT
        _removeClient(conn.id);
      case 2: // CONNACK（不应来自客户端）
      case 4: // PUBACK
      case 5: // PUBREC
      case 6: // PUBREL
      case 7: // PUBCOMP
      case 9: // SUBACK
      case 11: // UNSUBACK
      case 13: // PINGRESP
        // 服务端不处理这些来自客户端的包（忽略）。
        break;
      default:
        _events.add(MqttBrokerErrorEvent('未知 MQTT 包类型：$type'));
    }
  }

  int _remainingLengthOffset(Uint8List packet) {
    int pos = 1;
    while (pos < packet.length) {
      final b = packet[pos];
      pos++;
      if ((b & 0x80) == 0) break;
    }
    return pos;
  }

  void _handleConnect(_MqttClientConn conn, Uint8List packet, int flags) {
    final r = _MqttReader(packet, _remainingLengthOffset(packet));
    // 协议名 "MQTT" + 版本。
    r.readString(); // protoName
    final protoLevel = r.readUint8();
    r.readUint8(); // connectFlags
    r.readUint16(); // keepAlive
    final clientId = r.readString();
    conn.clientId = clientId.isNotEmpty ? clientId : conn.id;
    _clients[conn.id]?.clientId = conn.clientId;

    // CONNACK：固定头 0x20 0x02，可变头 连接确认标志 0x00 + 返回码 0x00。
    final connack = Uint8List.fromList([0x20, 0x02, 0x00, 0x00]);
    _send(conn, connack);
    _events.add(MqttBrokerDataEvent(conn.id, true, connack,
        'CONNACK (clientId=$clientId, level=$protoLevel)'));
    // 忽略用户名/密码（接受任意）。
  }

  void _handleSubscribe(_MqttClientConn conn, Uint8List packet) {
    final r = _MqttReader(packet, _remainingLengthOffset(packet));
    final packetId = r.readUint16();
    final granted = <int>[];
    final myTopics = _clientTopics.putIfAbsent(conn.clientId, () => <String>{});
    while (r.remaining > 0) {
      final topic = r.readString();
      final qos = r.readUint8();
      _subscriptions.putIfAbsent(topic, () => <String>{}).add(conn.clientId);
      myTopics.add(topic);
      granted.add(qos.clamp(0, 2));
      // 发送 retained 消息（如有）。
      final ret = _retained[topic];
      if (ret != null) {
        _deliver(conn, topic, ret.$1, Uint8List.fromList(ret.$2),
            retained: true);
      }
      _events.add(MqttBrokerDataEvent(conn.id, false, Uint8List(0),
          'SUBSCRIBE $topic (QoS$qos)'));
    }
    // SUBACK：固定头 0x90，可变头 packetId，payload 每个订阅一个返回码。
    final payload = Uint8List.fromList(granted);
    final out = _buildWithVarHeader(0x90, packetId, payload);
    _send(conn, out);
    _events.add(MqttBrokerDataEvent(conn.id, true, out, 'SUBACK ×${granted.length}'));
  }

  void _handleUnsubscribe(_MqttClientConn conn, Uint8List packet) {
    final r = _MqttReader(packet, _remainingLengthOffset(packet));
    final packetId = r.readUint16();
    final myTopics = _clientTopics[conn.clientId];
    while (r.remaining > 0) {
      final topic = r.readString();
      _subscriptions[topic]?.remove(conn.clientId);
      if (_subscriptions[topic]?.isEmpty ?? false) {
        _subscriptions.remove(topic);
      }
      myTopics?.remove(topic);
      _events.add(MqttBrokerDataEvent(conn.id, false, Uint8List(0), 'UNSUBSCRIBE $topic'));
    }
    // UNSUBACK：固定头 0xB0，可变头 packetId。
    final out = _buildWithVarHeader(0xB0, packetId, Uint8List(0));
    _send(conn, out);
    _events.add(MqttBrokerDataEvent(conn.id, true, out, 'UNSUBACK'));
  }

  void _handlePublish(_MqttClientConn conn, Uint8List packet, int flags) {
    final qos = (flags >> 1) & 0x03;
    final retain = (flags & 0x01) != 0;
    final r = _MqttReader(packet, _remainingLengthOffset(packet));
    final topic = r.readString();
    int? packetId;
    if (qos > 0) packetId = r.readUint16();
    final payload = r.rest();

    _events.add(MqttBrokerDataEvent(conn.id, false, Uint8List.fromList(payload),
        'PUBLISH $topic (QoS$qos${retain ? ' retained' : ''})'));

    if (retain) {
      if (payload.isEmpty) {
        _retained.remove(topic);
      } else {
        _retained[topic] = (_MqttQos.values[qos.clamp(0, 2)], payload);
      }
    }

    // 转发给匹配主题的订阅者（除发布者自身除非显式）。
    _broadcast(topic, _MqttQos.values[qos.clamp(0, 2)], payload,
        exclude: conn.clientId);

    if (qos == 1 && packetId != null) {
      // PUBACK：固定头 0x40 0x02，可变头 packetId。
      final out = Uint8List.fromList([0x40, 0x02, (packetId >> 8) & 0xFF, packetId & 0xFF]);
      _send(conn, out);
      _events.add(MqttBrokerDataEvent(conn.id, true, out, 'PUBACK ($packetId)'));
    } else if (qos == 2) {
      // 简化：不支持 QoS2 全握手，回 PUBREC 收到即视为完成，不再追踪。
      final out = Uint8List.fromList([0x50, 0x02, (packetId! >> 8) & 0xFF, packetId & 0xFF]);
      _send(conn, out);
      _events.add(MqttBrokerDataEvent(conn.id, true, out, 'PUBREC ($packetId, QoS2 简化)'));
    }
  }

  void _broadcast(String topic, _MqttQos qos, Uint8List payload,
      {required String exclude}) {
    for (final entry in _subscriptions.entries) {
      if (!_topicMatches(entry.key, topic)) continue;
      for (final cid in entry.value) {
        if (cid == exclude) continue;
        final target = _findByClientId(cid);
        if (target != null) {
          _deliver(target, topic, qos, payload);
        }
      }
    }
  }

  void _deliver(_MqttClientConn conn, String topic, _MqttQos qos,
      Uint8List payload, {bool retained = false}) {
    // PUBLISH 固定头：type=3，flags: QoS + retain。
    final qosBits = qos.index << 1;
    final flag = 0x30 | (qosBits & 0x06) | (retained ? 0x01 : 0);
    final topicBytes = utf8.encode(topic);
    final varHeader = Uint8List.fromList([
      ..._encodeRemainingLengthField(topicBytes.length),
      ..._int16(topicBytes.length),
      ...topicBytes,
    ]);
    // 这里简化：QoS0 转发不带 packetId。
    final out = _buildFixed(flag, Uint8List.fromList([...varHeader, ...payload]));
    _send(conn, out);
    _events.add(MqttBrokerDataEvent(conn.id, true, out,
        '转发 PUBLISH $topic → ${conn.clientId}'));
  }

  _MqttClientConn? _findByClientId(String clientId) {
    for (final c in _clients.values) {
      if (c.clientId == clientId) return c;
    }
    return null;
  }

  static bool _topicMatches(String filter, String topic) {
    final f = filter.split('/');
    final t = topic.split('/');
    for (var i = 0; i < f.length; i++) {
      if (f[i] == '#') {
        return true; // 多级通配。
      }
      if (i >= t.length) {
        return false;
      }
      if (f[i] == '+') {
        continue; // 单级通配。
      }
      if (f[i] != t[i]) return false;
    }
    return f.length == t.length;
  }

  Uint8List _buildFixed(int typeAndFlags, Uint8List payload) {
    final lenBytes = _encodeRemainingLengthField(payload.length);
    final out = Uint8List(1 + lenBytes.length + payload.length);
    out[0] = typeAndFlags;
    var idx = 1;
    for (final b in lenBytes) {
      out[idx++] = b;
    }
    for (final b in payload) {
      out[idx++] = b;
    }
    return out;
  }

  Uint8List _buildWithVarHeader(int type, int packetId, Uint8List payload) {
    final varHeader = Uint8List.fromList(_int16(packetId) + payload);
    return _buildFixed(type, varHeader);
  }

  static List<int> _encodeRemainingLengthField(int length) {
    final bytes = <int>[];
    var x = length;
    do {
      var b = x % 128;
      x ~/= 128;
      if (x > 0) b |= 0x80;
      bytes.add(b);
    } while (x > 0);
    return bytes;
  }

  static List<int> _int16(int v) => [(v >> 8) & 0xFF, v & 0xFF];

  void _send(_MqttClientConn conn, Uint8List bytes) {
    try {
      conn.socket.add(bytes);
    } catch (_) {
      // 忽略。
    }
  }
}

enum _MqttQos { atMostOnce, atLeastOnce, exactlyOnce }

/// 一个 MQTT 客户端连接。
class _MqttClientConn {
  _MqttClientConn(this.id, this.socket)
      : address = '${socket.remoteAddress.address}:${socket.remotePort}';

  final String id;
  final Socket socket;
  final String address;
  final buf = <int>[];
  String clientId = '';
}

/// MQTT 剩余长度之后的读工具。
class _MqttReader {
  _MqttReader(this.bytes, this.offset);

  final Uint8List bytes;
  int offset;

  int get remaining => bytes.length - offset;

  int readUint8() => bytes[offset++];
  int readUint16() {
    final v = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;
    return v;
  }

  String readString() {
    final len = readUint16();
    final code = bytes.sublist(offset, offset + len);
    offset += len;
    return utf8.decode(code);
  }

  Uint8List rest() => Uint8List.fromList(bytes.sublist(offset));
}

sealed class MqttBrokerEvent {}

class MqttBrokerStateEvent extends MqttBrokerEvent {
  MqttBrokerStateEvent(this.listening);
  final bool listening;
}

class MqttBrokerClientEvent extends MqttBrokerEvent {
  MqttBrokerClientEvent(this.clientId, this.address, this.connected);
  final String clientId;
  final String address;
  final bool connected;
}

class MqttBrokerDataEvent extends MqttBrokerEvent {
  MqttBrokerDataEvent(this.clientId, this.tx, this.bytes, this.note);
  final String clientId;
  final bool tx;
  final Uint8List bytes;
  final String note;
}

class MqttBrokerErrorEvent extends MqttBrokerEvent {
  MqttBrokerErrorEvent(this.message);
  final String message;
}
