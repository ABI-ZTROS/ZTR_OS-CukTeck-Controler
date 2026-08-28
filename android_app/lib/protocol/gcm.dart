import 'dart:typed_data';

import 'aes128.dart';

/// GCM 模式实现 (基于 GF(2^128))
///
/// 使用 AES-128 作为分组密码。

/// GF(2^128) 乘法 (GCM 核心运算)
///
/// 使用 little-endian 表示: byte 0 = LSB (x^0), byte 15 = MSB (x^127)
/// 多项式: x^128 + x^7 + x^2 + x + 1
void gf128Multiply(Uint8List result, Uint8List a, Uint8List b) {
  final z = Uint8List(16);
  final x = Uint8List.fromList(a);

  for (int i = 0; i < 128; i++) {
    // 检查 b 的第 i 位是否为 1 (bit 0 = LSB)
    final byteIdx = i >> 3;
    final bitMask = 1 << (i & 7);
    if ((b[byteIdx] & bitMask) != 0) {
      for (int j = 0; j < 16; j++) {
        z[j] ^= x[j];
      }
    }

    // X = X * x (左移 1 位)
    final bool msbSet = (x[15] & 0x80) != 0;
    for (int j = 15; j > 0; j--) {
      x[j] = (x[j] << 1) | (x[j - 1] >> 7);
    }
    x[0] = (x[0] << 1) & 0xFF;

    // 若 MSB 曾为 1，则约简: x^128 ≡ x^7 + x^2 + x + 1
    if (msbSet) {
      x[0] ^= 0x87; // 0x87 = x^7 + x^2 + x + 1
    }
  }

  for (int j = 0; j < 16; j++) {
    result[j] = z[j];
  }
}

/// GHASH: GCM 哈希函数
///
/// 对输入数据 (应已填充为 16 字节倍数) 进行 GHASH 计算。
/// H 为 hash subkey (16 字节)。
void ghash(Uint8List result, Uint8List data, Uint8List h) {
  result.fillRange(0, 16, 0); // 初始化为 0

  final block = Uint8List(16);
  for (int offset = 0; offset < data.length; offset += 16) {
    // 复制 16 字节分组 (若最后一组不足 16 字节则补零)
    block.fillRange(0, 16, 0);
    final remaining = data.length - offset;
    final blockSize = remaining >= 16 ? 16 : remaining;
    block.setRange(0, blockSize, data, offset);

    // XOR 累加结果
    for (int j = 0; j < 16; j++) {
      result[j] ^= block[j];
    }

    // 乘以 H
    gf128Multiply(result, result, h);
  }
}

/// 递增 GCM 计数器 (J_0 的最后 32 位，big-endian)
void incrementCounter(Uint8List j0) {
  for (int i = 15; i >= 12; i--) {
    j0[i] = (j0[i] + 1) & 0xFF;
    if (j0[i] != 0) break;
  }
}

/// GCM 加密，返回 ciphertext + 4 字节 tag
List<int> gcmEncrypt(
  List<int> key,
  List<int> nonce,
  List<int> plaintext,
) {
  final keyBytes = Uint8List.fromList(key);
  final nonceBytes = Uint8List.fromList(nonce);
  final rk = keyExpand(keyBytes);

  // 1. H = AES_K(0^128) -- hash subkey
  final h = aesEncryptBlock(Uint8List(16), rk);

  // 2. J_0 = nonce || 0^31 || 1 (96-bit nonce: 12 bytes + 4 bytes counter)
  final j0 = Uint8List(16);
  j0.setRange(0, 12, nonceBytes);
  j0[15] = 0x01; // 计数器从 1 开始

  // 3. 使用 GCTR 加密明文
  final plainLen = plaintext.length;
  final numBlocks = plainLen == 0 ? 0 : (plainLen + 15) ~/ 16;
  final ciphertext = Uint8List(plainLen);

  if (plainLen > 0) {
    final counter = Uint8List.fromList(j0);
    for (int i = 0; i < numBlocks; i++) {
      incrementCounter(counter);
      final keystream = aesEncryptBlock(counter, rk);

      final offset = i * 16;
      for (int j = 0; j < 16 && (offset + j) < plainLen; j++) {
        ciphertext[offset + j] = plaintext[offset + j] ^ keystream[j];
      }
    }
  }

  // 4. 计算 tag
  // GHASH(H, empty_AAD, ciphertext || len_block)
  // len_block: 0^64 || len(C)_64 (128 位，big-endian)
  final lenInBits = plainLen * 8;

  // 构造 GHASH 输入: ciphertext || 0-padding || len_block(16 bytes)
  final ghashInput = Uint8List(
    (numBlocks * 16) + 16, // 对齐到 16 字节边界 + 16 字节长度块
  );
  ghashInput.setRange(0, plainLen, ciphertext);
  // 其余部分已为 0 (填充)

  // 长度块位于末尾
  final lenOffset = numBlocks * 16;
  ghashInput[lenOffset + 8] = (lenInBits >> 56) & 0xFF;
  ghashInput[lenOffset + 9] = (lenInBits >> 48) & 0xFF;
  ghashInput[lenOffset + 10] = (lenInBits >> 40) & 0xFF;
  ghashInput[lenOffset + 11] = (lenInBits >> 32) & 0xFF;
  ghashInput[lenOffset + 12] = (lenInBits >> 24) & 0xFF;
  ghashInput[lenOffset + 13] = (lenInBits >> 16) & 0xFF;
  ghashInput[lenOffset + 14] = (lenInBits >> 8) & 0xFF;
  ghashInput[lenOffset + 15] = lenInBits & 0xFF;

  final ghashResult = Uint8List(16);
  ghash(ghashResult, ghashInput, h);

  // Tag = GHASH XOR AES_K(J_0)
  final tagKeystream = aesEncryptBlock(Uint8List.fromList(j0), rk);
  final fullTag = Uint8List(16);
  for (int i = 0; i < 16; i++) {
    fullTag[i] = ghashResult[i] ^ tagKeystream[i];
  }

  // 截断为 4 字节 tag
  final tag = fullTag.sublist(0, 4);

  // 返回 ciphertext + tag
  final result = <int>[];
  result.addAll(ciphertext);
  result.addAll(tag);
  return result;
}

