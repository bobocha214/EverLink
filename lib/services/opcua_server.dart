import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mcp_io_opcua/mcp_io_opcua.dart';

/// 单个可自定义的 OPC UA 节点（变量节点）。
///
/// 服务端地址空间由一组 [OpcUaNode] 构成，用户可增删、改 NodeId / 类型 / 值。
class OpcUaNode {
  OpcUaNode({
    required this.namespaceIndex,
    required this.identifier,
    required this.name,
    required this.builtInType,
    required this.valueText,
  });

  /// 命名空间索引（通常为 2，因 0/1 为标准和类型命名空间）。
  int namespaceIndex;

  /// 节点标识：数字或字符串（与 [identifierIsString] 配合）。
  String identifier;

  /// 显示名 / BrowseName。
  String name;

  /// 值的内置类型。
  OpcUaBuiltInType builtInType;

  /// 以文本形式存储的当前值（UI 编辑方便），运行时解析为对应类型。
  String valueText;

  bool get identifierIsString =>
      identifier.contains(RegExp(r'[^0-9]')) || identifier.isEmpty;

  OpcUaNodeIdValue get nodeId => identifierIsString
      ? OpcUaNodeIdString(namespaceIndex: namespaceIndex, identifier: identifier)
      : OpcUaNodeIdNumeric(
          namespaceIndex: namespaceIndex,
          identifier: int.tryParse(identifier) ?? 0,
        );

  /// 把 [valueText] 按 [builtInType] 解析为 [OpcUaVariantValue]。
  OpcUaVariantValue parseValue() {
    try {
      switch (builtInType) {
        case OpcUaBuiltInType.boolean:
          return OpcUaVariantValue.scalar(
              builtInType, valueText.trim().toLowerCase() == 'true');
        case OpcUaBuiltInType.sByte:
        case OpcUaBuiltInType.byte:
        case OpcUaBuiltInType.int16:
        case OpcUaBuiltInType.uInt16:
        case OpcUaBuiltInType.int32:
        case OpcUaBuiltInType.uInt32:
          return OpcUaVariantValue.scalar(
              builtInType, int.tryParse(valueText.trim()) ?? 0);
        case OpcUaBuiltInType.int64:
        case OpcUaBuiltInType.uInt64:
          return OpcUaVariantValue.scalar(
              builtInType, int.tryParse(valueText.trim()) ?? 0);
        case OpcUaBuiltInType.float:
        case OpcUaBuiltInType.double_:
          return OpcUaVariantValue.scalar(
              builtInType, double.tryParse(valueText.trim()) ?? 0.0);
        case OpcUaBuiltInType.string:
          return OpcUaVariantValue.scalar(builtInType, valueText);
        default:
          return OpcUaVariantValue.scalar(builtInType, valueText);
      }
    } catch (_) {
      return OpcUaVariantValue.scalar(builtInType, valueText);
    }
  }
}

/// 服务端地址空间：一组可自定义变量节点，外加固定的 Demo 根文件夹。
class OpcUaAddressSpace {
  OpcUaAddressSpace({List<OpcUaNode>? nodes}) : nodes = nodes ?? [];

  final List<OpcUaNode> nodes;

  OpcUaNode? findByNodeId(OpcUaNodeIdValue id) {
    for (final n in nodes) {
      if (_nodeIdEqual(n.nodeId, id)) return n;
    }
    return null;
  }

  void setValue(OpcUaNodeIdValue id, OpcUaVariantValue value) {
    final n = findByNodeId(id);
    if (n == null) return;
    n.valueText = _variantToText(value);
  }

  static bool _nodeIdEqual(OpcUaNodeIdValue a, OpcUaNodeIdValue b) {
    if (a is OpcUaNodeIdNumeric && b is OpcUaNodeIdNumeric) {
      return a.namespaceIndex == b.namespaceIndex && a.identifier == b.identifier;
    }
    if (a is OpcUaNodeIdString && b is OpcUaNodeIdString) {
      return a.namespaceIndex == b.namespaceIndex && a.identifier == b.identifier;
    }
    return false;
  }

