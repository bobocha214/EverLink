import 'dart:async';

import 'package:flutter/material.dart';

import 'package:everlink/models/mqtt_models.dart';
import 'package:everlink/services/mqtt_publisher.dart';
import 'package:everlink/services/server_registry.dart';

/// MQTT 发布模拟器页：连接外部 Broker，按主题模板/数量/间隔循环发布模拟数据。
class MqttPublisherPage extends StatefulWidget {
  const MqttPublisherPage({super.key});

  @override
  State<MqttPublisherPage> createState() => _MqttPublisherPageState();
}

class _MqttPublisherPageState extends State<MqttPublisherPage> {
  final _hostCtl = TextEditingController(text: 'tcp://10.0.0.1');
  final _portCtl = TextEditingController(text: '1883');
  final _topicCtl = TextEditingController(text: 'device/sensor/{i}');
  final _countCtl = TextEditingController(text: '5');
  final _intervalCtl = TextEditingController(text: '1000');
  final _userCtl = TextEditingController();
  final _passCtl = TextEditingController();
  final _clientIdCtl = TextEditingController();

  final _log = <String>[];
  // 使用常驻单例：退出页面不会停止发布，可后台运行。
  final _pub = ServerRegistry.instance.publisher;
  StreamSubscription<MqttPublisherEvent>? _sub;

  bool _running = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = _pub.events.listen(_onEvent);
    // 发布器可能已在后台运行，恢复输入框与运行态。
    if (_pub.running) {
      _running = true;
      if (_pub.host != null) _hostCtl.text = _pub.host!;
      if (_pub.port != null) _portCtl.text = _pub.port.toString();
      if (_pub.topicTemplate != null) _topicCtl.text = _pub.topicTemplate!;
      if (_pub.count != null) _countCtl.text = _pub.count.toString();
      if (_pub.intervalMs != null) _intervalCtl.text = _pub.intervalMs.toString();
      if (_pub.username != null) _userCtl.text = _pub.username!;
      if (_pub.clientId != null) _clientIdCtl.text = _pub.clientId!;
    }
  }

  void _onEvent(MqttPublisherEvent e) {
    if (!mounted) return;
    if (e is MqttPublisherStateEvent) {
      setState(() {
        _running = e.connected;
        _busy = false;
        if (e.connected) _error = null;
      });
    } else if (e is MqttPublisherDataEvent) {
      setState(() {
        _log.insert(0, '${_now()} ${e.topic} = ${e.value}');
        if (_log.length > 200) _log.removeLast();
      });
    } else if (e is MqttPublisherErrorEvent) {
      setState(() => _error = e.message);
    }
  }

  String _now() {
    final t = DateTime.now();
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }

  Future<void> _toggle() async {
    if (_running) {
      _pub.stop();
      return;
    }
    final host = _hostCtl.text.trim();
    final port = int.tryParse(_portCtl.text.trim());
    final count = int.tryParse(_countCtl.text.trim());
    final interval = int.tryParse(_intervalCtl.text.trim());
    if (host.isEmpty) {
      setState(() => _error = '请填写 Broker 地址');
      return;
    }
    if (port == null || count == null || interval == null) {
      setState(() => _error = '端口 / 数量 / 间隔需为整数');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await _pub.start(
      host: host,
      port: port,
      topicTemplate: _topicCtl.text.trim().isEmpty
          ? 'device/sensor/{i}'
          : _topicCtl.text.trim(),
      count: count,
      intervalMs: interval,
      qos: MqttQosLevel.atLeastOnce,
      username: _userCtl.text.trim(),
      password: _passCtl.text,
      clientId: _clientIdCtl.text.trim(),
    );
  }

  @override
  void dispose() {
    // 仅取消订阅，不销毁服务：保持后台发布，下次进入可恢复。
    _sub?.cancel();
    _hostCtl.dispose();
    _portCtl.dispose();
    _topicCtl.dispose();
    _countCtl.dispose();
    _intervalCtl.dispose();
    _userCtl.dispose();
    _passCtl.dispose();
    _clientIdCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _running ? Colors.green : Colors.grey;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('MQTT 发布模拟')),
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
                          controller: _hostCtl,
                          enabled: !_running,
                          decoration: const InputDecoration(
                            labelText: 'Broker 地址',
                            isDense: true,
                            hintText: 'tcp://host 或 ssl://host',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 96,
                        child: TextField(
                          controller: _portCtl,
                          enabled: !_running,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '端口',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _topicCtl,
                          enabled: !_running,
                          decoration: const InputDecoration(
                            labelText: '主题模板',
                            isDense: true,
                            hintText: '支持 {i} 占位，如 device/sensor/{i}',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      SizedBox(
                        width: 92,
                        child: TextField(
                          controller: _countCtl,
                          enabled: !_running,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '数量',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: _intervalCtl,
                          enabled: !_running,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '间隔(ms)',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _userCtl,
                          enabled: !_running,
                          decoration: const InputDecoration(
                            labelText: '用户名（可选）',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _passCtl,
                          enabled: !_running,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: '密码（可选）',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _clientIdCtl,
                    enabled: !_running,
                    decoration: const InputDecoration(
                      labelText: 'ClientID（可选，留空自动生成）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Row(
                        children: [
                          Icon(Icons.circle, size: 10, color: color),
                          const SizedBox(width: 6),
                          Text(_running ? '发布中' : '已停止',
                              style: TextStyle(color: color, fontSize: 13)),
                        ],
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _busy ? null : _toggle,
                        icon: _busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Icon(_running ? Icons.stop : Icons.play_arrow),
                        label: Text(_running ? '停止' : '开始发布'),
                      ),
                    ],
                  ),
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
          Text('发布记录（${_log.length}）',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 8),
          if (_log.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('开始发布后，这里显示已发出的消息',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            )
          else
            Card(
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _log.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(_log[i],
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
