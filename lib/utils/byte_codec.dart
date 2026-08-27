import 'dart:typed_data';

/// 字节展示与校验相关的纯函数集合，供 TCP / Modbus / OPC UA 等
/// 收发日志与发送增强复用，保证各页面视觉与算法一致。

/// 将字节流格式化为多行 hex dump（带偏移、十六进制、右侧 ASCII 视图）。
String hexDump(Uint8List bytes) {
  final buf = StringBuffer();
  const cols = 16;
  for (var i = 0; i < bytes.length; i += cols) {
    final end = (i + cols < bytes.length) ? i + cols : bytes.length;
    final offset = i.toRadixString(16).padLeft(8, '0');
    final hex = <String>[];
    final ascii = <String>[];
    for (var j = i; j < end; j++) {
      final b = bytes[j];
      hex.add(b.toRadixString(16).padLeft(2, '0'));
      ascii.add(b >= 0x20 && b < 0x7f ? String.fromCharCode(b) : '.');
    }
    // 用空格把 hex 每 8 字节分一组，便于读数。
    final grouped = <String>[];
    for (var k = 0; k < hex.length; k += 8) {
      grouped.add(hex.skip(k).take(8).join(' '));
    }
    buf.write(
        '$offset  ${grouped.join('  ').padRight(47)}  |${ascii.join('')}|');
    if (i + cols < bytes.length) buf.write('\n');
  }
  return buf.toString();
}

/// ASCII 视图：可打印字符原样显示，不可打印以 '.' 占位。
String asciiView(Uint8List bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(b >= 0x20 && b < 0x7f ? String.fromCharCode(b) : '.');
  }
  return buf.toString();
}

/// 空格分隔的大写十六进制串（如 `30 30 20`）。
String hexString(Uint8List bytes, {String sep = ' '}) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(sep);

/// CRC16-Modbus（多项式 0x8005，初值 0xFFFF，低字节在前）。
int crc16Modbus(Uint8List data) {
  var crc = 0xFFFF;
  for (final b in data) {
    crc ^= b;
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

/// 按校验模式计算并附在报文尾部的校验字节。
///
/// [mode] 取值：`none` / `crc16` / `sum` / `xor`。
Uint8List appendChecksum(Uint8List data, String mode) {
  switch (mode) {
    case 'crc16':
      final crc = crc16Modbus(data);
      return Uint8List.fromList(data + [crc & 0xFF, (crc >> 8) & 0xFF]);
    case 'sum':
      var s = 0;
      for (final b in data) {
        s = (s + b) & 0xFF;
      }
      return Uint8List.fromList(data + [s]);
    case 'xor':
      var x = 0;
      for (final b in data) {
        x ^= b;
      }
      return Uint8List.fromList(data + [x]);
    default:
      return data;
  }
}

/// 仅计算校验字节（不拼回原数据），用于 RX 校验比对。
Uint8List computeChecksum(Uint8List data, String mode) {
  switch (mode) {
    case 'crc16':
      final crc = crc16Modbus(data);
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

/// 某校验模式占用的字节长度（none 为 0）。
int checksumLen(String mode) {
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

/// 校验模式的中文短标签（用于日志徽章）。
String checksumShortLabel(String mode) {
  switch (mode) {
    case 'crc16':
      return 'CRC16-Modbus';
    case 'sum':
      return '累加和';
    case 'xor':
      return '异或';
    default:
      return '无';
  }
}

bool bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 把十六进制文本（可含空格）解析为字节；非法返回 null。
Uint8List? parseHex(String text) {
  var cleaned = text.replaceAll(RegExp(r'\s+'), '');
  if (cleaned.toLowerCase().startsWith('0x')) cleaned = cleaned.substring(2);
  if (cleaned.isEmpty || cleaned.length % 2 != 0) return null;
  try {
    return Uint8List.fromList([
      for (var i = 0; i < cleaned.length; i += 2)
        int.parse(cleaned.substring(i, i + 2), radix: 16)
    ]);
  } on FormatException {
    return null;
  }
}
