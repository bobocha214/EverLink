import 'package:flutter/material.dart';

import 'package:everlink/ui/widgets/app_background.dart';

/// 统一页面切换过渡：淡入 + 轻微右滑 + 微缩放，缓动 easeOutCubic。
///
/// 关键修复：每个被 push 的页面都在自身 Scaffold 之下垫一层不透明的
/// [AppBackground]，使新页面在切换时成为“实底”，彻底避免旧页面透过透明
/// Scaffold 在切换瞬间留下的残影（旧方案仅依赖全局 builder 的背景层，新页面
/// 背景透明时会在淡入/滑入过程中透出下方旧页面）。
class AppRoutes {
  AppRoutes._();

  static const Duration _duration = Duration(milliseconds: 280);
  static const Duration _reverseDuration = Duration(milliseconds: 220);

  /// 构造一个带统一过渡动画的 [Route]。
  static Route<T> page<T>(Widget page) {
    return PageRouteBuilder<T>(
      transitionDuration: _duration,
      reverseTransitionDuration: _reverseDuration,
      // 新页面自带不透明背景层，覆盖下方旧页面 —— 这是消除残影的关键。
      pageBuilder: (context, animation, secondaryAnimation) => Stack(
        fit: StackFit.expand,
        children: [const AppBackground(), page],
      ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        const curve = Curves.easeOutCubic;
        final slide = Tween<Offset>(
          begin: const Offset(0.035, 0), // 从右侧轻微滑入，而非整屏横移
          end: Offset.zero,
        ).chain(CurveTween(curve: curve)).animate(animation);
        final fade = CurvedAnimation(parent: animation, curve: curve);
        final scale = Tween<double>(begin: 0.992, end: 1.0)
            .chain(CurveTween(curve: curve))
            .animate(animation);
        return FadeTransition(
          opacity: fade,
          child: SlideTransition(
            position: slide,
            child: ScaleTransition(scale: scale, child: child),
          ),
        );
      },
    );
  }

  /// 以统一过渡推入一个新页面。
  static Future<T?> push<T>(BuildContext context, Widget page) {
    return Navigator.of(context).push<T>(AppRoutes.page<T>(page));
  }

  /// 以统一过渡替换当前页面。
  ///
  /// 用于同组工具子页之间的快捷切换，避免反复 push 把页面栈堆厚
  /// （例如进制工具五个页面互相跳转时）。
  static Future<T?> replace<T>(BuildContext context, Widget page) {
    return Navigator.of(context).pushReplacement<T, T>(AppRoutes.page<T>(page));
  }
}
