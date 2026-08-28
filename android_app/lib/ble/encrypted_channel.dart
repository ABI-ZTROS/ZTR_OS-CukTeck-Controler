import 'dart:typed_data';
import '../utils/logger/logger.dart';
import '../protocol/crypto.dart';
import '../protocol/miot_tlv.dart';
import 'android_connector.dart';

/// 加密命令通道
///
/// 负责通过 CMD_SEND / CMD_RECV 通道发送加密命令并接收响应。
/// 握手: 发送头部(1帧) → RCV_RDY → 发送数据帧 → RCV_OK
class EncryptedChannel {
  EncryptedChannel._();
  static final EncryptedChannel instance = EncryptedChannel._();

  final CryptoEngine _crypto = CryptoEngine.instance;

  /// 发送加密命令（plaintext）并等待响应
  Future<Map<String, dynamic>?> sendAndReceive(
    AndroidConnector connector,
    List<int> plaintext, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_crypto.hasKeys) {
      throw StateError('Session keys not established');
    }

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        if (attempt > 1) {
          AppLogger.instance.w('EncryptedChannel', 'Retry attempt $attempt/3');
        }
        final encrypted = await _crypto.encrypt(plaintext);

        // 1. 发送头部
        await connector.write('cmd_send', [0, 0, 0, 0, 1, 0]);

        // 2. 等 RCV_RDY
        final rcvRdy = await _wait(connector, 'cmd_send', timeout: timeout);
        if (rcvRdy == null || rcvRdy.length < 4 ||
            rcvRdy[2] != 1 || rcvRdy[3] != 1) {
          AppLogger.instance.w('EncryptedChannel', 'No RCV_RDY (attempt $attempt)');
          if (attempt >= 3) return null;
          continue;
        }

        // 3. 发送数据帧
        await connector.write('cmd_send', [1, 0]..addAll(encrypted));

        // 4. 等 RCV_OK
        final rcvOk = await _wait(connector, 'cmd_send', timeout: timeout);
        if (rcvOk == null || rcvOk.length < 4 ||
            rcvOk[2] != 1 || rcvOk[3] != 0) {
          AppLogger.instance.w('EncryptedChannel', 'No RCV_OK (attempt $attempt)');
          if (attempt >= 3) return null;
          continue;
        }

        // 5. 等响应
        final resp = await _wait(connector, 'cmd_recv', timeout: timeout);
        if (resp == null) {
          AppLogger.instance.w('EncryptedChannel', 'No response (attempt $attempt)');
          if (attempt >= 3) return null;
          continue;
        }

        // 解密
        final pt = await _crypto.decrypt(resp.sublist(2));
        if (pt == null) {
          AppLogger.instance.w('EncryptedChannel', 'Decrypt failed (attempt $attempt)');
          if (attempt >= 3) return null;
          continue;
        }
        return MiotTlv.parse(Uint8List.fromList(pt));
      } catch (e, stackTrace) {
        AppLogger.instance.e('EncryptedChannel', 'sendAndReceive attempt $attempt failed: $e', stackTrace);
        if (attempt >= 3) return null;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    return null;
  }

  Future<List<int>?> _wait(
    AndroidConnector connector,
    String channel, {
    required Duration timeout,
  }) async {
    // 关键修复：使用 connector.waitNotification() 真实订阅 BLE 通知流
    return connector.waitNotification(channel, timeout: timeout);
  }

  /// 发送 MiOT SET 命令（便捷）
  Future<Map<String, dynamic>?> sendSet(
    AndroidConnector connector,
    int siid,
    int piid,
    int value, {
    int Function()? seqProvider,
  }) async {
    final seq = seqProvider?.call() ?? 0;
    final tlvs = MiotTlv.build(seq, siid, piid, value: value);
    return sendAndReceive(connector, tlvs);
  }

  /// 发送 MiOT GET 命令（便捷）
  Future<Map<String, dynamic>?> sendGet(
    AndroidConnector connector,
    int siid,
    int piid, {
    int Function()? seqProvider,
  }) async {
    final seq = seqProvider?.call() ?? 0;
    final tlvs = MiotTlv.build(seq, siid, piid);
    return sendAndReceive(connector, tlvs);
  }
}
