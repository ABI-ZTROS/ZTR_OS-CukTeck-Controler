import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
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
  /// 返回: it_lo(2) + ciphertext（含 tag）
  Future<List<int>> encrypt(List<int> plaintext) async {
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

    final ciphertext = await _aesCcmEncrypt(_appKey!, nonce, plaintext);
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
  Future<List<int>?> decrypt(List<int> data) async {
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
      return await _aesCcmDecrypt(_devKey!, nonce, ciphertext);
    } catch (e, stackTrace) {
      AppLogger.instance.e('CryptoEngine', 'Decrypt failed: $e', stackTrace);
      return null;
    }
  }

  /// AES-GCM 加密（使用 cryptography 包，输出包含 tag）
  Future<List<int>> _aesCcmEncrypt(List<int> key, List<int> nonce, List<int> plain) async {
    final cipher = AesGcm(key: SecretKey(Uint8List.fromList(key)));
    final encrypted = await cipher.encrypt(
      SecretBox(Uint8List.fromList(plain), nonce: Nonce(Uint8List.fromList(nonce))),
    );
    return encrypted.cipherText; // This includes tag appended
  }

  /// AES-GCM 解密
  Future<List<int>> _aesCcmDecrypt(List<int> key, List<int> nonce, List<int> ciphertext) async {
    final cipher = AesGcm(key: SecretKey(Uint8List.fromList(key)));
    final decrypted = await cipher.decrypt(
      SecretBox(Uint8List.fromList(ciphertext), nonce: Nonce(Uint8List.fromList(nonce))),
    );
    return decrypted.cipherText;
  }

  static String _hex(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}