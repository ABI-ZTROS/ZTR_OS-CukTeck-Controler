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

/// 规范化 Guid 字符串用于跨 FBP 版本比较：统一去横线、小写
String _normGuidStr(String s) => s.replaceAll('-', '').toLowerCase();

/// 小米 IoT 16-bit Service UUID = 0xFE95 的 128 位形式（去掉横线小写）：
///   0000fe9500001000800000805f9b34fb
final String _fe95Norm128 = _normGuidStr(uuidFe95);

/// 16-bit 短形式（去掉横线、补零后取前 8 位中的后 4 位 → fe95）
/// 也可能是 Guid('FE95') / Guid('fe95') 作为短 key 直接存
const List<String> _fe95ShortCandidates = <String>['fe95', '0xfe95', '0000fe95'];

/// 在 AdvertisementData.serviceData 里稳健查找小米 FE95 条目：
/// - FlutterBluePlus 不同版本、Android/iOS，map key 形式不一定相同
///   可能是 Guid('0000FE95-…') / Guid('fe95') / Guid('FE95') 中的任何一种
/// - Guid.operator== 不同 FBP 实现不靠谱：直接 toByteArray 或 toString 都有坑
/// - 因此：**遍历所有 key**，转成字符串 → 规范化，匹配任一候选
List<int>? _lookupFe95ServiceData(Map<Guid, List<int>> serviceData) {
  if (serviceData.isEmpty) return null;
  for (final MapEntry<Guid, List<int>> e in serviceData.entries) {
    final String norm = _normGuidStr(e.key.toString());
    // 128 位完全相等
    if (norm == _fe95Norm128) return e.value;
    // 16 位短形式
    for (final String s in _fe95ShortCandidates) {
      if (norm == s || norm.endsWith(s) || norm.startsWith(s)) return e.value;
    }
    // 最终兜底：任何 key 只要包含 fe95 就是小米 IoT 的那条
    if (norm.contains('fe95')) return e.value;
  }
  return null;
}

/// Android BLE 扫描器（基于 flutter_blue_plus）
///
/// 🔑 识别策略（已对齐 ha-cuk-ble / cuktech-ble-server 参照项目）：
///   1. **硬件层**: 全量扫描 — 不使用 withServices 过滤
///      ❌ Android ScanFilter.setServiceUuid() 只匹配 AD 0x02/0x03
///         (Service UUID List)，而小米 IoT 设备把 FE95 放在 AD 0x16
///         (Service Data) 里 — 硬件过滤会直接把充电器挡掉
///   2. **Dart 层**: 遍历 advertisementData.serviceData 的 key，
///      多形态匹配 FE95（解决 FBP 1.32 Guid key 对比坑）
///   3. **进阶验证**: 解析 FE95 service-data frame 里的 product_id
///      是否等于 0x660E (AD1204U) — 避免误识别其他小米设备
///   4. **androidScanMode = lowLatency + continuousUpdates（allowDuplicates=true）**
///      — 老安卓只发"首次看到"事件；如果系统已经缓存了充电器，
///      `onScanResults` 可能一条都不回调 → 会让用户看到"未找到设备"。
///      FBP 上通过 `continuousUpdates: true` + `androidAllowDuplicates: true`
///      强制每个广播帧都回调，保证 cache hit 也能进入 callback。
///
/// ⚠️ 为什么不靠名字？米家可以远程改设备蓝牙广播名！
///    改名字不影响 FE95 广播数据（那是协议层字段）。
class AndroidScanner {
  AndroidScanner._();
  static final AndroidScanner instance = AndroidScanner._();

  /// 用 remoteId 作 key 去重，避免同设备多个 RSSI 采样把 list 挤爆
  final Map<String, CuktechScanResult> _resultsById = <String, CuktechScanResult>{};
  StreamSubscription<List<ScanResult>>? _sub;
  bool _isScanning = false;

  bool get isScanning => _isScanning;
  List<CuktechScanResult> get results =>
      List<CuktechScanResult>.unmodifiable(_resultsById.values);

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
    _resultsById.clear();
    _isScanning = true;

    try {
      _sub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          final name = r.advertisementData.localName ?? r.device.platformName ?? '';

          // ✅ 关键修复 #1：多形态匹配 serviceData 里的 FE95 key
          //     解决 FlutterBluePlus Guid 对比：128 位 vs 16 位 vs 大小写不统一
          final List<int>? fe95Bytes =
              _lookupFe95ServiceData(r.advertisementData.serviceData);
          final bool hasFe95 = fe95Bytes != null && fe95Bytes.isNotEmpty;

          // 进阶：解析 product_id 验证是 AD1204U (0x660E)
          // 避免把米家台灯、净化器等其他小米设备误判成酷态科
          final int? productId =
              hasFe95 ? _parseFe95ProductId(fe95Bytes!) : null;
          final bool isExactCuktech = productId == _ad1204ProductId;

          // 名字里带 cuk 关键词（仅用于日志标记，不做过滤）
          final bool hasNameHint = name.toLowerCase().contains('cuk') ||
              name.toLowerCase().contains('charger') ||
              name.toLowerCase().contains('power');

          final bool isTarget = hasFe95 && isExactCuktech;
          if (isTarget || !filterCuktech) {
            final String? hex = fe95Bytes == null || fe95Bytes.isEmpty
                ? null
                : fe95Bytes
                    .map((int b) => b.toRadixString(16).padLeft(2, '0'))
                    .join();
            final CuktechScanResult res = CuktechScanResult(
              device: r.device,
              rssi: r.rssi,
              localName: name,
              isCuktech: isTarget,
              productId: productId,
              serviceDataHex: hex,
            );
            // 去重（同 remoteId 覆盖，刷新 RSSI/广播字段）
            _resultsById[r.device.remoteId.str] = res;
            AppLogger.instance.d(
              'AndroidScanner',
              '📡 Found ${r.device.remoteId.str} rssi=${r.rssi} '
              'name="$name" fe95=$hasFe95 productId=0x${productId?.toRadixString(16).padLeft(4, '0') ?? "----"} '
              'exact=$isExactCuktech nameHint=$hasNameHint',
            );
          }
        }
      }, onError: (Object e, StackTrace stackTrace) {
        AppLogger.instance.e('AndroidScanner', 'Scan error: $e', stackTrace);
      });

      // ✅ 关键修复 #2：continuousUpdates=true + androidAllowDuplicates=true
      //     防止 Android 缓存到的设备不触发 onScanResults（典型"米家能找到我不行"）
      // ✅ 关键修复 #3：androidScanMode=lowLatency
      //     即便 10 秒里只扫到一个广播帧，也能命中识别逻辑
      // ✅ 依然不使用 withServices 硬件级过滤
      await FlutterBluePlus.startScan(
        timeout: timeout,
        continuousUpdates: true,
        androidUsesFineLocation: true,
        androidScanMode: AndroidScanMode.lowLatency,
        androidAllowDuplicates: true,
      );

      // startScan 带 timeout 会自动结束
      await stop();
      AppLogger.instance.i('AndroidScanner',
          '🔍 Scan done: ${_resultsById.length} device(s) found');
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
      await _sub?.cancel();
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
    final List<CuktechScanResult> list =
        await start(timeout: timeout, filterCuktech: true);
    try {
      return list.firstWhere((CuktechScanResult r) => r.isCuktech);
    } on StateError {
      return null;
    }
  }
}
