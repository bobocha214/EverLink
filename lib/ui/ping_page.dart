import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:everlink/services/ping_history_service.dart';

/// 单次 Ping 的结果（一条 ICMP 回显应答或一次超时/不可达）。
class _PingResult {
  _PingResult({required this.time, this.seq});

  bool ok = false;
  final DateTime time;

  /// ICMP 序号（Linux/Android 有，Windows 回显行无此字段）。
  final int? seq;
  String? error;
  Duration? latency;
}

/// 网络连通性测试（Ping）页。
///
/// 采用与 WiFi 诊断工具相同的方式：调用系统 `ping` 二进制发起**真正的 ICMP
/// Echo** 探测（移动端无法创建原始 ICMP 套接字，而系统 ping 具备 CAP_NET_RAW
/// 能力，可在非 root 设备正常运行）。逐行解析 ping 输出，实时展示每次回显的
/// 时延，并在结束后汇总丢包率与 min/avg/max。记录最近 Ping 过的主机便于重测。
class PingPage extends StatefulWidget {
  const PingPage({super.key});

  @override
  State<PingPage> createState() => _PingPageState();
}

class _PingPageState extends State<PingPage> {
  final _hostCtl = TextEditingController();
  final _countCtl = TextEditingController(text: '4');
  final _intervalCtl = TextEditingController(text: '1000');
  final _timeoutCtl = TextEditingController(text: '3');

  bool _running = false;
  final List<_PingResult> _results = [];
  String? _summary;

  /// 回显行：Linux/Android `time=23.4 ms`、Windows `time=23ms`。
  static final RegExp _replyRe = RegExp(
    r'time[=\s]+([\d.]+)\s*ms',
    caseSensitive: false,
  );
  static final RegExp _seqRe = RegExp(r'icmp_seq=(\d+)');

  @override
  void initState() {
    super.initState();
    PingHistoryService.instance.addListener(_onHistoryChanged);
  }

