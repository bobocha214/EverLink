import 'dart:typed_data';

import 'package:everlink/services/modbus/modbus_client.dart';

/// 把连续的 16 位寄存器值 [regs] 按 [type] 与字节序 [order] 解析为工程值。
///
/// [regs] 为寄存器原始值列表（每个 0..65535）；[start] 为起始寄存器下标，
/// [order] 控制多寄存器值的字交换与字节交换。解析失败或越界时返回 `null`。
num? parseModbusValue(
  List<int> regs,
  ModbusDataType type, {
  int start = 0,
  ModbusByteOrder order = const ModbusByteOrder(),
}) {
  final count = type.registerCount;
  if (start < 0 || start + count > regs.length) return null;

  // 取出本次参与解析的寄存器，并按字交换调整顺序。
  final words = regs.sublist(start, start + count).toList();
  if (order.wordSwap) {
    for (var i = 0; i < words.length ~/ 2; i++) {
      final j = words.length - 1 - i;
      final tmp = words[i];
      words[i] = words[j];
      words[j] = tmp;
    }
  }

  // 展开为字节流（每个寄存器大端两个字节），再按字节交换调整。
  final bytes = <int>[];
  for (final w in words) {
    bytes.add((w >> 8) & 0xFF);
    bytes.add(w & 0xFF);
  }
  if (order.byteSwap) {
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final tmp = bytes[i];
      bytes[i] = bytes[i + 1];
      bytes[i + 1] = tmp;
    }
  }

  final bd = ByteData.sublistView(Uint8List.fromList(bytes));
  switch (type) {
    case ModbusDataType.bool8:
      return (regs[start] & 0xFF) != 0 ? 1 : 0;
    case ModbusDataType.int16:
      return bd.getInt16(0);
    case ModbusDataType.uint16:
      return bd.getUint16(0);
    case ModbusDataType.int32:
      return bd.getInt32(0);
    case ModbusDataType.uint32:
      return bd.getUint32(0);
    case ModbusDataType.float32:
      return bd.getFloat32(0);
    case ModbusDataType.int64:
      return bd.getInt64(0);
    case ModbusDataType.uint64:
      return bd.getUint64(0);
    case ModbusDataType.double64:
      return bd.getFloat64(0);
  }
}
