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
/// 4. 通过 JavaScript 注入获取 ssecurity cookie
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

  /// 尝试从当前页面获取 cookies (通过 JavaScript)
  Future<void> _extractCookiesViaJS(InAppWebViewController webController) async {
    try {
      final result = await webController.evaluateJavascript(source: 'document.cookie');
      if (result != null && result.isNotEmpty) {
        final cookiesStr = result as String;
        final pairs = cookiesStr.split(';');
        for (final pair in pairs) {
          final parts = pair.trim().split('=');
          if (parts.length >= 2) {
            final name = parts[0];
            final value = parts.sublist(1).join('=');
            if (name == 'serviceToken' && serviceToken == null) {
              serviceToken = value;
              AppLogger.instance.d('WebviewLogin', 'Found serviceToken via JS');
            }
            if (name == 'ssecurity' && ssecurity == null) {
              ssecurity = value;
              AppLogger.instance.d('WebviewLogin', 'Found ssecurity via JS');
            }
            if (name == 'userId' && userId == null) {
              userId = value;
            }
          }
        }
      }
      if (serviceToken != null && ssecurity != null) {
        _emitSuccess();
      }
    } catch (e) {
      AppLogger.instance.w('WebviewLogin', 'JS cookie extraction failed: $e');
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
          AppLogger.instance.d('WebviewLogin', 'Found serviceToken in URL');
        }
        // 检查 fragment (# 后面的参数)
        final fragment = action.request.url!.fragment;
        if (fragment.isNotEmpty) {
          final uri = Uri.parse('https://dummy.com?$fragment');
          if (uri.queryParameters.containsKey('serviceToken') && serviceToken == null) {
            serviceToken = uri.queryParameters['serviceToken'];
          }
          if (uri.queryParameters.containsKey('ssecurity') && ssecurity == null) {
            ssecurity = uri.queryParameters['ssecurity'];
          }
        }
      }
    }

    // 检测 account.xiaomi.com 登录页 → 可能包含 ssecurity
    if (url.contains('account.xiaomi.com')) {
      if (action.request.url != null) {
        final params = action.request.url!.queryParameters;
        if (params.containsKey('ssecurity') && ssecurity == null) {
          ssecurity = params['ssecurity'];
        }
      }
    }

    // 检查是否已满足登录条件
    if (serviceToken != null && ssecurity != null) {
      _emitSuccess();
    }

    return NavigationActionPolicy.ALLOW;
  }

  /// 页面加载完成后提取凭据
  Future<void> onLoadStop(InAppWebViewController webController, String url) async {
    AppLogger.instance.d('WebviewLogin', 'Page loaded: $url');

    // 方法1: 从 URL 参数提取
    if (url.contains('sts.api.io.mi.com')) {
      final uri = Uri.parse(url);
      if (uri.queryParameters.containsKey('serviceToken') && serviceToken == null) {
        serviceToken = uri.queryParameters['serviceToken'];
      }
      final fragment = uri.fragment;
      if (fragment.isNotEmpty) {
        final fragUri = Uri.parse('https://dummy.com?$fragment');
        if (fragUri.queryParameters.containsKey('serviceToken') && serviceToken == null) {
          serviceToken = fragUri.queryParameters['serviceToken'];
        }
        if (fragUri.queryParameters.containsKey('ssecurity') && ssecurity == null) {
          ssecurity = fragUri.queryParameters['ssecurity'];
        }
      }
    }

    // 方法2: 通过 JavaScript 获取 cookies
    await _extractCookiesViaJS(webController);

    if (serviceToken != null && ssecurity != null) {
      _emitSuccess();
    }
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