import 'constants.dart';

/// 端口状态模型
class PortState {
  PortState({
    required this.portIndex,
    this.voltage = 0.0,
    this.current = 0.0,
    this.power = 0.0,
    this.isCharging = false,
    this.protocol = '',
  });

  final int portIndex;
  double voltage;
  double current;
  double power;
  bool isCharging;
  String protocol;

  factory PortState.fromJson(Map<String, dynamic> json) {
    return PortState(
      portIndex: json['portIndex'] as int? ?? 0,
      voltage: (json['voltage'] as num?)?.toDouble() ?? 0.0,
      current: (json['current'] as num?)?.toDouble() ?? 0.0,
      power: (json['power'] as num?)?.toDouble() ?? 0.0,
      isCharging: json['isCharging'] as bool? ?? false,
      protocol: json['protocol'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'portIndex': portIndex,
    'voltage': voltage,
    'current': current,
    'power': power,
    'isCharging': isCharging,
    'protocol': protocol,
  };

  @override
  String toString() =>
      'PortState($portIndex: ${voltage.toStringAsFixed(1)}V ${current.toStringAsFixed(1)}A ${power.toStringAsFixed(1)}W ${isCharging ? 'ON' : 'OFF'})';
}

/// 充电器整体状态
class ChargerState {
  ChargerState({
    this.inputVoltage = 0.0,
    this.inputCurrent = 0.0,
    this.inputPower = 0.0,
    this.temperature = 0,
    this.portCount = 4,
    this.ports = const <PortState>[],
    this.isConnected = false,
  });

  double inputVoltage;
  double inputCurrent;
  double inputPower;
  int temperature;
  int portCount;
  List<PortState> ports;
  bool isConnected;

  factory ChargerState.fromJson(Map<String, dynamic> json) {
    final List<dynamic> portList = json['ports'] as List<dynamic>? ?? <dynamic>[];
    return ChargerState(
      inputVoltage: (json['inputVoltage'] as num?)?.toDouble() ?? 0.0,
      inputCurrent: (json['inputCurrent'] as num?)?.toDouble() ?? 0.0,
      inputPower: (json['inputPower'] as num?)?.toDouble() ?? 0.0,
      temperature: json['temperature'] as int? ?? 0,
      portCount: json['portCount'] as int? ?? 4,
      ports: portList
          .map((dynamic e) => PortState.fromJson(e as Map<String, dynamic>))
          .toList(),
      isConnected: json['isConnected'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'inputVoltage': inputVoltage,
    'inputCurrent': inputCurrent,
    'inputPower': inputPower,
    'temperature': temperature,
    'portCount': portCount,
    'ports': ports.map((PortState e) => e.toJson()).toList(),
    'isConnected': isConnected,
  };
}

/// 设备信息
class DeviceInfo {
  DeviceInfo({
    this.model = '',
    this.serialNumber = '',
    this.firmwareVersion = '',
    this.productId = productId,
    this.hardwareVersion = '',
  });

  final String model;
  final String serialNumber;
  final String firmwareVersion;
  final int productId;
  final String hardwareVersion;

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    return DeviceInfo(
      model: json['model'] as String? ?? '',
      serialNumber: json['serialNumber'] as String? ?? '',
      firmwareVersion: json['firmwareVersion'] as String? ?? '',
      productId: json['productId'] as int? ?? productId,
      hardwareVersion: json['hardwareVersion'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'model': model,
    'serialNumber': serialNumber,
    'firmwareVersion': firmwareVersion,
    'productId': productId,
    'hardwareVersion': hardwareVersion,
  };
}

/// Token 配置
///
/// 当通过本地 miio2.db 扫描设备时，[deviceMac]/[deviceName]/[deviceModel]
/// 会被填充；手动输入或云端登录时这些字段可能为空。
class TokenConfig {
  const TokenConfig({
    required this.token,
    this.key = '',
    this.did = '',
    this.userId = '',
    this.deviceMac = '',
    this.deviceName = '',
    this.deviceModel = '',
  });

  final String token;
  final String key;
  final String did;
  final String userId;
  final String deviceMac;
  final String deviceName;
  final String deviceModel;

  factory TokenConfig.fromJson(Map<String, dynamic> json) {
    return TokenConfig(
      token: json['token'] as String? ?? '',
      key: json['key'] as String? ?? '',
      did: json['did'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      deviceMac: json['deviceMac'] as String? ?? '',
      deviceName: json['deviceName'] as String? ?? '',
      deviceModel: json['deviceModel'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'token': token,
    'key': key,
    'did': did,
    'userId': userId,
    'deviceMac': deviceMac,
    'deviceName': deviceName,
    'deviceModel': deviceModel,
  };

  /// Token 是否有效（长度 32 位十六进制）
  bool get isValid =>
      token.length == 32 && RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(token);

  /// 是否完整（含 BLE Key）
  bool get isComplete => isValid && key.isNotEmpty && key.length >= 16;

  Map<String, dynamic> toMap() => toJson();
}

// ============================================================================
// miio2.db 数据模型
// ============================================================================

/// 米家设备记录（来自 miio2.db 的 devices 表）
class MiioDevice {
  /// 设备 ID
  final String did;

  /// 型号，例如 'njcuk.fitting.ad1204u'
  final String model;

  /// 32 位 Token（12 字节十六进制）
  final String token;

  /// MAC 地址
  final String mac;

  /// 设备名称
  final String name;

  const MiioDevice({
    required this.did,
    required this.model,
    required this.token,
    required this.mac,
    required this.name,
  });

  /// 是否酷态科充电器（按 model 前缀匹配）
  bool get isCuktech => model.startsWith('njcuk.');

  /// Token 是否为非空合法 32 位十六进制
  bool get hasValidToken =>
      token.length == 32 && RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(token);

  Map<String, dynamic> toMap() => <String, dynamic>{
        'did': did,
        'model': model,
        'token': token,
        'mac': mac,
        'name': name,
      };

  @override
  String toString() =>
      'MiioDevice($name model=$model mac=$mac token=${token.substring(0, 4)}...)';
}

/// miio2.db 读取结果
class MiioDbResult {
  final bool success;
  final List<MiioDevice> devices;
  final String? errorCode; // DB_NOT_FOUND / NO_PERMISSION / PARSE_ERROR / null

  const MiioDbResult({
    required this.success,
    required this.devices,
    this.errorCode,
  });

  factory MiioDbResult.success(List<MiioDevice> devices) =>
      MiioDbResult(success: true, devices: devices);

  factory MiioDbResult.failure(String errorCode) =>
      MiioDbResult(success: false, devices: const [], errorCode: errorCode);
}

/// 错误码常量
class MiioDbErrors {
  static const String dbNotFound = 'DB_NOT_FOUND';
  static const String noPermission = 'NO_PERMISSION';
  static const String parseError = 'PARSE_ERROR';
  static const String emptyResult = 'EMPTY_RESULT';
}
