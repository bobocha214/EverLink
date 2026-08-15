import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:saver_gallery/saver_gallery.dart';

import 'package:everlink/services/lan_transfer/lan_models.dart';
import 'package:everlink/services/lan_transfer/lan_transfer_manager.dart';

/// 当前会话目标：某个频道，或某台设备（点对点）。
class ChatTarget {
  const ChatTarget.channel(this.channel) : device = null;
  const ChatTarget.device(this.device) : channel = '';

  final String channel;
  final DiscoveredDevice? device;

  bool get isChannel => device == null;
  String get title => isChannel ? channel : device!.name;
}

/// 待发送的附件（已读入内存并转为 dataURL）。
class _Pending {
  _Pending({
    required this.name,
    required this.size,
    required this.mime,
    required this.dataUrl,
  });

  final String name;
  final int size;
  final String mime;
  final String dataUrl;

  Map<String, dynamic> toJson() =>
      {'name': name, 'size': size, 'mime': mime, 'data': dataUrl};
}

/// 快传聊天页：展示某个频道或点对点会话的消息流，并支持发送文字与文件。
///
/// 由 [LanTransferPage]（管理页）点击某个频道或设备后 push 进入。
class LanChatPage extends StatefulWidget {
  const LanChatPage({super.key, required this.target});

  final ChatTarget target;

  @override
  State<LanChatPage> createState() => _LanChatPageState();
}

