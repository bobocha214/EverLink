import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:everlink/services/lan_transfer/lan_models.dart';
import 'package:everlink/services/lan_transfer/lan_transfer_manager.dart';
import 'package:everlink/ui/lan_chat_page.dart';

/// 快传管理页：频道与设备的列表入口。
///
/// 展示已加入的频道和已发现的设备，点击某个频道或设备进入
/// [LanChatPage] 进行聊天。每个频道卡片上直接放置二维码图标，
/// 点击即可展示该频道的二维码，无需进入聊天页。
class LanTransferPage extends StatefulWidget {
  const LanTransferPage({super.key});

  @override
  State<LanTransferPage> createState() => _LanTransferPageState();
}

class _LanTransferPageState extends State<LanTransferPage> {
  final manager = LanTransferManager.instance;
  bool _netExpanded = false;

  @override
  void initState() {
    super.initState();
    manager.addListener(_onChanged);
    _init();
  }

  Future<void> _init() async {
    if (!manager.isRunning) await manager.start();
    if (mounted) setState(() {});
  }

  void _onChanged() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    manager.removeListener(_onChanged);
    super.dispose();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('快传'),
        actions: _transferActions(),
      ),
      body: _buildTransferBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _joinChannelDialog,
        icon: const Icon(Icons.add),
        label: const Text('加入 / 创建频道'),
      ),
    );
  }

  /// 「传输」标签页右上角操作（扫描 + 菜单）。
  List<Widget> _transferActions() => [
        IconButton(
          icon: manager.isScanning
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_find),
          tooltip: '扫描局域网设备',
          onPressed: manager.isScanning ? null : _scan,
        ),
        PopupMenuButton<String>(
          onSelected: _onMenu,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'name', child: Text('修改我的名字')),
            PopupMenuItem(value: 'add', child: Text('手动添加设备')),
            PopupMenuItem(value: 'port', child: Text('修改端口')),
            PopupMenuItem(value: 'refresh', child: Text('刷新网络信息')),
            PopupMenuItem(value: 'help', child: Text('使用说明')),
            PopupMenuItem(value: 'clear', child: Text('清空全部消息')),
          ],
        ),
      ];

  /// 「传输」标签页主体：信息条 + 频道 + 设备。
  Widget _buildTransferBody() => ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: [
          _buildInfoBar(),
          _buildChannelSection(),
          _buildDeviceSection(),
        ],
      );

  void _onMenu(String v) {
    switch (v) {
      case 'name':
        _editName();
      case 'add':
        _addDeviceManually();
      case 'port':
        _changePort();
      case 'refresh':
        _refreshNetwork();
      case 'help':
        _showHelp();
      case 'clear':
        _confirmClearAll();
    }
  }

  Future<void> _refreshNetwork() async {
    _toast('正在刷新网络信息…');
    await manager.refreshAddress();
    if (!mounted) return;
    _toast('网络信息已刷新');
  }

  Future<void> _changePort() async {
    final ctl = TextEditingController(text: '${manager.port}');
    final v = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('修改快传端口'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '端口（1-65535）',
            hintText: '默认 5321',
            helperText: '修改后服务会重启，网页端需使用新端口访问',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(d, ctl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (v == null || v.isEmpty) return;
    final p = int.tryParse(v);
    _toast('正在切换端口…');
    final r = await manager.changePort(p ?? -1);
    if (!mounted) return;
    _toast(r.detail);
    setState(() {});
  }

  // ----------------------------------------------------------- 顶部信息条

  Widget _buildInfoBar() {
    final online = manager.devices.length;
    final info = manager.networkInfo;
    final type = (info['connectionType'] as String?) ?? '';
    final ssid = _ssid(info);
    final (connColor, connIcon) = _connStyle(type);
    return Column(
      children: [
        Material(
          color: Colors.teal.withValues(alpha: 0.08),
          child: InkWell(
            onTap: _editName,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  const Icon(Icons.badge_outlined, size: 22, color: Colors.teal),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                manager.selfName.isEmpty
                                    ? '未命名设备'
                                    : manager.selfName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 14),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.edit, size: 13, color: Colors.grey),
                            if (type.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              _connChip(type, connColor, connIcon),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _netSummary(type, ssid, online),
                          style: TextStyle(
                            fontSize: 11,
                            color: type == '移动数据'
                                ? Colors.orange[700]
                                : Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 网络信息展开按钮
                  GestureDetector(
                    onTap: () => setState(() => _netExpanded = !_netExpanded),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: connColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(connIcon, size: 14, color: connColor),
                          const SizedBox(width: 4),
                          Text(
                            _netExpanded ? '收起' : '网络',
                            style: TextStyle(
                                fontSize: 11,
                                color: connColor,
                                fontWeight: FontWeight.w600),
                          ),
                          Icon(
                            _netExpanded ? Icons.expand_less : Icons.expand_more,
                            size: 16,
                            color: connColor,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_netExpanded) _buildNetPanel(),
      ],
    );
  }

  Widget _buildNetPanel() {
    final info = manager.networkInfo;
    final addrs = manager.allAddresses;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.06),
        border: Border(
          bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildConnTypeBanner(info),
          const SizedBox(height: 10),
          // 所有 IP
          if (addrs.isNotEmpty) ...[
            const Text(
              '本机所有可访问 IP',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: addrs.map((a) {
                final ip = a['ip'] as String? ?? '';
                final type = a['type'] as String? ?? '';
                final isPrimary = a['primary'] == true;
                return GestureDetector(
                  onTap: () => _copyText('http://$ip:${manager.port}/'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isPrimary
                          ? Colors.teal.withValues(alpha: 0.12)
                          : Colors.grey.withValues(alpha: 0.08),
                      border: Border.all(
                        color: isPrimary
                            ? Colors.teal.withValues(alpha: 0.3)
                            : Colors.grey.withValues(alpha: 0.2),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          ip,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isPrimary ? Colors.teal : Colors.black87,
                          ),
                        ),
                        if (type.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.grey.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              type,
                              style: const TextStyle(fontSize: 9, color: Colors.grey),
                            ),
                          ),
                        ],
                        if (isPrimary) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.teal,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '主',
                              style: TextStyle(fontSize: 9, color: Colors.white),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 10),
          ],
          // 网络详情网格
          ..._netRows(info),
        ],
      ),
    );
  }

  /// 连接类型横幅：第一时间区分 WiFi / 移动数据 / 以太网，避免"连了流量却以为在 WiFi"。
  Widget _buildConnTypeBanner(Map<String, dynamic> info) {
    final type = (info['connectionType'] as String?) ?? '';
    if (type.isEmpty) return const SizedBox.shrink();
    final (color, icon) = _connStyle(type);
    final isWifi = type == 'WiFi';
    final ssid = _ssid(info);
    final primary = manager.selfAddress.isEmpty ? '—' : manager.selfAddress;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    type,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  isWifi
                      ? (ssid.isNotEmpty
                          ? '$ssid · $primary'
                          : 'WiFi 名称未获取到 · $primary')
                      : '当前走$type链路 · $primary',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500),
                ),
                if (isWifi && ssid.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text(
                      '需要定位权限才能读取 WiFi 名称',
                      style: TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ),
                if (type == '移动数据')
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '移动数据下其他设备无法访问，请连接同一 WiFi',
                      style:
                          TextStyle(fontSize: 10, color: Colors.orange[800]),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 从网络信息里取出清洗后的 WiFi 名称（去引号、过滤 `<unknown ssid>`）。
  String _ssid(Map<String, dynamic> info) {
    var ssid = (info['wifiName'] as String?) ?? '';
    if (ssid.length >= 2 && ssid.startsWith('"') && ssid.endsWith('"')) {
      ssid = ssid.substring(1, ssid.length - 1);
    }
    if (ssid == '<unknown ssid>' || ssid == '0x' || ssid == '0x00') ssid = '';
    return ssid;
  }

  /// 常驻信息条的副标题：优先显示 WiFi 名称，非 WiFi 链路明确标出类型。
  String _netSummary(String type, String ssid, int online) {
    if (!manager.hasLanAddress) {
      if (type == '移动数据') return '当前使用移动数据，需连同一 WiFi 才能互传';
      if (type == '无网络' || type.isEmpty) return '未连接网络，请检查 WiFi';
      return '未获取到局域网地址（$type）';
    }
    final addr = manager.selfAddress;
    final String head;
    if (type == 'WiFi') {
      head = ssid.isNotEmpty ? '$ssid · $addr' : 'WiFi · $addr';
    } else if (type.isNotEmpty) {
      head = '$type · $addr';
    } else {
      head = addr;
    }
    return '$head · 发现 $online 台设备';
  }

  /// 连接类型小标签，让「WiFi / 移动数据」在常驻位置一眼可分。
  Widget _connChip(String type, Color color, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
            Text(
              type,
              style: TextStyle(
                  fontSize: 10, color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );

  (Color, IconData) _connStyle(String type) {
    switch (type) {
      case 'WiFi':
        return (Colors.blue, Icons.wifi);
      case '移动数据':
        return (Colors.orange, Icons.signal_cellular_alt);
      case '以太网':
        return (Colors.purple, Icons.lan);
      case 'VPN':
        return (Colors.amber, Icons.vpn_lock);
      case 'USB 共享':
        return (Colors.cyan, Icons.usb);
      case '无网络':
        return (Colors.grey, Icons.wifi_off);
      default:
        return (Colors.blueGrey, Icons.wifi);
    }
  }

  List<Widget> _netRows(Map<String, dynamic> info) {
    final rows = <_NetRow>[];
    // WiFi 名称
    final ssid = _ssid(info);
    rows.add(_NetRow('WiFi 名称', ssid.isEmpty ? '—' : ssid));
    // 子网掩码
    rows.add(_NetRow('子网掩码', (info['subnetMask'] as String?) ?? '—'));
    // 网关
    rows.add(_NetRow('网关', (info['gateway'] as String?) ?? '—'));
    // DNS
    final dns = info['dnsServers'];
    if (dns is List && dns.isNotEmpty) {
      rows.add(_NetRow('DNS', dns.whereType<String>().join('、')));
    } else {
      rows.add(const _NetRow('DNS', '—'));
    }
    // 信号强度
    final rssi = info['signalRssi'];
    final sigDesc = info['signalDescription'];
    if (rssi != null && rssi is int && rssi != 0) {
      rows.add(_NetRow('信号强度', '$rssi dBm（$sigDesc）'));
    } else {
      rows.add(const _NetRow('信号强度', '—'));
    }
    rows.add(_NetRow('服务端口', '${manager.port}'));

    return [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 72,
                child: Text(
                  r.label,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
              Expanded(
                child: Text(
                  r.value,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('已复制：$text'),
        duration: const Duration(seconds: 2),
      ));
  }

  // ----------------------------------------------------------- 频道区域

  Widget _buildChannelSection() {
    final channels = manager.channels;
    return _Section(
      title: '频道',
      icon: Icons.tag,
      count: channels.length,
      children: [
        for (final c in channels) _buildChannelCard(c),
      ],
    );
  }

  Widget _buildChannelCard(LanChannel c) {
    final msgs = manager.messagesOf(c.name);
    final lastMsg = msgs.isNotEmpty ? msgs.last : null;
    final unreadHint = lastMsg != null ? lastMsg.summary : '暂无消息';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: c.isPrivate
                ? Colors.orange.withValues(alpha: 0.12)
                : Colors.teal.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            c.isPrivate ? Icons.lock : Icons.tag,
            color: c.isPrivate ? Colors.orange : Colors.teal,
            size: 20,
          ),
        ),
        title: Text(
          c.name,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: Text(
          unreadHint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (msgs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  '${msgs.length}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            // 每个频道卡片上直接放二维码图标，点击弹出该频道的二维码。
            IconButton(
              icon: const Icon(Icons.qr_code_2, size: 20),
              color: Colors.teal,
              tooltip: '频道二维码',
              onPressed: manager.hasLanAddress
                  ? () => _showQrForChannel(c.name)
                  : null,
            ),
          ],
        ),
        onTap: () => _enterChat(ChatTarget.channel(c.name)),
        onLongPress:
            c.name == kPublicChannel ? null : () => _confirmLeave(c.name),
      ),
    );
  }

  // ----------------------------------------------------------- 设备区域

  Widget _buildDeviceSection() {
    final devices = manager.devices;
    if (devices.isEmpty) return const SizedBox.shrink();
    return _Section(
      title: '设备',
      icon: Icons.devices,
      count: devices.length,
      children: [
        for (final d in devices) _buildDeviceCard(d),
      ],
    );
  }

  Widget _buildDeviceCard(DiscoveredDevice d) {
    final host = d.host;
    final p2pMsgs = manager.messages
        .where((m) => m.isP2P && m.peer.split(':').first == host)
        .toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    final lastMsg = p2pMsgs.isNotEmpty ? p2pMsgs.last : null;
    final hint = lastMsg != null ? lastMsg.summary : d.address;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 16),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: d.isWeb
                ? Colors.blue.withValues(alpha: 0.12)
                : Colors.purple.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            d.isWeb ? Icons.language : Icons.smartphone,
            color: d.isWeb ? Colors.blue : Colors.purple,
            size: 20,
          ),
        ),
        title: Text(
          d.name,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: Text(
          hint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        trailing: p2pMsgs.isNotEmpty
            ? Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  '${p2pMsgs.length}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              )
            : null,
        onTap: () => _enterChat(ChatTarget.device(d)),
      ),
    );
  }

  // ----------------------------------------------------------- 导航

  void _enterChat(ChatTarget target) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LanChatPage(target: target),
      ),
    );
  }

  // ----------------------------------------------------------- 交互

  Future<void> _scan() async {
    _toast('正在扫描本网段…');
    final result = await manager.scanDevices();
    if (!mounted) return;
    _toast(result.detail);
  }

  Future<void> _editName() async {
    final ctl = TextEditingController(text: manager.selfName);
    final v = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('我在局域网中的名字'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(
            hintText: '如：我的手机',
            helperText: '其他设备将看到这个名字',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(d, ctl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (v != null && v.isNotEmpty) await manager.setSelfName(v);
  }

  Future<void> _joinChannelDialog() async {
    final nameCtl = TextEditingController();
    final pwdCtl = TextEditingController();
    var private = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (_, setLocal) => AlertDialog(
          title: const Text('加入 / 创建频道'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                autofocus: true,
                maxLength: 20,
                decoration: const InputDecoration(
                  labelText: '频道名称',
                  hintText: '如：项目组',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: private,
                title: const Text('私有频道', style: TextStyle(fontSize: 14)),
                subtitle: const Text('需密码才能加入，内容加扰传输',
                    style: TextStyle(fontSize: 11)),
                onChanged: (v) => setLocal(() => private = v),
              ),
              if (private)
                TextField(
                  controller: pwdCtl,
                  decoration: const InputDecoration(labelText: '频道密码'),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('加入'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final name = nameCtl.text.trim();
    if (name.isEmpty) return;
    final pwd = private ? pwdCtl.text : '';
    if (private && pwd.isEmpty) {
      _toast('私有频道必须设置密码');
      return;
    }
    await manager.joinChannel(name, pwd);
    if (!mounted) return;
    // 加入后直接进入该频道的聊天页
    _enterChat(ChatTarget.channel(name));
  }

  Future<void> _confirmLeave(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('退出频道「$name」'),
        content: const Text('退出后将不再接收该频道的消息，已收到的内容会保留。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('退出')),
        ],
      ),
    );
    if (ok != true) return;
    await manager.leaveChannel(name);
  }

  Future<void> _addDeviceManually() async {
    final ctl = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('手动添加设备'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '对方 IP 地址',
            hintText: '如 192.168.1.23',
            helperText: '在路由器禁用广播时可直接指定对方地址',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(d, ctl.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (ip == null || ip.isEmpty) return;
    _toast('正在连接 $ip …');
    final name = await manager.addDeviceManually(ip);
    if (!mounted) return;
    _toast(name != null ? '已添加设备：$name' : '无法连接 $ip，请确认对方已打开快传');
  }

  void _confirmClearAll() {
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('清空全部消息'),
        content: const Text('将删除所有频道和点对点的聊天记录，此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(d);
              manager.clearMessages();
              _toast('已清空');
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  void _showQrForChannel(String channel) {
    final url = manager.urlForChannel(channel);
    showDialog(
      context: context,
      builder: (_) => ChannelQrDialog(
        url: url,
        channel: channel,
        isPrivate: (manager.channelPassword(channel) ?? '').isNotEmpty,
      ),
    );
  }

  void _showHelp() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.72,
        maxChildSize: 0.92,
        expand: false,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text('快传使用说明',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 14),
            _helpTile(Icons.tag, '频道管理',
                '在频道列表中点击某个频道即可进入聊天。点击频道右侧的二维码图标可展示该频道的二维码。长按频道可退出（公共频道除外）。点击右下角按钮可创建或加入新频道。'),
            _helpTile(Icons.qr_code_2, '每个频道一个二维码',
                '频道卡片上的二维码图标生成的是该频道专属链接；对方扫码后用浏览器打开，若为私有频道需输入密码才能加入。二维码可保存为图片分享。'),
            _helpTile(Icons.smartphone, '点对点直发',
                '在设备列表中点击某台已发现的设备，即可只与它单独收发，不经过频道。'),
            _helpTile(Icons.wifi_find, '搜不到设备怎么办',
                '先确认双方连同一 WiFi 且都打开了快传页。若仍看不到，点右上放大镜「扫描」主动探测整个网段；再不行用菜单里的「手动添加设备」直接填对方 IP。'),
            _helpTile(Icons.folder_open, '收到的文件在哪',
                '自动保存到应用文档目录 EverLink/Received/，在聊天页点击文件卡片可查看并复制完整路径。'),
            _helpTile(Icons.security, '注意事项',
                'iOS 首次会请求「本地网络」权限，请允许；部分路由器开启了 AP 隔离会导致设备互不可见，需在路由器中关闭。'),
          ],
        ),
      ),
    );
  }

  Widget _helpTile(IconData icon, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.teal, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 3),
                Text(body,
                    style: const TextStyle(fontSize: 13, color: Colors.grey)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 通用分区组件：标题 + 子项列表。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.count,
    required this.children,
  });

  final String title;
  final IconData icon;
  final int count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Row(
            children: [
              Icon(icon, size: 16, color: Colors.grey[600]),
              const SizedBox(width: 6),
              Text(
                '$title ($count)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[700],
                ),
              ),
            ],
          ),
        ),
        ...children,
      ],
    );
  }
}

/// 网络信息行：标签 + 值。
class _NetRow {
  final String label;
  final String value;
  const _NetRow(this.label, this.value);
}
