/// 米家云相关数据模型

/// 米家云服务器区域
///
/// 各区域 base URL 对应 Python 参考实现中的 `cn/de/us/ru/tw/sg/in/i2`。
enum XiaomiServer {
  cn('https://api.io.mi.com/app'),
  de('https://de.api.io.mi.com/app'),
  us('https://us.api.io.mi.com/app'),
  ru('https://ru.api.io.mi.com/app'),
  tw('https://tw.api.io.mi.com/app'),
  sg('https://sg.api.io.mi.com/app'),
  in_('https://in.api.io.mi.com/app'),
  i2('https://i2.api.io.mi.com/app');

  const XiaomiServer(this.baseUrl);
  final String baseUrl;
}

/// 登录上下文
///
/// 由用户名密码登录三步流程中 Step1/Step3 产生，用于后续 API 签名。
class LoginContext {
  const LoginContext({
    required this.userId,
    required this.serviceToken,
    required this.ssecurity,
    required this.location,
  });

  final String userId;
  final String serviceToken;
  final String ssecurity;
  final String location;
}

/// 登录结果
class LoginResult {
  const LoginResult({
    required this.success,
    this.errorMessage,
    this.userId,
    this.serviceToken,
  });

  final bool success;
  final String? errorMessage;
  final String? userId;
  final String? serviceToken;
}

/// 米家设备
class XiaomiDevice {
  const XiaomiDevice({
    required this.did,
    required this.name,
    required this.model,
    this.token = '',
    this.isOnline = false,
  });

  final String did;
  final String name;
  final String model;
  final String token;
  final bool isOnline;

  factory XiaomiDevice.fromJson(Map<String, dynamic> json) {
    return XiaomiDevice(
      did: json['did'] as String? ?? '',
      name: json['name'] as String? ?? '',
      model: json['model'] as String? ?? '',
      token: json['token'] as String? ?? '',
      isOnline: json['isOnline'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'did': did,
        'name': name,
        'model': model,
        'token': token,
        'isOnline': isOnline,
      };
}

/// 云端获取的设备信息（含 beaconToken / beaconKey）
///
/// 由 `POST /v2/home/home_device_list` 与
/// `POST /v2/device/blt_get_beaconkey` 组合得到，用于 BLE 直连登录。
class CloudDeviceInfo {
  const CloudDeviceInfo({
    required this.did,
    required this.name,
    required this.model,
    required this.mac,
    this.beaconToken = '',
    this.beaconKey = '',
    this.isOnline = false,
  });

  final String did;
  final String name;
  final String model;
  final String mac;
  final String beaconToken;
  final String beaconKey;
  final bool isOnline;

  factory CloudDeviceInfo.fromJson(Map<String, dynamic> json) {
    return CloudDeviceInfo(
      did: json['did'] as String? ?? '',
      name: json['name'] as String? ?? '',
      model: json['model'] as String? ?? '',
      mac: json['mac'] as String? ?? '',
      beaconToken: json['beaconToken'] as String? ?? '',
      beaconKey: json['beaconKey'] as String? ?? '',
      isOnline: json['isOnline'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'did': did,
        'name': name,
        'model': model,
        'mac': mac,
        'beaconToken': beaconToken,
        'beaconKey': beaconKey,
        'isOnline': isOnline,
      };
}

/// 二维码数据
class QrCodeData {
  const QrCodeData({
    required this.url,
    required this.token,
    required this.expiresAt,
  });

  final String url;
  final String token;
  final int expiresAt;
}

/// 扫码状态
class QrScanStatus {
  const QrScanStatus({
    required this.status,
    required this.sessionId,
  });

  static const int pending = 0;
  static const int scanned = 1;
  static const int confirmed = 2;
  static const int expired = 3;

  final int status;
  final String sessionId;

  bool get isPending => status == pending;
  bool get isScanned => status == scanned;
  bool get isConfirmed => status == confirmed;
  bool get isExpired => status == expired;
}
