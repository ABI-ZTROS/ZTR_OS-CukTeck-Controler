import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'bootstrap/zegoate_handler.dart';
import 'ui/pages/home_page.dart';
import 'ui/theme/app_theme.dart';
import 'utils/logger/logger.dart';
import 'utils/root/root_shell.dart';
import 'utils/settings_store.dart';

/// 全局路由观察者 — 让 HomePage 在 TokenImportPage pop 回来时自动重扫
final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 注册 Zygote 级全局异常捕获
  setupZygoteExceptionHandler();

  AppLogger.instance.i('Main', 'CukTechController starting');

  // runZonedGuarded 包裹 runApp，捕获 Isolate 级未捕获异常
  runZonedGuarded<Future<void>>(() async {
    await SettingsStore.instance.init();

    // ================================================================
    // 🪄 Root 自动夺权（适配 KernelSU / Magisk / APatch）
    //   - 非阻塞，默认 5s 上限 × 3 次
    //   - 成功/失败写入 RootShell.instance.statusNotifier
    //   - HomePage RootStatusBadge 负责显示 + 交互（点击重试、长按打开管理器）
    // ================================================================
    AppLogger.instance.i('Main', '🪄 启动 Root 自动夺权 (tryAcquireRoot 5s×3)');
    unawaited(RootShell.instance.tryAcquireRoot(
      timeoutMs: 5000,
      retries: 2,
      silentIfAvailable: false,
    ));

    runApp(const CukTechControllerApp());
  }, (error, stack) {
    AppLogger.instance.e('Zygote', 'ZonedError', error, stack);
  });
}

class CukTechControllerApp extends StatelessWidget {
  const CukTechControllerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '酷态科控制器',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const HomePage(),
      navigatorObservers: <NavigatorObserver>[routeObserver],
    );
  }
}// trigger rebuild
// trigger rebuild 2
// trigger rebuild 3
