import 'package:flutter/material.dart';

/// 响应式网格：窄屏单列，宽屏（桌面 / 横屏平板）自动多列。
///
/// 依据可用宽度计算列数，使用 [Wrap] 实现「瀑布流」式排布，因此卡片高度
/// 可以不一致而不会被强制拉伸（比 GridView 的固定行高更适合内容卡片）。
/// 自身不创建滚动视图，可直接放进 ListView / Column / Expanded 中。
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({
    super.key,
    required this.children,
    this.spacing = 12,
    this.maxColumns = 4,
  });

  final List<Widget> children;
  final double spacing;
  final int maxColumns;

  /// 根据宽度返回列数：>=1500 → 4，>=1050 → 3，>=640 → 2，否则 1。
  static int columnsForWidth(double width, {int maxColumns = 4}) {
    final int cols = switch (width) {
      >= 1500 => 4,
      >= 1050 => 3,
      >= 640 => 2,
      _ => 1,
    };
    return cols.clamp(1, maxColumns);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final cols =
            columnsForWidth(constraints.maxWidth, maxColumns: maxColumns);
        final childWidth =
            (constraints.maxWidth - spacing * (cols - 1)) / cols;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children)
              SizedBox(width: childWidth, child: child),
          ],
        );
      },
    );
  }
}
