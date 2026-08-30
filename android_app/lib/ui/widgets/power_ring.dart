/// 总功率环（环形进度 + 颜色映射）
///
/// 功率映射：
///   0-60W   翡翠绿 #10B981
///   60-120W 电光蓝 #3B82F6
///   120-180W 琥珀橙 #F59E0B
///   180W+    警示红 #EF4444
library;

import 'package:flutter/material.dart';

class PowerRing extends StatelessWidget {
  const PowerRing({
    super.key,
    required this.totalPower,
    required this.maxPower,
    this.activePortCount = 0,
    this.size = const Size(260, 260),
    this.ringWidth = 10,
  });

  final double totalPower;
  final double maxPower;
  final int activePortCount;
  final Size size;
  final double ringWidth;

  Color get _ringColor {
    if (totalPower <= 60) return const Color(0xFF10B981);
    if (totalPower <= 120) return const Color(0xFF3B82F6);
    if (totalPower <= 180) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  @override
  Widget build(BuildContext context) {
    final progress = (totalPower / maxPower).clamp(0.0, 1.0);

    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 背景环
          SizedBox.expand(
            child: CustomPaint(
              painter: _PowerRingPainter(
                progress: 1.0,
                ringWidth: ringWidth,
                color: Colors.white.withOpacity(0.05),
                isBackground: true,
              ),
            ),
          ),
          // 进度环（带动画）
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: progress),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
            builder: (context, value, _) {
              return SizedBox.expand(
                child: CustomPaint(
                  painter: _PowerRingPainter(
                    progress: value,
                    ringWidth: ringWidth,
                    color: _ringColor,
                  ),
                ),
              );
            },
          ),
          // 中心文字
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${totalPower.toStringAsFixed(1)} W',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$activePortCount/4 口活跃',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PowerRingPainter extends CustomPainter {
  _PowerRingPainter({
    required this.progress,
    required this.ringWidth,
    required this.color,
    this.isBackground = false,
  });

  final double progress;
  final double ringWidth;
  final Color color;
  final bool isBackground;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - ringWidth) / 2;

    final paint = Paint()
      ..strokeWidth = ringWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    if (!isBackground) {
      // 渐变色版本（仅进度环）
      paint.shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: -math.pi / 2 + math.pi * 2 * progress,
        colors: [color, color.withOpacity(0.6)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    }

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      math.pi * 2 * progress,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _PowerRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.ringWidth != ringWidth;
}
