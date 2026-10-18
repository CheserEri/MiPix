import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../providers/smb_provider.dart';
import '../providers/transfer_provider.dart';
import '../services/cache_service.dart';
import '../services/smb_service.dart';
import '../utils/mipix_theme.dart';
import 'smb_screen.dart';

/// 设置页：对齐小米相册「设置」——大标题随滚动收起居中、纯列表分行、
/// 小号灰色分组标题、整行描边分隔线，行内右侧为箭头或开关，不使用图标块与卡片外框。
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);
    final palette = MiPixPalette.of(context);
    final servers =
        ref.watch(smbServersProvider).valueOrNull ?? const <SmbConfig>[];
    final activeId = ref.watch(effectiveServerIdProvider);
    SmbConfig? active;
    for (final s in servers) {
      if (s.id == activeId) {
        active = s;
        break;
      }
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: MiPixTheme.overlayStyle(context),
      // 小米设置页大标题：展开时大号粗体、滚动后收起并居中变小。
      // SliverAppBar.large 正是按「展开=headlineMedium / 收起=titleLarge」取字号，
      // 故此处去掉全局 appBarTheme.titleTextStyle（否则两者同号），
      // 并把 headlineMedium 覆写为小米风格的 30 号粗体。
      child: Theme(
        data: Theme.of(context).copyWith(
          appBarTheme: AppBarThemeData(
            backgroundColor: palette.background,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            centerTitle: true,
            iconTheme: IconThemeData(color: palette.textPrimary),
            systemOverlayStyle: MiPixTheme.overlayStyle(context),
          ),
          textTheme: Theme.of(context).textTheme.copyWith(
            headlineMedium: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: palette.textPrimary,
            ),
          ),
        ),
        child: Scaffold(
          backgroundColor: palette.background,
          body: CustomScrollView(
            slivers: [
              SliverAppBar.large(
                pinned: true,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.pop(context),
                ),
                title: const Text('设置'),
              ),
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Section(
                      title: '云服务',
                      first: true,
                      children: [
                        _SettingsRow(
                          title: 'SMB 服务器',
                          subtitle: _serverSubtitle(servers, active),
                          showDivider: false,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SmbScreen(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    _Section(
                      title: '外观',
                      children: [
                        _SettingsRow(
                          title: '主题模式',
                          subtitle: _themeLabel(themeMode),
                          showDivider: false,
                          onTap: () => _showThemePicker(context, ref),
                        ),
                      ],
                    ),
                    _Section(
                      title: '存储',
                      children: const [
                        _SettingsRow(
                          title: '本地相册根目录',
                          subtitle: '/storage/emulated/0/Pictures',
                        ),
                        _SettingsRow(
                          title: '下载目录',
                          subtitle: '/storage/emulated/0/Download/MiPix',
                          showDivider: false,
                        ),
                      ],
                    ),
                    const _TransferSection(),
                    const _CacheSection(),
                    _Section(
                      title: '关于',
                      children: const [
                        _SettingsRow(
                          title: '米影相册',
                          subtitle: '版本 1.0.0 · 纯本地 SMB 相册管理',
                          showDivider: false,
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _serverSubtitle(List<SmbConfig> servers, SmbConfig? active) {
    if (servers.isEmpty) return '未配置，点击添加服务器';
    final base = '已配置 ${servers.length} 台';
    return active == null ? base : '$base · 当前 ${active.name}';
  }

  String _themeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return '跟随系统';
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
    }
  }

  void _showThemePicker(BuildContext context, WidgetRef ref) {
    final palette = MiPixPalette.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: palette.textSecondary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '选择主题',
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            ...ThemeMode.values.map(
              (mode) => ListTile(
                leading: Icon(
                  mode == ThemeMode.system
                      ? Icons.brightness_auto
                      : mode == ThemeMode.light
                      ? Icons.light_mode
                      : Icons.dark_mode,
                  color: palette.textSecondary,
                ),
                title: Text(
                  _themeLabel(mode),
                  style: TextStyle(color: palette.textPrimary),
                ),
                onTap: () {
                  ref.read(themeProvider.notifier).setMode(mode);
                  Navigator.pop(ctx);
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

/// 一个分组：小号灰色标题 + 若干行。
class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final bool first;

  const _Section({
    required this.title,
    required this.children,
    this.first = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(20, first ? 4 : 22, 20, 6),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: palette.textSecondary,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

/// 设置行：对齐小米相册——左侧标题（可选灰色副标题），右侧箭头，下方整行分隔线。
class _SettingsRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool showDivider;

  const _SettingsRow({
    required this.title,
    this.subtitle,
    this.onTap,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16.5,
                          fontWeight: FontWeight.w600,
                          color: palette.textPrimary,
                          height: 1.3,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 13,
                            color: palette.textSecondary,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (onTap != null) ...[
                  const SizedBox(width: 12),
                  Icon(
                    Icons.chevron_right,
                    color: palette.textSecondary,
                    size: 20,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (showDivider)
          Divider(height: 1, thickness: 1, indent: 20, color: palette.divider),
      ],
    );
  }
}

/// 传输设置：备份并发数（默认 4，最高 8）。
class _TransferSection extends ConsumerWidget {
  const _TransferSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final concurrency = ref.watch(uploadConcurrencyProvider);
    return _Section(
      title: '传输',
      children: [
        _SettingsRow(
          title: '备份并发数',
          subtitle: '同时上传 $concurrency 个文件',
          showDivider: false,
          onTap: () => _pickConcurrency(context, ref, concurrency),
        ),
      ],
    );
  }

  Future<void> _pickConcurrency(
    BuildContext context,
    WidgetRef ref,
    int current,
  ) async {
    final palette = MiPixPalette.of(context);
    final chosen = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: palette.textSecondary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '备份并发数',
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '同时上传的文件数，过高可能被服务器限流（1 - $maxUploadConcurrency）',
              style: TextStyle(color: palette.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            ...List.generate(maxUploadConcurrency, (i) => i + 1).map(
              (value) => ListTile(
                title: Text(
                  '$value 个',
                  style: TextStyle(
                    color: value == current
                        ? palette.accent
                        : palette.textPrimary,
                  ),
                ),
                trailing: value == current
                    ? Icon(Icons.check, color: palette.accent, size: 20)
                    : null,
                onTap: () => Navigator.pop(ctx, value),
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    await ref.read(uploadConcurrencyProvider.notifier).setConcurrency(chosen);
  }
}

/// 缓存设置：显示占用、设置上限、清除缓存。
class _CacheSection extends StatefulWidget {
  const _CacheSection();

  @override
  State<_CacheSection> createState() => _CacheSectionState();
}

class _CacheSectionState extends State<_CacheSection> {
  static const _limitOptions = <int>[
    200 * 1024 * 1024,
    500 * 1024 * 1024,
    1024 * 1024 * 1024,
    2 * 1024 * 1024 * 1024,
  ];

  final CacheService _cache = CacheService();
  int? _size;
  int? _limit;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    await _cache.init();
    final size = await _cache.getCacheSize();
    final limit = await _cache.getCacheLimit();
    if (!mounted) return;
    setState(() {
      _size = size;
      _limit = limit;
    });
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  Future<void> _clearCache() async {
    final palette = MiPixPalette.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text('清除缓存', style: TextStyle(color: palette.textPrimary)),
        content: Text(
          '将删除已缓存的缩略图与原图（约 ${_size == null ? '--' : _formatBytes(_size!)}），'
          '下次浏览时会重新从 SMB 加载。',
          style: TextStyle(color: palette.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: palette.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('清除', style: TextStyle(color: palette.accent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    await _cache.clearAllCache();
    SmbService.clearThumbnailMemoryCache();
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('缓存已清除'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _pickLimit() async {
    final palette = MiPixPalette.of(context);
    final chosen = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: palette.textSecondary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '缓存上限',
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '超出后自动优先清理最早的缓存原图',
              style: TextStyle(color: palette.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            ..._limitOptions.map(
              (bytes) => ListTile(
                title: Text(
                  _formatBytes(bytes),
                  style: TextStyle(
                    color: bytes == _limit
                        ? palette.accent
                        : palette.textPrimary,
                  ),
                ),
                trailing: bytes == _limit
                    ? Icon(Icons.check, color: palette.accent, size: 20)
                    : null,
                onTap: () => Navigator.pop(ctx, bytes),
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    await _cache.setCacheLimit(chosen);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: '缓存',
      children: [
        _SettingsRow(
          title: '已用缓存',
          subtitle: _size == null ? '统计中…' : _formatBytes(_size!),
        ),
        _SettingsRow(
          title: '缓存上限',
          subtitle: _limit == null ? '统计中…' : _formatBytes(_limit!),
          onTap: _pickLimit,
        ),
        _SettingsRow(
          title: '清除缓存',
          subtitle: _busy ? '正在清理…' : '删除所有已缓存的缩略图与原图',
          showDivider: false,
          onTap: _busy ? null : _clearCache,
        ),
      ],
    );
  }
}
