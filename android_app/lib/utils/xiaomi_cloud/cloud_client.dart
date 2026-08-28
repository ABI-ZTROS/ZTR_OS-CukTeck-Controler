import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:hex/hex.dart';
import 'package:http/http.dart' as http;

import '../logger/logger.dart';
import 'models.dart';

/// 米家云 API 客户端（Dart 移植自 xiaomi_cloud.py）
///
/// 支持：用户名密码登录 Step1 / 设备列表 / beaconkey 获取。
/// 不支持：滑块验证码、RC4-drop[1024]（待抓包补充）。
///
/// 登录三步流程：
///   1. GET  /pass/serviceLogin?sid=xiaomiio&_json=true → ssecurity
///   2. POST /pass/serviceLoginAuth2（hash = md5(password)） → location/callback
///   3. GET  location → serviceToken
///
/// API 加密：RC4-drop[1024] + sign = sha1(sorted params + signed_nonce)
class XiaomiCloudClient {
  XiaomiCloudClient._();

  static final XiaomiCloudClient instance = XiaomiCloudClient._();

  final http.Client _httpClient = http.Client();
  XiaomiServer _server = XiaomiServer.cn;

  String _userId = '';
  String _serviceToken = '';
  String _ssecurity = '';
  String _location = '';
  bool _isLoggedIn = false;

  /// 是否已登录
  bool get isLoggedIn => _isLoggedIn;

  /// 当前用户 ID
  String get userId => _userId;

  /// 当前登录上下文（供上层持久化使用）
  LoginContext? get loginContext {
    if (!_isLoggedIn) return null;
    return LoginContext(
      userId: _userId,
      serviceToken: _serviceToken,
      ssecurity: _ssecurity,
      location: _location,
    );
  }

  /// 切换服务器区域
  void setServer(XiaomiServer server) {
    _server = server;
    AppLogger.instance.i('XiaomiCloudClient', 'Server set to ${server.name}');
  }

  /// 生成模拟 Android User-Agent
  String _buildAgent() {
    final rand = Random();
    final suffix = String.fromCharCodes(
      [...List.generate(11, (_) => rand.nextInt(26) + 65),
       ...List.generate(6, (_) => rand.nextInt(26) + 65)],
    );
    return 'Android-7.1.1-1.0.0-ONEPLUS A3010-136-$suffix MIIO/';
  }

  /// 生成随机 16 位设备 ID
  String _buildDeviceId() {
    final rand = Random();
    return String.fromCharCodes(
      [...List.generate(16, (_) => rand.nextInt(10) + 48)],
    );
  }

