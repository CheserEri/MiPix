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
    final uploading = ref.watch(uploadingPathsProvider);

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
                          isUploading: uploading.contains(photo.path),
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
    var isBackingUp = false;

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
                          setState(() => selectedServer = s.id);
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  Text('将按照片在手机上的相册目录结构备份到服务器',
                      style: TextStyle(
                          fontSize: 13, color: palette.textSecondary)),
                  const SizedBox(height: 16),
                  Text('共 ${paths.length} 张照片',
                      style: TextStyle(color: palette.textSecondary)),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: isBackingUp
                          ? null
                          : () async {
                              setState(() => isBackingUp = true);
                              final result = await ref.read(transfersProvider.notifier).backupPhotos(
                                    selectedServer!,
                                    paths,
                                  );
                              ref.read(defaultServerProvider.notifier).state =
                                  selectedServer;
                              if (!context.mounted) return;
                              Navigator.pop(context);
                              toggleMultiSelect(ref);
                              final String message;
                              if (result.successCount == 0 &&
                                  result.failedCount == 0) {
                                message = '所选照片均在上传中，已跳过';
                              } else if (result.allSucceeded) {
                                message = '已加入备份队列 ${result.successCount} 项';
                              } else if (result.allFailed) {
                                message = '备份失败，请检查 SMB 配置或后端连接';
                              } else {
                                message =
                                    '部分备份已加入队列：成功 ${result.successCount}，失败 ${result.failedCount}';
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(message)),
                              );
                            },
                      child: isBackingUp
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('开始备份'),
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
  final bool isUploading;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PhotoTile({
    required this.photo,
    required this.isMultiSelect,
    required this.isSelected,
    this.isSynced = false,
    this.isUploading = false,
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
            // 上传中优先显示「上传中」；否则显示同步角标（已备份蓝色云勾 / 未同步白色云叉）。
            Positioned(
              right: 3,
              bottom: 3,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: isUploading ? 4 : 2,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: isUploading
                    ? const Text(
                        '上传中',
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.1,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
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
