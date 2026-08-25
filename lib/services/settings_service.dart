import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/protocol_registry.dart';
import 'package:everlink/utils/app_constants.dart';

/// 全局应用设置（协议启用状态、主题、更新来源），持久化到 SharedPreferences。
///
/// 单例 + [ChangeNotifier]，UI 可监听并随设置变化刷新（例如切换主题时
/// MaterialApp 会重建）。
class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  late SharedPreferences _prefs;
  bool _initialized = false;

  /// 已启用的协议集合（默认全部启用）。
  final Set<ProtocolType> _enabledProtocols = {};

  ThemeMode _themeMode = ThemeMode.system;
  /// 更新来源：0 = GitHub，1 = Gitee。
  int _updateSource = 0;
  /// 启动时自动检查更新（默认开启）。
  bool _autoCheckUpdate = true;
  /// 上次自动检查更新的时间戳（ms），用于避免短时间内重复检查。
  int _lastAutoCheckMs = 0;

  // —— 外观 ——
  /// 主题配色预设索引（0=青绿，详见 [AppTheme] 的调色板）。
  int _accentIndex = 0;
  /// 圆角风格：0=紧凑 / 1=标准 / 2=宽松。
  int _cornerStyle = 1;
  /// 玻璃质感强度：0=关 / 1=轻 / 2=中 / 3=强。
  int _glassStrength = 2;

  // —— 背景 ——
  /// 是否启用自定义背景（使用本地图片）。
  bool _backgroundEnabled = false;
  /// 本地背景图片的本地文件系统路径（开启自定义背景后生效）。
  String? _backgroundImagePath;
  /// 背景模糊强度（sigma，0~12）。
  double _backgroundBlur = 4.0;
  /// 背景暗化强度（0~0.75，保证前景内容可读）。
  double _backgroundDim = 0.35;

  // —— 导航 ——
  /// 底部菜单栏是否悬浮（毛玻璃浮动样式）。
  bool _navFloating = true;

  bool get initialized => _initialized;

  /// 从本地存储载入设置。必须在 [runApp] 之前 await。
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    // 协议：首次无记录则默认全部启用。
    final saved = _prefs.getStringList('enabled_protocols');
    if (saved == null) {
      _enabledProtocols.addAll(ProtocolRegistry.all.map((d) => d.type));
    } else {
      for (final name in saved) {
        final type = ProtocolType.values.where((t) => t.name == name);
        if (type.isNotEmpty) _enabledProtocols.add(type.first);
      }
    }

    // 主题：0=跟随系统, 1=浅色, 2=深色。
    final tm = _prefs.getInt('theme_mode') ?? 0;
    _themeMode = ThemeMode.values[tm.clamp(0, ThemeMode.values.length - 1)];

    _updateSource = _prefs.getInt('update_source') ?? 0;
    _autoCheckUpdate = _prefs.getBool('auto_check_update') ?? true;
    _lastAutoCheckMs = _prefs.getInt('last_auto_check_ms') ?? 0;

    // 外观
    _accentIndex = _prefs.getInt('accent_index') ?? 0;
    _cornerStyle = _prefs.getInt('corner_style') ?? 1;
    _glassStrength = _prefs.getInt('glass_strength') ?? 2;
    // 背景
    _backgroundEnabled = _prefs.getBool('background_enabled') ?? false;
    _backgroundImagePath = _prefs.getString('background_image_path');
    _backgroundBlur = _prefs.getDouble('background_blur') ?? 4.0;
    _backgroundDim = _prefs.getDouble('background_dim') ?? 0.35;
    // 导航
    _navFloating = _prefs.getBool('nav_floating') ?? true;

    _initialized = true;
    notifyListeners();
  }

  bool isProtocolEnabled(ProtocolType t) => _enabledProtocols.contains(t);

  Future<void> setProtocolEnabled(ProtocolType t, bool enabled) async {
    final changed = enabled
        ? _enabledProtocols.add(t)
        : _enabledProtocols.remove(t);
    if (!changed) return;
    await _prefs.setStringList(
      'enabled_protocols',
      _enabledProtocols.map((e) => e.name).toList(),
    );
    notifyListeners();
  }

  ThemeMode get themeMode => _themeMode;

  Future<void> setThemeMode(ThemeMode m) async {
    if (_themeMode == m) return;
    _themeMode = m;
    await _prefs.setInt('theme_mode', m.index);
    notifyListeners();
  }

  /// 更新来源：0 = GitHub，1 = Gitee。
  int get updateSource => _updateSource;

  Future<void> setUpdateSource(int source) async {
    _updateSource = source.clamp(0, 1);
    await _prefs.setInt('update_source', _updateSource);
    notifyListeners();
  }

  /// 启动时是否自动检查更新。
  bool get autoCheckUpdate => _autoCheckUpdate;

  Future<void> setAutoCheckUpdate(bool value) async {
    if (_autoCheckUpdate == value) return;
    _autoCheckUpdate = value;
    await _prefs.setBool('auto_check_update', _autoCheckUpdate);
    notifyListeners();
  }

  /// 上次自动检查更新的时间戳（ms）。
  int get lastAutoCheckMs => _lastAutoCheckMs;

  Future<void> setLastAutoCheckMs(int ms) async {
    _lastAutoCheckMs = ms;
    await _prefs.setInt('last_auto_check_ms', _lastAutoCheckMs);
  }

  /// 项目文档主页地址。
  String get docsUrl => AppConstants.docsUrl;

  // —— 外观 ——
  int get accentIndex => _accentIndex;

  Future<void> setAccentIndex(int v) async {
    if (_accentIndex == v) return;
    _accentIndex = v;
    await _prefs.setInt('accent_index', v);
    notifyListeners();
  }

  int get cornerStyle => _cornerStyle;

  Future<void> setCornerStyle(int v) async {
    if (_cornerStyle == v) return;
    _cornerStyle = v;
    await _prefs.setInt('corner_style', v);
    notifyListeners();
  }

  int get glassStrength => _glassStrength;

  Future<void> setGlassStrength(int v) async {
    if (_glassStrength == v) return;
    _glassStrength = v;
    await _prefs.setInt('glass_strength', v);
    notifyListeners();
  }

  // —— 背景 ——
  bool get backgroundEnabled => _backgroundEnabled;

  Future<void> setBackgroundEnabled(bool v) async {
    if (_backgroundEnabled == v) return;
    _backgroundEnabled = v;
    await _prefs.setBool('background_enabled', v);
    notifyListeners();
  }

  String? get backgroundImagePath => _backgroundImagePath;

  Future<void> setBackgroundImagePath(String? path) async {
    if (_backgroundImagePath == path) return;
    _backgroundImagePath = path;
    if (path == null) {
      await _prefs.remove('background_image_path');
    } else {
      await _prefs.setString('background_image_path', path);
    }
    notifyListeners();
  }

  double get backgroundBlur => _backgroundBlur;

  Future<void> setBackgroundBlur(double v) async {
    v = v.clamp(0.0, 12.0);
    if (_backgroundBlur == v) return;
    _backgroundBlur = v;
    await _prefs.setDouble('background_blur', v);
    notifyListeners();
  }

  double get backgroundDim => _backgroundDim;

  Future<void> setBackgroundDim(double v) async {
    v = v.clamp(0.0, 0.75);
    if (_backgroundDim == v) return;
    _backgroundDim = v;
    await _prefs.setDouble('background_dim', v);
    notifyListeners();
  }

  // —— 导航 ——
  bool get navFloating => _navFloating;

  Future<void> setNavFloating(bool v) async {
    if (_navFloating == v) return;
    _navFloating = v;
    await _prefs.setBool('nav_floating', v);
    notifyListeners();
  }

  /// 当前已启用的协议描述符（供添加设备、首页筛选等处使用）。
  List<ProtocolDescriptor> get enabledDescriptors =>
      ProtocolRegistry.all
          .where((d) => isProtocolEnabled(d.type))
          .toList();
}
