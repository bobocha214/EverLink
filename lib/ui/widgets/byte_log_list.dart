import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:everlink/utils/byte_codec.dart';

/// 单条收发记录（server 页与 client 页共用）。
class ByteLogEntry {
  ByteLogEntry({
    required this.tx,
    required this.bytes,
    required this.time,
    this.checksumLabel,
    this.checksumBytes,
    this.valid,
    this.note,
  });

  final bool tx; // true = 发出，false = 收到
  final Uint8List bytes;
  final DateTime time;
  final String? checksumLabel; // 附加/识别出的校验方式名，否则 null
  final Uint8List? checksumBytes; // 校验字节，否则 null
  final bool? valid; // RX 校验比对结果：true 通过 / false 不匹配 / null 无校验
  final String? note; // 可选解析摘要（如 "FC03 读保持寄存器 @0 ×16"）
}

/// 可复用的收发日志列表：
/// - 最新一条置顶；
/// - [showHex] 切换 HEX / ASCII 显示；
/// - 带校验信息时，数据区与校验码区醒目分区（校验区用琥珀色，始终 hex 展示）。
class ByteLogList extends StatelessWidget {
  const ByteLogList({
    super.key,
    required this.entries,
    required this.showHex,
    this.onClear,
    this.emptyHint = '启动服务后，收发的数据会显示在这里',
  });

  final List<ByteLogEntry> entries;
  final bool showHex;
  final VoidCallback? onClear;
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('收发日志（${entries.length}）',
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const Spacer(),
            if (entries.isNotEmpty && onClear != null)
              TextButton(onPressed: onClear, child: const Text('清空')),
          ],
        ),
        const SizedBox(height: 8),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(emptyHint,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          )
        else
          ...entries.map((e) => _buildCard(context, scheme, e)),
      ],
    );
  }

  Widget _buildCard(
      BuildContext context, ColorScheme scheme, ByteLogEntry e) {
    final tx = e.tx;
    final c = tx ? Colors.blue : Colors.green;
    final hasCs = e.checksumBytes != null && e.checksumBytes!.isNotEmpty;
    final csColor = Colors.amber.shade700;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: c.withValues(alpha: 0.12),
            child: Row(
              children: [
                Icon(Icons.circle, size: 8, color: c),
                const SizedBox(width: 6),
                Text(tx ? 'TX →' : 'RX ←',
                    style: TextStyle(
                        color: c,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        fontFamily: 'monospace')),
                const SizedBox(width: 8),
                if (hasCs)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: csColor.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(e.checksumLabel ?? '校验',
                        style: TextStyle(
                            color: csColor,
                            fontWeight: FontWeight.w600,
                            fontSize: 11)),
                  ),
                if (e.note != null)
                  Expanded(
                    child: Text(' ${e.note}',
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis),
                  ),
                const Spacer(),
                Text('${e.bytes.length} B',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                const SizedBox(width: 8),
                Text(
                    '${e.time.hour.toString().padLeft(2, '0')}:'
                    '${e.time.minute.toString().padLeft(2, '0')}:'
                    '${e.time.second.toString().padLeft(2, '0')}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: SelectableText(
              showHex ? hexDump(e.bytes) : asciiView(e.bytes),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
          if (hasCs)
            Container(
              color: csColor.withValues(alpha: 0.10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.verified_outlined,
                      size: 14, color: csColor),
                  const SizedBox(width: 6),
                  Text('校验码 · ${e.checksumLabel ?? ''}',
                      style: TextStyle(
                          color: csColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 12)),
                  const Spacer(),
                  if (e.valid != null)
                    Text(e.valid! ? '✓ 校验通过' : '✗ 校验不匹配',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: e.valid! ? Colors.green : Colors.red)),
                  if (e.valid == null)
                    Text(hexString(e.checksumBytes!),
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: csColor)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
