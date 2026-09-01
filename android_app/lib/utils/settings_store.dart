import '../protocol/settings.dart';

/// 应用设置入口（共享单例，main.dart 启动时 await 加载）。
///
/// 这是一层轻封装：把真实的持久化实现 [Settings] 暴露为一个带 `init()` 的单例，
/// 避免在 runApp 前写一半初始化逻辑。
class SettingsStore {
  SettingsStore._();
  static final SettingsStore instance = SettingsStore._();

  /// 启动时加载 SharedPreferences 中已保存的设置。
  Future<void> init() => Settings.instance.load();
}
