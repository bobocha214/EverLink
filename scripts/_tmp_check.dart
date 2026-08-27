import 'dart:typed_data';
import 'package:everlink/utils/byte_codec.dart';
import 'package:everlink/utils/ip_calc.dart';

void main() {
  print("crc([0x00]) = 0x${crc16Modbus(Uint8List.fromList([0x00])).toRadixString(16)}");
  print("parseHex('0x0102') = ${parseHex('0x0102')}");
  print("maskToPrefix([255,0,255,0]) = ${maskToPrefix([255,0,255,0])}");
  try {
    print("maskToPrefix([255,255,255,254]) = ${maskToPrefix([255,255,255,254])}");
  } catch (e) {
    print("maskToPrefix([255,255,255,254]) threw $e");
  }
}
