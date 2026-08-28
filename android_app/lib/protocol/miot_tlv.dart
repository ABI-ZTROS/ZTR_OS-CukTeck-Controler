import 'dart:typed_data';

/// MiOT TLV 编码/解码
///
/// 参考: kairui1108/cuktech-ble-ha/src/cuktech_ble/controller.py
///       _build_miot_tlv / send_miot_command / _recv_set_response / _recv_get_response
class MiotTlv {
  MiotTlv._();

  /// 构建 SET 命令 TLV
  ///
  /// [seq] 序列号（1 字节，自动回绕）
  /// [siid] 服务 ID（充电器固定为 2）
  /// [piid] 属性 ID
  /// [value] 要设置的值；null 时为 GET 命令
  static Uint8List build(int seq, int siid, int piid, {int? value}) {
    final bool isSet = value != null;
    final int opcode = isSet ? 0x00 : 0x02;

    late int typeId;
    late Uint8List valueBytes;
    if (isSet) {
      if (value! <= 0xFF) {
        typeId = 1; // UINT8
        valueBytes = Uint8List(1)..[0] = value;
      } else {
        typeId = 5; // UINT32
        valueBytes = Uint8List(4);
        // little-endian
        final int v = value;
        valueBytes[0] = v & 0xFF;
        valueBytes[1] = (v >> 8) & 0xFF;
        valueBytes[2] = (v >> 16) & 0xFF;
        valueBytes[3] = (v >> 24) & 0xFF;
      }
    } else {
      typeId = 1;
      valueBytes = Uint8List(1)..[0] = 0;
    }

    final int byteLen = valueBytes.length;
    final int tl = (typeId << 12) | byteLen;
    final int totalLen = 11 + byteLen;

    final Uint8List frame = Uint8List(totalLen);
    frame[0] = totalLen & 0xFF;
    frame[1] = 0x20;
    frame[2] = seq & 0xFF;
    frame[3] = 0x00;
    frame[4] = opcode;
    frame[5] = 0x01; // cnt
    frame[6] = siid & 0xFF;
    frame[7] = piid & 0xFF;
    frame[8] = (piid >> 8) & 0xFF;
    frame[9] = tl & 0xFF;
    frame[10] = (tl >> 8) & 0xFF;
    for (int i = 0; i < byteLen; i++) {
      frame[11 + i] = valueBytes[i];
    }
    return frame;
  }

  /// 解析响应帧（已解密的 plaintext）
  ///
  /// 返回 Map 包含：opcode(B4)、siid、piid、value、frame
  static Map<String, dynamic>? parse(Uint8List pt) {
    if (pt.length < 8) return null;
    final int b4 = pt[4];
    final int siid = pt[6];
    final int piid = pt[7];

    int? value;
    if (pt.length >= 12) {
      final int vlen = pt[11];
      if (vlen >= 4 && pt.length >= 15) {
        value = pt[11] |
            (pt[12] << 8) |
            (pt[13] << 16) |
            (pt[14] << 24);
      } else if (pt.length > 13) {
        value = pt[13];
      }
    }

    return <String, dynamic>{
      'opcode': b4,
      'siid': siid,
      'piid': piid,
      'value': value,
      'frame': pt,
    };
  }

  /// 响应 opcode 常量
  static const int opSetAck   = 0x01; // SET ACK
  static const int opSetRes  = 0x04; // SET Result
  static const int opGetRes  = 0x03; // GET Result
  static const int opPortPush = 0x02; // 端口数据推送
}