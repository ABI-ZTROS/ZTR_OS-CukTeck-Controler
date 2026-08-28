import 'constants.dart';
import '../ble/port_stream.dart';
import '../utils/logger/logger.dart';

/// 端口类型
enum PortType {
  c1C2, // C1/C2: Type-C 全系列 PD
  c3,   // C3: 混合口 PD+QC
  a,    // A 口: USB-A+QC
}

/// 原始端口数据
class RawPortData {
  const RawPortData({
    required this.statusRaw,
    required this.code,
    required this.currentRaw,
    required this.voltageRaw,
  });
  final int statusRaw;
  final int code;
  final int currentRaw;
  final int voltageRaw;

  bool get inUse => statusRaw != 0;
  double get current => currentRaw / 10.0; // mA → A
  double get voltage => voltageRaw / 10.0; // 10mV → V
  double get power => double.parse((voltage * current).toStringAsFixed(1));

  /// 从 MiOT 属性 payload（plaintext）解析
  static RawPortData? fromPayload(List<int> payload) {
    if (payload.length < 12) return null;
    // 最后 4 字节: [status, code, current, voltage]
    final b = payload.sublist(payload.length - 4);
    return RawPortData(
      statusRaw: b[0],
      code: b[1],
      currentRaw: b[2],
      voltageRaw: b[3],
    );
  }
}

/// 米家协议号 → 协议名
const Map<int, String> mijiaProtocols = <int, String>{
  0: 'idle', 1: '5V', 2: '5V', 3: 'QC', 4: 'AFC',
  5: 'FCP', 6: 'SCP', 7: 'PD', 8: 'PPS', 9: 'PPS', 10: 'UFCS',
};

String getMijiaProtocolName(int protoNum) =>
    mijiaProtocols[protoNum] ?? 'Unknown (0x${protoNum.toRadixString(16)})';

/// 协议号估算
int estimateProtocolNumber(int piid, RawPortData raw) {
  final voltage = raw.voltage;
  final code = raw.code;

  // 未使用或 code=0 → idle
  if (!raw.inUse || code == 0) return 0;

  // 按电压档位估算
  // PD 固定档位
  const pdFixed = <double>[5.0, 9.0, 12.0, 15.0, 20.0];
  const qcVoltages = <double>[5.0, 9.0, 12.0, 20.0];

  if (piid == 4) {
    // A 口
    if (voltage <= 5.5) return 1; // 5V
    if (voltage <= 12.5) return 3; // QC
    return 3;
  }

  // C 口（C1/C2/C3）
  if (voltage <= 5.5) return 1; // 5V
  if (voltage <= 9.5) return 5; // FCP
  if (voltage <= 12.5) {
    // QC 或 PPS
    if (code >= 3 && code <= 5) return 3; // QC
    return 8; // PPS
  }
  if (voltage <= 15.5) return 7; // PD Fixed
  if (voltage <= 20.5) return 7; // PD
  return 10; // UFCS

  // 未覆盖到的情况默认 idle
}

/// 端口解码器
class PortDecoder {
  PortDecoder._();
  static final PortDecoder instance = PortDecoder._();

  /// 端口类型
  static PortType getPortType(int piid) {
    if (piid == 1 || piid == 2) return PortType.c1C2;
    if (piid == 3) return PortType.c3;
    if (piid == 4) return PortType.a;
    throw ArgumentError('Invalid PIID: $piid');
  }

  /// 解码端口 TLV 推送数据
  ///
  /// [piid] 端口 PIID (1-4)
  /// [payload] MiOT plaintext payload（已解密）
  /// 发布 PortState 到 [PortStreamController]
  static PortState? decode(int piid, List<int> payload) {
    final raw = RawPortData.fromPayload(payload);
    if (raw == null) return null;

    final protoNum = estimateProtocolNumber(piid, raw);
    final state = PortState(
      piid: piid,
      voltage: raw.voltage,
      current: raw.current,
      power: raw.power,
      protocol: getMijiaProtocolName(protoNum),
      active: raw.inUse,
    );

    PortStreamController.instance.publish(state);
    AppLogger.instance.d(
      'PortDecoder',
      'Port $piid: ${state.voltage.toStringAsFixed(1)}V ${state.current.toStringAsFixed(1)}A ${state.power.toStringAsFixed(1)}W ${state.protocol}',
    );
    return state;
  }

  /// 从解析好的 TLV map（包含 B4=0x02 推送）批量解码
  static void dispatchFromTlvMap(Map<String, dynamic> tlv) {
    final int? b4 = tlv['opcode'] as int?;
    final int? siid = tlv['siid'] as int?;
    final int? piid = tlv['piid'] as int?;
    final List<int>? frame = tlv['frame'] as List<int>?;

    if (b4 != 0x02 || siid != 2 || piid == null || frame == null) return;
    if (piid < 1 || piid > 4) return;

    // frame 结构: [tot_len][0x20][seq][0][opcode=02][cnt=1][siid=2][piid_lo][piid_hi][tl_lo][tl_hi][value...]
    // payload = frame.sublist(11 + tl)
    final int tl = (frame[9]) | (frame[10] << 8);
    final int valueLen = tl & 0xFFF;
    // 跳过 value 的前几个字节（type+len），获取原始 payload
    final payloadStart = 11 + 2; // type_id(1) + len(1)
    if (frame.length >= payloadStart + valueLen) {
      final payload = frame.sublist(payloadStart, payloadStart + valueLen);
      decode(piid, payload);
    }
  }
}