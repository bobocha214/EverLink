import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:everlink/services/network_info_service.dart';
import 'package:everlink/ui/ping_page.dart';
import 'package:everlink/ui/widgets/tool_list_card.dart';
import 'package:everlink/utils/app_routes.dart';
import 'package:everlink/utils/ip_calc.dart';

/// 通用网络调试客户端工具页。
///
/// 设计文档模块四的落地，包含以下网络调试功能（TCP Client 已作为正式
/// 协议归入「设备」体系，不再作为独立工具重复提供）：
/// - **端口扫描**：对目标 IP 并发 TCP `connect` 探测常见/自定义端口（4.2）。
/// - **目标探测**：对目标做多次 TCP 连通性探测并统计 RTT（类似 TCP Ping）。
/// - **局域网扫描**：对指定网段某端口做 TCP 探测，发现同网段内提供服务的主机。
/// - **IP 计算**：根据 IP 与子网掩码计算网络地址、可用范围等。
///
/// HTTP 调试与网络信息面板已有独立页面（http_page / network_info_page），
/// 此处不再重复实现。
class NetworkDebugPage extends StatelessWidget {
  const NetworkDebugPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('网络调试')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _netFuncs.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          final f = _netFuncs[i];
          return ToolListCard(
            icon: f.icon,
            title: f.label,
            subtitle: f.desc,
            onTap: () => AppRoutes.push(context, f.page),
          );
        },
      ),
    );
  }
}

/// 网络调试的五个功能入口（目录页使用）。
class _NetFunc {
  const _NetFunc(this.icon, this.label, this.desc, this.page);
  final IconData icon;
  final String label;
  final String desc;
  final Widget page;
}

const List<_NetFunc> _netFuncs = [
  _NetFunc(Icons.scanner, '端口扫描',
      '并发探测目标主机的常见 / 自定义端口是否开放', PortScanPage()),
  _NetFunc(Icons.route, '目标探测',
      '对目标做多次 TCP 连通性探测并统计往返时延（RTT）', TargetProbePage()),
  _NetFunc(Icons.lan_outlined, '局域网扫描',
      '发现同网段内开放指定端口的局域网设备', LanScanPage()),
  _NetFunc(Icons.calculate_outlined, 'IP 计算',
      '根据 IP 与子网掩码计算网络地址、可用范围等', IpCalcPage()),
  _NetFunc(Icons.network_ping, '网络诊断',
      '对目标主机执行 ICMP Ping，查看时延与丢包率', PingPage()),
];

/// 端口扫描器。
class PortScanPage extends StatefulWidget {
  const PortScanPage({super.key});

  @override
  State<PortScanPage> createState() => _PortScanPageState();
}

class _ScanResult {
  _ScanResult(this.port, this.open, this.service);
  final int port;
  final bool open;
  final String? service;
}

class _PortScanPageState extends State<PortScanPage> {
  final _hostCtl = TextEditingController();
  final _portsCtl =
      TextEditingController(text: '502,1883,4840,80,443,21,22,23,3389');
  final List<_ScanResult> _results = [];
  bool _scanning = false;
  String? _error;
  int _done = 0;
  int _total = 0;

  @override
  void dispose() {
    _hostCtl.dispose();
    _portsCtl.dispose();
    super.dispose();
  }

  /// 解析端口列表：支持逗号分隔与 `a-b` 区间。
  List<int> _parsePorts(String s) {
    final out = <int>{};
    for (final part in s.split(',')) {
      final p = part.trim();
      if (p.isEmpty) continue;
      if (p.contains('-')) {
        final range = p.split('-');
        if (range.length == 2) {
          final a = int.tryParse(range[0].trim());
          final b = int.tryParse(range[1].trim());
          if (a != null && b != null) {
            for (var i = a; i <= b && i <= 65535; i++) {
              if (i > 0) out.add(i);
            }
          }
        }
      } else {
        final n = int.tryParse(p);
        if (n != null && n > 0 && n <= 65535) out.add(n);
      }
    }
    return out.toList()..sort();
  }

  String? _serviceName(int port) {
    const map = {
      21: 'FTP',
      22: 'SSH',
      23: 'Telnet',
      80: 'HTTP',
      443: 'HTTPS',
      502: 'Modbus TCP',
      1883: 'MQTT',
      4840: 'OPC UA',
      3306: 'MySQL',
      3389: 'RDP',
      5432: 'PostgreSQL',
      6379: 'Redis',
      8080: 'HTTP-Alt',
      8883: 'MQTT-TLS',
    };
    return map[port];
  }

