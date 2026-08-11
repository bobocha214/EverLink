import 'dart:math';

import 'package:flutter/material.dart';

import 'package:everlink/services/data_point.dart';

/// 可复用的单点位可视化组件，供各协议调试页（Modbus / OPC UA）内嵌，
/// 替代原先独立的「可视化」页。数据来自调用方按 source 过滤后的 DataPoint 序列。
///
/// 用法示例：
/// ```dart
/// TrendCard(label: '寄存器 $k', points: _series[k]!),
/// GaugeCard(label: '寄存器 $k', points: _series[k]!),
/// ```

/// 单点位趋势卡片（自绘折线，按采样顺序）。
class TrendCard extends StatelessWidget {
  const TrendCard({
    super.key,
    required this.label,
    required this.points,
    this.height = 120,
  });

  final String label;
  final List<DataPoint> points;

  /// 曲线绘制区高度，监控页可传更大值。
  final double height;

  @override
  Widget build(BuildContext context) {
    final vals = points.map((e) => e.value.toDouble()).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SizedBox(
              height: height,
              child: CustomPaint(
                size: Size(double.infinity, height),
                painter: _TrendPainter(vals),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.values);

  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) {
      final t = TextPainter(
        text: const TextSpan(
          text: '采样点不足',
          style: TextStyle(color: Colors.grey),
        ),
        textDirection: TextDirection.ltr,
      );
      t.layout();
      t.paint(canvas,
          Offset(size.width / 2 - t.width / 2, size.height / 2 - t.height / 2));
      return;
    }
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    final range = (hi - lo) == 0 ? 1.0 : hi - lo;
    final dx = size.width / (values.length - 1);
    final paint = Paint()
      ..color = Colors.teal
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i * dx;
      final y = size.height - ((values[i] - lo) / range) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

/// 单点位仪表盘卡片（半圆弧 + 指针，范围按近期数据动态计算）。
class GaugeCard extends StatelessWidget {
  const GaugeCard({
    super.key,
    required this.label,
    required this.points,
    this.width = 160,
  });

  final String label;
  final List<DataPoint> points;

  /// 卡片整体宽度，监控页可传更大值（弧面按比例放大）。
  final double width;

  @override
  Widget build(BuildContext context) {
    final vals = points.map((e) => e.value.toDouble()).toList();
    if (vals.isEmpty) return const SizedBox.shrink();
    final lo = vals.reduce((a, b) => a < b ? a : b);
    final hi = vals.reduce((a, b) => a > b ? a : b);
    final value = vals.last;
    final arcW = width - 20;
    final arcH = arcW * 100 / 140;
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(label,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              SizedBox(
                height: arcH,
                width: arcW,
                child: CustomPaint(
                  size: Size(arcW, arcH),
                  painter: _GaugePainter(value, lo, hi),
                ),
              ),
              const SizedBox(height: 4),
              Text(value.toStringAsFixed(2),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.value, this.min, this.max);

  final double value;
  final double min;
  final double max;

  @override
  void paint(Canvas canvas, Size size) {
    const start = -pi; // 从左开始
    const sweep = pi; // 半圆
    final cx = size.width / 2;
    final cy = size.height - 8;
    final r = size.width / 2 - 8;

    final bg = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: r), start,
        sweep, false, bg);

    final range = (max - min) == 0 ? 1.0 : max - min;
    final t = ((value - min) / range).clamp(0.0, 1.0);
    final fg = Paint()
      ..color = Colors.teal
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: r), start,
        sweep * t, false, fg);

    // 指针
    final angle = start + sweep * t;
    final px = cx + cos(angle) * (r - 2);
    final py = cy + sin(angle) * (r - 2);
    final needle = Paint()
      ..color = Colors.red.shade400
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx, cy), Offset(px, py), needle);
    canvas.drawCircle(Offset(cx, cy), 4, Paint()..color = Colors.red.shade400);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}
