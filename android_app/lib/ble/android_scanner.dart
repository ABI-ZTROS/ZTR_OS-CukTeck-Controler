import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../utils/logger/logger.dart';
import '../protocol/constants.dart';

/// 扫描结果
class CuktechScanResult {
  const CuktechScanResult({
    required this.device,
    required this.rssi,
    required this.localName,
    required this.isCuktech,
  });
  final BluetoothDevice device;
  final int rssi;
  final String localName;
  final bool isCuktech;
}

/// Android BLE 扫描器（基于 flutter_blue_plus）
///
/// 🔑 识别策略（和 Python 参照完全一致）：
///   - **主要标识**: Service UUID 0xFE95 — 小米 IoT 设备广播服务
///   - **次要标识**: 名字/MAC 中的 cuktech 关键词（仅用于日志和标记，不做过滤）
///   - **权威验证**: 连接后用 beaconKey 做 MiOT 认证 — 这才是最终判定
///
/// ⚠️ 为什么不靠名字？米家可以远程改设备蓝牙广播名！
///    一旦改名成 "酷态科充电器" 或别的，`contains('njcuk')` 就挂了。
///    Service UUID 0xFE95 是芯片硬编码，永远不变。
class AndroidScanner {
  AndroidScanner._();
  static final AndroidScanner instance = AndroidScanner._();

  final List<CuktechScanResult> _results = <CuktechScanResult>[];
  StreamSubscription<List<ScanResult>>? _sub;
  bool _isScanning = false;

  bool get isScanning => _isScanning;
  List<CuktechScanResult> get results => List<CuktechScanResult>.unmodifiable(_results);

  /// 开始扫描
  ///
  /// [timeout] 扫描时长（默认 10 秒）
  /// [filterCuktech] 是否仅显示酷态科设备（已硬编码：只有 0xFE95 才算）
  Future<List<CuktechScanResult>> start({
    Duration timeout = const Duration(seconds: 10),
    bool filterCuktech = true,
  }) async {
    if (_isScanning) {
      AppLogger.instance.w('AndroidScanner', 'Already scanning');
      return results;
    }
    _results.clear();
    _isScanning = true;

    try {
      _sub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          final name = r.advertisementData.localName ?? r.device.platformName ?? '';

          // 🔑 Service UUID 0xFE95 = 小米 IoT BLE 设备的硬编码广播服务
          // 这是唯一可靠的硬件标识 — 芯片写死，米家改不了
          final hasFe95 = r.advertisementData.serviceUuids
              .any((u) => u.str.toLowerCase() == uuidFe95.toLowerCase());

          // 名字里带 cuk 关键词（仅用于日志标记，不做过滤）
          final hasNameHint = name.toLowerCase().contains('cuk') ||
              name.toLowerCase().contains('charger') ||
              name.toLowerCase().contains('power');

          if (hasFe95 || !filterCuktech) {
            _results.add(CuktechScanResult(
              device: r.device,
              rssi: r.rssi,
              localName: name,
              isCuktech: hasFe95, // ✅ 只靠 0xFE95 判定
            ));
            AppLogger.instance.d(
              'AndroidScanner',
              '📡 Found ${r.device.remoteId.str} rssi=${r.rssi} '
              'name="$name" fe95=$hasFe95 nameHint=$hasNameHint',
            );
          }
        }
      }, onError: (e, stackTrace) {
        AppLogger.instance.e('AndroidScanner', 'Scan error: $e', stackTrace);
      });

      // 开始扫描 — 🔑 关键：只扫 Service UUID 0xFE95 的设备
      // flutter_blue_plus 在 Android 上会做后台过滤，只返回包含此 UUID 的广播
      await FlutterBluePlus.startScan(
        withServices: [Guid(uuidFe95)],
        timeout: timeout,
      );

      // 超时结束
      await Future<void>.delayed(timeout);
      await stop();
      AppLogger.instance.i('AndroidScanner',
          '🔍 Scan done: ${_results.length} device(s) found');
      return results;
    } catch (e, stackTrace) {
      AppLogger.instance.e('AndroidScanner', 'Scan failed: $e', stackTrace);
      await stop();
      rethrow;
    }
  }

  /// 停止扫描
  Future<void> stop() async {
    try {
      _sub?.cancel();
      _sub = null;
      if (_isScanning) {
        await FlutterBluePlus.stopScan();
      }
    } catch (e, stackTrace) {
      AppLogger.instance.e('AndroidScanner', 'stop error: $e');
    } finally {
      _isScanning = false;
    }
  }

  /// 扫描并返回第一个匹配的酷态科设备
  Future<CuktechScanResult?> findCuktech({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final list = await start(timeout: timeout, filterCuktech: true);
    try {
      return list.firstWhere((r) => r.isCuktech);
    } on StateError {
      return null;
    }
  }
}
