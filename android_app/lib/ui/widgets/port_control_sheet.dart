/// 端口控制 Bottom Sheet
///
/// 长按 PortRadialButton 弹出
/// - 协议切换多选
/// - 倒计时关闭
/// - 端口开关
library;

import 'package:flutter/material.dart';
import 'package:cuktech_controller/protocol/constants.dart';
import 'package:cuktech_controller/protocol/port_control.dart';

class PortControlSheet extends StatefulWidget {
  const PortControlSheet({
    super.key,
    required this.piid,
    required this.portName,
    required this.isActive,
    required this.activeProtocols,
    this.onToggle,
    this.onProtocolsChanged,
    this.onCountdown,
  });

  final int piid;
  final String portName;
  final bool isActive;
  final Set<String> activeProtocols;
  final VoidCallback? onToggle;
  final ValueChanged<Set<String>>? onProtocolsChanged;
  final ValueChanged<Duration>? onCountdown;

  @override
  State<PortControlSheet> createState() => _PortControlSheetState();
}

class _PortControlSheetState extends State<PortControlSheet> {
  late Set<String> _protocols;
  Duration? _countdown;

  @override
  void initState() {
    super.initState();
    _protocols = Set.from(widget.activeProtocols);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 拖拽条
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 头部
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: widget.isActive
                          ? const Color(0xFF10B981).withOpacity(0.2)
                          : const Color(0xFF374151).withOpacity(0.3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Text(
                        widget.portName,
                        style: TextStyle(
                          color: widget.isActive
                              ? const Color(0xFF10B981)
                              : Colors.white.withOpacity(0.6),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '端口控制',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          widget.isActive ? '运行中' : '空闲',
                          style: TextStyle(
                            color: widget.isActive
                                ? const Color(0xFF10B981)
                                : Colors.white.withOpacity(0.5),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // 协议切换
              const Text('协议开关',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final proto in ['PD', 'UFCS', 'QC 3+', 'PPS'])
                    FilterChip(
                      label: Text(proto),
                      selected: _protocols.contains(proto),
                      onSelected: (selected) {
                        setState(() {
                          if (selected) {
                            _protocols.add(proto);
                          } else {
                            _protocols.remove(proto);
                          }
                        });
                        widget.onProtocolsChanged?.call(_protocols);
                      },
                      backgroundColor: const Color(0xFF1E293B),
                      selectedColor: const Color(0xFF3B82F6).withOpacity(0.3),
                      labelStyle: const TextStyle(color: Colors.white),
                      side: BorderSide(
                        color: _protocols.contains(proto)
                            ? const Color(0xFF3B82F6)
                            : Colors.white.withOpacity(0.2),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),

              // 倒计时
              const Text('倒计时关闭',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final mins in [15, 30, 60, 120])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: OutlinedButton(
                          onPressed: () {
                            final d = Duration(minutes: mins);
                            setState(() => _countdown = d);
                            widget.onCountdown?.call(d);
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(
                              color: Colors.white.withOpacity(0.2),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: Text('${mins}分'),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),

              // 开关按钮
              ElevatedButton(
                onPressed: () {
                  widget.onToggle?.call();
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.isActive
                      ? const Color(0xFFEF4444)
                      : const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(widget.isActive ? '关闭端口' : '开启端口'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
