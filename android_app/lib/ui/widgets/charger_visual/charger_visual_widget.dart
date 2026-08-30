/// 充电头动画容器
///
/// 管理 4 路 LED 呼吸 AnimationController
/// 以及向外暴露的 [ChargerPaintState] 给 CustomPainter
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:cuktech_controller/ui/theme/coloros_animations.dart';

import 'cuktech_charger_painter.dart';

class ChargerVisualWidget extends StatefulWidget {
  const ChargerVisualWidget({
    super.key,
    this.activePorts = const {},
    this.glassEnabled = true,
    this.size = const Size(220, 220),
  });

  final Set<int> activePorts;
  final bool glassEnabled;
  final Size size;

  @override
  State<ChargerVisualWidget> createState() => _ChargerVisualWidgetState();
}

class _ChargerVisualWidgetState extends State<ChargerVisualWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  // 4 个端口独立的 LED 呼吸相位
  final Map<int, double> _phases = {1: 0.0, 2: 0.25, 3: 0.5, 4: 0.75};

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500), // 单相位时长
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // 计算每个端口独立的呼吸值（正弦波，各端口有相位差）
        final portPulses = <int, double>{};
        for (final piid in const [1, 2, 3, 4]) {
          final phase = _phases[piid]!;
          // 使用 0.5Hz 周期（呼吸 2 秒一次）+ 相位偏移
          final t = (_controller.value + phase) * 2 * math.pi;
          portPulses[piid] = (math.sin(t) + 1) / 2; // 0~1
        }

        final state = ChargerPaintState(
          activePorts: widget.activePorts,
          portPulses: portPulses,
          glassEnabled: widget.glassEnabled,
        );

        return SizedBox(
          width: widget.size.width,
          height: widget.size.height,
          child: CustomPaint(
            painter: CuktechChargerPainter(state),
            size: widget.size,
          ),
        );
      },
    );
  }
}