  Future<void> _scan() async {
    final host = _hostCtl.text.trim();
    if (host.isEmpty) {
      setState(() => _error = '请填写目标 IP 或域名');
      return;
    }
    final ports = _parsePorts(_portsCtl.text);
    if (ports.isEmpty) {
      setState(() => _error = '没有可扫描的端口');
      return;
    }
    setState(() {
      _scanning = true;
      _error = null;
      _results.clear();
      _done = 0;
      _total = ports.length;
    });
    const batch = 25;
    final open = <_ScanResult>[];
    final closed = <_ScanResult>[];
    for (var i = 0; i < ports.length; i += batch) {
      final chunk = ports.sublist(i, (i + batch).clamp(0, ports.length));
      final batchResults = await Future.wait(
        chunk.map((p) => _probe(host, p)),
      );
      for (final r in batchResults) {
        if (r.open) {
          open.add(r);
        } else {
          closed.add(r);
        }
      }
      if (mounted) {
        setState(() {
          _done = (i + chunk.length).clamp(0, ports.length);
          _results
            ..clear()
            ..addAll([...open, ...closed]);
        });
      }
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<_ScanResult> _probe(String host, int port) async {
    try {
      final s = await Socket.connect(host, port,
          timeout: const Duration(milliseconds: 700));
      try {
        await s.close();
      } catch (_) {
        // 忽略关闭异常。
      }
      return _ScanResult(port, true, _serviceName(port));
    } on SocketException {
      return _ScanResult(port, false, null);
    } on TimeoutException {
      return _ScanResult(port, false, null);
    } catch (_) {
      return _ScanResult(port, false, null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final openCount = _results.where((r) => r.open).length;
    return Scaffold(
      appBar: AppBar(title: const Text('端口扫描')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _hostCtl,
                    decoration: const InputDecoration(
                      labelText: '目标主机',
                      hintText: 'IP 或域名',
                      isDense: true,
                    ),
                    enabled: !_scanning,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _portsCtl,
                    decoration: const InputDecoration(
                      labelText: '端口',
                      hintText: '逗号分隔或 a-b 区间，如 502,80-90',
                      isDense: true,
                    ),
                    enabled: !_scanning,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _scanning
                            ? LinearProgressIndicator(
                                value: _total == 0 ? 0 : _done / _total)
                            : FilledButton.icon(
                                onPressed: _scan,
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('开始扫描'),
                              ),
                      ),
                      if (_scanning) ...[
                        const SizedBox(width: 12),
                        Text('$_done/$_total',
                            style: const TextStyle(color: Colors.grey)),
                      ],
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
          if (_results.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('扫描完成：发现 $openCount 个开放端口',
                  style: TextStyle(color: Colors.green.shade700)),
            ),
          const SizedBox(height: 12),
          if (_results.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('填写目标与端口后开始扫描',
                    style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            ..._results.map((r) {
              final c = r.open ? Colors.green : Colors.grey;
              return ListTile(
                leading: Icon(r.open ? Icons.lock_open : Icons.lock, color: c),
                title: Text('端口 ${r.port}',
                    style: TextStyle(
                        color: r.open ? null : Colors.grey, fontSize: 14)),
                subtitle: r.open && r.service != null
                    ? Text(r.service!, style: const TextStyle(fontSize: 12))
                    : const Text('关闭', style: TextStyle(fontSize: 12)),
                trailing: r.open
                    ? const Chip(
                        label: Text('开放'),
                        backgroundColor: Colors.green,
                        labelStyle: TextStyle(color: Colors.white, fontSize: 12),
                      )
                    : null,
              );
            }),
        ],
      ),
    );
  }
}

/// 目标探测（TCP 连通性 + RTT）。
///
/// 设计文档模块四.3 的 Traceroute 在纯 Dart / 当前 Flutter·Android SDK 下
/// 无法真正逐跳实现：本 SDK 的 `dart:io` 不提供 [SocketOption.ipTtl]（无法设置
/// IP 存活跳数），且移动端无法创建原始 ICMP 套接字读取中间路由响应。因此此处
/// 退化为**对目标主机做多次 TCP 连通性探测并统计 RTT**（类似“TCP Ping”），
/// 用于判断设备是否可达及其时延，无法列出中间路由 IP。结果仅供参考（4.3 边界）。
class TargetProbePage extends StatefulWidget {
  const TargetProbePage({super.key});

  @override
  State<TargetProbePage> createState() => _TargetProbePageState();
}

class _ProbeResult {
  _ProbeResult(this.index, this.rtt, this.ok, this.note);
  final int index;
  final Duration? rtt;
  final bool ok;
  final String note;
}

class _TargetProbePageState extends State<TargetProbePage> {
  final _hostCtl = TextEditingController();
  final _portCtl = TextEditingController(text: '80');
  final List<_ProbeResult> _results = [];
  bool _running = false;
  String? _error;

  @override
  void dispose() {
    _hostCtl.dispose();
    _portCtl.dispose();
    super.dispose();
  }

  Future<void> _probeTarget() async {
    final host = _hostCtl.text.trim();
    final port = int.tryParse(_portCtl.text.trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      setState(() => _error = '请填写合法的主机地址与端口（1-65535）');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _results.clear();
    });
    const probes = 4;
    for (var i = 1; i <= probes; i++) {
      final sw = Stopwatch()..start();
      bool ok = false;
      String note = '';
      try {
        final s = await Socket.connect(host, port,
            timeout: const Duration(seconds: 2));
        try {
          await s.close();
        } catch (_) {
          // 忽略关闭异常。
        }
        ok = true;
        note = '可达';
      } on SocketException catch (e) {
        note = _connNote(e);
      } on TimeoutException {
        note = '超时（2s）';
      } catch (_) {
        note = '错误';
      }
      if (mounted) {
        setState(() => _results.add(_ProbeResult(
              i,
              ok ? sw.elapsed : null,
              ok,
              note,
            )));
      }
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final okRtts = _results
        .where((r) => r.ok && r.rtt != null)
        .map((r) => r.rtt!)
        .toList();
    final avg = okRtts.isEmpty
        ? null
        : okRtts.reduce((a, b) => a + b) ~/ okRtts.length;
    final minRtt = okRtts.isEmpty ? null : okRtts.reduce((a, b) => a < b ? a : b);
    final maxRtt = okRtts.isEmpty ? null : okRtts.reduce((a, b) => a > b ? a : b);
    final reachable = okRtts.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('目标探测')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: const Text(
              '本平台不支持逐跳 Traceroute（无 ipTtl / 无原始 ICMP 套接字），此处为'
              '对目标的多次 TCP 连通性探测 + RTT 统计（TCP Ping），用于判断设备可达'
              '性与时延，无法列出中间路由 IP。结果仅供参考。',
              style: TextStyle(color: Colors.orange, fontSize: 12),
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
                          controller: _hostCtl,
                          decoration: const InputDecoration(
                            labelText: '目标主机',
                            hintText: 'IP 或域名',
                            isDense: true,
                          ),
                          enabled: !_running,
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 90,
                        child: TextField(
                          controller: _portCtl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '端口',
                            isDense: true,
                          ),
                          enabled: !_running,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _running
                            ? const LinearProgressIndicator()
                            : FilledButton.icon(
                                onPressed: _probeTarget,
                                icon: const Icon(Icons.route),
                                label: const Text('开始探测'),
                              ),
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
          if (okRtts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${reachable ? '目标可达' : '目标不可达'} · 探测 ${_results.length} 次 · '
                'RTT 最小 ${minRtt!.inMilliseconds}ms / 平均 ${avg!.inMilliseconds}ms / '
                '最大 ${maxRtt!.inMilliseconds}ms',
                style: TextStyle(color: Colors.green.shade700, fontSize: 13),
              ),
            ),
          ] else if (_results.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('目标不可达',
                  style: TextStyle(color: Colors.red)),
            ),
          ],
          const SizedBox(height: 12),
          if (_results.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('探测结果将显示在这里',
                    style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            ..._results.map((r) {
              final c = r.ok ? Colors.green : Colors.grey;
              return ListTile(
                leading: Icon(Icons.label, color: c, size: 18),
                title: Text('探测 #${r.index}',
                    style: const TextStyle(fontSize: 14)),
                subtitle: Text(r.note, style: const TextStyle(fontSize: 12)),
                trailing: r.rtt != null
                    ? Text('${r.rtt!.inMilliseconds} ms',
                        style: const TextStyle(fontSize: 12, color: Colors.grey))
                    : null,
              );
            }),
        ],
      ),
    );
  }
}

/// 局域网设备扫描。
///
/// 对指定网段（x.x.x.1 ~ x.x.x.254）的某一端口做 TCP 探测，列出“开放该端口的
/// 局域网主机 IP”。这是**局域网主机发现**工具，**不是** Modbus 从站地址
/// （unit ID / 站号 1~247）。
class LanScanPage extends StatefulWidget {
  const LanScanPage({super.key});