  static String _variantToText(OpcUaVariantValue v) {
    if (v.value == null) return '';
    if (v.isArray) {
      return (v.value as List<Object?>).join(', ');
    }
    return v.value.toString();
  }
}

sealed class OpcUaServerEvent {}

class OpcUaServerStateEvent extends OpcUaServerEvent {
  OpcUaServerStateEvent(this.listening);
  final bool listening;
}

class OpcUaServerClientEvent extends OpcUaServerEvent {
  OpcUaServerClientEvent(this.clientId, this.address, this.connected);
  final String clientId;
  final String address;
  final bool connected;
}

class OpcUaServerDataEvent extends OpcUaServerEvent {
  OpcUaServerDataEvent(this.clientId, this.tx, this.bytes, this.note);
  final String clientId;
  final bool tx;
  final Uint8List bytes;
  final String? note;
}

class OpcUaServerErrorEvent extends OpcUaServerEvent {
  OpcUaServerErrorEvent(this.message);
  final String message;
}

/// OPC UA 服务端模拟（SecurityPolicy=None，匿名访问）。
///
/// 实现 HEL/ACK、OpenSecureChannel、CreateSession、ActivateSession、
/// Read、Write、Browse。地址空间由 [OpcUaAddressSpace] 提供（可自定义节点/数量）。
/// 复用了 `mcp_io_opcua` 导出的二进制编解码原语以保证与现有客户端的互通。
class OpcUaServer {
  OpcUaServer({OpcUaAddressSpace? addressSpace})
      : addressSpace = addressSpace ?? OpcUaAddressSpace();

  OpcUaAddressSpace addressSpace;

  final _events = StreamController<OpcUaServerEvent>.broadcast();
  Stream<OpcUaServerEvent> get events => _events.stream;

  ServerSocket? _server;
  String? _bindAddress;
  final _conns = <String, _Conn>{};
  var _channelSeq = 0;

  /// 当前监听端口（未监听时为 null）。
  int? get port => _server?.port;

  /// 当前监听网卡地址：null/空/'0.0.0.0' 表示全部接口。
  String get bindAddress => _bindAddress ?? '0.0.0.0';

