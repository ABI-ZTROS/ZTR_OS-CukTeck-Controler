/// 酷态科 Ad1204 充电头 CustomPainter
///
/// 纯静态绘图逻辑，接收当前状态参数，不持有 AnimationController。
/// 动画由上层 Widget 驱动 [ledPulse] / [energyFlowT]。
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

/// 充电头状态参数
class ChargerPaintState {
  const ChargerPaintState({
    required this.activePorts, // {1,2,3,4} 活跃端口集合
    this.ledPulse = 0.0,      // 全局 LED 呼吸值 0~1（实际用各端口独立的）
    this.portPulses = const {1: 0.0, 2: 0.0, 3: 0.0, 4: 0.0},
    this.glassEnabled = true,
  });

  final Set<int> activePorts;
  final double ledPulse;
  final Map<int, double> portPulses;
  final bool glassEnabled;

  bool isActive(int piid) => activePorts.contains(piid);
  double portPulse(int piid) => portPulses[piid] ?? 0.0;
}

/// 酷态科充电头 CustomPainter
///
/// Canvas 尺寸假设：300x300（外层 Box 负责缩放）
/// 几何参数基于 Ad1204 实物 3C + 1A 布局还原
class CuktechChargerPainter extends CustomPainter {
  CuktechChargerPainter(this.state);

  final ChargerPaintState state;

  // 颜色常量
  static const Color _casingColor = Color(0xFF1E293B);     // 外壳深蓝灰
  static const Color _casingHighlight = Color(0xFF334155);  // 外壳高光
  static const Color _bodyColor = Color(0xFF0F172A);        // 机身内深色
  static const Color _usbCColor = Color(0xFF64748B);       // C 口金属
  static const Color _usbAColor = Color(0xFF78716C);       // A 口金属（金色偏暖）
  static const Color _logoColor = Color(0xFFF1F5F9);       // LOGO 白
  static const Color _ledIdleColor = Color(0xFF374151);    // LED 非活跃
  static const Color _ledActiveColor = Color(0xFF10B981);  // LED 活跃（翡翠绿）
  static const Color _centerEnergyColor = Color(0xFF3B82F6); // 中心能量点

  // 端口 LED 位置（以 Canvas 中心 150,150 为基准）
  // Ad1204: 上排 3xUSB-C，右下 USB-A
  static const _ledPositions = <int, Offset>{
    1: Offset(110, 95),   // C1 左
    2: Offset(160, 95),   // C2 中
    3: Offset(210, 95),   // C3 右
    4: Offset(230, 170),  // A 右下
  };

  // USB 口中心
  static const _usbCenters = <int, Offset>{
    1: Offset(110, 130),
    2: Offset(160, 130),
    3: Offset(210, 130),
    4: Offset(230, 170),
  };

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scale = math.min(size.width, size.height) / 300.0;

    canvas.save();
    canvas.translate(center.dx - 150 * scale, center.dy - 150 * scale);
    canvas.scale(scale);

    _drawCasing(canvas);
    _drawLogo(canvas);
    _drawUsbPorts(canvas);
    _drawCenterEnergy(canvas);
    _drawLeds(canvas);

