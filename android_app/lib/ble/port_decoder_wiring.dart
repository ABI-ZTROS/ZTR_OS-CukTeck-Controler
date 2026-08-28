import 'dart:async';
import 'dart:typed_data';
import '../utils/logger/logger.dart';
import '../protocol/crypto.dart';
import '../protocol/miot_tlv.dart';
import '../protocol/port_decoder.dart';
import 'android_connector.dart';

/// 将 BLE cmd_recv 通知连接到 PortDecoder
///
/// 在连接认证成功后调用此函数以启动端口数据解码。
/// 返回 [StreamSubscription] 以便调用方在断开连接时取消订阅。
Future<StreamSubscription<BleNotification>> wirePortDecoder(
  AndroidConnector connector,
) async {
  return connector.notifications
      .where((n) => n.channel == 'cmd_recv')
      .listen((n) async {
    try {
      final ciphertext = n.data;
      if (ciphertext.length < 3) return;

      // 使用加密通道解密
      final crypto = CryptoEngine.instance;
      if (!crypto.hasKeys) {
        AppLogger.instance.w('PortDecoder', 'No session keys, cannot decrypt');
        return;
      }

      final plaintext = await crypto.decrypt(ciphertext.sublist(2));
      if (plaintext == null || plaintext.isEmpty) {
        AppLogger.instance.w('PortDecoder', 'Decrypt failed');
        return;
      }

      // 尝试解析 TLV
      final tlv = MiotTlv.parse(Uint8List.fromList(plaintext));
      if (tlv == null) return;

      // 如果是端口推送 (opcode=0x02, siid=2)
      PortDecoder.dispatchFromTlvMap(tlv);
    } catch (e, st) {
      AppLogger.instance.e('PortDecoder', 'Decode error: $e', st);
    }
  }, onError: (e, st) {
    AppLogger.instance.e('PortDecoder', 'Stream error: $e', st);
  });
}
