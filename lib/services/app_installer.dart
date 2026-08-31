import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 应用内下载并安装更新包。
///
/// 按平台分流：
///  - **Android**：通过 [MethodChannel] 调用系统 [DownloadManager] 下载 APK，
///    下载完成后自动拉起系统安装器；状态由原生侧经 [EventChannel] 回传。
///  - **Windows**：直接下载 `.exe` 安装包到临时目录并发起安装（本类用 Dart
///    侧 [HttpClient] + [Process] 实现，进度事件由 [_nonAndroidController]
///    回传），不再错误地跳转到 Android 的 .apk。
///  - **iOS / Linux / macOS 等**：无内置安装能力，回退到浏览器打开下载链接。
///
/// 下载 / 安装状态通过 [onInstallEvent] 实时回传：
///   {status:'started'}
///   {status:'progress', downloaded:int, total:int}
///   {status:'completed'}
///   {status:'failed', message:String}
class AppInstaller {
  AppInstaller._();
  static const _channel = MethodChannel('everlink/installer');
  static const _events = EventChannel('everlink/installer_events');

  /// 非 Android 平台（Windows 等）的事件流，由 Dart 侧驱动。
  static StreamController<Map<String, dynamic>>? _nonAndroidController;

  /// 最近一次下载的 Windows 安装包路径，供「立即安装」按钮二次拉起。
  static String? _lastExePath;

  /// 下载 / 安装状态事件流（原生侧 / Dart 侧统一出口）。
  ///
  /// Android 上每次访问都建立一条全新的 [receiveBroadcastStream] 连接，
  /// 不缓存单例流——否则订阅被取消（弹框关闭）后原生 `onCancel` 会把
  /// `installEventSink` 置空，缓存流不会再触发 `onListen` 重建连接，
  /// 下一次下载完成的 `completed` 事件将彻底丢失，弹框永远停在"下载中"。
  static Stream<Map<String, dynamic>> get onInstallEvent {
    if (!Platform.isAndroid) {
      // 非 Android 走 Dart 侧事件流（Windows 下载 .exe、其它平台浏览器回退）。
      _nonAndroidController ??=
          StreamController<Map<String, dynamic>>.broadcast();
      return _nonAndroidController!.stream;
    }
    return _events
        .receiveBroadcastStream()
        .map((e) => (e as Map<Object?, Object?>).cast<String, dynamic>());
  }

  /// 下载并安装更新包。返回是否成功发起。
  ///
  /// - Android：调用原生通道开始下载 APK（返回 true 表示已开始）。
  /// - Windows 且为 .exe：下载到临时目录并（由「立即安装」按钮）拉起安装器。
  /// - 其它平台：以外部浏览器打开链接。
  static Future<bool> downloadAndInstall(String url) async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<bool>('downloadAndInstall', {'url': url});
        return true;
      } on PlatformException {
        // 通道不可用，回退到浏览器。
      }
    }
    if (Platform.isWindows && url.toLowerCase().endsWith('.exe')) {
      return _downloadAndRunExe(url);
    }
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      _emitNonAndroid({'status': 'completed'});
      return true;
    }
    return false;
  }

  /// 拉起安装器安装已下载的更新包。
  ///
  /// - Windows：运行已下载到临时目录的 .exe 安装器。
  /// - Android：调用原生 `installApk`（下载完成后手动触发 / 兜底）。
  /// - 其它平台：无内置安装能力，返回 false。
  static Future<bool> launchInstall() async {
    if (Platform.isWindows && _lastExePath != null) {
      try {
        await Process.start(_lastExePath!, [], runInShell: true);
        return true;
      } catch (_) {
        return false;
      }
    }
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('installApk');
      return ok == true;
    } on PlatformException {
      return false;
    }
  }

  // ── 非 Android 辅助 ──────────────────────────────────────

  static void _emitNonAndroid(Map<String, dynamic> e) {
    if (!Platform.isAndroid) _nonAndroidController?.add(e);
  }

  /// 下载 Windows .exe 到临时目录（不自动运行，由「立即安装」按钮拉起），
  /// 期间通过 [onInstallEvent] 回传进度。
  static Future<bool> _downloadAndRunExe(String url) async {
    HttpClient? client;
    try {
      _emitNonAndroid({'status': 'started'});
      client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        _emitNonAndroid({'status': 'failed', 'message': 'HTTP ${response.statusCode}'});
        return false;
      }
      final total = response.contentLength;
      final fileName =
          'everlink_update_${DateTime.now().millisecondsSinceEpoch}.exe';
      final file = File('${Directory.systemTemp.path}/$fileName');
      _lastExePath = file.path;
      final sink = file.openWrite();
      var downloaded = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        downloaded += chunk.length;
        if (total > 0) {
          _emitNonAndroid({
            'status': 'progress',
            'downloaded': downloaded,
            'total': total,
          });
        }
      }
      await sink.close();
      _emitNonAndroid({'status': 'completed'});
      return true;
    } catch (e) {
      _emitNonAndroid({'status': 'failed', 'message': '下载失败：$e'});
      return false;
    } finally {
      client?.close();
    }
  }
}
