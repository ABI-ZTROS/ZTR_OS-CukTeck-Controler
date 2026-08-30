import 'dart:async';

import 'package:flutter/material.dart';
import '../../utils/xiaomi_cloud/webview_login.dart';

/// 米家云登录页面 —— 纯 HTTP 实现
///
/// 用户输入账号密码，走 HTTP API 登录流程：
///   密码 → serviceLoginAuth2 → (2FA 验证码) → ssecurity + serviceToken
///
/// 依赖：[XiaomiLoginController]（纯 HTTP，不需要 WebView）
class WebviewLoginPage extends StatefulWidget {
  final Function(String serviceToken, String ssecurity, String userId)
      onLoginSuccess;

  const WebviewLoginPage({super.key, required this.onLoginSuccess});

  @override
  State<WebviewLoginPage> createState() => _WebviewLoginPageState();
}

class _WebviewLoginPageState extends State<WebviewLoginPage> {
  final _ctrl = XiaomiLoginController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();

  bool _loading = false;
  String? _error;
  String? _phoneHint;
  int _countdown = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ctrl.events.listen(_onEvent);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _timer?.cancel();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _onEvent(LoginEvent e) {
    if (!mounted) return;
    setState(() {
      _loading = e.errorMessage == null && !e.isSuccess && !e.needCode;
      _error = e.errorMessage;
      if (e.needCode) {
        _phoneHint = e.phone;
        _countdown = e.countdown ?? 0;
        _loading = false;
        _startCountdown();
      }
      if (e.isSuccess) {
        _loading = false;
        widget.onLoginSuccess(e.serviceToken!, e.ssecurity!, e.userId ?? '');
      }
    });
  }

  void _startCountdown() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_countdown <= 0) {
        t.cancel();
        return;
      }
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _countdown--);
    });
  }

  Future<void> _login() async {
    if (_usernameCtrl.text.isEmpty || _passwordCtrl.text.isEmpty) {
      setState(() => _error = '请输入账号和密码');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    await _ctrl.login(
      username: _usernameCtrl.text.trim(),
      password: _passwordCtrl.text,
    );
  }

  Future<void> _submitCode() async {
    if (_codeCtrl.text.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _ctrl.submitCode(_codeCtrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('米家云登录')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.cloud_login, size: 64, color: Colors.blue),
              const SizedBox(height: 16),
              const Text(
                '登录你的米家账号',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),

              // 用户名密码表单
              if (_phoneHint == null) ...[
                TextField(
                  controller: _usernameCtrl,
                  decoration: const InputDecoration(
                    labelText: '账号 (手机号/邮箱)',
                    prefixIcon: Icon(Icons.person),
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.text,
                  enabled: !_loading,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordCtrl,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    prefixIcon: Icon(Icons.lock),
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                  enabled: !_loading,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _loading ? null : _login,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                  ),
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('登录'),
                ),
              ],

              // 2FA 验证码表单
              if (_phoneHint != null) ...[
                Text(
                  '验证码已发送到 $_phoneHint',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _codeCtrl,
                  decoration: const InputDecoration(
                    labelText: '6 位验证码',
                    prefixIcon: Icon(Icons.sms),
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  enabled: !_loading,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _loading ? null : _submitCode,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                  ),
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Text(_countdown > 0
                          ? '提交验证码 ($_countdown)'
                          : '提交验证码'),
                ),
              ],

              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 24),
              Text(
                '提示：登录成功后，凭证会自动保存并可一键导出到 Windows 端',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
