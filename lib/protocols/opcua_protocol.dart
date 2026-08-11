import 'dart:async';
import 'dart:typed_data';

import 'package:mcp_io_opcua/io.dart';
import 'package:mcp_io_opcua/mcp_io_opcua.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/opcua_models.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/device_protocol.dart';
import 'package:everlink/services/data_point.dart';

/// OPC UA 协议实现（基于纯 Dart 的 [mcp_io_opcua] 包）。
///
/// OPC UA 采用有状态的会话：连接时需依次完成 Hello / OpenSecureChannel /
/// CreateSession / ActivateSession 握手；握手成功后即可对地址空间中的节点
/// 进行 Read / Write / Browse。断开时关闭底层 TCP 传输与帧泵。
///
/// MVP 阶段安全策略固定为 None（匿名连接）；用户名 / 密码鉴权为后续扩展点。
class OpcUaProtocol extends DeviceProtocol {
  OpcUaProtocol()
      : super(
          type: ProtocolType.opcUa,
          name: 'OPC UA',
          description: '工业设备地址空间浏览与变量读写',
        );

  OpcUaProtocolSession? _session;

  /// 请求串行化队列：保证任意时刻只有一个服务请求在链路上，消除“监控轮询读”
  /// 与“手动下发写 / 浏览”在共享单条 TCP 连接上并发时，服务端丢弃请求而触发
  /// 的 5s [TimeoutException]。
  Future<void> _requestQueue = Future.value();

