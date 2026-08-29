import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/device_session.dart';
import 'package:everlink/protocols/tcp_raw_protocol.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/services/tcp_history_service.dart';
import 'package:everlink/services/tcp_log_store.dart';
import 'package:everlink/ui/widgets/responsive_sheet.dart';

/// TCP 原始连接设备详情页。
///
/// 作为正式协议（`ProtocolType.tcpRaw`）的调试视图，通过 [ConnectionManager]
/// 复用统一的连接状态与历史记录。页面提供：可编辑的 host/port（未连接时）、
/// 连接 / 断开、发送框（Hex / 文本两种解析模式）、以及收发日志（最新置顶，
/// 支持 HEX / ASCII 显示切换）。其交互形态与「网络调试」下的裸 TCP 收发场景一致，
/// 但此处由共享 [ConnectionManager] 驱动，使首页设备卡片状态与该页保持同步。
///
/// 额外能力：
/// - **连接历史**：每次成功连接写入 `TcpHistoryService`，右上角「历史」可
///   查看、切回历史 IP、删除单条或清空；
/// - **附加校验码**：发送时可选择自动在报文尾部附加 CRC16-Modbus / 累加和 /
///   异或校验，算法与「进制工具 → CRC16」保持一致。
class TcpRawDetailPage extends StatefulWidget {
  final DeviceSession session;
  const TcpRawDetailPage({super.key, required this.session});

  @override
  State<TcpRawDetailPage> createState() => _TcpRawDetailPageState();
}

class _TcpRawDetailPageState extends State<TcpRawDetailPage> {
  late final ConnectionManager _cm;
  final _hostCtl = TextEditingController();
  final _portCtl = TextEditingController();
  final _sendCtl = TextEditingController();
  final _log = <_RawLogEntry>[];
  final _history = <String>[];
  StreamSubscription<Uint8List>? _rxSub;
  bool _hexMode = false; // 发送输入框解析模式（hex / 文本）
  bool _showHex = true; // 收发日志显示模式（HEX / ASCII），持久化记忆
  bool _jsonFormat = false; // ASCII 模式下是否对内容做 JSON 美化（仅当前会话）
  String _checksum = 'none'; // 发送时附加的校验方式
  String? _error;

  /// 收发日志显示模式（HEX / ASCII）的持久化 key。
  static const String _kShowHex = 'tcp_log_show_hex_v1';

  /// ASCII 模式下 JSON 格式化开关的持久化 key。
  static const String _kJsonFormat = 'tcp_log_json_format_v1';

