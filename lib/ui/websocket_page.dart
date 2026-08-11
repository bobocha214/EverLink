import 'dart:async';

import 'package:flutter/material.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/device_session.dart';
import 'package:everlink/protocols/websocket_protocol.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/ui/widgets/connection_panel.dart';

/// WebSocket 调试页：连接服务端、收发文本消息，并把收发过程沉淀到历史。
class WebSocketPage extends StatefulWidget {
  const WebSocketPage({super.key, required this.session});

  final DeviceSession session;

  @override
  State<WebSocketPage> createState() => _WebSocketPageState();
}

class _WebSocketPageState extends State<WebSocketPage> {
  late final ConnectionManager _manager;
  final _urlCtl = TextEditingController();
  final _protoCtl = TextEditingController();
  final _sendCtl = TextEditingController();
  final List<WsMessageRecord> _messages = [];
  String? _error;
  StreamSubscription<WsMessageRecord>? _sub;

  @override
  void initState() {
    super.initState();
    final c = widget.session.config as WebSocketConnectionConfig;
    _urlCtl.text = c.url;
    _protoCtl.text = c.protocols?.join(', ') ?? '';
    _manager = SessionManager.instance.ensureManager(widget.session);
    _manager.addListener(_onManagerChanged);
    _sub = (_manager.protocol as WebSocketProtocol).messageStream.listen((m) {
      setState(() => _messages.insert(0, m));
      if (!m.outgoing) {
        HistoryService.instance.add(
          HistoryRecord(
            time: m.time,
            type: widget.session.type,
            deviceName: widget.session.name,
            op: HistoryOp.receive,
            success: true,
            summary: '收到消息',
            detail: m.isBinary ? '(二进制 ${m.data.length} 字符 base64)' : m.data,
          ),
        );
      }
    });
  }

  void _onManagerChanged() {
    if (mounted) setState(() {});
  }

  void _syncConfigFromFields() {
    final cfg = WebSocketConnectionConfig(
      url: _urlCtl.text.trim(),
      protocols: _protoCtl.text
          .split(RegExp(r'[,\s]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
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

  void _send() {
    final text = _sendCtl.text;
    if (text.isEmpty) return;
    try {
      (_manager.protocol as WebSocketProtocol).send(text);
      _sendCtl.clear();
      setState(() => _error = null);
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.publish,
          success: true,
          summary: '发送消息',
          detail: text,
        ),
      );
    } catch (e) {
      setState(() => _error = e.toString());
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
          _buildSendCard(connected),
          const SizedBox(height: 12),
          _buildMessagesCard(),
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
            const Text('连接配置', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _urlCtl,
              decoration: const InputDecoration(
                labelText: 'WebSocket 地址',
                hintText: 'ws://host:port/path 或 wss://...',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _protoCtl,
              decoration: const InputDecoration(
                labelText: '子协议（可选，逗号分隔）',
                hintText: '如 chat, superchat',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSendCard(bool connected) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('发送消息', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sendCtl,
                    decoration: const InputDecoration(
                      labelText: '消息内容',
                      hintText: '输入文本后回车或点发送',
                    ),
                    onSubmitted: connected ? (_) => _send() : null,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: connected ? _send : null,
                  icon: const Icon(Icons.send),
                  label: const Text('发送'),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessagesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('消息 (${_messages.length})',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_messages.isEmpty)
              const Text('连接并发送消息后，收发记录会显示在这里',
                  style: TextStyle(color: Colors.grey)),
            ..._messages.map((m) => _MessageTile(record: m)),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _manager.removeListener(_onManagerChanged);
    _urlCtl.dispose();
    _protoCtl.dispose();
    _sendCtl.dispose();
    super.dispose();
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.record});

  final WsMessageRecord record;

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay.fromDateTime(record.time).format(context);
    final color = record.outgoing ? Colors.blue : Colors.teal;
    final prefix = record.outgoing ? '发出' : '收到';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(record.outgoing ? Icons.north_east : Icons.south_west,
                  size: 14, color: color),
              const SizedBox(width: 4),
              Text(prefix, style: TextStyle(color: color, fontSize: 12)),
              if (record.isBinary)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Text('(二进制)', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
              const Spacer(),
              Text(time, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(record.data,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
        ],
      ),
    );
  }
}
