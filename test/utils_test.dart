// 纯函数单元测试：进制/补码/字节视图/CRC16/IP 子网计算。
// 这些函数已从 UI 页面抽取到 lib/utils/*，此处独立验证其行为。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:everlink/utils/byte_codec.dart';
import 'package:everlink/utils/number_codec.dart';
import 'package:everlink/utils/ip_calc.dart';

void main() {
  group('byte_codec - CRC16-Modbus', () {
    test('标准向量 01 03 00 00 00 01 -> 0x0A84 (LE: 84 0A)', () {
      final v = crc16Modbus(Uint8List.fromList([0x01, 0x03, 0x00, 0x00, 0x00, 0x01]));
      expect(v, 0x0A84);
      expect(v & 0xFF, 0x84); // 低字节在前
      expect((v >> 8) & 0xFF, 0x0A); // 高字节在后
    });

    test('标准向量 01 03 00 6B 00 03 -> 0x1774', () {
      final v = crc16Modbus(Uint8List.fromList([0x01, 0x03, 0x00, 0x6B, 0x00, 0x03]));
      expect(v, 0x1774);
    });

    test('CRC 对字节顺序敏感', () {
      final a = crc16Modbus(Uint8List.fromList([0x01, 0x02, 0x03]));
      final b = crc16Modbus(Uint8List.fromList([0x03, 0x02, 0x01]));
      expect(a, isNot(b));
    });

    test('单字节 crc16Modbus(0x00) == 0x40BF（已知参考值）', () {
      expect(crc16Modbus(Uint8List.fromList([0x00])), 0x40BF);
    });
  });

  group('byte_codec - appendChecksum', () {
    test('crc16 模式在尾部追加 2 字节（低字节在前）', () {
      final out = appendChecksum(Uint8List.fromList([0x01, 0x03, 0x00, 0x00, 0x00, 0x01]), 'crc16');
      expect(out, [0x01, 0x03, 0x00, 0x00, 0x00, 0x01, 0x84, 0x0A]);
    });

    test('sum 模式追加累加和', () {
      final out = appendChecksum(Uint8List.fromList([0x01, 0x02, 0x03]), 'sum');
      expect(out, [0x01, 0x02, 0x03, 0x06]);
    });

    test('xor 模式追加异或', () {
      final out = appendChecksum(Uint8List.fromList([0xFF, 0x0F, 0xF0]), 'xor');
      expect(out, [0xFF, 0x0F, 0xF0, 0x00]);
    });

    test('none 模式原样返回', () {
      final data = Uint8List.fromList([0x01, 0x02]);
      expect(appendChecksum(data, 'none'), data);
    });
  });

  group('byte_codec - hex 解析/格式化', () {
    test('parseHex 正常解析', () {
      expect(parseHex('010203'), [0x01, 0x02, 0x03]);
      expect(parseHex('FF 0a'), [0xFF, 0x0A]); // 忽略空格
      expect(parseHex('0x0102'), [0x01, 0x02]);
    });

    test('parseHex 非法输入返回 null', () {
      expect(parseHex(''), isNull); // 空
      expect(parseHex('0'), isNull); // 奇数位
      expect(parseHex('ZZ'), isNull); // 非十六进制
    });

    test('hexString 与 parseHex 互为逆', () {
      final bytes = Uint8List.fromList([0, 1, 15, 255, 16, 128]);
      expect(parseHex(hexString(bytes)), bytes);
    });

    test('hexString 大写两位 + 分隔符', () {
      expect(hexString(Uint8List.fromList([0x0a, 0xff]), sep: ''), '0AFF');
      expect(hexString(Uint8List.fromList([0x0a, 0xff])), '0A FF');
    });
  });

  group('number_codec - parseRadix', () {
    test('十进制与负号', () {
      expect(parseRadix('255', 10), BigInt.from(255));
      expect(parseRadix('-10', 10), BigInt.from(-10));
      expect(parseRadix('', 10), BigInt.zero); // 空串视为 0
    });

    test('十六/八/二进制自动识别前缀', () {
      expect(parseRadix('0xFF', 16), BigInt.from(255));
      expect(parseRadix('0o17', 8), BigInt.from(15));
      expect(parseRadix('0b1010', 2), BigInt.from(10));
    });

    test('非法输入返回 null', () {
      expect(parseRadix('zz', 16), isNull);
      expect(parseRadix('12', 2), isNull); // 二进制含 2
      expect(parseRadix('0xZZ', 16), isNull);
    });
  });

  group('number_codec - 补码互转', () {
    test('toUnsigned：有符号 -> 指定位宽无符号', () {
      expect(toUnsigned(BigInt.from(-1), 8), BigInt.from(255));
      expect(toUnsigned(BigInt.from(-128), 8), BigInt.from(128));
      expect(toUnsigned(BigInt.from(255), 8), BigInt.from(255));
      expect(toUnsigned(BigInt.from(0), 16), BigInt.zero);
    });

    test('toSigned：无符号 -> 有符号', () {
      expect(toSigned(BigInt.from(255), 8), BigInt.from(-1));
      expect(toSigned(BigInt.from(128), 8), BigInt.from(-128));
      expect(toSigned(BigInt.from(127), 8), BigInt.from(127));
      expect(toSigned(BigInt.from(0), 8), BigInt.zero);
    });

    test('round-trip：-1 在 16 位下可还原', () {
      final u = toUnsigned(BigInt.from(-1), 16);
      expect(u, BigInt.from(65535));
      expect(toSigned(u, 16), BigInt.from(-1));
    });
  });

  group('ip_calc - IP 解析', () {
    test('合法 IPv4', () {
      expect(parseIp('192.168.1.1'), [192, 168, 1, 1]);
      expect(parseIp('255.255.255.0'), [255, 255, 255, 0]);
      expect(parseIp('0.0.0.0'), [0, 0, 0, 0]);
      expect(parseIp(' 8.8.8.8 '), [8, 8, 8, 8]); // 允许首尾空白
    });

    test('非法 IPv4 返回 null', () {
      expect(parseIp('1.2.3'), isNull); // 段数不足
      expect(parseIp('1.2.3.4.5'), isNull); // 段数过多
      expect(parseIp('256.0.0.1'), isNull); // 超范围
      expect(parseIp('-1.0.0.1'), isNull); // 负数
      expect(parseIp('a.b.c.d'), isNull); // 非数字
    });
  });

  group('ip_calc - ipToInt / intToIp', () {
    test('转换与逆转换', () {
      expect(ipToInt([192, 168, 1, 1]), (192 << 24) | (168 << 16) | (1 << 8) | 1);
      expect(intToIp((192 << 24) | (168 << 16) | (1 << 8) | 1), '192.168.1.1');
    });

    test('边界地址往返一致', () {
      for (final ip in ['0.0.0.0', '255.255.255.255', '10.0.0.0', '127.0.0.1']) {
        final bytes = parseIp(ip)!;
        expect(intToIp(ipToInt(bytes)), ip);
      }
    });
  });

  group('ip_calc - maskToPrefix', () {
    test('连续掩码正确', () {
      expect(maskToPrefix([255, 255, 255, 0]), 24);
      expect(maskToPrefix([255, 255, 0, 0]), 16);
      expect(maskToPrefix([255, 255, 255, 255]), 32);
      expect(maskToPrefix([0, 0, 0, 0]), 0);
    });

    test('非连续掩码抛 FormatException', () {
      expect(() => maskToPrefix([255, 0, 255, 0]), throwsA(isA<FormatException>()));
      expect(() => maskToPrefix([255, 255, 0, 255]), throwsA(isA<FormatException>()));
    });
  });
}
