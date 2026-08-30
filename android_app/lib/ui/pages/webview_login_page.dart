import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/logger/logger.dart';
import '../../utils/xiaomi_cloud/webview_login.dart';

/// 米家云登录页面 —— 纯 HTTP 实现
///
/// 带实时调试日志面板，方便诊断登录失败。
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

  // 调试面板
  final List<String> _debugLog = [];
  bool _showDebug = true;
  bool _autoScroll = true;
  final ScrollController _logScrollCtrl = ScrollController();

  void _dlog(String msg) {
    final ts = DateTime.now().toString().substring(11, 23);
    setState(() {
      _debugLog.add('[$ts] $msg');
      if (_debugLog.length > 200) _debugLog.removeAt(0);
    });
    // 自动滚到底
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScrollCtrl.hasClients) {
          _logScrollCtrl.jumpTo(_logScrollCtrl.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _ctrl.events.listen(_onEvent);
    _dlog('🌐 登录页面已加载');
    _dlog('📱 User-Agent: Android-7.1.1-1.0.0-ONEPLUS A3010');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _timer?.cancel();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _codeCtrl.dispose();
    _logScrollCtrl.dispose();
    super.dispose();
  }

  void _onEvent(LoginEvent e) {
    if (!mounted) return;
    if (e.isDebug) {
      _dlog(e.debugMessage!);
      return;
    }
    setState(() {
      _loading = e.errorMessage == null && !e.isSuccess && !e.needCode;
      _error = e.errorMessage;
      if (e.needCode) {
        _phoneHint = e.phone;
        _countdown = e.countdown ?? 0;
        _loading = false;
        _startCountdown();
        _dlog('📱 需要验证码 → 已发送到 ${e.phone}');
      }
      if (e.isSuccess) {
        _loading = false;
        _dlog('✅ 登录成功! userId=${e.userId}');
        _dlog('   serviceToken=${e.serviceToken?.substring(0, 20)}...');
        _dlog('   ssecurity=${e.ssecurity?.substring(0, 20)}...');
        widget.onLoginSuccess(e.serviceToken!, e.ssecurity!, e.userId ?? '');
      }
      if (e.errorMessage != null) {
        _dlog('❌ 错误: ${e.errorMessage}');
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
      _debugLog.clear();
    });
    _dlog('🔐 开始登录...');
    _dlog('   账号: ${_usernameCtrl.text}');
    _dlog('   密码长度: ${_passwordCtrl.text.length}');
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
    _dlog('📨 提交验证码: ${_codeCtrl.text}');
    await _ctrl.submitCode(_codeCtrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('米家云登录'),
        actions: [
          IconButton(
            icon: Icon(_showDebug ? Icons.terminal : Icons.computer),
            tooltip: '调试面板',
            onPressed: () => setState(() => _showDebug = !_showDebug),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 主表单区
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.cloud, size: 64, color: Colors.blue),
                    const SizedBox(height: 16),
                    const Text(
                      '登录你的米家账号',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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

                    // 详细错误显示
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.shade100,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red.shade300),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.error_outline,
                                    color: Colors.red),
                                const SizedBox(width: 8),
                                const Text('登录失败',
                                    style: TextStyle(
                                        color: Colors.red,
                                        fontWeight: FontWeight.bold)),
                                const Spacer(),
                                TextButton(
                                  onPressed: () {
                                    Clipboard.setData(
                                        ClipboardData(text: _error!));
                                    ScaffoldMessenger.of(context)
                                        .showSnackBar(
                                      const SnackBar(
                                          content: Text('已复制到剪贴板')),
                                    );
                                  },
                                  child: const Text('复制'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _error!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),

            // 调试日志面板（可折叠）
            if (_showDebug)
              Container(
                height: 220,
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0A0F),
                  border: Border(
                    top: BorderSide(color: Colors.grey.shade700),
                  ),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      color: const Color(0xFF1A1A2E),
                      child: Row(
                        children: [
                          const Icon(Icons.bug_report,
                              size: 14, color: Colors.orange),
                          const SizedBox(width: 4),
                          const Text('调试日志',
                              style: TextStyle(
                                  color: Colors.orange,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(width: 8),
                          Text('${_debugLog.length} lines',
                              style: const TextStyle(
                                  color: Colors.grey, fontSize: 11)),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.clear, size: 14),
                            constraints: const BoxConstraints(),
                            onPressed: () =>
                                setState(() => _debugLog.clear()),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, size: 14),
                            constraints: const BoxConstraints(),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(
                                  text: _debugLog.join('\n')));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('日志已复制到剪贴板')),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: _logScrollCtrl,
                        itemCount: _debugLog.length,
                        itemBuilder: (_, i) {
                          final line = _debugLog[i];
                          Color color = Colors.grey;
                          if (line.contains('✅') || line.contains('success')) {
                            color = Colors.green;
                          } else if (line.contains('❌') ||
                              line.contains('error') ||
                              line.contains('FAILED')) {
                            color = Colors.red;
                          } else if (line.contains('🔐') ||
                              line.contains('📱') ||
                              line.contains('📨')) {
                            color = Colors.blue;
                          } else if (line.contains('ssecurity') ||
                              line.contains('serviceToken')) {
                            color = Colors.purpleAccent;
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 1),
                            child: Text(
                              line,
                              style: TextStyle(
                                  color: color,
                                  fontSize: 11,
                                  fontFamily: 'monospace'),
                            ),
                          );
                        },
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
