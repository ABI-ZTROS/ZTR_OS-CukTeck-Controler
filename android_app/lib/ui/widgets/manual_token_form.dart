import 'package:flutter/material.dart';

/// 手动 Token 输入表单（复用在 TokenImportPage 与独立入口）
class ManualTokenForm extends StatefulWidget {
  const ManualTokenForm({
    super.key,
    this.initial,
    this.onSubmit,
    this.onClear,
    this.submitLabel = '保存 Token',
    this.saving = false,
  });

  final Map<String, String>? initial; // token/key/userId/did
  final Future<void> Function(Map<String, String> values)? onSubmit;
  final Future<void> Function()? onClear;
  final String submitLabel;
  final bool saving;

  @override
  State<ManualTokenForm> createState() => _ManualTokenFormState();
}

class _ManualTokenFormState extends State<ManualTokenForm> {
  final _tokenCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _uidCtrl = TextEditingController();
  final _didCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    if (init != null) {
      _tokenCtrl.text = init['token'] ?? '';
      _keyCtrl.text = init['key'] ?? '';
      _uidCtrl.text = init['userId'] ?? '';
      _didCtrl.text = init['did'] ?? '';
    }
  }

  @override
  void didUpdateWidget(covariant ManualTokenForm old) {
    super.didUpdateWidget(old);
    if (old.initial != widget.initial) {
      final init = widget.initial;
      _tokenCtrl.text = init?['token'] ?? '';
      _keyCtrl.text = init?['key'] ?? '';
      _uidCtrl.text = init?['userId'] ?? '';
      _didCtrl.text = init?['did'] ?? '';
    }
  }

  Future<void> _submit() async {
    if (widget.saving || widget.onSubmit == null) return;
    await widget.onSubmit!(<String, String>{
      'token': _tokenCtrl.text.trim(),
      'key': _keyCtrl.text.trim(),
      'userId': _uidCtrl.text.trim(),
      'did': _didCtrl.text.trim(),
    });
  }

  Future<void> _clear() async {
    if (widget.saving || widget.onClear == null) return;
    await widget.onClear!();
    _tokenCtrl.clear();
    _keyCtrl.clear();
    _uidCtrl.clear();
    _didCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text('手动输入 Token',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
              '从米家 App 提取的认证 Token，用于与设备建立安全通道。',
              style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          TextField(
              controller: _tokenCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                  labelText: 'Token (32 位十六进制)',
                  hintText: '请输入 Token',
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
              controller: _keyCtrl,
              decoration: const InputDecoration(
                  labelText: 'Key',
                  hintText: '请输入 Key (16 字节)',
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
              controller: _uidCtrl,
              decoration: const InputDecoration(
                  labelText: 'User ID',
                  hintText: '请输入 User ID',
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
              controller: _didCtrl,
              decoration: const InputDecoration(
                  labelText: 'Device ID (DID)',
                  hintText: '请输入 DID',
                  border: OutlineInputBorder())),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: widget.saving ? null : _submit,
            child: widget.saving
                ? const CircularProgressIndicator()
                : Text(widget.submitLabel),
          ),
          const SizedBox(height: 12),
          TextButton(
              onPressed: widget.saving ? null : _clear,
              child: const Text('清除已保存的 Token')),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _keyCtrl.dispose();
    _uidCtrl.dispose();
    _didCtrl.dispose();
    super.dispose();
  }
}
