/// ColorOS 15 极光引擎动画参数
///
/// 来源：OPPO ODC24 + Flutter Physics 对照换算
///
/// 核心特征：
///   - 柔性回弹 dampingRatio ≈ 0.5（MediumBouncy）
///   - FastOutSlowIn 标准过渡 (0.4, 0.0, 0.2, 1.0)
///   - 并行动画（极光引擎）— 多个 AnimationController 同时跑
library;

import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/material.dart';

class ColorOS {
  ColorOS._();

  // === 核心动画曲线 ===
  static const Curve standard = Cubic(0.4, 0.0, 0.2, 1.0);
  static const Curve enter = Cubic(0.0, 0.0, 0.2, 1.0);
  static const Curve exit = Cubic(0.4, 0.0, 1.0, 1.0);
  static const Curve emphasis = Cubic(0.2, 0.0, 0.0, 1.0);

  // === 物理弹簧参数 ===
  static const double springDamping = 0.5;
  static const double springStiffness = 200.0;

  // === 时长规范 ===
  static const Duration dInstant = Duration(milliseconds: 100);
  static const Duration dFast = Duration(milliseconds: 200);
  static const Duration dNormal = Duration(milliseconds: 300);
  static const Duration dSpring = Duration(milliseconds: 400);
  static const Duration dSlow = Duration(milliseconds: 500);
  static const Duration dEmphasis = Duration(milliseconds: 700);

  // === 延迟（stagger）===
  static const Duration stagger = Duration(milliseconds: 50);
}

/// ColorOS SpringSimulation 包装
Simulation colorosSpring(double start, double end, {double velocity = 0}) {
  final damping = 2 * ColorOS.springDamping *
      math.sqrt(ColorOS.springStiffness);
  return SpringSimulation(
    SpringDescription(
      mass: 1.0,
      stiffness: ColorOS.springStiffness,
      damping: damping,
    ),
    start,
    end,
    velocity,
  );
}
