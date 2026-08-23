import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 应用内下载并安装 APK。
///
/// Android 上通过 [MethodChannel] 调用系统 [DownloadManager] 下载更新包，
/// 下载完成后自动拉起系统安装器；非 Android 或通道不可用时，回退到浏览器
/// 打开下载链接。调用方无需关心平台差异。
///
/// 下载 / 安装状态会通过 [onInstallEvent]（EventChannel）实时回传：
///   {status:'started'}
///   {status:'progress', downloaded:int, total:int}
///   {status:'completed'}
///   {status:'failed', message:String}
class AppInstaller {
  AppInstaller._();
  static const _channel = MethodChannel('everlink/installer');
  static const _events = EventChannel('everlink/installer_events');

  static Stream<Map<String, dynamic>>? _installStream;

  /// 下载 / 安装状态事件流（原生侧回传）。首次访问时建立订阅。
  static Stream<Map<String, dynamic>> get onInstallEvent {
    _installStream ??= _events
        .receiveBroadcastStream()
        .map((e) => (e as Map<Object?, Object?>).cast<String, dynamic>());
    return _installStream!;
  }

  /// 下载并安装指定 APK。返回是否成功发起（Android 上表示已开始下载）。
  static Future<bool> downloadAndInstall(String url) async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<bool>('downloadAndInstall', {'url': url});
        return true;
      } on PlatformException {
        // 通道不可用，回退到浏览器。
      }
    }
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return true;
    }
    return false;
  }
}
