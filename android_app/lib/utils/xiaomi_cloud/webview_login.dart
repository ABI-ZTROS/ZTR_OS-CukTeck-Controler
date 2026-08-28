import 'dart:async';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../logger/logger.dart';

/// WebView 登录控制器
///
/// 监听 WebView 导航变化，自动捕获 serviceToken 和 ssecurity。
/// 流程：
/// 1. 打开 https://account.xiaomi.com/pass/serviceLogin?sid=xiaomiio&_json=true
/// 2. 用户完成登录后，WebView 重定向到 sts.api.io.mi.com
/// 3. 从重定向 URL 的参数中提取 serviceToken
/// 4. 从 WebView cookies 中提取 ssecurity
class WebviewLoginController {
  final StreamController<LoginEvent> _controller = StreamController.broadcast();

  Stream<LoginEvent> get events => _controller.stream;

  String? serviceToken;
  String? ssecurity;
  String? userId;
  String? location;
  bool _successReported = false;

  bool get isLoggedIn => serviceToken != null && ssecurity != null;

  /// 通知登录成功（只触发一次）
  void _emitSuccess() {
    if (_successReported) return;
    if (serviceToken == null || ssecurity == null) return;
    _successReported = true;
    AppLogger.instance.i('WebviewLogin', 'Login success: serviceToken=${serviceToken!.substring(0, 8)}...');
    _controller.add(LoginEvent.success(serviceToken!, ssecurity!));
  }

  /// 从 cookies 中提取凭据 (通过 InAppWebViewController)
  Future<void> _extractCookies(InAppWebViewController webController) async {
    try {
      final cookies = await webController.getCookies();
      for (final cookie in cookies) {
        if (cookie.name == 'serviceToken' && serviceToken == null) {
          serviceToken = cookie.value;
          AppLogger.instance.d('WebviewLogin', 'Found serviceToken');
        }
        if (cookie.name == 'ssecurity' && ssecurity == null) {
          ssecurity = cookie.value;
          AppLogger.instance.d('WebviewLogin', 'Found ssecurity');
        }
        if (cookie.name == 'userId' && userId == null) {
          userId = cookie.value;
        }
      }
      // 成功条件：同时拥有 serviceToken 和 ssecurity
      if (serviceToken != null && ssecurity != null) {
        _emitSuccess();
      }
    } catch (e) {
      AppLogger.instance.w('WebviewLogin', 'Cookie extraction failed: $e');
    }
  }

  /// 监听导航变化
  Future<NavigationActionPolicy> onNavigation(NavigationAction action) async {
    final url = action.request.url?.toString() ?? '';
    AppLogger.instance.d('WebviewLogin', 'Navigating: $url');

    // 检测 sts.api.io.mi.com 重定向 → 登录成功
    if (url.contains('sts.api.io.mi.com')) {
      // 尝试从 URL query/fragment 中获取 serviceToken
      if (action.request.url != null) {
        final params = action.request.url!.queryParameters;
        if (params.containsKey('serviceToken')) {
          serviceToken = params['serviceToken'];
        }
      }
    }

    return NavigationActionPolicy.ALLOW;
  }

  /// 页面加载完成后提取 cookies
  Future<void> onLoadStop(InAppWebViewController webController, String url) async {
    AppLogger.instance.d('WebviewLogin', 'Page loaded: $url');
    await _extractCookies(webController);
  }

  void dispose() {
    _controller.close();
  }
}

class LoginEvent {
  const LoginEvent.success(this.serviceToken, this.ssecurity)
      : errorMessage = null;
  const LoginEvent.error(this.errorMessage)
      : serviceToken = null, ssecurity = null;

  final String? serviceToken;
  final String? ssecurity;
  final String? errorMessage;
  bool get isSuccess => serviceToken != null;
}