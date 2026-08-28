/// 全局 BLE 配置常量
class AppConfig {
  AppConfig._();

  // ---- BLE 协议 UUID ----
  static const String serviceUuid = '0000fe95-0000-1000-8000-00805f9b34fb';
  static const String initCharUuid = '0000001c-0000-1000-8000-00805f9b34fb';
  static const String writeCharUuid = '00000010-0000-1000-8000-00805f9b34fb';
  static const String notifyCharUuid = '00000019-0000-1000-8000-00805f9b34fb';
  static const String port1CharUuid = '0000001a-0000-1000-8000-00805f9b34fb';
  static const String port2CharUuid = '0000001b-0000-1000-8000-00805f9b34fb';

  // ---- 重试参数 ----
  static const int bleMaxRetries = 3;
  static const Duration bleTimeout = Duration(seconds: 5);
  static const int reconnectMaxAttempts = 3;
  static const Duration reconnectInterval = Duration(seconds: 2);

  // ---- 扫描参数 ----
  static const Duration scanTimeout = Duration(seconds: 10);
  static const String targetDeviceName = 'CUKTECH';
}