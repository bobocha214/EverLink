import 'package:flutter/material.dart';

import 'package:everlink/services/settings_service.dart';

/// 单套品牌强调色（accent）在亮 / 暗两套下的主色派生。
///
/// 仅主色系随 accent 变化，中性灰阶保持全局统一，避免大面积撞色导致的不协调。
class _Accent {
  const _Accent({
    required this.name,
    required this.lightPrimary,
    required this.lightOnPrimary,
    required this.lightPrimaryContainer,
    required this.lightOnPrimaryContainer,
    required this.darkPrimary,
    required this.darkOnPrimary,
    required this.darkPrimaryContainer,
    required this.darkOnPrimaryContainer,
  });

  final String name;
  final Color lightPrimary;
  final Color lightOnPrimary;
  final Color lightPrimaryContainer;
  final Color lightOnPrimaryContainer;
  final Color darkPrimary;
  final Color darkOnPrimary;
  final Color darkPrimaryContainer;
  final Color darkOnPrimaryContainer;
}

/// EverLink 的视觉主题。
///
/// 刻意不使用 [ColorScheme.fromSeed]，而是手动定义一套低饱和、克制的配色，
/// 避免 Material 3 自动生成的“高饱和 + 渐变感”模板气质。主色保留品牌 teal，
/// 但压到沉稳的 teal-700（亮色）/ teal-500（暗色），并把大量空间留给中性灰阶，
/// 通过“扁平描边卡片 + 柔和层次”替代默认的投影堆叠。
///
/// 主题配色（accent）、圆角风格、玻璃强度等可由 [SettingsService] 在运行时调整。
class AppTheme {
  AppTheme._();

  /// 主题配色预设（index 与 [SettingsService.accentIndex] 对应）。
  static const List<_Accent> _accents = [
    _Accent(
      name: '青绿',
      lightPrimary: Color(0xFF0F766E),
      lightOnPrimary: Color(0xFFFFFFFF),
      lightPrimaryContainer: Color(0xFFD2F4EE),
      lightOnPrimaryContainer: Color(0xFF004F47),
      darkPrimary: Color(0xFF14B8A6),
      darkOnPrimary: Color(0xFF00302A),
      darkPrimaryContainer: Color(0xFF0C3B36),
      darkOnPrimaryContainer: Color(0xFF9DEEE2),
    ),
    _Accent(
      name: '蓝',
      lightPrimary: Color(0xFF1565C0),
      lightOnPrimary: Color(0xFFFFFFFF),
      lightPrimaryContainer: Color(0xFFD6E4FF),
      lightOnPrimaryContainer: Color(0xFF0B3D91),
      darkPrimary: Color(0xFF4DA3FF),
      darkOnPrimary: Color(0xFF00305A),
      darkPrimaryContainer: Color(0xFF0E47A6),
      darkOnPrimaryContainer: Color(0xFFE1EFFD),
    ),
    _Accent(
      name: '靛',
      lightPrimary: Color(0xFF3949AB),
      lightOnPrimary: Color(0xFFFFFFFF),
      lightPrimaryContainer: Color(0xFFE0E2F5),
      lightOnPrimaryContainer: Color(0xFF1A237E),
      darkPrimary: Color(0xFF7986CB),
      darkOnPrimary: Color(0xFF1A237E),
      darkPrimaryContainer: Color(0xFF283593),
      darkOnPrimaryContainer: Color(0xFFE8EAF6),
    ),
    _Accent(
      name: '紫',
      lightPrimary: Color(0xFF7B1FA2),
      lightOnPrimary: Color(0xFFFFFFFF),
      lightPrimaryContainer: Color(0xFFF3E0F7),
      lightOnPrimaryContainer: Color(0xFF4A0072),
      darkPrimary: Color(0xFFBA68C8),
      darkOnPrimary: Color(0xFF3A004F),
      darkPrimaryContainer: Color(0xFF6A1B9A),
      darkOnPrimaryContainer: Color(0xFFF5E6FB),
    ),
    _Accent(
      name: '玫红',
      lightPrimary: Color(0xFFC2185B),
      lightOnPrimary: Color(0xFFFFFFFF),
      lightPrimaryContainer: Color(0xFFF8D7E5),
      lightOnPrimaryContainer: Color(0xFF7A003C),
      darkPrimary: Color(0xFFEC7BA0),
      darkOnPrimary: Color(0xFF5C002E),
      darkPrimaryContainer: Color(0xFFB3336A),
      darkOnPrimaryContainer: Color(0xFFFCE4EE),
    ),
    _Accent(
      name: '橙',
      lightPrimary: Color(0xFFE65100),
      lightOnPrimary: Color(0xFFFFFFFF),
      lightPrimaryContainer: Color(0xFFFFE0B2),
      lightOnPrimaryContainer: Color(0xFF7A2E00),
      darkPrimary: Color(0xFFFF9E40),
      darkOnPrimary: Color(0xFF5C2E00),
      darkPrimaryContainer: Color(0xFFC75B00),
      darkOnPrimaryContainer: Color(0xFFFFE9D6),
    ),
    _Accent(
      name: '青蓝',
      lightPrimary: Color(0xFF00838F),
      lightOnPrimary: Color(0xFFFFFFFF),
      lightPrimaryContainer: Color(0xFFD0F4F7),
      lightOnPrimaryContainer: Color(0xFF00363B),
      darkPrimary: Color(0xFF4DD0E1),
      darkOnPrimary: Color(0xFF00363B),
      darkPrimaryContainer: Color(0xFF0A6E78),
      darkOnPrimaryContainer: Color(0xFFD6F6FA),
    ),
  ];

