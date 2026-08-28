import 'package:flutter/material.dart';
import '../../protocol/models.dart';

/// 扫描结果列表（支持空态/错误态复用）
class ScanResultList extends StatelessWidget {
  const ScanResultList({
    super.key,
    required this.devices,
    this.saving = false,
    this.onTap,
    this.onRescan,
    this.onSwitchManual,
  });

  final List<MiioDevice> devices;
  final bool saving;
  final ValueChanged<MiioDevice>? onTap;
  final VoidCallback? onRescan;
  final VoidCallback? onSwitchManual;

  String _mask(String t) =>
      t.length <= 8 ? t : '${t.substring(0, 4)}****${t.substring(t.length - 4)}';

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.inbox, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              const Text('未扫描到设备'),
              const SizedBox(height: 24),
              ElevatedButton(
                  onPressed: onRescan, child: const Text('重新扫描')),
              const SizedBox(height: 12),
              TextButton(
                  onPressed: onSwitchManual,
                  child: const Text('手动输入 Token')),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: devices.length,
      itemBuilder: (context, i) {
        final d = devices[i];
        return ListTile(
          leading: Icon(
            d.isCuktech ? Icons.bolt : Icons.devices,
            color: d.isCuktech ? Colors.indigo : Colors.grey,
          ),
          title: Text(d.name.isEmpty ? '(未命名设备)' : d.name,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
              '${d.model} · ${d.mac}\nToken: ${_mask(d.token)}',
              maxLines: 2),
          isThreeLine: true,
          trailing: saving
              ? const CircularProgressIndicator()
              : const Icon(Icons.chevron_right),
          onTap: saving ? null : (onTap == null ? null : () => onTap!(d)),
        );
      },
    );
  }
}

/// 扫描错误提示面板
class ScanErrorPanel extends StatelessWidget {
  const ScanErrorPanel({
    super.key,
    required this.errorCode,
    this.onRetry,
    this.onDowngrade,
    this.onManual,
    this.onCloud,
  });

  final String errorCode;
  final VoidCallback? onRetry;
  final VoidCallback? onDowngrade;
  final VoidCallback? onManual;
  final VoidCallback? onCloud;

  bool get _isRoot => errorCode == MiioDbErrors.noPermission;

  String _describe() {
    switch (errorCode) {
      case MiioDbErrors.noPermission:
        return '无法访问 miio2.db，可能原因：\n'
            '• 设备未获取 Root 权限\n'
            '• 米家 App 版本过高，数据库已加密\n\n'
            '请尝试降级米家 App 到 8.x 或手动输入 Token。';
      case MiioDbErrors.dbNotFound:
        return '未找到 miio2.db，请确认已安装米家 App 并至少登录过一次。';
      case MiioDbErrors.parseError:
        return '解析 miio2.db 失败，可能数据库结构已变更。';
      case MiioDbErrors.emptyResult:
        return '数据库中未读取到任何设备记录。';
      default:
        return '未知错误：$errorCode';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRoot = _isRoot;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 64, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(isRoot ? '无 Root 权限' : '扫描失败',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(_describe(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: onRetry, child: const Text('重试扫描')),
            if (isRoot) ...[
              const SizedBox(height: 12),
              TextButton(
                  onPressed: onDowngrade,
                  child: const Text('降级米家 App 版本')),
            ],
            const SizedBox(height: 12),
            OutlinedButton(
                onPressed: onManual, child: const Text('手动输入')),
            const SizedBox(height: 12),
            TextButton(onPressed: onCloud, child: const Text('云登录')),
          ],
        ),
      ),
    );
  }
}
