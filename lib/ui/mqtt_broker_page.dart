import 'dart:async';

import 'package:flutter/material.dart';

import 'package:everlink/services/mqtt_broker.dart';
import 'package:everlink/services/server_registry.dart';
import 'package:everlink/services/tcp_server.dart';
import 'package:everlink/ui/widgets/byte_log_list.dart';

/// 本地 MQTT Broker 模拟页：监听端口、接受客户端连接、转发消息、retained。
class MqttBrokerPage extends StatefulWidget {
  const MqttBrokerPage({super.key});

  @override
  State<MqttBrokerPage> createState() => _MqttBrokerPageState();
}

class _MqttBrokerPageState extends State<MqttBrokerPage> {
  final _portCtl = TextEditingController(text: '1883');
  final _log = <ByteLogEntry>[];
  final _clients = <Map<String, String>>[];

  late final MqttBroker _broker;
  StreamSubscription<MqttBrokerEvent>? _sub;

  bool _listening = false;
  bool _busy = false;
  String _ip = '0.0.0.0'; // 监听网卡；0.0.0.0 = 全部接口
  List<String> _ipOptions = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    // 使用常驻单例：退出页面不会停止服务，可后台运行。
    _broker = ServerRegistry.instance.broker;
    _sub = _broker.events.listen(_onEvent);
    TcpServer.localAddresses().then((list) {
      if (!mounted) return;
      setState(() {
        _ipOptions = list;
        if (_listening && _ip != '0.0.0.0' && !list.contains(_ip)) {
          _ipOptions = [...list, _ip];
        }
      });
    });
    // 服务可能在本页之前已在后台运行，恢复运行态与端口/IP/客户端。
    if (_broker.listening) {
      _listening = true;
      final p = _broker.port;
      if (p != null) _portCtl.text = p.toString();
      _ip = _broker.bindAddress;
      _clients
        ..clear()
        ..addAll(_broker.clientList);
    }
  }

  void _onEvent(MqttBrokerEvent e) {
    if (!mounted) return;
    if (e is MqttBrokerStateEvent) {
      setState(() {
        _listening = e.listening;
        _busy = false;
        if (e.listening) _error = null;
      });
    } else if (e is MqttBrokerClientEvent) {
      setState(() {
        if (e.connected) {
          _clients.add({'id': e.clientId, 'address': e.address});
        } else {
          _clients.removeWhere((c) => c['id'] == e.clientId);
        }
      });
    } else if (e is MqttBrokerDataEvent) {
      setState(() => _log.insert(
            0,
            ByteLogEntry(
              tx: e.tx,
              bytes: e.bytes,
              time: DateTime.now(),
              note: e.note,
            ),
          ));
    } else if (e is MqttBrokerErrorEvent) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _toggle() async {
    if (_listening) {
      _broker.stop();
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
    try {
      await _broker.start(port, bindAddress: _ip == '0.0.0.0' ? null : _ip);
    } catch (ex) {
      setState(() {
        _busy = false;
        _error = '启动失败：$ex';
      });
    }
  }

  @override
  void dispose() {
    // 仅取消订阅，不销毁服务：保持后台运行，下次进入可恢复。
    _sub?.cancel();
    _portCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _listening ? Colors.green : Colors.grey;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('MQTT Broker')),
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
                              label: Text(c['address']!),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                      '支持 MQTT 3.1.1：CONNECT/SUBSCRIBE/PUBLISH/UNSUBSCRIBE/'
                      'PINGREQ，通配符 + / #，Retained 消息，QoS0/1。',
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
          ByteLogList(
            entries: _log,
            showHex: true,
            onClear: () => setState(() => _log.clear()),
            emptyHint: '启动后，客户端连接与收发报文会显示在这里',
          ),
        ],
      ),
    );
  }
}
