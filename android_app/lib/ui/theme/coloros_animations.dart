/// ColorOS 15 极光引擎动画参数
///
/// 来源：OPPO ODC24 + Compose 物理弹簧对照换算
///
/// 核心特征：
///   - 柔性回弹 dampingRatio ≈ 0.5（MediumBouncy）
///   - FastOutSlowIn 标准过渡 (0.4, 0.0, 0.2, 1.0)
///   - 并行动画（极光引擎）— 多个 AnimationController 同时跑
///   - 自然光影 / 弥散投影 — BackdropFilter + 半透明叠加

library;

import 'package:flutter/material.dart';

class ColorOS {
  ColorOS._();

  // === 核心动画曲线 ===
  static const Curve standard = Cubic(0.4, 0.0, 0.2, 1.0); // FastOutSlowIn
  static const Curve enter = Cubic(0.0, 0.0, 0.2, 1.0);   // LinearOutSlowIn
  static const Curve exit = Cubic(0.4, 0.0, 1.0, 1.0);    // FastOutLinearIn
  static const Curve emphasis = Cubic(0.2, 0.0, 0.0, 1.0); // ExtremeDeceleration

  // === 物理弹簧参数（柔性回弹）===
  static const double springDamping = 0.5; // MediumBouncy: 轻微弹性
  static const double springStiffness = 200.0; // StiffnessLow: 不硬不软

  // === 时长规范 ===
  static const Duration dInstant = Duration(milliseconds: 100);  // 状态变化
  static const Duration dFast = Duration(milliseconds: 200);     // 微交互
  static const Duration dNormal = Duration(milliseconds: 300);    // 常规过渡
  static const Duration dSpring = Duration(milliseconds: 400);   // 弹簧动画
  static const Duration dSlow = Duration(milliseconds: 500);     // 页面切换
  static const Duration dEmphasis = Duration(milliseconds: 700);  // 强调动画

  // === 延迟（stagger）===
  static const Duration stagger = Duration(milliseconds: 50);
}

/// ColorOS SpringSimulation 包装
///
/// 使用方式：
///   AnimationController(vsync: this, duration: ColorOS.dSpring)
///   controller.animateTo(1.0,
///     curve: Curves.easeOut,
///   );
///   // 或者用 SpringSimulation 做物理动画
Simulation springSimulation(double start, double end, {double velocity = 0}) {
  return SpringSimulation(
    Spring(
      description: const SpringDescription(
        mass: 1.0,
        stiffness: ColorOS.springStiffness,
        damping: 2 * ColorOS.springDamping *
            sqrt(ColorOS.springStiffness), // critical damping * ratio
      ),
    ),
    start,
    end,
    velocity,
  );
}
