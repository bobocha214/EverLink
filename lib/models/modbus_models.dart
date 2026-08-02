/// Modbus 功能码（常用子集）。
enum ModbusFunction {
  readCoils(0x01, '读线圈', true, false),
  readDiscreteInputs(0x02, '读离散输入', true, false),
  readHoldingRegisters(0x03, '读保持寄存器', true, false),
  readInputRegisters(0x04, '读输入寄存器', true, false),
  writeSingleCoil(0x05, '写单个线圈', false, true),
  writeSingleRegister(0x06, '写单个保持寄存器', false, true),
  writeMultipleCoils(0x0F, '写多个线圈', false, true),
  writeMultipleRegisters(0x10, '写多个保持寄存器', false, true);

  const ModbusFunction(
    this.code,
    this.label,
    this.canRead,
    this.canWrite,
  );

  final int code;
  final String label;
  final bool canRead;
  final bool canWrite;
}

/// 寄存器数据类型，用于把连续的 16 位寄存器组合成更高精度的值。
enum ModbusDataType {
  uint16('Uint16', 1),
  int16('Int16', 1),
  uint32('Uint32', 2),
  int32('Int32', 2),
  float32('Float32', 2);

  const ModbusDataType(this.label, this.registerCount);

  final String label;

  /// 该类型占用的寄存器数量。
  final int registerCount;

  /// 是否占用多个寄存器（32 位 / 浮点需要 2 个寄存器）。
  bool get isMultiRegister => registerCount > 1;

  /// 是否为浮点类型（值以 double 表示）。
  bool get isFloat => this == ModbusDataType.float32;
}

/// 字节序（用于多寄存器数据解析）。
enum ByteOrder {
  abcd('ABCD（大端）'),
  cdab('CDAB'),
  badc('BADC'),
  dcba('DCBA（小端）');

  const ByteOrder(this.label);

  final String label;
}
