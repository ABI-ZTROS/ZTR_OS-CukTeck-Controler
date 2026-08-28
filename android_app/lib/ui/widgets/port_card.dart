import 'package:flutter/material.dart';
import '../../ble/port_stream.dart';
import '../../protocol/constants.dart';

/// 端口卡片
class PortCard extends StatelessWidget {
  const PortCard({
    super.key,
    required this.portName,
    this.state,
    this.onToggle,
    this.onOpenControl,
  });

  final String portName; // C1/C2/C3/A
  final PortState? state; // null = 未连接
  final VoidCallback? onToggle;
  final VoidCallback? onOpenControl;

  String get _display(double v) {
    // 未连接显示 --，活跃时才显示数值
    if (state == null) return '--';
    if (!state!.active && v == 0) return '--';
    return v.toStringAsFixed(1);
  }

  String get _protocol =>
      state == null ? '--' : (state!.active ? state!.protocol : 'idle');

  @override
  Widget build(BuildContext context) {
    final connected = state != null;
    final active = state?.active ?? false;

    return Card(
      margin: const EdgeInsets.all(8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: active
              ? Theme.of(context).colorScheme.primary.withAlpha(180)
              : Colors.grey.shade600,
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  portName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                _buildStatusChip(connected, active),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildMetric('V', _display(state?.voltage ?? 0)),
                _buildMetric('A', _display(state?.current ?? 0)),
                _buildMetric('W', _display(state?.power ?? 0)),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '协议: $_protocol',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: onToggle,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: active ? Colors.red : Colors.green,
                    ),
                    child: Text(active ? '关闭' : '开启'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: onOpenControl,
                    child: const Text('设置'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(bool connected, bool active) {
    final label = !connected
        ? '未连接'
        : active
            ? '充电中'
            : '空闲';
    final color = !connected
        ? Colors.grey
        : active
            ? Colors.green
            : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(50),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Text(label, style: TextStyle(fontSize: 12, color: color)),
    );
  }

  Widget _buildMetric(String unit, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        Text(unit, style: const TextStyle(color: Colors.grey, fontSize: 12)),
      ],
    );
  }
}
