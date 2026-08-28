import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/key_derivators/hkdf.dart';
import '../ble/android_connector.dart';
import '../utils/logger/logger.dart';
import 'constants.dart';
import 'crypto.dart';

/// MiOT BLE 认证流程
///
/// 参考: controller.py _try_authenticate
/// Phase A (0xa4 初始化) → Phase B (CMD_LOGIN 0x24 + HKDF + HMAC) → 第二轮 challenge-response
class Authenticator {
  Authenticator._();
  static final Authenticator instance = Authenticator._();

  final CryptoEngine _crypto = CryptoEngine.instance;

  Future<bool> authenticate(AndroidConnector connector, String token) async {
    try {
      AppLogger.instance.i('Authenticator', 'Starting MiOT authenticate...');

      // Phase A: 设备初始化
      AppLogger.instance.i('Authenticator', '[1/5] Device init (0xa4)...');
      await connector.write('auth_ctrl', [0xa4]);
      final initResp = await _waitNotify(connector, 'auth_data', timeout: const Duration(seconds: 3));
      if (initResp == null) {
        AppLogger.instance.w('Authenticator', 'No init response');
        return false;
      }
      final ack = List<int>.from(initResp);
      if (ack.length >= 3) ack[2] = ack[2] + 1;
      await connector.write('auth_data', ack);

      // 读取设备密钥交换数据
      final keyData = await _waitNotify(connector, 'auth_data', timeout: const Duration(seconds: 5));
      if (keyData == null || keyData.length < 20) {
        AppLogger.instance.w('Authenticator', 'Key exchange data invalid');
        return false;
      }
      final padLen = keyData.length - 4;
      final placeholder = <int>[0, 0, 5, 1] + List<int>.filled(padLen, 0xf2);
      await connector.write('auth_data', placeholder);

      // Phase B: CMD_LOGIN
      AppLogger.instance.i('Authenticator', '[2/5] Sending CMD_LOGIN=0x24...');
      await connector.write('auth_ctrl', [0x24, 0x00, 0x00, 0x00]);

      AppLogger.instance.i('Authenticator', '[3/5] Sending random key...');
      final randKey = _randomBytes(16);
      await connector.write('auth_data', [0, 0, 0, 0x0b, 1, 0]);

      // 等待 RCV_RDY
      var rcvRdy = await _waitNotify(connector, 'auth_data', timeout: const Duration(seconds: 3));
      while (rcvRdy != null &&
          !(rcvRdy.length == 4 && rcvRdy[2] == 1 && rcvRdy[3] == 1)) {
        rcvRdy = await _waitNotify(connector, 'auth_data', timeout: const Duration(seconds: 3));
      }

      await connector.write('auth_data', [1, 0]..addAll(randKey));

      final rcvOk = await _waitNotify(connector, 'auth_data', timeout: const Duration(seconds: 3));
      if (rcvOk == null || rcvOk.length < 4 || rcvOk[3] != 0) {
        AppLogger.instance.w('Authenticator', 'No RCV_OK');
        return false;
      }

      final devRandom = await _recvAuthResponse(connector, 'auth_data');
      if (devRandom == null || devRandom.length < 16) {
        AppLogger.instance.w('Authenticator', 'Invalid dev random');
        return false;
      }
      final devKey = devRandom.sublist(0, 16);

      final devHmacInfo = await _recvAuthResponse(connector, 'auth_data');
      if (devHmacInfo == null || devHmacInfo.length < 32) {
        AppLogger.instance.w('Authenticator', 'Invalid dev HMAC');
        return false;
      }
      final devHmac = devHmacInfo.sublist(0, 32);

      // HKDF 派生会话密钥
      final tokenBytes = _hexToBytes(token);
      final salt = <int>[]..addAll(randKey)..addAll(devKey);
      final derived = _hkdfSha256(tokenBytes, salt, 64);

      final devKey_ = derived.sublist(0, 16);
      final appKey_ = derived.sublist(16, 32);
      final devIv = derived.sublist(32, 36);
      final appIv = derived.sublist(36, 40);

      _crypto.setSessionKeys(
        devKey: devKey_, appKey: appKey_, devIv: devIv, appIv: appIv);
      AppLogger.instance.i('Authenticator', 'Session keys derived');

      // HMAC 验证设备
      final saltInv = <int>[]..addAll(devKey)..addAll(randKey);
      final expectedDevHmac = _hmacSha256(devKey_, saltInv);
      if (!_listEquals(expectedDevHmac, devHmac)) {
        AppLogger.instance.e('Authenticator', 'Device HMAC verify failed');
        return false;
      }
      AppLogger.instance.i('Authenticator', '[4/5] Device HMAC verified');

      // 发送我方 HMAC
      final ourHmac = _hmacSha256(appKey_, salt);
      await connector.write('auth_data', [0, 0, 0, 10, 1, 0]);
      final rcvRdy2 = await _waitNotify(connector, 'auth_data', timeout: const Duration(seconds: 3));
      if (rcvRdy2 == null) return false;

      await connector.write('auth_data', [1, 0]..addAll(ourHmac));
      final rcvOk2 = await _waitNotify(connector, 'auth_data', timeout: const Duration(seconds: 3));

      // 第二轮 challenge-response
      // TODO: 待抓包补充完整 challenge-response 细节
      AppLogger.instance.i('Authenticator', '[5/5] Waiting login result...');
      final result = await _waitNotify(connector, 'auth_ctrl', timeout: const Duration(seconds: 5));
      if (result != null && result.isNotEmpty) {
        final frm = result[0];
        if (frm == 0x21) {
          AppLogger.instance.i('Authenticator', 'Login OK');
          return true;
        } else if (frm == 0x11) {
          AppLogger.instance.i('Authenticator', 'Activate OK');
          return true;
        } else {
          AppLogger.instance.e('Authenticator', 'Login failed: frm=0x${frm.toRadixString(16)}');
          return false;
        }
      }
      AppLogger.instance.w('Authenticator', 'No login result');
      return false;
    } catch (e, stackTrace) {
      AppLogger.instance.e('Authenticator', 'authenticate error: $e', stackTrace);
      return false;
    }
  }

