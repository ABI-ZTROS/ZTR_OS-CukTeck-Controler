import '../logger/logger.dart';
import 'cloud_client.dart';
import 'models.dart';

/// 二维码登录会话
///
/// 完整流程：
///   1. [start]  → 获取 QR URL 与长轮询 URL（由 [XiaomiCloudClient.startQrLogin] 提供）
///   2. [poll]    → 周期性调用轮询接口检查扫码状态
///   3. [complete] → 扫码确认后获取 serviceToken 并标记已登录
///
/// 注：当前 QR 长轮询接口存在未明确的风控逻辑，相关实现标注
/// `TODO: 待抓包补充`。调用方通过 `await for` 订阅 [poll] 后应及时
///取消订阅，以避免不必要的网络轮询。
class QrLoginSession {
  QrLoginSession._();

  static final QrLoginSession instance = QrLoginSession._();

  final XiaomiCloudClient _client = XiaomiCloudClient.instance;

  /// 启动二维码登录
  ///
  /// 返回包含 QR URL 与 token 的 [QrCodeData]，UI 层据此渲染二维码。
  Future<QrCodeData> start() async {
    try {
      return await _client.startQrLogin();
    } catch (e, stackTrace) {
      AppLogger.instance.e('QrLoginSession', 'start failed: $e', stackTrace);
      rethrow;
    }
  }

  /// 轮询扫码状态
  ///
  /// [sessionId] 由 [start] 返回的 [QrCodeData.token] 提供。
  /// 每 [interval] 调用一次 [XiaomiCloudClient.pollQrStatus]；
  /// 当状态为已确认/已过期时 Stream 自动结束。
  Stream<QrScanStatus> poll(
    String sessionId, {
    Duration interval = const Duration(seconds: 3),
  }) async* {
    while (true) {
      try {
        final status = await _client.pollQrStatus(sessionId);
        yield status;
        if (status.isConfirmed || status.isExpired) break;
      } catch (e, stackTrace) {
        AppLogger.instance
            .e('QrLoginSession', 'poll error: $e', stackTrace);
        rethrow;
      }
      await Future<void>.delayed(interval);
    }
  }

  /// 完成登录（扫码确认后调用）
  ///
  /// 成功时写入 [XiaomiCloudClient] 的登录态，返回 [LoginResult]。
  Future<LoginResult> complete() async {
    try {
      // TODO: 待抓包补充 serviceToken 获取逻辑
      // 参考：扫码确认后需 GET location 回调 URL，解析 serviceToken。
      throw UnimplementedError('complete TODO: 待抓包补充');
    } catch (e) {
      AppLogger.instance.e('QrLoginSession', 'complete failed: $e');
      return LoginResult(
        success: false,
        errorMessage: 'QR 登录完成异常: $e',
      );
    }
  }
}
