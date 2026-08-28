import 'dart:async';
import 'package:flutter/foundation.dart';
import '../utils/logger/logger.dart';

/// Zygote 级异常处理器（Flutter 原生层）
///
/// 注册 3 种异常捕获点：
/// 1. [FlutterError.onError] —— Widget 树内渲染异常
/// 2. [PlatformDispatcher.onError] —— 异步未捕获异常
///
/// 注意：[runZonedGuarded] 包装应在 [main] 中围绕 [runApp] 调用。
void setupZygoteExceptionHandler() {
  // FlutterError.onError 捕获 widget 树异常
  FlutterError.onError = (FlutterErrorDetails details) async {
    AppLogger.instance.e('Zygote', 'FlutterError', details.exception, details.stack);
    // 继续上报到默认处理器
    FlutterError.presentError(details);
  };

  // PlatformDispatcher.onError 捕获异步未捕获异常
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.instance.e('Zygote', 'PlatformError', error, stack);
    return true; // 已处理
  };
}

/// 便捷包装：在 runZonedGuarded 内执行
Future<T> runGuarded<T>(Future<T> Function() body,
    {String tag = 'App'}) async {
  try {
    return await body().timeout(const Duration(seconds: 30));
  } catch (e, st) {
    AppLogger.instance.e(tag, 'Unhandled', e, st);
    rethrow;
  }
}