import 'dart:async';

import 'package:flutter/material.dart';

import 'package:everlink/services/app_installer.dart';
import 'package:everlink/services/update_service.dart';

/// 统一的「发现新版本」专用弹框。
///
/// 取代了原先「底部 SnackBar + 点击再弹框」的两段式提示，启动检查到更新时
/// 直接弹出此对话框。对话框内明确告知用户：本次更新为**增量升级**，会保留
/// 全部本地数据（设备配置 / 历史记录 / 设置等），不会从头来过。
///
/// 返回用户是否点击了「立即更新」（true=确认更新，false=稍后）。下载与安装
/// 由调用方负责（便于在不同页面给出各自的反馈）。
Future<bool> showUpdateDialog(BuildContext context, UpdateInfo u) async {
  final scheme = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    // 升级提示需要用户明确决策，不允许误触空白关闭。
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.system_update_alt_rounded, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text('发现新版本 v${u.version}'),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.55,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (u.build != null) ...[
                Text('版本号 ${u.build}',
                    style: TextStyle(color: scheme.primary, fontSize: 13)),
                const SizedBox(height: 8),
              ],
              if (u.notes != null && u.notes!.isNotEmpty) ...[
                const Text('更新内容',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 4),
                Text(u.notes!,
                    style:
                        const TextStyle(color: Colors.grey, fontSize: 13)),
                const SizedBox(height: 12),
              ],
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.verified_user_outlined,
                        size: 16, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '本次为增量升级，将保留您的全部本地数据'
                        '（设备配置、历史记录、个人设置等），无需重新配置。',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('立即更新'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// 下载 / 安装进度专用弹框。
///
/// 取代原先「已开始下载 / 无法下载」的 SnackBar 反馈。调用后会先发起下载，
/// 再通过 [AppInstaller.onInstallEvent] 实时展示进度；下载完成自动拉起系统
/// 安装器，失败则可重试。下载在后台持续进行，用户可点「后台下载」收起弹框。
Future<void> showDownloadDialog(BuildContext context, String url) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _DownloadDialog(url: url),
  );
}

class _DownloadDialog extends StatefulWidget {
  final String url;
  const _DownloadDialog({required this.url});

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  int _progress = 0;
  bool _indeterminate = true;
  bool _done = false;
  bool _failed = false;
  String _error = '';
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    setState(() {
      _progress = 0;
      _indeterminate = true;
      _done = false;
      _failed = false;
      _error = '';
    });
    // 先订阅再发起，避免错过 started 事件。
    _sub?.cancel();
    _sub = AppInstaller.onInstallEvent.listen(_onEvent);
    AppInstaller.downloadAndInstall(widget.url).then((ok) {
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _failed = true;
          _error = '无法启动下载，请检查网络后重试';
        });
      }
    });
  }

  void _onEvent(Map<String, dynamic> e) {
    if (!mounted) return;
    switch (e['status']) {
      case 'started':
        setState(() => _indeterminate = true);
      case 'progress':
        final downloaded = (e['downloaded'] as num?)?.toInt() ?? 0;
        final total = (e['total'] as num?)?.toInt() ?? 0;
        setState(() {
          _indeterminate = total <= 0;
          _progress = total > 0
              ? ((downloaded / total) * 100).clamp(0, 100).round()
              : 0;
        });
      case 'completed':
        setState(() {
          _done = true;
          _indeterminate = false;
          _progress = 100;
        });
        // 原生已尝试自动拉起系统安装器；此处保留弹框并提供「立即安装」按钮，
        // 作为自动拉起未生效（如未授予“安装未知应用”权限）时的手动兜底。
      case 'failed':
        setState(() {
          _failed = true;
          _error = (e['message'] as String?) ?? '下载失败';
        });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = _failed
        ? '下载失败'
        : _done
            ? '下载完成'
            : '正在更新';
    final icon = _failed
        ? Icons.error_outline_rounded
        : _done
            ? Icons.check_circle_outline_rounded
            : Icons.system_update_alt_rounded;
    final iconColor = _failed
        ? scheme.error
        : _done
            ? Colors.green
            : scheme.primary;

    Widget body;
    if (_failed) {
      body = Text(_error, style: const TextStyle(color: Colors.grey, fontSize: 13));
    } else if (_done) {
      body = const Text(
          '更新包已下载完成。点击「立即安装」开始升级，将保留您的全部本地数据。',
          style: TextStyle(color: Colors.grey, fontSize: 13));
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_indeterminate)
            const LinearProgressIndicator()
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: _progress / 100),
                const SizedBox(height: 6),
                Text('正在下载更新包… $_progress%',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          const SizedBox(height: 10),
          const Text('请保持网络畅通，下载完成后将自动弹出安装。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );
    }

    List<Widget> actions;
    if (_failed) {
      actions = [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: () {
            _sub?.cancel();
            _start();
          },
          child: const Text('重试'),
        ),
      ];
    } else if (_done) {
      actions = [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () async {
            final navigator = Navigator.of(context);
            final ok = await AppInstaller.launchInstall();
            if (!mounted) return;
            if (ok) {
              if (navigator.canPop()) navigator.pop();
            } else {
              setState(() {
                _failed = true;
                _error = '无法启动安装，请检查是否已允许“安装未知应用”权限';
              });
            }
          },
          child: const Text('立即安装'),
        ),
      ];
    } else {
      actions = [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('后台下载'),
        ),
      ];
    }

    return AlertDialog(
      title: Row(
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 8),
          Expanded(child: Text(title)),
        ],
      ),
      content: body,
      actions: actions,
    );
  }
}
