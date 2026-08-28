import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../logger/logger.dart';
import '../protocol/constants.dart';

/// 连接状态枚举
enum BleConnectionState {
  disconnected,
  connecting,
  connected,
  subscribing,
  ready,
  error,
}

/// Android BLE 连接器
///
/// 支持：
///   - 连接 + MTU 协商
///   - 5 个通知通道订阅（顺序对齐参考项目）
///   - 5 秒超时 + 3 次重试
class AndroidConnector {
  AndroidConnector._();
  static final AndroidConnector instance = AndroidConnector._();

  BleConnectionState _state = BleConnectionState.disconnected;
  BluetoothDevice? _device;
  final Map<String, BluetoothCharacteristic> _characteristics =
      <String, BluetoothCharacteristic>{};
  final Map<String, StreamSubscription<List<int>>> _notifySubs =
      <String, StreamSubscription<List<int>>>{};

  BleConnectionState get state => _state;
  BluetoothDevice? get device => _device;

  /// 连接并订阅所有通道
  ///
  /// [device] 目标设备
  /// 返回是否成功
  Future<bool> connect(BluetoothDevice device) async {
    _state = BleConnectionState.connecting;
    AppLogger.instance.i(
      'AndroidConnector',
      'Connecting to ${device.remoteId.str}...',
    );

    // 3 次重试
    for (int attempt = 1; attempt <= bleMaxRetries; attempt++) {
      try {
        if (attempt > 1) {
          AppLogger.instance.w(
            'AndroidConnector',
            'Retry attempt $attempt/$bleMaxRetries',
          );
        }
        await device.connect(timeout: bleTimeout);
        _device = device;
        _state = BleConnectionState.connected;
        AppLogger.instance.i('AndroidConnector', 'Connected');

        // MTU 协商
        final mtu = await device.mtu.first;
        AppLogger.instance.i('AndroidConnector', 'MTU negotiated: $mtu');

        // 订阅通道
        await _subscribeAll();
        _state = BleConnectionState.ready;
        return true;
      } catch (e, stackTrace) {
        AppLogger.instance.e(
          'AndroidConnector',
          'Connect attempt $attempt failed: $e',
          stackTrace,
        );
        try {
          await device.disconnect();
        } catch (_) {}
        if (attempt >= bleMaxRetries) {
          _state = BleConnectionState.error;
          return false;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    _state = BleConnectionState.error;
    return false;
  }

  /// 订阅所有 GATT 通道
  Future<void> _subscribeAll() async {
    final dev = _device;
    if (dev == null) throw StateError('Not connected');

    // 发现服务
    final services = await dev.discoverServices();
    final fe95 = services.firstWhere(
      (s) => s.uuid.str == uuidFe95,
      orElse: () => throw StateError('Service 0xFE95 not found'),
    );

    final mappings = <String, String>{
      'dev_info': charDeviceInfo,
      'auth_ctrl': charAuthCtrl,
      'auth_data': charAuthData,
      'cmd_send': charCmdSend,
      'cmd_recv': charCmdRecv,
    };

    for (final entry in mappings.entries) {
      final char = fe95.characteristics.firstWhere(
        (c) => c.uuid.str == entry.value,
        orElse: () => throw StateError('Char ${entry.value} not found'),
      );
      _characteristics[entry.key] = char;
      if (char.isNotifiable) {
        await char.setNotifyValue(true);
        _notifySubs[entry.key] = char.lastValueStream.listen(
          (data) {
            AppLogger.instance.d(
              'BleNotify:${entry.key}',
              'len=${data.length} hex=${_bytesToHex(data)}',
            );
          },
          onError: (e, stack) {
            AppLogger.instance.e(
              'BleNotify:${entry.key}',
              'Stream error: $e',
              stack,
            );
          },
        );
      }
    }
    AppLogger.instance.i('AndroidConnector', 'All channels subscribed');
  }

  /// 发送数据
  Future<void> write(String channel, List<int> data) async {
    final char = _characteristics[channel];
    if (char == null) throw StateError('Channel $channel not subscribed');
    await char.write(data, withoutResponse: false);
  }

  /// 读取数据
  Future<List<int>> read(String channel) async {
    final char = _characteristics[channel];
    if (char == null) throw StateError('Channel $channel not subscribed');
    return char.read();
  }

  /// 断开连接
  Future<void> disconnect() async {
    try {
      for (final sub in _notifySubs.values) {
        await sub.cancel();
      }
      _notifySubs.clear();
      _characteristics.clear();
      if (_device != null) {
        await _device!.disconnect();
      }
    } catch (e, stackTrace) {
      AppLogger.instance.e('AndroidConnector', 'disconnect error: $e');
    } finally {
      _state = BleConnectionState.disconnected;
      _device = null;
    }
  }

  String _bytesToHex(List<int> data) {
    return data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}