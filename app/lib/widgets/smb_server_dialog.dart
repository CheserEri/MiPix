import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/smb_service.dart';
import '../utils/smb_form_logic.dart';

Future<void> showSmbServerDialog(
  BuildContext context, {
  SmbConfig? initial,
  required Future<void> Function(SmbConfig config) onSubmit,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _SmbServerDialog(initial: initial, onSubmit: onSubmit),
  );
}

class _SmbServerDialog extends StatefulWidget {
  const _SmbServerDialog({this.initial, required this.onSubmit});

  final SmbConfig? initial;
  final Future<void> Function(SmbConfig config) onSubmit;

  @override
  State<_SmbServerDialog> createState() => _SmbServerDialogState();
}

class _SmbServerDialogState extends State<_SmbServerDialog> {
  final _smbService = SmbService();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _shareCtrl;
  late final TextEditingController _rootPathCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;
  late final TextEditingController _domainCtrl;

  bool _submitting = false;
  bool _probingShares = false;
  bool _probingPaths = false;
  bool _testingConnection = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameCtrl = TextEditingController(text: initial?.name ?? '');
    _hostCtrl = TextEditingController(text: initial?.host ?? '');
    _portCtrl = TextEditingController(text: (initial?.port ?? 445).toString());
    _shareCtrl = TextEditingController(text: initial?.share ?? '');
    _rootPathCtrl = TextEditingController(text: initial?.rootPath ?? '');
    _userCtrl = TextEditingController(text: initial?.username ?? '');
    _passCtrl = TextEditingController(text: initial?.password ?? '');
    _domainCtrl = TextEditingController(text: initial?.domain ?? '');

