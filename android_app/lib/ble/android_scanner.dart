import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/logger/logger.dart' hide LogLevel;
import '../protocol/constants.dart';

/// 扫描失败的细粒度原因 — 让 UI 分情况给出中文提示，而不仅是"未找到设备"
enum ScanFailReason {
  /// 一切正常但真的没搜到目标
  noneFound,

  /// 设备不支持 BLE (uses-feature 不符合)
  bleUnsupported,

  /// 蓝牙适配器未打开或不可用
  adapterOff,

  /// 缺少运行时权限（BLUETOOTH_SCAN / BLUETOOTH_CONNECT / LOCATION 之一被拒）
  permissionDenied,

  /// scan() 抛了平台异常（例如 AirplaneMode 下的系统拦截）
  runtimeError,
}

class ScanDiagnosis {
  const ScanDiagnosis({
    required this.failReason,
    required this.totalRawDevices,
    required this.cuktechMatched,
    required this.fe95SeenButWrongPid,
    this.message,
    this.missingPermissions = const <Permission>[],
  });

  final ScanFailReason failReason;

  /// 扫描期间一共回调过多少台唯一 BLE 设备（不挑协议）
  /// =0：权限/蓝牙/飞机模式 直接把回调掐了
  /// >0：回调正常，只是 FE95 匹配没中
  final int totalRawDevices;

  /// 真正命中 isCuktech=true 的台数（就是我们展示结果的台数）
  final int cuktechMatched;

  /// 广播里有 FE95 serviceData key 但 product_id≠0x660E 的台数
  final int fe95SeenButWrongPid;

  /// 给 UI/日志看的详细文本
  final String? message;

  /// 缺失的权限列表（仅 failReason=permissionDenied 时有）
  final List<Permission> missingPermissions;

  bool get isOk =>
      failReason == ScanFailReason.noneFound && cuktechMatched > 0;
}

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
int? _parseFe95ProductId(List<int> data) {
  if (data.length < 5) return null;
  return data[2] | (data[3] << 8); // LE uint16
}

const int _ad1204ProductId = 0x660E;

/// 规范化 Guid 字符串：去横线、转小写。避免 FBP 128/16 位 Guid key 对比坑。
String _normGuidStr(String s) => s.replaceAll('-', '').toLowerCase();

final String _fe95Norm128 = _normGuidStr(uuidFe95);
const List<String> _fe95ShortCandidates = <String>['fe95', '0xfe95', '0000fe95'];

/// 多形态查找：serviceData 的 key 可能以 Guid('FE95')/Guid('fe95')/
/// Guid('0000FE95-…')/Guid('0000fe95') 等任何形态出现
List<int>? _lookupFe95ServiceData(Map<Guid, List<int>> serviceData) {
  if (serviceData.isEmpty) return null;
  for (final MapEntry<Guid, List<int>> e in serviceData.entries) {
    final String norm = _normGuidStr(e.key.toString());
    if (norm == _fe95Norm128) return e.value;
    for (final String s in _fe95ShortCandidates) {
      if (norm == s || norm.endsWith(s) || norm.startsWith(s)) return e.value;
    }
    if (norm.contains('fe95')) return e.value;
  }
  return null;
}

/// 一次扫描的最终结果（成功列表 + 诊断元数据）
class ScannerOutcome {
  const ScannerOutcome(this.results, this.diagnosis);
  final List<CuktechScanResult> results;
  final ScanDiagnosis diagnosis;
}