  @override
  void initState() {
    super.initState();
    _cm = SessionManager.instance.ensureManager(widget.session);
    _cm.addListener(_onCm);
    final cfg = _cm.config;
    if (cfg is TcpRawConnectionConfig) {
      _hostCtl.text = cfg.host;
      _portCtl.text = cfg.port.toString();
    }
    final proto = _cm.protocol;
    if (proto is TcpRawProtocol) {
      _rxSub = proto.received.listen((bytes) {
        if (!mounted) return;
        // 按当前校验模式解析收到的帧（假定对方采用相同校验约定），
        // 把数据区与尾部校验字节拆开，并自动验证校验是否正确。
        String? csLabel;
        Uint8List? csBytes;
        bool? valid;
        final csLen = _csLenOf(_checksum);
        if (csLen > 0 && bytes.length > csLen) {
          final payload = bytes.sublist(0, bytes.length - csLen);
          final cs = bytes.sublist(bytes.length - csLen);
          final ok = _bytesEqual(_computeChecksum(payload), cs);
          if (ok) {
            // 仅当校验确实匹配时才把尾部识别为校验码；否则保持原始数据展示，
            // 避免把普通数据误拆成校验块（如 server 未附加校验时）。
            csLabel = _checksumShortLabel(_checksum);
            csBytes = cs;
            valid = true;
          } else {
            valid = false;
          }
        }
        _appendLog(_RawLogEntry(
          tx: false,
          bytes: bytes,
          time: DateTime.now(),
          checksumLabel: csLabel,
          checksumBytes: csBytes,
          valid: valid,
        ));
      });
    }
    if (_cm.state == DeviceConnectionState.error) _error = _cm.lastError;
    _loadHistory();
    _loadLog();
    // 恢复上次记住的 HEX / ASCII 显示偏好与 JSON 格式化开关。
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      final saved = p.getBool(_kShowHex);
      if (saved != null) setState(() => _showHex = saved);
      final jsonSaved = p.getBool(_kJsonFormat);
      if (jsonSaved != null) setState(() => _jsonFormat = jsonSaved);
    });
  }

  Future<void> _loadHistory() async {
    final list = await TcpHistoryService.load();
    if (mounted && list.isNotEmpty) setState(() => _history.addAll(list));
  }

  /// 当前连接地址（持久化日志的 key）。
  String get _curHost => _hostCtl.text.trim();
  int get _curPort => int.tryParse(_portCtl.text.trim()) ?? 502;

  /// 载入指定连接的已保存通讯记录（最新在前），页面进入时调用。
  Future<void> _loadLog() async {
    await TcpLogStore.flushNow();
    final list = await TcpLogStore.load(_curHost, _curPort);
    if (mounted && list.isNotEmpty) {
      setState(() => _log.addAll(list.map(_entryFromMap)));
    }
  }

  /// 在内存列表头部插入一条记录，并写入持久化（按 host:port）。
  void _appendLog(_RawLogEntry e) {
    setState(() => _log.insert(0, e));
    TcpLogStore.append(_curHost, _curPort, _entryToMap(e));
  }

  /// 清空当前连接的通讯记录（内存 + 持久化）。
  Future<void> _clearLog() async {
    setState(() => _log.clear());
    await TcpLogStore.clear(_curHost, _curPort);
  }

  /// 将日志条目序列化为可持久化的 map。
  static Map<String, dynamic> _entryToMap(_RawLogEntry e) => {
        'tx': e.tx,
        'b': base64Encode(e.bytes),
        't': e.time.millisecondsSinceEpoch,
        'cs': e.checksumBytes == null ? null : base64Encode(e.checksumBytes!),
        'csl': e.checksumLabel,
        'v': e.valid,
      };

  /// 从持久化的 map 还原为日志条目。
  static _RawLogEntry _entryFromMap(Map<String, dynamic> m) => _RawLogEntry(
        tx: m['tx'] as bool,
        bytes: Uint8List.fromList(base64Decode(m['b'] as String)),
        time: DateTime.fromMillisecondsSinceEpoch(m['t'] as int),
        checksumLabel: m['csl'] as String?,
        checksumBytes: m['cs'] == null
            ? null
            : Uint8List.fromList(base64Decode(m['cs'] as String)),
        valid: m['v'] as bool?,
      );

  void _onCm() {
    if (!mounted) return;
    setState(() {});
    if (_cm.state == DeviceConnectionState.error) {
      _error = _cm.lastError;
    } else if (_cm.state == DeviceConnectionState.connected) {
      _error = null;
    }
  }

  /// 把当前输入同步进连接配置并持久化（未连接时调用有效）。
  void _syncConfigFromFields() {
    final cfg = TcpRawConnectionConfig(
      host: _hostCtl.text.trim(),
      port: int.tryParse(_portCtl.text.trim()) ?? 502,
    );
    _cm.updateConfig(cfg);
    widget.session.config = cfg;
    SessionManager.instance.persist();
  }

  Future<void> _connect() async {
    if (_hostCtl.text.trim().isEmpty) {
      setState(() => _error = '请填写主机地址');
      return;
    }
    _syncConfigFromFields();
    try {
      await _cm.connect();
      // 连接成功后写入历史（去重、最新在前），供右上角「历史」切换。
      if (_cm.state == DeviceConnectionState.connected) {
        final host = _hostCtl.text.trim();
        final port = int.tryParse(_portCtl.text.trim()) ?? 502;
        final updated = await TcpHistoryService.add(host, port);
        if (mounted) setState(() => _history..clear()..addAll(updated));
      }
    } catch (_) {
      // 错误已通过状态流反映。
    }
  }

  Future<void> _disconnect() async {
    await _cm.disconnect();
  }

  void _send() {
    final proto = _cm.protocol;
    if (_cm.state != DeviceConnectionState.connected ||
        proto is! TcpRawProtocol) {
      return;
    }
    final raw = _sendCtl.text;
    if (raw.trim().isEmpty) return;
    Uint8List bytes;
    if (_hexMode) {
      final cleaned = raw.replaceAll(RegExp(r'\s+'), '');
      if (cleaned.length % 2 != 0) {
        setState(() => _error = 'Hex 模式：字节数必须为偶数');
        return;
      }
      try {
        bytes = Uint8List.fromList([
          for (var i = 0; i < cleaned.length; i += 2)
            int.parse(cleaned.substring(i, i + 2), radix: 16)
        ]);
      } on FormatException {
        setState(() => _error = 'Hex 模式：存在非法十六进制字符');
        return;
      }
    } else {
      bytes = Uint8List.fromList(utf8.encode(raw));
    }
    // 按所选方式在报文尾部附加校验字节，并记录校验字节与类型用于日志标识。
    final original = bytes;
    bytes = _appendChecksum(bytes);
    final csCount = bytes.length - original.length;
    final csBytes = csCount > 0 ? bytes.sublist(original.length) : null;
    final csLabel = csCount > 0 ? _checksumShortLabel(_checksum) : null;
    try {
      proto.send(bytes);
      _appendLog(_RawLogEntry(
        tx: true,
        bytes: bytes,
        time: DateTime.now(),
        checksumLabel: csLabel,
        checksumBytes: csBytes,
      ));
      _sendCtl.clear();
    } on StateError catch (e) {
      setState(() => _error = '发送失败：$e');
    }
  }

  /// 在载荷后附加校验字节（按当前 [_checksum] 模式）。
  Uint8List _appendChecksum(Uint8List data) =>
      Uint8List.fromList([...data, ..._computeChecksum(data)]);

  /// 仅计算载荷的附加校验字节（不拼回数据），crc16 以低字节在前。
  Uint8List _computeChecksum(Uint8List data) {
    switch (_checksum) {
      case 'crc16':
        final crc = _crc16Modbus(data);
        return Uint8List.fromList([crc & 0xFF, (crc >> 8) & 0xFF]);
      case 'sum':
        var s = 0;
        for (final b in data) {
          s = (s + b) & 0xFF;
        }
        return Uint8List.fromList([s]);
      case 'xor':
        var x = 0;
        for (final b in data) {
          x ^= b;
        }
        return Uint8List.fromList([x]);
      default:
        return Uint8List(0);
    }
  }

  /// 当前校验模式的尾部校验字节长度（crc16=2，sum/xor=1，none=0）。
  int _csLenOf(String mode) {
    switch (mode) {
      case 'crc16':
        return 2;
      case 'sum':
      case 'xor':
        return 1;
      default:
        return 0;
    }
  }

  /// 比较两个字节序列是否相等（用于校验验证）。
  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// CRC16-Modbus：多项式 0x8005，初始 0xFFFF，输入/输出均反射，结果异或 0。
  /// 与「进制工具 → CRC16」实现保持一致（反射形式 0xA001 逐字节处理）。
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

  /// 当前校验模式下的提示文案。
  String get _checksumHint {
    switch (_checksum) {
      case 'crc16':
        return '将附加 2 字节（低字节在前）';
      case 'sum':
        return '将附加 1 字节累加和';
      case 'xor':
        return '将附加 1 字节异或值';
      default:
        return '不附加校验';
    }
  }

  /// 校验方式的短标签（用于日志中标识校验类型）。
  String _checksumShortLabel(String mode) {
    switch (mode) {
      case 'crc16':
        return 'CRC16-Modbus';
      case 'sum':
        return '累加和';
      case 'xor':
        return '异或';
      default:
        return '';
    }
  }

  /// 把字节序列拼成紧凑 hex 串（如 "34 12"），用于头部展示校验值。
  static String _hexString(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

  @override
  void dispose() {
    _hostCtl.dispose();
    _portCtl.dispose();
    _sendCtl.dispose();
    _rxSub?.cancel();
    _cm.removeListener(_onCm);
    TcpLogStore.flushNow();
    super.dispose();
  }

  /// 把字节序列格式化为带偏移量的 hex dump（每行 16 字节）。
  static String _hexDump(Uint8List bytes, {int bytesPerLine = 16}) {
    final buf = StringBuffer();
    for (var i = 0; i < bytes.length; i += bytesPerLine) {
      final end =
          (i + bytesPerLine < bytes.length) ? i + bytesPerLine : bytes.length;
      final hex = <String>[];
      final ascii = <String>[];
      for (var j = i; j < end; j++) {
        hex.add(bytes[j].toRadixString(16).padLeft(2, '0'));
        final c = bytes[j];
        ascii.add(c >= 32 && c < 127 ? String.fromCharCode(c) : '.');
      }
      final offset = i.toRadixString(16).padLeft(8, '0');
      buf.writeln('$offset  ${hex.join(' ')}  ${ascii.join()}');
    }
    return buf.toString();
  }

  /// 把字节序列以 ASCII 形式展示：可打印字符原样，其余以 `.` 占位。
  static String _asciiView(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b >= 32 && b < 127 ? String.fromCharCode(b) : '.');
    }
    return sb.toString();
  }

  /// ASCII 模式下可选的 JSON 美化：把内容按 UTF-8 解码后尝试 [jsonDecode]，
  /// 成功则用 2 空格缩进美化输出；非合法 JSON（或含不可解码字节）时回退为
  /// 原始 ASCII 视图，保证任意字节流都有可读展示。
  static String _jsonView(Uint8List bytes) {
    try {
      final text = utf8.decode(bytes, allowMalformed: true);
      final decoded = jsonDecode(text);
      return JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return _asciiView(bytes);
    }
  }

  /// 右上角「历史连接」弹层：查看 / 切回 / 删除历史。
  void _openHistory() {
    showResponsiveSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setSheet) {
            final scheme = Theme.of(ctx2).colorScheme;
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                    child: Row(
                      children: [
                        const Text('历史连接',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        if (_history.isNotEmpty)
                          TextButton(
                            onPressed: () {
                              setSheet(() => _history.clear());
                              TcpHistoryService.save(_history);
                              Navigator.pop(ctx);
                            },
                            child: const Text('清空'),
                          ),
                      ],
                    ),
                  ),
                  Divider(height: 1),
                  if (_history.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Text('暂无历史连接',
                          style: TextStyle(color: Colors.grey)),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _history.length,
                      separatorBuilder: (_, _) => Divider(height: 1),
                      itemBuilder: (_, i) {
                        final h = _history[i];
                        return ListTile(
                          leading:
                              Icon(Icons.history, color: scheme.primary),
                          title: Text(h,
                              style: const TextStyle(fontFamily: 'monospace')),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: '删除',
                            onPressed: () {
                              setSheet(() => _history.removeAt(i));
                              TcpHistoryService.save(_history);
                            },
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _applyHistoryEntry(h);
                          },
                        );
                      },
                    ),
                ],
              ),
            ),
          );
          },
        );
      },
    );
  }

  /// 切回历史连接：若已连接先断开并清空日志，再回填地址与端口并持久化。
  void _applyHistoryEntry(String entry) {
    final parts = entry.split(':');
    if (parts.length != 2) return;
    final host = parts[0];
    final port = int.tryParse(parts[1]);
    if (port == null) return;
    if (_cm.state == DeviceConnectionState.connected) {
      _disconnect();
      setState(() => _log.clear());
    }
    _hostCtl.text = host;
    _portCtl.text = port.toString();
    _syncConfigFromFields();
    setState(() => _log.clear());
    _loadLog();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _cm.state == DeviceConnectionState.connected;
    final connecting = _cm.state == DeviceConnectionState.connecting;
    final color =
        connected ? Colors.green : (connecting ? Colors.orange : Colors.grey);
    final cfg = _cm.config is TcpRawConnectionConfig
        ? _cm.config as TcpRawConnectionConfig
        : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '历史连接',
            onPressed: _openHistory,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('TCP Client',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _hostCtl,
                          enabled: !connected,
                          decoration: const InputDecoration(
                            labelText: '主机',
                            hintText: 'IP 或域名',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 100,
                        child: TextField(
                          controller: _portCtl,
                          enabled: !connected,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '端口',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.circle, size: 10, color: color),
                      const SizedBox(width: 6),
                      Text(
                        connected
                            ? '已连接'
                            : connecting
                                ? '连接中…'
                                : _cm.state == DeviceConnectionState.error
                                    ? '连接错误'
                                    : '未连接',
                        style: TextStyle(color: color, fontSize: 13),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: connecting
                            ? null
                            : (connected ? _disconnect : _connect),
                        icon: Icon(connected ? Icons.link_off : Icons.link),
                        label: Text(connected ? '断开' : '连接'),
                      ),
                    ],
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
                      Expanded(
                        child: TextField(
                          controller: _sendCtl,
                          enabled: connected,
                          decoration: InputDecoration(
                            labelText: '发送内容',
                            hintText: _hexMode
                                ? '十六进制，如 01 03 00 00 00 01'
                                : '文本内容',
                            isDense: true,
                          ),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(_hexMode ? Icons.hexagon : Icons.text_fields),
                        tooltip: _hexMode ? '切换为文本模式' : '切换为 Hex 模式',
                        onPressed: () => setState(() => _hexMode = !_hexMode),
                      ),
                      FilledButton(
                        onPressed: connected ? _send : null,
                        child: const Text('发送'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('附加校验',
                          style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 12),
                      DropdownButton<String>(
                        value: _checksum,
                        isDense: true,
                        items: const [
                          DropdownMenuItem(
                              value: 'none', child: Text('无')),
                          DropdownMenuItem(
                              value: 'crc16', child: Text('CRC16-Modbus')),
                          DropdownMenuItem(
                              value: 'sum', child: Text('累加和 (8位)')),
                          DropdownMenuItem(
                              value: 'xor', child: Text('异或 (8位)')),
                        ],
                        onChanged: (v) =>
                            setState(() => _checksum = v ?? 'none'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(_checksumHint,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 6),
                  Text(
                      '发送模式：${_hexMode ? 'Hex（十六进制）' : '文本（UTF-8）'}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Text('收发日志（${_log.length}）',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              const Spacer(),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, label: Text('HEX')),
                  ButtonSegment(value: false, label: Text('ASCII')),
                ],
                selected: {_showHex},
                onSelectionChanged: (s) {
                  setState(() => _showHex = s.first);
                  SharedPreferences.getInstance()
                      .then((p) => p.setBool(_kShowHex, s.first));
                },
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              if (_log.isNotEmpty)
                TextButton(
                  onPressed: _clearLog,
                  child: const Text('清空'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_showHex)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  const Text('JSON 格式化',
                      style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 8),
                  Switch(
                    value: _jsonFormat,
                    onChanged: (v) {
                      setState(() => _jsonFormat = v);
                      SharedPreferences.getInstance()
                          .then((p) => p.setBool(_kJsonFormat, v));
                    },
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 12),
                  if (_jsonFormat)
                    const Expanded(
                      child: Text(
                        '美化 JSON 输出，非 JSON 内容原样显示',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ),
                ],
              ),
            ),
          if (_log.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('连接后收发的数据会显示在这里（最新在最上方）',
                    style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            ..._log.map((e) {
              final tx = e.tx;
              final c = tx ? Colors.blue : Colors.green;
              // 按 entry 携带的校验信息（TX 发送时记录 / RX 接收时按当前模式解析）
              // 把报文拆成「数据区」与「校验码区」。
              final hasCs =
                  e.checksumBytes != null && e.checksumBytes!.isNotEmpty;
              final payloadLen = hasCs
                  ? e.bytes.length - e.checksumBytes!.length
                  : e.bytes.length;
              final payload = e.bytes.sublist(0, payloadLen);
              final checksum = e.checksumBytes ?? Uint8List(0);
              final csColor = Colors.amber;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
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
                          if (hasCs) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: csColor.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                e.checksumLabel ?? '校验',
                                style: TextStyle(
                                    color: csColor,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                          const Spacer(),
                          Text('${e.bytes.length} B',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                          const SizedBox(width: 8),
                          Text(
                              '${e.time.hour.toString().padLeft(2, '0')}:'
                              '${e.time.minute.toString().padLeft(2, '0')}:'
                              '${e.time.second.toString().padLeft(2, '0')}',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(10),
                      child: SelectableText(
                        _showHex
                            ? _hexDump(payload)
                            : (_jsonFormat
                                ? _jsonView(payload)
                                : _asciiView(payload)),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                    if (hasCs) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: csColor.withValues(alpha: 0.12),
                          border: Border(
                            top: BorderSide(
                                color: csColor.withValues(alpha: 0.35)),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.verified, size: 14, color: csColor),
                            const SizedBox(width: 6),
                            Text('校验码 · ${e.checksumLabel ?? ''}',
                                style: TextStyle(
                                    color: csColor,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12)),
                            if (e.valid != null) ...[
                              const SizedBox(width: 8),
                              Icon(
                                e.valid!
                                    ? Icons.check_circle
                                    : Icons.error,
                                size: 14,
                                color: e.valid! ? Colors.green : Colors.red,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                e.valid! ? '校验通过' : '校验不匹配',
                                style: TextStyle(
                                  color: e.valid! ? Colors.green : Colors.red,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                            const Spacer(),
                            Text(_hexString(checksum),
                                style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: csColor)),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: SelectableText(
                          // 校验字节本身非文本语义，始终以 HEX 展示便于核对。
                          _hexDump(checksum),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: csColor,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
          if (cfg != null && !connected)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  '地址：${cfg.host.isEmpty ? '（未填写）' : cfg.host}:${cfg.port}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
        ],
      ),
    );
  }
}

/// 单条收发日志（TCP 详情页内部使用）。
class _RawLogEntry {
  _RawLogEntry({
    required this.tx,
    required this.bytes,
    required this.time,
    this.checksumLabel,
    this.checksumBytes,
    this.valid,
  });
  final bool tx; // true = TX，false = RX
  final Uint8List bytes;
  final DateTime time;
  final String? checksumLabel; // 附加校验时：校验方式名（如 "CRC16-Modbus"），否则 null
  final Uint8List? checksumBytes; // 附加在报文尾部的校验字节，否则 null
  final bool? valid; // null=无校验/未验证；true=校验通过；false=校验不匹配（RX 使用）
}
