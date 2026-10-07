import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/album_provider.dart';
import '../providers/photo_provider.dart';
import '../providers/smb_provider.dart';
import '../providers/transfer_provider.dart';
import '../utils/mipix_theme.dart';
import 'albums_screen.dart';
import 'photos_screen.dart';
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
  static const _tabCount = 4;

  late final TabController _tabController;

  final _screens = const [
    PhotosScreen(),
    AlbumsScreen(),
    SmbScreen(),
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
    final index = _tabController.index;
    // 「照片 / 相册」与小米相册一致使用浅色，其余页面保持深色沉浸风。
    final isLight = index <= 1;
    final background = isLight ? MiPixColors.miuiBackground : Colors.black;
    final foreground = isLight ? MiPixColors.miuiText : Colors.white;

    final labels = <String>[
      '照片',
      '相册',
      'SMB',
      activeCount > 0 ? '传输 $activeCount' : '传输',
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isLight ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
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
                child: Row(
                  children: [
                    Expanded(
                      child: TabBar(
                        controller: _tabController,
                        indicatorColor: Colors.transparent,
                        dividerColor: Colors.transparent,
                        indicatorSize: TabBarIndicatorSize.tab,
                        labelColor: MiPixColors.miuiBlue,
                        unselectedLabelColor: foreground,
                        labelStyle: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                        unselectedLabelStyle: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w400,
                        ),
                        tabs: [
                          for (final label in labels)
                            Tab(height: kToolbarHeight, text: label),
                        ],
                      ),
                    ),
                    _buildMoreMenu(foreground),
                    const SizedBox(width: 2),
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

  /// 右上角的刷新菜单（对应小米相册顶栏右侧的「⋮」）。
  Widget _buildMoreMenu(Color foreground) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, color: foreground),
      tooltip: '更多',
      onSelected: (value) {
        switch (value) {
          case 'photos':
            ref.read(localPhotosProvider.notifier).load();
            break;
          case 'albums':
            ref.read(localLibraryProvider.notifier).load();
            break;
          case 'smb':
            ref.invalidate(allSmbAlbumsProvider);
            ref.invalidate(smbServersProvider);
            break;
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'photos', child: Text('刷新照片')),
        PopupMenuItem(value: 'albums', child: Text('刷新相册')),
        PopupMenuItem(value: 'smb', child: Text('刷新 SMB')),
      ],
    );
  }
}
