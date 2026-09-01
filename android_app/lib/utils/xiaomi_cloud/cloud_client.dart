import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../logger/logger.dart';
import 'models.dart';
import 'rc4.dart';
import 'signature.dart';

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

  bool get isLoggedIn => _isLoggedIn;
  String get userId => _userId;

  LoginContext? get loginContext {
    if (!_isLoggedIn) return null;
    return LoginContext(
      userId: _userId,
      serviceToken: _serviceToken,
      ssecurity: _ssecurity,
      location: _location,
    );
  }

  void setServer(XiaomiServer server) {
    _server = server;
    AppLogger.instance.i('XiaomiCloudClient', 'Server set to ${server.name}');
  }

  // 从 WebView 登录设置凭据
  void setCredentials({
    required String serviceToken,
    required String ssecurity,
    String userId = '',
    String location = '',
  }) {
    _serviceToken = serviceToken;
    _ssecurity = ssecurity;
    _userId = userId;
    _location = location;
    _isLoggedIn = true;
    AppLogger.instance.i('XiaomiCloudClient', 'Credentials set userId=$_userId');
  }

  String _buildAgent() {
    final rand = Random.secure();
    final suffix = String.fromCharCodes(
      [...List.generate(11, (_) => rand.nextInt(26) + 65),
       ...List.generate(6, (_) => rand.nextInt(26) + 65)],
    );
    return 'Android-7.1.1-1.0.0-ONEPLUS A3010-136-$suffix MIIO/';
  }

  Future<Map<String, dynamic>?> _apiCall(
    String url,
    Map<String, String> params,
  ) async {
    final millis = DateTime.now().millisecondsSinceEpoch;
    final nonce = generateNonce(millis);
    final sNonce = signedNonce(_ssecurity, nonce);
    final encParams = generateEncParams(
      url: url,
      method: 'POST',
      signedNonce: sNonce,
      nonce: nonce,
      params: params,
      ssecurity: _ssecurity,
    );

    final headers = <String, String>{
      'Accept-Encoding': 'identity',
      'User-Agent': _buildAgent(),
      'Content-Type': 'application/x-www-form-urlencoded',
      'x-xiaomi-protocal-flag-cli': 'PROTOCAL-HTTP2',
      'MIOT-ENCRYPT-ALGORITHM': 'ENCRYPT-RC4',
    };

    final cookies = <String, String>{
      'userId': _userId,
      'serviceToken': _serviceToken,
      'yetAnotherServiceToken': _serviceToken, // 🔑 Python second class includes this!
      'locale': 'en_GB',
      'timezone': 'GMT+08:00',
      'channel': 'MI_APP_STORE',
    };

    for (int retry = 0; retry < 3; retry++) {
      try {
        // 🔑 Python puts encParams in URL query, NOT body! (params=fields)
        final queryString = encParams.entries
            .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        final fullUrl = '$url?$queryString';
        final request = http.Request('POST', Uri.parse(fullUrl))
          ..headers.addAll(headers)
          ..headers['Cookie'] = cookies.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; ');

        AppLogger.instance.i('XiaomiCloudClient',
            'POST ${url.split("com")[1]}?... encParams keys=[${encParams.keys.join(",")}]');

        final response = await _httpClient.send(request).timeout(
              const Duration(seconds: 5),
            );

        if (response.statusCode == 200) {
          final responseBody = await response.stream.bytesToString();
          AppLogger.instance.i('XiaomiCloudClient',
              'API raw resp: ${responseBody.substring(0, responseBody.length > 200 ? 200 : responseBody.length)}');
          final decrypted = decryptRc4(
            signedNonce(_ssecurity, encParams['_nonce']!),
            responseBody,
          );
          AppLogger.instance.i('XiaomiCloudClient',
              'API decrypted: ${decrypted.substring(0, decrypted.length > 300 ? 300 : decrypted.length)}');
          return jsonDecode(decrypted) as Map<String, dynamic>;
        } else {
          AppLogger.instance.w(
            'XiaomiCloudClient',
            'API $url returned ${response.statusCode}',
          );
        }
      } catch (e, stackTrace) {
        AppLogger.instance.e(
          'XiaomiCloudClient',
          'API call failed (retry $retry): $e',
          stackTrace,
        );
        if (retry == 2) rethrow;
      }
    }
    return null;
  }

  // 获取 beaconKey
  Future<String?> getBeaconKey(String did) async {
    if (!_isLoggedIn) throw StateError('Not logged in');

    final url = '${_server.baseUrl}/v2/device/blt_get_beaconkey';
    final result = await _apiCall(url, {
      'data': jsonEncode({'did': did, 'pdid': 1}),
    });

    if (result != null && result['code'] == 0) {
      return result['result']?['beaconkey'] as String?;
    }
    return null;
  }

  // 获取设备列表
  Future<List<CloudDeviceInfo>> getDeviceList() async {
    if (!_isLoggedIn) throw StateError('Not logged in');

    final url = _server.baseUrl;
    final homes = await _apiCall('$url/v2/homeroom/gethome', {
      'data': jsonEncode({
        'fg': true,
        'fetch_share': true,
        'fetch_share_dev': true,
        'limit': 300,
        'app_ver': 7,
      }),
    });

    final devices = <CloudDeviceInfo>[];
    if (homes?['code'] == 0) {
      final homelist = homes!['result']?['homelist'] as List? ?? [];
      for (final home in homelist) {
        final homeMap = home as Map;
        final homeId = homeMap['id'] as String? ?? '';
        final homeOwner = homeMap['uid'] as String? ?? _userId;

        final homeData = await _apiCall('$url/v2/home/home_device_list', {
          'data': jsonEncode({
            'home_owner': homeOwner,
            'home_id': homeId,
            'limit': 200,
            'get_split_device': true,
            'support_smart_home': true,
          }),
        });

        if (homeData?['code'] == 0) {
          final devList =
              homeData!['result']?['device_info'] as List? ?? [];
          for (final dev in devList) {
            final d = dev as Map;
            final token = d['token'] as String? ?? '';
            if (token.isNotEmpty) {
              devices.add(CloudDeviceInfo(
                did: d['did'] as String? ?? '',
                name: d['name'] as String? ?? '',
                model: d['model'] as String? ?? '',
                mac: d['mac'] as String? ?? '',
                beaconToken: token,
              ));
            }
          }
        }
      }
    }
    return devices;
  }

  Future<void> logout() async {
    _userId = '';
    _serviceToken = '';
    _ssecurity = '';
    _location = '';
    _isLoggedIn = false;
    AppLogger.instance.i('XiaomiCloudClient', 'Logged out');
  }
}