  @override
  State<LanScanPage> createState() => _LanScanPageState();
}

class _LanScanPageState extends State<LanScanPage> {
  final _prefixCtl = TextEditingController(text: '192.168.1');
  final _portCtl = TextEditingController(text: '502');
  final _timeoutCtl = TextEditingController(text: '300');

  final List<String> _results = <String>[];
  bool _scanning = false;
  int _done = 0;
  int _total = 0;
  String? _error;

  @override
  void dispose() {
    _prefixCtl.dispose();
    _portCtl.dispose();
    _timeoutCtl.dispose();
    super.dispose();
  }

  /// 用本机当前 IP 的前三段自动填充网段前缀。
  Future<void> _useLocalSubnet() async {
    try {
      final info = await NetworkInfoService.instance.collect();
      final ip = info.primaryIp;
      final parts = ip.split('.');
      if (parts.length == 4) {
        _prefixCtl.text = '${parts[0]}.${parts[1]}.${parts[2]}';
        if (mounted) setState(() {});
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法获取本机网段')),
        );
      }
    }
  }

  Future<void> _scan() async {
    final base = _prefixCtl.text.trim();
    final port = int.tryParse(_portCtl.text.trim());
    final timeoutMs = int.tryParse(_timeoutCtl.text.trim()) ?? 300;
    if (!base.contains(RegExp(r'^\d+\.\d+\.\d+$'))) {
      setState(() => _error = '网段前缀格式应为 x.x.x（如 192.168.1）');
      return;
    }
    if (port == null || port <= 0 || port > 65535) {
      setState(() => _error = '请填写合法端口（1-65535）');
      return;
    }
    setState(() {
      _scanning = true;
      _error = null;
      _results.clear();
      _done = 0;
      _total = 254;
    });
    final futures = <Future<void>>[];
    for (var i = 1; i <= 254; i++) {
      final ip = '$base.$i';
      futures.add(
        Socket.connect(ip, port, timeout: Duration(milliseconds: timeoutMs))
            .then((s) {
          s.destroy();
          if (mounted) {
            setState(() {
              _results.add(ip);
              _done++;
            });
          }
        }).catchError((_) {
          if (mounted) setState(() => _done++);
        }),
      );
    }
    await Future.wait(futures);
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _copy(String ip) async {
    await Clipboard.setData(ClipboardData(text: ip));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已复制 $ip')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('局域网扫描')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.shade100),
            ),
            child: const Text(
              '扫描“开放某端口的局域网主机 IP”，用于发现同网段内提供服务的设备。'
              '注意：这是局域网主机探测，不是 Modbus 从站地址（站号 1~247）。'
              '要在具体设备上读写寄存器，请到对应协议调试页。',
              style: TextStyle(color: Colors.blue, fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _prefixCtl,
                          decoration: const InputDecoration(
                            labelText: '网段前缀 (x.x.x)',
                            isDense: true,
                          ),
                          enabled: !_scanning,
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _scanning ? null : _useLocalSubnet,
                        icon: const Icon(Icons.auto_fix_high, size: 16),
                        label: const Text('本机网段'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _portCtl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '端口',
                            hintText: '如 502 / 1883 / 80',
                            isDense: true,
                          ),
                          enabled: !_scanning,
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: _timeoutCtl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '超时(ms)',
                            isDense: true,
                          ),
                          enabled: !_scanning,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _scanning
                            ? LinearProgressIndicator(
                                value: _total == 0 ? 0 : _done / _total,
                              )
                            : FilledButton.icon(
                                onPressed: _scan,
                                icon: const Icon(Icons.scanner),
                                label: const Text('开始扫描'),
                              ),
                      ),
                      if (_scanning) ...[
                        const SizedBox(width: 12),
                        Text('$_done/$_total',
                            style: const TextStyle(color: Colors.grey)),
                      ],
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
          if (_results.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '发现 ${_results.length} 个开放端口 ${_portCtl.text.trim()} 的主机',
                style: TextStyle(color: Colors.green.shade700, fontSize: 13),
              ),
            ),
          const SizedBox(height: 12),
          if (_results.isEmpty && !_scanning)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('填写网段前缀与端口后开始扫描',
                    style: TextStyle(color: Colors.grey)),
              ),
            )
          else if (_results.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _results
                  .map((ip) => ActionChip(
                        label: Text(ip),
                        onPressed: () => _copy(ip),
                        avatar: const Icon(Icons.content_copy, size: 16),
                      ))
                  .toList(),
            ),
        ],
      ),
    );
  }
}

