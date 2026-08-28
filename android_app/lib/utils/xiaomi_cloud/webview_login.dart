import 'dart:async';
import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import '../logger/logger.dart';

/// WebView 登录控制器
///
/// 米家云登录完整流程（参照 xiaomi_cloud.py）：
/// 1. HTTP GET serviceLogin?sid=xiaomiio&_json=true → JSON 响应
/// 2. 解析 JSON 获取 location URL（含 _sign, serviceParam, callback）
/// 3. WebView 加载 location URL → 显示登录表单
/// 4. 用户完成登录 → 重定向到 callback (sts.api.io.mi.com)
/// 5. 从 callback URL 参数和 cookies 中提取 serviceToken + ssecurity
class WebviewLoginController {
  final StreamController<LoginEvent> _controller = StreamController.broadcast();
  final http.Client _httpClient = http.Client();

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
    AppLogger.instance
        .i('WebviewLogin', 'Login success: serviceToken=${serviceToken!.substring(0, 8)}...');
    _controller.add(LoginEvent.success(serviceToken!, ssecurity!));
  }

  /// 第一步：获取登录 URL
  /// 返回需要在 WebView 中加载的 location URL
  Future<String?> fetchLoginUrl() async {
    try {
      final response = await _httpClient.get(
        Uri.parse('https://account.xiaomi.com/pass/serviceLogin?sid=xiaomiio&_json=true'),
        headers: {
          'User-Agent': 'Android-7.1.1-1.0.0-ONEPLUS A3010-136 MIIO/',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        AppLogger.instance.d('WebviewLogin', 'serviceLogin response: code=${data['code']}');

        // 从响应中提取 location URL
        String? loginUrl;
        if (data['location'] != null) {
          loginUrl = (data['location'] as String).trim();
          // 移除可能的反引号包裹
          if (loginUrl.startsWith('`') && loginUrl.endsWith('`')) {
            loginUrl = loginUrl.substring(1, loginUrl.length - 1);
          }
        }

        if (loginUrl != null && loginUrl.isNotEmpty) {
          AppLogger.instance.i('WebviewLogin', 'Got login URL');
          return loginUrl;
        } else {
          AppLogger.instance.e('WebviewLogin', 'No location in response: ${response.body}');
          _controller.add(LoginEvent.error('无法获取登录页面: ${data['description'] ?? '未知错误'}'));
          return null;
        }
      } else {
        AppLogger.instance.e('WebviewLogin', 'serviceLogin HTTP ${response.statusCode}');
        _controller.add(LoginEvent.error('网络请求失败: HTTP ${response.statusCode}'));
        return null;
      }
    } catch (e, stackTrace) {
      AppLogger.instance.e('WebviewLogin', 'fetchLoginUrl error: $e', stackTrace);
      _controller.add(LoginEvent.error('获取登录页面失败: $e'));
      return null;
    }
  }

  /// 从当前页面提取 cookies
  /// 优先使用 CookieManager（可读取 httpOnly cookies），失败则回退到 JS
  Future<void> _extractCookies(InAppWebViewController webController, String url) async {
    try {
      // 方法1: CookieManager (可读取 httpOnly cookies)
      final uri = WebUri(url);
      final cookies = await CookieManager.instance.getCookies(url: uri);
      for (final cookie in cookies) {
        if (cookie.name == 'serviceToken' && serviceToken == null) {
          serviceToken = cookie.value;
          AppLogger.instance.d('WebviewLogin', 'Found serviceToken via CookieManager');
        }
        if (cookie.name == 'ssecurity' && ssecurity == null) {
          ssecurity = cookie.value;
          AppLogger.instance.d('WebviewLogin', 'Found ssecurity via CookieManager');
        }
        if (cookie.name == 'userId' && userId == null) {
          userId = cookie.value;
        }
      }

      // 方法2: JavaScript (fallback, 不能读 httpOnly)
      if (serviceToken == null || ssecurity == null) {
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
      }

      if (serviceToken != null && ssecurity != null) {
        _emitSuccess();
      }
    } catch (e) {
      AppLogger.instance.w('WebviewLogin', 'Cookie extraction failed: $e');
      // JS fallback
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
              }
              if (name == 'ssecurity' && ssecurity == null) {
                ssecurity = value;
              }
              if (name == 'userId' && userId == null) {
                userId = value;
              }
            }
          }
          if (serviceToken != null && ssecurity != null) {
            _emitSuccess();
          }
        }
      } catch (e2) {
        AppLogger.instance.w('WebviewLogin', 'JS fallback also failed: $e2');
      }
    }
  }

  /// 监听导航变化，捕获登录回调
  Future<NavigationActionPolicy> onNavigation(NavigationAction action) async {
    final url = action.request.url?.toString() ?? '';
    AppLogger.instance.d('WebviewLogin', 'Navigating: $url');

    // 检测 sts.api.io.mi.com 回调 → 登录成功
    if (url.contains('sts.api.io.mi.com')) {
      if (action.request.url != null) {
        final uri = action.request.url!;

        // 从 URL 查询参数获取 serviceToken
        final params = uri.queryParameters;
        if (params.containsKey('serviceToken') && serviceToken == null) {
          serviceToken = params['serviceToken'];
          AppLogger.instance.d('WebviewLogin', 'Found serviceToken in callback URL');
        }

        // 从 fragment 获取
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

        // 尝试从 cookies 获取 ssecurity
        // (将在 onLoadStop 中通过 JS 获取)
      }
    }

    return NavigationActionPolicy.ALLOW;
  }

  /// 页面加载完成后提取凭据
  Future<void> onLoadStop(InAppWebViewController webController, String url) async {
    AppLogger.instance.d('WebviewLogin', 'Page loaded: $url');

    // 方法1: 从 URL 参数提取（callback 页面）
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

    // 方法2: 通过 CookieManager + JS 提取 cookies
    await _extractCookies(webController, url);

    // 方法3: 从多个域名尝试获取 cookies
    final urlsToCheck = <String>[
      'https://account.xiaomi.com',
      'https://sts.api.io.mi.com',
      url,
    ];
    for (final checkUrl in urlsToCheck) {
      if (serviceToken != null && ssecurity != null) break;
      await _extractCookies(webController, checkUrl);
    }

    if (serviceToken != null && ssecurity != null) {
      _emitSuccess();
    }
  }

  void dispose() {
    _httpClient.close();
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