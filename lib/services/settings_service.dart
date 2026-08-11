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

  /// 当前已启用的协议描述符（供添加设备、首页筛选等处使用）。
  List<ProtocolDescriptor> get enabledDescriptors =>
      ProtocolRegistry.all
          .where((d) => isProtocolEnabled(d.type))
          .toList();
}
