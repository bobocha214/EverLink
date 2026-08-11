import 'dart:io';

import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';

/// 共享网络信息服务：收集本机所有局域网 IP、连接类型、WiFi 详情等。
///
/// 设计目标：
/// - **IP 正确性**：优先使用 [NetworkInfo.getWifiIP] 拿到 WiFi 真实 IP 作为主地址，
///   避免把移动数据 / VPN 的 IP 误当成"局域网地址"展示给同网段设备。
/// - **连接类型区分**：明确区分「WiFi / 移动数据 / 以太网 / 无网络」，
///   让用户在快传、剪贴板、网络信息页都能一眼看出当前走的是哪条链路。
/// - **单一数据源**：快传、剪贴板、网络信息工具页共用，避免各处重复且不一致的逻辑。
class NetworkInfoService {
  NetworkInfoService._();
  static final NetworkInfoService instance = NetworkInfoService._();

  static const MethodChannel _nativeChannel = MethodChannel('everlink/lan');

  // 定位权限只需在 Android 10–12 申请一次（这些版本读 SSID 需要它）；
  // Android 13+ 靠 NEARBY_WIFI_DEVICES 即可，无需定位。
  static bool _askedLocationPermission = false;
  static int _cachedSdkInt = 0;

  /// 收集一次完整网络信息。非阻塞，异常时降级返回最小可用结果。
  Future<NetInfo> collect({int port = 0}) async {
    final addresses = <NetAddress>[];

    // 1) 枚举所有 IPv4 接口（不含回环），推断每个地址的接口类型。
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final a = addr.address;
          if (a.startsWith('169.254.')) continue; // 链路本地地址，跨设备不可达
          addresses.add(NetAddress(
            ip: a,
            interface: iface.name,
            type: _inferType(iface.name, a),
          ));
        }
      }
    } catch (_) {
      // 枚举失败就不展示地址列表，后续降级处理
    }

    // 2) WiFi 检测：network_info_plus 的 getWifiIP 在连接 WiFi 时返回真实 IP，
    //    未连 WiFi 时返回 "0.0.0.0" 或抛错。用它判断当前是否走 WiFi 且拿到主 IP。
    String? wifiIp;
    try {
      wifiIp = await NetworkInfo().getWifiIP();
      if (wifiIp == null ||
          wifiIp.isEmpty ||
          wifiIp.startsWith('0.0.0.0') ||
          wifiIp.startsWith('127.')) {
        wifiIp = null;
      }
    } catch (_) {
      wifiIp = null;
    }

    // 3) 判定连接类型与主地址。
    final connectionType = _resolveConnectionType(addresses, wifiIp);
    String primaryIp;
    switch (connectionType) {
      case 'WiFi':
        primaryIp = wifiIp!;
      case '移动数据':
      case '以太网':
        primaryIp = addresses
                .firstWhere((a) => a.type == connectionType,
                    orElse: () => addresses.first)
                .ip;
      case '无网络':
        primaryIp = '127.0.0.1';
      default:
        primaryIp = addresses.isNotEmpty ? addresses.first.ip : '127.0.0.1';
    }

    // 标记主地址并排序（主地址在前，再按类型权重）。
    for (final a in addresses) {
      a.primary = a.ip == primaryIp;
    }
    addresses.sort((a, b) {
      if (a.primary) return -1;
      if (b.primary) return 1;
      return _typeWeight(b.type) - _typeWeight(a.type);
    });

    // 4) WiFi 详情（SSID / 网关 / 子网 / 信号），仅在 WiFi 下有意义。
    String? wifiName;
    String? wifiBssid;
    String? gateway;
    String? subnetMask;
    int? signalRssi;
    int? signalLevel;
    String? signalDescription;
    if (connectionType == 'WiFi') {
      // 优先原生 MethodChannel（比插件可靠），空了再让插件兜底。
      try {
        final wifi = await _nativeChannel.invokeMethod<Map>('getWifiInfo');
        if (wifi != null) {
          final ssid = (wifi['ssid'] as String?) ?? '';
          if (ssid.isNotEmpty) wifiName = ssid;
          final bssid = (wifi['bssid'] as String?) ?? '';
          if (bssid.isNotEmpty) wifiBssid = bssid;
          final gw = (wifi['gateway'] as String?) ?? '';
          if (gw.isNotEmpty && gw != '0.0.0.0') gateway = gw;
          final sm = (wifi['subnetMask'] as String?) ?? '';
          if (sm.isNotEmpty && sm != '0.0.0.0') subnetMask = sm;
          final rssi = wifi['rssi'];
          if (rssi is int && rssi != 0) {
            signalRssi = rssi;
            signalLevel = wifi['level'] is int ? wifi['level'] as int : null;
            signalDescription = wifi['description'] as String?;
          }
        }
      } catch (_) {}

      // Android 10–12：NEARBY_WIFI_DEVICES 不存在，读 SSID 仍需 ACCESS_FINE_LOCATION。
      // 若 SSID 仍缺失，发起一次性授权后再拉取一次（用户拒绝则不再打扰）。
      if (wifiName == null && !_askedLocationPermission) {
        try {
          if (Platform.isAndroid) {
            final sdk = await _androidSdkInt();
            if (sdk >= 1 && sdk <= 32) {
              _askedLocationPermission = true;
              final granted = await _nativeChannel
                  .invokeMethod<bool>('requestWifiLocationPermission');
              if (granted == true) {
                final wifi2 =
                    await _nativeChannel.invokeMethod<Map>('getWifiInfo');
                if (wifi2 != null) {
                  final ssid = (wifi2['ssid'] as String?) ?? '';
                  if (ssid.isNotEmpty) wifiName = ssid;
                  final gw = (wifi2['gateway'] as String?) ?? '';
                  if (gw.isNotEmpty && gw != '0.0.0.0') gateway ??= gw;
                  final sm = (wifi2['subnetMask'] as String?) ?? '';
                  if (sm.isNotEmpty && sm != '0.0.0.0') subnetMask ??= sm;
                }
              }
            }
          }
        } catch (_) {}
      }

      // 插件兜底拿 SSID
      if (wifiName == null) {
        try {
          final ssid = await NetworkInfo().getWifiName();
          if (ssid != null && ssid.isNotEmpty && ssid != '<unknown ssid>') {
            wifiName = ssid;
          }
        } catch (_) {}
      }
    }

    // 5) DNS：当前活动网络的 DNS 服务器（任意连接类型都可取）。
    final dnsServers = <String>[];
    try {
      final dns = await _nativeChannel.invokeMethod<List>('getDnsServers');
      if (dns != null) {
        for (final d in dns) {
          final s = d.toString();
          if (s.isNotEmpty && s != '0.0.0.0' && !dnsServers.contains(s)) {
            dnsServers.add(s);
          }
        }
      }
    } catch (_) {}

    return NetInfo(
      connectionType: connectionType,
      primaryIp: primaryIp,
      wifiName: wifiName,
      wifiBssid: wifiBssid,
      gateway: gateway,
      subnetMask: subnetMask,
      dnsServers: dnsServers,
      signalRssi: signalRssi,
      signalLevel: signalLevel,
      signalDescription: signalDescription,
      addresses: addresses,
    );
  }

  /// 读取 Android 系统版本号（仅 Android 有效，其余平台返回 0）。
  Future<int> _androidSdkInt() async {
    if (_cachedSdkInt != 0) return _cachedSdkInt;
    try {
      _cachedSdkInt =
          await _nativeChannel.invokeMethod<int>('getSdkInt') ?? 0;
    } catch (_) {
      _cachedSdkInt = 0;
    }
    return _cachedSdkInt;
  }

  /// 根据接口名与 IP 推断连接类型。
  String _inferType(String name, String ip) {
    final n = name.toLowerCase();
    if (n.contains('wlan') ||
        n.contains('wifi') ||
        n.startsWith('en') && !n.startsWith('enx') && !n.startsWith('enp')) {
      return 'WiFi';
    }
    if (n.contains('eth') || n.startsWith('enx') || n.startsWith('enp')) {
      return '以太网';
    }
    if (n.startsWith('rmnet') ||
        n.startsWith('radio') ||
        n.contains('mobile') ||
        n.startsWith('ccmni')) {
      return '移动数据';
    }
    if (n.contains('tun') || n.contains('ppp') || n.contains('vpn')) {
      return 'VPN';
    }
    if (n.contains('usb') || n.contains('rndis')) {
      return 'USB 共享';
    }
    // IP 段兜底：移动数据常用 10.x
    if (ip.startsWith('10.')) return '移动数据';
    return '其它';
  }

  /// 连接类型判定：WiFi 优先；其次移动数据；再以太网；最后无网络。
  String _resolveConnectionType(List<NetAddress> addrs, String? wifiIp) {
    if (wifiIp != null) return 'WiFi';
    if (addrs.isEmpty) return '无网络';
    if (addrs.any((a) => a.type == '移动数据')) return '移动数据';
    if (addrs.any((a) => a.type == '以太网')) return '以太网';
    if (addrs.any((a) => a.type == 'WiFi')) return 'WiFi';
    if (addrs.any((a) => a.type == 'VPN')) return 'VPN';
    if (addrs.any((a) => a.type == 'USB 共享')) return 'USB 共享';
    if (addrs.any((a) => a.type == '其它')) return '其它';
    return addrs.first.type.isNotEmpty ? addrs.first.type : '其它';
  }

  int _typeWeight(String type) {
    switch (type) {
      case 'WiFi':
        return 100;
      case '以太网':
        return 80;
      case '移动数据':
        return 40;
      case 'USB 共享':
        return 20;
      case 'VPN':
        return 10;
      default:
        return 0;
    }
  }
}