/// Android BLE 扫描器（基于 flutter_blue_plus 1.32）
///
/// 修复清单（2026-09-01 TDD 第 2 轮 — 用户报"还是未找到设备"）：
///  ① Manifest 有声明但**未动态请求权限** → 新增加 ensurePermissions()
///     主动申请 BLUETOOTH_SCAN / BLUETOOTH_CONNECT /
///     ACCESS_FINE_LOCATION / POST_NOTIFICATIONS
///  ② 没检查蓝牙是否打开 → 新增加 ensureAdapterOn()
///     查 isSupported + adapterState.onNow；否则直接拒绝并提示
///  ③ "未找到设备"无诊断 → 输出 ScannerOutcome.diagnosis：
///     totalRawDevices=0 → 权限/适配器被拦截；
///     totalRawDevices>0 + cuktechMatched=0 + fe95SeenButWrongPid>0 → 周围有
///     其他小米设备但没有 AD1204U；
///     totalRawDevices>0 + fe95SeenButWrongPid=0 → 没抓到 AD 0x16 里的 FE95
///  ④ 兜底：每台原始设备都 D 级别 log 一条，包括
///     name/rssi/manufacturerData/serviceData.keys/serviceUuids
///     → 用户把日志发回来我们一眼就能看出"广播 key 长啥样"
///  ⑤ FBP 开 verbose log（debug 模式）
class AndroidScanner {
  AndroidScanner._();
  static final AndroidScanner instance = AndroidScanner._();

  final Map<String, CuktechScanResult> _resultsById = <String, CuktechScanResult>{};

  /// 原始设备集合（不挑协议，用于诊断：看扫描到底有没有回调进来）
  final Set<String> _rawSeenIds = <String>{};

  /// 有 FE95 key 但是 product_id 不是 0x660E 的设备计数（小米台灯/净化器等）
  int _fe95WrongPid = 0;

  StreamSubscription<List<ScanResult>>? _sub;
  bool _isScanning = false;

  bool get isScanning => _isScanning;
  List<CuktechScanResult> get results =>
      List<CuktechScanResult>.unmodifiable(_resultsById.values);

  // ============================== 前置闸门 ==============================

  /// 运行时权限：蓝牙扫描 + 蓝牙连接 + (11-) 位置
  static const List<Permission> _blePerms = <Permission>[
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.locationWhenInUse,
    Permission.bluetoothAdvertise,
  ];

  /// 申请权限并检查状态。返回值 = 缺失权限列表（空=全部OK）
  Future<List<Permission>> ensurePermissions() async {
    final Map<Permission, PermissionStatus> statuses =
        await _blePerms.request();
    final List<Permission> missing = <Permission>[];
    statuses.forEach((Permission p, PermissionStatus s) {
      if (!s.isGranted && !(p == Permission.bluetoothAdvertise)) {
        missing.add(p);
      }
    });
    // POST_NOTIFICATIONS 不阻塞扫描，单独申请不强制
    unawaited(Permission.notification.request());
    return missing;
  }

