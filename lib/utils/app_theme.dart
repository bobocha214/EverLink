import 'package:flutter/material.dart';

/// EverLink 的视觉主题。
///
/// 刻意不使用 [ColorScheme.fromSeed]，而是手动定义一套低饱和、克制的配色，
/// 避免 Material 3 自动生成的“高饱和 + 渐变感”模板气质。主色保留品牌 teal，
/// 但压到沉稳的 teal-700（亮色）/ teal-500（暗色），并把大量空间留给中性灰阶，
/// 通过“扁平描边卡片 + 柔和层次”替代默认的投影堆叠。
class AppTheme {
  AppTheme._();

  // —— 亮色 ——
  static const Color _lightPrimary = Color(0xFF0F766E); // teal-700，沉稳
  static const Color _lightOnPrimary = Color(0xFFFFFFFF);
  static const Color _lightPrimaryContainer = Color(0xFFD2F4EE);
  static const Color _lightOnPrimaryContainer = Color(0xFF004F47);
  static const Color _lightBg = Color(0xFFF5F6F8); // 冷灰白背景
  static const Color _lightSurface = Color(0xFFFFFFFF);
  static const Color _lightOnSurface = Color(0xFF16191C);
  static const Color _lightOnSurfaceVariant = Color(0xFF5B6663);
  static const Color _lightOutline = Color(0xFFE2E6E4);
  static const Color _lightOutlineVariant = Color(0xFFEAEEEC);
  static const Color _lightSurfaceVariant = Color(0xFFEDF1F0);

  // —— 暗色 ——
  static const Color _darkPrimary = Color(0xFF14B8A6); // teal-500，暗底需更亮
  static const Color _darkOnPrimary = Color(0xFF00302A);
  static const Color _darkPrimaryContainer = Color(0xFF0C3B36);
  static const Color _darkOnPrimaryContainer = Color(0xFF9DEEE2);
  static const Color _darkBg = Color(0xFF0D0F12);
  static const Color _darkSurface = Color(0xFF171A1E);
  static const Color _darkOnSurface = Color(0xFFE6E9E8);
  static const Color _darkOnSurfaceVariant = Color(0xFF9AA6A2);
  static const Color _darkOutline = Color(0xFF2A2F33);
  static const Color _darkOutlineVariant = Color(0xFF32383D);
  static const Color _darkSurfaceVariant = Color(0xFF21262B);

  static ColorScheme _scheme(Brightness brightness) {
    final light = brightness == Brightness.light;
    return ColorScheme(
      brightness: brightness,
      primary: light ? _lightPrimary : _darkPrimary,
      onPrimary: light ? _lightOnPrimary : _darkOnPrimary,
      primaryContainer: light ? _lightPrimaryContainer : _darkPrimaryContainer,
      onPrimaryContainer:
          light ? _lightOnPrimaryContainer : _darkOnPrimaryContainer,
      secondary: light ? _lightPrimary : _darkPrimary,
      onSecondary: light ? _lightOnPrimary : _darkOnPrimary,
      secondaryContainer:
          light ? _lightPrimaryContainer : _darkPrimaryContainer,
      onSecondaryContainer:
          light ? _lightOnPrimaryContainer : _darkOnPrimaryContainer,
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

  /// 根据亮度构建一套完整的 [ThemeData]。
  static ThemeData build(Brightness brightness) {
    final scheme = _scheme(brightness);
    final isLight = brightness == Brightness.light;
    final cardRadius = BorderRadius.circular(16);
    final controlRadius = BorderRadius.circular(12);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: isLight ? _lightBg : _darkBg,
      // AppBar 融入背景、无阴影，更现代
      appBarTheme: AppBarTheme(
        backgroundColor: isLight ? _lightBg : scheme.surface,
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
        color: scheme.surface,
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
        fillColor: isLight ? scheme.surface : scheme.surfaceContainerHighest,
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 0,
        backgroundColor: scheme.surface,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(color: scheme.outline),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        backgroundColor: scheme.surface,
      ),
      visualDensity: VisualDensity.adaptivePlatformDensity,
    );
  }
}
