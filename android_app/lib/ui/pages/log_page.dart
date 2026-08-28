import 'dart:io';
import 'package:flutter/material.dart';
import '../../utils/logger/logger.dart';

class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  List<String> _logs = const [];
  bool _loading = false;

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final path = await AppLogger.instance.logPath;
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          final content = await file.readAsString();
          setState(() => _logs = content.split('\n').toList(growable: false));
        } else {
          setState(() => _logs = const ['(日志文件尚未创建)']);
        }
      } else {
        setState(() => _logs = const [
              '(日志文件尚未创建)',
            ]);
      }
    } catch (e) {
      setState(() => _logs = ['读取日志失败: $e']);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _reload,
          ),
        ],
      ),
      body: _logs.isEmpty
          ? const Center(child: Text('无日志'))
          : ListView.builder(
              itemCount: _logs.length,
              itemBuilder: (context, i) => ListTile(
                    title: Text(
                      _logs[i],
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
            ),
    );
  }
}
