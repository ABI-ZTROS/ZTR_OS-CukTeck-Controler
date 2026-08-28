import 'dart:typed_data';
import '../utils/logger/logger.dart';

/// AES-CCM 加解密工具（Dart 移植）
///
/// 参考: controller.py _encrypt / decrypt
/// 非包 tag_length=4，nonce 格式: iv(4) + zeros(4) + counter(4)
///
/// 本实现使用自实现的 AES-128-GCM（tag 截断为 4 字节），
/// 不依赖 cryptography 或 pointycastle 包。
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

    final ciphertext = _gcmEncrypt(_appKey!, nonce, plaintext);
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
      return _gcmDecrypt(_devKey!, nonce, ciphertext);
    } catch (e, stackTrace) {
      AppLogger.instance.e('CryptoEngine', 'Decrypt failed: $e', stackTrace);
      return null;
    }
  }

  // ==========================================================================
  // AES-128 实现（从 Dart 原生实现，无第三方依赖）
  // ==========================================================================

  /// AES S-Box (256 字节)
  static const List<int> _sBox = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
  ];

  /// AES 逆 S-Box (256 字节)
  static const List<int> _invSBox = [
    0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
    0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
    0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
    0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
    0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
    0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
    0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
    0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
    0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
    0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
    0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
    0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
    0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
    0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
    0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
  ];

  /// AES 轮常量 (Rcon)
  static const List<int> _rcon = [
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36,
  ];

  // ---------------------------------------------------------------------------
  // GF(2^8) 乘法 (用于 MixColumns)
  // ---------------------------------------------------------------------------

  /// GF(2^8) 乘法，约简多项式 x^8 + x^4 + x^3 + x + 1 (0x11B)
  static int _gmul(int a, int b) {
    int p = 0;
    for (int i = 0; i < 8; i++) {
      if ((b & 1) != 0) p ^= a;
      final hi = (a & 0x80) != 0;
      a = (a << 1) & 0xFF;
      if (hi) a ^= 0x1B;
      b >>= 1;
    }
    return p;
  }

  // ---------------------------------------------------------------------------
  // AES-128 密钥扩展
  // ---------------------------------------------------------------------------

  /// AES-128 密钥扩展，生成 44 个 32 位字 (round keys)
  static List<List<int>> _keyExpand(List<int> key) {
    final w = <List<int>>[];

    // 前 4 个字直接从密钥取
    for (int i = 0; i < 4; i++) {
      w.add([key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]]);
    }

    for (int i = 4; i < 44; i++) {
      final temp = List<int>.from(w[i - 1]);
      if (i % 4 == 0) {
        // RotWord: [a,b,c,d] -> [b,c,d,a]
        final rotated = [temp[1], temp[2], temp[3], temp[0]];
        // SubWord: 对每个字节应用 S-Box
        final substituted = [
          _sBox[rotated[0]],
          _sBox[rotated[1]],
          _sBox[rotated[2]],
          _sBox[rotated[3]],
        ];
        // XOR with Rcon (仅第一个字节)
        substituted[0] ^= _rcon[(i ~/ 4) - 1];
        w.add(substituted);
      } else {
        final prev = w[i - 4];
        w.add([
          prev[0] ^ temp[0],
          prev[1] ^ temp[1],
          prev[2] ^ temp[2],
          prev[3] ^ temp[3],
        ]);
      }
    }

    return w;
  }

  // ---------------------------------------------------------------------------
  // AES-128 分组加密 (单 16 字节分组)
  // ---------------------------------------------------------------------------

  /// ShiftRows: 行移位
  static void _shiftRows(List<int> s) {
    // 第 1 行: 左移 1 位
    final t1 = s[1];
    s[1] = s[5];
    s[5] = s[9];
    s[9] = s[13];
    s[13] = t1;

    // 第 2 行: 左移 2 位
    final t2a = s[2];
    final t2b = s[6];
    s[2] = s[10];
    s[6] = s[14];
    s[10] = t2a;
    s[14] = t2b;

    // 第 3 行: 左移 3 位 (= 右移 1 位)
    final t3 = s[15];
    s[15] = s[11];
    s[11] = s[7];
    s[7] = s[3];
    s[3] = t3;
  }

  /// MixColumns: 列混合
  static void _mixColumns(List<int> s) {
    for (int c = 0; c < 4; c++) {
      final i = c * 4;
      final s0 = s[i];
      final s1 = s[i + 1];
      final s2 = s[i + 2];
      final s3 = s[i + 3];

      s[i] = _gmul(s0, 2) ^ _gmul(s1, 3) ^ s2 ^ s3;
      s[i + 1] = s0 ^ _gmul(s1, 2) ^ _gmul(s2, 3) ^ s3;
      s[i + 2] = s0 ^ s1 ^ _gmul(s2, 2) ^ _gmul(s3, 3);
      s[i + 3] = _gmul(s0, 3) ^ s1 ^ s2 ^ _gmul(s3, 2);
    }
  }

  /// AddRoundKey: 轮密钥加
  static void _addRoundKey(List<int> state, List<List<int>> rk, int round) {
    for (int i = 0; i < 16; i++) {
      state[i] ^= rk[round * 4 + (i ~/ 4)][i % 4];
    }
  }

  /// AES-128 加密单个 16 字节分组
  static Uint8List _aesEncryptBlock(Uint8List block, List<List<int>> rk) {
    final state = List<int>.from(block);

    // 初始轮密钥加
    _addRoundKey(state, rk, 0);

    // 9 轮主循环
    for (int round = 1; round <= 9; round++) {
      // SubBytes
      for (int i = 0; i < 16; i++) {
        state[i] = _sBox[state[i]];
      }

      // ShiftRows
      _shiftRows(state);

      // MixColumns
      _mixColumns(state);

      // AddRoundKey
      _addRoundKey(state, rk, round);
    }

    // 最后一轮 (无 MixColumns)
    for (int i = 0; i < 16; i++) {
      state[i] = _sBox[state[i]];
    }
    _shiftRows(state);
    _addRoundKey(state, rk, 10);

    return Uint8List.fromList(state);
  }

  // ==========================================================================
  // GCM 实现 (基于 GF(2^128))
  // ==========================================================================

  /// GF(2^128) 乘法 (GCM 核心运算)
  ///
  /// 使用 little-endian 表示: byte 0 = LSB (x^0), byte 15 = MSB (x^127)
  /// 多项式: x^128 + x^7 + x^2 + x + 1
  static void _gf128Multiply(Uint8List result, Uint8List a, Uint8List b) {
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
  static void _ghash(Uint8List result, Uint8List data, Uint8List h) {
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
      _gf128Multiply(result, result, h);
    }
  }

  /// 递增 GCM 计数器 (J_0 的最后 32 位，big-endian)
  static void _incrementCounter(Uint8List j0) {
    for (int i = 15; i >= 12; i--) {
      j0[i] = (j0[i] + 1) & 0xFF;
      if (j0[i] != 0) break;
    }
  }

  // ---------------------------------------------------------------------------
  // GCM 加密 (同步)
  // ---------------------------------------------------------------------------

  /// GCM 加密，返回 ciphertext + 4 字节 tag
  static List<int> _gcmEncrypt(
    List<int> key,
    List<int> nonce,
    List<int> plaintext,
  ) {
    final keyBytes = Uint8List.fromList(key);
    final nonceBytes = Uint8List.fromList(nonce);
    final rk = _keyExpand(keyBytes);

    // 1. H = AES_K(0^128) -- hash subkey
    final h = _aesEncryptBlock(Uint8List(16), rk);

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
        _incrementCounter(counter);
        final keystream = _aesEncryptBlock(counter, rk);

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

    final ghash = Uint8List(16);
    _ghash(ghash, ghashInput, h);

    // Tag = GHASH XOR AES_K(J_0)
    final tagKeystream = _aesEncryptBlock(Uint8List.fromList(j0), rk);
    final fullTag = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      fullTag[i] = ghash[i] ^ tagKeystream[i];
    }

    // 截断为 4 字节 tag
    final tag = fullTag.sublist(0, 4);

    // 返回 ciphertext + tag
    final result = <int>[];
    result.addAll(ciphertext);
    result.addAll(tag);
    return result;
  }

  // ---------------------------------------------------------------------------
  // GCM 解密 (同步)
  // ---------------------------------------------------------------------------

  /// GCM 解密，输入为 ciphertext + 4 字节 tag，返回明文
  static List<int> _gcmDecrypt(
    List<int> key,
    List<int> nonce,
    List<int> ciphertextWithTag,
  ) {
    if (ciphertextWithTag.length < 4) {
      throw ArgumentError('Ciphertext too short: must be at least 4 bytes for tag');
    }

    final keyBytes = Uint8List.fromList(key);
    final nonceBytes = Uint8List.fromList(nonce);
    final rk = _keyExpand(keyBytes);

    // 拆分: 实际密文 + 4 字节 tag
    final actualCipherLen = ciphertextWithTag.length - 4;
    final actualCiphertext = Uint8List.fromList(
      ciphertextWithTag.sublist(0, actualCipherLen),
    );
    final receivedTag = Uint8List.fromList(
      ciphertextWithTag.sublist(actualCipherLen),
    );

    // 1. H = AES_K(0^128)
    final h = _aesEncryptBlock(Uint8List(16), rk);

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
        _incrementCounter(counter);
        final keystream = _aesEncryptBlock(counter, rk);

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

    final ghash = Uint8List(16);
    _ghash(ghash, ghashInput, h);

    final tagKeystream = _aesEncryptBlock(Uint8List.fromList(j0), rk);
    final fullTag = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      fullTag[i] = ghash[i] ^ tagKeystream[i];
    }

    // 截断为 4 字节并比较
    for (int i = 0; i < 4; i++) {
      if (fullTag[i] != receivedTag[i]) {
        throw Exception('GCM tag verification failed');
      }
    }

    return List<int>.from(plaintext);
  }

  static String _hex(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
