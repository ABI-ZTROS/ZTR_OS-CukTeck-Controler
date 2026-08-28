import 'package:flutter/material.dart';
import '../../ble/android_connector.dart';
import '../../protocol/constants.dart';
import '../../protocol/settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SettingsService _settings = SettingsService.instance;
  final AndroidConnector _connector = AndroidConnector.instance;

  int _sceneMode = 1;
  int _screenOffTime = 2;
  int _language = 1;
  int _usbSmallCurrent = 0;
  int _idleScreenOff = 0;
  int _screenOrientationLock = 0;
  int _globalTimer = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final vals = await Future.wait<int?>([
        _settings.getSceneMode(_connector),
        _settings.getScreenOffTime(_connector),
        _settings.read(_connector, 13),
        _settings.read(_connector, 15),
        _settings.read(_connector, 19),
        _settings.read(_connector, 20),
        _settings.getGlobalTimer(_connector),
      ]);
      setState(() {
        _sceneMode = vals[0] ?? 1;
        _screenOffTime = vals[1] ?? 2;
        _language = vals[2] ?? 1;
        _usbSmallCurrent = vals[3] ?? 0;
        _idleScreenOff = vals[4] ?? 0;
        _screenOrientationLock = vals[5] ?? 0;
        _globalTimer = vals[6] ?? 0;
      });
    } catch (e) {
      // 未连接时保持默认值
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _buildDropdown(
            '场景模式',
            _sceneMode,
            const {1: 'AI模式', 2: '数码生态', 3: '单口模式', 4: '均衡模式'},
            (v) => _settings.setSceneMode(_connector, v!),
            (v) => setState(() => _sceneMode = v!),
          ),
          _buildDropdown(
            '息屏时间',
            _screenOffTime,
            const {1: '5分钟', 2: '10分钟', 3: '30分钟', 4: '常亮', 5: '1分钟'},
            (v) => _settings.setScreenOffTime(_connector, v!),
            (v) => setState(() => _screenOffTime = v!),
          ),
          _buildDropdown(
            '语言',
            _language,
            const {0: 'English', 1: '中文'},
            (v) => _settings.write(_connector, 13, v!),
            (v) => setState(() => _language = v!),
          ),
          _buildSwitch(
            'USB-A 小电流',
            _usbSmallCurrent == 1,
            (on) => _settings.setUsbASmallCurrent(_connector, on),
            (on) => setState(() => _usbSmallCurrent = on ? 1 : 0),
          ),
          _buildSwitch(
            '空闲息屏',
            _idleScreenOff == 1,
            (on) => _settings.setIdleScreenOff(_connector, on),
            (on) => setState(() => _idleScreenOff = on ? 1 : 0),
          ),
          _buildSwitch(
            '屏幕方向锁',
            _screenOrientationLock == 1,
            (on) => _settings.setScreenOrientationLock(_connector, on),
            (on) => setState(() => _screenOrientationLock = on ? 1 : 0),
          ),
          _buildGlobalTimer(),
        ],
      ),
    );
  }

  Widget _buildDropdown(
    String label,
    int current,
    Map<int, String> options,
    Future<void> Function(int?) onSave,
    void Function(int?) onLocal,
  ) {
    return ListTile(
      title: Text(label),
      trailing: DropdownButton<int>(
        value: current,
        items: options.entries
            .map((e) => DropdownMenuItem<int>(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: (v) async {
          onLocal(v);
          await onSave(v);
        },
      ),
    );
  }

  Widget _buildSwitch(
    String label,
    bool current,
    Future<void> Function(bool) onSave,
    void Function(bool) onLocal,
  ) {
    return ListTile(
      title: Text(label),
      trailing: Switch(
        value: current,
        onChanged: (v) async {
          onLocal(v);
          await onSave(v);
        },
      ),
    );
  }

  Widget _buildGlobalTimer() {
    return ListTile(
      title: const Text('总倒计时 (分钟)'),
      subtitle: const Text('设置所有端口的总倒计时时间，0 表示关闭'),
      trailing: SizedBox(
        width: 80,
        child: TextFormField(
          initialValue: _globalTimer.toString(),
          keyboardType: TextInputType.number,
          textAlign: TextAlign.right,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
          onFieldSubmitted: (v) async {
            final min = int.tryParse(v) ?? 0;
            await _settings.setGlobalTimer(_connector, min);
            setState(() => _globalTimer = min);
          },
        ),
      ),
    );
  }
}
