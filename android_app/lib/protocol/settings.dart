import '../ble/encrypted_channel.dart';
import '../ble/android_connector.dart';
import '../utils/logger/logger.dart';
import 'constants.dart';

// ============================================================================
// 应用偏好设置（本地持久化，非设备端 PIID 控制）
// ============================================================================

/// 应用设置管理
///
/// 管理用户偏好设置，如自动连接、日志等级、主题等。
class Settings {
  Settings._();

  static final Settings instance = Settings._();

  // TODO: 接入 SharedPreferences 持久化

  bool _autoConnect = true;
  bool _darkMode = true;
  String _logLevel = 'info';
  int _scanTimeout = 10;
  int _refreshInterval = 500;

  /// 是否自动连接上次设备
  bool get autoConnect => _autoConnect;
  set autoConnect(bool value) {
    _autoConnect = value;
    _save();
  }

  /// 深色模式
  bool get darkMode => _darkMode;
  set darkMode(bool value) {
    _darkMode = value;
    _save();
  }

  /// 日志等级
  String get logLevel => _logLevel;
  set logLevel(String value) {
    _logLevel = value;
    _save();
  }

  /// 扫描超时（秒）
  int get scanTimeout => _scanTimeout;
  set scanTimeout(int value) {
    _scanTimeout = value;
    _save();
  }

  /// 状态刷新间隔（毫秒）
  int get refreshInterval => _refreshInterval;
  set refreshInterval(int value) {
    _refreshInterval = value;
    _save();
  }

  Future<void> _save() async {
    // TODO: 实现持久化
    AppLogger.instance.d('Settings', 'Settings saved');
  }

  Future<void> load() async {
    // TODO: 从 SharedPreferences 加载
    AppLogger.instance.d('Settings', 'Settings loaded');
  }
}

// ============================================================================
// 充电器设备设置封装（PIID 读-改-写-回读）
// ============================================================================

/// 充电器设置封装
class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  final EncryptedChannel _channel = EncryptedChannel.instance;
  int _miotSeq = 1;
  int get _nextSeq {
    final s = _miotSeq;
    _miotSeq = (_miotSeq + 1) & 0xFF;
    return s;
  }

  Future<int?> read(AndroidConnector c, int piid) async {
    final resp = await _channel.sendGet(c, siidCharger, piid,
        seqProvider: () => _nextSeq);
    return resp?['value'] as int?;
  }

  Future<bool> write(AndroidConnector c, int piid, int value) async {
    final resp = await _channel.sendSet(c, siidCharger, piid, value,
        seqProvider: () => _nextSeq);
    if (resp == null) return false;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final rb = await read(c, piid);
    final ok = rb == value;
    AppLogger.instance.i('Settings', 'PIID $piid wrote=$value read=$rb OK=$ok');
    return ok;
  }

  // ---- 场景模式 PIID 5 ----
  Future<int?> getSceneMode(AndroidConnector c) => read(c, 5);
  Future<bool> setSceneMode(AndroidConnector c, int mode) => write(c, 5, mode);

  // ---- 息屏时间 PIID 6 ----
  Future<int?> getScreenOffTime(AndroidConnector c) => read(c, 6);
  Future<bool> setScreenOffTime(AndroidConnector c, int time) => write(c, 6, time);

  // ---- 总倒计时 PIID 8 ----
  Future<int?> getGlobalTimer(AndroidConnector c) => read(c, 8);
  Future<bool> setGlobalTimer(AndroidConnector c, int minutes) => write(c, 8, minutes);

  // ---- 单端口倒计时 PIID 9-12 ----
  Future<int?> getPortTimer(AndroidConnector c, String port) =>
      read(c, timerPorts[port]!);
  Future<bool> setPortTimer(AndroidConnector c, String port, int minutes) =>
      write(c, timerPorts[port]!, minutes);

  // ---- 语言 PIID 13 ----
  Future<int?> getLanguage(AndroidConnector c) => read(c, 13);
  Future<bool> setLanguage(AndroidConnector c, int lang) => write(c, 13, lang);

  // ---- USB-A 小电流 PIID 15 ----
  Future<bool> setUsbASmallCurrent(AndroidConnector c, bool on) =>
      write(c, 15, on ? 1 : 0);

  // ---- 空闲息屏 PIID 19 ----
  Future<bool> setIdleScreenOff(AndroidConnector c, bool on) =>
      write(c, 19, on ? 1 : 0);

  // ---- 屏幕方向锁 PIID 20 ----
  Future<bool> setScreenOrientationLock(AndroidConnector c, bool on) =>
      write(c, 20, on ? 1 : 0);

  // ---- 进入界面 PIID 14 (只写) ----
  Future<bool> gotoScreen(AndroidConnector c, int page) async {
    final resp = await _channel.sendSet(c, siidCharger, 14, page,
        seqProvider: () => _nextSeq);
    return resp != null;
  }
}