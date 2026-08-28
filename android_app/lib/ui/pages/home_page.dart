import 'dart:async';

import 'package:flutter/material.dart';
import '../../ble/android_scanner.dart';
import '../../ble/android_connector.dart';
import '../../ble/port_decoder_wiring.dart';
import '../../ble/port_stream.dart';
import '../../protocol/authenticator.dart';
import '../../protocol/constants.dart';
import '../../protocol/token_service.dart';
import '../widgets/port_card.dart';
import '../widgets/status_banner.dart';
import 'device_info_page.dart';
import 'log_page.dart';
import 'port_control_page.dart';
import 'settings_page.dart';
import 'token_import_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final AndroidScanner _scanner = AndroidScanner.instance;
  final AndroidConnector _connector = AndroidConnector.instance;
  final TokenService _tokenService = TokenService.instance;

  bool _isScanning = false;
  bool _isConnecting = false;
  int _currentStep = -1;
  String? _errorMessage;
  List<CuktechScanResult> _scanResults = const [];
  Map<int, PortState> _portStates = {}; // piid=1..4

  late final StreamSubscription<PortState> _subC1;
  late final StreamSubscription<PortState> _subC2;
  late final StreamSubscription<PortState> _subC3;
  late final StreamSubscription<PortState> _subA;

  final List<String> _authSteps = const [
    '设备初始化 (0xa4)',
    '密钥交换',
    '发送随机密钥',
    'HMAC 双向验证',
    '登录完成',
  ];

  @override
  void initState() {
    super.initState();
    // 订阅 4 路端口广播
    _subC1 = PortStreamController.instance.watch(1).listen((s) => _updatePort(1, s));
    _subC2 = PortStreamController.instance.watch(2).listen((s) => _updatePort(2, s));
    _subC3 = PortStreamController.instance.watch(3).listen((s) => _updatePort(3, s));
    _subA = PortStreamController.instance.watch(4).listen((s) => _updatePort(4, s));
    _checkSavedToken();
  }

  @override
  void dispose() {
    _subC1.cancel();
    _subC2.cancel();
    _subC3.cancel();
    _subA.cancel();
    super.dispose();
  }

  void _updatePort(int piid, PortState state) {
    setState(() {
      _portStates[piid] = state;
    });
  }

  Future<void> _checkSavedToken() async {
    final cfg = await _tokenService.getSaved();
    if (cfg == null || !cfg.isValid) {
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TokenImportPage()),
        );
      }
    }
  }

  Future<void> _scanAndConnect() async {
    setState(() {
      _isScanning = true;
      _errorMessage = null;
      _currentStep = -1;
    });
    try {
      final results = await _scanner.start();
      setState(() => _scanResults = results);
      final target = _firstOrNull(results.where((r) => r.isCuktech));
      if (target == null) {
        setState(() {
          _isScanning = false;
          _errorMessage = '未扫描到酷态科设备';
        });
        return;
      }
      await _connectTo(target);
    } catch (e) {
      setState(() {
        _isScanning = false;
        _errorMessage = '扫描失败: $e';
      });
    }
  }

  Future<void> _connectTo(CuktechScanResult target) async {
    setState(() {
      _isConnecting = true;
      _currentStep = 0;
      _errorMessage = null;
    });
    final ok = await _connector.connect(target.device);
    if (!ok) {
      setState(() {
        _isConnecting = false;
        _currentStep = -1;
        _errorMessage = '连接失败';
      });
      return;
    }
    setState(() => _currentStep = 1);

    // Authenticate
    final cfg = await _tokenService.getSaved();
    if (cfg == null || !cfg.isValid) {
      setState(() {
        _isConnecting = false;
        _currentStep = -1;
        _errorMessage = '未配置 Token，请先导入';
      });
      await _connector.disconnect();
      return;
    }

    final authed = await Authenticator.instance.authenticate(_connector, cfg.token);
    if (!authed) {
      setState(() {
        _isConnecting = false;
        _currentStep = -1;
        _errorMessage = '认证失败：Token 无效或设备无响应';
      });
      await _connector.disconnect();
      return;
    }
    setState(() => _currentStep = 4);

    // Wire up port decoder
    await wirePortDecoder(_connector);

    setState(() {
      _isConnecting = false;
      _currentStep = -1;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('连接成功')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('酷态科控制器'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.info),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DeviceInfoPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.list_alt),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LogPage()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          StatusBanner(
            steps: _authSteps,
            currentStep: _currentStep,
            isConnecting: _isConnecting,
            errorMessage: _errorMessage,
            onRetry: _scanAndConnect,
            onCancel: () {
              setState(() {
                _isScanning = false;
                _isConnecting = false;
                _currentStep = -1;
                _errorMessage = null;
              });
            },
          ),
          Expanded(child: _buildContent()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning || _isConnecting ? null : _scanAndConnect,
        icon: Icon(_isScanning ? Icons.hourglass_empty : Icons.bluetooth_searching),
        label: Text(_isScanning ? '扫描中' : '开始扫描'),
      ),
    );
  }

  Widget _buildContent() {
    final bool connected = _connector.state == BleConnectionState.ready;
    if (!connected && _portStates.isEmpty) {
      return const Center(
        child: Text(
          '未连接，请点击下方按钮开始扫描',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return GridView.count(
      crossAxisCount: 2,
      childAspectRatio: 0.75,
      children: List.generate(4, (i) {
        final piid = i + 1;
        final name = const ['C1', 'C2', 'C3', 'A'][i];
        return PortCard(
          portName: name,
          state: _portStates[piid],
          onToggle: () => _gotoControl(piid),
          onOpenControl: () => _gotoControl(piid),
        );
      }),
    );
  }

  void _gotoControl(int piid) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PortControlPage(piid: piid),
      ),
    );
  }

  T? _firstOrNull<T>(Iterable<T> iter) {
    for (final e in iter) return e;
    return null;
  }
}