  Future<List<int>?> _waitNotify(
    AndroidConnector connector,
    String channel, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    // 关键修复：使用 connector.waitNotification() 真实订阅 BLE 通知流
    return connector.waitNotification(channel, timeout: timeout);
  }

  Future<List<int>?> _recvAuthResponse(
    AndroidConnector connector,
    String channel,
  ) async {
    final data = await _waitNotify(connector, channel, timeout: const Duration(seconds: 3));
    if (data == null || data.length < 4) return null;
    if (data[2] == 0x02) {
      await connector.write(channel, [0, 0, 3, 0]);
      return data.sublist(4);
    }
    if (data[2] == 0x00 && data.length >= 6) {
      final count = data[4] | (data[5] << 8);
      await connector.write(channel, [0, 0, 1, 1]);
      final received = <int>[];
      for (int i = 0; i < count; i++) {
        final f = await _waitNotify(connector, channel, timeout: const Duration(seconds: 3));
        if (f == null) return null;
        received.addAll(f.sublist(2));
      }
      await connector.write(channel, [0, 0, 1, 0]);
      return received;
    }
    return null;
  }

  List<int> _randomBytes(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  List<int> _hexToBytes(String hex) {
    final s = hex.replaceAll(' ', '');
    final result = <int>[];
    for (int i = 0; i < s.length; i += 2) {
      result.add(int.parse(s.substring(i, i + 2), radix: 16));
    }
    return result;
  }

  List<int> _hkdfSha256(List<int> ikm, List<int> salt, int length) {
    final hkdf = HKDFKeyDerivator(Sha256Digest());
    hkdf.init(HkdfParameters(Uint8List.fromList(ikm), length, Uint8List.fromList(salt), null));
    final output = Uint8List(length);
    hkdf.deriveKeys(output);
    return output.toList();
  }

  List<int> _hmacSha256(List<int> key, List<int> data) {
    final hmac = HMac(Sha256Digest(), 64);
    hmac.init(KeyParameter(Uint8List.fromList(key)));
    hmac.update(Uint8List.fromList(data), 0, data.length);
    final output = Uint8List(32);
    hmac.doFinal(output, 0);
    return output.toList();
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
