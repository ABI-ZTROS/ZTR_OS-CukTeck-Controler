/// 主页 — ColorOS 中心辐射型
///
/// 上半屏：充电头 SVG + 总功率环 + 4 端口快捷按钮
/// 下半屏：快捷操作区（全部开/关）+ 设置入口
///
/// 动画：并行动画入场（极光引擎风格）
///   - 充电头 scale 0.3→1.0 + fade
///   - 功率环 sweep 0→full
///   - 4 按钮 stagger 50ms 依次入场
///   - 连接成功 → 弹性微放大
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:cuktech_controller/ble/android_scanner.dart';
import 'package:cuktech_controller/ble/android_connector.dart';
import 'package:cuktech_controller/ble/port_decoder_wiring.dart';
import 'package:cuktech_controller/ble/port_stream.dart';
import 'package:cuktech_controller/protocol/authenticator.dart';
import 'package:cuktech_controller/protocol/constants.dart';
import 'package:cuktech_controller/protocol/port_control.dart';
import 'package:cuktech_controller/protocol/token_service.dart';
import 'package:cuktech_controller/protocol/settings.dart';
import 'package:cuktech_controller/ui/theme/coloros_animations.dart';

import '../widgets/charger_visual/charger_visual_widget.dart';
import '../widgets/power_ring.dart';
import '../widgets/port_radial_button.dart';
import '../widgets/status_banner.dart';
import '../widgets/port_control_sheet.dart';
import 'device_info_page.dart';
import 'log_page.dart';
import 'settings_page.dart';
import 'token_import_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  final AndroidScanner _scanner = AndroidScanner.instance;
  final AndroidConnector _connector = AndroidConnector.instance;
  final TokenService _tokenService = TokenService.instance;

  // ===== 状态 =====
  bool _isScanning = false;
  bool _isConnecting = false;
  bool _isConnected = false;
  int _currentStep = -1;
  String? _errorMessage;
  Map<int, PortState> _portStates = {};

  // ===== 动画 =====
  late final AnimationController _entranceController;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  // ===== 订阅 =====
  late final List<StreamSubscription<PortState>> _subs;

  final List<String> _authSteps = const [
    '设备初始化',
    '密钥交换',
    '发送随机密钥',
    'HMAC 双向验证',
    '登录完成',
  ];

  @override
  void initState() {
    super.initState();
    Settings.instance.load();
    _setupEntranceAnimation();
    _setupPortSubscriptions();
    _entranceController.forward();
    _checkSavedToken();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    for (final s in _subs) s.cancel();
    super.dispose();
  }

  void _setupEntranceAnimation() {
    _entranceController = AnimationController(
      vsync: this,
      duration: ColorOS.dEmphasis,
    );

    // ColorOS Standard 曲线 + 弹性收尾
    _scaleAnim = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController, curve: ColorOS.standard),
    );

    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController, curve: ColorOS.enter),
    );
  }

  void _setupPortSubscriptions() {
    _subs = [
      PortStreamController.instance.watch(1).listen((s) => _updatePort(1, s)),
      PortStreamController.instance.watch(2).listen((s) => _updatePort(2, s)),
      PortStreamController.instance.watch(3).listen((s) => _updatePort(3, s)),
      PortStreamController.instance.watch(4).listen((s) => _updatePort(4, s)),
    ];
  }

  void _updatePort(int piid, PortState state) {
    setState(() => _portStates[piid] = state);
  }

  Future<void> _checkSavedToken() async {
    final cfg = await _tokenService.getSaved();
    if (cfg != null && cfg.isValid) {
      _startScan();
    } else if (!mounted) {
      // 跳转到 TokenImportPage
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TokenImportPage()),
      );
    }
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _errorMessage = null;
    });
    try {
      final results = await _scanner.start();
      if (results.isNotEmpty) {
        await _connect(results.first);
      } else {
        setState(() {
          _isScanning = false;
          _errorMessage = '未发现设备，请确认充电器已通电';
        });
      }
    } catch (e) {
      setState(() {
        _isScanning = false;
        _errorMessage = '扫描失败: $e';
      });
    }
  }

  Future<void> _connect(CuktechScanResult result) async {
    setState(() {
      _isConnecting = true;
      _currentStep = 0;
    });
    try {
      final ok = await _connector.connect(result.device);
      for (var i = 0; i < _authSteps.length; i++) {
        setState(() => _currentStep = i);
        await Future.delayed(const Duration(milliseconds: 300));
      }
      if (!ok) throw Exception("BLE 连接失败");
      // Authenticator 会在 connect 内部完成认证
      await Future.delayed(const Duration(milliseconds: 200));
      setState(() {
        _isConnecting = false;
        _isConnected = true;
        _currentStep = -1;
      });
      await wirePortDecoder(_connector);
    } catch (e) {
      setState(() {
        _isConnecting = false;
        _errorMessage = '连接失败: $e';
      });
    }
  }

  Future<void> _togglePort(int piid) async {
    if (!_isConnected) return;
    try {
      final portKey = piid == 1 ? 'C1' : piid == 2 ? 'C2' : piid == 3 ? 'C3' : 'A';
      final currentState = _portStates[piid];
      final targetOn = !(currentState?.active ?? false);
      await PortControl.instance.setPort(_connector, portKey, targetOn);
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('端口控制失败: $e')),
        );
      }
    }
  }

  Future<void> _allOn() async {
    for (final piid in const [1, 2, 3, 4]) {
      final s = _portStates[piid];
      if (s != null && !s.active) await _togglePort(piid);
    }
  }

  Future<void> _allOff() async {
    for (final piid in const [1, 2, 3, 4]) {
      final s = _portStates[piid];
      if (s != null && s.active) await _togglePort(piid);
    }
  }

  void _showPortSheet(int piid) {
    final s = _portStates[piid];
    final protocols = <String>{'PD', 'UFCS', 'QC 3+', 'PPS'};
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      transitionAnimationController: _entranceController,
      builder: (_) => PortControlSheet(
        piid: piid,
        portName: piidNames[piid] ?? '?',
        isActive: s?.active ?? false,
        activeProtocols: protocols,
        onToggle: () => _togglePort(piid),
      ),
    );
  }

  // ===== 计算属性 =====
  Set<int> get _activePorts {
    return _portStates.entries
        .where((e) => e.value.active)
        .map((e) => e.key)
        .toSet();
  }

  double get _totalPower {
    return _portStates.values.fold(
        0.0, (sum, s) => sum + (s.active ? s.power : 0.0));
  }

  int get _activeCount => _activePorts.length;

  // ===== 构建 =====
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0F1E),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _entranceController,
          builder: (context, _) {
            return FadeTransition(
              opacity: _fadeAnim,
              child: RefreshIndicator(
                onRefresh: () async => _startScan(),
                backgroundColor: const Color(0xFF3B82F6),
                color: Colors.white,
                child: CustomScrollView(
                  slivers: [
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Column(
                        children: [
                          _buildHeader(),
                          const SizedBox(height: 8),
                          StatusBanner(
                            steps: _authSteps,
                            currentStep: _currentStep,
                            isConnecting: _isConnecting,
                            errorMessage: _errorMessage,
                            onRetry: _isScanning ? null : _startScan,
                          ),
                          const SizedBox(height: 12),
                          _buildCenter(),
                          const SizedBox(height: 24),
                          _buildActions(),
                          const Spacer(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _isConnected
                  ? const Color(0xFF10B981).withOpacity(0.2)
                  : _isConnecting
                      ? const Color(0xFFF59E0B).withOpacity(0.2)
                      : const Color(0xFFEF4444).withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _isConnected
                        ? const Color(0xFF10B981)
                        : _isConnecting
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFFEF4444),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _isConnected ? '已连接' : _isConnecting ? '连接中' : '未连接',
                  style: TextStyle(
                    color: _isConnected
                        ? const Color(0xFF10B981)
                        : _isConnecting
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFFEF4444),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white70),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline, color: Colors.white70),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DeviceInfoPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.code, color: Colors.white70),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LogPage()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCenter() {
    // 中心辐射布局：Stack + Positioned
    // 中心：充电头 + 功率环
    // 周围：4 个 PortRadialButton（stagger 入场）
    const ringSize = 260.0;
    const chargerSize = 180.0;

    return SizedBox(
      height: 420,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 功率环（最外层）
          AnimatedScale(
            scale: _scaleAnim.value,
            duration: ColorOS.dSpring,
            curve: Curves.easeOut,
            child: PowerRing(
              totalPower: _totalPower,
              maxPower: 240,
              activePortCount: _activeCount,
              size: const Size(ringSize, ringSize),
            ),
          ),

          // 充电头 SVG
          AnimatedScale(
            scale: _scaleAnim.value,
            duration: ColorOS.dSpring,
            curve: Curves.easeOut,
            child: ChargerVisualWidget(
              activePorts: _activePorts,
              size: const Size(chargerSize, chargerSize),
            ),
          ),

          // 4 个端口按钮（环形分布，stagger 入场）
          for (final entry in _radialPositions().entries)
            _buildStaggeredPortButton(entry.key, entry.value),
        ],
      ),
    );
  }

  Map<int, Offset> _radialPositions() {
    // 4 按钮，以中心为原点
    // C1 (-135°): 左上 → (-180, -180)
    // C2 (-45°):  右上 → (180, -180)
    // C3 (45°):   右下 → (180, 180)
    // A  (135°):  左下 → (-180, 180)
    const radius = 185.0;
    final map = <int, Offset>{};
    const angles = <int, double>{1: -135, 2: -45, 3: 45, 4: 135};
    for (final a in angles.entries) {
      final rad = a.value * math.pi / 180;
      map[a.key] = Offset(
        math.cos(rad) * radius,
        math.sin(rad) * radius,
      );
    }
    return map;
  }

  Widget _buildStaggeredPortButton(int piid, Offset offset) {
    final staggerDelay = piid * 50; // 每个按钮延迟 50ms
    final animationDuration = ColorOS.dNormal;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: animationDuration,
      curve: Curves.easeOut,
      builder: (context, value, _) {
        // 利用 4 个 piid 用不同的初始延迟值来 stagger
        // 简化：直接在布局层用 Transform + Opacity
        return Transform.translate(
          offset: offset * value,
          child: Opacity(
            opacity: value,
            child: PortRadialButton(
              piid: piid,
              state: _portStates[piid],
              angle: piid == 1 ? -135 : piid == 2 ? -45 : piid == 3 ? 45 : 135,
              radius: 185,
              size: 72,
              onToggle: _isConnected ? () => _togglePort(piid) : null,
              onLongPress: _isConnected ? () => _showPortSheet(piid) : null,
            ),
          ),
        );
      },
    );
  }

  Widget _buildActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _isConnected ? _allOff : null,
              icon: const Icon(Icons.power_settings_new, size: 18),
              label: const Text('全部关闭'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: BorderSide(color: Colors.white.withOpacity(0.2)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: _isConnected ? _allOn : null,
              icon: const Icon(Icons.flash_on, size: 18),
              label: const Text('全部开启'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
