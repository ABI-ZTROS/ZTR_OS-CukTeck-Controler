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

  /// 手动跟随重定向的 GET —— 每一步都提取 Set-Cookie！
  /// Python requests 默认 allow_redirects=True，中间步骤的 cookies 都会被收集。
  /// Dart http 跟随重定向时中间 cookies 会丢失，所以我们手动处理。
  Future<http.Response> _getFollowRedirects(
    String url, {
    Map<String, String>? params,
    int maxRedirects = 10,
  }) async {
    String? currentUrl;
    http.Response? lastResp;
    int step = 0;

    while (step < maxRedirects) {
      final uri = Uri.parse(currentUrl ?? url).replace(
        queryParameters: (step == 0 && params != null) ? params : null,
      );
      final cookieHeader = _buildCookieHeader();

      final req = http.Request('GET', uri)
        ..headers['User-Agent'] = _agent
        ..headers['Cookie'] = cookieHeader
        ..followRedirects = false;

      _emitDebug('  ↳ [redirect step $step] GET ${uri.path}${uri.query.isNotEmpty ? '?' + uri.query : ''}');
      final streamed = await _httpClient.send(req);
      final resp = await http.Response.fromStream(streamed);

      // 提取这一步的 cookies！
      final setCookieHeader = resp.headers['set-cookie'] ?? '';
      if (setCookieHeader.isNotEmpty) {
        final newCookies = _extractSetCookies(setCookieHeader);
        _sessionCookies.addAll(newCookies);
        _emitDebug('    ← collected cookies: [${newCookies.keys.join(",")}]');
      } else {
        _emitDebug('    ← no Set-Cookie in this step');
      }
      _emitDebug('    → ${resp.statusCode}, ALL session=[${_sessionCookies.keys.join(",")}]');
      if (_sessionCookies.containsKey('serviceToken')) {
        _emitDebug('      serviceToken len=${_sessionCookies['serviceToken']!.length}');
      }

      lastResp = resp;

      if (resp.statusCode >= 300 &&
          resp.statusCode < 400 &&
          resp.headers['location'] != null) {
        var next = resp.headers['location']!;
        _emitDebug('    → redirecting to: ${next.substring(0, next.length > 100 ? 100 : next.length)}...');
        if (!next.startsWith('http')) {
          final baseUri = Uri.parse(currentUrl ?? url);
          next = '${baseUri.scheme}://${baseUri.host}${next}';
        }
        currentUrl = next;
        step++;
      } else {
        break;
      }
    }

    return lastResp!;
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
      _emitDebug('═══════ Step 1: serviceLogin ═══════');
      _sessionCookies['deviceId'] = _deviceId;
      _emitDebug('GET /pass/serviceLogin cookies=[sdkVersion,deviceId,userId]');

      final r1 = await _get(
        'https://account.xiaomi.com/pass/serviceLogin',
        params: {'sid': 'xiaomiio', '_json': 'true', 'cc': '+86'},
        extraCookies: {'userId': username},
      );
      final d1 = _parseXiaomiJson(r1.body);
      final sign = d1['_sign'] as String;
      final nonce = d1['nonce'] as String? ?? '';
      _emitDebug('  ↳ ${r1.statusCode} sign=${sign.substring(0, 20)}... (${sign.length} chars)');
      _emitDebug('  ↳ session cookies now: [${_sessionCookies.keys.join(",")}]');

      // Step 2
      _controller.add(LoginEvent.loading('正在验证密码...'));
      _emitDebug('═══════ Step 2: serviceLoginAuth2 ═══════');
      _emitDebug('POST /pass/serviceLoginAuth2 hash=${_passwordHash.substring(0, 8)}...');

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
        extraCookies: {'userId': username},
      );
      final d2 = _parseXiaomiJson(r2.body);
      final secStatus = d2['securityStatus'] ?? d2['secStatus'] ?? 0;

      _emitDebug('  ↳ ${r2.statusCode} code=${d2['code']} secStatus=$secStatus');
      _emitDebug('  ↳ ALL keys: [${d2.keys.join(",")}]');
      _emitDebug('  ↳ has ssecurity=${d2.containsKey('ssecurity')}');

      if (d2['code'] != 0) {
        final desc = d2['desc'] ?? d2['description'] ?? '登录失败';
        _emitDebug('❌ Step 2 FAILED: $desc');
        _emitDebug('   Full resp: ${_truncate(r2.body, 400)}');
        _controller.add(LoginEvent.error(desc));
        return;
      }

      if (secStatus == 0 && d2.containsKey('ssecurity')) {
        _emitDebug('  ✅ 无需2FA，直接拿 ssecurity');
        await _completeLogin(
          d2['ssecurity'] as String,
          d2['location'] as String,
          d2['userId']?.toString() ?? '',
          nonce,
        );
        return;
      }

      if (secStatus == 16 || secStatus == null) {
        _emitDebug('  → 需要2FA (secStatus=$secStatus)');
        await _handle2FA(d2);
        return;
      }

      _emitDebug('❌ 未知 secStatus=$secStatus');
      _controller.add(LoginEvent.error('未知登录状态 (secStatus=$secStatus)'));
    } catch (e, stackTrace) {
      _emitDebug('❌ Exception: $e');
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

    _emitDebug('═══════ 2FA 流程 ═══════');
    _emitDebug('notificationUrl=${_truncate(notifUrl, 80)}');
    _emitDebug('context=${_truncate(context, 40)}');

    // Step 3: authStart
    _emitDebug('Step 3: authStart (GET $notifUrl)');
    final r3 = await _get(notifUrl);
    _emitDebug('  ↳ ${r3.statusCode}, cookies=[${_sessionCookies.keys.join(",")}]');

    // Step 4: identity/list → 获取验证方式
    _emitDebug('Step 4: identity/list');
    final r4 = await _get('https://account.xiaomi.com/identity/list', params: {
      'sid': 'xiaomiio',
      'supportedMask': '0',
      '_locale': 'zh_CN',
      'context': context,
    });
    final d4 = _parseXiaomiJson(r4.body);
    _authFlag = d4['flag'] ?? 4;
    final maskedPhone = d4['maskedPhone'] as String? ?? '';
    _emitDebug('  ↳ ${r4.statusCode} flag=$_authFlag phone=$maskedPhone');
    _emitDebug('  ↳ session cookies: [${_sessionCookies.keys.join(",")}]');

    // Step 5
    _emitDebug('Step 5: verifyPhone GET');
    await _get(
      'https://account.xiaomi.com/identity/auth/verifyPhone',
      params: {'_flag': '$_authFlag', '_json': 'true'},
    );

    // Step 6
    _emitDebug('Step 6: sendPhoneTicket');
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
    _emitDebug('  ↳ ${r6.statusCode} code=${d6['code']} wt=$wt');

    if (d6['code'] != 0) {
      final errMsg = d6['tips']?.toString() ??
          d6['desc']?.toString() ??
          '发送验证码失败';
      _emitDebug('❌ Step 6 FAILED: code=${d6['code']} msg=$errMsg');
      _emitDebug('   Full: ${_truncate(r6.body, 300)}');
      _controller.add(LoginEvent.error('发送验证码失败($errMsg)'));
      return;
    }

    _controller.add(LoginEvent.needCode(maskedPhone, wt));
    _emitDebug('✅ SMS sent! wt=${wt}s, waiting for user...');
  }

  Future<void> submitCode(String code) async {
    if (_context == null) {
      _controller.add(LoginEvent.error('没有待处理的 2FA 请求'));
      return;
    }

    try {
      _controller.add(LoginEvent.loading('正在验证验证码...'));
      _emitDebug('═══════ Step 7: verifyPhone submit ═══════');
      _emitDebug('_authFlag=$_authFlag, code=*** (${code.length} digits)');

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
      _emitDebug('  ↳ ${r7.statusCode} code=${d7['code']} hasLocation=${d7.containsKey('location')}');
      _emitDebug('  ↳ ALL keys: [${d7.keys.join(",")}]');

      if (d7['code'] != 0 || !d7.containsKey('location')) {
        final msg = d7['desc']?.toString() ?? '验证码错误';
        _emitDebug('❌ Step 7 FAILED: $msg');
        _emitDebug('   Full: ${_truncate(r7.body, 300)}');
        _controller.add(LoginEvent.error(msg));
        return;
      }

      // Step 8
      var location = d7['location'] as String;
      if (!location.startsWith('http')) {
        location = 'https://account.xiaomi.com$location';
      }
      _emitDebug('═══════ Step 8: follow location ═══════');
      _emitDebug('GET ${_truncate(location, 80)} (WITH redirect follow!)');
      final r8 = await _getFollowRedirects(location);
      _emitDebug('  ↳ final status=${r8.statusCode}');
      _emitDebug('  ↳ FINAL cookies NOW: [${_sessionCookies.keys.join(",")}]');
      if (_sessionCookies.containsKey('serviceToken')) {
        _emitDebug('  ↳ serviceToken LEN=${_sessionCookies['serviceToken']!.length}');
      }
      if (_sessionCookies.containsKey('passToken')) {
        _emitDebug('  ↳ passToken LEN=${_sessionCookies['passToken']!.length}');
      }

      // Step 8.5: CLEAN
      _emitDebug('═══════ Step 8.5: CLEAN cookies ═══════');
      _cleanForSsecurity();
      _emitDebug('  ↳ AFTER CLEAN: [${_sessionCookies.keys.join(",")}]');

      // Step 9 — ⚠️ 必须加回 userId cookie（clean 删掉了）
      _emitDebug('═══════ Step 9: fresh serviceLogin ═══════');
      _emitDebug('  (extraCookies: userId=$_username)');
      final r9 = await _get(
        'https://account.xiaomi.com/pass/serviceLogin',
        params: {'sid': 'xiaomiio', '_json': 'true', 'cc': '+86'},
        extraCookies: {'userId': _username},
      );
      final d9 = _parseXiaomiJson(r9.body);
      final sign = d9['_sign'] as String;
      final nonce = d9['nonce'] as String? ?? '';
      _emitDebug('  ↳ ${r9.statusCode} sign len=${sign.length} nonce=$nonce');
      _emitDebug('  ↳ has ssecurity=${d9.containsKey('ssecurity')} has psecurity=${d9.containsKey('psecurity')}');
      _emitDebug('  ↳ ALL keys: [${d9.keys.join(",")}]');
      _emitDebug('  ↳ FULL BODY: ${r9.body}'); // ⚠️ 完整输出！

      // ⚠️ 关键优化：如果 Step 9 直接返回了 ssecurity，跳过 Step 10！
      if (d9.containsKey('ssecurity')) {
        _emitDebug('  🎉 Step 9 ALREADY HAS ssecurity! Skipping Step 10.');
        await _completeLogin(
          d9['ssecurity'] as String,
          d9['location'] as String? ?? '',
          d9['userId']?.toString() ?? '',
          nonce,
        );
        _context = null;
        return;
      }

      // Step 10 — THE CRITICAL ONE — ⚠️ 必须加 userId cookie
      _controller.add(LoginEvent.loading('正在完成登录...'));
      _emitDebug('═══════ Step 10: serviceLoginAuth2 (FINAL!) ═══════');
      _emitDebug('POST /pass/serviceLoginAuth2 hash=${_passwordHash.substring(0, 8)}... userId=$_username');
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
        extraCookies: {'userId': _username},
      );
      final d10 = _parseXiaomiJson(r10.body);
      _emitDebug('  ↳ ${r10.statusCode} code=${d10['code']} secStatus=${d10['securityStatus']}');
      _emitDebug('  ↳ has ssecurity=${d10.containsKey('ssecurity')} has psecurity=${d10.containsKey('psecurity')}');
      _emitDebug('  ↳ ALL keys: [${d10.keys.join(",")}]');
      _emitDebug('  ↳ FULL BODY: ${r10.body}'); // ⚠️ 完整输出！

      if (d10.containsKey('ssecurity')) {
        _emitDebug('  ✅ GOT SSECURITY! Proceeding...');
        await _completeLogin(
          d10['ssecurity'] as String,
          d10['location'] as String,
          d10['userId']?.toString() ?? '',
          nonce,
        );
      } else {
        _emitDebug('❌ Step 10 NO SSECURITY! This is the bug.');
        _emitDebug('   Full body above ↑');
        _emitDebug('   Session cookies: [${_sessionCookies.keys.join(",")}]');
        _emitDebug('   identity_session present? ${_sessionCookies.containsKey('identity_session')} len=${_sessionCookies['identity_session']?.length ?? 0}');
        _emitDebug('   passToken present? ${_sessionCookies.containsKey('passToken')} len=${_sessionCookies['passToken']?.length ?? 0}');
        _emitDebug('   serviceToken present? ${_sessionCookies.containsKey('serviceToken')} len=${_sessionCookies['serviceToken']?.length ?? 0}');
        // 打印每个 cookie 的存在情况（不含敏感值）
        _emitDebug('   ALL cookie check:');
        for (final key in _sessionCookies.keys) {
          final val = _sessionCookies[key] ?? '';
          _emitDebug('     $key = ${val.length} bytes');
        }
        _controller.add(LoginEvent.error('无法获取登录凭据（Step 10 失败）。请查看调试日志'));
      }
      _context = null;
    } catch (e, stackTrace) {
      _emitDebug('❌ Exception: $e');
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
    _emitDebug('═══════ Step 11: follow location for serviceToken ═══════');
    final nsec = 'nonce=$nonce&$ssecurity';
    final clientSign =
        base64.encode(sha1.convert(utf8.encode(nsec)).bytes);
    final fullLocation =
        '$location&clientSign=${Uri.encodeQueryComponent(clientSign)}';

    _emitDebug('GET ${_truncate(fullLocation, 100)} (WITH redirect follow!)');
    final r = await _getFollowRedirects(fullLocation);
    _emitDebug('  ↳ final status=${r.statusCode}');
    _emitDebug('  ↳ FINAL cookies: [${_sessionCookies.keys.join(",")}]');

    serviceToken = _sessionCookies['serviceToken'];
    this.ssecurity = ssecurity;
    this.userId = userId;

    if (serviceToken != null) {
      _emitDebug('  ✅ serviceToken len=${serviceToken!.length}');
    } else {
      _emitDebug('  ❌ No serviceToken in cookies! Trying body parse...');
      try {
        final body = r.body.replaceAll('&&&START&&&', '').trim();
        final j = jsonDecode(body) as Map<String, dynamic>;
        serviceToken = j['serviceToken'] as String?;
        if (serviceToken != null) {
          _emitDebug('  ✅ serviceToken found in body len=${serviceToken!.length}');
        }
      } catch (e) {
        _emitDebug('  ❌ Body parse also failed: $e');
      }
    }

    if (serviceToken == null) {
      _emitDebug('  ❌ GIVING UP — no serviceToken anywhere');
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

  void _emitDebug(String msg) {
    AppLogger.instance.d('XiaomiLogin', msg);
    _controller.add(LoginEvent.debug(msg));
  }

  void dispose() {
    _httpClient.close();
    unawaited(_controller.close());
  }
}

class LoginEvent {
  const LoginEvent.success(this.serviceToken, this.ssecurity, this.userId)
      : errorMessage = null,
        phone = null,
        countdown = null,
        debugMessage = null;
  const LoginEvent.needCode(this.phone, this.countdown)
      : errorMessage = null,
        serviceToken = null,
        ssecurity = null,
        userId = null,
        debugMessage = null;
  const LoginEvent.loading([this.errorMessage])
      : serviceToken = null,
        ssecurity = null,
        userId = null,
        phone = null,
        countdown = null,
        debugMessage = null;
  const LoginEvent.error(this.errorMessage)
      : serviceToken = null,
        ssecurity = null,
        userId = null,
        phone = null,
        countdown = null,
        debugMessage = null;
  const LoginEvent.debug(this.debugMessage)
      : serviceToken = null,
        ssecurity = null,
        userId = null,
        errorMessage = null,
        phone = null,
        countdown = null;

  final String? serviceToken;
  final String? ssecurity;
  final String? userId;
  final String? errorMessage;
  final String? phone;
  final int? countdown;
  final String? debugMessage;

  bool get isSuccess => serviceToken != null;
  bool get needCode => phone != null;
  bool get isDebug => debugMessage != null;
}