    canvas.restore();
  }

  void _drawCasing(Canvas canvas) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(30, 50, 240, 200),
      const Radius.circular(28),
    );

    // 外壳主色
    canvas.drawRRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
        ).createShader(rect.outerRect),
    );

    // 顶部高光条
    canvas.drawRRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment(0, 0.3),
          colors: [Color(0x22FFFFFF), Color(0x00FFFFFF)],
        ).createShader(rect.outerRect),
    );

    // 边框
    canvas.drawRRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white.withOpacity(0.08)
        ..strokeWidth = 1.0,
    );

    // 内机身
    final inner = RRect.fromRectAndRadius(
      Rect.fromLTWH(42, 62, 216, 176),
      const Radius.circular(20),
    );
    canvas.drawRRect(
      inner,
      Paint()..color = const Color(0xFF020617),
    );
  }

  void _drawLogo(Canvas canvas) {
    // 品牌 LOGO 区域（底部偏下）
    final textPainter = TextPainter(
      text: const TextSpan(
        text: 'CUKTECH',
        style: TextStyle(
          color: _logoColor,
          fontSize: 12,
          fontWeight: FontWeight.w300,
          letterSpacing: 2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    textPainter.paint(canvas, Offset(150 - textPainter.width / 2, 195));

    // LOGO 下方细线
    final linePaint = Paint()
      ..color = Colors.white.withOpacity(0.1)
      ..strokeWidth = 0.5;
    canvas.drawLine(
      const Offset(120, 210),
      const Offset(180, 210),
      linePaint,
    );
  }

  void _drawUsbPorts(Canvas canvas) {
    // USB-C（3 个圆口）
    for (final piid in [1, 2, 3]) {
      final pos = _usbCenters[piid]!;
      final paint = Paint()
        ..shader = const RadialGradient(
          center: Alignment.center,
          radius: 1.0,
          colors: [Color(0xFF94A3B8), Color(0xFF475569)],
        ).createShader(Rect.fromCircle(center: pos, radius: 16));

      // C 口圆孔
      canvas.drawCircle(pos, 16, paint);

      // C 口内部 — 三条 CC 触点线
      final innerPaint = Paint()
        ..color = const Color(0xFF1E293B)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(pos.dx - 8, pos.dy), Offset(pos.dx + 8, pos.dy), innerPaint);

      // 金属高光
      final highlightPaint = Paint()
        ..color = Colors.white.withOpacity(0.3)
        ..strokeWidth = 0.5;
      canvas.drawCircle(pos, 14, highlightPaint..style = PaintingStyle.stroke);
    }

    // USB-A（1 个矩形口）
    final aPos = _usbCenters[4]!;
    final aRect = Rect.fromCenter(center: aPos, width: 26, height: 18);
    final aRRect = RRect.fromRectAndRadius(aRect, const Radius.circular(4));

    final aPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFA8A29E), Color(0xFF57534E)],
      ).createShader(aRect);

    canvas.drawRRect(aRRect, aPaint);

    // A 口内部舌片
    final tonguePaint = Paint()..color = const Color(0xFF1C1917);
    final tongueRect = Rect.fromCenter(center: aPos, width: 18, height: 3);
    canvas.drawRect(tongueRect, tonguePaint);

    // A 口金属边框高光
    canvas.drawRRect(
      aRRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white.withOpacity(0.3)
        ..strokeWidth = 0.5,
    );
  }

  void _drawCenterEnergy(Canvas canvas) {
    final center = const Offset(150, 160);

    // 能量点脉动（根据活跃端口数）
    final activeCount = state.activePorts.length;
    final baseRadius = 4.0 + activeCount * 0.5;

    // 外环光晕
    if (activeCount > 0) {
      final glowPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            _centerEnergyColor.withOpacity(0.6),
            _centerEnergyColor.withOpacity(0.0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: 20));
      canvas.drawCircle(center, 20, glowPaint);
    }

    // 核心点
    final corePaint = Paint()..color =
        activeCount > 0 ? _centerEnergyColor.withOpacity(0.9) : Colors.white.withOpacity(0.15);
    canvas.drawCircle(center, baseRadius, corePaint);
  }

  void _drawLeds(Canvas canvas) {
    for (final entry in _ledPositions.entries) {
      final piid = entry.key;
      final pos = entry.value;
      final active = state.isActive(piid);
      final pulse = state.portPulse(piid); // 0~1

      if (active) {
        // 活跃 LED：光晕 + 核心
        final glowRadius = 8 + pulse * 6;
        final glowPaint = Paint()
          ..shader = RadialGradient(
            colors: [
              _ledActiveColor.withOpacity(0.8),
              _ledActiveColor.withOpacity(0.0),
            ],
          ).createShader(Rect.fromCircle(center: pos, radius: glowRadius));
        canvas.drawCircle(pos, glowRadius, glowPaint);

        // 核心
        canvas.drawCircle(
          pos,
          4 + pulse * 2,
          Paint()..color = Colors.white.withOpacity(0.9),
        );
      } else {
        // 非活跃：微弱常亮
        canvas.drawCircle(
          pos,
          3,
          Paint()..color = _ledIdleColor.withOpacity(0.5),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CuktechChargerPainter oldDelegate) {
    return state.activePorts != oldDelegate.state.activePorts ||
        state.portPulses.toString() != oldDelegate.state.portPulses.toString() ||
        state.glassEnabled != oldDelegate.state.glassEnabled;
  }
}
