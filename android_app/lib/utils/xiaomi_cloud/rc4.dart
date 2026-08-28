import 'dart:convert';
import 'dart:typed_data';

/// RC4-drop[1024] 加密/解密 (纯 Dart 实现，无需外部依赖)
///
/// 参照 Python 参考实现 (xiaomi_cloud.py)：
/// 实现 RC4 流密码并丢弃前 1024 字节输出以消除偏差。
///
/// RC4 是对称流密码，加密和解密使用相同的算法。

/// RC4-drop[1024] 加密
///
/// [password] 为 base64 编码的密钥，[payload] 为待加密明文。
/// 返回 base64 编码的密文。
///
/// 对应 Python:
/// ```python
/// r = ARC4.new(base64.b64decode(password))
/// r.encrypt(bytes(1024))
/// return base64.b64encode(r.encrypt(payload.encode())).decode()
/// ```
String encryptRc4(String password, String payload) {
  final key = base64Decode(password);
  final engine = _Rc4Engine(key);
  // 丢弃前 1024 字节输出以消除 RC4 偏差
  engine.process(Uint8List(1024));
  final plaintext = utf8.encode(payload);
  final encrypted = engine.process(plaintext);
  return base64.encode(encrypted);
}

/// RC4-drop[1024] 解密
///
/// [password] 为 base64 编码的密钥，[payload] 为 base64 编码的密文。
/// 返回解密后的明文字符串。
///
/// 对应 Python:
/// ```python
/// r = ARC4.new(base64.b64decode(password))
/// r.encrypt(bytes(1024))
/// return r.encrypt(base64.b64decode(payload))
/// ```
String decryptRc4(String password, String payload) {
  final key = base64Decode(password);
  final engine = _Rc4Engine(key);
  // 丢弃前 1024 字节输出以消除 RC4 偏差
  engine.process(Uint8List(1024));
  final ciphertext = base64Decode(payload);
  final decrypted = engine.process(ciphertext);
  return utf8.decode(decrypted);
}

/// 纯 Dart RC4 引擎实现
class _Rc4Engine {
  final Uint8List _state;
  int _x = 0;
  int _y = 0;

  _Rc4Engine(Uint8List key) : _state = Uint8List(256) {
    for (int i = 0; i < 256; i++) {
      _state[i] = i;
    }
    int j = 0;
    for (int i = 0; i < 256; i++) {
      j = (j + _state[i] + key[i % key.length]) & 255;
      final temp = _state[i];
      _state[i] = _state[j];
      _state[j] = temp;
    }
  }

  /// 处理字节块（加密/解密）
  Uint8List process(Uint8List input) {
    final output = Uint8List(input.length);
    for (int i = 0; i < input.length; i++) {
      _x = (_x + 1) & 255;
      _y = (_y + _state[_x]) & 255;
      final temp = _state[_x];
      _state[_x] = _state[_y];
      _state[_y] = temp;
      output[i] = input[i] ^ _state[(_state[_x] + _state[_y]) & 255];
    }
    return output;
  }
}