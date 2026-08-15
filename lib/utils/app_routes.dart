import 'package:flutter/material.dart';

/// 统一页面切换过渡：淡入 + 轻微右滑 + 微缩放，缓动 easeOutCubic。
///
/// 替代散落的 [MaterialPageRoute]，让全站导航手感一致、更顺滑、不显生硬。
class AppRoutes {
  AppRoutes._();

  static const Duration _duration = Duration(milliseconds: 300);
  static const Duration _reverseDuration = Duration(milliseconds: 240);

  /// 构造一个带统一过渡动画的 [Route]。
  static Route<T> page<T>(Widget page) {
    return PageRouteBuilder<T>(
      transitionDuration: _duration,
      reverseTransitionDuration: _reverseDuration,
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        const curve = Curves.easeOutCubic;
        final slide = Tween<Offset>(
          begin: const Offset(0.06, 0), // 从右侧轻微滑入，而非整屏横移
          end: Offset.zero,
        ).chain(CurveTween(curve: curve)).animate(animation);
        final fade = CurvedAnimation(parent: animation, curve: curve);
        final scale = Tween<double>(begin: 0.985, end: 1.0)
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