  bool get listening => _server != null;

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
    _events.add(OpcUaServerStateEvent(true));
    _server!.listen(_onAccept, onError: (e) {
      _events.add(OpcUaServerErrorEvent('监听错误：$e'));
    });
  }

  void stop() {
    final snapshot = List.of(_conns.values);
    for (final c in snapshot) {
      try {
        c.socket.destroy();
      } catch (_) {
        // 忽略。
      }
    }
    _conns.clear();
    _server?.close();
    _server = null;
    _events.add(OpcUaServerStateEvent(false));
  }

  void dispose() {
    stop();
    _events.close();
  }

  int get clientCount => _conns.length;

  /// 当前已连接的客户端列表（供页面重新进入时恢复显示）。
  List<Map<String, String>> get clientList =>
      _conns.values
          .map((c) => {'id': c.id, 'address': c.address})
          .toList();

  void _onAccept(Socket socket) {
    final id =
        '${socket.remoteAddress.address}:${socket.remotePort}';
    final conn = _Conn(id, socket);
    _conns[id] = conn;
    _events.add(OpcUaServerClientEvent(id, conn.address, true));
    socket.listen(
      (data) {
        conn.buf.addAll(data);
        _drain(conn);
      },
      onDone: () {
        _removeConn(id);
      },
      onError: (e) {
        _events.add(OpcUaServerErrorEvent('连接 $id 出错：$e'));
        _removeConn(id);
      },
    );
  }

  void _removeConn(String id) {
    final c = _conns.remove(id);
    if (c != null) {
      try {
        c.socket.destroy();
      } catch (_) {
        // 忽略。
      }
      _events.add(OpcUaServerClientEvent(id, c.address, false));
    }
  }

  void _drain(_Conn conn) {
    while (conn.buf.length >= 8) {
      final type = String.fromCharCodes(conn.buf.sublist(0, 3));
      // HEL/ACK/ERR：8 字节头。
      if (type == 'HEL' || type == 'ACK' || type == 'ERR') {
        if (conn.buf.length < 8) return;
        final total = ByteData.sublistView(
                Uint8List.fromList(conn.buf.sublist(0, 8)))
            .getUint32(4, Endian.little);
        if (conn.buf.length < total) return;
        final frame = Uint8List.fromList(conn.buf.sublist(0, total));
        conn.buf.removeRange(0, total);
        _handleTransport(conn, frame);
        continue;
      }
      // OPN/MSG/CLO：12 字节头。
      if (conn.buf.length < 12) return;
      final total = ByteData.sublistView(
              Uint8List.fromList(conn.buf.sublist(0, 12)))
          .getUint32(4, Endian.little);
      if (conn.buf.length < total) return;
      final frame = Uint8List.fromList(conn.buf.sublist(0, total));
      conn.buf.removeRange(0, total);
      _handleSecure(conn, frame);
    }
  }

  void _handleTransport(_Conn conn, Uint8List frame) {
    final type = String.fromCharCodes(frame.sublist(0, 3));
    if (type == 'HEL') {
      // 回 ACK。
      final ack = OpcUaAcknowledgeMessage(
        receiveBufferSize: 65535,
        sendBufferSize: 65535,
        maxMessageSize: 16777216,
        maxChunkCount: 0,
      ).encode();
      _send(conn, ack);
      _events.add(OpcUaServerDataEvent(conn.id, true, ack, 'ACK'));
    }
    // ACK/ERR 来自客户端，忽略。
  }

  void _handleSecure(_Conn conn, Uint8List frame) {
    final parsed = OpcUaSecureChannelFrame.decode(frame);
    final reader = BinaryReader(parsed.body);
    if (parsed.type == OpcUaSecureMessageType.opn) {
      // body 开头为类型 NodeId，再是请求结构体。
      NodeIdCodec.decode(reader);
      final req = OpcUaOpenSecureChannelRequest.decode(reader);
      _handleOpn(conn, parsed, req);
      return;
    }
    if (parsed.type == OpcUaSecureMessageType.clo) {
      // body 开头为类型 NodeId，再是请求结构体。回一个 CLO 响应再关闭。
      NodeIdCodec.decode(reader);
      final ack = BinaryWriter();
      NodeIdCodec.encode(
        ack,
        const OpcUaNodeIdNumeric(
            namespaceIndex: 0, identifier: kOpcUaNodeIdCloseSecureChannelResponse),
      );
      OpcUaCloseSecureChannelResponse(
        header: OpcUaResponseHeader(
          timestamp: DateTime.now().toUtc(),
          requestHandle: 0,
        ),
      ).encode(ack);
      final framed = OpcUaSecureChannelFrame.encodeSymmetric(
        type: OpcUaSecureMessageType.clo,
        secureChannelId: conn.channelId,
        symmetric: OpcUaSymmetricSecurityHeader(tokenId: conn.tokenId),
        sequence: OpcUaSequenceHeader(
            sequenceNumber: 3, requestId: parsed.sequence.requestId),
        body: ack.takeBytes(),
      );
      _send(conn, framed);
      _removeConn(conn.id);
      return;
    }
    // MSG：body 开头为服务类型 NodeId。
    final typeId = NodeIdCodec.decode(reader);
    if (typeId is! OpcUaNodeIdNumeric) {
      _sendServiceError(conn, parsed, 0, 'unsupported type');
      return;
    }
    _handleMsg(conn, parsed, typeId.identifier, reader);
  }

  void _handleOpn(_Conn conn, OpcUaSecureChannelFrame parsed,
      OpcUaOpenSecureChannelRequest req) {
    _channelSeq++;
    final tokenId = _channelSeq;
    final channelId = _channelSeq;
    conn.channelId = channelId;
    conn.tokenId = tokenId;
    final resp = OpcUaOpenSecureChannelResponse(
      header: OpcUaResponseHeader(
        timestamp: DateTime.now().toUtc(),
        requestHandle: req.header.requestHandle,
      ),
      securityToken: OpcUaChannelSecurityToken(
        channelId: channelId,
        tokenId: tokenId,
        createdAt: DateTime.now().toUtc(),
        revisedLifetime: req.requestedLifetime,
      ),
    );
    final body = BinaryWriter();
    NodeIdCodec.encode(
      body,
      const OpcUaNodeIdNumeric(
          namespaceIndex: 0,
          identifier: kOpcUaNodeIdOpenSecureChannelResponse),
    );
    resp.encode(body);
    final out = OpcUaSecureChannelFrame.encodeOpn(
      secureChannelId: channelId,
      asymmetric:
          const OpcUaAsymmetricSecurityHeader(),
      sequence: OpcUaSequenceHeader(
          sequenceNumber: 1, requestId: parsed.sequence.requestId),
      body: body.takeBytes(),
    );
    _send(conn, out);
    _events.add(OpcUaServerDataEvent(
        conn.id, true, out, 'OpenSecureChannelResponse'));
  }

  void _handleMsg(_Conn conn, OpcUaSecureChannelFrame parsed, int numericId,
      BinaryReader reader) {
    late final String note;
    late final int respTypeId;
    late final void Function(BinaryWriter) encodeStruct;

    switch (numericId) {
      case kOpcUaNodeIdCreateSessionRequest:
        final req = OpcUaCreateSessionRequest.decode(reader);
        respTypeId = kOpcUaNodeIdCreateSessionResponse;
        conn.authToken = _makeSessionToken();
        encodeStruct = (w) => _encodeCreateSession(w, req, conn.authToken);
        note = 'CreateSessionResponse';
      case kOpcUaNodeIdActivateSessionRequest:
        final req = OpcUaActivateSessionRequest.decode(reader);
        respTypeId = kOpcUaNodeIdActivateSessionResponse;
        encodeStruct = (w) => _encodeActivateSession(w, req);
        note = 'ActivateSessionResponse';
      case kOpcUaNodeIdReadRequest:
        final req = OpcUaReadRequest.decode(reader);
        respTypeId = kOpcUaNodeIdReadResponse;
        encodeStruct = (w) => _encodeRead(w, req);
        note = 'ReadResponse ×${req.nodesToRead.length}';
      case kOpcUaNodeIdWriteRequest:
        final req = OpcUaWriteRequest.decode(reader);
        respTypeId = kOpcUaNodeIdWriteResponse;
        encodeStruct = (w) => _encodeWrite(w, req);
        note = 'WriteResponse ×${req.nodesToWrite.length}';
      case kOpcUaNodeIdBrowseRequest:
        final req = OpcUaBrowseRequest.decode(reader);
        respTypeId = kOpcUaNodeIdBrowseResponse;
        encodeStruct = (w) => _encodeBrowse(w, req);
        note = 'BrowseResponse ×${req.nodesToBrowse.length}';
      case kOpcUaNodeIdCloseSessionRequest:
        final req = OpcUaCloseSessionRequest.decode(reader);
        respTypeId = kOpcUaNodeIdCloseSessionResponse;
        encodeStruct = (w) => OpcUaCloseSessionResponse(
          header: OpcUaResponseHeader(
              timestamp: DateTime.now().toUtc(),
              requestHandle: req.header.requestHandle),
        ).encode(w);
        note = 'CloseSessionResponse';
      default:
        respTypeId = numericId + 3;
        encodeStruct = (w) => OpcUaResponseHeader(
          timestamp: DateTime.now().toUtc(),
          requestHandle: 0,
        ).encode(w);
        note = 'Unsupported service ($numericId)';
    }

    // MSG 帧 body：类型 NodeId + 响应结构体。
    final out = BinaryWriter();
    NodeIdCodec.encode(
      out,
      OpcUaNodeIdNumeric(namespaceIndex: 0, identifier: respTypeId),
    );
    encodeStruct(out);

    final framed = OpcUaSecureChannelFrame.encodeSymmetric(
      type: OpcUaSecureMessageType.msg,
      secureChannelId: conn.channelId,
      symmetric: OpcUaSymmetricSecurityHeader(tokenId: conn.tokenId),
      sequence: OpcUaSequenceHeader(
          sequenceNumber: 2, requestId: parsed.sequence.requestId),
      body: out.takeBytes(),
    );
    _send(conn, framed);
    _events.add(OpcUaServerDataEvent(conn.id, true, framed, note));
  }

  void _sendServiceError(_Conn conn, OpcUaSecureChannelFrame parsed,
      int requestHandle, String reason) {
    final body = BinaryWriter();
    NodeIdCodec.encode(
      body,
      const OpcUaNodeIdNumeric(
          namespaceIndex: 0, identifier: kOpcUaNodeIdReadResponse),
    );
    OpcUaResponseHeader(
      timestamp: DateTime.now().toUtc(),
      requestHandle: requestHandle,
      serviceResult: 0x80040000,
    ).encode(body);
    final framed = OpcUaSecureChannelFrame.encodeSymmetric(
      type: OpcUaSecureMessageType.msg,
      secureChannelId: conn.channelId,
      symmetric: OpcUaSymmetricSecurityHeader(tokenId: conn.tokenId),
      sequence: OpcUaSequenceHeader(
          sequenceNumber: 2, requestId: parsed.sequence.requestId),
      body: body.takeBytes(),
    );
    _send(conn, framed);
  }

  OpcUaNodeIdValue _makeSessionToken() =>
      OpcUaNodeIdNumeric(namespaceIndex: 1, identifier: 1001);

  void _encodeCreateSession(
      BinaryWriter w, OpcUaCreateSessionRequest req, OpcUaNodeIdValue token) {
    OpcUaCreateSessionResponse(
      header: OpcUaResponseHeader(
        timestamp: DateTime.now().toUtc(),
        requestHandle: req.header.requestHandle,
      ),
      sessionId:
          OpcUaNodeIdNumeric(namespaceIndex: 1, identifier: 5001),
      authenticationToken: token,
      revisedSessionTimeout: req.requestedSessionTimeout,
      serverNonce: Uint8List(16),
    ).encode(w);
  }

  void _encodeActivateSession(
      BinaryWriter w, OpcUaActivateSessionRequest req) {
    OpcUaActivateSessionResponse(
      header: OpcUaResponseHeader(
        timestamp: DateTime.now().toUtc(),
        requestHandle: req.header.requestHandle,
      ),
      serverNonce: Uint8List(16),
    ).encode(w);
  }

  void _encodeRead(BinaryWriter w, OpcUaReadRequest req) {
    final results = <OpcUaDataValue>[];
    for (final rv in req.nodesToRead) {
      final node = addressSpace.findByNodeId(rv.nodeId);
      if (node == null) {
        results.add(OpcUaDataValue(
          status: OpcUaStatusCode(0x80340000), // Bad_NodeIdUnknown
        ));
      } else {
        results.add(OpcUaDataValue(
          value: node.parseValue(),
          status: OpcUaStatusCode.good,
          serverTimestamp: DateTime.now().toUtc(),
        ));
      }
    }
    OpcUaReadResponse(
      header: OpcUaResponseHeader(
        timestamp: DateTime.now().toUtc(),
        requestHandle: req.header.requestHandle,
      ),
      results: results,
    ).encode(w);
  }

  void _encodeWrite(BinaryWriter w, OpcUaWriteRequest req) {
    final codes = <int>[];
    for (final wv in req.nodesToWrite) {
      if (wv.attributeId != OpcUaAttribute.value) {
        codes.add(0x80350000); // Bad_AttributeIdInvalid
        continue;
      }
      final node = addressSpace.findByNodeId(wv.nodeId);
      if (node == null) {
        codes.add(0x80340000); // Bad_NodeIdUnknown
        continue;
      }
      if (wv.value.value != null) {
        addressSpace.setValue(wv.nodeId, wv.value.value!);
      }
      codes.add(0); // Good
    }
    OpcUaWriteResponse(
      header: OpcUaResponseHeader(
        timestamp: DateTime.now().toUtc(),
        requestHandle: req.header.requestHandle,
      ),
      results: codes,
    ).encode(w);
  }

  void _encodeBrowse(BinaryWriter w, OpcUaBrowseRequest req) {
    final rows = <OpcUaBrowseResultRow>[];
    for (final bd in req.nodesToBrowse) {
      if (_nodeIdIsDemoRoot(bd.nodeId)) {
        final refs = <OpcUaReferenceDescriptionWire>[];
        for (final n in addressSpace.nodes) {
          refs.add(OpcUaReferenceDescriptionWire(
            referenceTypeId: const OpcUaNodeIdNumeric(
                namespaceIndex: 0, identifier: 35), // HasComponent
            isForward: true,
            nodeId: n.nodeId,
            browseName: OpcUaQualifiedName(
                namespaceIndex: n.namespaceIndex, name: n.name),
            displayName: OpcUaLocalizedText(text: n.name),
            nodeClass: OpcUaNodeClass.variable,
            typeDefinition: const OpcUaNodeIdNumeric(
                namespaceIndex: 0, identifier: 63), // BaseDataVariableType
          ));
        }
        rows.add(OpcUaBrowseResultRow(references: refs));
      } else {
        rows.add(OpcUaBrowseResultRow(
            statusCode: 0x80340000)); // Bad_NodeIdUnknown
      }
    }
    OpcUaBrowseResponse(
      header: OpcUaResponseHeader(
        timestamp: DateTime.now().toUtc(),
        requestHandle: req.header.requestHandle,
      ),
      results: rows,
    ).encode(w);
  }

  bool _nodeIdIsDemoRoot(OpcUaNodeIdValue id) {
    // 接受 Objects 文件夹或自定义 Demo 根；这里宽松匹配根查询。
    if (id is OpcUaNodeIdNumeric && id.namespaceIndex == 0) {
      return id.identifier == 85 || // Objects
          id.identifier == 0; // 也可从根开始
    }
    return false;
  }

  void _send(_Conn conn, Uint8List bytes) {
    try {
      conn.socket.add(bytes);
    } catch (_) {
      // 忽略发送失败。
    }
  }
}

