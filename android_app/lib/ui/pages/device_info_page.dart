import 'package:flutter/material.dart';
import '../../protocol/token_service.dart';

class DeviceInfoPage extends StatefulWidget {
  const DeviceInfoPage({super.key});

  @override
  State<DeviceInfoPage> createState() => _DeviceInfoPageState();
}

class _DeviceInfoPageState extends State<DeviceInfoPage> {
  final TokenService _tokenService = TokenService.instance;
  String? _deviceName;
  String? _deviceModel;
  String? _deviceMac;
  String? _tokenMasked;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await _tokenService.getSaved();
    if (cfg != null) {
      setState(() {
        _deviceName = cfg.deviceName;
        _deviceModel = cfg.deviceModel;
        _deviceMac = cfg.deviceMac;
        final t = cfg.token;
        _tokenMasked = t.length >= 8
            ? '${t.substring(0, 4)}...${t.substring(t.length - 4)}'
            : t;
      });
    }
  }

  Future<void> _clearToken() async {
    await _tokenService.clearSaved();
    setState(() {
      _deviceName = null;
      _deviceModel = null;
      _deviceMac = null;
      _tokenMasked = null;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Token 已清除')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设备信息')),
      body: ListView(
        children: [
          _tile('设备名称', _deviceName ?? '--'),
          _tile('型号', _deviceModel ?? '--'),
          _tile('MAC', _deviceMac ?? '--'),
          _tile('Token', _tokenMasked ?? '--'),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('清除 Token', style: TextStyle(color: Colors.red)),
            onTap: _clearToken,
          ),
        ],
      ),
    );
  }

  Widget _tile(String label, String value) {
    return ListTile(
      title: Text(label, style: const TextStyle(color: Colors.grey)),
      subtitle: Text(value, style: const TextStyle(fontSize: 16)),
    );
  }
}
