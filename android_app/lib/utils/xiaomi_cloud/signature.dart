import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'rc4.dart';

/// 生成 12 字节 nonce（8 字节随机 + 4 字节时间戳），base64 编码
///
/// [millis] 为当前时间戳（毫秒），取 `millis ~/ 60000` 作为时间分量。
/// 随机分量使用 [Random.secure()] 保证密码学安全性。
///
/// 对应 Python:
/// ```python
/// nonce_bytes = os.urandom(8) + (int(millis / 60000)).to_bytes(4, byteorder="big")
/// return base64.b64encode(nonce_bytes).decode()
/// ```
String generateNonce(int millis) {
  final random = Random.secure();
  final bd = ByteData(12);
  for (int i = 0; i < 8; i++) {
    bd.setUint8(i, random.nextInt(256));
  }
  final ts = millis ~/ 60000;
  bd.setUint32(8, ts, Endian.big);
  return base64.encode(bd.buffer.asUint8List());
}

/// 计算 signedNonce = SHA256(base64Decode(ssecurity) + base64Decode(nonce))
///
/// 返回 base64 编码的 SHA256 摘要。对于相同输入，输出确定（可重现）。
///
/// 对应 Python:
/// ```python
/// hash_obj = hashlib.sha256(base64.b64decode(ssecurity) + base64.b64decode(nonce))
/// return base64.b64encode(hash_obj.digest()).decode()
/// ```
String signedNonce(String ssecurity, String nonce) {
  final bytes = <int>[
    ...base64Decode(ssecurity),
    ...base64Decode(nonce),
  ];
  final digest = sha256.convert(bytes);
  return base64.encode(digest.bytes);
}

/// 生成加密签名
///
/// 签名规则（与 Python 参考实现一致）：
///   1. `method.toUpperCase()`
///   2. URL 中 `"com"` 之后的路径，`"/app/"` 替换为 `"/"`
///   3. 按 key 字典序排序的 `key=value` 对
///   4. `signedNonce`
///   5. 以上用 `"&"` 连接，SHA1 后 base64 编码
///
/// 对应 Python:
/// ```python
/// signature_params = [str(method).upper(), url.split("com")[1].replace("/app/", "/")]
/// for k, v in params.items():
///     signature_params.append(f"{k}={v}")
/// signature_params.append(signed_nonce)
/// signature_string = "&".join(signature_params)
/// return base64.b64encode(hashlib.sha1(signature_string.encode("utf-8")).digest()).decode()
/// ```
String generateEncSignature(
  String url,
  String method,
  String signedNonce,
  Map<String, String> params,
) {
  final signatureParams = <String>[];
  signatureParams.add(method.toUpperCase());

  // url.split('com')[1].replaceFirst('/app/', '/')
  final urlParts = url.split('com');
  if (urlParts.length > 1) {
    signatureParams.add(urlParts[1].replaceFirst('/app/', '/'));
  } else {
    // URL 不含 "com" 时使用原始路径作为 fallback
    signatureParams.add(url);
  }

  // 按 key 字典序排序
  final sortedKeys = params.keys.toList()..sort();
  for (final key in sortedKeys) {
    signatureParams.add('$key=${params[key]}');
  }

  signatureParams.add(signedNonce);

  final signatureString = signatureParams.join('&');
  final digest = sha1.convert(utf8.encode(signatureString));
  return base64.encode(digest.bytes);
}

/// 生成加密后的 API 参数
///
/// 完整流程（与 Python 参考实现 `_generate_enc_params` 一致）：
///   1. 基于原始 [params] 计算 `rc4_hash__` 签名
///   2. RC4-drop[1024] 加密所有 param 的值（包括 `rc4_hash__`）
///   3. 基于加密后的 params 计算 `signature` 签名
///   4. 添加 `ssecurity` 和 `_nonce`
///
/// 返回的 Map 可直接作为 HTTP 请求的 body 参数。
///
/// 对应 Python:
/// ```python
/// params["rc4_hash__"] = _generate_enc_signature(url, method, signed_nonce, params)
/// for k, v in params.items():
///     params[k] = _encrypt_rc4(signed_nonce, v)
/// params.update({
///     "signature": _generate_enc_signature(url, method, signed_nonce, params),
///     "ssecurity": ssecurity,
///     "_nonce": nonce,
/// })
/// return params
/// ```
Map<String, String> generateEncParams({
  required String url,
  required String method,
  required String signedNonce,
  required String nonce,
  required Map<String, String> params,
  required String ssecurity,
}) {
  final result = Map<String, String>.from(params);

  // Step 1: rc4_hash__（基于加密前的原始 params 签名）
  result['rc4_hash__'] = generateEncSignature(url, method, signedNonce, result);

  // Step 2: RC4 加密所有值
  for (final key in result.keys.toList()) {
    final value = result[key]!;
    result[key] = encryptRc4(signedNonce, value);
  }

  // Step 3: signature（基于加密后的 params 签名）
  result['signature'] = generateEncSignature(url, method, signedNonce, result);

  // Step 4: ssecurity 和 _nonce
  result['ssecurity'] = ssecurity;
  result['_nonce'] = nonce;

  return result;
}