class _Conn {
  _Conn(this.id, this.socket)
      : address = '${socket.remoteAddress.address}:${socket.remotePort}';

  final String id;
  final Socket socket;
  final String address;
  final buf = <int>[];

  int channelId = 0;
  int tokenId = 0;
  OpcUaNodeIdValue authToken =
      const OpcUaNodeIdNumeric(namespaceIndex: 0, identifier: 0);
}

/// 内置几个示例节点，供初次进入时使用（命名空间 2，挂在 Demo 根下）。
List<OpcUaNode> defaultOpcUaNodes() => [
      OpcUaNode(
        namespaceIndex: 2,
        identifier: '1',
        name: 'Temperature',
        builtInType: OpcUaBuiltInType.double_,
        valueText: '25.5',
      ),
      OpcUaNode(
        namespaceIndex: 2,
        identifier: '2',
        name: 'Pressure',
        builtInType: OpcUaBuiltInType.float,
        valueText: '101.3',
      ),
      OpcUaNode(
        namespaceIndex: 2,
        identifier: '3',
        name: 'Running',
        builtInType: OpcUaBuiltInType.boolean,
        valueText: 'true',
      ),
      OpcUaNode(
        namespaceIndex: 2,
        identifier: '4',
        name: 'DeviceName',
        builtInType: OpcUaBuiltInType.string,
        valueText: 'EverLink-Sim',
      ),
      OpcUaNode(
        namespaceIndex: 2,
        identifier: '5',
        name: 'Count',
        builtInType: OpcUaBuiltInType.int32,
        valueText: '123',
      ),
    ];
