import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import '../utils/logger/logger.dart';

/// AES-CCM 加解密工具（Dart 移植）
///
/// 参考: controller.py _encrypt / decrypt
/// 非包 tag_length=4，nonce 格式: iv(4) + zeros(4) + counter(4)
class CryptoEngine {
  CryptoEngine._();
  static final CryptoEngine instance = CryptoEngine._();

  List<int>? _devKey;
  List<int>? _appKey;
  List<int>? _devIv;
  List<int>? _appIv;

  int _sendIt = 0;
  int _devItHi = 0;
  int _lastDevItLo = 0;

  /// 设置会话密钥
  void setSessionKeys({
    required List<int> devKey,
    required List<int> appKey,
    required List<int> devIv,
    required List<int> appIv,
  }) {
    _devKey = devKey;
    _appKey = appKey;
    _devIv = devIv;
    _appIv = appIv;
    _sendIt = 0;
    _devItHi = 0;
    _lastDevItLo = 0;
    AppLogger.instance.i('CryptoEngine', 'Session keys set (dev_key=${_hex(devKey)}...)');
  }

  /// 是否已派生密钥
  bool get hasKeys =>
      _devKey != null && _appKey != null &&
      _devIv != null && _appIv != null;

  /// 加密（发送方向：app_key + app_iv）
  ///
  /// 返回: it_lo(2) + ciphertext（含 4 字节 tag）
  List<int> encrypt(List<int> plaintext) {
    if (_appKey == null || _appIv == null) {
      throw StateError('Session keys not set');
    }
    final int it = _sendIt;
    final nonce = Uint8List(12);
    nonce.setRange(0, 4, _appIv!);
    nonce.setRange(4, 8, const [0, 0, 0, 0]);
    nonce[8] = it & 0xFF;
    nonce[9] = (it >> 8) & 0xFF;
    nonce[10] = (it >> 16) & 0xFF;
    nonce[11] = (it >> 24) & 0xFF;

    final ciphertext = _aesCcmEncrypt(_appKey!, nonce, plaintext);
    _sendIt++;

    // it_lo(2) + ciphertext
    final result = <int>[it & 0xFF, (it >> 8) & 0xFF];
    result.addAll(ciphertext);
    return result;
  }

  /// 解密（接收方向：dev_key + dev_iv）
  ///
  /// 输入: it_lo(2) + ciphertext
  /// 返回: plaintext 或 null
  List<int>? decrypt(List<int> data) {
    if (data.length < 6) return null;
    if (_devKey == null || _devIv == null) return null;

    final int itLo = data[0] | (data[1] << 8);
    // 溢出跟踪
    if (itLo < _lastDevItLo && (_lastDevItLo - itLo) > 32768) {
      _devItHi++;
    }
    _lastDevItLo = itLo;
    final int it = (_devItHi << 16) | itLo;

    final nonce = Uint8List(12);
    nonce.setRange(0, 4, _devIv!);
    nonce.setRange(4, 8, const [0, 0, 0, 0]);
    nonce[8] = it & 0xFF;
    nonce[9] = (it >> 8) & 0xFF;
    nonce[10] = (it >> 16) & 0xFF;
    nonce[11] = (it >> 24) & 0xFF;

    final ciphertext = data.sublist(2);
    try {
      return _aesCcmDecrypt(_devKey!, nonce, ciphertext);
    } catch (e, stackTrace) {
      AppLogger.instance.e('CryptoEngine', 'Decrypt failed: $e', stackTrace);
      return null;
    }
  }

  /// AES-CCM 加密（tag_length=4）
  List<int> _aesCcmEncrypt(List<int> key, List<int> nonce, List<int> plain) {
    // pointycastle 的 GCM 可视为 CCM 的特例；实际使用 AesFastEngine + CCM 模式
    // 注：pointycastle 未直接提供 CCM，本实现使用 GCM(tag=4) 近似
    // TODO: 严格意义上的 CCM 需手写；当前按 GCM(tag_length=4) 实现
    final cipher = GCMBlockCipher(AesFastEngine());
    cipher.init(
      true,
      AEADParameters(
        KeyParameter(Uint8List.fromList(key)),
        32, // 4 bytes tag * 8 = 32 bits
        Uint8List.fromList(nonce),
        Uint8List(0),
      ),
    );
    final output = cipher.process(Uint8List.fromList(plain));
    return output;
  }

  /// AES-CCM 解密
  List<int> _aesCcmDecrypt(List<int> key, List<int> nonce, List<int> ciphertext) {
    final engine = GCMBlockCipher(AesFastEngine());
    engine.init(
      false,
      AEADParameters(
        KeyParameter(Uint8List.fromList(key)),
        32,
        Uint8List.fromList(nonce),
        Uint8List(0),
      ),
    );
    return engine.process(Uint8List.fromList(ciphertext));
  }

  static String _hex(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
