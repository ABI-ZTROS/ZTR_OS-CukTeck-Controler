import 'dart:async';
import '../utils/logger/logger.dart';
import '../protocol/constants.dart';

/// 端口状态
class PortState {
  const PortState({
    required this.piid,
    this.voltage = 0.0,
    this.current = 0.0,
    this.power = 0.0,
    this.protocol = 'idle',
    this.active = false,
  });
  final int piid;
  final double voltage;
  final double current;
  final double power;
  final String protocol;
  final bool active;

  PortState copyWith({
    double? voltage,
    double? current,
    double? power,
    String? protocol,
    bool? active,
  }) => PortState(
    piid: piid,
    voltage: voltage ?? this.voltage,
    current: current ?? this.current,
    power: power ?? this.power,
    protocol: protocol ?? this.protocol,
    active: active ?? this.active,
  );
}

/// 端口广播流控制器
class PortStreamController {
  PortStreamController._();
  static final PortStreamController instance = PortStreamController._();

  final Map<int, StreamController<PortState>> _controllers = <int, StreamController<PortState>>{};

  Stream<PortState> watch(int piid) {
    return _controllers.putIfAbsent(piid, () => StreamController<PortState>.broadcast()).stream;
  }

  void publish(PortState state) {
    final c = _controllers[state.piid];
    if (c != null && !c.isClosed) {
      c.add(state);
    }
  }

  Future<void> dispose() async {
    for (final c in _controllers.values) {
      await c.close();
    }
    _controllers.clear();
  }
}
