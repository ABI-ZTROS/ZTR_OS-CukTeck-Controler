/// 辐射型端口快捷按钮
///
/// 4 个按钮按环形分布在充电头周围：
///   C1 (piid=1): angle = -135°
///   C2 (piid=2): angle =  -45°
///   C3 (piid=3): angle =   45°
///   A  (piid=4): angle =  135°
///
/// 交互：
///   单击 → onToggle（开/关端口）
///   长按 → onLongPress（弹出 Bottom Sheet）
///   双击 → onDoubleTap（进入详情页）
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cuktech_controller/protocol/constants.dart';
import 'package:cuktech_controller/ble/port_stream.dart';
import 'package:cuktech_controller/ui/theme/coloros_animations.dart';

class PortRadialButton extends StatefulWidget {
  const PortRadialButton({
    super.key,
    required this.piid,
    required this.state,
    this.angle = 0,
    this.radius = 200,
    this.size = 72,
    this.onToggle,
    this.onLongPress,
    this.onDoubleTap,
    this.heroTag,
  });

  final int piid;                // 1=C1, 2=C2, 3=C3, 4=A
  final PortState? state;        // null = 未连接
  final double angle;            // 角度（度数）
  final double radius;           // 距中心半径
  final double size;             // 按钮尺寸
  final VoidCallback? onToggle;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final String? heroTag;

  // 快捷：预计算位置
  Offset get position {
    final rad = angle * math.pi / 180;
    return Offset(
      math.cos(rad) * radius,
      math.sin(rad) * radius,
    );
  }

  String get portName => piidNames[piid] ?? '?';

  String get protocolLabel {
    final s = state;
    if (s == null) return '--';
    if (!s.active) return 'idle';
    return s.protocol;
  }

  @override
  State<PortRadialButton> createState() => _PortRadialButtonState();
}

class _PortRadialButtonState extends State<PortRadialButton> {
  double _scale = 1.0;
  Timer? _doubleTapTimer;
  bool _isDoubleTap = false;

  void _handleTapDown(_) => setState(() => _scale = 0.92);
  void _handleTapCancel() => setState(() => _scale = 1.0);

  void _handleTap() {
    if (_isDoubleTap) return;
    _doubleTapTimer?.cancel();
    _doubleTapTimer = Timer(const Duration(milliseconds: 250), () {
      if (!_isDoubleTap) widget.onToggle?.call();
      _reset();
    });
  }

  void _handleDoubleTap() {
    _doubleTapTimer?.cancel();
    _isDoubleTap = true;
    widget.onDoubleTap?.call();
    Future.delayed(const Duration(milliseconds: 300), _reset);
  }

  void _handleLongPress() {
    HapticFeedback.mediumImpact();
    widget.onLongPress?.call();
    setState(() => _scale = 1.0);
  }

  void _reset() {
    _isDoubleTap = false;
    setState(() => _scale = 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.state != null;
    final active = widget.state?.active ?? false;
    final power = widget.state?.power ?? 0.0;
    final voltage = widget.state?.voltage ?? 0.0;
    final current = widget.state?.current ?? 0.0;

    // 颜色映射
    final borderColor = active
        ? const Color(0xFF10B981)
        : connected
            ? const Color(0xFF6B7280).withOpacity(0.5)
            : const Color(0xFF374151).withOpacity(0.3);

    final bgColor = active
        ? const Color(0xFF10B981).withOpacity(0.15)
        : connected
            ? const Color(0xFF1F2937)
            : const Color(0xFF111827).withOpacity(0.5);

    final textColor = active
        ? Colors.white
        : connected
            ? Colors.white.withOpacity(0.9)
            : Colors.white.withOpacity(0.4);

    final powerText = active
        ? power.toStringAsFixed(1)
        : connected
            ? '${power.toStringAsFixed(1)}'
            : '--';

    final miniText = active
        ? '${voltage.toStringAsFixed(1)}V · ${current.toStringAsFixed(1)}A'
        : connected
            ? 'idle'
            : '未连接';

    return Transform.scale(
      scale: _scale,
      child: GestureDetector(
        onTapDown: _handleTapDown,
        onTapCancel: _handleTapCancel,
        onTapUp: (_) {
          HapticFeedback.lightImpact();
          setState(() => _scale = 1.0);
          _handleTap();
        },
        onLongPress: _handleLongPress,
        onDoubleTap: _handleDoubleTap,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor, width: 1.5),
            // 活跃时加光晕
            boxShadow: active
                ? [
                    BoxShadow(
                      color: const Color(0xFF10B981).withOpacity(0.3),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 顶部：端口名 + 协议
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    widget.portName,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 2),
                  if (active)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        widget.protocolLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              // 中部：功率
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  powerText,
                  key: ValueKey(powerText),
                  style: TextStyle(
                    color: active
                        ? const Color(0xFF10B981)
                        : textColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              Text(
                miniText,
                style: TextStyle(
                  color: textColor.withOpacity(0.7),
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
