import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:everlink/services/data_point.dart';
import 'package:everlink/ui/widgets/point_charts.dart';

/// 单点位实时监控页。
///
/// 由各协议调试页（Modbus 点位行 / OPC UA 监控项）点击进入，订阅
/// [DataPointBus] 中匹配 `source + tag` 的数据点，实时绘制趋势曲线，
/// 并给出最新值 / 最值 / 均值等统计。
///
/// 因为 [DataPointBus] 本身不保留历史，调用方需要通过 [initial] 把自己已经
/// 缓存的序列传进来，否则进入本页只能看到「之后」的新采样点。
class PointMonitorPage extends StatefulWidget {
  const PointMonitorPage({
    super.key,
    required this.source,
    required this.tag,
    required this.label,
    this.unit,
    this.initial = const <DataPoint>[],
    this.onWrite,
  });

  /// 数据来源：'modbus' / 'opcua' / 'mqtt'。
  final String source;

  /// 点位标识（Modbus 为寄存器地址，OPC UA 为 nodeId）。
  final String tag;

  /// 页面标题上展示的点位名称。
  final String label;

  /// 可选单位后缀。
  final String? unit;

  /// 调用方已缓存的历史采样点，作为曲线初值。
  final List<DataPoint> initial;

  /// 可选写入回调；提供后右上角出现「写入」按钮。
  final Future<void> Function()? onWrite;

  @override
  State<PointMonitorPage> createState() => _PointMonitorPageState();
}

class _PointMonitorPageState extends State<PointMonitorPage> {
  static const int _maxPoints = 300;

  final List<DataPoint> _points = <DataPoint>[];
  StreamSubscription<DataPoint>? _sub;
  Timer? _repaintTimer;
  bool _dirty = false;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _points.addAll(widget.initial);
    _trim();
    _sub = DataPointBus.instance.stream
        .where((p) => p.source == widget.source && p.tag == widget.tag)
        .listen(_onPoint);
    // 高频采集时合并刷新，避免每来一个点就 setState。
    _repaintTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (_dirty && mounted) {
        _dirty = false;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _repaintTimer?.cancel();
    super.dispose();
  }

  void _onPoint(DataPoint p) {
    if (_paused) return;
    _points.add(p);
    _trim();
    _dirty = true;
  }

  void _trim() {
    while (_points.length > _maxPoints) {
      _points.removeAt(0);
    }
  }

  // —— 统计 ——

  double? get _latest =>
      _points.isEmpty ? null : _points.last.value.toDouble();

  double? get _min => _points.isEmpty
      ? null
      : _points
          .map((e) => e.value.toDouble())
          .reduce((a, b) => a < b ? a : b);

  double? get _max => _points.isEmpty
      ? null
      : _points
          .map((e) => e.value.toDouble())
          .reduce((a, b) => a > b ? a : b);

  double? get _avg {
    if (_points.isEmpty) return null;
    final sum = _points.fold<double>(0, (s, e) => s + e.value.toDouble());
    return sum / _points.length;
  }

  String _fmt(double? v) => v == null ? '—' : _trimZero(v);

  static String _trimZero(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    return v.toStringAsFixed(3);
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.unit ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.label),
        actions: [
          IconButton(
            icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
            tooltip: _paused ? '继续采集' : '暂停采集',
            onPressed: () => setState(() => _paused = !_paused),
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空曲线',
            onPressed: () => setState(_points.clear),
          ),
          if (widget.onWrite != null)
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: '写入此点位',
              onPressed: () async => widget.onWrite!(),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildLatestCard(unit),
          const SizedBox(height: 12),
          _buildStatCard(unit),
          const SizedBox(height: 12),
          TrendCard(label: '实时趋势（近 ${_points.length} 点）', points: _points),
          const SizedBox(height: 12),
          _buildRecentCard(unit),
        ],
      ),
    );
  }

  Widget _buildLatestCard(String unit) {
    final t = _points.isEmpty ? null : _points.last.time;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _paused ? Icons.pause_circle_outline : Icons.sensors,
                  size: 18,
                  color: _paused ? Colors.orange : Colors.teal,
                ),
                const SizedBox(width: 6),
                Text(
                  _paused ? '已暂停' : '实时采集中',
                  style: TextStyle(
                    fontSize: 12,
                    color: _paused ? Colors.orange : Colors.teal,
                  ),
                ),
                const Spacer(),
                Text(
                  '${widget.source.toUpperCase()} · ${widget.tag}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  _fmt(_latest),
                  style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
                if (unit.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(unit,
                      style: const TextStyle(fontSize: 16, color: Colors.grey)),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              t == null ? '等待数据…' : '更新于 ${_fmtTime(t)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String unit) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _stat('最小', _fmt(_min), unit),
              _stat('最大', _fmt(_max), unit),
              _stat('平均', _fmt(_avg), unit),
              _stat('采样', '${_points.length}', ''),
            ],
          ),
        ),
      );

  Widget _stat(String label, String value, String unit) => Expanded(
        child: Column(
          children: [
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(
              unit.isEmpty ? value : '$value$unit',
              style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 15,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );

  Widget _buildRecentCard(String unit) {
    final recent = _points.reversed.take(20).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('最近采样',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                if (recent.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: '复制全部采样',
                    onPressed: _copyAll,
                  ),
              ],
            ),
            if (recent.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child:
                    Text('暂无采样数据', style: TextStyle(color: Colors.grey)),
              )
            else
              ...recent.map(
                (p) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Text(_fmtTime(p.time),
                          style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                              fontFamily: 'monospace')),
                      const Spacer(),
                      Text(
                        '${_trimZero(p.value.toDouble())}$unit',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyAll() async {
    final text = _points
        .map((p) =>
            '${p.time.toIso8601String()},${widget.tag},${p.value}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${_points.length} 条采样')),
    );
  }

  static String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';
}
