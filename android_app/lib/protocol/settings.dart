/// 用户设置 — SharedPreferences 持久化
///
/// 支持：液态玻璃开关 / 自动重连 / 动画等级
library;

import 'package:shared_preferences/shared_preferences.dart';

enum AnimationLevel { full, lite }

class Settings {
  Settings._();
  static final Settings instance = Settings._();

  bool isGlassEnabled = true;
  bool autoReconnect = true;
  Duration reconnectInterval = const Duration(seconds: 30);
  AnimationLevel animationLevel = AnimationLevel.full;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    isGlassEnabled = prefs.getBool('glass_enabled') ?? true;
    autoReconnect = prefs.getBool('auto_reconnect') ?? true;
    final seconds = prefs.getInt('reconnect_sec') ?? 30;
    reconnectInterval = Duration(seconds: seconds);
    final level = prefs.getString('anim_level') ?? 'full';
    animationLevel = level == 'lite' ? AnimationLevel.lite : AnimationLevel.full;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('glass_enabled', isGlassEnabled);
    await prefs.setBool('auto_reconnect', autoReconnect);
    await prefs.setInt('reconnect_sec', reconnectInterval.inSeconds);
    await prefs.setString('anim_level',
        animationLevel == AnimationLevel.full ? 'full' : 'lite');
  }
}
