import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:everlink/services/data_point.dart';
import 'package:everlink/services/modbus/modbus_client.dart';
import 'package:everlink/services/modbus/modbus_parse.dart';

enum _ModbusFunc {
  readHolding(0x03, '读保持寄存器 (0x03)'),
  readInput(0x04, '读输入寄存器 (0x04)'),
  writeSingle(0x06, '写单寄存器 (0x06)'),
  writeMultiple(0x10, '写多寄存器 (0x10)'),
  writeCoil(0x05, '强制单线圈 (0x05)'),
  writeCoils(0x0F, '强制多线圈 (0x0F)');

  const _ModbusFunc(this.code, this.label);
  final int code;
  final String label;
  bool get isRead => this == readHolding || this == readInput;
}

class ModbusPage extends StatefulWidget {
  const ModbusPage({super.key});

  @override
  State<ModbusPage> createState() => _ModbusPageState();
}

class _ModbusPageState extends State<ModbusPage> {
  final _ipCtl = TextEditingController(text: '192.168.1.1');
  final _portCtl = TextEditingController(text: '502');
  final _slaveCtl = TextEditingController(text: '1');
  final _addrCtl = TextEditingController(text: '0');
  final _countCtl = TextEditingController(text: '10');
  final _valueCtl = TextEditingController(text: '0');
  final _valuesCtl = TextEditingController(text: '0, 1, 2');
  final _statesCtl = TextEditingController(text: '1, 0, 1');
  final _baseIpCtl = TextEditingController(text: '192.168.1');

  _ModbusFunc _func = _ModbusFunc.readHolding;
  ModbusDataType _dataType = ModbusDataType.float32;
  bool _wordSwap = false;
  bool _byteSwap = false;
  bool _coilOn = true;

  ModbusTcpClient? _client;
  bool get _connected => _client?.isConnected ?? false;

  final List<String> _log = <String>[];
  List<String> _results = <String>[];
  List<double> _history = <double>[];
  Timer? _pollTimer;
  bool _polling = false;
  final _pollIntervalCtl = TextEditingController(text: '1000');

  List<String> _scanResults = <String>[];
  bool _scanning = false;

