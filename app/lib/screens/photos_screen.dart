import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../providers/album_provider.dart';
import '../providers/photo_provider.dart';
import '../providers/smb_provider.dart';
import '../providers/transfer_provider.dart';
import '../services/photo_service.dart';
import '../widgets/glass_container.dart';
import '../widgets/animations.dart';
import '../widgets/local_media_thumb.dart';
import '../utils/mipix_theme.dart';
import 'photo_viewer_screen.dart';
import '../services/smb_service.dart';
import '../widgets/smb_image_widget.dart';

/// 相册选择列表项（支持本地和远程封面）
class _AlbumSelectorItem extends StatelessWidget {
  final Album album;
  final bool selected;
  final VoidCallback onTap;

  const _AlbumSelectorItem({
    required this.album,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: album.coverPath != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: album.source is SmbSource
                  ? SmbRemoteImage(
                      serverId: (album.source as SmbSource).serverId,
                      remotePath: album.coverPath!,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                    )
                  : Image.file(
                      File(album.coverPath!),
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 48,
                        height: 48,
                        color: palette.fill,
                        child: Icon(Icons.folder,
                            size: 24, color: palette.textSecondary),
                      ),
                    ),
            )
          : Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: palette.fill,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.folder,
                  size: 24, color: palette.textSecondary),
            ),
      title: Text(album.name,
          style: TextStyle(color: palette.textPrimary)),
      subtitle: Text('${album.count} 张照片',
          style: TextStyle(color: palette.textSecondary)),
      trailing: selected
          ? Icon(Icons.check_circle, color: palette.accent)
          : null,
      onTap: onTap,
    );
  }
}

class PhotosScreen extends ConsumerStatefulWidget {
  const PhotosScreen({super.key});

  @override
  ConsumerState<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends ConsumerState<PhotosScreen>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();