/// GCM 解密，输入为 ciphertext + 4 字节 tag，返回明文
List<int> gcmDecrypt(
  List<int> key,
  List<int> nonce,
  List<int> ciphertextWithTag,
) {
  if (ciphertextWithTag.length < 4) {
    throw ArgumentError('Ciphertext too short: must be at least 4 bytes for tag');
  }

  final keyBytes = Uint8List.fromList(key);
  final nonceBytes = Uint8List.fromList(nonce);
  final rk = keyExpand(keyBytes);

  // 拆分: 实际密文 + 4 字节 tag
  final actualCipherLen = ciphertextWithTag.length - 4;
  final actualCiphertext = Uint8List.fromList(
    ciphertextWithTag.sublist(0, actualCipherLen),
  );
  final receivedTag = Uint8List.fromList(
    ciphertextWithTag.sublist(actualCipherLen),
  );

  // 1. H = AES_K(0^128)
  final h = aesEncryptBlock(Uint8List(16), rk);

  // 2. J_0 = nonce || 0^31 || 1
  final j0 = Uint8List(16);
  j0.setRange(0, 12, nonceBytes);
  j0[15] = 0x01;

  // 3. 使用 GCTR 解密密文
  final numBlocks = actualCipherLen == 0 ? 0 : (actualCipherLen + 15) ~/ 16;
  final plaintext = Uint8List(actualCipherLen);

  if (actualCipherLen > 0) {
    final counter = Uint8List.fromList(j0);
    for (int i = 0; i < numBlocks; i++) {
      incrementCounter(counter);
      final keystream = aesEncryptBlock(counter, rk);

      final offset = i * 16;
      for (int j = 0; j < 16 && (offset + j) < actualCipherLen; j++) {
        plaintext[offset + j] = actualCiphertext[offset + j] ^ keystream[j];
      }
    }
  }

  // 4. 计算期望的 tag
  final lenInBits = actualCipherLen * 8;
  final ghashInput = Uint8List(
    (numBlocks * 16) + 16,
  );
  ghashInput.setRange(0, actualCipherLen, actualCiphertext);

  final lenOffset = numBlocks * 16;
  ghashInput[lenOffset + 8] = (lenInBits >> 56) & 0xFF;
  ghashInput[lenOffset + 9] = (lenInBits >> 48) & 0xFF;
  ghashInput[lenOffset + 10] = (lenInBits >> 40) & 0xFF;
  ghashInput[lenOffset + 11] = (lenInBits >> 32) & 0xFF;
  ghashInput[lenOffset + 12] = (lenInBits >> 24) & 0xFF;
  ghashInput[lenOffset + 13] = (lenInBits >> 16) & 0xFF;
  ghashInput[lenOffset + 14] = (lenInBits >> 8) & 0xFF;
  ghashInput[lenOffset + 15] = lenInBits & 0xFF;

  final ghashResult = Uint8List(16);
  ghash(ghashResult, ghashInput, h);

  final tagKeystream = aesEncryptBlock(Uint8List.fromList(j0), rk);
  final fullTag = Uint8List(16);
  for (int i = 0; i < 16; i++) {
    fullTag[i] = ghashResult[i] ^ tagKeystream[i];
  }

  // 截断为 4 字节并比较
  for (int i = 0; i < 4; i++) {
    if (fullTag[i] != receivedTag[i]) {
      throw Exception('GCM tag verification failed');
    }
  }

  return List<int>.from(plaintext);
}