  /// 确认蓝牙已打开 + 设备支持 BLE；失败抛字符串给 UI catch
  Future<bool> ensureAdapterOn() async {
    try {
      final bool supported = await FlutterBluePlus.isSupported;
      if (!supported) return false;
      final BluetoothAdapterState state = FlutterBluePlus.adapterStateNow;
      if (state == BluetoothAdapterState.on) return true;
      // 尝试 turnOn（仅 Android 可用）
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {}
      // 轮询最多 5 秒
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on) {
          return true;
        }
      }
      return FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;
    } catch (e) {
      AppLogger.instance.e('AndroidScanner', 'ensureAdapterOn error: $e');
      return false;
    }
  }

  // ============================== 主入口 ==============================

  /// 开始扫描（带闸门 + 诊断）
  Future<ScannerOutcome> startWithDiagnosis({
    Duration timeout = const Duration(seconds: 10),
    bool filterCuktech = true,
  }) async {
    // -------------- 闸门 1: BLE 支持 --------------
    try {
      if (!await FlutterBluePlus.isSupported) {
        return _outcomeEmpty(
          const ScanDiagnosis(
            failReason: ScanFailReason.bleUnsupported,
            totalRawDevices: 0,
            cuktechMatched: 0,
            fe95SeenButWrongPid: 0,
            message: '本机硬件 / ROM 不支持低功耗蓝牙 (BLE)，无法使用本 App。',
          ),
        );
      }
    } catch (e) {
      return _outcomeEmpty(ScanDiagnosis(
        failReason: ScanFailReason.bleUnsupported,
        totalRawDevices: 0,
        cuktechMatched: 0,
        fe95SeenButWrongPid: 0,
        message: '蓝牙服务初始化失败：$e',
      ));
    }

    // -------------- 闸门 2: 运行时权限 --------------
    final List<Permission> missing = await ensurePermissions();
    if (missing.isNotEmpty) {
      return _outcomeEmpty(ScanDiagnosis(
        failReason: ScanFailReason.permissionDenied,
        totalRawDevices: 0,
        cuktechMatched: 0,
        fe95SeenButWrongPid: 0,
        message: '缺少权限：${missing.join(", ")}，'
            '请到「设置 → 应用 → 酷态科控制器 → 权限」允许蓝牙/附近设备/位置。',
        missingPermissions: missing,
      ));
    }

    // -------------- 闸门 3: 适配器 --------------
    if (!await ensureAdapterOn()) {
      return _outcomeEmpty(const ScanDiagnosis(
        failReason: ScanFailReason.adapterOff,
        totalRawDevices: 0,
        cuktechMatched: 0,
        fe95SeenButWrongPid: 0,
        message: '蓝牙尚未打开，请在系统下拉开关里打开蓝牙后重试。',
      ));
    }

    // -------------- 正式扫描 --------------
    if (kDebugMode) {
      try {
        FlutterBluePlus.setLogLevel(LogLevel.verbose, color: false);
      } catch (_) {}
    }

    if (_isScanning) {
      AppLogger.instance.w('AndroidScanner', 'Already scanning');
      return ScannerOutcome(results, _makeDiagnosis(ScanFailReason.noneFound));
    }
    _resultsById.clear();
    _rawSeenIds.clear();
    _fe95WrongPid = 0;
    _isScanning = true;

    try {
      _sub = FlutterBluePlus.onScanResults.listen((List<ScanResult> results) {
        for (final ScanResult r in results) {
          final String id = r.device.remoteId.str;
          _rawSeenIds.add(id);

          final String name =
              r.advertisementData.localName ?? r.device.platformName ?? '';

          final List<int>? fe95Bytes =
              _lookupFe95ServiceData(r.advertisementData.serviceData);
          final bool hasFe95 = fe95Bytes != null && fe95Bytes.isNotEmpty;

          final int? productId =
              hasFe95 ? _parseFe95ProductId(fe95Bytes!) : null;
          final bool isExactCuktech = productId == _ad1204ProductId;

          if (hasFe95 && !isExactCuktech) _fe95WrongPid++;

          final bool hasNameHint = name.toLowerCase().contains('cuk') ||
              name.toLowerCase().contains('charger') ||
              name.toLowerCase().contains('power');

          final bool isTarget = hasFe95 && isExactCuktech;

          // ==== 【诊断兜底】不管是否命中，把原始广告打到 D log
          // 这样用户复现失败时，直接把日志发我们即可看出 key 形态
          final String serviceKeys = r.advertisementData.serviceData.keys
              .map((Guid g) => _normGuidStr(g.toString()))
              .join(',');
          final String serviceUuids = r.advertisementData.serviceUuids
              .map((Guid g) => _normGuidStr(g.toString()))
              .take(5)
              .join(',');
          AppLogger.instance.d(
            'AndroidScanner',
            '📡 RAW id=$id rssi=${r.rssi} name="$name" '
            'svcKeys=[$serviceKeys] svcUuids=[$serviceUuids] '
            'fe95=$hasFe95 pid=0x${productId?.toRadixString(16).padLeft(4, '0') ?? '----'} '
            'exact=$isExactCuktech nh=$hasNameHint',
          );

          if (isTarget || !filterCuktech) {
            final String? hex = fe95Bytes == null || fe95Bytes.isEmpty
                ? null
                : fe95Bytes
                    .map((int b) => b.toRadixString(16).padLeft(2, '0'))
                    .join();
            _resultsById[id] = CuktechScanResult(
              device: r.device,
              rssi: r.rssi,
              localName: name,
              isCuktech: isTarget,
              productId: productId,
              serviceDataHex: hex,
            );
          }
        }
      }, onError: (Object e, StackTrace stackTrace) {
        AppLogger.instance.e('AndroidScanner', 'Scan error: $e', stackTrace);
      });

      await FlutterBluePlus.startScan(
        timeout: timeout,
        continuousUpdates: true,
        androidUsesFineLocation: true,
        androidScanMode: AndroidScanMode.lowLatency,
      );
      await stop();
      AppLogger.instance.i(
          'AndroidScanner',
          '🔍 done: cuktech=${_resultsById.length} '
          'rawSeen=${_rawSeenIds.length} fe95WrongPid=$_fe95WrongPid');
      return ScannerOutcome(
          results, _makeDiagnosis(ScanFailReason.noneFound));
    } catch (e, stackTrace) {
      AppLogger.instance.e('AndroidScanner', 'Scan failed: $e', stackTrace);
      await stop();
      return ScannerOutcome(
        results,
        ScanDiagnosis(
          failReason: ScanFailReason.runtimeError,
          totalRawDevices: _rawSeenIds.length,
          cuktechMatched: _resultsById.length,
          fe95SeenButWrongPid: _fe95WrongPid,
          message: '扫描执行异常：$e',
        ),
      );
    }
  }

  /// 简单兼容 API（返回 List；诊断可在事后通过 lastDiagnosis 字段获取）
  Future<List<CuktechScanResult>> start({
    Duration timeout = const Duration(seconds: 10),
    bool filterCuktech = true,
  }) async {
    final ScannerOutcome o = await startWithDiagnosis(
      timeout: timeout,
      filterCuktech: filterCuktech,
    );
    lastDiagnosis = o.diagnosis;
    return o.results;
  }

  /// 最近一次扫描的诊断（HomePage 用它渲染详细中文原因）
  ScanDiagnosis? lastDiagnosis;

  Future<void> stop() async {
    try {
      await _sub?.cancel();
      _sub = null;
      if (_isScanning) {
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {}
      }
    } catch (e, stackTrace) {
      AppLogger.instance.e('AndroidScanner', 'stop error: $e');
    } finally {
      _isScanning = false;
    }
  }

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

  // ============================== 工具 ==============================

  ScannerOutcome _outcomeEmpty(ScanDiagnosis d) {
    lastDiagnosis = d;
    return ScannerOutcome(const <CuktechScanResult>[], d);
  }

  ScanDiagnosis _makeDiagnosis(ScanFailReason reasonIfNotFound) {
    if (_resultsById.isNotEmpty) {
      return ScanDiagnosis(
        failReason: ScanFailReason.noneFound,
        totalRawDevices: _rawSeenIds.length,
        cuktechMatched: _resultsById.length,
        fe95SeenButWrongPid: _fe95WrongPid,
      );
    }
    final String msg;
    if (_rawSeenIds.isEmpty) {
      msg = '扫描过程中未收到任何 BLE 广播。\n'
          '可能原因：\n  1) 附近 BLE 设备真的离线\n'
          '  2) 蓝牙被系统级优化静默拦截（电池/手机管家）\n'
          '  3) 请检查米家或系统蓝牙扫描界面是否能看到充电器。';
    } else if (_fe95WrongPid > 0) {
      msg = '搜到了 $_fe95WrongPid 台其他小米/米家设备，但没有 AD1204U '
          '（酷态科10号 Ultra，product_id=0x660E）。\n'
          '请确认充电器插电、屏幕亮着、且没有被其他手机蓝牙连接（米家独占）。';
    } else {
      msg = '共收到 ${_rawSeenIds.length} 台 BLE 设备广播，'
          '但没有任何一条包含小米 FE95 广播数据。\n'
          '（酷态科充电头必须以 0xFE95 Service Data 广播才能被识别）。\n'
          '请检查充电器是否是 AD1204U 型号、是否未进入休眠。';
    }
    return ScanDiagnosis(
      failReason: reasonIfNotFound,
      totalRawDevices: _rawSeenIds.length,
      cuktechMatched: 0,
      fe95SeenButWrongPid: _fe95WrongPid,
      message: msg,
    );
  }
}
