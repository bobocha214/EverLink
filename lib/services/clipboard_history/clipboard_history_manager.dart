import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条本地剪贴板历史记录。
class ClipboardHistoryItem {
  final String id;
  final String text;
  final DateTime time;

  /// 来源：'app' = 本应用主动复制；'system' = 系统剪贴板变化（其它 App 或本机复制）。
  final String source;

  ClipboardHistoryItem({
    required this.id,
    required this.text,
    required this.time,
    this.source = 'system',
  });

  factory ClipboardHistoryItem.fromJson(Map<String, dynamic> m) =>
      ClipboardHistoryItem(
        id: m['id'] as String,
        text: m['text'] as String? ?? '',
        time: DateTime.fromMillisecondsSinceEpoch(m['time'] as int),
        source: m['source'] as String? ?? 'system',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'time': time.millisecondsSinceEpoch,
        'source': source,
      };

  String get preview {
    if (text.length <= 120) return text;
    return '${text.substring(0, 120)}…';
  }
}

/// 系统剪贴板变化监听器适配器（实现 clipboard_watcher 的接口）。
class _WatcherListener with ClipboardListener {
  final ClipboardHistoryManager manager;
  _WatcherListener(this.manager);

  @override
  void onClipboardChanged() => manager.captureFromSystem();
}

/// 本地剪贴板历史管理器。
///
/// 通过 [ClipboardWatcher]（原生平台监听，事件驱动）在 EverLink 处于前台时捕获系统剪贴板变化，
/// 任何 App（含后台切回前台后的复制）被复制的文本都会记录到本地，持久化到 SharedPreferences。
/// 另提供 [copyAndRecord] 用于记录本应用内主动复制的内容，确保应用内复制也不遗漏。
///
/// 平台限制：受 Android 10+ / iOS 14+ 系统策略约束，剪贴板仅能在应用处于前台时被读取，
/// 因此"其它 App 在后台的复制"无法被捕获——这是系统层面的限制，非本实现缺陷。
class ClipboardHistoryManager {
  ClipboardHistoryManager._() {
    _watcherListener = _WatcherListener(this);
  }

  static final ClipboardHistoryManager instance = ClipboardHistoryManager._();

  static const String _kKey = 'clipboard_history_v1';
  static const int _kMax = 500;

  late final _WatcherListener _watcherListener;
  final List<ClipboardHistoryItem> _items = [];
  final _ctrl = StreamController<void>.broadcast();
  Stream<void> get onChange => _ctrl.stream;

  bool _initialized = false;
  bool _watching = false;

  List<ClipboardHistoryItem> get items => List.unmodifiable(_items);

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _load();
    // 注册系统剪贴板监听并启动原生监听。若平台不支持（如 web）或权限受限，
    // 降级为仅记录应用内复制，不影响已记录数据的展示。
    try {
      ClipboardWatcher.instance.addListener(_watcherListener);
      await ClipboardWatcher.instance.start();
      _watching = true;
    } catch (_) {
      _watching = false;
    }
  }

  /// 由原生监听回调触发：抓取当前系统剪贴板并追加（去重 + 限长）。
  Future<void> captureFromSystem() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _append(text, 'system');
  }

  /// 由本应用主动复制时调用：写剪贴板并记入历史（保证应用内复制也不遗漏）。
  Future<void> copyAndRecord(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _append(text, 'app');
  }

  void _append(String text, String source) {
    if (text.isEmpty) return;
    // 与最新一条相同则跳过（避免同一次复制被重复记录）。
    if (_items.isNotEmpty && _items.first.text == text) return;
    _items.insert(
      0,
      ClipboardHistoryItem(
        id: _uid(),
        text: text,
        time: DateTime.now(),
        source: source,
      ),
    );
    if (_items.length > _kMax) {
      _items.removeRange(_kMax, _items.length);
    }
    _save();
    _ctrl.add(null);
  }

  Future<void> remove(String id) async {
    _items.removeWhere((e) => e.id == id);
    await _save();
    _ctrl.add(null);
  }

  Future<void> clear() async {
    _items.clear();
    await _save();
    _ctrl.add(null);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _items
        ..clear()
        ..addAll(
          list
              .map((e) => ClipboardHistoryItem.fromJson(e as Map<String, dynamic>))
              .toList(),
        );
    } catch (_) {
      _items.clear();
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _items.map((e) => e.toJson()).toList();
    await prefs.setString(_kKey, jsonEncode(list));
  }

  String _uid() {
    final r = Random();
    return '${DateTime.now().millisecondsSinceEpoch}_${r.nextInt(1 << 31)}';
  }

  void dispose() {
    try {
      if (_watching) {
        ClipboardWatcher.instance.removeListener(_watcherListener);
        ClipboardWatcher.instance.stop();
      }
    } catch (_) {}
    _ctrl.close();
  }
}
