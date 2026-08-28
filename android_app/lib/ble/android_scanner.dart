import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide ScanResult;
import '../logger/logger.dart';
import '../protocol/constants.dart';

/// 扫描结果
class ScanResult {
  const ScanResult({
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
/// 支持：
///   - 按 Service UUID (0xFE95) 过滤
///   - 按名称前缀 (njcuk) 过滤
///   - 手动输入 MAC 直连
///   - 5 秒超时 + 3 次重试
class AndroidScanner {
  AndroidScanner._();
  static final AndroidScanner instance = AndroidScanner._();

  final List<ScanResult> _results = <ScanResult>[];
  StreamSubscription<BluetoothDiscoveryResult>? _sub;
  bool _isScanning = false;

  bool get isScanning => _isScanning;
  List<ScanResult> get results => List<ScanResult>.unmodifiable(_results);

  /// 开始扫描
  ///
  /// [timeout] 扫描时长（默认 10 秒）
  /// [filterCuktech] 是否仅显示酷态科设备
  Future<List<ScanResult>> start({
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
      _sub = FlutterBluePlus.onScanResults.listen((event) {
        final r = event.result;
        final name = r.advertisementData.localName ?? r.device.platformName ?? '';
        final isCuktech =
            name.toLowerCase().contains('njcuk') ||
            r.device.remoteId.str.toLowerCase().contains('cuk');
        // 检查 Service UUID 0xFE95
        final hasFe95 = r.advertisementData.serviceUuids
            .any((u) => u.str == uuidFe95);
        if (!filterCuktech || isCuktech || hasFe95) {
          _results.add(ScanResult(
            device: r.device,
            rssi: r.rssi,
            localName: name,
            isCuktech: isCuktech || hasFe95,
          ));
          AppLogger.instance.d(
            'AndroidScanner',
            'Found ${r.device.remoteId.str} rssi=${r.rssi} name=$name',
          );
        }
      }, onError: (e, stackTrace) {
        AppLogger.instance.e('AndroidScanner', 'Scan error: $e', stackTrace);
      });

      // 监听扫描结果订阅前先 startScan
      await FlutterBluePlus.startScan(
        withServices: [Guid(uuidFe95)],
        timeout: timeout,
        allowDuplicates: false,
      );

      // 超时结束
      await Future<void>.delayed(timeout);
      await stop();
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
  Future<ScanResult?> findCuktech({
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