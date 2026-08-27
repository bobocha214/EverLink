/// IPv4 子网计算的纯函数，从 [network_debug_page] 抽取以便单元测试与复用。
///
/// 所有函数为纯函数，不依赖 Flutter / 上下文，便于独立测试。
library;

/// 解析点分十进制 IP（a.b.c.d，每段 0-255），非法返回 null。
List<int>? parseIp(String s) {
  final parts = s.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p.trim());
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}

/// 4 字节列表 → 32 位整数。
int ipToInt(List<int> b) => (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];

/// 32 位整数 → 点分十进制 IP。
String intToIp(int v) =>
    '${(v >> 24) & 0xFF}.${(v >> 16) & 0xFF}.${(v >> 8) & 0xFF}.${v & 0xFF}';

/// 子网掩码（4 字节）→ CIDR 前缀长度。
///
/// 掩码必须连续（如 255.255.255.0），否则抛 [FormatException]。
int maskToPrefix(List<int> mask) {
  final v = ipToInt(mask);
  int bits = 0;
  int t = v;
  while (t > 0) {
    bits += t & 1;
    t >>= 1;
  }
  final expected = ((BigInt.one << bits) - BigInt.one) << (32 - bits);
  if ((BigInt.from(v) & BigInt.from(0xFFFFFFFF)) !=
      (expected & BigInt.from(0xFFFFFFFF))) {
    throw const FormatException('子网掩码不连续');
  }
  return bits;
}
