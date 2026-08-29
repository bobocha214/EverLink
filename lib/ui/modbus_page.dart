import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/device_session.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/services/data_point.dart';
import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/modbus/modbus_client.dart';
import 'package:everlink/services/modbus/modbus_parse.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/ui/point_monitor_page.dart';
import 'package:everlink/utils/app_routes.dart';

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
  const ModbusPage({super.key, required this.session});

  /// 当前调试的设备会话（首页点击进入时传入，用于预填连接参数）。
  final DeviceSession session;

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

  _ModbusFunc _func = _ModbusFunc.readHolding;
  ModbusDataType _dataType = ModbusDataType.int16;
  bool _wordSwap = false;
  bool _byteSwap = false;
  bool _coilOn = true;

  // 连接状态以“共享 ConnectionManager”为准，保证与首页设备卡片、统计、筛选
  // 显示一致；真正的原始 TCP 客户端由 ConnectionManager.modbusDebugClient 持有，
  // 随会话存活，因此退出本页后连接不丢失。
  bool get _connected => _cm?.state == DeviceConnectionState.connected;

  /// 共享连接管理器（首页也用同一个实例，二者状态互通）。
  ConnectionManager? _cm;
  StreamSubscription<DeviceConnectionState>? _cmSub;

  final List<String> _log = <String>[];
  Timer? _pollTimer;
  bool _polling = false;
  final _pollIntervalCtl = TextEditingController(text: '1000');

  // —— 点位列表（读值结构化，供行内写入）——
  List<_ModbusPoint> _points = <_ModbusPoint>[];

  // —— 点位序列缓存：仅用于跳转「点位监控页」时带上已有历史曲线 ——
  // 本页不再内嵌图表，因此累积数据时不触发重绘。
  final Map<String, List<DataPoint>> _series = <String, List<DataPoint>>{};
  StreamSubscription<DataPoint>? _dpSub;

  @override
  void initState() {
    super.initState();
    // 优先用会话中保存的 Modbus 配置预填连接参数，方便直接调试已存设备。
    final cfg = widget.session.config;
    if (cfg is ModbusConnectionConfig) {
      _ipCtl.text = cfg.host;
      _portCtl.text = cfg.port.toString();
      _slaveCtl.text = cfg.unitId.toString();
    }
    // 订阅本设备 Modbus 数据点，缓存序列供「点位监控页」作为曲线初值。
    _dpSub = DataPointBus.instance.stream
        .where((p) => p.source == 'modbus')
        .listen(_onPoint);
    // 接入共享连接管理器：让本页连接状态与首页卡片/统计互通。
    _cm = SessionManager.instance.ensureManager(widget.session);
    _cmSub = _cm!.connectionStateStream.listen(_onSharedState);
  }

  /// 监听共享连接状态：首页断开 / 删除设备等使共享状态变非连接时，关闭本页
  /// 持有的原始客户端，保持“本页真实连接”与“共享状态”一致。
  void _onSharedState(DeviceConnectionState st) {
    if (st != DeviceConnectionState.connected) {
      final c = _cm?.modbusDebugClient;
      if (c != null && c.isConnected) {
        c.disconnect();
        _cm?.modbusDebugClient = null;
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _dpSub?.cancel();
    _cmSub?.cancel();
    // 退出调试页时保留共享连接（由 ConnectionManager 持有，首页断开 / 删除设备
    // 时才回收），仅在此保存最新连接参数，确保 IP / 端口 / 从站等修改不丢失。
    _syncConfig();
    for (final c in [
      _ipCtl,
      _portCtl,
      _slaveCtl,
      _addrCtl,
      _countCtl,
      _valueCtl,
      _valuesCtl,
      _statesCtl,
      _pollIntervalCtl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    final ip = _ipCtl.text.trim();
    final port = int.tryParse(_portCtl.text) ?? 502;
    // 复用或新建共享的原始客户端；IP / 端口变化则断开旧连接重建。连接随
    // ConnectionManager 存活，退出本页后不丢失。
    var client = _cm!.modbusDebugClient;
    if (client == null || client.host != ip || client.port != port) {
      client?.disconnect();
      client = ModbusTcpClient(ip, port);
      _cm!.modbusDebugClient = client;
    }
    try {
      if (!client.isConnected) await client.connect();
      _addLog('[连接] $ip:$port');
      _hist(HistoryOp.connect, true, '连接 $ip:$port',
          detail: '目标: $ip:$port\n从站: ${_slaveCtl.text.trim()}');
      _cm?.reflectState(DeviceConnectionState.connected);
      if (mounted) setState(() {});
    } on Object catch (e) {
      _addLog('[连接失败] $e');
      _hist(HistoryOp.connect, false, '连接失败 $ip:$port',
          detail: '目标: $ip:$port', error: '$e');
      client.disconnect();
      _cm!.modbusDebugClient = null;
      _cm?.reflectState(DeviceConnectionState.disconnected);
      if (mounted) setState(() {});
    }
  }

  void _disconnect() {
    _stopPoll();
    _cm?.modbusDebugClient?.disconnect();
    _cm?.modbusDebugClient = null;
    _addLog('[断开]');
    _hist(HistoryOp.disconnect, true,
        '断开 ${_ipCtl.text.trim()}:${_portCtl.text.trim()}');
    _cm?.reflectState(DeviceConnectionState.disconnected);
    if (mounted) setState(() {});
  }

  /// 执行当前功能码。轮询触发时 [fromPoll] 为 true，此时不写历史记录，
  /// 避免高频轮询把历史刷屏（HistoryService 每条都会落盘）。
  Future<void> _exec({bool fromPoll = false}) async {
    if (_cm?.modbusDebugClient == null || !_connected) {
      await _connect();
      if (_cm?.modbusDebugClient == null) return;
    }
    final slave = int.tryParse(_slaveCtl.text) ?? 1;
    final addr = int.tryParse(_addrCtl.text) ?? 0;
    try {
      if (_func.isRead) {
        final count = int.tryParse(_countCtl.text) ?? 1;
        final regs =
            await _cm!.modbusDebugClient!.readRegisters(slave, _func.code, addr, count);
        _showRawFrames();
        final out = _parseAndShow(regs, addr, slave);
        if (!fromPoll) {
          _hist(HistoryOp.read, true, '${_func.label} 地址 $addr × $count',
              detail: '${_frameDetail('${_func.label}\n'
                  '地址: $addr  数量: $count  类型: ${_dataType.label}')}'
                  '\n\n解析结果:\n${out.join('\n')}');
        }
      } else if (_func == _ModbusFunc.writeSingle) {
        final v = int.tryParse(_valueCtl.text) ?? 0;
        await _cm!.modbusDebugClient!.writeRegister(slave, addr, v);
        _showRawFrames();
        _addLog('[写] 0x06 addr=$addr value=$v');
        _hist(HistoryOp.write, true, '写单寄存器 地址 $addr = $v',
            detail: _frameDetail('写单寄存器 (0x06)\n地址: $addr  值: $v'));
      } else if (_func == _ModbusFunc.writeMultiple) {
        final vals = _valuesCtl.text
            .split(',')
            .map((e) => int.tryParse(e.trim()))
            .whereType<int>()
            .toList();
        await _cm!.modbusDebugClient!.writeRegisters(slave, addr, vals);
        _showRawFrames();
        _addLog('[写] 0x10 addr=$addr count=${vals.length}');
        _hist(HistoryOp.write, true, '写多寄存器 地址 $addr × ${vals.length}',
            detail: _frameDetail('写多寄存器 (0x10)\n'
                '起始地址: $addr  数量: ${vals.length}\n值: ${vals.join(', ')}'));
      } else if (_func == _ModbusFunc.writeCoil) {
        await _cm!.modbusDebugClient!.writeCoil(slave, addr, _coilOn);
        _showRawFrames();
        _addLog('[写] 0x05 addr=$addr on=$_coilOn');
        _hist(HistoryOp.write, true,
            '强制单线圈 地址 $addr = ${_coilOn ? 'ON' : 'OFF'}',
            detail: _frameDetail('强制单线圈 (0x05)\n地址: $addr  状态: $_coilOn'));
      } else if (_func == _ModbusFunc.writeCoils) {
        final states = _statesCtl.text
            .split(',')
            .map((e) => e.trim() == '1' || e.trim().toLowerCase() == 'true')
            .toList();
        await _cm!.modbusDebugClient!.writeCoils(slave, addr, states);
        _showRawFrames();
        _addLog('[写] 0x0F addr=$addr count=${states.length}');
        _hist(HistoryOp.write, true, '强制多线圈 地址 $addr × ${states.length}',
            detail: _frameDetail('强制多线圈 (0x0F)\n'
                '起始地址: $addr  数量: ${states.length}\n'
                '状态: ${states.map((e) => e ? 1 : 0).join(', ')}'));
      }
      if (mounted) setState(() {});
    } on Object catch (e) {
      _addLog('[错误] $e');
      if (!fromPoll) {
        _hist(_func.isRead ? HistoryOp.read : HistoryOp.write, false,
            '${_func.label} 失败 地址 $addr',
            detail: _frameDetail('${_func.label}\n地址: $addr'), error: '$e');
      }
      if (mounted) setState(() {});
    }
  }

  List<String> _parseAndShow(List<int> regs, int addr, int slave) {
    final order = ModbusByteOrder(wordSwap: _wordSwap, byteSwap: _byteSwap);
    final out = <String>[];
    final pts = <_ModbusPoint>[];
    final step = _dataType.registerCount;
    for (var i = 0; i + step <= regs.length; i += step) {
      final v = parseModbusValue(regs, _dataType,
          start: i, order: order);
      final tag = '${addr + i}';
      out.add('[$tag] ${_dataType.label} = $v');
      pts.add(_ModbusPoint(address: addr + i, value: v ?? 0, type: _dataType.label));
      // 写入数据点总线，驱动单点位监控页可视化
      DataPointBus.instance.emit(DataPoint(
        source: 'modbus',
        tag: tag,
        value: v ?? 0,
        time: DateTime.now(),
      ));
    }
    _addLog('[读] ${regs.length} 寄存器 → ${out.length} 值');
    _points = pts;
    if (mounted) setState(() {});
    return out;
  }

  void _showRawFrames() {
    _addLog('[Tx] ${_toHex(_cm?.modbusDebugClient?.lastRequest)}');
    _addLog('[Rx] ${_toHex(_cm?.modbusDebugClient?.lastResponse)}');
  }

  void _addLog(String s) {
    _log.add('${_ts()} $s');
    if (_log.length > 500) _log.removeAt(0);
  }

  /// 沉淀一条历史记录，供「历史」Tab 追溯（含原始报文，可查看详情）。
  void _hist(HistoryOp op, bool success, String summary,
      {String? detail, String? error}) {
    HistoryService.instance.add(
      HistoryRecord(
        time: DateTime.now(),
        type: widget.session.type,
        deviceName: widget.session.name,
        op: op,
        success: success,
        summary: summary,
        detail: detail,
        error: error,
      ),
    );
  }

  /// 把当前连接参数（IP / 端口 / 从站）写回会话配置并落盘，使修改被保存、
  /// 首页设备卡片同步更新，下次进入页面仍显示最新值。
  void _syncConfig() {
    widget.session.config = ModbusConnectionConfig(
      host: _ipCtl.text.trim(),
      port: int.tryParse(_portCtl.text) ?? 502,
      unitId: int.tryParse(_slaveCtl.text) ?? 1,
    );
    SessionManager.instance.persist();
  }

  /// 组装带原始报文的详情文本。
  String _frameDetail(String head) {
    final b = StringBuffer(head);
    b.writeln();
    b.writeln('从站: ${_slaveCtl.text.trim()}');
    b.writeln('Tx: ${_toHex(_cm?.modbusDebugClient?.lastRequest)}');
    b.write('Rx: ${_toHex(_cm?.modbusDebugClient?.lastResponse)}');
    return b.toString();
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
    _pollTimer = Timer.periodic(
        Duration(milliseconds: ms), (_) => _exec(fromPoll: true));
    if (mounted) setState(() {});
  }

  void _stopPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _polling = false;
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
          _buildPointsCard(),
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
                      onChanged: (_) => _syncConfig(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _portCtl,
                      decoration: const InputDecoration(labelText: '端口'),
                      keyboardType: TextInputType.number,
                      onChanged: (_) => _syncConfig(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 70,
                    child: TextField(
                      controller: _slaveCtl,
                      decoration: const InputDecoration(labelText: '从站'),
                      keyboardType: TextInputType.number,
                      onChanged: (_) => _syncConfig(),
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

  Widget _buildPointsCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('点位', style: TextStyle(fontWeight: FontWeight.w600)),
              const Text('点击点位查看实时曲线，点右侧图标直接写入',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 8),
              if (_points.isEmpty)
                const Text('暂无数据，请先读取寄存器',
                    style: TextStyle(color: Colors.grey))
              else
                ..._points.map(_buildPointRow),
            ],
          ),
        ),
      );

  Widget _buildPointRow(_ModbusPoint p) => InkWell(
        onTap: () => _openMonitor(p),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(
            children: [
              const Icon(Icons.show_chart, size: 18, color: Colors.teal),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('地址 ${p.address}',
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w500)),
                    Text(p.type,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
              Text('${p.value}',
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 16)),
              IconButton(
                icon: const Icon(Icons.edit, size: 20),
                tooltip: '写入此点位',
                onPressed: () => _showWriteDialog(p.address, p.value),
              ),
            ],
          ),
        ),
      );

  Future<void> _showWriteDialog(int addr, num current) async {
    final ctl = TextEditingController(text: current.toString());
    var asCoil = false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSt) => AlertDialog(
          title: Text('写入地址 $addr'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctl,
                  decoration: const InputDecoration(labelText: '写入值'),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                const Text('写入类型', style: TextStyle(fontSize: 13)),
                RadioListTile<bool>(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('写寄存器 (0x06)'),
                  value: false,
                  groupValue: asCoil,
                  onChanged: (v) => setSt(() => asCoil = v ?? false),
                ),
                RadioListTile<bool>(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('强制线圈 (0x05)'),
                  value: true,
                  groupValue: asCoil,
                  onChanged: (v) => setSt(() => asCoil = v ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('写入'),
            ),
          ],
        ),
      ),
    );
    if (result == true) {
      await _writePoint(addr, asCoil, ctl.text);
    }
  }

  Future<void> _writePoint(int addr, bool asCoil, String raw) async {
    if (_cm?.modbusDebugClient == null || !_connected) {
      await _connect();
      if (_cm?.modbusDebugClient == null) return;
    }
    final slave = int.tryParse(_slaveCtl.text) ?? 1;
    try {
      if (asCoil) {
        final on =
            raw.trim() == '1' || raw.trim().toLowerCase() == 'true';
        await _cm!.modbusDebugClient!.writeCoil(slave, addr, on);
        _addLog('[写] 0x05 addr=$addr on=$on');
        _hist(HistoryOp.write, true,
            '点位写入 地址 $addr = ${on ? 'ON' : 'OFF'}',
            detail: _frameDetail('点位写入 · 强制线圈 (0x05)\n地址: $addr  状态: $on'));
      } else {
        final v = int.tryParse(raw) ?? 0;
        await _cm!.modbusDebugClient!.writeRegister(slave, addr, v);
        _addLog('[写] 0x06 addr=$addr value=$v');
        _hist(HistoryOp.write, true, '点位写入 地址 $addr = $v',
            detail: _frameDetail('点位写入 · 写寄存器 (0x06)\n地址: $addr  值: $v'));
      }
      // 重新读取以刷新点位值；此处不再另记一条读历史。
      await _exec(fromPoll: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('写入成功')),
        );
      }
    } on Object catch (e) {
      _addLog('[写失败] $e');
      _hist(HistoryOp.write, false, '点位写入失败 地址 $addr',
          detail: _frameDetail('点位写入\n地址: $addr  原始输入: $raw'), error: '$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('写入失败：$e')),
        );
      }
    }
  }

  /// 打开单点位监控页：实时趋势 + 仪表盘 + 统计，并可直接写入。
  void _openMonitor(_ModbusPoint p) {
    final tag = '${p.address}';
    AppRoutes.push(context, PointMonitorPage(
          source: 'modbus',
          tag: tag,
          label: '寄存器 ${p.address}',
          initial: List<DataPoint>.from(_series[tag] ?? const <DataPoint>[]),
          onWrite: () => _showWriteDialog(p.address, p.value),
        ));
  }

  void _onPoint(DataPoint p) {
    final list = _series.putIfAbsent(p.tag, () => <DataPoint>[]);
    list.add(p);
    if (list.length > 300) list.removeAt(0);
  }

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

/// 读取得到的单个 Modbus 点位（地址 + 当前值 + 数据类型），用于「点位列表」中的行内写入。
class _ModbusPoint {
  final int address;
  final num value;
  final String type;

  _ModbusPoint(
      {required this.address, required this.value, required this.type});
}
