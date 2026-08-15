import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:everlink/utils/app_routes.dart';

/// 进制工具页（离线，无需连接设备）。
///
/// 以「目录页 + 独立子页面」呈现，与「网络调试」一致的展示形态：
/// 入口为功能卡片列表，点击进入各自的独立页面（不左右滑动切换）。
/// 包含：进制转换、文本⇄Hex、大小端、浮点、CRC16-Modbus 五个功能。
class BaseToolPage extends StatelessWidget {
  const BaseToolPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('进制工具')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _baseFuncs.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          final f = _baseFuncs[i];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => AppRoutes.push(context, f.page),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(f.icon, color: scheme.primary, size: 24),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(f.label,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(f.desc,
                              style: TextStyle(
                                  fontSize: 13, color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 进制工具的五个功能入口（目录页使用）。
class _BaseFunc {
  const _BaseFunc(this.icon, this.label, this.desc, this.page);
  final IconData icon;
  final String label;
  final String desc;
  final Widget page;
}

const List<_BaseFunc> _baseFuncs = [
  _BaseFunc(Icons.swap_horiz_outlined, '进制转换',
      '二/八/十/十六进制任意互转，支持补码与字节视图', _BaseConvertPage()),
  _BaseFunc(Icons.text_fields, '文本⇄Hex',
      '文本与十六进制（UTF-8）互转', _TextHexPage()),
  _BaseFunc(Icons.swap_vert, '大小端',
      '字节序翻转（16 / 32 / 64 位）', _EndianPage()),
  _BaseFunc(Icons.numbers, '浮点',
      'IEEE754 FLOAT32 解析（大小端）', _FloatPage()),
  _BaseFunc(Icons.check_circle_outline, 'CRC16',
      'CRC16-Modbus 校验', _CrcPage()),
];

/// 进制工具各子页底部的功能快捷条：横向滚动的 chip，当前页高亮，
/// 点击用 [AppRoutes.replace] 切换到其它进制功能（不堆积页面栈）。
class _BaseQuickBar extends StatelessWidget {
  const _BaseQuickBar({required this.currentIndex});
  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
        color: scheme.surface,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < _baseFuncs.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(_baseFuncs[i].label),
                  selected: i == currentIndex,
                  onSelected: (_) {
                    if (i != currentIndex) {
                      AppRoutes.replace(context, _baseFuncs[i].page);
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 解析 hex 文本为字节列表，失败返回 null。
List<int>? _parseHex(String s) {
  final cleaned = s.replaceAll(RegExp(r'\s+'), '');
  if (cleaned.isEmpty) return [];
  if (cleaned.length % 2 != 0) return null;
  final out = <int>[];
  for (var i = 0; i < cleaned.length; i += 2) {
    final v = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
    if (v == null) return null;
    out.add(v);
  }
  return out;
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// 按指定进制解析字符串，失败返回 null。
/// 自动识别 0x / 0o / 0b 前缀；十进制支持负号。
BigInt? _parseRadix(String s, int radix) {
  var t = s.trim();
  if (t.isEmpty) return BigInt.zero;
  if (radix == 16 && t.toLowerCase().startsWith('0x')) t = t.substring(2);
  if (radix == 8 && t.toLowerCase().startsWith('0o')) t = t.substring(2);
  if (radix == 2 && t.toLowerCase().startsWith('0b')) t = t.substring(2);
  if (t.isEmpty) return BigInt.zero;
  try {
    return BigInt.parse(t, radix: radix);
  } catch (_) {
    return null;
  }
}

/// 有符号值 → 指定位宽的补码无符号表示（大整数模 2^width）。
BigInt _toUnsigned(BigInt signed, int width) {
  final modulus = BigInt.one << width;
  BigInt u = signed % modulus;
  if (u < BigInt.zero) u += modulus;
  return u;
}

/// 指定位宽的补码无符号表示 → 有符号值。
BigInt _toSigned(BigInt u, int width) {
  final modulus = BigInt.one << width;
  final half = BigInt.one << (width - 1);
  return u >= half ? u - modulus : u;
}

String _pad(String s, int len) => s.padLeft(len, '0');

/// 页面：多种进制互转（BigInt 大整数 + 可选补码 + 字节视图）。
class _BaseConvertPage extends StatefulWidget {
  const _BaseConvertPage();

  @override
  State<_BaseConvertPage> createState() => _BaseConvertPageState();
}

class _BaseConvertPageState extends State<_BaseConvertPage> {
  final _bin = TextEditingController();
  final _oct = TextEditingController();
  final _dec = TextEditingController();
  final _hex = TextEditingController();
  final _dummy = TextEditingController(); // 用于「全部刷新」时跳过判定
  BigInt _signedValue = BigInt.zero;
  String? _err;
  bool _signed = false;
  int _width = 32; // 有符号位宽 / 字节视图长度基准

  @override
  void dispose() {
    _bin.dispose();
    _oct.dispose();
    _dec.dispose();
    _hex.dispose();
    _dummy.dispose();
    super.dispose();
  }

  /// 从某个字段解析并更新其余字段。
  /// [isDecimal] 表示来源字段是十进制（有符号模式下即直接的有符号值）。
  void _setFrom(String text, int radix, bool isDecimal) {
    final raw = _parseRadix(text, radix);
    if (raw == null) {
      setState(() => _err = '格式错误（含非法字符或非 $_width 进制范围）');
      return;
    }
    BigInt signed;
    if (!_signed) {
      if (raw < BigInt.zero) {
        setState(() => _err = '无符号模式下不能输入负数');
        return;
      }
      signed = raw;
    } else if (isDecimal) {
      // 十进制直接作为有符号值
      signed = raw;
    } else {
      // 其他进制按当前位宽的补码无符号值解析
      signed = _toSigned(raw, _width);
    }
    _signedValue = signed;
    _pushToAllExcept(_fieldFor(radix, isDecimal));
    setState(() => _err = null);
  }

  TextEditingController _fieldFor(int radix, bool isDecimal) {
    if (isDecimal) return _dec;
    if (radix == 2) return _bin;
    if (radix == 8) return _oct;
    return _hex;
  }

  /// 依据当前 [“有符号 + 位宽”] 状态，把 [_signedValue] 写入除 [skip] 外的所有字段。
  void _pushToAllExcept(TextEditingController skip) {
    final s = _signedValue;
    if (!_signed) {
      final b = s.toRadixString(2);
      final o = s.toRadixString(8);
      final d = s.toString();
      final h = s.toRadixString(16).toUpperCase();
      if (skip != _bin) _bin.text = b;
      if (skip != _oct) _oct.text = o;
      if (skip != _dec) _dec.text = d;
      if (skip != _hex) _hex.text = h;
    } else {
      final u = _toUnsigned(s, _width);
      final b = _pad(u.toRadixString(2), _width);
      final h = _pad(u.toRadixString(16).toUpperCase(), (_width + 3) ~/ 4);
      if (skip != _bin) _bin.text = b;
      if (skip != _oct) _oct.text = u.toRadixString(8);
      if (skip != _dec) _dec.text = s.toString();
      if (skip != _hex) _hex.text = h;
    }
  }

  /// 计算当前值的大端字节视图。
  List<int> _computeBytes() {
    final u = _signed ? _toUnsigned(_signedValue, _width) : _signedValue;
    int byteLen = _signed ? _width ~/ 8 : ((u.bitLength + 7) ~/ 8);
    if (byteLen < 1) byteLen = 1;
    final bytes = List.filled(byteLen, 0);
    var tmp = u;
    for (var i = byteLen - 1; i >= 0; i--) {
      bytes[i] = (tmp & BigInt.from(0xFF)).toInt();
      tmp >>= 8;
    }
    return bytes;
  }

  Future<void> _copy(String text) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _computeBytes();
    final byteView = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    return Scaffold(
      appBar: AppBar(title: const Text('进制转换')),
      bottomNavigationBar: const _BaseQuickBar(currentIndex: 0),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('有符号（补码）',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          value: _signed,
                          onChanged: (v) {
                            setState(() {
                              _signed = v;
                              // 切回无符号时若当前为负值，取其绝对值避免显示负数
                              if (!v && _signedValue < BigInt.zero) {
                                _signedValue = -_signedValue;
                              }
                              _pushToAllExcept(_dummy);
                              _err = null;
                            });
                          },
                        ),
                      ),
                      DropdownButton<int>(
                        value: _width,
                        isDense: true,
                        items: const [
                          DropdownMenuItem(value: 8, child: Text('8 位')),
                          DropdownMenuItem(value: 16, child: Text('16 位')),
                          DropdownMenuItem(value: 32, child: Text('32 位')),
                          DropdownMenuItem(value: 64, child: Text('64 位')),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            _width = v;
                            _pushToAllExcept(_dummy);
                            _err = null;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text('任意编辑一个框，其余自动换算（支持 0x/0o/0b 前缀）',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  _Field(
                    label: '二进制 (BIN)',
                    controller: _bin,
                    onChanged: (t) => _setFrom(t, 2, false),
                    onCopy: () => _copy(_bin.text),
                    hint: '如 1010',
                  ),
                  const SizedBox(height: 8),
                  _Field(
                    label: '八进制 (OCT)',
                    controller: _oct,
                    onChanged: (t) => _setFrom(t, 8, false),
                    onCopy: () => _copy(_oct.text),
                    hint: '如 12',
                  ),
                  const SizedBox(height: 8),
                  _Field(
                    label: '十进制 (DEC)',
                    controller: _dec,
                    onChanged: (t) => _setFrom(t, 10, true),
                    onCopy: () => _copy(_dec.text),
                    hint: '如 10（可带负号）',
                  ),
                  const SizedBox(height: 8),
                  _Field(
                    label: '十六进制 (HEX)',
                    controller: _hex,
                    onChanged: (t) => _setFrom(t, 16, false),
                    onCopy: () => _copy(_hex.text),
                    hint: '如 A（或 0xA）',
                  ),
                  if (_err != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_err!,
                          style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('字节视图（大端）',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: '复制字节视图',
                        onPressed: () => _copy(byteView),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.purple.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      byteView.isEmpty ? '00' : byteView,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _signed
                        ? '位宽 $_width · ${_width ~/ 8} 字节 · 有符号补码'
                        : '无符号 · ${bytes.length} 字节',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 进制转换页中单个进制输入框。
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.onChanged,
    required this.onCopy,
    required this.hint,
  });

  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onCopy;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        suffixIcon: IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: '复制',
          onPressed: onCopy,
        ),
      ),
    );
  }
}

/// 页面：文本 ↔ 十六进制。
class _TextHexPage extends StatefulWidget {
  const _TextHexPage();

  @override
  State<_TextHexPage> createState() => _TextHexPageState();
}

class _TextHexPageState extends State<_TextHexPage> {
  final _textCtl = TextEditingController();
  final _hexCtl = TextEditingController();
  String? _hexErr;

  @override
  void dispose() {
    _textCtl.dispose();
    _hexCtl.dispose();
    super.dispose();
  }

  void _textToHex() {
    final bytes = utf8.encode(_textCtl.text);
    setState(() {
      _hexCtl.text = _toHex(bytes);
    });
  }

  void _hexToText() {
    final bytes = _parseHex(_hexCtl.text);
    if (bytes == null) {
      setState(() => _hexErr = 'Hex 格式错误（需偶数位十六进制）');
      return;
    }
    try {
      setState(() {
        _textCtl.text = utf8.decode(bytes);
        _hexErr = null;
      });
    } on FormatException {
      setState(() => _hexErr = '无法按 UTF-8 解码（含非法字节序列）');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('文本⇄Hex')),
      bottomNavigationBar: const _BaseQuickBar(currentIndex: 1),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('文本 → 十六进制 (UTF-8)',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _textCtl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '文本',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                        onPressed: _textToHex, child: const Text('转换')),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('十六进制 → 文本 (UTF-8)',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _hexCtl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '十六进制（空格分隔，如 48 65 6C 6C 6F）',
                      isDense: true,
                    ),
                  ),
                  if (_hexErr != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_hexErr!,
                          style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                        onPressed: _hexToText, child: const Text('转换')),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 页面：大小端转换（16/32/64 位）。
class _EndianPage extends StatefulWidget {
  const _EndianPage();

  @override
  State<_EndianPage> createState() => _EndianPageState();
}

class _EndianPageState extends State<_EndianPage> {
  final _ctl = TextEditingController();
  String? _result;
  String? _err;
  int _width = 32;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _convert() {
    final bytes = _parseHex(_ctl.text);
    if (bytes == null) {
      setState(() => _err = 'Hex 格式错误（需偶数位十六进制）');
      return;
    }
    final want = _width ~/ 8;
    if (bytes.isEmpty) {
      setState(() => _err = '请输入字节');
      return;
    }
    if (bytes.length != want) {
      setState(() => _err = '$_width 位需要 $want 字节，当前 ${bytes.length} 字节');
      return;
    }
    final swapped = bytes.reversed.toList();
    setState(() {
      _result = _toHex(swapped);
      _err = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('大小端')),
      bottomNavigationBar: const _BaseQuickBar(currentIndex: 2),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('字节序翻转（大小端互换）',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    value: _width,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: '位宽',
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 16, child: Text('16 位 (2 字节)')),
                      DropdownMenuItem(value: 32, child: Text('32 位 (4 字节)')),
                      DropdownMenuItem(value: 64, child: Text('64 位 (8 字节)')),
                    ],
                    onChanged: (v) => setState(() => _width = v ?? _width),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ctl,
                    decoration: const InputDecoration(
                      labelText: '原始字节（Hex）',
                      hintText: '如 01 02 03 04',
                      isDense: true,
                    ),
                  ),
                  if (_err != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_err!,
                          style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                        onPressed: _convert, child: const Text('翻转')),
                  ),
                  if (_result != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.teal.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText('结果：$_result',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 14)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 页面：浮点数(IEEE754 FLOAT32) 解析。
class _FloatPage extends StatefulWidget {
  const _FloatPage();

  @override
  State<_FloatPage> createState() => _FloatPageState();
}

class _FloatPageState extends State<_FloatPage> {
  final _ctl = TextEditingController();
  String? _result;
  String? _err;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _parse() {
    final bytes = _parseHex(_ctl.text);
    if (bytes == null) {
      setState(() => _err = 'Hex 格式错误（需偶数位十六进制）');
      return;
    }
    if (bytes.length != 4) {
      setState(() => _err = 'FLOAT32 需要 4 字节（8 位十六进制），当前 ${bytes.length} 字节');
      return;
    }
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    final le = bd.getFloat32(0, Endian.little);
    final be = bd.getFloat32(0, Endian.big);
    // 同时给出 32 位整数视图（便于对照寄存器值）。
    final u32 = bd.getUint32(0, Endian.big);
    setState(() {
      _result = '小端(Little): $le\n大端(Big):    $be\n'
          '作为 UInt32:  $u32 (0x${u32.toRadixString(16)})';
      _err = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('浮点')),
      bottomNavigationBar: const _BaseQuickBar(currentIndex: 3),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('IEEE754 FLOAT32 解析',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('输入 4 字节（两寄存器拼成），按大小端解析为浮点。',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ctl,
                    decoration: const InputDecoration(
                      labelText: '4 字节 Hex',
                      hintText: '如 42 48 00 00',
                      isDense: true,
                    ),
                  ),
                  if (_err != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_err!,
                          style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                        onPressed: _parse, child: const Text('解析')),
                  ),
                  if (_result != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.teal.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(_result!,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 14)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 页面：CRC16-Modbus 计算。
class _CrcPage extends StatefulWidget {
  const _CrcPage();

  @override
  State<_CrcPage> createState() => _CrcPageState();
}

class _CrcPageState extends State<_CrcPage> {
  final _ctl = TextEditingController();
  String? _result;
  String? _err;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  /// CRC16-Modbus：多项式 0x8005，初始 0xFFFF，输入/输出均反射，结果异或 0。
  /// 实现采用反射形式的 0xA001 查表替代，逐字节处理。
  int _crc16Modbus(List<int> bytes) {
    int crc = 0xFFFF;
    for (final b in bytes) {
      crc ^= b & 0xFF;
      for (var i = 0; i < 8; i++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ 0xA001;
        } else {
          crc >>= 1;
        }
      }
    }
    return crc & 0xFFFF;
  }

  void _calc() {
    final bytes = _parseHex(_ctl.text);
    if (bytes == null) {
      setState(() => _err = 'Hex 格式错误（需偶数位十六进制）');
      return;
    }
    if (bytes.isEmpty) {
      setState(() => _err = '请输入要计算的报文');
      return;
    }
    final crc = _crc16Modbus(bytes);
    // Modbus 报文习惯以低字节在前附加 CRC。
    final lo = crc & 0xFF;
    final hi = (crc >> 8) & 0xFF;
    setState(() {
      _result = 'CRC16: 0x${crc.toRadixString(16).padLeft(4, '0').toUpperCase()}'
          '  (附加报文: ${lo.toRadixString(16).padLeft(2, '0')} '
          '${hi.toRadixString(16).padLeft(2, '0')})';
      _err = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CRC16')),
      bottomNavigationBar: const _BaseQuickBar(currentIndex: 4),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('CRC16-Modbus 校验',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('多项式 0x8005 · 初始 0xFFFF · 反射 · 异或 0',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ctl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '报文（Hex，不含 CRC 本身）',
                      hintText: '如 01 03 00 00 00 01',
                      isDense: true,
                    ),
                  ),
                  if (_err != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_err!,
                          style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                        onPressed: _calc, child: const Text('计算')),
                  ),
                  if (_result != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.teal.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(_result!,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 14)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
