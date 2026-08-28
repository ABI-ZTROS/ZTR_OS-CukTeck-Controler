import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../utils/xiaomi_cloud/webview_login.dart';
import '../../utils/logger/logger.dart';

class WebviewLoginPage extends StatefulWidget {
  final Function(String serviceToken, String ssecurity) onLoginSuccess;

  const WebviewLoginPage({
    super.key,
    required this.onLoginSuccess,
  });

  @override
  State<WebviewLoginPage> createState() => _WebviewLoginPageState();
}

class _WebviewLoginPageState extends State<WebviewLoginPage> {
  final WebviewLoginController _controller = WebviewLoginController();
  InAppWebViewController? _webController;
  bool _isLoading = true;
  bool _isInitializing = true;
  String? _errorMessage;
  String? _loginUrl;
  bool _loginCompleted = false;

  @override
  void initState() {
    super.initState();
    _controller.events.listen((event) {
      if (_loginCompleted) return;
      if (event.isSuccess) {
        _loginCompleted = true;
        AppLogger.instance
            .i('WebviewLoginPage', 'Login success: serviceToken=${event.serviceToken}');
        widget.onLoginSuccess(event.serviceToken!, event.ssecurity!);
        if (mounted) {
          Navigator.of(context).pop();
        }
      } else if (event.errorMessage != null) {
        setState(() => _errorMessage = event.errorMessage);
      }
    });
    _initLoginFlow();
  }

  Future<void> _initLoginFlow() async {
    final url = await _controller.fetchLoginUrl();
    if (url != null && mounted) {
      setState(() {
        _loginUrl = url;
        _isInitializing = false;
      });
    } else if (mounted) {
      setState(() {
        _isInitializing = false;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _clearCookiesAndReload() async {
    try {
      await _webController?.clearCache();
      await _webController?.reload();
    } catch (e) {
      AppLogger.instance.w('WebviewLoginPage', 'Clear cookies failed: $e');
    }
  }

  Widget _buildInitializingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('正在准备登录页面...'),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _errorMessage = null;
                  _isInitializing = true;
                });
                _initLoginFlow();
              },
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('米家云登录'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: '清除Cookie重新登录',
            onPressed: _clearCookiesAndReload,
          ),
        ],
      ),
      body: Stack(
        children: [
          // 初始化阶段：获取登录 URL
          if (_isInitializing) _buildInitializingView(),

          // 错误状态
          if (_errorMessage != null && !_isInitializing) _buildErrorView(),

          // WebView 加载登录页面
          if (_loginUrl != null)
            InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(_loginUrl!),
              ),
              initialSettings: InAppWebViewSettings(
                useShouldOverrideUrlLoading: true,
                mediaPlaybackRequiresUserGesture: false,
                clearCache: true,
              ),
              onWebViewCreated: (controller) {
                _webController = controller;
                AppLogger.instance.i('WebviewLoginPage', 'WebView created');
              },
              onLoadStart: (controller, url) {
                setState(() {
                  _isLoading = true;
                  _errorMessage = null;
                });
              },
              onLoadStop: (controller, url) async {
                setState(() => _isLoading = false);
                if (url != null) {
                  await _controller.onLoadStop(controller, url.toString());
                }
              },
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final policy = await _controller.onNavigation(navigationAction);
                return policy;
              },
              onReceivedError: (controller, url, error) {
                AppLogger.instance
                    .e('WebviewLoginPage', 'Received error: ${error.description}');
                setState(() {
                  _isLoading = false;
                  _errorMessage = '加载失败: ${error.description}';
                });
              },
            ),

          if (_isLoading && !_isInitializing)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}