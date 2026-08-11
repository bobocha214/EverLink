import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/device_protocol.dart';

/// 一次 HTTP 请求的响应结果。
class HttpResponseModel {
  HttpResponseModel({
    required this.statusCode,
    this.statusText,
    required this.headers,
    required this.body,
    required this.bytes,
    required this.elapsed,
  });

  /// HTTP 状态码（如 200、404）。
  final int statusCode;

  /// 状态行原因短语（如 OK、Not Found），可能为空。
  final String? statusText;

  /// 响应头（名称 -> 值，已合并同名头）。
  final Map<String, String> headers;

  /// 响应体文本（二进制内容按 latin1 解码，便于展示）。
  final String body;

  /// 原始响应字节。
  final List<int> bytes;

  /// 请求耗时。
  final Duration elapsed;

  /// 是否为疑似二进制响应（依据 Content-Type）。
  bool get isBinary {
    final ct = headers['content-type'] ?? headers['Content-Type'] ?? '';
    return !ct.startsWith('text/') &&
        !ct.contains('json') &&
        !ct.contains('xml') &&
        !ct.contains('html') &&
        bytes.isNotEmpty;
  }
}

/// HTTP 协议实现。
///
/// 基于 [dart:io] 的 [HttpClient] 封装。HTTP 是无状态的请求 / 响应协议，没有
/// 持久的“连接”概念；这里把“连接”实现为一次可达性探针（HEAD 请求），
/// 而真正的读写通过 [request] 发起任意方法（GET / POST / ...）的请求。
class HttpProtocol extends DeviceProtocol {
  HttpProtocol()
      : super(
          type: ProtocolType.http,
          name: 'HTTP',
          description: 'REST / HTTP 端点请求调试，支持 GET/POST/PUT/DELETE 等。',
        );

  HttpConnectionConfig? _config;

  final StreamController<DeviceConnectionState> _stateController =
      StreamController<DeviceConnectionState>.broadcast();

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

  void _setState(DeviceConnectionState state, [String? error]) {
    _state = state;
    lastError = error;
    _stateController.add(state);
  }

  @override
  Future<void> connect(ConnectionConfig config) async {
    if (config is! HttpConnectionConfig) {
      throw ArgumentError('HttpProtocol 需要 HttpConnectionConfig');
    }
    _config = config;
    _setState(DeviceConnectionState.connecting);
    try {
      final resp = await _rawRequest('HEAD', '', {}, null);
      // 2xx/3xx 视为可达；4xx/5xx 视为端点存在但探针受限，仍记为已连接。
      _setState(DeviceConnectionState.connected);
      if (resp.statusCode >= 400) {
        lastError = '探针返回 HTTP ${resp.statusCode}';
      } else {
        lastError = null;
      }
    } catch (e) {
      _setState(DeviceConnectionState.error, e.toString());
      rethrow;
    }
  }

  /// 发起一次 HTTP 请求。
  ///
  /// [path] 为相对路径（可为空），会与配置中的 [HttpConnectionConfig.baseUrl]
  /// 拼接；[headers] 会与默认请求头合并（同名覆盖）。返回响应模型。
  Future<HttpResponseModel> request({
    required String method,
    String path = '',
    Map<String, String>? headers,
    String? body,
  }) async {
    if (_config == null) throw StateError('HTTP 未配置，请先连接');
    return _rawRequest(method.toUpperCase(), path, headers ?? {}, body);
  }

  Future<HttpResponseModel> _rawRequest(
    String method,
    String path,
    Map<String, String> headers,
    String? body,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = _config!.timeout;
    final sw = Stopwatch()..start();
    try {
      final uri = Uri.parse(_joinUrl(_config!.baseUrl, path));
      final req = await client.openUrl(method, uri);
      final merged = <String, String>{
        ...?_config!.defaultHeaders,
        ...headers,
      };
      merged.forEach((k, v) => req.headers.set(k, v));
      if (body != null && body.isNotEmpty) {
        req.write(body);
      }
      final resp = await req.close();
      final bytes = <int>[];
      await for (final chunk in resp) {
        bytes.addAll(chunk);
      }
      sw.stop();
      final bodyText = _decodeBody(bytes, resp.headers.contentType);
      return HttpResponseModel(
        statusCode: resp.statusCode,
        statusText: resp.reasonPhrase,
        headers: _headersToMap(resp.headers),
        body: bodyText,
        bytes: bytes,
        elapsed: sw.elapsed,
      );
    } finally {
      client.close(force: true);
      sw.stop();
    }
  }

  String _decodeBody(List<int> bytes, ContentType? contentType) {
    if (bytes.isEmpty) return '';
    // 文本类直接 UTF-8 解码；其余用 latin1 保留原始字节，便于展示。
    final ct = contentType?.value.toLowerCase() ?? '';
    if (ct.contains('charset=utf-8') ||
        ct.contains('json') ||
        ct.contains('xml') ||
        ct.contains('html') ||
        ct.startsWith('text/')) {
      try {
        return utf8.decode(bytes);
      } catch (_) {
        return latin1.decode(bytes);
      }
    }
    return latin1.decode(bytes);
  }

  Map<String, String> _headersToMap(HttpHeaders headers) {
    final map = <String, String>{};
    headers.forEach((name, values) {
      map[name] = values.join(', ');
    });
    return map;
  }

  String _joinUrl(String base, String path) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    if (path.isEmpty) return b;
    final p = path.startsWith('/') ? path : '/$path';
    return '$b$p';
  }

  @override
  Future<void> disconnect() async {
    _setState(DeviceConnectionState.disconnected);
  }

  @override
  void dispose() {
    _stateController.close();
  }
}
