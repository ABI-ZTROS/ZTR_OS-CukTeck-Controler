import 'package:flutter/material.dart';
import '../../utils/root/root_shell.dart';

/// Root 状态徽章（放 AppBar actions 或 header 里）
///
/// 行为：
///   - 按 RootState 变颜色 + 文字（KernelSU/Magisk/APatch）
///   - 单击 = 重新 tryAcquireRoot() 探测
///   - 长按 = 打开对应 root 管理器 App（KSU/Magisk/APatch 自动匹配）
///   - 非 available 状态：tooltip 显示 Kotlin 层返回的中文 suggestion
class RootStatusBadge extends StatefulWidget {
  const RootStatusBadge({super.key});

  @override
  State<RootStatusBadge> createState() => _RootStatusBadgeState();
}

class _RootStatusBadgeState extends State<RootStatusBadge> {
  final RootShell _rs = RootShell.instance;

  (MaterialColor color, String icon, String text, String? hint) _pick(RootStatus s) {
    switch (s.state) {
      case RootState.unknown:
        return (
          Colors.grey,
          '❔',
          'Root: 未检测',
          null,
        );
      case RootState.checking:
        return (
          Colors.blue,
          '🔎',
          'Root: 夺权中…',
          '正在尝试 su -c id（${s.managerDisplay}），请稍候'
        );
      case RootState.available:
        return (
          Colors.green,
          '✅',
          'Root: ${s.managerDisplay}',
          s.suggestion,
        );
      case RootState.none:
        return (
          Colors.grey,
          '❌',
          'Root: 无环境',
          s.suggestion,
        );
      case RootState.denied:
        return (
          Colors.red,
          '🚫',
          'Root: ${s.managerDisplay} 已拒绝',
          s.suggestion,
        );
      case RootState.timeout:
        return (
          Colors.orange,
          '⏳',
          'Root: ${s.managerDisplay} 超时',
          s.suggestion,
        );
      case RootState.error:
        return (
          Colors.red,
          '💥',
          'Root: 异常',
          s.suggestion ?? s.rawError,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RootStatus>(
      valueListenable: _rs.statusNotifier,
      builder: (BuildContext context, RootStatus s, Widget? child) {
        final p = _pick(s);
        final MaterialColor color = p.$1;
        final String icon = p.$2;
        final String text = p.$3;
        final String? hint = p.$4;

        return Tooltip(
          message: hint ?? text,
          padding: const EdgeInsets.all(10),
          preferBelow: false,
          showDuration: const Duration(milliseconds: 120),
          child: Material(
            color: color.shade50,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _onTap(context, s),
              onLongPress: () => _onLongPress(context, s),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  border: Border.all(color: color.shade300),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(icon, style: const TextStyle(fontSize: 14)),
                    const SizedBox(width: 6),
                    DefaultTextStyle(
                      style: TextStyle(
                        color: color.shade800,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      child: Text(text),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _onTap(BuildContext context, RootStatus s) async {
    if (s.state == RootState.checking) return;
    final RootStatus r = await _rs.tryAcquireRoot(
      timeoutMs: 5000,
      retries: 2,
      silentIfAvailable: false,
    );
    if (!mounted) return;
    if (r.isOk) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✅ 夺权成功：${r.managerDisplay}（uid=${r.uid}）'),
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 2),
      ));
    } else {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (BuildContext ctx) => _RootTroubleshootSheet(
          status: r,
        ),
      );
    }
  }

  Future<void> _onLongPress(BuildContext context, RootStatus s) async {
    // 尝试自动匹配当前检测到的 manager
    if (s.manager == RootManager.none) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('没有检测到 KernelSU / Magisk / APatch，无法打开管理器'),
      ));
      return;
    }
    final bool ok = await _rs.openRootManager('auto');
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          '未找到已安装的 ${s.managerDisplay} App，'
          '请先在 KernelSU/Magisk 官网下载并安装管理器。',
        ),
      ));
    }
  }
}

class _RootTroubleshootSheet extends StatelessWidget {
  const _RootTroubleshootSheet({required this.status});
  final RootStatus status;

  @override
  Widget build(BuildContext context) {
    final String title = switch (status.state) {
      RootState.timeout => '⏳ 授权等待超时',
      RootState.denied => '🚫 授权被拒绝',
      RootState.none => '❌ 未检测到 Root 环境',
      RootState.error => '💥 执行异常',
      _ => '提示',
    };
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                status.suggestion ?? '（无附加提示）',
                style: const TextStyle(height: 1.6, fontSize: 14),
              ),
            ),
            if (status.rawError != null && status.rawError!.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('错误详情（开发者可见）：',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 4),
              SelectableText(
                status.rawError!,
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            if (status.suVersion != null && status.suVersion!.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('su -V 版本输出：',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
              SelectableText(
                status.suVersion!,
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: <Widget>[
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试夺权'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      RootShell.instance.tryAcquireRoot(
                        timeoutMs: 5000,
                        retries: 2,
                        silentIfAvailable: false,
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new),
                    label: Text('打开${status.manager.displayName}'),
                    onPressed: status.manager == RootManager.none
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            RootShell.instance.openRootManager('auto');
                          },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
