import 'dart:async';
import 'package:flutter/material.dart';
import '../../utils/xiaomi_cloud/webview_login.dart' show XiaomiLoginController, LoginEvent;

/// 米家云登录页面 —— 纯 HTTP 实现（无 WebView）
///
/// 流程：用户名 + 密码 → HTTP serviceLoginAuth2 → 2FA 验证码对话框 → 完成
class WebviewLoginPage extends StatefulWidget {
  final Function(String serviceToken, String ssecurity, String userId) onLoginSuccess;

  const WebviewLoginPage({
    super.key,
    required this.onLoginSuccess,
  });

  @override
  State<WebviewLoginPage> createState() => _WebviewLoginPageState();
}

class _WebviewLoginPageState extends State<WebviewLoginPage> {
  final XiaomiLoginController _controller = XiaomiLoginController();
  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();
  final TextEditingController _codeCtrl = TextEditingController();

  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;
  int? _countdown;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _controller.events.listen(_onLoginEvent);
  }

  @override
  void dispose() {
    _controller.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _codeCtrl.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _onLoginEvent(LoginEvent event) {
    if (!mounted) return;
    setState(() {
      _isLoading = !event.isSuccess && event.errorMessage == null && !event.needCode;
      _errorMessage = event.errorMessage;
    });

    if (event.needCode && event.phone != null) {
      _showCodeDialog(event.phone!, event.countdown ?? 180);
    }

    if (event.isSuccess) {
      _countdownTimer?.cancel();
      _countdownTimer = null;
      widget.onLoginSuccess(event.serviceToken!, event.ssecurity!, event.userId!);
    }
  }

  Future<void> _submitLogin() async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = '请输入用户名和密码');
      return;
    }
    setState(() {
      _errorMessage = null;
      _isLoading = true;
    });
    await _controller.login(username: username, password: password);
  }

  void _showCodeDialog(String phone, int seconds) {
    _countdown = seconds;
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown != null) {
        setState(() {
          _countdown = _countdown! - 1;
          if (_countdown! <= 0) {
            _countdownTimer?.cancel();
            _countdown = null;
          }
        });
      }
    });

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('输入验证码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('验证码已发送到 $phone'),
            const SizedBox(height: 12),
            TextField(
              controller: _codeCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '6位验证码',
              ),
              onSubmitted: (_) => _submitCode(),
            ),
            if (_countdown != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '剩余 $_countdown 秒',
                  style: TextStyle(
                    color: _countdown! > 30 ? Colors.green : Colors.red,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: _isLoading ? null : _submitCode,
            child: _isLoading
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('确认'),
          ),
        ],
      ),
    );
  }

  Future<void> _submitCode() async {
    final code = _codeCtrl.text.trim();
    if (code.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入6位验证码')),
      );
      return;
    }
    Navigator.pop(context);
    setState(() => _isLoading = true);
    await _controller.submitCode(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('米家云登录')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '输入米家账号和密码',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '登录成功后将自动获取设备 beaconKey（BLE Token）',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _usernameCtrl,
              decoration: const InputDecoration(
                labelText: '手机号/邮箱',
                prefixIcon: Icon(Icons.person),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordCtrl,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: '密码',
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword
                      ? Icons.visibility_off
                      : Icons.visibility),
                  onPressed: () => setState(
                      () => _obscurePassword = !_obscurePassword),
                ),
                border: const OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submitLogin(),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error, color: Colors.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_errorMessage!,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _submitLogin,
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('登录'),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info, color: Colors.blue, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '登录凭据仅保存在设备本地安全存储中，不会上传到任何服务器。',
                      style: TextStyle(color: Colors.blue, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