/// IP 子网计算器。
class IpCalcPage extends StatefulWidget {
  const IpCalcPage({super.key});

  @override
  State<IpCalcPage> createState() => _IpCalcPageState();
}

class _IpCalcPageState extends State<IpCalcPage> {
  final _ipCtl = TextEditingController();
  final _maskCtl = TextEditingController(text: '255.255.255.0');
  String? _result;
  String? _err;

  @override
  void dispose() {
    _ipCtl.dispose();
    _maskCtl.dispose();
    super.dispose();
  }

  void _calc() {
    final ip = parseIp(_ipCtl.text.trim());
    if (ip == null) {
      setState(() => _err = 'IP 格式错误（应为 a.b.c.d，每段 0-255）');
      return;
    }
    int prefix;
    final maskStr = _maskCtl.text.trim();
    try {
      if (maskStr.startsWith('/')) {
        prefix = int.parse(maskStr.substring(1));
        if (prefix < 0 || prefix > 32) {
          throw const FormatException('CIDR 范围 0-32');
        }
      } else {
        final mask = parseIp(maskStr);
        if (mask == null) throw const FormatException('掩码格式错误');
        prefix = maskToPrefix(mask);
      }
    } on FormatException catch (e) {
      setState(() => _err = '掩码错误：${e.message}');
      return;
    }
    final ipInt = ipToInt(ip);
    final maskInt = ((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF);
    final net = ipInt & maskInt;
    final bcast = net | (~maskInt & 0xFFFFFFFF);
    final hostCount = prefix >= 31 ? 0 : (bcast - net - 1);
    final first = prefix >= 31 ? net : net + 1;
    final last = prefix >= 31 ? bcast : bcast - 1;
    setState(() {
      _err = null;
      _result = 'CIDR：/$prefix\n'
          '网络地址：${intToIp(net)}\n'
          '广播地址：${intToIp(bcast)}\n'
          '可用主机：${hostCount > 0 ? '$hostCount 个' : '无（/31、/32）'}\n'
          '可用范围：${hostCount > 0 ? '${intToIp(first)} ~ ${intToIp(last)}' : intToIp(net)}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('IP 计算')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('IP 子网计算',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ipCtl,
                    decoration: const InputDecoration(
                      labelText: 'IP 地址',
                      hintText: '192.168.1.10',
                      isDense: true,
                    ),
                    onChanged: (_) => _calc(),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _maskCtl,
                    decoration: const InputDecoration(
                      labelText: '子网掩码（或 /CIDR）',
                      hintText: '255.255.255.0 或 /24',
                      isDense: true,
                    ),
                    onChanged: (_) => _calc(),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(onPressed: _calc, child: const Text('计算')),
                  if (_err != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_err!,
                          style:
                              const TextStyle(color: Colors.red, fontSize: 13)),
                    ),
                  if (_result != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.teal.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(_result!,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 14)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 尝试从 [SocketException] 推断失败原因（best-effort）。
String _connNote(SocketException e) {
  final msg = e.message.toLowerCase();
  if (msg.contains('timed out') || msg.contains('timeout')) {
    return '超时 / 不可达';
  }
  if (msg.contains('network is unreachable')) return '网络不可达';
  if (msg.contains('host unreachable')) return '主机不可达';
  if (msg.contains('connection refused')) return '连接被拒绝';
  return '不可达';
}