  /// MD5 密码 hash（ASCII hex，用于 Step2 `hash` 字段）
  String hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = md5.convert(bytes);
    return HEX.encode(digest.bytes).toLowerCase();
  }

  /// SHA1 签名（用于 API `sign` 字段）
  String signParams(Map<String, String> params, String signedNonce) {
    final sorted = params.keys.toList()..sort();
    final buf = StringBuffer();
    for (final k in sorted) {
      buf.write('$k=${params[k]}&');
    }
    buf.write('$signedNonce&');
    final bytes = utf8.encode(buf.toString());
    final digest = sha1.convert(bytes);
    return HEX.encode(digest.bytes).toLowerCase();
  }

  /// Step 1：获取 ssecurity / location
  ///
  /// GET `https://account.xiaomi.com/pass/serviceLogin?sid=xiaomiio&_json=true`
  Future<LoginResult> _loginStep1(String username) async {
    final url = Uri.parse(
      'https://account.xiaomi.com/pass/serviceLogin?sid=xiaomiio&_json=true&userId=${Uri.encodeQueryComponent(username)}',
    );
    final headers = <String, String>{
      'User-Agent': _buildAgent(),
      'Content-Type': 'application/x-www-form-urlencoded',
    };
    try {
      final response = await _httpClient.get(
        url,
        headers: headers,
      );
      if (response.statusCode != 200) {
        return LoginResult(
          success: false,
          errorMessage: '网络错误 Step1 (HTTP ${response.statusCode})',
        );
      }
      final body = response.body.replaceAll('&&&START&&&', '').trim();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final ssecurity = json['ssecurity'] as String? ?? '';
      final userId = json['userId'] as String? ?? '';
      final location = json['location'] as String? ?? '';
      if (ssecurity.isEmpty || userId.isEmpty) {
        return const LoginResult(
          success: false,
          errorMessage: 'Step1 未获取到 ssecurity，账号可能不存在',
        );
      }
      _ssecurity = ssecurity;
      _userId = userId;
      _location = location;
      AppLogger.instance.i('XiaomiCloudClient', 'Step1 OK userId=$userId');
      return const LoginResult(success: true);
    } catch (e, stackTrace) {
      AppLogger.instance.e('XiaomiCloudClient', 'Step1 failed: $e', stackTrace);
      return LoginResult(
        success: false,
        errorMessage: 'Step1 异常: $e',
      );
    }
  }

  /// RC4-drop[1024] 加密（占位）
  ///
  /// Dart 原生无 ARC4 实现，需结合 `pointycastle` 手动实现 RC4-drop[1024]。
  /// 当前仅作为占位，返回空串将使上层登录失败。
  String _rc4Encrypt(String password, String payload) {
    // TODO: 待抓包补充 pointycastle RC4-drop[1024] 实现
    throw UnimplementedError(
      'RC4 加密 TODO: 待抓包补充 pointycastle RC4-drop[1024] 实现',
    );
  }

  /// Step 2 + Step 3：用户名密码登录
  ///
  /// 当前 RC4 加密尚未补齐，仅完成 Step1（ssecurity 获取）。
  /// UI 层应友好提示用户改用二维码登录或等待 RC4 实现。
  Future<LoginResult> login(String username, String password) async {
    AppLogger.instance.i('XiaomiCloudClient', 'Login start: $username');
    final step1 = await _loginStep1(username);
    if (!step1.success) return step1;

    // TODO: Step2 POST /pass/serviceLoginAuth2（hash = md5(password)，sign = sha1(sorted params + signed_nonce)）
    // TODO: Step3 GET location → serviceToken
    // TODO: 滑块/图形验证码处理（待抓包补充）
    // TODO: RC4-drop[1024] + sign 加密（待抓包补充）
    return const LoginResult(
      success: false,
      errorMessage:
          'TODO: RC4 登录待抓包补充，请改用二维码登录或手动输入 Token',
    );
  }

  /// 二维码登录：返回 QR URL 供 UI 展示
  ///
  /// GET `https://account.xiaomi.com/longPolling/loginUrl`
  Future<QrCodeData> startQrLogin() async {
    // TODO: 实现 QR 长轮询（待抓包补充）
    throw UnimplementedError('QR 登录 TODO: 待抓包补充');
  }

  /// 轮询 QR 扫码状态
  Future<QrScanStatus> pollQrStatus(String sessionId) async {
    // TODO: 实现长轮询（待抓包补充）
    throw UnimplementedError('QR 状态轮询 TODO: 待抓包补充');
  }

  /// 登录完成：根据当前上下文构造 [LoginContext]
  ///
  /// 供 QR 登录成功后回填状态使用。
  void _markLoggedIn(String serviceToken) {
    _serviceToken = serviceToken;
    _isLoggedIn = true;
    AppLogger.instance.i(
      'XiaomiCloudClient',
      'Logged in userId=$_userId server=${_server.name}',
    );
  }

  /// 获取设备列表
  ///
  /// POST `/v2/home/home_device_list`（data JSON，加密 + 签名）
  Future<List<CloudDeviceInfo>> getDeviceList() async {
    if (!_isLoggedIn) {
      throw StateError('Not logged in');
    }
    // TODO: 调用 /v2/home/home_device_list（待抓包补充 RC4 + sign）
    throw UnimplementedError('getDeviceList TODO: 待抓包补充');
  }

  /// 获取 beaconkey（BLE 直连 Token）
  ///
  /// POST `/v2/device/blt_get_beaconkey`，body: `{"did": ..., "pdid": 1}`
  Future<String?> getBeaconKey(String did) async {
    if (!_isLoggedIn) {
      throw StateError('Not logged in');
    }
    // TODO: 调用 /v2/device/blt_get_beaconkey（待抓包补充 RC4 + sign）
    throw UnimplementedError('getBeaconKey TODO: 待抓包补充');
  }

  /// 登出
  Future<void> logout() async {
    _userId = '';
    _serviceToken = '';
    _ssecurity = '';
    _location = '';
    _isLoggedIn = false;
    AppLogger.instance.i('XiaomiCloudClient', 'Logged out');
  }

  /// 生成随机 16 位设备 ID（对外暴露便于测试）
  String buildDeviceId() => _buildDeviceId();
}
