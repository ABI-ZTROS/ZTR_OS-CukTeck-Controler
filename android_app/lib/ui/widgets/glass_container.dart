/// ColorOS 液态玻璃容器 — 自动降级
///
/// 开启：BackdropFilter blur + 半透明白色 + 顶部高光
/// 关闭：纯色渐变 + 圆角 + 边框
///
/// 设置开关：Settings.isGlassEnabled
library;

import 'dart:ui';

import 'package:flutter/material.dart';

/// 液态玻璃容器
///
/// [child] 子组件
/// [radius] 圆角，默认 16
/// [blurSigma] 模糊强度，默认 15（≤20 避免 GPU 过载）
/// [isGlassEnabled] 外部传入开关，false 时降级为纯色
/// [color] 降级色，默认深色 #111827
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.radius = 16,
    this.blurSigma = 15,
    this.isGlassEnabled = true,
    this.color = const Color(0xFF111827),
    this.padding = const EdgeInsets.all(12),
    this.width,
    this.height,
  });

  final Widget child;
  final double radius;
  final double blurSigma;
  final bool isGlassEnabled;
  final Color color;
  final EdgeInsets padding;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );

    Widget container = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: isGlassEnabled ? Colors.transparent : color,
      ),
      child: child,
    );

    if (!isGlassEnabled) return ClipRRect(borderRadius: shape.borderRadius, child: container);

    return ClipRRect(
      borderRadius: shape.borderRadius,
      child: Stack(
        children: [
          // 半透明黑色底（保证深色模式下可读）
          Positioned.fill(
            child: Container(color: Colors.black.withOpacity(0.4)),
          ),
          // 液态玻璃模糊层
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              child: Container(),
            ),
          ),
          // 半透明白色叠加
          Positioned.fill(
            child: Container(color: Colors.white.withOpacity(0.08)),
          ),
          // 顶部高光条（ColorOS 质感）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white.withOpacity(0.25),
                    Colors.white.withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
          container,
        ],
      ),
    );
  }
}