  /// 供设置页展示的配色色卡（名称 + 展示色）。
  static List<(String, Color)> get accentOptions =>
      _accents.map((a) => (a.name, a.lightPrimary)).toList();

  /// 圆角风格选项（名称 + 索引）。
  static const List<(String, int)> cornerOptions = [
    ('紧凑', 0),
    ('标准', 1),
    ('宽松', 2),
  ];

  /// 玻璃质感强度选项（名称 + 索引）。
  static const List<(String, int)> glassOptions = [
    ('关', 0),
    ('轻', 1),
    ('中', 2),
    ('强', 3),
  ];

  /// 玻璃强度 → 模糊 sigma 的映射（悬浮底栏 / 玻璃容器据此取值）。
  static double glassBlur(int strength) {
    switch (strength) {
      case 0:
        return 0;
      case 1:
        return 8;
      case 3:
        return 22;
      default:
        return 14;
    }
  }

  /// 圆角风格 → 半径缩放因子。
  static double _cornerFactor(int style) {
    switch (style) {
      case 0:
        return 0.75;
      case 2:
        return 1.25;
      default:
        return 1.0;
    }
  }

  // —— 中性灰阶（不随 accent 变化）——

  // 亮色
  static const Color _lightBg = Color(0xFFF5F6F8); // 冷灰白背景
  /// 公开底色常量，供全局背景层 [AppBackground] 复用，避免魔法数字重复。
  static const Color lightBg = _lightBg;
  static const Color _lightSurface = Color(0xFFFFFFFF);
  static const Color _lightOnSurface = Color(0xFF16191C);
  static const Color _lightOnSurfaceVariant = Color(0xFF5B6663);
  static const Color _lightOutline = Color(0xFFE2E6E4);
  static const Color _lightOutlineVariant = Color(0xFFEAEEEC);
  static const Color _lightSurfaceVariant = Color(0xFFEDF1F0);

  // 暗色
  static const Color darkBg = Color(0xFF0D0F12);
  static const Color _darkSurface = Color(0xFF171A1E);
  static const Color _darkOnSurface = Color(0xFFE6E9E8);
  static const Color _darkOnSurfaceVariant = Color(0xFF9AA6A2);
  static const Color _darkOutline = Color(0xFF2A2F33);
  static const Color _darkOutlineVariant = Color(0xFF32383D);
  static const Color _darkSurfaceVariant = Color(0xFF21262B);

