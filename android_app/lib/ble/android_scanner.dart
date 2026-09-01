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
    this.productId,
    this.serviceDataHex,
  });
  final BluetoothDevice device;
  final int rssi;
  final String localName;
  final bool isCuktech;
  final int? productId;
  final String? serviceDataHex;
}

/// Xiaomi FE95 BLE service-data frame parser (AD 0x16, 16-bit UUID)
///
/// 帧结构（小端）：
///   bytes 0-1 : frame_control (uint16 LE)
///   bytes 2-3 : product_id   (uint16 LE) ← AD1204U = 0x660E
///   byte  4   : frame_counter
///   bytes 5-10: MAC (6 bytes LE, 可选)
///   bytes 11+ : payload
///
/// 参考: ha-cuk-ble/custom_components/cuktech_ble/lib/fe95.py
int? _parseFe95ProductId(List<int> data) {
  if (data.length < 5) return null;
  return data[2] | (data[3] << 8); // LE uint16
}

/// AD1204U 产品 ID (小端 0x660E)
const int _ad1204ProductId = 0x660E;

/// Android BLE 扫描器（基于 flutter_blue_plus）
///
/// 🔑 识别策略（已对齐 ha-cuk-ble / cuktech-ble-server 参照项目）：
///   1. **硬件层**: 全量扫描 — 不使用 withServices 过滤
///      ❌ Android ScanFilter.setServiceUuid() 只匹配 AD 0x02/0x03
///         (Service UUID List)，而小米 IoT 设备把 FE95 放在 AD 0x16
///         (Service Data) 里 — 硬件过滤会直接把充电器挡掉
///   2. **Dart 层**: 检查 advertisementData.serviceData 的 key 是否包含
///      FE95 UUID — 这才是小米 IoT 设备广播 FE95 的正确位置
///   3. **进阶验证**: 解析 FE95 service-data frame 里的 product_id
///      是否等于 0x660E (AD1204U) — 避免误识别其他小米设备
///
/// ⚠️ 为什么不靠名字？米家可以远程改设备蓝牙广播名！
///    改名字不影响 FE95 广播数据（那是协议层字段）。
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
  /// [filterCuktech] 是否仅显示酷态科设备
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

    final fe95Guid = Guid(uuidFe95);

    try {
      _sub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          final name = r.advertisementData.localName ?? r.device.platformName ?? '';

          // ✅ 关键修复：FE95 在 AD 0x16 (Service Data) 里，不是 AD 0x02 (Service UUID)
          // flutter_blue_plus 暴露为 advertisementData.serviceData（Map<Guid, List<int>>）
          final serviceData = r.advertisementData.serviceData;
          final fe95Bytes = serviceData[fe95Guid] ?? const <int>[];
          final hasFe95 = fe95Bytes.isNotEmpty;

          // 进阶：解析 product_id 验证是 AD1204U (0x660E)
          // 避免把米家台灯、净化器等其他小米设备误判成酷态科
          final productId = _parseFe95ProductId(fe95Bytes);
          final isExactCuktech = productId == _ad1204ProductId;

          // 名字里带 cuk 关键词（仅用于日志标记，不做过滤）
          final hasNameHint = name.toLowerCase().contains('cuk') ||
              name.toLowerCase().contains('charger') ||
              name.toLowerCase().contains('power');

          final isTarget = hasFe95 && isExactCuktech;
          if (isTarget || !filterCuktech) {
            final hex = fe95Bytes.isEmpty
                ? null
                : fe95Bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
            _results.add(CuktechScanResult(
              device: r.device,
              rssi: r.rssi,
              localName: name,
              isCuktech: isTarget,
              productId: productId,
              serviceDataHex: hex,
            ));
            AppLogger.instance.d(
              'AndroidScanner',
              '📡 Found ${r.device.remoteId.str} rssi=${r.rssi} '
              'name="$name" fe95=$hasFe95 productId=0x${productId?.toRadixString(16).padLeft(4, '0') ?? "----"} '
              'exact=$isExactCuktech nameHint=$hasNameHint',
            );
          }
        }
      }, onError: (e, stackTrace) {
        AppLogger.instance.e('AndroidScanner', 'Scan error: $e', stackTrace);
      });

      // ✅ 不再使用 withServices 硬件级过滤
      // 原因：AD 0x16 (Service Data) 无法被 Android ScanFilter.Builder.setServiceUuid() 匹配
      // 扫全量，Dart 层按 serviceData key + product_id 精准过滤
      await FlutterBluePlus.startScan(timeout: timeout);

      // startScan 带 timeout 会自动结束，无需额外 delayed
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