class _LanChatPageState extends State<LanChatPage> {
  final manager = LanTransferManager.instance;
  final _textCtl = TextEditingController();
  final _scrollCtl = ScrollController();
  final List<_Pending> _pending = [];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    manager.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  @override
  void dispose() {
    manager.removeListener(_onChanged);
    _textCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtl.hasClients) return;
      _scrollCtl.animateTo(
        _scrollCtl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  /// 当前会话的消息流。
  List<LanMessage> get _messages {
    if (widget.target.isChannel) return manager.messagesOf(widget.target.channel);
    final host = widget.target.device!.host;
    return manager.messages
        .where((m) => m.isP2P && m.peer.split(':').first == host)
        .toList()
      ..sort((a, b) => a.time.compareTo(b.time));
  }

  // ------------------------------------------------------------------ 发送

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );
    if (result == null) return;
    var skipped = 0;
    for (final f in result.files) {
      if (f.path == null) continue;
      final file = File(f.path!);
      final len = await file.length();
      if (len > 80 * 1024 * 1024) {
        skipped++;
        continue;
      }
      final bytes = await file.readAsBytes();
      final mime = _guessMime(f.name);
      _pending.add(_Pending(
        name: f.name,
        size: bytes.length,
        mime: mime,
        dataUrl: 'data:$mime;base64,${base64Encode(bytes)}',
      ));
    }
    if (!mounted) return;
    setState(() {});
    if (skipped > 0) _toast('$skipped 个文件超过 80MB，已跳过');
  }

  Future<void> _send() async {
    final text = _textCtl.text.trim();
    if (text.isEmpty && _pending.isEmpty) return;
    setState(() => _sending = true);

    final result = await manager.send(
      text: text,
      files: _pending.map((e) => e.toJson()).toList(),
      channel: widget.target.isChannel ? widget.target.channel : '',
      target: widget.target.isChannel ? null : widget.target.device!.address,
    );

    if (!mounted) return;
    setState(() {
      _sending = false;
      if (result.ok) {
        _textCtl.clear();
        _pending.clear();
      }
    });
    _scrollToEnd();
    if (!result.ok) _toast(result.detail);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              target.isChannel
                  ? (manager.channelPassword(target.channel)?.isNotEmpty == true
                      ? Icons.lock
                      : Icons.tag)
                  : (target.device!.isWeb ? Icons.language : Icons.smartphone),
              size: 18,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                target.title,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (target.isChannel)
            IconButton(
              icon: const Icon(Icons.qr_code_2),
              tooltip: '频道二维码',
              onPressed: manager.hasLanAddress ? _showQrDialog : null,
            ),
          PopupMenuButton<String>(
            onSelected: _onMenu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('清空本会话消息')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessageList()),
          _buildComposer(),
        ],
      ),
    );
  }

  void _onMenu(String v) {
    if (v == 'clear') {
      manager.clearMessages();
    }
  }

  Widget _buildMessageList() {
    final msgs = _messages;
    if (msgs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 46, color: Colors.grey[350]),
            const SizedBox(height: 10),
            Text(
              widget.target.isChannel
                  ? '「${widget.target.channel}」还没有消息'
                  : '与 ${widget.target.title} 还没有消息',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 4),
            const Text('发送文字或文件开始传输',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scrollCtl,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      itemCount: msgs.length,
      itemBuilder: (_, i) => _buildBubble(msgs[i]),
    );
  }

  Widget _buildBubble(LanMessage m) {
    final mine = m.isSelf;
    final bg = mine ? Colors.teal.shade100 : Theme.of(context).cardColor;
    const double maxWidthRatio = 0.78;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine) _avatar(m.fromName, false),
          if (!mine) const SizedBox(width: 8),
          if (mine) const Spacer(),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * maxWidthRatio,
            ),
            child: Column(
              crossAxisAlignment:
                  mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!mine)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3, left: 4),
                    child: Text(m.fromName,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.grey)),
                  ),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 2,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (m.text.isNotEmpty)
                        SelectableText(m.text,
                            style: const TextStyle(fontSize: 14)),
                      if (m.text.isNotEmpty && m.files.isNotEmpty)
                        const SizedBox(height: 8),
                      for (final f in m.files) _buildFileTile(f),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
                  child: Text(_fmtTime(m.time),
                      style:
                          const TextStyle(fontSize: 10, color: Colors.grey)),
                ),
              ],
            ),
          ),
          if (!mine) const Spacer(),
          if (mine) const SizedBox(width: 8),
          if (mine) _avatar(m.fromName, true),
        ],
      ),
    );
  }

  Widget _avatar(String name, bool mine) {
    final ch = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return CircleAvatar(
      radius: 15,
      backgroundColor: mine ? Colors.teal : Colors.blueGrey.shade300,
      child: Text(ch,
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildFileTile(LanFileItem f) {
    if (f.isImage && File(f.savedPath).existsSync()) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: GestureDetector(
          onTap: () => _previewImage(f),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(f.savedPath),
              width: 180,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _fileCard(f),
            ),
          ),
        ),
      );
    }
    return _fileCard(f);
  }

  Widget _fileCard(LanFileItem f) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: () => _showFileInfo(f),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 230),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file_outlined,
                  size: 22, color: Colors.teal),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(f.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                    Text(f.sizeText,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 底部输入区：附件、文本框、发送。
  Widget _buildComposer() {
    final canSend =
        !_sending && (_textCtl.text.trim().isNotEmpty || _pending.isNotEmpty);
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(top: BorderSide(color: Colors.grey.withValues(alpha: 0.2))),
      ),
      padding: EdgeInsets.fromLTRB(
          8, 6, 8, 6 + MediaQuery.of(context).viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < _pending.length; i++)
                    Chip(
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 140),
                        child: Text(_pending[i].name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12)),
                      ),
                      onDeleted: () => setState(() => _pending.removeAt(i)),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                icon: const Icon(Icons.attach_file),
                tooltip: '选择文件',
                onPressed: _sending ? null : _pickFiles,
              ),
              Expanded(
                child: TextField(
                  controller: _textCtl,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: widget.target.isChannel
                        ? '发送到「${widget.target.channel}」'
                        : '发送给 ${widget.target.title}',
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _sending
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton.filled(
                      icon: const Icon(Icons.send, size: 20),
                      onPressed: canSend ? _send : null,
                    ),
            ],
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 交互

  void _previewImage(LanFileItem f) {
    showDialog(
      context: context,
      builder: (d) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InteractiveViewer(
                child: Image.file(File(f.savedPath)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text('${f.name} · ${f.sizeText}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ],
        ),
      ),
    );
  }

  void _showFileInfo(LanFileItem f) {
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(f.name, style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('大小：${f.sizeText}'),
            const SizedBox(height: 6),
            const Text('保存位置', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            SelectableText(f.savedPath, style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: f.savedPath));
              Navigator.pop(d);
              _toast('路径已复制');
            },
            child: const Text('复制路径'),
          ),
          FilledButton(
              onPressed: () => Navigator.pop(d), child: const Text('关闭')),
        ],
      ),
    );
  }

  void _showQrDialog() {
    final channel = widget.target.channel;
    showDialog(
      context: context,
      builder: (_) => ChannelQrDialog(
        manager: manager,
        channel: channel,
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _guessMime(String name) {
    final ext = name.toLowerCase().split('.').last;
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'mp4':
        return 'video/mp4';
      case 'mp3':
        return 'audio/mpeg';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'json':
        return 'application/json';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }
}

/// 频道二维码弹窗：展示当前频道专属链接，并支持保存为图片。
///
/// 在管理页和聊天页均可使用：管理页点击频道卡片上的二维码图标弹出，
/// 聊天页 AppBar 二维码按钮弹出。
class ChannelQrDialog extends StatefulWidget {
  const ChannelQrDialog({
    super.key,
    required this.manager,
    required this.channel,
  });

  /// 快传统筹（ChangeNotifier）：二维码链接随对外 IP / 频道密码变化实时刷新。
  final LanTransferManager manager;
  final String channel;

  @override
  State<ChannelQrDialog> createState() => _ChannelQrDialogState();
}

class _ChannelQrDialogState extends State<ChannelQrDialog> {
  final _boundaryKey = GlobalKey();
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;
    final channel = widget.channel;
    return AlertDialog(
      title: Row(
        children: [
          AnimatedBuilder(
            animation: manager,
            builder: (context, _) => Icon(
              (manager.channelPassword(channel) ?? '').isNotEmpty
                  ? Icons.lock
                  : Icons.tag,
              size: 18,
              color: Colors.teal,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(channel,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16)),
          ),
        ],
      ),
      content: AnimatedBuilder(
        animation: manager,
        builder: (context, _) {
          // 随对外 IP / 频道密码变化实时重算。
          final url = manager.urlForChannel(channel);
          final isPrivate =
              (manager.channelPassword(channel) ?? '').isNotEmpty;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 对外地址直接在二维码界面切换：二维码随 selfAddress 实时刷新。
              Row(
                children: [
                  const Text('对外地址',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String?>(
                      value: manager.selectedIp,
                      isExpanded: true,
                      isDense: true,
                      hint: const Text('全部接口'),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('全部接口（自动主地址）',
                              overflow: TextOverflow.ellipsis),
                        ),
                        for (final a in manager.allAddresses)
                          DropdownMenuItem(
                            value: a['ip'] as String,
                            child: Text(
                              '${a['ip']}  ${a['type'] ?? ''}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        manager.setSelectedIp(v).then((r) {
                          if (r.detail.isNotEmpty && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(r.detail)),
                            );
                          }
                        });
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              RepaintBoundary(
                key: _boundaryKey,
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ExcludeSemantics(
                        child: SizedBox(
                          width: 210,
                          height: 210,
                          child: QrImageView(
                            data: url,
                            version: QrVersions.auto,
                            size: 210,
                            backgroundColor: Colors.white,
                            errorStateBuilder: (ctx, err) => Center(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(
                                  '二维码生成失败：${err.toString().split('\n').first}',
                                  style: const TextStyle(fontSize: 12, color: Colors.red),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'EverLink 快传 · $channel',
                        style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black87,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(url,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              Text(
                isPrivate
                    ? '扫码后需输入频道密码才能加入'
                    : '对方扫码或用浏览器打开即可进入该频道聊天',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(
                ClipboardData(text: manager.urlForChannel(channel)));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('链接已复制')),
            );
          },
          child: const Text('复制链接'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download, size: 18),
          label: const Text('保存图片'),
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }

  /// 把二维码区域截图为 PNG 并保存到系统相册（图库）。
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final boundary = _boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) throw '截图失败';
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw '编码失败';
      final bytes = data.buffer.asUint8List();
      final safe = widget.channel.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final fileName =
          'quickshare_${safe}_${DateTime.now().millisecondsSinceEpoch}.png';
      final result = await SaverGallery.saveImage(
        bytes,
        fileName: fileName,
        skipIfExists: false,
        albumPath: 'EverLink',
      );
      if (!mounted) return;
      if (result.isSuccess) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已保存到系统相册（EverLink 相簿）'),
            duration: Duration(seconds: 4),
          ),
        );
      } else {
        throw result.errorMessage ?? '保存失败';
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
