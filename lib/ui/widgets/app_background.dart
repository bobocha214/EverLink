import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:everlink/services/settings_service.dart';
import 'package:everlink/utils/app_theme.dart';

/// 全局页面背景层：由 [MaterialApp.builder] 注入到所有页面之下。
///
/// - 背景关闭或未选择图片：显示纯主题色（与未启用时一致）。
/// - 背景开启且已选本地图片：绘制该图片（文件缺失则自动降级为纯色），
///   叠加可调模糊与暗化层保证前景内容始终可读；
/// - 顶部一抹品牌色渐隐，提供层次（延续液态玻璃观感）。
class AppBackground extends StatelessWidget {
  const AppBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    final brightness = Theme.of(context).brightness;
    final scheme = Theme.of(context).colorScheme;

    final baseColor =
        brightness == Brightness.light ? AppTheme.lightBg : AppTheme.darkBg;

    final imgPath = settings.backgroundImagePath;
    if (imgPath == null ||
        !settings.backgroundEnabled ||
        !File(imgPath).existsSync()) {
      return Container(color: baseColor);
    }

    final blur = settings.backgroundBlur;
    final dim = settings.backgroundDim;

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(File(imgPath), fit: BoxFit.cover),
        if (blur > 0)
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: const SizedBox.expand(),
          ),
        Container(color: Colors.black.withValues(alpha: dim)),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.center,
              colors: [
                scheme.primary.withValues(alpha: 0.10),
                Colors.transparent,
              ],
            ),
          ),
        ),
      ],
    );
  }
}
