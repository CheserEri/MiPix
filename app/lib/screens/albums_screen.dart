import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/album_provider.dart';
import '../providers/app_provider.dart';
import '../models/models.dart';import '../providers/photo_provider.dart';
import '../providers/smb_provider.dart';
import '../widgets/glass_container.dart';
import '../widgets/animations.dart';
import '../widgets/smb_server_switcher.dart';
import 'photo_grid_screen.dart';
import '../services/photo_service.dart';
import '../utils/mipix_theme.dart';
import '../widgets/smb_image_widget.dart';
import '../widgets/thumb_image.dart';

class AlbumsScreen extends ConsumerStatefulWidget {
  const AlbumsScreen({super.key});

  @override
  ConsumerState<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends ConsumerState<AlbumsScreen>
    with AutomaticKeepAliveClientMixin {
  /// 标签页切换时不销毁本页，避免每次回到「相册」重新加载相册列表。
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 进入页面时请求权限并加载相册。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(localLibraryProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 要求先调用
    // 系统媒体库变化（如新增截图）时自动刷新相册列表（封面 / 张数）。
    ref.listen(mediaChangeTickProvider, (_, __) {
      ref.read(localLibraryProvider.notifier).load();
    });
    final palette = MiPixPalette.of(context);
    final localLibrary = ref.watch(localLibraryProvider);
    // 当前生效的服务器：默认服务器已被删除/未设置时回退到第一台。
    final activeId = ref.watch(defaultServerProvider);
    final smbServers =
        ref.watch(smbServersProvider).valueOrNull ?? const <SmbConfig>[];
    final activeServerId = smbServers.isEmpty
        ? ''
        : (smbServers.any((s) => s.id == activeId)
            ? activeId!
            : smbServers.first.id);

    return Scaffold(
      backgroundColor: palette.background,
      body: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          localLibrary.when(
            loading: () => SliverFillRemaining(
              child: Center(
                  child: CircularProgressIndicator(color: palette.accent)),
            ),
            error: (err, _) => SliverFillRemaining(
              child: Center(
                child: Text('加载失败: $err',
                    style: TextStyle(color: palette.textSecondary)),
              ),
            ),
            data: (library) {
              if (!library.canRead) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyStateWidget(
                    icon: Icons.lock_outline,
                    title: '需要相册访问权限',
                    subtitle: library.access == LocalAccess.restricted
                        ? '系统限制了本应用读取相册，请在系统设置中为 米影相册 开启"存储/照片"权限。'
                        : '米影相册 需要相册权限才能显示本地相册，请前往系统设置为 米影相册 开启权限。',
                    action: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton(
                          onPressed: () => PhotoService.openSettings(),
                          child: const Text('打开设置'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: () =>
                              ref.read(localLibraryProvider.notifier).load(),
                          child: const Text('重新检测'),
                        ),
                      ],
                    ),
                  ),
                );
              }

              if (library.blank) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyStateWidget(
                    icon: Icons.visibility_off_outlined,
                    title: '读不到任何照片',
                    subtitle: '已获得权限但仍读不到照片。MIUI 可能授予了"空白权限"，'
                        '请在系统设置中先关闭再重新开启 米影相册 的存储/照片权限，然后重试。',
                    action: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton(
                          onPressed: () => PhotoService.openSettings(),
                          child: const Text('打开设置'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: () =>
                              ref.read(localLibraryProvider.notifier).load(),
                          child: const Text('重新检测'),
                        ),
                      ],
                    ),
                  ),
                );
              }

              if (library.view.isEmpty) {
                return SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(48),
                    child: EmptyStateWidget(
                      icon: Icons.photo_library_outlined,
                      title: '暂无本地相册',
                      subtitle: '设备上还没有可显示的图片或视频',
                    ),
                  ),
                );
              }

              return SliverMainAxisGroup(
                slivers: [
                  ..._localSections(library.view),
                ],
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          SliverToBoxAdapter(
            child: Divider(
              height: 1,
              thickness: 1,
              color: palette.divider,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Row(
                children: [
                  Text(
                    'SMB 相册',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: palette.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const SmbServerSwitcher(),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () async {
                      final servers =
                          ref.read(smbServersProvider).value ?? const [];
                      await rescanSmbAlbums(servers);
                      ref.invalidate(allSmbAlbumsProvider);
                    },
                    icon: Icon(Icons.refresh, size: 18, color: palette.textSecondary),
                    label: Text('刷新', style: TextStyle(color: palette.textSecondary)),
                  ),
                ],
              ),
            ),
          ),
          ref.watch(allSmbAlbumsProvider(activeServerId)).when(
            loading: () => SliverToBoxAdapter(
              child: SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator(color: palette.accent)),
              ),
            ),
            error: (err, _) => SliverToBoxAdapter(
              child: Center(child: Text('加载失败: $err', style: TextStyle(color: palette.textSecondary))),
            ),
            data: (albums) {
              if (albums.isEmpty) {
                return SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(48),
                    child: EmptyStateWidget(
                      icon: Icons.folder_off,
                      title: '暂无线 SMB 相册',
                      subtitle: '请检查服务器 rootPath 设置是否正确',
                    ),
                  ),
                );
              }
              return SliverToBoxAdapter(
                child: _albumGrid(
                  albums,
                  onTap: _openSmbAlbum,
                  onLongPress: _setSmbCover,
                ),
              );
            },
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }

  void _openSmbAlbum(Album album) {
    final serverId =
        album.source is SmbSource ? (album.source as SmbSource).serverId : '';
    if (serverId.isEmpty) return;
    ref.read(selectedSmbServerProvider.notifier).state = serverId;
    ref.read(smbCurrentPathProvider.notifier).state = album.id;
    Navigator.push(
      context,
      PageSlideTransition(
        child: PhotoGridScreen(
          albumId: serverId,
          albumName: album.name,
          isLocal: false,
        ),
      ),
    );
  }

  Future<void> _setSmbCover(Album album) async {
    final serverId =
        album.source is SmbSource ? (album.source as SmbSource).serverId : '';
    if (serverId.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置自定义封面'),
        content: Text('为相册 "${album.name}" 选择一张照片作为封面？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('选择照片'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final result = await Navigator.push(
      context,
      PageSlideTransition(
        child: PhotoGridScreen(
          albumId: serverId,
          albumName: album.name,
          isLocal: false,
          isSettingCover: true,
          albumPath: album.id,
        ),
      ),
    );
    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('封面已更新'), duration: Duration(seconds: 1)),
      );
      // 相册列表会自动刷新（getAlbums 会读取新的自定义封面）
    }
  }

  /// 本地相册按 MIUI 结构分为「系统相册 / 我的相册 / 更多相册」三段，
  /// 其中第一段（系统相册）与小米相册一致不显示标题。
  List<Widget> _localSections(LocalLibraryView view) {
    return [
      ..._albumSection(null, view.system, divider: false),
      ..._albumSection('我的相册', view.mine, divider: true),
      ..._albumSection('更多相册', view.more, divider: true),
    ];
  }

  List<Widget> _albumSection(String? title, List<Album> albums,
      {required bool divider}) {
    if (albums.isEmpty) return const [];
    final palette = MiPixPalette.of(context);
    return [
      if (divider)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Divider(
              height: 1,
              thickness: 1,
              color: palette.divider,
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, divider ? 22 : 16, 16, 12),
          child: title == null
              ? const SizedBox.shrink()
              : Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: palette.textSecondary,
                  ),
                ),
        ),
      ),
      SliverToBoxAdapter(child: _albumGrid(albums)),
    ];
  }

  /// 相册网格：3 列，卡片高度自适应（与小米相册一致，名称在封面下方）。
  Widget _albumGrid(
    List<Album> albums, {
    void Function(Album album)? onTap,
    void Function(Album album)? onLongPress,
  }) {
    const double gap = 12;
    final rows = <Widget>[];
    for (var start = 0; start < albums.length; start += 3) {
      final end = (start + 3 <= albums.length) ? start + 3 : albums.length;
      final row = albums.sublist(start, end);
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: gap),
            Expanded(
              child: i < row.length
                  ? _AlbumCard(
                      name: row[i].name,
                      count: row[i].count,
                      coverPath: row[i].coverPath,
                      source: row[i].source,
                      icon: row[i].id == SystemAlbum.videos
                          ? Icons.videocam
                          : null,
                      onTap: () => (onTap ?? _openAlbum)(row[i]),
                      onLongPress: onLongPress == null
                          ? null
                          : () => onLongPress(row[i]),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ],
      ));
      if (end < albums.length) rows.add(const SizedBox(height: 18));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child:
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
    );
  }

  void _openAlbum(Album album) {
    Navigator.push(
      context,
      PageSlideTransition(
        child: PhotoGridScreen(
          albumId: album.id,
          albumName: album.name,
          isLocal: true,
        ),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final String name;
  final int count;
  final String? coverPath;
  final IconData? icon;
  final MediaSource source;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _AlbumCard({
    required this.name,
    required this.count,
    this.coverPath,
    this.icon,
    required this.source,
    required this.onTap,
    this.onLongPress,
  });

  /// 与小米相册一致：封面为正方形（1:1、圆角 12），
  /// 相册名与张数排在封面下方（名称近黑、数量灰色）。
  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    return BounceTap(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1.0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (coverPath != null)
                    if (source is SmbSource)
                      SmbRemoteImage(
                        serverId: (source as SmbSource).serverId,
                        remotePath: coverPath!,
                      )
                    else
                      ThumbImage(
                        path: coverPath!,
                        fit: BoxFit.cover,
                        cacheWidth: 400,
                        errorBuilder: (_, __, ___) => _placeholder(context),
                      )
                  else
                    _placeholder(context),
                  if (icon == Icons.videocam)
                    const Positioned(
                      left: 6,
                      bottom: 6,
                      child: Icon(
                        Icons.play_circle_fill,
                        size: 22,
                        color: Colors.white,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            name,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: palette.textPrimary,
              height: 1.2,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 1),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 13,
              color: palette.textSecondary,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final palette = MiPixPalette.of(context);
    return Container(
      color: palette.fill,
      child: Center(
        child: Icon(
          icon ?? Icons.folder,
          size: 40,
          color: palette.textSecondary.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}
