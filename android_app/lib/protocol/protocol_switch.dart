import '../ble/encrypted_channel.dart';
import '../ble/android_connector.dart';
import '../utils/logger/logger.dart';
import 'constants.dart';

/// 协议开关（PIID 21）
class ProtocolSwitch {
  ProtocolSwitch._();
  static final ProtocolSwitch instance = ProtocolSwitch._();

  final EncryptedChannel _channel = EncryptedChannel.instance;
  int _miotSeq = 1;
  int get _nextSeq {
    final s = _miotSeq;
    _miotSeq = (_miotSeq + 1) & 0xFF;
    return s;
  }

  /// 按端口查询协议开关状态（从 PIID 21 原始值解析）
  Map<String, Map<String, bool>> parse(int rawValue) {
    final result = <String, Map<String, bool>>{};
    for (final port in const ['c1', 'c2', 'c3', 'a']) {
      final bits = protocolSwitchBits[port]!;
      final map = <String, bool>{};
      for (final entry in bits.entries) {
        map[entry.key] = (rawValue & (1 << entry.value)) != 0;
      }
      result[port] = map;
    }
    return result;
  }

  /// 按端口+协议开关生成 PIID 21 原始值
  int encode(Map<String, Map<String, bool>> switches) {
    int v = 0;
    for (final port in const ['c1', 'c2', 'c3', 'a']) {
      final portSwitches = switches[port] ?? const <String, bool>{};
      final bits = protocolSwitchBits[port]!;
      for (final entry in bits.entries) {
        if (portSwitches[entry.key] == true) {
          v |= (1 << entry.value);
        }
      }
      // c1/c2 的 reserved 位保持为 1 (c1: bit3, c2: bit11)
      if (port == 'c1' || port == 'c2') {
        final reservedBit = bits['_reserved'] ?? 3;
        v |= (1 << reservedBit);
      }
    }
    return v;
  }

  /// 读取当前 PIID 21 值
  Future<int?> read(AndroidConnector connector) async {
    final resp = await _channel.sendGet(connector, siidCharger, 21,
        seqProvider: () => _nextSeq);
    if (resp == null) return null;
    return resp['value'] as int?;
  }

  /// 写入 PIID 21 值
  Future<bool> write(AndroidConnector connector, int value) async {
    final resp = await _channel.sendSet(connector, siidCharger, 21, value,
        seqProvider: () => _nextSeq);
    if (resp == null) return false;
    // 回读验证
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final readBack = await read(connector);
    final ok = readBack == value;
    AppLogger.instance.i('ProtocolSwitch', 'Write $value -> readBack=$readBack OK=$ok');
    return ok;
  }

  /// 便捷: 设置某端口某协议开关
  Future<bool> setProtocol(
    AndroidConnector connector,
    String port,
    String protocol,
    bool enabled,
  ) async {
    final current = await read(connector);
    if (current == null) {
      AppLogger.instance.w('ProtocolSwitch', 'Cannot read current state');
      return false;
    }
    final switches = parse(current);
    switches.putIfAbsent(port, () => <String, bool>{});
    switches[port]![protocol] = enabled;
    final next = encode(switches);
    return write(connector, next);
  }
}