  /// 标签页切换时不销毁本页。否则每次回到「照片」都会重新挂载 →
  /// initState 再次 load() → 重新扫描媒体库并闪一次转圈。
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 进入页面时请求权限并加载照片。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(localPhotosProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 要求先调用
    final palette = MiPixPalette.of(context);
    final photosAsync = ref.watch(localPhotosProvider);
    final access = ref.watch(localAccessProvider).valueOrNull;
    final isMultiSelect = ref.watch(isMultiSelectProvider);
    final selected = ref.watch(selectedPhotosProvider);
    final synced = ref.watch(syncedPhotosProvider);

    return Scaffold(
      backgroundColor: palette.background,
      appBar: isMultiSelect
          ? AppBar(
              title: Text(
                '已选择 ${selected.length} 项',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary),
              ),
              backgroundColor: palette.background,
              elevation: 0,
              iconTheme: IconThemeData(color: palette.textPrimary),
              actions: [
                IconButton(
                  icon: const Icon(Icons.select_all),
                  onPressed: () {
                    final photos = ref.read(localPhotosProvider).valueOrNull ?? [];
                    ref.read(selectedPhotosProvider.notifier).state =
                        photos.map((p) => p.id).toSet();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => toggleMultiSelect(ref),
                ),
              ],
            )
          : null,
      body: photosAsync.when(
        loading: () => Center(
            child: CircularProgressIndicator(color: palette.accent)),
        error: (err, _) => Center(
          child: Text('加载失败: $err',
              style: TextStyle(color: palette.textSecondary)),
        ),
        data: (photos) {
          if (access != null && !access.canRead) {
            return EmptyStateWidget(
              icon: Icons.lock_outline,
              title: '需要相册访问权限',
              subtitle: access == LocalAccess.restricted
                  ? '系统限制了本应用读取相册，请在系统设置中为 米影相册 开启"存储/照片"权限。'
                  : '米影相册 需要相册权限才能显示照片，请前往系统设置为 米影相册 开启权限。',
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
                        ref.read(localPhotosProvider.notifier).load(),
                    child: const Text('重新检测'),
                  ),
                ],
              ),
            );
          }
          if (photos.isEmpty) {
            return const EmptyStateWidget(
              icon: Icons.photo_library_outlined,
              title: '暂无照片',
              subtitle: '设备上还没有可显示的图片或视频',
            );
          }
          final grouped = _groupByDate(photos);
          return CustomScrollView(
            controller: _scrollController,
            slivers: [
              // 顶部留白（顶栏下方）
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
              for (final entry in grouped.entries) ...[
                SliverToBoxAdapter(
                  child: DateGroupHeader(_formatDateHeader(entry.key)),
                ),
                SliverPadding(
                  padding: EdgeInsets.zero,
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      crossAxisSpacing: 3,
                      mainAxisSpacing: 3,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final photo = entry.value[index];
                        final isSelected = selected.contains(photo.id);
                        return _PhotoTile(
                          photo: photo,
                          isMultiSelect: isMultiSelect,
                          isSelected: isSelected,
                          isSynced: synced.contains(photo.path),
                          onTap: () {
                            if (isMultiSelect) {
                              togglePhotoSelection(ref, photo.id);
                              HapticFeedback.lightImpact();
                            } else {
                              _openViewer(photos, photo);
                            }
                          },
                          onLongPress: () {
                            if (!isMultiSelect) {
                              toggleMultiSelect(ref);
                              togglePhotoSelection(ref, photo.id);
                              HapticFeedback.mediumImpact();
                            }
                          },
                        );
                      },
                      childCount: entry.value.length,
                    ),
                  ),
                ),
              ],
              const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
            ],
          );
        },
      ),
      bottomSheet: isMultiSelect && selected.isNotEmpty
          ? _MultiSelectBottomBar(
              selectedCount: selected.length,
              onBackup: () => _showBackupDialog(selected.toList()),
              onClear: () {
                ref.read(selectedPhotosProvider.notifier).state = {};
              },
            )
          : null,
    );
  }

  Map<DateTime, List<MediaItem>> _groupByDate(List<MediaItem> photos) {
    final map = <DateTime, List<MediaItem>>{};
    for (final photo in photos) {
      final date = DateTime(
        photo.modifiedAt.year,
        photo.modifiedAt.month,
        photo.modifiedAt.day,
      );
      map.putIfAbsent(date, () => []).add(photo);
    }
    final sorted = Map.fromEntries(
      map.entries.toList()..sort((a, b) => b.key.compareTo(a.key)),
    );
    return sorted;
  }

  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    if (date == today) return '今天';
    if (date == yesterday) return '昨天';
    // 与小米相册一致：只显示「M月d日」，不带年份与星期。
    // 模式里只有数字占位符，无需 zh_CN 语言包，避免启动时初始化 intl 数据。
    return DateFormat('M月d日').format(date);
  }

  void _openViewer(List<MediaItem> photos, MediaItem initial) {
    final index = photos.indexWhere((p) => p.id == initial.id);
    Navigator.push(
      context,
      PageFadeTransition(
        child: PhotoViewerScreen(
          photos: photos,
          initialIndex: index,
        ),
      ),
    );
  }

    void _showBackupDialog(List<String> photoIds) {
    final palette = MiPixPalette.of(context);
    final photos = ref.read(localPhotosProvider).valueOrNull ?? [];
    final paths = photoIds
        .map((id) => photos.firstWhere((p) => p.id == id).path)
        .where((p) => p.isNotEmpty)
        .toList();

    final serversAsync = ref.read(smbServersProvider);
    final servers = serversAsync.valueOrNull ?? [];

    if (servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先添加 SMB 服务器')),
      );
      return;
    }

    String? selectedServer = ref.read(defaultServerProvider);
    if (selectedServer == null || !servers.any((s) => s.id == selectedServer)) {
      selectedServer = servers.first.id;
    }
    var remoteDir = ref.read(defaultBackupPathProvider);
    var selectedAlbumId = <String>{}; // 多选相册，为空则使用 remoteDir
    var isCreating = false; // 是否正在创建相册

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            // 获取选中服务器的相册
            final selectedServerObj = servers.firstWhere((s) => s.id == selectedServer);
            final albumsAsync = ref.watch(smbAlbumsProvider(selectedServer!));
            final albums = albumsAsync.valueOrNull ?? [];

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
                left: 20,
                right: 20,
                top: 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '备份到 SMB',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('选择服务器',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: palette.textSecondary)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: servers.map((s) {
                      return ChoiceChip(
                        label: Text(s.name,
                            style: TextStyle(
                                color: selectedServer == s.id
                                    ? Colors.white
                                    : palette.textPrimary)),
                        selected: selectedServer == s.id,
                        selectedColor: palette.accent,
                        backgroundColor: palette.fill,
                        onSelected: (_) {
                          setState(() {
                            selectedServer = s.id;
                            selectedAlbumId.clear(); // 重置相册选择
                            remoteDir = '';
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),
                  Text('选择相册（可选）',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: palette.textSecondary)),
                  const SizedBox(height: 10),
                  ...albums.map((album) => _AlbumSelectorItem(
                        album: album,
                        selected: selectedAlbumId.contains(album.id),
                        onTap: () {
                          setState(() {
                            if (selectedAlbumId.contains(album.id)) {
                              selectedAlbumId.remove(album.id);
                            } else {
                              selectedAlbumId.add(album.id);
                            }
                            remoteDir = album.id;
                          });
                        },
                      )),
                  // 新建相册按钮
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: palette.fill,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: isCreating
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: palette.accent,
                              ),
                            )
                          : Icon(Icons.create_new_folder,
                              color: palette.textSecondary),
                    ),
                    title: Text('新建相册',
                        style: TextStyle(color: palette.textPrimary)),
                    trailing: isCreating
                        ? null
                        : Icon(Icons.add, color: palette.textSecondary),
                    onTap: isCreating
                        ? null
                        : () async {
                            final controller = TextEditingController();
                            final result = await showDialog<String>(
                              context: ctx,
                              builder: (dialogCtx) => AlertDialog(
                                title: const Text('新建相册'),
                                content: TextField(
                                  controller: controller,
                                  autofocus: true,
                                  decoration: const InputDecoration(
                                    hintText: '输入相册文件夹名称',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(dialogCtx),
                                    child: const Text('取消'),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      final name = controller.text.trim();
                                      if (name.isNotEmpty) Navigator.pop(dialogCtx, name);
                                    },
                                    child: const Text('创建'),
                                  ),
                                ],
                              ),
                            );

                            if (result == null || result.isEmpty) return;

                            final newAlbumName = result;
                            final smbService = SmbService();
                            try {
                              setState(() => isCreating = true);
                              final server = servers.firstWhere((s) => s.id == selectedServer);
                              final serverRoot = server.rootPath;
                              final newPath = serverRoot.isEmpty ? newAlbumName : '$serverRoot/$newAlbumName';
                              await smbService.createDirectory(server, newPath);

                              ref.invalidate(smbAlbumsProvider(selectedServer!));
                              await Future.delayed(const Duration(milliseconds: 800));

                              final newAlbums = await smbService.getAlbums(server);
                              final newAlbum = newAlbums.firstWhere(
                                (a) => a.name.toLowerCase() == newAlbumName.toLowerCase(),
                                orElse: () => Album(
                                  id: newAlbumName,
                                  name: newAlbumName,
                                  source: SmbSource(server.id),
                                  coverPath: null,
                                  count: 0,
                                  parentPath: serverRoot,
                                ),
                              );

                              if (!ctx.mounted) return;
                              setState(() {
                                selectedAlbumId.clear();
                                selectedAlbumId.add(newAlbum.id);
                                remoteDir = newAlbum.id;
                                isCreating = false;
                              });

                              if (mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                    content: Text('相册创建成功'),
                                    backgroundColor: Colors.green,
                                  ),
                                );
                              }
                            } catch (e) {
                              if (!ctx.mounted) return;
                              setState(() => isCreating = false);
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(
                                    content: Text('创建失败: ${e.toString()}'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }
                          },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Checkbox(
                        value: selectedAlbumId.isEmpty,
                        onChanged: (v) {
                          setState(() {
                            if (v == true) selectedAlbumId.clear();
                          });
                        },
                      ),
                      Expanded(
                        child: Text('或手动输入目录（不选择相册时使用）',
                            style: TextStyle(color: palette.textSecondary)),
                      ),
                    ],
                  ),
                  TextField(
                    controller: TextEditingController(text: remoteDir),
                    onChanged: (v) {
                      remoteDir = v;
                      if (v.isNotEmpty) {
                        setState(() => selectedAlbumId.clear());
                      }
                    },
                    style: TextStyle(color: palette.textPrimary),
                    decoration: InputDecoration(
                      hintText: '/MiPixBackup 或选择的相册路径',
                      hintStyle: TextStyle(color: palette.textSecondary),
                      filled: true,
                      fillColor: palette.fill,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('共 ${paths.length} 张照片',
                      style: TextStyle(color: palette.textSecondary)),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () async {
                        final result = await ref.read(transfersProvider.notifier).backupPhotos(
                              selectedServer!,
                              paths,
                              remoteDir,
                            );
                        ref.read(defaultServerProvider.notifier).state =
                            selectedServer;
                        ref.read(defaultBackupPathProvider.notifier).state =
                            remoteDir;
                        if (!context.mounted) return;
                        Navigator.pop(context);
                        toggleMultiSelect(ref);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              result.allSucceeded
                                  ? '已加入备份队列 ${result.successCount} 项'
                                  : result.allFailed
                                      ? '备份失败，请检查 SMB 配置或后端连接'
                                      : '部分备份已加入队列：成功 ${result.successCount}，失败 ${result.failedCount}',
                            ),
                          ),
                        );
                      },
                      child: const Text('开始备份'),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            );
          },
        );
      },
    );
  }

}

