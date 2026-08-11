import 'package:flutter/material.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/device_session.dart';
import 'package:everlink/protocols/http_protocol.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/ui/widgets/connection_panel.dart';

/// HTTP 调试页：连接（可达性探针）后，构造任意方法的请求并查看响应。
class HttpPage extends StatefulWidget {
  const HttpPage({super.key, required this.session});

  final DeviceSession session;

  @override
  State<HttpPage> createState() => _HttpPageState();
}

class _HttpPageState extends State<HttpPage> {
  late final ConnectionManager _manager;
  final _baseUrlCtl = TextEditingController();
  final _timeoutCtl = TextEditingController(text: '8');
  final _defaultHeadersCtl = TextEditingController();
  final _pathCtl = TextEditingController(text: '/');
  final _headersCtl = TextEditingController();
  final _bodyCtl = TextEditingController();
  String _method = 'GET';
  HttpResponseModel? _response;
  String? _error;
  bool _busy = false;

  static const List<String> _methods = [
    'GET',
    'POST',
    'PUT',
    'DELETE',
    'PATCH',
    'HEAD',
    'OPTIONS',
  ];

  @override
  void initState() {
    super.initState();
    final c = widget.session.config as HttpConnectionConfig;
    _baseUrlCtl.text = c.baseUrl;
    _timeoutCtl.text = '${c.timeout.inSeconds}';
    _defaultHeadersCtl.text = _formatHeaders(c.defaultHeaders);
    _manager = SessionManager.instance.ensureManager(widget.session);
    _manager.addListener(_onManagerChanged);
  }

  void _onManagerChanged() {
    if (mounted) setState(() {});
  }

  void _syncConfigFromFields() {
    final cfg = HttpConnectionConfig(
      baseUrl: _baseUrlCtl.text.trim(),
      timeout: Duration(seconds: int.tryParse(_timeoutCtl.text) ?? 8),
      defaultHeaders: _parseHeaders(_defaultHeadersCtl.text),
    );
    _manager.updateConfig(cfg);
    widget.session.config = cfg;
  }

  Future<void> _connect() async {
    _syncConfigFromFields();
    try {
      await _manager.connect();
      final ok = _manager.state == DeviceConnectionState.connected;
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.connect,
          success: ok,
          summary: ok
              ? '连接成功：${widget.session.name}'
              : '连接失败：${widget.session.name}',
          error: ok ? null : _manager.lastError,
        ),
      );
    } catch (e) {
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.connect,
          success: false,
          summary: '连接失败：${widget.session.name}',
          error: e.toString(),
        ),
      );
    }
  }

  Future<void> _disconnect() async {
    await _manager.disconnect();
    HistoryService.instance.add(
      HistoryRecord(
        time: DateTime.now(),
        type: widget.session.type,
        deviceName: widget.session.name,
        op: HistoryOp.disconnect,
        success: true,
        summary: '断开连接：${widget.session.name}',
      ),
    );
  }

  Map<String, String>? _parseHeaders(String raw) {
    final map = <String, String>{};
    for (final line in raw.split('\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final k = line.substring(0, idx).trim();
      final v = line.substring(idx + 1).trim();
      if (k.isNotEmpty) map[k] = v;
    }
    return map.isEmpty ? null : map;
  }

  String _formatHeaders(Map<String, String>? headers) {
    if (headers == null) return '';
    return headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  }

  Future<void> _send() async {
    _syncConfigFromFields();
    setState(() {
      _busy = true;
      _error = null;
      _response = null;
    });
    final isWrite = _method != 'GET' && _method != 'HEAD' && _method != 'OPTIONS';
    try {
      final resp = await (_manager.protocol as HttpProtocol).request(
        method: _method,
        path: _pathCtl.text.trim(),
        headers: _parseHeaders(_headersCtl.text),
        body: _bodyCtl.text,
      );
      setState(() => _response = resp);
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: isWrite ? HistoryOp.write : HistoryOp.read,
          success: resp.statusCode < 400,
          summary: '$_method 请求 ${_pathCtl.text.trim()} → ${resp.statusCode}',
          detail:
              '耗时 ${resp.elapsed.inMilliseconds} ms\n\n${resp.body}',
          error: resp.statusCode >= 400 ? 'HTTP ${resp.statusCode}' : null,
        ),
      );
    } catch (e) {
      setState(() => _error = e.toString());
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: isWrite ? HistoryOp.write : HistoryOp.read,
          success: false,
          summary: '$_method 请求失败',
          error: e.toString(),
        ),
      );
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _manager.state == DeviceConnectionState.connected;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.name),
        actions: [
          IconButton(
            icon: Icon(connected ? Icons.link_off : Icons.link),
            tooltip: connected ? '断开' : '连接',
            onPressed: _manager.state == DeviceConnectionState.connecting
                ? null
                : (connected ? _disconnect : _connect),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ConnectionPanel(manager: _manager, onConnectPressed: _connect),
          const SizedBox(height: 12),
          _buildConfigCard(),
          const SizedBox(height: 12),
          _buildRequestCard(),
          const SizedBox(height: 12),
          _buildResponseCard(),
        ],
      ),
    );
  }

  Widget _buildConfigCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('端点配置', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _baseUrlCtl,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://api.example.com',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _timeoutCtl,
                    decoration: const InputDecoration(labelText: '超时(秒)'),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _defaultHeadersCtl,
              decoration: const InputDecoration(
                labelText: '默认请求头（可选，每行 Key: Value）',
                alignLabelWithHint: true,
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequestCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('构造请求', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                DropdownButton<String>(
                  value: _method,
                  items: _methods
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setState(() => _method = v!),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _pathCtl,
                    decoration: const InputDecoration(labelText: '路径'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _headersCtl,
              decoration: const InputDecoration(
                labelText: '本次请求头（可选，每行 Key: Value）',
                alignLabelWithHint: true,
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _bodyCtl,
              decoration: const InputDecoration(
                labelText: '请求体（可选，如 JSON）',
                alignLabelWithHint: true,
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _send,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    label: Text(_busy ? '请求中' : '发送请求'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResponseCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('响应', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_busy)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              )
            else if (_response == null)
              const Text('点击“发送请求”查看响应', style: TextStyle(color: Colors.grey))
            else
              _ResponseView(response: _response!),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerChanged);
    _baseUrlCtl.dispose();
    _timeoutCtl.dispose();
    _defaultHeadersCtl.dispose();
    _pathCtl.dispose();
    _headersCtl.dispose();
    _bodyCtl.dispose();
    super.dispose();
  }
}

class _ResponseView extends StatelessWidget {
  const _ResponseView({required this.response});

  final HttpResponseModel response;

  @override
  Widget build(BuildContext context) {
    final code = response.statusCode;
    final ok = code < 400;
    final codeColor = ok ? Colors.green : Colors.red;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: codeColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('$code',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: codeColor, fontSize: 16)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(response.statusText ?? '',
                  style: const TextStyle(color: Colors.grey)),
            ),
            Text('${response.elapsed.inMilliseconds} ms',
                style: const TextStyle(color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 8),
        const Text('响应头',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        ...response.headers.entries.map(
          (e) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: SelectableText('${e.key}: ${e.value}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ),
        const SizedBox(height: 8),
        const Text('响应体',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(
            response.body.isEmpty ? '(空)' : response.body,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
      ],
    );
  }
}
