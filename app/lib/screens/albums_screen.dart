import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/album_provider.dart';
import '../models/models.dart';import '../providers/smb_provider.dart';
import '../widgets/glass_container.dart';
import '../widgets/animations.dart';
import 'photo_grid_screen.dart';
import '../services/photo_service.dart';
import '../services/smb_service.dart';
import '../services/local_storage_service.dart';
import '../utils/mipix_theme.dart';
import '../widgets/smb_image_widget.dart';

/// SMB 远程图片加载Widget

class SmbRemoteImageState extends State<SmbRemoteImage> {
  Uint8List? _imageData;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final servers = await LocalStorageService().getSmbServers();
      final server = servers.firstWhere((s) => s.id == widget.serverId);
      final data = await SmbService().readFile(server, widget.remotePath);
      if (mounted) {
        setState(() {
          _imageData = data;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: const Color(0xFF1A1A2E),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        ),
      );
    }
    if (_imageData == null) {
      return Container(
        color: const Color(0xFF1A1A2E),
        child: const Icon(Icons.broken_image, color: Colors.white24),
      );
    }
    return Image.memory(
      _imageData!,
      fit: BoxFit.cover,
      cacheWidth: 400,
      errorBuilder: (_, __, ___) => Container(
        color: const Color(0xFF1A1A2E),
        child: const Icon(Icons.broken_image, color: Colors.white24),
      ),
    );
  }
}

class AlbumsScreen extends ConsumerStatefulWidget {
  const AlbumsScreen({super.key});

  @override
  ConsumerState<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends ConsumerState<AlbumsScreen> {
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
    final localLibrary = ref.watch(localLibraryProvider);

    return Scaffold(
      backgroundColor: MiPixColors.miuiBackground,
      body: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          localLibrary.when(
            loading: () => const SliverFillRemaining(
              child: Center(
                  child: CircularProgressIndicator(color: MiPixColors.miuiBlue)),
            ),
            error: (err, _) => SliverFillRemaining(
              child: Center(
                child: Text('加载失败: $err',
                    style: const TextStyle(color: MiPixColors.miuiSubText)),
              ),
            ),
            data: (library) {
              if (!library.canRead) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyStateWidget(
                    light: true,
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
                    light: true,
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
                return const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(48),
                    child: EmptyStateWidget(
                      light: true,
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
          const SliverToBoxAdapter(
            child: Divider(
              height: 1,
              thickness: 1,
              color: MiPixColors.miuiDivider,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Row(
                children: [
                  const Text(
                    'SMB 相册',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: MiPixColors.miuiSubText,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () { ref.invalidate(allSmbAlbumsProvider); },
                    icon: const Icon(Icons.refresh, size: 18, color: MiPixColors.miuiSubText),
                    label: const Text('刷新', style: TextStyle(color: MiPixColors.miuiSubText)),
                  ),
                ],
              ),
            ),
          ),
          ref.watch(allSmbAlbumsProvider).when(
            loading: () => const SliverToBoxAdapter(
              child: SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator(color: MiPixColors.miuiBlue)),
              ),
            ),
            error: (err, _) => SliverToBoxAdapter(
              child: Center(child: Text('加载失败: $err', style: const TextStyle(color: MiPixColors.miuiSubText))),
            ),
            data: (albums) {
              if (albums.isEmpty) {
                return const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(48),
                    child: EmptyStateWidget(
                      light: true,
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
      PageFadeTransition(
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
      PageFadeTransition(
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
    return [
      if (divider)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 16),
            child: Divider(
              height: 1,
              thickness: 1,
              color: MiPixColors.miuiDivider,
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
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: MiPixColors.miuiSubText,
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
      PageFadeTransition(
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

  /// 与小米相册一致：封面在上（约 1.15 宽高比、圆角 12），
  /// 相册名与张数排在封面下方（名称近黑、数量灰色）。
  @override
  Widget build(BuildContext context) {
    return BounceTap(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1.15,
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
                      Image.file(
                        File(coverPath!),
                        fit: BoxFit.cover,
                        cacheWidth: 400,
                        errorBuilder: (_, __, ___) => _placeholder(),
                      )
                  else
                    _placeholder(),
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
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: MiPixColors.miuiText,
              height: 1.2,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 1),
          Text(
            '$count',
            style: const TextStyle(
              fontSize: 13,
              color: MiPixColors.miuiSubText,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: MiPixColors.miuiGridFill,
      child: Center(
        child: Icon(
          icon ?? Icons.folder,
          size: 40,
          color: MiPixColors.miuiSubText.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}
