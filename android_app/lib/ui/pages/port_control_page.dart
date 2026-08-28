import 'package:flutter/material.dart';
import '../../ble/android_connector.dart';
import '../../ble/port_stream.dart';
import '../../protocol/constants.dart';
import '../../protocol/port_control.dart';
import '../../protocol/protocol_switch.dart';
import '../../protocol/settings.dart';
import '../widgets/status_banner.dart';

class PortControlPage extends StatefulWidget {
  const PortControlPage({super.key, required this.piid});
  final int piid;

  @override
  State<PortControlPage> createState() => _PortControlPageState();
}

class _PortControlPageState extends State<PortControlPage> {
  final PortControl _portControl = PortControl.instance;
  final ProtocolSwitch _protocolSwitch = ProtocolSwitch.instance;
  final SettingsService _settings = SettingsService.instance;
  final AndroidConnector _connector = AndroidConnector.instance;

  late final String _portName;
  late final String _portKey;
  bool _portOn = false;
  int _countdownMinutes = 0;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _portName = const {1: 'C1', 2: 'C2', 3: 'C3', 4: 'A'}[widget.piid] ?? 'C?';
    _portKey = const {1: 'c1', 2: 'c2', 3: 'c3', 4: 'a'}[widget.piid] ?? 'c1';
    _loadState();
  }

  Future<void> _loadState() async {
    setState(() => _loading = true);
    try {
      final portState = await _portControl.readState(_connector);
      if (portState != null) {
        final bit = portBits[_portKey]!;
        setState(() => _portOn = (portState & (1 << bit)) != 0);
      }
      final timerPiid = timerPorts[_portKey];
      if (timerPiid != null) {
        final min = await _settings.read(_connector, timerPiid);
        if (min != null) setState(() => _countdownMinutes = min);
      }
    } catch (e) {
      setState(() => _error = '读取状态失败: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _togglePort(bool on) async {
    setState(() => _loading = true);
    final ok = await _portControl.setPort(_connector, _portKey, on);
    setState(() {
      _portOn = ok ? on : _portOn;
      _loading = false;
      if (!ok) _error = '操作失败';
      else _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('$_portName 控制')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusBanner(
              steps: const ['读取状态', '准备完成'],
              currentStep: _loading ? 0 : -1,
              isConnecting: _loading,
              errorMessage: _error,
            ),
            const SizedBox(height: 16),
            _buildPortSwitch(),
            const SizedBox(height: 24),
            _buildProtocolToggles(),
            const SizedBox(height: 24),
            _buildCountdown(),
          ],
        ),
      ),
    );
  }

  Widget _buildPortSwitch() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('$_portName 端口',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Switch(
              value: _portOn,
              onChanged: _loading ? null : _togglePort,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProtocolToggles() {
    final protocols = const {
      'c1': ['pd', 'pps', 'ufcs'],
      'c2': ['pd', 'pps', 'ufcs'],
      'c3': ['ufcs', 'scp'],
      'a': ['ufcs', 'scp'],
    }[_portKey] ?? <String>[];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('协议',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...protocols.map((p) => _ProtocolTile(
                  port: _portKey,
                  protocol: p,
                  connector: _connector,
                  switchCtrl: _protocolSwitch,
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildCountdown() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('倒计时',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('分钟:'),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    initialValue: _countdownMinutes.toString(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                    onFieldSubmitted: (v) async {
                      final min = int.tryParse(v) ?? 0;
                      await _settings.setPortTimer(_connector, _portKey, min);
                      setState(() => _countdownMinutes = min);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProtocolTile extends StatefulWidget {
  const _ProtocolTile({
    required this.port,
    required this.protocol,
    required this.connector,
    required this.switchCtrl,
  });
  final String port;
  final String protocol;
  final AndroidConnector connector;
  final ProtocolSwitch switchCtrl;

  @override
  State<_ProtocolTile> createState() => _ProtocolTileState();
}

class _ProtocolTileState extends State<_ProtocolTile> {
  bool _enabled = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await widget.switchCtrl.read(widget.connector);
    if (v != null) {
      final parsed = widget.switchCtrl.parse(v);
      setState(() => _enabled = parsed[widget.port]?[widget.protocol] ?? false);
    }
  }

  Future<void> _toggle(bool on) async {
    setState(() => _loading = true);
    await widget.switchCtrl.setProtocol(widget.connector, widget.port, widget.protocol, on);
    setState(() {
      _enabled = on;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(widget.protocol.toUpperCase()),
      trailing: Switch(
        value: _enabled,
        onChanged: _loading ? null : _toggle,
      ),
    );
  }
}
