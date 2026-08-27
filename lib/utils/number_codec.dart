/// 进制转换与补码相关的纯函数，从 [base_tool_page] 抽取以便单元测试与复用。
///
/// 所有函数为纯函数，不依赖 Flutter / 上下文，便于独立测试。
library;

/// 按指定进制解析字符串为 [BigInt]，失败返回 null。
///
/// 自动识别 0x / 0o / 0b 前缀；十进制支持负号；空串视为 0。
BigInt? parseRadix(String s, int radix) {
  var t = s.trim();
  if (t.isEmpty) return BigInt.zero;
  if (radix == 16 && t.toLowerCase().startsWith('0x')) t = t.substring(2);
  if (radix == 8 && t.toLowerCase().startsWith('0o')) t = t.substring(2);
  if (radix == 2 && t.toLowerCase().startsWith('0b')) t = t.substring(2);
  if (t.isEmpty) return BigInt.zero;
  try {
    return BigInt.parse(t, radix: radix);
  } on FormatException {
    return null;
  }
}

/// 有符号值 → 指定位宽的补码无符号表示（大整数模 2^width）。
BigInt toUnsigned(BigInt signed, int width) {
  final modulus = BigInt.one << width;
  BigInt u = signed % modulus;
  if (u < BigInt.zero) u += modulus;
  return u;
}

/// 指定位宽的补码无符号表示 → 有符号值。
BigInt toSigned(BigInt u, int width) {
  final modulus = BigInt.one << width;
  final half = BigInt.one << (width - 1);
  return u >= half ? u - modulus : u;
}
