import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// RC4-drop[1024] 加密/解密
///
/// 参照 Python 参考实现 (xiaomi_cloud.py)：
/// 使用 pointycastle 的 [Arc4Engine]，丢弃前 1024 字节输出以消除偏差。
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
  final engine = Arc4Engine(key);
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
  final engine = Arc4Engine(key);
  // 丢弃前 1024 字节输出以消除 RC4 偏差
  engine.process(Uint8List(1024));
  final ciphertext = base64Decode(payload);
  final decrypted = engine.process(ciphertext);
  return utf8.decode(decrypted);
}