  @override
  void dispose() {
    _pollTimer?.cancel();
    _client?.disconnect();
    for (final c in [
      _ipCtl,
      _portCtl,
      _slaveCtl,
      _addrCtl,
      _countCtl,
      _valueCtl,
      _valuesCtl,
      _statesCtl,
      _baseIpCtl,
      _pollIntervalCtl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    final ip = _ipCtl.text.trim();
    final port = int.tryParse(_portCtl.text) ?? 502;
    _client?.disconnect();
    _client = ModbusTcpClient(ip, port);
    try {
      await _client!.connect();
      _addLog('[连接] $ip:$port');
      if (mounted) setState(() {});
    } on Object catch (e) {
      _addLog('[连接失败] $e');
      _client = null;
      if (mounted) setState(() {});
    }
  }

  void _disconnect() {
    _stopPoll();
    _client?.disconnect();
    _client = null;
    _addLog('[断开]');
    if (mounted) setState(() {});
  }

  Future<void> _exec() async {
    if (_client == null || !_connected) {
      await _connect();
      if (_client == null) return;
    }
    final slave = int.tryParse(_slaveCtl.text) ?? 1;
    final addr = int.tryParse(_addrCtl.text) ?? 0;
    try {
      if (_func.isRead) {
        final count = int.tryParse(_countCtl.text) ?? 1;
        final regs =
            await _client!.readRegisters(slave, _func.code, addr, count);
        _showRawFrames();
        _parseAndShow(regs, addr, slave);
      } else if (_func == _ModbusFunc.writeSingle) {
        final v = int.tryParse(_valueCtl.text) ?? 0;
        await _client!.writeRegister(slave, addr, v);
        _showRawFrames();
        _addLog('[写] 0x06 addr=$addr value=$v');
      } else if (_func == _ModbusFunc.writeMultiple) {
        final vals = _valuesCtl.text
            .split(',')
            .map((e) => int.tryParse(e.trim()))
            .whereType<int>()
            .toList();
        await _client!.writeRegisters(slave, addr, vals);
        _showRawFrames();
        _addLog('[写] 0x10 addr=$addr count=${vals.length}');
      } else if (_func == _ModbusFunc.writeCoil) {
        await _client!.writeCoil(slave, addr, _coilOn);
        _showRawFrames();
        _addLog('[写] 0x05 addr=$addr on=$_coilOn');
      } else if (_func == _ModbusFunc.writeCoils) {
        final states = _statesCtl.text
            .split(',')
            .map((e) => e.trim() == '1' || e.trim().toLowerCase() == 'true')
            .toList();
        await _client!.writeCoils(slave, addr, states);
        _showRawFrames();
        _addLog('[写] 0x0F addr=$addr count=${states.length}');
      }
      if (mounted) setState(() {});
    } on Object catch (e) {
      _addLog('[错误] $e');
      if (mounted) setState(() {});
    }
  }

  void _parseAndShow(List<int> regs, int addr, int slave) {
    final order = ModbusByteOrder(wordSwap: _wordSwap, byteSwap: _byteSwap);
    final out = <String>[];
    final step = _dataType.registerCount;
    num? first;
    for (var i = 0; i + step <= regs.length; i += step) {
      final v = parseModbusValue(regs, _dataType,
          start: i, order: order);
      final tag = '${addr + i}';
      out.add('[$tag] ${_dataType.label} = $v');
      if (first == null && v != null) first = v;
      // 写入数据点总线，供记录仪/可视化消费
      DataPointBus.instance.emit(DataPoint(
        source: 'modbus',
        tag: tag,
        value: v ?? 0,
        time: DateTime.now(),
      ));
    }
    if (first != null) {
      _history.add(first.toDouble());
      if (_history.length > 300) _history.removeAt(0);
    }
    _addLog('[读] ${regs.length} 寄存器 → ${out.length} 值');
    _results = out;
    if (mounted) setState(() {});
  }

  void _showRawFrames() {
    _addLog('[Tx] ${_toHex(_client?.lastRequest)}');
    _addLog('[Rx] ${_toHex(_client?.lastResponse)}');
  }

  void _addLog(String s) {
    _log.add('${_ts()} $s');
    if (_log.length > 500) _log.removeAt(0);
  }

  String _ts() {
    final t = DateTime.now();
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }

  static String _toHex(List<int>? b) =>
      b == null ? '(空)' : b.map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  void _startPoll() {
    final ms = int.tryParse(_pollIntervalCtl.text) ?? 1000;
    if (ms < 100) return;
    _polling = true;
    _pollTimer = Timer.periodic(Duration(milliseconds: ms), (_) => _exec());
    if (mounted) setState(() {});
  }

  void _stopPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _polling = false;
    if (mounted) setState(() {});
  }

  Future<void> _scan() async {
    final base = _baseIpCtl.text.trim();
    if (!base.contains(RegExp(r'^\d+\.\d+\.\d+$'))) {
      _addLog('[扫描] 网段格式应为 x.x.x');
      if (mounted) setState(() {});
      return;
    }
    _scanning = true;
    _scanResults = <String>[];
    if (mounted) setState(() {});
    final futures = <Future<void>>[];
    for (var i = 1; i <= 254; i++) {
      final ip = '$base.$i';
      futures.add(
        Socket.connect(ip, 502, timeout: const Duration(milliseconds: 300))
            .then((s) {
          s.destroy();
          _scanResults.add(ip);
          if (mounted) setState(() {});
        }).catchError((_) {}),
      );
    }
    await Future.wait(futures);
    _scanning = false;
    _addLog('[扫描] 发现 ${_scanResults.length} 个 502 从站');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Modbus 调试')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildConnCard(),
          const SizedBox(height: 12),
          _buildOpCard(),
          const SizedBox(height: 12),
          _buildResultCard(),
          const SizedBox(height: 12),
          _buildScanCard(),
          const SizedBox(height: 12),
          _buildLogCard(),
        ],
      ),
    );
  }

  Widget _buildConnCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('连接', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ipCtl,
                      decoration: const InputDecoration(labelText: 'IP'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _portCtl,
                      decoration: const InputDecoration(labelText: '端口'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 70,
                    child: TextField(
                      controller: _slaveCtl,
                      decoration: const InputDecoration(labelText: '从站'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  ElevatedButton(
                    onPressed: _connected ? null : _connect,
                    child: const Text('连接'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _connected ? _disconnect : null,
                    child: const Text('断开'),
                  ),
                  const SizedBox(width: 12),
                  Chip(
                    label: Text(_connected ? '已连接' : '未连接'),
                    backgroundColor:
                        _connected ? Colors.green.shade100 : Colors.grey.shade200,
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _buildOpCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('操作', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              DropdownButtonFormField<_ModbusFunc>(
                value: _func,
                items: _ModbusFunc.values
                    .map((f) => DropdownMenuItem(value: f, child: Text(f.label)))
                    .toList(),
                onChanged: (v) => setState(() => _func = v!),
                decoration: const InputDecoration(labelText: '功能码'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _addrCtl,
                      decoration: const InputDecoration(labelText: '起始地址'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  if (_func.isRead) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _countCtl,
                        decoration: const InputDecoration(labelText: '数量'),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              if (!_func.isRead) ..._buildWriteFields(),
              if (_func.isRead) ...[
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<ModbusDataType>(
                        value: _dataType,
                        items: ModbusDataType.values
                            .map((t) =>
                                DropdownMenuItem(value: t, child: Text(t.label)))
                            .toList(),
                        onChanged: (v) => setState(() => _dataType = v!),
                        decoration:
                            const InputDecoration(labelText: '数据类型'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('字交换', style: TextStyle(fontSize: 13)),
                        value: _wordSwap,
                        onChanged: (v) => setState(() => _wordSwap = v),
                      ),
                    ),
                    Expanded(
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('字节交换', style: TextStyle(fontSize: 13)),
                        value: _byteSwap,
                        onChanged: (v) => setState(() => _byteSwap = v),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  ElevatedButton(
                    onPressed: _exec,
                    child: const Text('执行'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _polling ? _stopPoll : _startPoll,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _polling ? Colors.orange : Colors.teal,
                    ),
                    child: Text(_polling ? '停止轮询' : '开始轮询'),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _pollIntervalCtl,
                      decoration: const InputDecoration(labelText: '间隔(ms)'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              if (_history.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('实时趋势（首个解析值）',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                SizedBox(height: 80, child: _Sparkline(points: _history)),
              ],
            ],
          ),
        ),
      );

  List<Widget> _buildWriteFields() {
    if (_func == _ModbusFunc.writeSingle) {
      return [
        TextField(
          controller: _valueCtl,
          decoration: const InputDecoration(labelText: '写入值 (0-65535)'),
          keyboardType: TextInputType.number,
        ),
      ];
    }
    if (_func == _ModbusFunc.writeMultiple) {
      return [
        TextField(
          controller: _valuesCtl,
          decoration:
              const InputDecoration(labelText: '寄存器值，逗号分隔 (如 0,1,2)'),
        ),
      ];
    }
    if (_func == _ModbusFunc.writeCoil) {
      return [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('线圈状态'),
          value: _coilOn,
          onChanged: (v) => setState(() => _coilOn = v),
        ),
      ];
    }
    if (_func == _ModbusFunc.writeCoils) {
      return [
        TextField(
          controller: _statesCtl,
          decoration:
              const InputDecoration(labelText: '线圈状态，逗号分隔 (1/0 或 true/false)'),
        ),
      ];
    }
    return [];
  }

  Widget _buildResultCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('解析结果', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              if (_results.isEmpty)
                const Text('暂无数据', style: TextStyle(color: Colors.grey))
              else
                ..._results.map((r) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(r,
                          style: const TextStyle(fontFamily: 'monospace')),
                    )),
            ],
          ),
        ),
      );

  Widget _buildScanCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('网段扫描 Modbus 从站 (502)',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _baseIpCtl,
                      decoration:
                          const InputDecoration(labelText: '网段前缀 (x.x.x)'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _scanning ? null : _scan,
                    child: Text(_scanning ? '扫描中…' : '扫描'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_scanResults.isEmpty)
                const Text('未发现从站', style: TextStyle(color: Colors.grey))
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: _scanResults
                      .map((ip) => ActionChip(
                            label: Text(ip),
                            onPressed: () {
                              _ipCtl.text = ip;
                              if (mounted) setState(() {});
                            },
                          ))
                      .toList(),
                ),
            ],
          ),
        ),
      );

  Widget _buildLogCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('收发日志',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: _log.join('\n')));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('日志已复制到剪贴板')),
                        );
                      }
                    },
                    child: const Text('复制'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _log.clear()),
                    child: const Text('清空'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                height: 160,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView(
                  children: _log
                      .map((l) => Text(
                            l,
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ))
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      );
}

/// 轻量趋势迷你曲线（实时数据可视化占位，模块九 会扩展为完整趋势图）。
class _Sparkline extends StatelessWidget {
  final List<double> points;
  const _Sparkline({required this.points});

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return const Center(child: Text('无数据', style: TextStyle(color: Colors.grey)));
    }
    return CustomPaint(
      size: const Size(double.infinity, 80),
      painter: _SparklinePainter(points),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> points;
  _SparklinePainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final min = points.reduce((a, b) => a < b ? a : b);
    final max = points.reduce((a, b) => a > b ? a : b);
    final range = (max - min) == 0 ? 1.0 : (max - min);
    final dx = size.width / (points.length - 1).clamp(1, 10000);
    final paint = Paint()
      ..color = Colors.teal
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = i * dx;
      final y = size.height - ((points[i] - min) / range) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}
