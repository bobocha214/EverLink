import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:everlink/services/tcp_server.dart';
import 'package:everlink/services/server_registry.dart';
import 'package:everlink/ui/widgets/byte_log_list.dart';
import 'package:everlink/utils/byte_codec.dart';

/// TCP 服务端模拟页：监听端口、接受多客户端、广播/定向收发。
class TcpServerPage extends StatefulWidget {
  const TcpServerPage({super.key});

  @override
  State<TcpServerPage> createState() => _TcpServerPageState();
}

class _TcpServerPageState extends State<TcpServerPage> {
  final _portCtl = TextEditingController(text: '8080');
  final _sendCtl = TextEditingController();
  final _log = <ByteLogEntry>[];
  final _clients = <Map<String, String>>[];

  late final TcpServer _server;
  StreamSubscription<TcpServerEvent>? _sub;

  bool _listening = false;
  bool _busy = false;
  bool _showHex = true;
  bool _hexMode = false;
  bool _forward = false;
  String _checksum = 'none';
  String? _target; // null = 广播
  String _ip = '0.0.0.0'; // 监听网卡；0.0.0.0 = 全部接口
  List<String> _ipOptions = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    // 使用常驻单例：退出页面不会停止服务，可后台运行。
    _server = ServerRegistry.instance.tcp;
    // 恢复服务当前的转发开关（单例可能已在运行中）。
    _forward = _server.forwardToOthers;
    _sub = _server.events.listen(_onEvent);
    TcpServer.localAddresses().then((list) {
      if (!mounted) return;
      setState(() {
        _ipOptions = list;
        // 若服务正以具体 IP 监听，确保该 IP 出现在下拉选项中。
        if (_listening && _ip != '0.0.0.0' && !list.contains(_ip)) {
          _ipOptions = [...list, _ip];
        }
      });
    });
    // 服务可能在本页之前已在后台运行，恢复运行态与端口/IP/客户端。
    if (_server.isListening) {
      _listening = true;
      final p = _server.port;
      if (p != null) _portCtl.text = p.toString();
      _ip = _server.bindAddress;
      _clients
        ..clear()
        ..addAll(_server.clientList);
    }
  }

  void _onEvent(TcpServerEvent e) {
    if (!mounted) return;
    if (e is TcpServerStateEvent) {
      setState(() {
        _listening = e.listening;
        _busy = false;
        if (e.listening) _error = null;
      });
    } else if (e is TcpServerClientEvent) {
      setState(() {
        if (e.connected) {
          _clients.add({'id': e.clientId, 'address': e.address});
        } else {
          _clients.removeWhere((c) => c['id'] == e.clientId);
          if (_target == e.clientId) _target = null;
        }
      });
    } else if (e is TcpServerDataEvent) {
      // TX 由 _send 本地记录（含校验信息），这里只记录客户端发来的 RX。
      if (!e.tx) setState(() => _log.insert(0, _toEntry(e)));
    } else if (e is TcpServerErrorEvent) {
      setState(() => _error = e.message);
    }
  }

  ByteLogEntry _toEntry(TcpServerDataEvent e) {
    final csLen = checksumLen(_checksum);
    String? label;
    Uint8List? csBytes;
    bool? valid;
    if (!e.tx && csLen > 0 && e.bytes.length > csLen) {
      final payload = e.bytes.sublist(0, e.bytes.length - csLen);
      final cs = e.bytes.sublist(e.bytes.length - csLen);
      if (bytesEqual(computeChecksum(payload, _checksum), cs)) {
        label = checksumShortLabel(_checksum);
        csBytes = cs;
        valid = true;
      }
    }
    return ByteLogEntry(
      tx: e.tx,
      bytes: e.bytes,
      time: DateTime.now(),
      checksumLabel: label,
      checksumBytes: csBytes,
      valid: valid,
    );
  }

  Future<void> _toggle() async {
    if (_listening) {
      _server.stop();
      setState(() => _log.clear());
      return;
    }
    final port = int.tryParse(_portCtl.text.trim());
    if (port == null || port <= 0 || port > 65535) {
      setState(() => _error = '请填写合法端口（1-65535）');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await _server.start(port, bindAddress: _ip == '0.0.0.0' ? null : _ip);
  }

  void _send() {
    final raw = _sendCtl.text;
    if (raw.trim().isEmpty) return;
    Uint8List bytes;
    if (_hexMode) {
      final parsed = parseHex(raw);
      if (parsed == null) {
        setState(() => _error = 'Hex 模式：需为偶数个合法十六进制字符');
        return;
      }
      bytes = parsed;
    } else {
      bytes = Uint8List.fromList(utf8.encode(raw));
    }
    String? csLabel;
    Uint8List? csBytes;
    if (_checksum != 'none') {
      final cs = computeChecksum(bytes, _checksum);
      csLabel = checksumShortLabel(_checksum);
      csBytes = cs;
      bytes = Uint8List.fromList(bytes + cs);
    }
    if (_target == null) {
      _server.broadcast(bytes);
    } else {
      _server.sendTo(_target!, bytes);
    }
    // TX 本地记录（含校验标识）；RX 由事件流记录。
    setState(() => _log.insert(
          0,
          ByteLogEntry(
            tx: true,
            bytes: bytes,
            time: DateTime.now(),
            checksumLabel: csLabel,
            checksumBytes: csBytes,
          )));
    _sendCtl.clear();
  }

  @override
  void dispose() {
    // 仅取消订阅，不销毁服务：保持后台运行，下次进入可恢复。
    _sub?.cancel();
    _portCtl.dispose();
    _sendCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _listening ? Colors.green : Colors.grey;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('TCP 服务端')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _portCtl,
                          enabled: !_listening,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '监听端口',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Row(
                        children: [
                          Icon(Icons.circle, size: 10, color: color),
                          const SizedBox(width: 6),
                          Text(_listening ? '监听中' : '已停止',
                              style: TextStyle(color: color, fontSize: 13)),
                        ],
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _busy ? null : _toggle,
                        icon: _busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Icon(_listening ? Icons.stop : Icons.play_arrow),
                        label: Text(_listening ? '停止' : '启动'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text('监听 IP', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _ip,
                          isDense: true,
                          disabledHint: const Text('监听中…'),
                          items: [
                            const DropdownMenuItem(
                                value: '0.0.0.0',
                                child: Text('全部接口 (0.0.0.0)')),
                            for (final a in _ipOptions)
                              DropdownMenuItem(value: a, child: Text(a)),
                          ],
                          onChanged: _listening
                              ? null
                              : (v) => setState(() => _ip = v ?? '0.0.0.0'),
                        ),
                      ),
                    ],
                  ),
                  if (_listening)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _ip == '0.0.0.0'
                            ? '已监听全部接口，客户端可连接本机任一 IP'
                            : '连接地址：$_ip:${_portCtl.text.trim()}',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Switch(
                        value: _forward,
                        onChanged: (v) {
                          setState(() => _forward = v);
                          // 同步到运行中的服务（单例常驻，切换即时生效）。
                          _server.forwardToOthers = v;
                        },
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      const Text('收到数据转发给其他客户端',
                          style: TextStyle(fontSize: 13)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('已连接客户端：${_clients.length}',
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                  if (_clients.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final c in _clients)
                            Chip(
                              avatar: const Icon(Icons.computer, size: 16),
                              label: Text('${c['id']} · ${c['address']}'),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _sendCtl,
                          enabled: _listening,
                          decoration: InputDecoration(
                            labelText: '发送内容',
                            hintText: _hexMode ? '十六进制，如 01 03 00 00 00 01'
                                : '文本内容',
                            isDense: true,
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(_hexMode ? Icons.hexagon : Icons.text_fields),
                        tooltip: _hexMode ? '切换为文本模式' : '切换为 Hex 模式',
                        onPressed: () => setState(() => _hexMode = !_hexMode),
                      ),
                      FilledButton(
                        onPressed: _listening ? _send : null,
                        child: const Text('发送'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('目标', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButton<String?>(
                          value: _target,
                          isExpanded: true,
                          isDense: true,
                          hint: const Text('广播（全部）'),
                          items: [
                            const DropdownMenuItem(
                                value: null, child: Text('广播（全部）')),
                            for (final c in _clients)
                              DropdownMenuItem(
                                  value: c['id'],
                                  child: Text('${c['id']} · ${c['address']}')),
                          ],
                          onChanged: (v) => setState(() => _target = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text('附加校验', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 8),
                      DropdownButton<String>(
                        value: _checksum,
                        isDense: true,
                        items: const [
                          DropdownMenuItem(value: 'none', child: Text('无')),
                          DropdownMenuItem(
                              value: 'crc16', child: Text('CRC16-Modbus')),
                          DropdownMenuItem(
                              value: 'sum', child: Text('累加和 (8位)')),
                          DropdownMenuItem(
                              value: 'xor', child: Text('异或 (8位)')),
                        ],
                        onChanged: (v) =>
                            setState(() => _checksum = v ?? 'none'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                      '发送模式：${_hexMode ? 'Hex（十六进制）' : '文本（UTF-8）'}',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('HEX')),
                  ButtonSegment(value: false, label: Text('ASCII')),
                ],
                selected: {_showHex},
                onSelectionChanged: (s) =>
                    setState(() => _showHex = s.first),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 8),
          ByteLogList(
            entries: _log,
            showHex: _showHex,
            onClear: () => setState(() => _log.clear()),
          ),
        ],
      ),
    );
  }
}