    for (final controller in [
      _nameCtrl,
      _hostCtrl,
      _portCtrl,
      _shareCtrl,
      _rootPathCtrl,
      _userCtrl,
      _passCtrl,
      _domainCtrl,
    ]) {
      controller.addListener(_onDraftChanged);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _shareCtrl.dispose();
    _rootPathCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _domainCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initial != null;
    final draft = _draft;
    final canSave = SmbFormLogic.canSave(draft) && !_submitting;

    return AlertDialog(
      backgroundColor: const Color(0xFF0F172A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(
        isEditing ? '编辑 SMB 服务器' : '添加 SMB 服务器',
        style: const TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildField(_hostCtrl, 'Samba服务器地址', hint: '10.147.20.50'),
              _buildField(_userCtrl, '用户名', hint: 'naeuta'),
              _buildField(
                _passCtrl,
                '密码',
                obscure: _obscurePassword,
                hint: '可选',
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                ),
              ),
              _buildField(
                _shareCtrl,
                '分享',
                hint: '点击右侧按钮选择或手动填写',
                suffixIcon: IconButton(
                  onPressed: _probingShares ? null : _pickShare,
                  icon: _probingShares
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.open_in_new_outlined),
                ),
              ),
              _buildField(
                _rootPathCtrl,
                '储存根目录(照片会储存在该目录下)',
                hint: '如 storage/photos，开头不要带 /',
                suffixIcon: IconButton(
                  onPressed: _probingPaths ? null : _pickRootPath,
                  icon: _probingPaths
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.open_in_new_outlined),
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'eg: storage/photos (no \'/\' or \'\\\' at the start)',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: _testingConnection || _submitting ? null : _testConnection,
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
          ),
          child: _testingConnection
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('测试连接'),
        ),
        FilledButton(
          onPressed: canSave ? _submit : null,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(isEditing ? '保存' : '添加'),
        ),
      ],
    );
  }

  SmbFormDraft get _draft => SmbFormDraft(
        name: _nameCtrl.text,
        host: _hostCtrl.text,
        share: _shareCtrl.text,
        rootPath: _rootPathCtrl.text,
        username: _userCtrl.text,
      );

  int get _port => int.tryParse(_portCtrl.text.trim()) ?? 445;

  SmbConfig get _draftConfig => SmbConfig(
        id: widget.initial?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        name: _nameCtrl.text,
        host: _hostCtrl.text.trim(),
        port: _port,
        share: _shareCtrl.text.trim(),
        rootPath: SmbFormLogic.normalizeRootPath(_rootPathCtrl.text),
        username: _userCtrl.text.trim(),
        password: _passCtrl.text.isEmpty ? null : _passCtrl.text,
        domain: _domainCtrl.text.trim(),
        createdAt: widget.initial?.createdAt ?? DateTime.now(),
        updatedAt: DateTime.now(),
      );

  void _onDraftChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _pickShare() async {
    if (!SmbFormLogic.canBrowseShares(_draft)) {
      _showSnack('请先填写服务器地址和用户名', isError: true);
      return;
    }

    setState(() => _probingShares = true);
    try {
      final shares = await _smbService.listShares(_draftConfig);
      if (!mounted) return;
      final selected = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFFEFF7F5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          title: const Text('Select share'),
          content: SizedBox(
            width: 320,
            child: shares.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('No shares found'),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: shares.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final share = shares[index];
                      return ListTile(
                        title: Text(share),
                        onTap: () => Navigator.pop(ctx, share),
                      );
                    },
                  ),
          ),
        ),
      );
      if (selected != null && mounted) {
        _shareCtrl.text = selected;
        _rootPathCtrl.clear();
        if (_nameCtrl.text.trim().isEmpty) {
          _nameCtrl.text = SmbFormLogic.resolveDisplayName(
            SmbFormDraft(host: _hostCtrl.text, share: selected),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        _showSnack('获取共享名失败：$e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _probingShares = false);
    }
  }

  Future<void> _pickRootPath() async {
    if (!SmbFormLogic.canBrowseRootPath(_draft)) {
      _showSnack('请先选择共享名', isError: true);
      return;
    }

    setState(() => _probingPaths = true);
    try {
      final selected = await showDialog<String>(
        context: context,
        builder: (_) => _RootPathDialog(
          config: _draftConfig,
          initialPath: SmbFormLogic.normalizeRootPath(_rootPathCtrl.text),
        ),
      );
      if (selected != null && mounted) {
        _rootPathCtrl.text = SmbFormLogic.normalizeRootPath(selected);
        if (_nameCtrl.text.trim().isEmpty) {
          _nameCtrl.text = SmbFormLogic.resolveDisplayName(
            SmbFormDraft(
              host: _hostCtrl.text,
              share: _shareCtrl.text,
              rootPath: _rootPathCtrl.text,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        _showSnack('获取目录失败：$e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _probingPaths = false);
    }
  }

  Future<void> _testConnection() async {
    if (_hostCtrl.text.trim().isEmpty) {
      _showSnack('请先填写服务器地址', isError: true);
      return;
    }

    setState(() => _testingConnection = true);
    try {
      final ok = await _smbService.testConnection(_draftConfig);
      if (mounted) {
        _showSnack(ok ? '连接成功' : '连接失败', isError: !ok);
      }
    } catch (e) {
      if (mounted) {
        _showSnack('测试失败：$e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      final normalizedRoot = SmbFormLogic.normalizeRootPath(_rootPathCtrl.text);
      final config = SmbConfig(
        id: widget.initial?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        name: SmbFormLogic.resolveDisplayName(
          SmbFormDraft(
            name: _nameCtrl.text,
            host: _hostCtrl.text,
            share: _shareCtrl.text,
            rootPath: normalizedRoot,
            username: _userCtrl.text,
          ),
        ),
        host: _hostCtrl.text.trim(),
        port: _port,
        share: _shareCtrl.text.trim(),
        rootPath: normalizedRoot,
        username: _userCtrl.text.trim(),
        password: _passCtrl.text.isEmpty ? null : _passCtrl.text,
        domain: _domainCtrl.text.trim(),
        createdAt: widget.initial?.createdAt ?? DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await widget.onSubmit(config);
      if (mounted) Navigator.pop(context);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _buildField(
    TextEditingController controller,
    String label, {
    bool obscure = false,
    TextInputType? keyboard,
    String? hint,
    Widget? suffixIcon,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboard,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          suffixIcon: suffixIcon,
          labelStyle: const TextStyle(color: Color(0x99FFFFFF)),
          hintStyle: const TextStyle(color: Color(0x61FFFFFF)),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.06),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
    );
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? const Color(0xFFF87171) : const Color(0xFF34D399),
      ),
    );
  }
}

class _RootPathDialog extends StatefulWidget {
  const _RootPathDialog({
    required this.config,
    required this.initialPath,
  });

  final SmbConfig config;
  final String initialPath;

  @override
  State<_RootPathDialog> createState() => _RootPathDialogState();
}

class _RootPathDialogState extends State<_RootPathDialog> {
  final _smbService = SmbService();
  late String _currentPath;
  bool _loading = true;
  String? _error;
  List<String> _directories = const [];

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFFEFF7F5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      title: const Text('Select root path'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current path: ${_currentPath.isEmpty ? '/' : _currentPath}'),
            const SizedBox(height: 12),
            Flexible(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Text(_error!, style: const TextStyle(color: Colors.red))
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            if (_currentPath.isNotEmpty)
                              ListTile(
                                leading: const Icon(Icons.arrow_upward),
                                title: const Text('..'),
                                onTap: _goUp,
                              ),
                            ..._directories.map(
                              (dir) => ListTile(
                                leading: const Icon(Icons.folder_outlined),
                                title: Text(dir),
                                onTap: () => _enter(dir),
                              ),
                            ),
                          ],
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _currentPath),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final directories = await _smbService.listDirectories(widget.config, _currentPath);
      if (!mounted) return;
      setState(() {
        _directories = directories;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _enter(String segment) {
    _currentPath = _currentPath.isEmpty ? segment : '$_currentPath/$segment';
    _load();
  }

  void _goUp() {
    final parts = _currentPath.split('/')..removeLast();
    _currentPath = parts.where((e) => e.isNotEmpty).join('/');
    _load();
  }
}