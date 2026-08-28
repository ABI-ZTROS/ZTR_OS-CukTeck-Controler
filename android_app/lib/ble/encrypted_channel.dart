import '../logger/logger.dart';
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
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!_crypto.hasKeys) {
      throw StateError('Session keys not established');
    }

    final encrypted = _crypto.encrypt(plaintext);

    try {
      // 1. 发送头部
      await connector.write('cmd_send', [0, 0, 0, 0, 1, 0]);
      // 2. 等 RCV_RDY
      final rcvRdy = await _wait(connector, 'cmd_send', timeout: timeout);
      if (rcvRdy == null || rcvRdy.length < 4 ||
          rcvRdy[2] != 1 || rcvRdy[3] != 1) {
        AppLogger.instance.w('EncryptedChannel', 'No RCV_RDY');
        return null;
      }
      // 3. 发送数据帧
      await connector.write('cmd_send', [1, 0]..addAll(encrypted));
      // 4. 等 RCV_OK
      final rcvOk = await _wait(connector, 'cmd_send', timeout: timeout);
      if (rcvOk == null || rcvOk.length < 4 ||
          rcvOk[2] != 1 || rcvOk[3] != 0) {
        AppLogger.instance.w('EncryptedChannel', 'No RCV_OK');
        return null;
      }

      // 5. 等响应
      final resp = await _wait(connector, 'cmd_recv', timeout: timeout);
      if (resp == null) return null;

      // 解密
      final pt = _crypto.decrypt(resp.sublist(2));
      if (pt == null) return null;
      return MiotTlv.parse(Uint8List.fromList(pt));
    } catch (e, stackTrace) {
      AppLogger.instance.e('EncryptedChannel', 'sendAndReceive failed: $e', stackTrace);
      return null;
    }
  }

  Future<List<int>?> _wait(
    AndroidConnector connector,
    String channel, {
    required Duration timeout,
  }) async {
    // TODO: 接入 connector 通知流
    await Future<void>.delayed(timeout);
    return null;
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
