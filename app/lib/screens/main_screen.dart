import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/album_provider.dart';
import '../providers/photo_provider.dart';
import '../providers/smb_provider.dart';
import '../providers/transfer_provider.dart';
import '../utils/mipix_theme.dart';
import '../widgets/animations.dart';
import 'albums_screen.dart';
import 'photos_screen.dart';
import 'settings_screen.dart';
import 'smb_screen.dart';
import 'transfers_screen.dart';

/// 与小米相册一致：顶部标签栏 + 支持左右滑动切换页面。
class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with SingleTickerProviderStateMixin {
  static const _tabCount = 3;

  late final TabController _tabController;

  final _screens = const [
    PhotosScreen(),
    AlbumsScreen(),
    TransfersScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabCount, vsync: this);
    // 滑动切换时同步顶栏配色与状态栏图标明暗。
    _tabController.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeCount = ref.watch(activeTransferCountProvider);
    // 与小米相册一致：所有主页面统一使用色板配色，随主题明暗切换。
    final palette = MiPixPalette.of(context);
    final background = palette.background;
    final foreground = palette.textPrimary;

    final labels = <String>[
      '照片',
      '相册',
      activeCount > 0 ? '传输 $activeCount' : '传输',
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: MiPixTheme.overlayStyle(context),
      child: Scaffold(
        backgroundColor: background,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            color: background,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: kToolbarHeight,
                // 仿小米相册：左侧搜索、标签组整体居中、右侧「⋮」。
                child: Stack(
                  children: [
                    Center(
                      child: TabBar(
                        controller: _tabController,
                        isScrollable: true,
                        tabAlignment: TabAlignment.center,
                        indicatorColor: Colors.transparent,
                        dividerColor: Colors.transparent,
                        overlayColor: WidgetStateProperty.all(Colors.transparent),
                        indicatorSize: TabBarIndicatorSize.label,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 16),
                        labelColor: palette.accent,
                        unselectedLabelColor: palette.textPrimary,
                        labelStyle: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                        unselectedLabelStyle: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                        ),
                        tabs: [
                          for (final label in labels)
                            Tab(height: kToolbarHeight, text: label),
                        ],
                      ),
                    ),
                    Positioned(
                      right: 2,
                      top: 0,
                      bottom: 0,
                      child: _buildMoreMenu(foreground),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: _screens,
        ),
      ),
    );
  }

  /// 右上角的菜单（对应小米相册顶栏右侧的「⋮」）。
  Widget _buildMoreMenu(Color foreground) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, color: foreground),
      tooltip: '更多',
      onSelected: (value) {
        switch (value) {
          case 'smb':
            // 配置 SMB 服务器入口收进「⋮」设置中，不再占用顶部导航栏。
            Navigator.push(
              context,
              PageSlideTransition(child: const SmbScreen()),
            );
            break;
          case 'photos':
            ref.read(localPhotosProvider.notifier).load();
            break;
          case 'albums':
            ref.read(localLibraryProvider.notifier).load();
            break;
          case 'refresh_smb':
            ref.invalidate(allSmbAlbumsProvider);
            ref.invalidate(smbServersProvider);
            break;
          case 'settings':
            Navigator.push(
              context,
              PageSlideTransition(child: const SettingsScreen()),
            );
            break;
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'smb', child: Text('SMB 服务器')),
        PopupMenuItem(value: 'settings', child: Text('设置')),
        PopupMenuItem(value: 'photos', child: Text('刷新照片')),
        PopupMenuItem(value: 'albums', child: Text('刷新相册')),
        PopupMenuItem(value: 'refresh_smb', child: Text('刷新 SMB')),
      ],
    );
  }
}
