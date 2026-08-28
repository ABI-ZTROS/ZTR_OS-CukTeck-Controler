import 'package:flutter/material.dart';

/// 连接状态 Banner
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.steps,
    required this.currentStep,
    required this.isConnecting,
    required this.errorMessage,
    this.onRetry,
    this.onCancel,
  });

  final List<String> steps;
  final int currentStep; // -1 = 未开始, 0..N-1
  final bool isConnecting;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    if (errorMessage != null) {
      return _buildError(context);
    }
    if (!isConnecting && currentStep < 0) {
      return const SizedBox.shrink();
    }
    return _buildProgress(context);
  }

  Widget _buildProgress(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('连接中...', style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          ...List.generate(steps.length, (i) {
            final done = i < currentStep;
            final current = i == currentStep;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    done ? Icons.check_circle : current ? Icons.radio_button_checked : Icons.circle,
                    size: 16,
                    color: done ? Colors.green : current ? Colors.blue : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      steps[i],
                      style: TextStyle(
                        color: done || current ? Colors.white : Colors.grey,
                        decoration: done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
          if (onCancel != null) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: onCancel, child: const Text('取消')),
          ],
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withAlpha(50),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.error, color: Colors.red),
              SizedBox(width: 8),
              Text('连接失败',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
            ],
          ),
          const SizedBox(height: 8),
          Text(errorMessage!, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          if (onRetry != null)
            ElevatedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
