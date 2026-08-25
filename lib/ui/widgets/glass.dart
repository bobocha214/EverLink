import 'dart:ui';

import 'package:flutter/material.dart';

/// 液态玻璃容器：真模糊（BackdropFilter）+ 半透明表面 + 渐变高光 +
/// 1px 描边 + 品牌色柔和光晕。用于悬浮菜单栏、对话框等需要"毛玻璃"质感的场合。
///
/// [blur]=0 时仅保留表面半透明与描边（不启用模糊层），仍可作为轻量卡片使用。
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    this.child,
    this.borderRadius = 20,
    this.blur = 14,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.surfaceAlpha = 0.55,
    this.onTap,
  });

  final Widget? child;
  final double borderRadius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final double surfaceAlpha;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    final glass = Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.55),
          width: 1,
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: isDark ? 0.12 : 0.40),
            Colors.white.withValues(alpha: isDark ? 0.02 : 0.08),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: isDark ? 0.20 : 0.14),
            blurRadius: 26,
            spreadRadius: -8,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            color: scheme.surface.withValues(alpha: surfaceAlpha),
            child: child,
          ),
        ),
      ),
    );

    if (onTap == null) return glass;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(borderRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(borderRadius),
        onTap: onTap,
        splashColor: scheme.primary.withValues(alpha: 0.2),
        highlightColor: scheme.primary.withValues(alpha: 0.08),
        child: glass,
      ),
    );
  }
}