/// 单个网络地址（含接口类型）。
class NetAddress {
  final String ip;
  final String interface;
  final String type;
  bool primary;

  NetAddress({
    required this.ip,
    required this.interface,
    required this.type,
    this.primary = false,
  });

  Map<String, dynamic> toMap() => {
        'ip': ip,
        'interface': interface,
        'type': type,
        'primary': primary,
      };
}

/// 一次完整的网络信息快照。
class NetInfo {
  final String connectionType; // 'WiFi' | '移动数据' | '以太网' | 'VPN' | 'USB 共享' | '其它' | '无网络'
  final String primaryIp;
  final String? wifiName;
  final String? wifiBssid;
  final String? gateway;
  final String? subnetMask;
  final List<String> dnsServers;
  final int? signalRssi;
  final int? signalLevel;
  final String? signalDescription;
  final List<NetAddress> addresses;

  NetInfo({
    required this.connectionType,
    required this.primaryIp,
    this.wifiName,
    this.wifiBssid,
    this.gateway,
    this.subnetMask,
    this.dnsServers = const [],
    this.signalRssi,
    this.signalLevel,
    this.signalDescription,
    this.addresses = const [],
  });

  /// 供 `/api/network` 与 App 面板使用的扁平 Map（含 port 与 addresses）。
  Map<String, dynamic> toInfoMap(int port) => {
        'port': port,
        'connectionType': connectionType,
        'primaryIp': primaryIp,
        'wifiName': wifiName,
        'wifiBssid': wifiBssid,
        'gateway': gateway,
        'subnetMask': subnetMask,
        'dnsServers': dnsServers,
        'signalRssi': signalRssi,
        'signalLevel': signalLevel,
        'signalDescription': signalDescription,
        'addresses': addresses.map((a) => a.toMap()).toList(),
      };

  /// 生成 5 格信号强度（0~4），供 UI 展示。
  int get signalBars {
    if (signalRssi == null || signalRssi == 0) return 0;
    if (signalRssi! >= -50) return 4;
    if (signalRssi! >= -60) return 3;
    if (signalRssi! >= -70) return 2;
    if (signalRssi! >= -80) return 1;
    return 0;
  }
}
