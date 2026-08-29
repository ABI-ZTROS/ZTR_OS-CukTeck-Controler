import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../logger/logger.dart';

/// 米家云登录控制器 —— 纯 HTTP 实现
///
/// 完整登录流程（严格参照 xiaomi_cloud.py + 实测验证）：
///
/// [密码登录]
///   1. serviceLogin?sid=xiaomiio&_json=true → 获取 _sign, nonce, location
///   2. serviceLoginAuth2（MD5(password).toUpperCase() 作为 hash）：
///      → code=0, secStatus=0 → 直接成功！拿 ssecurity + location
///      → code=0, secStatus=16 → 需要 2FA！走下面流程
///
/// [2FA 流程]（secStatus=16 时）
///   3. identity/list → 确定验证方式（flag=4 手机, flag=8 邮箱）
///   4. identity/auth/verifyPhone → 触发验证
///   5. identity/auth/sendPhoneTicket → 发送短信验证码
///   6. 用户输入验证码
///   7. POST identity/auth/verifyPhone（ticket=验证码） → 2FA 通过
///   8. 重新 serviceLoginAuth2（fresh _sign + 密码 hash）→ 拿 ssecurity
///
/// [完成登录]
///   9. 跟随 location URL（加 clientSign）→ 获取 serviceToken
///  10. ssecurity + serviceToken → API 全通！
///
/// 根因说明：
///   serviceLogin（未登录）→ 返回 psecurity（部分令牌）→ 签名失败！
///   serviceLoginAuth2（已认证）→ 返回 ssecurity（完整令牌）→ 签名正确！
///   2FA 通过后必须重新调 serviceLoginAuth2（带密码 hash）才能拿 ssecurity！
class XiaomiLoginController {
  final StreamController<LoginEvent> _controller = StreamController.broadcast();
  final http.Client _httpClient = http.Client();

  Stream<LoginEvent> get events => _controller.stream;

  String _username = '';
  String _passwordHash = ''; // MD5(password).toUpperCase()
  String _agent = '';
  String _deviceId = '';

  String? serviceToken;
  String? ssecurity;
  String? userId;
  String? passToken;
  bool _successReported = false;

