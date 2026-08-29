import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 米家云登录页面 —— WebView 全流程
///
/// 用户在 WebView 里完整走完浏览器登录（密码 + OTP），
/// 登录成功后：
///   1. 从 CookieManager 提取 cookies → 拿到 serviceToken / userId
///   2. 通过 JS fetch() 调 serviceLogin（带 credentials:include）→ 拿到 ssecurity
class WebviewLoginPage extends StatefulWidget {
  final Function(String serviceToken, String ssecurity, String userId) onLoginSuccess;

  const WebviewLoginPage({super.key, required this.onLoginSuccess});

  @override
  State<WebviewLoginPage> createState() => _WebviewLoginPageState();
}

class _WebviewLoginPageState extends State<WebviewLoginPage> {
  InAppWebViewController? _webCtrl;
  bool _isLoading = true;
  bool _extracting = false;
  String? _error;

  // 登录入口 —— 不带 _json=true，让服务器返回 HTML 登录页
  late final Uri _loginUrl = Uri.parse(
    'https://account.xiaomi.com/pass/serviceLogin'
    '?sid=xiaomiio'
    '&callback=https%3A%2F%2Fsts.api.io.mi.com%2Fsts'
    '&cc=%2B86',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('米家云登录')),
      body: Stack(
        children: [
          InAppWebView(
            initialSettings: InAppWebViewSettings(
              useShouldOverrideUrlLoading: true,
              mediaPlaybackRequiresUserGesture: false,
              javaScriptEnabled: true,
              domStorageEnabled: true,
              cacheEnabled: true,
            ),
            initialUrlRequest: URLRequest(url: WebUri(_loginUrl.toString())),
            onWebViewCreated: (ctrl) => _webCtrl = ctrl,
            onLoadStart: (_, __) => setState(() {
              _isLoading = true;
              _error = null;
            }),
            onLoadStop: (_, url) async {
              setState(() => _isLoading = false);
              final urlStr = url?.toString() ?? '';
              if (urlStr.contains('sts.api.io.mi.com')) {
                await _extractTokens();
              }
            },
            shouldOverrideUrlLoading: (_, action) async {
              final url = action.request.url?.toString() ?? '';
              if (url.contains('sts.api.io.mi.com')) {
                await Future.delayed(const Duration(milliseconds: 500));
                await _extractTokens();
                return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            },
            onReceivedError: (_, req, err) {
              final isMain = req != null &&
                  (req.isForMainFrame ?? true);
              if (isMain) {
                setState(() => _error = err.description);
              }
            },
          ),
          if (_isLoading && !_extracting)
            const Center(child: CircularProgressIndicator()),
          if (_extracting)
            Container(
              color: Colors.black.withOpacity(0.7),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 12),
                    Text('正在提取登录凭据...',
                        style: TextStyle(color: Colors.white, fontSize: 16)),
                  ],
                ),
              ),
            ),
          if (_error != null)
            Positioned(
              top: 0, left: 0, right: 0,
              child: Container(
                color: Colors.red.shade700,
                padding: const EdgeInsets.all(8),
                child: Text('加载错误: $_error',
                    style: const TextStyle(color: Colors.white)),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _extractTokens() async {
    if (_extracting || _webCtrl == null) return;
    setState(() => _extracting = true);

    try {
      final cookies = await CookieManager.instance()
          .getCookies(url: WebUri('https://account.xiaomi.com'));

      final cookieMap = <String, String>{};
      for (final c in cookies) {
        if (c.name != null && c.value != null) {
          cookieMap[c.name!] = c.value!;
        }
      }

      final serviceToken = cookieMap['serviceToken'] ?? '';
      final userId = cookieMap['userId'] ?? '';

      debugPrint('📋 WebView cookies (${cookieMap.length}): ${cookieMap.keys.join(", ")}');
      debugPrint('🔑 serviceToken=${serviceToken.isNotEmpty ? serviceToken.substring(0, serviceToken.length > 12 ? 12 : serviceToken.length) + "..." : "MISSING"}');
      debugPrint('👤 userId=$userId');

      if (serviceToken.isEmpty || userId.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未检测到登录凭据，请确认已完成登录')),
        );
        setState(() => _extracting = false);
        return;
      }

      final ssecurity = await _fetchSsecurity();

      if (!mounted) return;

      if (ssecurity.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ssecurity 获取失败，请重试')),
        );
        setState(() => _extracting = false);
        return;
      }

      widget.onLoginSuccess(serviceToken, ssecurity, userId);
    } catch (e) {
      debugPrint('❌ Extract error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('提取失败: $e')),
      );
      setState(() => _extracting = false);
    }
  }

  Future<String> _fetchSsecurity() async {
    final result = await _webCtrl?.evaluateJavascript(source: '''
(function() {
  return fetch('/pass/serviceLogin?sid=xiaomiio&_json=true&cc=%2B86', {
    credentials: 'include',
    headers: {'Accept': 'application/json, text/plain, */*'}
  }).then(function(r) { return r.text(); })
    .catch(function(e) { return 'ERR:' + e.message; });
})()
''');

    if (result == null) {
      debugPrint('❌ evaluateJavascript returned null');
      return '';
    }

    final text = result.toString();
    if (text.startsWith('ERR:')) {
      debugPrint('❌ JS fetch error: $text');
      return '';
    }

    debugPrint('📡 JS fetch raw (first 200): ${text.substring(0, text.length > 200 ? 200 : text.length)}');

    var body = text;
    if (body.startsWith('&&&START&&&')) body = body.substring(11);
    if (body.endsWith('&&&END&&&')) body = body.substring(0, body.length - 9);

    try {
      final map = jsonDecode(body) as Map<String, dynamic>;
      final ssec = map['ssecurity']?.toString() ?? '';
      debugPrint('${ssec.isNotEmpty ? "✅" : "❌"} ssecurity: ${ssec.isNotEmpty ? ssec.substring(0, ssec.length > 12 ? 12 : ssec.length) + "..." : "NOT FOUND in response"}');
      return ssec;
    } catch (e) {
      debugPrint('❌ JSON parse error: $e');
      return '';
    }
  }

  @override
  void dispose() {
    _webCtrl?.dispose();
    super.dispose();
  }
}
