import 'dart:async';

import 'package:flutter/material.dart';

import 'package:everlink/services/app_installer.dart';
import 'package:everlink/services/update_service.dart';
import 'package:everlink/ui/widgets/responsive_sheet.dart';

/// 与 App 主题一致的语义色，避免硬编码 Colors.green / Colors.orange / Colors.grey。
/// 取自项目统一状态色板：在线/成功 = 0xFF30D158，连接中/警告 = 0xFFFF9F0A。
const Color _kSuccessGreen = Color(0xFF30D158);
const Color _kWarningAmber = Color(0xFFFF9F0A);

/// 统一的「发现新版本」提示。
///
/// 取代原先「底部 SnackBar + 点击再弹框」的两段式提示，并改为**响应式底部弹层**
/// （移动端底部弹层、桌面端居中对话框，见 [showResponsiveSheet]）。弹层内明确
/// 告知用户：本次更新为**增量升级**，会保留全部本地数据；iOS 未签名包会额外给出
/// 自签安装的提示。
///
/// 返回用户是否点击了「立即更新」（true=确认更新，false/关闭=稍后）。
Future<bool> showUpdateDialog(BuildContext context, UpdateInfo u) async {
  final result = await showResponsiveSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _UpdateCard(info: u),
  );
  return result == true;
}

class _UpdateCard extends StatelessWidget {
  const _UpdateCard({required this.info});
  final UpdateInfo info;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isDesktopPlatform) _dragHandle(scheme),
        Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            isDesktopPlatform ? 20 : 4,
            20,
            20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：更新图标 + 版本号
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.system_update_alt_rounded,
                        color: scheme.primary, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('发现新版本 v${info.version}',
                        style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700, fontSize: 18)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 安装包信息（平台 + 文件名）
              if (info.assetName != null && info.assetName!.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.inventory_2_outlined,
                          size: 16, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(info.assetName!,
                            style: text.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontFamily: 'monospace')),
                      ),
                    ],
                  ),
                ),
              // 未签名提示（iOS）
              if (info.isUnsigned) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _kWarningAmber.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: _kWarningAmber.withValues(alpha: 0.35), width: 1),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 18, color: _kWarningAmber),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '未签名 IPA：需通过 AltStore / Sideloadly 等工具自行重签后'
                          '才能安装到真机，无法直接点按安装或在 App Store 获取。',
                          style: text.bodySmall?.copyWith(
                              color: _kWarningAmber, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // 更新内容
              if (info.notes != null && info.notes!.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('更新内容',
                    style: text.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.28,
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      info.notes!,
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              // 增量升级提示卡
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.verified_user_outlined,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '本次为增量升级，将保留您的全部本地数据'
                        '（设备配置、历史记录、个人设置等），无需重新配置。',
                        style: text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              // 操作按钮
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('稍后'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).pop(true),
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('立即更新'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 顶部拖拽手柄（仅移动端底部弹层展示）。
Widget _dragHandle(ColorScheme scheme) => Center(
      child: Container(
        margin: const EdgeInsets.only(top: 8, bottom: 4),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );

/// 下载 / 安装进度弹层。
///
/// 取代原先「已开始下载 / 无法下载」的 SnackBar 反馈，改为响应式底部弹层，
/// 通过 [AppInstaller.onInstallEvent] 实时展示进度；下载在后台持续进行，
/// 用户可点「后台下载」收起弹层。弹层不可误触关闭（下载中强制停留）。
Future<void> showDownloadDialog(BuildContext context, String url) async {
  if (!context.mounted) return;
  await showResponsiveSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (ctx) => _DownloadCard(url: url),
  );
}

class _DownloadCard extends StatefulWidget {
  final String url;
  const _DownloadCard({required this.url});

  @override
  State<_DownloadCard> createState() => _DownloadCardState();
}

class _DownloadCardState extends State<_DownloadCard> {
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
    final text = Theme.of(context).textTheme;
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
            ? _kSuccessGreen
            : scheme.primary;

    Widget body;
    if (_failed) {
      body = Text(_error,
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant));
    } else if (_done) {
      body = Text(
          '更新包已下载完成。点击「立即安装」开始升级，将保留您的全部本地数据。',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13));
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
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
          const SizedBox(height: 10),
          Text('请保持网络畅通，下载完成后点击下方「立即安装」开始升级。',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
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
                _error = '无法启动安装，请检查是否已允许相关权限';
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isDesktopPlatform) _dragHandle(scheme),
        Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            isDesktopPlatform ? 20 : 4,
            20,
            20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: iconColor, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(title,
                        style: text.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              body,
              const SizedBox(height: 18),
              Row(
                children: actions
                    .map((w) => Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: w,
                          ),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