  @override
  void dispose() {
    PingHistoryService.instance.removeListener(_onHistoryChanged);
    _hostCtl.dispose();
    _countCtl.dispose();
    _intervalCtl.dispose();
    _timeoutCtl.dispose();
    super.dispose();
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  /// 选取 ping 可执行文件：Android 优先用 /system/bin/ping，否则走 PATH。
  Future<String> _pingExecutable() async {
    if (Platform.isAndroid) {
      const p = '/system/bin/ping';
      if (await File(p).exists()) return p;
    }
    return 'ping';
  }

  /// 构造平台相关的 ping 参数。
  List<String> _buildArgs(String host, int count, int intervalMs, int timeoutSec) {
    if (Platform.isWindows) {
      // Windows：ping -n <count> -w <timeout_ms> <host>
      return ['-n', '$count', '-w', '${timeoutSec * 1000}', host];
    }
    // Linux / Android / macOS：ping -c <count> [-i <interval>] <host>
    final args = ['-c', '$count'];
    final intervalSec = (intervalMs / 1000).ceil();
    if (intervalSec >= 1) args.addAll(['-i', '$intervalSec']);
    args.add(host);
    return args;
  }

  Future<void> _start() async {
    final host = _hostCtl.text.trim();
    if (host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先输入要测试的主机或 IP')),
      );
      return;
    }
    final count = int.tryParse(_countCtl.text) ?? 4;
    final intervalMs = int.tryParse(_intervalCtl.text) ?? 1000;
    final timeoutSec = int.tryParse(_timeoutCtl.text) ?? 3;

    setState(() {
      _running = true;
      _results.clear();
      _summary = null;
    });

    final exe = await _pingExecutable();
    final args = _buildArgs(host, count, intervalMs, timeoutSec);

    Process process;
    try {
      process = await Process.start(exe, args);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _summary = '无法启动 ping（${exe.isNotEmpty ? exe : 'ping'}）：$e';
      });
      return;
    }

    final log = StringBuffer();
    void handleLine(String line) {
      log.writeln(line);
      _parseLine(line, host);
    }

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(handleLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(handleLine);

    final overall = Duration(
      seconds: count * (intervalMs / 1000).ceil().clamp(1, 9999) + 5,
    );
    final code = await process.exitCode.timeout(
      overall,
      onTimeout: () {
        process.kill();
        return -1;
      },
    );

    if (!mounted) return;
    final summary = _parseSummary(log.toString(), host, code);
    _saveRecord(host, summary);
    setState(() {
      _running = false;
      _summary = summary;
    });
  }

  /// 将本次 Ping 结果写入历史记录。
  void _saveRecord(String host, String summary) {
    final sent = int.tryParse(_countCtl.text) ?? _results.length;
    final received = _results.where((r) => r.ok).length;
    final lats = _results
        .where((r) => r.ok)
        .map((r) => r.latency!.inMilliseconds)
        .toList();
    int? minMs;
    int? avgMs;
    int? maxMs;
    if (lats.isNotEmpty) {
      minMs = lats.reduce((a, b) => a < b ? a : b);
      maxMs = lats.reduce((a, b) => a > b ? a : b);
      avgMs = lats.reduce((a, b) => a + b) ~/ lats.length;
    }
    PingHistoryService.instance.addRecord(
      PingRecord(
        host: host,
        time: DateTime.now(),
        sent: sent,
        received: received,
        minMs: minMs,
        avgMs: avgMs,
        maxMs: maxMs,
        summary: summary,
      ),
    );
  }

  void _parseLine(String line, String host) {
    final reply = _replyRe.firstMatch(line);
    if (reply != null) {
      final ms = double.tryParse(reply.group(1)!);
      final r = _PingResult(
        time: DateTime.now(),
        seq: _parseSeq(line),
      );
      r.ok = true;
      r.latency = ms == null ? null : Duration(microseconds: (ms * 1000).round());
      if (mounted) setState(() => _results.insert(0, r));
      return;
    }
    if (_isErrorLine(line)) {
      final r = _PingResult(time: DateTime.now());
      r.ok = false;
      r.error = line.trim();
      if (mounted) setState(() => _results.insert(0, r));
    }
  }

  int? _parseSeq(String line) {
    final m = _seqRe.firstMatch(line);
    return m != null ? int.tryParse(m.group(1)!) : null;
  }

  bool _isErrorLine(String line) {
    final l = line.toLowerCase();
    return l.contains('request timeout') ||
        l.contains('timed out') ||
        l.contains('unreachable') ||
        l.contains('network is unreachable') ||
        l.contains('no route');
  }

  /// 从 ping 文本输出解析汇总（兼容 Linux/Android 与 Windows 格式）。
  String _parseSummary(String log, String host, int code) {
    final sent = int.tryParse(_countCtl.text) ?? _results.length;
    final received = _results.where((r) => r.ok).length;
    final loss = sent == 0 ? 0 : ((sent - received) / sent * 100).round();

    final lats = _results.where((r) => r.ok).map((r) => r.latency!).toList();
    final base =
        '已发送 $sent，已接收 $received，丢包率 $loss%';

    if (lats.isEmpty) {
      final lower = log.toLowerCase();
      if (lower.contains('unknown host') ||
          lower.contains('temporary failure in name resolution')) {
        return '$base · 无法解析主机（$host）';
      }
      if (lower.contains('network is unreachable')) {
        return '$base · 网络不可达';
      }
      return '$base · 全部超时 / 主机不可达';
    }

    final min = lats.reduce((a, b) => a < b ? a : b);
    final max = lats.reduce((a, b) => a > b ? a : b);
    final avg = lats.reduce((a, b) => a + b) ~/ lats.length;
    return '$base · '
        'min ${min.inMilliseconds}ms / avg ${avg.inMilliseconds}ms / max ${max.inMilliseconds}ms';
  }

  void _stop() => setState(() => _running = false);

  /// 打开历史记录弹窗：查看过往 Ping 记录，支持单条删除与清空。
  void _openHistory(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: PingHistoryService.instance,
        builder: (_, _) {
          final records = PingHistoryService.instance.records;
          return DraggableScrollableSheet(
            initialChildSize: 0.7,
            maxChildSize: 0.9,
            minChildSize: 0.4,
            expand: false,
            builder: (_, scrollController) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('Ping 历史记录',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.delete_sweep, size: 18),
                        label: const Text('清空'),
                        onPressed: records.isEmpty
                            ? null
                            : () async {
                                final ok = await showDialog<bool>(
                                  context: sheetContext,
                                  builder: (d) => AlertDialog(
                                    title: const Text('清空历史记录'),
                                    content: const Text(
                                        '将删除全部 Ping 历史记录，且不可恢复。'),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(d).pop(false),
                                        child: const Text('取消'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.of(d).pop(true),
                                        child: const Text('清空'),
                                      ),
                                    ],
                                  ),
                                );
                                if (ok == true) {
                                  PingHistoryService.instance.clear();
                                }
                              },
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: records.isEmpty
                      ? const Center(
                          child: Text('暂无历史记录',
                              style: TextStyle(color: Colors.grey)),
                        )
                      : ListView.separated(
                          controller: scrollController,
                          padding: const EdgeInsets.all(12),
                          itemCount: records.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, i) {
                            final r = records[i];
                            return _HistoryTile(
                              record: r,
                              onTap: () => _showRecordDetail(sheetContext, r),
                              onDelete: () =>
                                  PingHistoryService.instance.removeAt(i),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 查看单条历史记录的当时状态（不重新 Ping）。
  void _showRecordDetail(BuildContext sheetContext, PingRecord r) {
    final date = '${r.time.year}-'
        '${r.time.month.toString().padLeft(2, '0')}-'
        '${r.time.day.toString().padLeft(2, '0')}';
    final time = TimeOfDay.fromDateTime(r.time).format(context);
    showDialog(
      context: sheetContext,
      builder: (d) => AlertDialog(
        title: Text(r.host),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailRow('时间', '$date $time'),
              _detailRow('结果', r.reachable ? '可达' : '不可达'),
              _detailRow('已发送', '${r.sent}'),
              _detailRow('已接收', '${r.received}'),
              _detailRow('丢包率', '${r.lossPercent}%'),
              if (r.reachable && r.avgMs != null)
                _detailRow('时延',
                    'min ${r.minMs} / avg ${r.avgMs} / max ${r.maxMs} ms'),
              const SizedBox(height: 10),
              const Text('详情',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(r.summary, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(d).pop();
              Navigator.of(sheetContext).pop();
              _hostCtl.text = r.host;
              if (!_running) _start();
            },
            child: const Text('重新测试'),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(label,
                style: const TextStyle(
                    color: Colors.grey, fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ping 连通性测试'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '历史记录',
            onPressed: () => _openHistory(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('目标',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _hostCtl,
                    decoration: const InputDecoration(
                      labelText: '主机 / IP',
                      hintText: '如 8.8.8.8 或 example.com',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _countCtl,
                          decoration: const InputDecoration(labelText: '次数'),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _intervalCtl,
                          decoration: const InputDecoration(
                            labelText: '间隔(ms)',
                            hintText: '默认 1000',
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _timeoutCtl,
                          decoration: const InputDecoration(
                            labelText: '超时(s)',
                            hintText: '默认 3',
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _running ? null : _start,
                          icon: const Icon(Icons.network_ping),
                          label: const Text('开始 Ping'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _running ? _stop : null,
                        child: const Text('停止'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '采用系统 ping 发起真正的 ICMP Echo 探测（与 WiFi 诊断工具一致）。'
                    '移动端无法创建原始 ICMP 套接字，故由具备 CAP_NET_RAW 的系统 ping 完成。',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildHistoryCard(),
          const SizedBox(height: 12),
          if (_summary != null)
            Card(
              color: Colors.teal.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_summary!,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          const SizedBox(height: 8),
          ..._results.map(_buildResultTile),
        ],
      ),
    );
  }

  Widget _buildHistoryCard() {
    final hosts = PingHistoryService.instance.hosts;
    if (hosts.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('历史 IP',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton(
                  onPressed: hosts.isEmpty
                      ? null
                      : () => PingHistoryService.instance.clear(),
                  child: const Text('清空'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: hosts
                  .map(
                    (h) => InputChip(
                      label: Text(h),
                      onPressed: () {
                        _hostCtl.text = h;
                        if (!_running) _start();
                      },
                      onDeleted: () =>
                          PingHistoryService.instance.removeByHost(h),
                      deleteIcon: const Icon(Icons.close, size: 16),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultTile(_PingResult r) {
    final time = TimeOfDay.fromDateTime(r.time).format(context);
    if (r.ok) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.check_circle, color: Colors.green),
          title: Text('来自 ${_hostCtl.text.trim()} 的回复'
              '${r.seq != null ? ' · #${r.seq}' : ''}'),
          trailing: Text('${r.latency!.inMilliseconds} ms',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(time),
        ),
      );
    }
    return Card(
      child: ListTile(
        leading: const Icon(Icons.cancel, color: Colors.red),
        title: const Text('请求超时 / 不可达'),
        subtitle: Text('${r.error ?? '未知错误'} · $time'),
      ),
    );
  }
}

/// 历史记录弹窗中的单条记录卡片。
class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.record,
    required this.onTap,
    required this.onDelete,
  });

  final PingRecord record;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = TimeOfDay.fromDateTime(record.time).format(context);
    final date = '${record.time.year}-'
        '${record.time.month.toString().padLeft(2, '0')}-'
        '${record.time.day.toString().padLeft(2, '0')}';
    final latency = record.reachable && record.avgMs != null
        ? 'min ${record.minMs} / avg ${record.avgMs} / max ${record.maxMs} ms'
        : '全部超时 / 不可达';
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          record.reachable ? Icons.check_circle : Icons.cancel,
          color: record.reachable ? Colors.green : Colors.red,
        ),
        title: Text(record.host),
        subtitle: Text(
          '$date $t · 丢包 ${record.lossPercent}% · $latency',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.grey),
          tooltip: '删除',
          onPressed: onDelete,
        ),
      ),
    );
  }
}