  static ColorScheme _scheme(Brightness brightness, _Accent accent) {
    final light = brightness == Brightness.light;
    final primary = light ? accent.lightPrimary : accent.darkPrimary;
    final onPrimary = light ? accent.lightOnPrimary : accent.darkOnPrimary;
    final primaryContainer =
        light ? accent.lightPrimaryContainer : accent.darkPrimaryContainer;
    final onPrimaryContainer =
        light ? accent.lightOnPrimaryContainer : accent.darkOnPrimaryContainer;
    return ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: primary,
      onSecondary: onPrimary,
      secondaryContainer: primaryContainer,
      onSecondaryContainer: onPrimaryContainer,
      surface: light ? _lightSurface : _darkSurface,
      onSurface: light ? _lightOnSurface : _darkOnSurface,
      surfaceContainerHighest: light ? _lightSurfaceVariant : _darkSurfaceVariant,
      onSurfaceVariant:
          light ? _lightOnSurfaceVariant : _darkOnSurfaceVariant,
      outline: light ? _lightOutline : _darkOutline,
      outlineVariant: light ? _lightOutlineVariant : _darkOutlineVariant,
      error: light ? const Color(0xFFB3261E) : const Color(0xFFF2B8B5),
      onError: light ? const Color(0xFFFFFFFF) : const Color(0xFF601410),
      errorContainer:
          light ? const Color(0xFFF9DEDC) : const Color(0xFF8C1D18),
      onErrorContainer:
          light ? const Color(0xFF410E0B) : const Color(0xFFF9DEDC),
    );
  }

  /// 根据亮度与当前设置（accent / 圆角）构建一套完整的 [ThemeData]。
  static ThemeData build(Brightness brightness) {
    final accent = _accents[
        SettingsService.instance.accentIndex.clamp(0, _accents.length - 1)];
    final scheme = _scheme(brightness, accent);
    final isLight = brightness == Brightness.light;
    final f = _cornerFactor(SettingsService.instance.cornerStyle.clamp(0, 2));
    // 启用自定义背景时，把卡片 / 弹层 / 顶栏等“内容容器”改为半透明表面，
    // 透出底层彩色背景，使整体协调；关闭背景时保持原本的不透明纯色。
    final bgOn = SettingsService.instance.backgroundEnabled;
    final surfaceGlass = scheme.surface.withValues(alpha: bgOn ? 0.80 : 1.0);
    final cardRadius = BorderRadius.circular(16 * f);
    final controlRadius = BorderRadius.circular(12 * f);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      // 背景由全局 AppBackground 提供（纯色 / 预设渐变 / 本地图），
      // 这里置透明以透出底层背景。
      scaffoldBackgroundColor: Colors.transparent,
      // AppBar 融入背景、无阴影，更现代
      appBarTheme: AppBarTheme(
        backgroundColor: bgOn ? surfaceGlass : (isLight ? _lightBg : scheme.surface),
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      ),
      // 扁平描边卡片，替代默认投影
      cardTheme: CardThemeData(
        color: surfaceGlass,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: cardRadius,
          side: BorderSide(color: scheme.outline, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outline,
        thickness: 1,
        space: 1,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16),
        minLeadingWidth: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(borderRadius: controlRadius),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: controlRadius),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: controlRadius),
          side: BorderSide(color: scheme.outline),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceGlass,
        border: OutlineInputBorder(
          borderRadius: controlRadius,
          borderSide: BorderSide(color: scheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: controlRadius,
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: controlRadius,
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20 * f)),
        elevation: 0,
        backgroundColor: surfaceGlass,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaceGlass,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? scheme.primary : null),
        trackColor: WidgetStateProperty.resolveWith((states) => states
                .contains(WidgetState.selected)
            ? scheme.primary.withValues(alpha: 0.5)
            : null),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8 * f)),
        side: BorderSide(color: scheme.outline),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        backgroundColor: surfaceGlass,
      ),
      visualDensity: VisualDensity.adaptivePlatformDensity,
    );
  }
}