  /// 把一次服务调用串行化执行（读 / 写 / 浏览共用），并在前序调用失败时不中断
  /// 后续调用（队列始终以完成态推进）。
  Future<T> _run<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _requestQueue = _requestQueue.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }, onError: (_, _) async {
      // 前序请求失败：保持队列存活，仍执行本次请求。
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  final StreamController<DeviceConnectionState> _stateController =
      StreamController<DeviceConnectionState>.broadcast();

  /// 原始链路报文流：每条记录是一次 TCP 收发的原始字节（方向 + 时间 + 内容）。
  /// UI 订阅此流即可呈现“报文”视图。注意这不是 pcap 抓包，仅记录本应用收发
  /// 的字节流；加密策略下记录的是链路密文。
  final StreamController<OpcUaTrafficRecord> _trafficController =
      StreamController<OpcUaTrafficRecord>.broadcast();

  /// 订阅原始报文流（多订阅者安全）。
  Stream<OpcUaTrafficRecord> get trafficStream => _trafficController.stream;

  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  @override
  String? lastError;

  @override
  DeviceConnectionState get connectionState => _state;

  @override
  Stream<DeviceConnectionState> get connectionStateStream =>
      _stateController.stream;

  @override
  bool get supportsRead => true;

  @override
  bool get supportsWrite => true;

  void _setState(DeviceConnectionState s, [String? error]) {
    _state = s;
    lastError = error;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  OpcUaProtocolSession _requireSession() {
    final s = _session;
    if (s == null || _state != DeviceConnectionState.connected) {
      throw StateError('OPC UA 未连接');
    }
    return s;
  }

  /// 把公开的 [OpcUaNodeId] 转换为底层请求需要的 [OpcUaNodeIdValue]。
  static OpcUaNodeIdValue _toValue(OpcUaNodeId id) {
    if (id.kind == OpcUaNodeIdKind.numeric) {
      return OpcUaNodeIdNumeric(
          namespaceIndex: id.namespace, identifier: id.numericId!);
    }
    return OpcUaNodeIdString(
        namespaceIndex: id.namespace, identifier: id.stringId!);
  }

  int _handle = 0;
  OpcUaRequestHeader _header() => OpcUaRequestHeader(
        authenticationToken: const OpcUaNodeIdNumeric(namespaceIndex: 0, identifier: 0),
        timestamp: DateTime.now(),
        requestHandle: ++_handle,
      );

  @override
  Future<void> connect(ConnectionConfig config) async {
    if (config is! OpcUaConnectionConfig) {
      throw ArgumentError('OpcUaProtocol 需要 OpcUaConnectionConfig');
    }
    // 能力降级检查：底层 mcp_io_opcua 0.2.1 仅完整实现 None 安全策略与匿名
    // 认证。签名策略（Basic256Sha256 / Basic128Rsa15）与用户名/证书登录在
    // 握手阶段尚未完成密钥派生/绑定与身份令牌下发，连接前明确拒绝，避免
    // 出现难以理解的底层异常。
    if (config.securityPolicy !=
        'http://opcfoundation.org/UA/SecurityPolicy#None') {
      throw UnsupportedError(
        '当前底层 mcp_io_opcua 0.2.1 仅完整支持 None 安全策略；签名策略'
        '（Basic256Sha256 等）需底层库完成 SecureChannel 密钥派生与绑定后方可'
        '连通真实服务端，敬请期待升级。',
      );
    }
    if (config.authMode != OpcUaAuthMode.anonymous) {
      throw UnsupportedError(
        '当前底层库仅实现匿名 ActivateSession；用户名/证书登录需底层库升级后开放。',
      );
    }
    _setState(DeviceConnectionState.connecting);
    try {
      final uri = Uri.parse(config.endpoint);
      if (uri.scheme != 'opc.tcp') {
        throw ArgumentError('OPC UA 端点必须以 opc.tcp:// 开头');
      }
      final base = TcpOpcUaByteTransport.fromEndpoint(uri);
      final transport = LoggingOpcUaByteTransport(
        base,
        (r) {
          if (!_trafficController.isClosed) _trafficController.add(r);
        },
      );
      _session = OpcUaProtocolSession(
        transport: transport,
        endpoint: uri,
        securityPolicy: const NoneSecurityPolicy(),
        clientDescription: const OpcUaApplicationDescription(
          applicationUri: 'urn:everlink:client',
          productUri: 'urn:everlink:product',
          applicationName: OpcUaLocalizedText(text: 'EverLink OPC UA Client'),
        ),
        // 工业 OPC UA 服务端偶有慢响应，5s 偏紧；放宽到 10s 避免误超时。
        defaultTimeout: const Duration(seconds: 10),
      );
      await _session!.open();
      await _session!.hello();
      await _session!.openSecureChannel();
      await _session!.createSession(sessionName: 'everlink-client');
      await _session!.activateSession();
      _setState(DeviceConnectionState.connected);
    } catch (e) {
      _setState(DeviceConnectionState.error, 'OPC UA 连接失败：$e');
      try {
        await _session?.close();
      } catch (_) {
        // 忽略关闭时的次级错误。
      }
      _session = null;
      rethrow;
    }
  }

  /// 读取单个节点的值（默认读取 Value 属性）。
  ///
  /// 通过 [_run] 串行化，避免与监控轮询的读 / 手动下发写 / 浏览在共享的
  /// 单条 TCP 连接上并发，导致服务端丢弃请求而触发 5s 超时。
  Future<OpcUaReadResult> read(String nodeId) {
    return _run(() async {
      final session = _requireSession();
      final node = _toValue(OpcUaNodeId.parse(nodeId));
      final req = OpcUaReadRequest(
        header: _header(),
        nodesToRead: [
          OpcUaReadValueId(nodeId: node, attributeId: OpcUaAttribute.value),
        ],
      );
      final resp = await session.read(req);
      if (resp.results.isEmpty) {
        throw StateError('OPC UA 读取返回空结果');
      }
      final dv = resp.results.first;
      final result = OpcUaReadResult(
        nodeId: nodeId,
        value: dv.value?.value,
        typeName: dv.value?.type.name ?? 'null',
        statusCode: dv.status?.value ?? 0,
        good: dv.status?.isGood ?? true,
        sourceTimestamp: dv.sourceTimestamp,
      );
      // 数值型结果作为标准化数据点广播，供记录仪(模块五)/可视化(模块九)消费。
      if (result.value is num) {
        DataPointBus.instance.emit(DataPoint(
          source: 'opcua',
          tag: nodeId,
          value: result.value as num,
          time: DateTime.now(),
        ));
      }
      return result;
    });
  }

  /// 向单个节点写入一个值（按 [type] 解析输入文本）。
  Future<void> write(String nodeId, OpcUaWriteType type, String raw) {
    return _run(() async {
      final session = _requireSession();
      final node = _toValue(OpcUaNodeId.parse(nodeId));
      final variant =
          OpcUaVariantValue(type: type.builtInType, value: type.parse(raw));
      final req = OpcUaWriteRequest(
        header: _header(),
        nodesToWrite: [
          OpcUaWriteValue(
            nodeId: node,
            attributeId: OpcUaAttribute.value,
            value: OpcUaDataValue(value: variant),
          ),
        ],
      );
      final resp = await session.write(req);
      for (final code in resp.results) {
        if (code != 0) {
          throw Exception('OPC UA 写入失败：状态码 0x${code.toRadixString(16)}');
        }
      }
    });
  }

  /// 浏览某个节点下的引用（子节点），返回可点击跳转的节点条目列表。
  ///
  /// 注意：方向固定为 [OpcUaBrowseDirection.forward]，只取“正向引用”（即本节点
  /// 的子节点）。库默认是 `both`，会把父节点也作为反向引用带回，导致浏览树里
  /// 出现循环 / 父子倒置，无法正常遍历。
  ///
  /// 通过 [_run] 串行化，避免与监控轮询读 / 手动下发写在共享连接上并发超时。
  Future<List<OpcUaNodeEntry>> browse(String nodeId) {
    return _run(() async {
      final session = _requireSession();
      final node = _toValue(OpcUaNodeId.parse(nodeId));
      final req = OpcUaBrowseRequest(
        header: _header(),
        view: OpcUaViewDescription.nullView(),
        nodesToBrowse: [
          OpcUaBrowseDescription(
            nodeId: node,
            browseDirection: OpcUaBrowseDirection.forward,
          ),
        ],
      );
      final resp = await session.browse(req);
      final out = <OpcUaNodeEntry>[];
      for (final row in resp.results) {
        for (final r in row.references) {
          out.add(OpcUaNodeEntry(
            nodeId: r.nodeId.toString(),
            browseName: r.browseName.name,
            displayName: r.displayName.text ?? r.browseName.name,
            nodeClass: r.nodeClass,
          ));
        }
      }
      return out;
    });
  }

  @override
  Future<void> disconnect() async {
    try {
      await _session?.close();
    } catch (_) {
      // 忽略关闭时的次级错误。
    }
    _session = null;
    _setState(DeviceConnectionState.disconnected);
  }

  @override
  void dispose() {
    _stateController.close();
    if (!_trafficController.isClosed) _trafficController.close();
    try {
      _session?.close();
    } catch (_) {
      // 忽略关闭时的次级错误。
    }
    _session = null;
  }
}

/// 包裹一个 [OpcUaByteTransport]，在收发字节时记录原始报文到回调，再把字节
/// 透传给被包裹的传输。用于 OPC UA “报文”视图——记录本应用经 TCP 实际收发的
/// 字节流（None 策略下为明文 OPC UA 二进制，加密策略下为密文）。
///
/// 注意：OS 读缓冲区返回的字节块不保证与完整帧对齐，本类只做“原始字节”
/// 记录，不做帧解析；帧解析仍由上层协议会话负责。
class LoggingOpcUaByteTransport implements OpcUaByteTransport {
  LoggingOpcUaByteTransport(this._inner, this.onRecord);

  final OpcUaByteTransport _inner;
  final void Function(OpcUaTrafficRecord record) onRecord;

  final StreamController<Uint8List> _rxCtrl =
      StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _rxSub;
  bool _closed = false;

  @override
  Future<void> open() async {
    await _inner.open();
    _rxSub = _inner.incoming.listen(
      (chunk) {
        onRecord(OpcUaTrafficRecord(
          direction: OpcUaTrafficDirection.rx,
          bytes: Uint8List.fromList(chunk),
          time: DateTime.now(),
        ));
        if (!_rxCtrl.isClosed) _rxCtrl.add(chunk);
      },
      onError: (Object e, StackTrace st) {
        if (!_rxCtrl.isClosed) _rxCtrl.addError(e, st);
      },
      onDone: () {
        if (!_closed) {
          _closed = true;
          if (!_rxCtrl.isClosed) _rxCtrl.close();
        }
      },
    );
  }

  @override
  Future<void> send(List<int> bytes) async {
    onRecord(OpcUaTrafficRecord(
      direction: OpcUaTrafficDirection.tx,
      bytes: Uint8List.fromList(bytes),
      time: DateTime.now(),
    ));
    await _inner.send(bytes);
  }

  @override
  Stream<Uint8List> get incoming => _rxCtrl.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _rxSub?.cancel();
    try {
      await _inner.close();
    } catch (_) {
      // 底层关闭失败不影响上层清理。
    }
    if (!_rxCtrl.isClosed) await _rxCtrl.close();
  }
}