  String? _context; // 2FA context

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
      return c < 10 ? c + 48 : c - 10 + 97; // 0-9a-z
    }))}';
  }

  /// 从响应体中解析小米 JSON
  Map<String, dynamic> _parseXiaomiJson(String body) {
    var text = body;
    if (text.startsWith('&&&START&&&')) {
      text = text.substring('&&&START&&&'.length);
    }
    if (text.endsWith('&&&END&&&')) {
      text = text.substring(0, text.length - '&&&END&&&'.length);
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// 计算密码 hash：MD5(password).toUpperCase()
  static String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = md5.convert(bytes);
    return digest.toString().toUpperCase();
  }


  /// 把 response 的 Set-Cookie 头提取为 Map
  ///
  /// http package 会把多个同名 Set-Cookie 头用逗号 join，
  /// 但 cookie 值里不含逗号，Expires 属性里含逗号（如 "Sat, 12 Sep 2026"），
  /// 所以用正则直接匹配 "key=value" 模式（值终止于 ; 或 ,）。
  Map<String, String> _extractSetCookies(http.Response response) {
    final result = <String, String>{};
    final raw = response.headers['set-cookie'] ?? '';
    if (raw.isEmpty) return result;
    // 匹配 cookie 名值对：name=value（终止于 ; , 或末尾）
    final cookiePattern = RegExp(r'([a-zA-Z_][a-zA-Z0-9_\-]*)=([^;,]+?)[;,\s]');
    for (final m in cookiePattern.allMatches(raw)) {
      final name = m.group(1)!;
      final value = m.group(2)!;
      // 跳过 Set-Cookie 属性（Domain, Path, Expires 等）
      const attrs = {'domain', 'path', 'expires', 'max-age', 'secure', 'httponly', 'samesite'};
      if (!attrs.contains(name.toLowerCase())) {
        result[name] = value;
      }
    }
    AppLogger.instance.d('XiaomiLogin',
        '_extractSetCookies: found ${result.length} cookies: ${result.keys.join(", ")}');
    return result;
  }

  /// 合并 cookies（保留已有 + 添加新的）
  final Map<String, String> _sessionCookies = {};

  /// ⚠️ 关键：sdkVersion cookie — 标记请求来自 MI SDK，让服务器返回 ssecurity 而不是 psecurity
  static const String _sdkVersion = 'accountsdk-18.8.15';

  Future<http.Response> _get(String url, {Map<String, String>? params}) async {
    final uri = Uri.parse(url).replace(queryParameters: params);
    final headers = <String, String>{'User-Agent': _agent};
    headers['Cookie'] = _buildCookieHeader();
    AppLogger.instance.d('XiaomiLogin',
        'GET ${uri.path} cookies=[${_sessionCookies.keys.join(",")}]');
    final resp = await _httpClient.get(uri, headers: headers);
    _sessionCookies.addAll(_extractSetCookies(resp));
    AppLogger.instance.d('XiaomiLogin',
        '  ↳ ${resp.statusCode}, body=${resp.body.substring(0, resp.body.length > 200 ? 200 : resp.body.length)}');
    return resp;
  }

  Future<http.Response> _post(String url, {Map<String, String>? params}) async {
    final uri = Uri.parse(url);
    final headers = <String, String>{
      'User-Agent': _agent,
      'Content-Type': 'application/x-www-form-urlencoded',
    };
    headers['Cookie'] = _buildCookieHeader();
    final body = params?.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&') ?? '';
    AppLogger.instance.d('XiaomiLogin',
        'POST ${uri.path} cookies=[${_sessionCookies.keys.join(",")}] body=${body.substring(0, body.length > 100 ? 100 : body.length)}');
    final resp = await _httpClient.post(uri, headers: headers, body: body);
    _sessionCookies.addAll(_extractSetCookies(resp));
    AppLogger.instance.d('XiaomiLogin',
        '  ↳ ${resp.statusCode}, body=${resp.body.substring(0, resp.body.length > 300 ? 300 : resp.body.length)}');
    return resp;
  }

  /// 构建 Cookie header（始终包含 sdkVersion，它是跨域 cookie）
  String _buildCookieHeader() {
    final all = <String, String>{'sdkVersion': _sdkVersion, ..._sessionCookies};
    return all.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// ⚠️ 关键：清理 cookies 到最小集合，只为拿 ssecurity 做 auth2 做准备
  ///
  /// 根据 Python 实测，serviceLoginAuth2 在同时带 userId/serviceToken cookie 时，
  /// 服务器会认为"已登录"，只返回 psecurity 而不返回 ssecurity。
  /// 正确做法：只保留 auth cookies（不带 userId/serviceToken），让 auth2 返回 ssecurity。
  void _cleanForSsecurity() {
    final keep = <String>{};
    // 先保存需要保留的值
    final toKeep = <String, String>{};
    for (final name in ['identity_session', 'passToken', 'passInfo', 'pass_ua', 'deviceId', 'uLocale']) {
      if (_sessionCookies.containsKey(name)) {
        toKeep[name] = _sessionCookies[name]!;
        keep.add(name);
      }
    }
    // 清空
    _sessionCookies.clear();
    // 只放保留的
    _sessionCookies.addAll(toKeep);
    AppLogger.instance.i('XiaomiLogin',
        '🧹 Cleaned cookies for ssecurity fetch: keep=[${_sessionCookies.keys.join(",")}]');
  }

  /// 开始登录流程
  Future<void> login({required String username, required String password}) async {
    _username = username;
    _passwordHash = _hashPassword(password);
    _successReported = false;
    _controller.add(LoginEvent.loading('正在初始化...'));

    try {
      // Step 1: serviceLogin → 获取 _sign
      AppLogger.instance.i('XiaomiLogin', 'Step 1: serviceLogin');
      _sessionCookies['deviceId'] = _deviceId;
      final r1 = await _get('https://account.xiaomi.com/pass/serviceLogin',
          params: {'sid': 'xiaomiio', '_json': 'true'});
      final d1 = _parseXiaomiJson(r1.body);
      final sign = d1['_sign'] as String;
      final nonce = d1['nonce'] as String? ?? '';
      AppLogger.instance.d('XiaomiLogin', 'Got _sign, nonce=$nonce');

      // Step 2: serviceLoginAuth2 → 密码登录
      _controller.add(LoginEvent.loading('正在验证密码...'));
      AppLogger.instance.i('XiaomiLogin', 'Step 2: serviceLoginAuth2');

      final r2 = await _post('https://account.xiaomi.com/pass/serviceLoginAuth2',
          params: {
            'sid': 'xiaomiio',
            'hash': _passwordHash,
            'callback': 'https://sts.api.io.mi.com/sts',
            'qs': '%3Fsid%3Dxiaomiio%26_json%3Dtrue',
            'user': username,
            '_sign': sign,
            '_json': 'true',
            'cc': '+86',
          });
      final d2 = _parseXiaomiJson(r2.body);
      final secStatus = d2['securityStatus'] ?? d2['secStatus'] ?? 0;
      AppLogger.instance.i('XiaomiLogin',
          'Auth2: code=${d2['code']}, secStatus=$secStatus, hasSsecurity=${d2.containsKey('ssecurity')}');

      if (d2['code'] != 0) {
        _controller.add(LoginEvent.error(
            d2['desc'] ?? d2['message'] ?? '登录失败'));
        return;
      }

      if (secStatus == 0 && d2.containsKey('ssecurity')) {
        // ✅ 无需 2FA，直接成功！
        await _completeLogin(d2['ssecurity'] as String, d2['location'] as String,
            d2['userId']?.toString() ?? '', nonce);
        return;
      }

      // secStatus == 16 → 需要 2FA
      if (secStatus == 16 || secStatus == null) {
        await _handle2FA(d2);
        return;
      }

      _controller.add(LoginEvent.error('未知登录状态'));
    } catch (e, stackTrace) {
      AppLogger.instance.e('XiaomiLogin', 'Login error: $e', stackTrace);
      _controller.add(LoginEvent.error('网络错误: $e'));
    }
  }

  /// 处理 2FA 流程
  Future<void> _handle2FA(Map<String, dynamic> d2) async {
    final notifUrl = d2['notificationUrl'] as String;
    final uri = Uri.parse(notifUrl);
    final context = uri.queryParameters['context'] ?? '';
    _context = context;

    AppLogger.instance.i('XiaomiLogin', 'Need 2FA, context=${context.substring(0, 40)}...');

    // Step 3: Open authStart
    await _get(notifUrl);

    // Step 4: identity/list → 确定验证方式
    final r4 = await _get('https://account.xiaomi.com/identity/list', params: {
      'sid': 'xiaomiio',
      'supportedMask': '0',
      '_locale': 'zh_CN',
      'context': context,
    });
    final d4 = _parseXiaomiJson(r4.body);
    final flag = d4['flag'] ?? 4;
    final maskedPhone = d4['maskedPhone'] as String? ?? '';
    AppLogger.instance.i('XiaomiLogin', '2FA method flag=$flag, phone=$maskedPhone');

    // Step 5: verifyPhone
    await _get('https://account.xiaomi.com/identity/auth/verifyPhone',
        params: {'_flag': '$flag', '_json': 'true'});

    // Step 6: sendPhoneTicket → 发送短信（带上 context 和 sid）
    final r6 = await _post('https://account.xiaomi.com/identity/auth/sendPhoneTicket',
        params: {
          'retry': '0',
          'icode': '',
          '_json': 'true',
          'context': context,
          'sid': 'xiaomiio',
        });
    final d6 = _parseXiaomiJson(r6.body);
    final wt = d6['data']?['wt'] as int? ?? 0;

    if (d6['code'] != 0) {
      final desc = d6['desc'] ?? d6['message'] ?? '';
      final tips = d6['tips'] ?? '';
      final errMsg = tips.isNotEmpty ? tips : (desc.isNotEmpty ? desc : '未知错误');
      AppLogger.instance.e('XiaomiLogin',
          'sendPhoneTicket FAILED: code=${d6['code']}, desc=$desc, tips=$tips');
      _controller.add(LoginEvent.error('发送验证码失败($errMsg)'));
      return;
    }

    // 通知 UI 显示验证码输入框
    _controller.add(LoginEvent.needCode(maskedPhone, wt));
    AppLogger.instance.i('XiaomiLogin', 'SMS sent! wt=${wt}s');
  }

  /// 用户输入验证码后调用
  Future<void> submitCode(String code) async {
    if (_context == null) {
      _controller.add(LoginEvent.error('没有待处理的 2FA 请求'));
      return;
    }

    try {
      _controller.add(LoginEvent.loading('正在验证验证码...'));

      // Step 7: POST verifyPhone → 提交验证码
      final r7 = await _post('https://account.xiaomi.com/identity/auth/verifyPhone',
          params: {
            '_flag': '4',
            'ticket': code,
            'trust': 'false',
            '_json': 'true',
            '_dc': DateTime.now().millisecondsSinceEpoch.toString(),
          });
      final d7 = _parseXiaomiJson(r7.body);
      AppLogger.instance.i('XiaomiLogin', 'Submit code: code=${d7['code']}, hasLoc=${d7.containsKey('location')}');

      if (d7['code'] != 0 || !d7.containsKey('location')) {
        _controller.add(LoginEvent.error('验证码错误'));
        return;
      }

      // Step 8: Follow location → 会设 identity_session 更新 + passToken + serviceToken
      var location = d7['location'] as String;
      if (!location.startsWith('http')) {
        location = 'https://account.xiaomi.com$location';
      }
      await _get(location);

      // ⚠️ Step 8.5: 清理 cookies！关键！否则 auth2 只返回 psecurity 不返回 ssecurity
      _cleanForSsecurity();

      // Step 9: serviceLogin → fresh _sign（用清理后的 auth cookies + sdkVersion）
      final r9 = await _get('https://account.xiaomi.com/pass/serviceLogin',
          params: {'sid': 'xiaomiio', '_json': 'true', 'cc': '+86'});
      final d9 = _parseXiaomiJson(r9.body);
      final sign = d9['_sign'] as String;
      final nonce = d9['nonce'] as String? ?? '';
      AppLogger.instance.i('XiaomiLogin',
          'Step 9: fresh sign=${sign.substring(0, sign.length > 20 ? 20 : sign.length)}..., hasSsec=${d9.containsKey("ssecurity")}, hasPsec=${d9.containsKey("psecurity")}');

      // Step 10: 关键！重新调 serviceLoginAuth2（带密码 hash + sdkVersion auth cookies）→ 拿 ssecurity
      _controller.add(LoginEvent.loading('正在完成登录...'));
      final r10 = await _post('https://account.xiaomi.com/pass/serviceLoginAuth2',
          params: {
            'sid': 'xiaomiio',
            'hash': _passwordHash,
            'callback': 'https://sts.api.io.mi.com/sts',
            'qs': '%3Fsid%3Dxiaomiio%26_json%3Dtrue',
            'user': _username,
            '_sign': sign,
            '_json': 'true',
            'cc': '+86',
          });
      final d10 = _parseXiaomiJson(r10.body);
      AppLogger.instance.i('XiaomiLogin',
          'Auth2 (after OTP): code=${d10['code']}, secStatus=${d10['securityStatus']}, hasSsec=${d10.containsKey('ssecurity')}');

      if (d10.containsKey('ssecurity')) {
        await _completeLogin(
            d10['ssecurity'] as String,
            d10['location'] as String,
            d10['userId']?.toString() ?? '',
            nonce,
        );
      } else {
        _controller.add(LoginEvent.error('无法获取登录凭据，请重试'));
      }
      _context = null;
    } catch (e, stackTrace) {
      AppLogger.instance.e('XiaomiLogin', 'Submit code error: $e', stackTrace);
      _controller.add(LoginEvent.error('验证失败: $e'));
    }
  }

  /// 完成登录 → 获取 serviceToken → 通知成功
  Future<void> _completeLogin(String ssecurity, String location, String userId, String nonce) async {
    AppLogger.instance.i('XiaomiLogin', 'Completing login: ssec=${ssecurity.substring(0, 8)}...');

    // Follow location URL to get serviceToken
    final nsec = 'nonce=$nonce&$ssecurity';
    final clientSign = base64.encode(sha1.convert(utf8.encode(nsec)).bytes);
    final fullLocation = '$location&clientSign=${Uri.encodeQueryComponent(clientSign)}';

    final r = await _get(fullLocation);

    // serviceToken 应该在 cookies 里
    serviceToken = _sessionCookies['serviceToken'];
    this.ssecurity = ssecurity;
    this.userId = userId;

    if (serviceToken == null) {
      // fallback: try response JSON
      final body = r.body;
      if (body.startsWith('&&&START&&&')) {
        try {
          final j = jsonDecode(body.substring(11));
          serviceToken = j['serviceToken'] as String?;
        } catch (_) {}
      }
    }

    if (serviceToken == null) {
      AppLogger.instance.e('XiaomiLogin', 'No serviceToken in cookies: ${_sessionCookies.keys}');
      _controller.add(LoginEvent.error('无法获取 serviceToken'));
      return;
    }

    _emitSuccess();
  }

  void _emitSuccess() {
    if (_successReported) return;
    _successReported = true;
    AppLogger.instance.i('XiaomiLogin',
        '✅ Login success: userId=$userId, ssecurity=${ssecurity!.substring(0, 8)}..., serviceToken=${serviceToken!.substring(0, 8)}...');
    _controller.add(LoginEvent.success(serviceToken!, ssecurity!, userId!));
  }

  void dispose() {
    _httpClient.close();
    _controller.close();
  }
}

class LoginEvent {
  const LoginEvent.success(this.serviceToken, this.ssecurity, this.userId)
      : errorMessage = null, phone = null, countdown = null;
  const LoginEvent.needCode(this.phone, this.countdown)
      : errorMessage = null, serviceToken = null, ssecurity = null, userId = null;
  const LoginEvent.loading([this.errorMessage])
      : serviceToken = null, ssecurity = null, userId = null, phone = null, countdown = null;
  const LoginEvent.error(this.errorMessage)
      : serviceToken = null, ssecurity = null, userId = null, phone = null, countdown = null;

  final String? serviceToken;
  final String? ssecurity;
  final String? userId;
  final String? errorMessage;
  final String? phone;
  final int? countdown;

  bool get isSuccess => serviceToken != null;
  bool get needCode => phone != null;
}
