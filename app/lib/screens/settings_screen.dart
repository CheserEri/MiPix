import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_provider.dart';
import '../widgets/glass_container.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 60)),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Text(
                '设置',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: -1.2,
                ),
              ),
            ),
          ),
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
                ),
              ],
            ),
          ),
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
                          color: Colors.white.withValues(alpha: 0.04),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Image.asset('assets/branding/mipix_logo_ui.png'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '米影相册',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              '版本 1.0.0',
                              style: TextStyle(
                                color: Color(0x99FFFFFF),
                                fontSize: 13,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              '纯本地 SMB 相册管理',
                              style: TextStyle(
                                color: Color(0x66FFFFFF),
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
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0F172A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '选择主题',
              style: TextStyle(
                color: Colors.white,
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
                color: Colors.white70,
              ),
              title: Text(
                _themeLabel(mode),
                style: const TextStyle(color: Colors.white),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0x99FFFFFF),
                letterSpacing: 0.5,
              ),
            ),
          ),
          GlassContainer(
            blur: 16,
            tint: const Color(0xFF0F172A).withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(20),
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

  const _SettingsTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 18, color: iconColor),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: Color(0x66FFFFFF),
          fontSize: 13,
        ),
      ),
      trailing: onTap != null
          ? const Icon(Icons.chevron_right, color: Color(0x33FFFFFF))
          : null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
    );
  }
}