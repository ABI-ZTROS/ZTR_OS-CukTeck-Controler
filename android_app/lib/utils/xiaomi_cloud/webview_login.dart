import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../logger/logger.dart';

/// 米家云登录控制器 —— 纯 HTTP 实现
///
/// 严格参照 Python 参照项目 xiaomi_cloud.py 的每一步：
///   1. 所有请求 followRedirects=false（和 Python requests 一致）
///   2. Step 1 带 userId=username cookie（和 Python 一致）
///   3. _parseXiaomiJson 加 .strip()（和 Python 一致）
///   4. submitCode 动态用 Step 4 的 flag（不硬编码）
class XiaomiLoginController {
  final StreamController<LoginEvent> _controller = StreamController.broadcast();
  final http.Client _httpClient = http.Client();

  Stream<LoginEvent> get events => _controller.stream;

  String _username = '';
  String _passwordHash = '';
  String _agent = '';
  String _deviceId = '';

  String? serviceToken;
  String? ssecurity;
  String? userId;
  String? passToken;
  bool _successReported = false;

  String? _context;
  int _authFlag = 4; // Step 4 返回的验证方式（4=手机, 8=邮箱）

  bool get isLoggedIn => serviceToken != null && ssecurity != null;

  XiaomiLoginController() {
    final rand = Random.secure();
    final suffix1 = String.fromCharCodes(
      List.generate(11, (_) => rand.nextInt(26) + 65),
    );
    final suffix2 = String.fromCharCodes(
      List.generate(6, (_) => rand.nextInt(26) + 65),
    );
    _agent = 'Android-7.1.1-1.0.0-ONEPLUS A3010-136-$suffix1 MIIO/$suffix2';
    _deviceId = '${String.fromCharCodes(List.generate(16, (_) {
      final c = rand.nextInt(36);
      return c < 10 ? c + 48 : c - 10 + 97;
    }))}';
  }

  /// 从响应体解析小米 JSON —— 和 Python 完全一致
  Map<String, dynamic> _parseXiaomiJson(String body) {
    // Python: text.replace("&&&START&&&", "").strip()
    var text = body.replaceAll('&&&START&&&', '').trim();
    if (text.endsWith('&&&END&&&')) {
      text = text.substring(0, text.length - '&&&END&&&'.length);
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  static String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = md5.convert(bytes);
    return digest.toString().toUpperCase();
  }

  // ===== Cookie 管理 =====

  final Map<String, String> _sessionCookies = {};

  static const String _sdkVersion = 'accountsdk-18.8.15';

  Map<String, String> _extractSetCookies(String raw) {
    final result = <String, String>{};
    if (raw.isEmpty) return result;
    final cookiePattern = RegExp(r'([a-zA-Z_][a-zA-Z0-9_\-]*)=([^;,]+?)[;,\s]');
    const attrs = {
      'domain', 'path', 'expires', 'max-age', 'secure', 'httponly', 'samesite'
    };
    for (final m in cookiePattern.allMatches(raw)) {
      final name = m.group(1)!;
      final value = m.group(2)!;
      if (!attrs.contains(name.toLowerCase())) {
        result[name] = value;
      }
    }
    AppLogger.instance.d('XiaomiLogin',
        '  cookies from resp: ${result.keys.join(",")}');
    return result;
  }

  String _buildCookieHeader() {
    // sdkVersion 必须总是带上（跨域 cookie，不依赖 domain 匹配）
    final all = <String, String>{'sdkVersion': _sdkVersion, ..._sessionCookies};
    return all.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 关键：清理 cookies 到只剩 auth cookies（为了让 auth2 返回 ssecurity）
  void _cleanForSsecurity() {
    const keepNames = {
      'identity_session', 'passToken', 'passInfo', 'pass_ua',
      'deviceId', 'uLocale',
    };
    final kept = <String, String>{
      for (final k in keepNames)
        if (_sessionCookies.containsKey(k)) k: _sessionCookies[k]!,
    };
    _sessionCookies
      ..clear()
      ..addAll(kept);
    AppLogger.instance.i('XiaomiLogin',
        '🧹 Cleaned cookies: keep=[${_sessionCookies.keys.join(",")}]');
  }

  // ===== HTTP helpers —— 全部 followRedirects=false =====

  Future<http.Response> _get(
    String url, {
    Map<String, String>? params,
    Map<String, String>? extraCookies,
  }) async {
    final uri = Uri.parse(url).replace(queryParameters: params);
    final cookies = <String, String>{..._sessionCookies};
    if (extraCookies != null) cookies.addAll(extraCookies);
    final cookieHeader = _buildCookieHeaderWith(cookies);

    final req = http.Request('GET', uri)
      ..headers['User-Agent'] = _agent
      ..headers['Cookie'] = cookieHeader
      ..followRedirects = false; // ⚠️ 关键：Python requests 默认 allow_redirects=False

    AppLogger.instance.d('XiaomiLogin',
        'GET ${uri.path} cookies=[${cookies.keys.join(",")}]');

    final streamed = await _httpClient.send(req);
    final resp = await http.Response.fromStream(streamed);

    // 提取新 cookies
    final setCookieHeader = resp.headers['set-cookie'] ?? '';
    _sessionCookies.addAll(_extractSetCookies(setCookieHeader));

    AppLogger.instance.d('XiaomiLogin',
        '  ↳ ${resp.statusCode}, body=${_truncate(resp.body, 200)}');
    return resp;
  }

  Future<http.Response> _post(
    String url, {
    Map<String, String>? params,
    Map<String, String>? extraCookies,
  }) async {
    final uri = Uri.parse(url);
    final cookies = <String, String>{..._sessionCookies};
    if (extraCookies != null) cookies.addAll(extraCookies);
    final cookieHeader = _buildCookieHeaderWith(cookies);

    final body = params?.entries
            .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
            .join('&') ??
        '';

    final req = http.Request('POST', uri)
      ..headers['User-Agent'] = _agent
      ..headers['Content-Type'] = 'application/x-www-form-urlencoded'
      ..headers['Cookie'] = cookieHeader
      ..body = body
      ..followRedirects = false; // ⚠️ 关键

    AppLogger.instance.d('XiaomiLogin',
        'POST ${uri.path} cookies=[${cookies.keys.join(",")}] body=${_truncate(body, 100)}');

    final streamed = await _httpClient.send(req);
    final resp = await http.Response.fromStream(streamed);

    final setCookieHeader = resp.headers['set-cookie'] ?? '';
    _sessionCookies.addAll(_extractSetCookies(setCookieHeader));

    AppLogger.instance.d('XiaomiLogin',
        '  ↳ ${resp.statusCode}, body=${_truncate(resp.body, 300)}');
    return resp;
  }

  String _buildCookieHeaderWith(Map<String, String> cookies) {
    final all = <String, String>{'sdkVersion': _sdkVersion, ...cookies};
    return all.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  static String _truncate(String s, int max) {
    return s.length > max ? '${s.substring(0, max)}...' : s;
  }

  // ===== 登录主流程 =====

  Future<void> login({
    required String username,
    required String password,
  }) async {
    _username = username;
    _passwordHash = _hashPassword(password);
    _successReported = false;
    _controller.add(LoginEvent.loading('正在初始化...'));

    try {
      // Step 1: serviceLogin → 获取 _sign
      // Python: self._session.get(url, cookies={"userId": self._username})
      AppLogger.instance.i('XiaomiLogin', 'Step 1: serviceLogin');
      _sessionCookies['deviceId'] = _deviceId;

      final r1 = await _get(
        'https://account.xiaomi.com/pass/serviceLogin',
        params: {'sid': 'xiaomiio', '_json': 'true', 'cc': '+86'},
        extraCookies: {'userId': username}, // ⚠️ 和 Python 一致！
      );
      final d1 = _parseXiaomiJson(r1.body);
      final sign = d1['_sign'] as String;
      final nonce = d1['nonce'] as String? ?? '';
      AppLogger.instance.d('XiaomiLogin', 'Got _sign, nonce=$nonce');

      // Step 2: serviceLoginAuth2 → 密码验证
      _controller.add(LoginEvent.loading('正在验证密码...'));
      AppLogger.instance.i('XiaomiLogin', 'Step 2: serviceLoginAuth2');

      final r2 = await _post(
        'https://account.xiaomi.com/pass/serviceLoginAuth2',
        params: {
          'sid': 'xiaomiio',
          'hash': _passwordHash,
          'callback': 'https://sts.api.io.mi.com/sts',
          'qs': '%3Fsid%3Dxiaomiio%26_json%3Dtrue',
          'user': username,
          '_sign': sign,
          '_json': 'true',
          'cc': '+86',
        },
        extraCookies: {'userId': username}, // ⚠️ 和 Python 一致
      );
      final d2 = _parseXiaomiJson(r2.body);
      final secStatus = d2['securityStatus'] ?? d2['secStatus'] ?? 0;

      AppLogger.instance.i('XiaomiLogin',
          'Auth2: code=${d2['code']}, secStatus=$secStatus, '
          'hasSsecurity=${d2.containsKey('ssecurity')}');

      if (d2['code'] != 0) {
        final desc = d2['desc'] ?? d2['description'] ?? '登录失败';
        AppLogger.instance.e('XiaomiLogin', 'Auth2 FAILED: $desc');
        _controller.add(LoginEvent.error(desc));
        return;
      }

      if (secStatus == 0 && d2.containsKey('ssecurity')) {
        // ✅ 无需 2FA，直接成功
        await _completeLogin(
          d2['ssecurity'] as String,
          d2['location'] as String,
          d2['userId']?.toString() ?? '',
          nonce,
        );
        return;
      }

      if (secStatus == 16 || secStatus == null) {
        // 需要 2FA
        await _handle2FA(d2);
        return;
      }

      _controller.add(LoginEvent.error('未知登录状态 (secStatus=$secStatus)'));
    } catch (e, stackTrace) {
      AppLogger.instance.e('XiaomiLogin', 'Login error: $e', stackTrace);
      _controller.add(LoginEvent.error('网络错误: $e'));
    }
  }

  /// 2FA 流程
  Future<void> _handle2FA(Map<String, dynamic> d2) async {
    final notifUrl = d2['notificationUrl'] as String;
    final uri = Uri.parse(notifUrl);
    final context = uri.queryParameters['context'] ?? '';
    _context = context;

    AppLogger.instance.i('XiaomiLogin',
        'Need 2FA, context=${_truncate(context, 40)}');

    // Step 3: authStart
    final r3 = await _get(notifUrl);
    AppLogger.instance.d('XiaomiLogin',
        'Step 3 authStart: status=${r3.statusCode}');

    // Step 4: identity/list → 获取验证方式
    final r4 = await _get('https://account.xiaomi.com/identity/list', params: {
      'sid': 'xiaomiio',
      'supportedMask': '0',
      '_locale': 'zh_CN',
      'context': context,
    });
    final d4 = _parseXiaomiJson(r4.body);
    _authFlag = d4['flag'] ?? 4; // 保存，submitCode 要用！
    final maskedPhone = d4['maskedPhone'] as String? ?? '';
    AppLogger.instance.i('XiaomiLogin',
        '2FA method flag=$_authFlag, phone=$maskedPhone');

    // Step 5: verifyPhone（GET）
    await _get(
      'https://account.xiaomi.com/identity/auth/verifyPhone',
      params: {'_flag': '$_authFlag', '_json': 'true'},
    );

    // Step 6: sendPhoneTicket
    final r6 = await _post(
      'https://account.xiaomi.com/identity/auth/sendPhoneTicket',
      params: {
        'retry': '0',
        'icode': '',
        '_json': 'true',
        'context': context,
        'sid': 'xiaomiio',
      },
    );
    final d6 = _parseXiaomiJson(r6.body);
    final wt = d6['data']?['wt'] as int? ?? 0;

    if (d6['code'] != 0) {
      final errMsg = d6['tips']?.toString() ??
          d6['desc']?.toString() ??
          '发送验证码失败';
      AppLogger.instance.e('XiaomiLogin',
          'sendPhoneTicket FAILED: code=${d6['code']}, msg=$errMsg');
      _controller.add(LoginEvent.error('发送验证码失败($errMsg)'));
      return;
    }

    _controller.add(LoginEvent.needCode(maskedPhone, wt));
    AppLogger.instance.i('XiaomiLogin', 'SMS sent! wt=${wt}s');
  }

  Future<void> submitCode(String code) async {
    if (_context == null) {
      _controller.add(LoginEvent.error('没有待处理的 2FA 请求'));
      return;
    }

    try {
      _controller.add(LoginEvent.loading('正在验证验证码...'));

      // Step 7: POST verifyPhone — 提交验证码
      // ⚠️ 用 _authFlag（从 Step 4 动态获取），不是硬编码！
      final r7 = await _post(
        'https://account.xiaomi.com/identity/auth/verifyPhone',
        params: {
          '_flag': '$_authFlag',
          'ticket': code,
          'trust': 'false',
          '_json': 'true',
          '_dc': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      );
      final d7 = _parseXiaomiJson(r7.body);
      AppLogger.instance.i('XiaomiLogin',
          'Step 7 verifyPhone: code=${d7['code']}, '
          'hasLocation=${d7.containsKey('location')}, '
          'desc=${d7['desc'] ?? ""}');

      if (d7['code'] != 0 || !d7.containsKey('location')) {
        final msg = d7['desc']?.toString() ?? '验证码错误';
        _controller.add(LoginEvent.error(msg));
        return;
      }

      // Step 8: Follow location — 更新 identity_session / passToken
      var location = d7['location'] as String;
      if (!location.startsWith('http')) {
        location = 'https://account.xiaomi.com$location';
      }
      final r8 = await _get(location);
      AppLogger.instance.i('XiaomiLogin',
          'Step 8 followLocation: status=${r8.statusCode}, '
          'cookies=${_sessionCookies.keys.join(",")}');

      // Step 8.5: ⚠️ 清理 cookies！关键！否则 auth2 只返回 psecurity
      _cleanForSsecurity();

      // Step 9: serviceLogin → fresh _sign
      final r9 = await _get(
        'https://account.xiaomi.com/pass/serviceLogin',
        params: {'sid': 'xiaomiio', '_json': 'true', 'cc': '+86'},
      );
      final d9 = _parseXiaomiJson(r9.body);
      final sign = d9['_sign'] as String;
      final nonce = d9['nonce'] as String? ?? '';
      AppLogger.instance.i('XiaomiLogin',
          'Step 9 fresh sign: ${_truncate(sign, 20)}..., '
          'hasSsec=${d9.containsKey('ssecurity')}, '
          'hasPsec=${d9.containsKey('psecurity')}');

      // Step 10: 关键！重新 auth2 → 拿 ssecurity
      _controller.add(LoginEvent.loading('正在完成登录...'));
      final r10 = await _post(
        'https://account.xiaomi.com/pass/serviceLoginAuth2',
        params: {
          'sid': 'xiaomiio',
          'hash': _passwordHash,
          'callback': 'https://sts.api.io.mi.com/sts',
          'qs': '%3Fsid%3Dxiaomiio%26_json%3Dtrue',
          'user': _username,
          '_sign': sign,
          '_json': 'true',
          'cc': '+86',
        },
      );
      final d10 = _parseXiaomiJson(r10.body);
      AppLogger.instance.i('XiaomiLogin',
          'Step 10 auth2: code=${d10['code']}, '
          'secStatus=${d10['securityStatus']}, '
          'hasSsec=${d10.containsKey('ssecurity')}');

      if (d10.containsKey('ssecurity')) {
        await _completeLogin(
          d10['ssecurity'] as String,
          d10['location'] as String,
          d10['userId']?.toString() ?? '',
          nonce,
        );
      } else {
        AppLogger.instance.e('XiaomiLogin',
            'Step 10 no ssecurity! Full resp: ${_truncate(r10.body, 500)}');
        _controller.add(LoginEvent.error('无法获取登录凭据，请重试'));
      }
      _context = null;
    } catch (e, stackTrace) {
      AppLogger.instance.e('XiaomiLogin', 'Submit code error: $e', stackTrace);
      _controller.add(LoginEvent.error('验证失败: $e'));
    }
  }

  Future<void> _completeLogin(
    String ssecurity,
    String location,
    String userId,
    String nonce,
  ) async {
    AppLogger.instance.i('XiaomiLogin',
        'Completing login: ssec=${_truncate(ssecurity, 8)}');

    // Python: follow location, then serviceToken 自动在 cookies 里
    final nsec = 'nonce=$nonce&$ssecurity';
    final clientSign =
        base64.encode(sha1.convert(utf8.encode(nsec)).bytes);
    final fullLocation =
        '$location&clientSign=${Uri.encodeQueryComponent(clientSign)}';

    final r = await _get(fullLocation);
    AppLogger.instance.i('XiaomiLogin',
        'completeLogin: status=${r.statusCode}, '
        'final cookies=${_sessionCookies.keys.join(",")}');

    serviceToken = _sessionCookies['serviceToken'];
    this.ssecurity = ssecurity;
    this.userId = userId;

    if (serviceToken == null) {
      // fallback: try parse response body
      try {
        final body = r.body.replaceAll('&&&START&&&', '').trim();
        final j = jsonDecode(body) as Map<String, dynamic>;
        serviceToken = j['serviceToken'] as String?;
      } catch (_) {}
    }

    if (serviceToken == null) {
      AppLogger.instance.e('XiaomiLogin',
          '❌ No serviceToken! Cookies: ${_sessionCookies.keys}');
      _controller.add(LoginEvent.error('无法获取 serviceToken'));
      return;
    }

    _emitSuccess();
  }

  void _emitSuccess() {
    if (_successReported) return;
    _successReported = true;
    AppLogger.instance.i('XiaomiLogin',
        '✅ LOGIN SUCCESS userId=$userId, '
        'ssecurity=${_truncate(ssecurity!, 8)}, '
        'serviceToken=${_truncate(serviceToken!, 8)}');
    _controller
        .add(LoginEvent.success(serviceToken!, ssecurity!, userId!));
  }

  void dispose() {
    _httpClient.close();
    unawaited(_controller.close());
  }
}

class LoginEvent {
  const LoginEvent.success(this.serviceToken, this.ssecurity, this.userId)
      : errorMessage = null, phone = null, countdown = null;
  const LoginEvent.needCode(this.phone, this.countdown)
      : errorMessage = null,
        serviceToken = null,
        ssecurity = null,
        userId = null;
  const LoginEvent.loading([this.errorMessage])
      : serviceToken = null,
        ssecurity = null,
        userId = null,
        phone = null,
        countdown = null;
  const LoginEvent.error(this.errorMessage)
      : serviceToken = null,
        ssecurity = null,
        userId = null,
        phone = null,
        countdown = null;

  final String? serviceToken;
  final String? ssecurity;
  final String? userId;
  final String? errorMessage;
  final String? phone;
  final int? countdown;

  bool get isSuccess => serviceToken != null;
  bool get needCode => phone != null;
}
