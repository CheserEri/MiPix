import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_provider.dart';
import '../services/cache_service.dart';
import '../services/smb_service.dart';
import '../utils/mipix_theme.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);
    final palette = MiPixPalette.of(context);

    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        backgroundColor: palette.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          '设置',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: palette.textPrimary,
          ),
        ),
        iconTheme: IconThemeData(color: palette.textPrimary),
      ),
      body: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(
            child: _SectionCard(
              title: '外观',
              children: [
                _SettingsTile(
                  icon: Icons.dark_mode,
                  iconColor: const Color(0xFF94A3B8),
                  title: '主题模式',
                  subtitle: _themeLabel(themeMode),
                  onTap: () => _showThemePicker(context, ref),
                  showDivider: false,
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          SliverToBoxAdapter(
            child: _SectionCard(
              title: '存储',
              children: [
                const _SettingsTile(
                  icon: Icons.folder,
                  iconColor: Color(0xFF60A5FA),
                  title: '本地相册根目录',
                  subtitle: '/storage/emulated/0/Pictures',
                ),
                const _SettingsTile(
                  icon: Icons.cloud_download,
                  iconColor: Color(0xFF34D399),
                  title: '下载目录',
                  subtitle: '/storage/emulated/0/Download/MiPix',
                  showDivider: false,
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          const SliverToBoxAdapter(child: _CacheSection()),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          SliverToBoxAdapter(
            child: _SectionCard(
              title: '关于',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                  child: Row(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: palette.fill,
                          border: Border.all(color: palette.divider),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Image.asset('assets/branding/mipix_logo_ui.png'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '米影相册',
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '版本 1.0.0',
                              style: TextStyle(
                                color: palette.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '纯本地 SMB 相册管理',
                              style: TextStyle(
                                color: palette.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
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
            ...ThemeMode.values.map((mode) => ListTile(
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
            )),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SectionCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: palette.textSecondary,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.divider),
            ),
            child: Column(
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool showDivider;

  const _SettingsTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          onTap: onTap,
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          title: Text(
            title,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 13,
            ),
          ),
          trailing: onTap != null
              ? Icon(Icons.chevron_right, color: palette.textSecondary, size: 20)
              : null,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
        if (showDivider)
          Padding(
            padding: const EdgeInsets.only(left: 68),
            child: Divider(height: 1, thickness: 1, color: palette.divider),
          ),
      ],
    );
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
    return _SectionCard(
      title: '缓存',
      children: [
        _SettingsTile(
          icon: Icons.sd_storage,
          iconColor: const Color(0xFFF59E0B),
          title: '已用缓存',
          subtitle: _size == null ? '统计中…' : _formatBytes(_size!),
        ),
        _SettingsTile(
          icon: Icons.straighten,
          iconColor: const Color(0xFFA78BFA),
          title: '缓存上限',
          subtitle: _limit == null ? '统计中…' : _formatBytes(_limit!),
          onTap: _pickLimit,
        ),
        _SettingsTile(
          icon: Icons.delete_outline,
          iconColor: const Color(0xFFF87171),
          title: '清除缓存',
          subtitle: _busy ? '正在清理…' : '删除所有已缓存的缩略图与原图',
          onTap: _busy ? null : _clearCache,
        ),
      ],
    );
  }
}