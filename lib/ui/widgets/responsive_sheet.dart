import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 响应式弹层：桌面端（Windows / Linux / macOS）以**居中对话框**展示，
/// 移动端保持原有的底部弹层（BottomSheet）体验。
///
/// 这样既不改动移动端的布局与尺寸，又解决了桌面端弹层贴底、不好看的问题。
///
/// 约定：[builder] 返回的内容应自带可滚动容器（如 [SingleChildScrollView]），
/// 或内部列表用 [ListView.shrinkWrap] / 受 [BoxConstraints] 约束——
/// 桌面端对话框有最大宽高约束，内容会自动在其中滚动。
Future<T?> showResponsiveSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  ShapeBorder? shape,
  Color? backgroundColor,
  double desktopMaxWidth = 560,
  double desktopMaxHeightFactor = 0.86,
}) async {
  if (!_isDesktop) {
    // 移动端：完全保持原来的底部弹层行为。
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      shape: shape,
      backgroundColor: backgroundColor,
      builder: builder,
    );
  }
  // 桌面端：居中对话框，带圆角与最大宽高约束。
  return showDialog<T>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: desktopMaxWidth,
          maxHeight: MediaQuery.sizeOf(ctx).height * desktopMaxHeightFactor,
        ),
        // 兜底滚动：即使调用方内容自带滚动，嵌套滚动也无害；
        // 若调用方忘记包滚动，这里保证内容超高时仍可滚动而非被裁切。
        child: SingleChildScrollView(
          child: builder(ctx),
        ),
      ),
    ),
  );
}

/// 是否为桌面平台（此处底部弹层体验差，应改用居中对话框）。
bool get _isDesktop {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;
}