class _PhotoTile extends StatelessWidget {
  final MediaItem photo;
  final bool isMultiSelect;
  final bool isSelected;
  final bool isSynced;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PhotoTile({
    required this.photo,
    required this.isMultiSelect,
    required this.isSelected,
    this.isSynced = false,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary 隔离每个网格单元：单张图片解码完成时只重绘自己，
    // 不会触发整个网格重绘（滚动时不掉帧）。
    // 同时不再对每个单元做 Opacity 淡入：Opacity 会为每个单元创建
    // saveLayer 离屏图层，滚动时数十个图层同时动画是主要卡顿来源。
    final palette = MiPixPalette.of(context);
    return RepaintBoundary(
      child: BounceTap(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: [
            LocalMediaThumb(item: photo),
            // 同步状态角标：已备份到 SMB 为蓝色云勾，未同步为白色云叉。
            Positioned(
              right: 3,
              bottom: 3,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  isSynced ? Icons.cloud_done : Icons.cloud_off,
                  size: 13,
                  color: isSynced ? palette.accent : Colors.white,
                ),
              ),
            ),
            if (isMultiSelect)
              Container(
                color: isSelected
                    ? Colors.black.withValues(alpha: 0.45)
                    : Colors.transparent,
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      isSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: isSelected
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.6),
                      size: 24,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MultiSelectBottomBar extends StatelessWidget {
  final int selectedCount;
  final VoidCallback onBackup;
  final VoidCallback onClear;

  const _MultiSelectBottomBar({
    required this.selectedCount,
    required this.onBackup,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.background,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: onBackup,
                  icon: const Icon(Icons.cloud_upload, size: 20),
                  label: Text('备份 ($selectedCount)'),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                onPressed: onClear,
                icon: Icon(Icons.clear_all, color: palette.textSecondary),
                tooltip: '清除选择',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
