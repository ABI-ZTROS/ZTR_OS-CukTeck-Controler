import 'package:flutter/material.dart';
import '../../protocol/models.dart';
import '../../protocol/secure_token_store.dart';
import '../../protocol/token_service.dart';
import '../../utils/logger/logger.dart';
import '../widgets/manual_token_form.dart';
import '../widgets/scan_widgets.dart';

/// Token 导入页 —— 扫描米家设备（miio2.db）/ 手动输入 / 云登录
class TokenImportPage extends StatefulWidget {
  const TokenImportPage({Key? key}) : super(key: key);

  @override
  State<TokenImportPage> createState() => _TokenImportPageState();
}

enum _PageMode { home, scanning, scanResult, scanError, manual, cloud }

class _TokenImportPageState extends State<TokenImportPage> {
  final TokenService _svc = TokenService.instance;
  final SecureTokenStore _store = SecureTokenStore.instance;

  _PageMode _mode = _PageMode.home;
  List<MiioDevice> _devices = const []; // 真实数据，无 Mock
  String? _errorCode;
  bool _saving = false;
  Map<String, String>? _initialForm;

  @override
  void initState() {
    super.initState();
    _loadExistingToken();
  }

  Future<void> _loadExistingToken() async {
    final cfg = await _svc.getSaved();
    if (cfg != null && cfg.isValid && mounted) {
      setState(() {
        _initialForm = <String, String>{
          'token': cfg.token,
          'key': cfg.key,
          'userId': cfg.userId,
          'did': cfg.did,
        };
      });
    }
  }

  Future<void> _startScan() async {
    setState(() {
      _mode = _PageMode.scanning;
      _devices = const [];
      _errorCode = null;
    });
    try {
      final r = await _svc.scanLocalDevices();
      if (!mounted) return;
      setState(() {
        _devices = r.devices;
        _errorCode = r.success ? null : r.errorCode;
        _mode = r.success ? _PageMode.scanResult : _PageMode.scanError;
      });
    } catch (e, stackTrace) {
      AppLogger.instance.e('TokenImportPage', 'scan error: $e');
      if (!mounted) return;
      setState(() {
        _errorCode = MiioDbErrors.parseError;
        _mode = _PageMode.scanError;
      });
    }
  }

  Future<void> _selectAndSave(MiioDevice device) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final cfg = await _svc.selectAndSave(device);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已保存设备：${cfg.deviceName.isEmpty ? cfg.did : cfg.deviceName}',
          ),
        ),
      );
      Navigator.of(context).pop(cfg);
    } catch (e) {
      AppLogger.instance.e('TokenImportPage', 'select failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _handleManualSubmit(Map<String, String> v) async {
    if (_saving) return;
    final cfg = TokenConfig(
      token: v['token']!,
      key: v['key']!,
      did: v['did']!,
      userId: v['userId']!,
    );
    if (!cfg.isValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Token 必须为 32 位十六进制字符串')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await _store.write(cfg);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Token 保存成功')));
      Navigator.of(context).pop(cfg);
    } catch (e, stackTrace) {
      AppLogger.instance.e('TokenImportPage', 'manual save failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _handleManualClear() async {
    await _store.clear();
    if (!mounted) return;
    setState(() => _initialForm = null);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Token 已清除')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('导入 Token'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_mode == _PageMode.home || _mode == _PageMode.manual) {
              Navigator.of(context).pop();
            } else {
              setState(() => _mode = _PageMode.home);
            }
          },
        ),
      ),
      body: switch (_mode) {
        _PageMode.home => _buildHome(),
        _PageMode.scanning => const _CenterWait(),
        _PageMode.scanResult => ScanResultList(
            devices: _devices,
            saving: _saving,
            onTap: _selectAndSave,
            onRescan: _startScan,
            onSwitchManual: () => setState(() => _mode = _PageMode.manual),
          ),
        _PageMode.scanError => ScanErrorPanel(
            errorCode: _errorCode ?? MiioDbErrors.parseError,
            onRetry: _startScan,
            onDowngrade: _openDowngradeGuide,
            onManual: () => setState(() => _mode = _PageMode.manual),
            onCloud: () => setState(() => _mode = _PageMode.cloud),
          ),
        _PageMode.manual => ManualTokenForm(
            initial: _initialForm,
            saving: _saving,
            onSubmit: _handleManualSubmit,
            onClear: _handleManualClear,
          ),
        _PageMode.cloud => _buildCloud(),
      },
    );
  }

  Widget _buildHome() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Icon(Icons.security, size: 72, color: Colors.indigo),
              const SizedBox(height: 24),
              const Text('选择 Token 导入方式',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                  icon: const Icon(Icons.radar),
                  label: const Text('扫描米家设备'),
                  onPressed: _startScan,
                  style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16))),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  icon: const Icon(Icons.edit),
                  label: const Text('手动输入'),
                  onPressed: () => setState(() => _mode = _PageMode.manual),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16))),
              const SizedBox(height: 12),
              TextButton.icon(
                  icon: const Icon(Icons.cloud),
                  label: const Text('云登录'),
                  onPressed: () => setState(() => _mode = _PageMode.cloud)),
            ],
          ),
        ),
      );

  Widget _buildCloud() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.cloud, size: 72, color: Colors.indigo),
              const SizedBox(height: 16),
              const Text('云端登录',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                  '即将跳转到小米账号授权页面，登录后自动同步你的设备列表。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  // TODO: 接入 qr_login.dart 云端登录流程
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('云登录尚未实现')),
                  );
                },
                child: const Text('开始云登录'),
              ),
              const SizedBox(height: 12),
              TextButton(
                  onPressed: () => setState(() => _mode = _PageMode.home),
                  child: const Text('返回')),
            ],
          ),
        ),
      );

  void _openDowngradeGuide() {
    // TODO: 打开降级米家 App 的说明页或浏览器链接
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('降级指引尚未实现')));
  }
}

class _CenterWait extends StatelessWidget {
  const _CenterWait();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('正在读取 miio2.db...'),
        ],
      ),
    );
  }
}
