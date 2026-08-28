import '../ble/encrypted_channel.dart';
import '../ble/android_connector.dart';
import '../utils/logger/logger.dart';
import 'constants.dart';

/// 单口控制（PIID 16）
class PortControl {
  PortControl._();
  static final PortControl instance = PortControl._();

  final EncryptedChannel _channel = EncryptedChannel.instance;

  int _miotSeq = 1;
  int get _nextSeq {
    final s = _miotSeq;
    _miotSeq = (_miotSeq + 1) & 0xFF;
    return s;
  }

  /// 查询端口状态（当前位掩码）
  Future<int?> readState(AndroidConnector connector) async {
    final resp = await _channel.sendGet(connector, siidCharger, 16,
        seqProvider: () => _nextSeq);
    if (resp == null) return null;
    return resp['value'] as int?;
  }

  /// 设置端口位掩码
  Future<Map<String, dynamic>?> writeMask(
    AndroidConnector connector,
    int mask,
  ) async {
    return _channel.sendSet(connector, siidCharger, 16, mask,
        seqProvider: () => _nextSeq);
  }

  /// 便捷: 切换单口开关
  ///
  /// [port] 'c1'/'c2'/'c3'/'a'/'all'
  /// [on] true 开 / false 关
  Future<bool> setPort(AndroidConnector connector, String port, bool on) async {
    final current = await readState(connector);
    int mask;
    if (current == null) {
      AppLogger.instance.w('PortControl', 'Cannot read current state');
      return false;
    }
    mask = current;

    if (port == 'all') {
      mask = on ? 0x0F : 0x00;
    } else {
      final bit = portBits[port];
      if (bit == null) {
        AppLogger.instance.e('PortControl', 'Unknown port: $port');
        return false;
      }
      if (on) {
        mask = mask | (1 << bit);
      } else {
        mask = mask & ~(1 << bit);
      }
    }

    if (mask == current) {
      AppLogger.instance.i('PortControl', 'Port $port already ${on ? 'on' : 'off'}');
      return true;
    }

    final resp = await writeMask(connector, mask);
    if (resp == null) {
      AppLogger.instance.e('PortControl', 'Write failed');
      return false;
    }

    // 回读验证
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final readBack = await readState(connector);
    final ok = readBack == mask;
    AppLogger.instance.i(
      'PortControl',
      'Set $port=${on ? 'on' : 'off'} -> mask=$mask readBack=$readBack OK=$ok',
    );
    return ok;
  }
}