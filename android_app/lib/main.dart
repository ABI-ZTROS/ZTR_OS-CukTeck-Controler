import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'bootstrap/zegoate_handler.dart';
import 'ui/pages/home_page.dart';
import 'ui/theme/app_theme.dart';
import 'utils/logger/logger.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 注册 Zygote 级全局异常捕获
  setupZygoteExceptionHandler();

  AppLogger.instance.i('Main', 'CukTechController starting');

  // runZonedGuarded 包裹 runApp，捕获 Isolate 级未捕获异常
  runZonedGuarded<Future<void>>(() async {
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
    );
  }
}