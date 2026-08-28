import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../utils/logger/logger.dart';
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

/// BLE 通知数据记录
class BleNotification {
  const BleNotification(this.channel, this.data);
  final String channel;
  final List<int> data;
}

/// Android BLE 连接器
///
/// 支持：
///   - 连接 + MTU 协商
///   - 5 个通知通道订阅（顺序对齐参考项目）
///   - 5 秒超时 + 3 次重试
///   - 广播通知流供 Authenticator / EncryptedChannel / PortDecoder 消费
class AndroidConnector {
  AndroidConnector._();
  static final AndroidConnector instance = AndroidConnector._();

  BleConnectionState _state = BleConnectionState.disconnected;
  BluetoothDevice? _device;
  final Map<String, BluetoothCharacteristic> _characteristics =
      <String, BluetoothCharacteristic>{};
  final Map<String, StreamSubscription<List<int>>> _notifySubs =
      <String, StreamSubscription<List<int>>>{};

  /// 广播通知流：所有通道的 BLE 通知都会通过此 Stream 发出
  final StreamController<BleNotification> _notificationController =
      StreamController<BleNotification>.broadcast();

  /// 订阅此流以接收所有 BLE 通知
  Stream<BleNotification> get notifications => _notificationController.stream;

  BleConnectionState get state => _state;
  BluetoothDevice? get device => _device;

  /// 连接并订阅所有通道
  Future<bool> connect(BluetoothDevice device) async {
    _state = BleConnectionState.connecting;
    AppLogger.instance.i(
      'AndroidConnector',
      'Connecting to ${device.remoteId.str}...',
    );

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

        final mtu = await device.mtu.first;
        AppLogger.instance.i('AndroidConnector', 'MTU negotiated: $mtu');

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

  Future<void> _subscribeAll() async {
    final dev = _device;
    if (dev == null) throw StateError('Not connected');

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
            // 关键：转发到广播通知流
            _notificationController.add(BleNotification(entry.key, data));
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

  /// 等待指定通道的下一个通知，带超时
  Future<List<int>?> waitNotification(
    String channel, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final completer = Completer<List<int>?>();
    late final StreamSubscription<BleNotification> sub;
    sub = notifications.listen((event) {
      if (event.channel == channel && !completer.isCompleted) {
        completer.complete(event.data);
        sub.cancel();
      }
    });
    try {
      return await completer.future.timeout(timeout, onTimeout: () {
        sub.cancel();
        return null;
      });
    } catch (e) {
      sub.cancel();
      return null;
    }
  }

  Future<void> write(String channel, List<int> data) async {
    final char = _characteristics[channel];
    if (char == null) throw StateError('Channel $channel not subscribed');
    await char.write(data, withoutResponse: false);
  }

  Future<List<int>> read(String channel) async {
    final char = _characteristics[channel];
    if (char == null) throw StateError('Channel $channel not subscribed');
    return char.read();
  }

  Future<void> disconnect() async {
    try {
      for (final sub in _notifySubs.values) {
        await sub.cancel();
      }
      _notifySubs.clear();
      _characteristics.clear();
      await _notificationController.close();
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
