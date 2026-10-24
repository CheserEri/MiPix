import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import '../models/models.dart';
import '../providers/album_provider.dart';
import '../providers/photo_provider.dart';
import '../providers/smb_provider.dart';
import '../providers/transfer_provider.dart';
import '../services/smb_service.dart';
import '../services/video_thumbnail_service.dart';
import '../services/photo_service.dart';
import '../services/local_storage_service.dart';
import '../utils/mipix_theme.dart';
import '../widgets/animations.dart';
import '../widgets/glass_container.dart';
import '../widgets/local_media_thumb.dart';
import 'photo_viewer_screen.dart';

/// 相册内页：进入某个相册后的照片网格。
///
/// 布局对齐小米相册：4 列密排（3px 间距）、左对齐日期分组头、居中标题；
/// 支持多选（瓦片右下角圆形勾选圈 + 分组头「全选」胶囊）。
class PhotoGridScreen extends ConsumerStatefulWidget {
  final String albumId;
  final String albumName;
  final bool isLocal;
  final bool isSettingCover;
  final String? albumPath;

  const PhotoGridScreen({
    super.key,
    required this.albumId,
    required this.albumName,
    required this.isLocal,
    this.isSettingCover = false,
    this.albumPath,
  });

  @override
  ConsumerState<PhotoGridScreen> createState() => _PhotoGridScreenState();
}

class _PhotoGridScreenState extends ConsumerState<PhotoGridScreen> {
  /// 设为封面场景下的单选（按文件名）。
  String? _selectedPhotoName;

  /// 普通浏览场景下的多选状态：选中的 [MediaItem.id] 集合。
  bool _multiSelect = false;
  final Set<String> _selected = {};

  /// 本次动态刷新相对上次新增的照片 id：只让这些瓦片播放入场动画。
  Set<String> _newIds = {};

  /// 本地相册正在追加下一页（用于显示底部加载指示）。
  bool _loadingMoreLocal = false;

  final ScrollController _scrollController = ScrollController();

  /// 4 列密排，与小米相册一致。
  static const SliverGridDelegateWithFixedCrossAxisCount _gridDelegate =
      SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 4,
    crossAxisSpacing: 3,
    mainAxisSpacing: 3,
  );

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    if (widget.isLocal) {
      // 本地相册改为分页数据源，进入时主动加载首屏。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(albumItemsProvider(widget.albumId).notifier).load();
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 500) {
      _loadMore();
    }
  }

  void _loadMore() {
    if (widget.isLocal) {
      _loadMoreLocal();
      return;
    }
    final path = ref.read(smbCurrentPathProvider);
    ref
        .read(smbItemsPagedProvider((serverId: widget.albumId, path: path))
            .notifier)
        .loadMore();
  }

  /// 本地相册分页：滚动到底追加下一页，直到与相册总数对齐。
  Future<void> _loadMoreLocal() async {
    final notifier = ref.read(albumItemsProvider(widget.albumId).notifier);
    if (_loadingMoreLocal || !notifier.hasMore) return;
    setState(() => _loadingMoreLocal = true);
    await notifier.loadMore();
    if (mounted) setState(() => _loadingMoreLocal = false);
  }

  /// 刷新当前相册内容（返回查看器删除照片后也会调用）。
  void _refresh() {
    if (widget.isLocal) {
      ref.read(albumItemsProvider(widget.albumId).notifier).load();
    } else {
      final path = ref.read(smbCurrentPathProvider);
      ref
          .read(smbItemsPagedProvider((serverId: widget.albumId, path: path))
              .notifier)
          .load();
    }
  }

  List<MediaItem> _localItems() =>
      ref.read(albumItemsProvider(widget.albumId)).valueOrNull ??
      const <MediaItem>[];

  List<MediaItem> _remoteItems() {
    final path = ref.read(smbCurrentPathProvider);
    return ref
            .read(smbItemsPagedProvider((serverId: widget.albumId, path: path)))
            .valueOrNull
            ?.items ??
        const <MediaItem>[];
  }

  List<MediaItem> _allItems() => widget.isLocal ? _localItems() : _remoteItems();

  void _exitMultiSelect() {
    setState(() {
      _multiSelect = false;
      _selected.clear();
    });
  }

  void _selectAll() {
    final items = _allItems();
    setState(() {
      if (items.isNotEmpty && _selected.length == items.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(items.map((e) => e.id));
      }
    });
  }

  void _toggleGroupSelection(List<MediaItem> group) {
    final ids = group.map((e) => e.id).toSet();
    final allSelected = ids.every(_selected.contains);
    setState(() {
      if (allSelected) {
        _selected.removeAll(ids);
      } else {
        _selected.addAll(ids);
      }
    });
  }

  void _enterMultiSelect(String id) {
    setState(() {
      _multiSelect = true;
      _selected.add(id);
    });
    HapticFeedback.mediumImpact();
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
    HapticFeedback.lightImpact();
  }

  void _openViewer(List<MediaItem> items, MediaItem item,
      {required bool isRemote}) {
    final index = items.indexWhere((e) => e.id == item.id);
    Navigator.push(
      context,
      PageFadeTransition(
        child: PhotoViewerScreen(
          photos: items,
          initialIndex: index < 0 ? 0 : index,
          isRemote: isRemote,
          serverId: isRemote ? widget.albumId : null,
        ),
      ),
    ).then((deleted) {
      // 只有查看器里确实删除了照片才需要重载列表；否则重载会把分页
      // 退回到第一页，返回时滚动位置也跟着丢失（老照片页跳回近期页）。
      if (mounted && deleted == true) _refresh();
    });
  }

  void _notSupported(String name) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$name 暂不支持')));
  }

  // ---------------------------------------------------------------------------
  // 顶栏
  // ---------------------------------------------------------------------------

  PreferredSizeWidget _buildAppBar(MiPixPalette palette, bool multi) {
    if (multi) {
      return AppBar(
        backgroundColor: palette.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.close, color: palette.textPrimary),
          onPressed: _exitMultiSelect,
        ),
        title: Text(
          '已选择 ${_selected.length} 项',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: palette.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.select_all, color: palette.textPrimary),
            onPressed: _selectAll,
            tooltip: '全选',
          ),
        ],
      );
    }
    return AppBar(
      backgroundColor: palette.background,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      title: Text(
        widget.albumName,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: palette.textPrimary,
        ),
      ),
      iconTheme: IconThemeData(color: palette.textPrimary),
      actions: widget.isSettingCover
          ? null
          : [
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: palette.textPrimary),
                onSelected: (v) {
                  if (v == 'select') {
                    setState(() => _multiSelect = true);
                  } else {
                    _refresh();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'select', child: Text('选择')),
                  PopupMenuItem(value: 'refresh', child: Text('刷新')),
                ],
              ),
            ],
    );
  }

  // ---------------------------------------------------------------------------
  // 页面构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (widget.isLocal) {
      // 系统媒体库变化（如本相册内新增截图）时自动刷新，无需手动刷新。
      ref.listen(mediaChangeTickProvider, (_, __) {
        ref.read(albumItemsProvider(widget.albumId).notifier).load();
      });
      // 记录本次刷新增的照片 id，只让新瓦片播放入场动画。
      ref.listen<AsyncValue<List<MediaItem>>>(
        albumItemsProvider(widget.albumId),
        (prev, next) {
          final prevItems = prev?.valueOrNull;
          final nextItems = next.valueOrNull;
          if (prevItems == null || nextItems == null) return;
          // 尾部追加（加载更早的内容）不是新增照片，不播放入场动画。
          if (prevItems.isNotEmpty &&
              nextItems.isNotEmpty &&
              prevItems.first.id == nextItems.first.id) {
            return;
          }
          final prevIds = prevItems.map((e) => e.id).toSet();
          final added = nextItems
              .where((e) => !prevIds.contains(e.id))
              .map((e) => e.id)
              .toSet();
          if (added.isEmpty) return;
          setState(() => _newIds = added);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _newIds.isNotEmpty) {
              setState(() => _newIds = {});
            }
          });
        },
      );
      return _buildLocalGrid();
    } else {
      return _buildRemoteGrid();
    }
  }

  /// 依据瓦片的 [ValueKey]（照片 id）找到它在分组内的新下标，
  /// 使 Sliver 在列表头部插入新照片时搬移已有瓦片而非重建它们。
  int? _indexByKey(List<MediaItem> items, Key key) {
    if (key is! ValueKey<String>) return null;
    final i = items.indexWhere((p) => p.id == key.value);
    return i < 0 ? null : i;
  }

  Widget _buildLocalGrid() {
    final palette = MiPixPalette.of(context);
    final itemsAsync = ref.watch(albumItemsProvider(widget.albumId));
    final uploading = ref.watch(uploadingPathsProvider);
    final coverMode = widget.isSettingCover;
    final multi = _multiSelect && !coverMode;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: MiPixTheme.overlayStyle(context),
      child: Scaffold(
        backgroundColor: palette.background,
        appBar: _buildAppBar(palette, multi),
        body: itemsAsync.when(
          loading: () => Center(
            child: CircularProgressIndicator(color: palette.accent),
          ),
          error: (err, _) => Center(
            child: Text('加载失败: $err',
                style: TextStyle(color: palette.textSecondary)),
          ),
          data: (items) {
            if (items.isEmpty) {
              return const EmptyStateWidget(
                icon: Icons.photo_library_outlined,
                title: '暂无照片',
                subtitle: '该相册里还没有可显示的内容',
              );
            }
            // 首屏不足一屏时自动补下一页，否则没有滚动事件可触发加载更多。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || !_scrollController.hasClients) return;
              final notifier =
                  ref.read(albumItemsProvider(widget.albumId).notifier);
              if (notifier.hasMore &&
                  _scrollController.position.maxScrollExtent <= 0) {
                _loadMoreLocal();
              }
            });
            final grouped = _groupByDate(items);
            return CustomScrollView(
              controller: _scrollController,
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 4)),
                for (final entry in grouped.entries) ...[
                  SliverToBoxAdapter(
                    child: _GroupHeader(
                      text: _formatDateHeader(entry.key),
                      multiSelect: multi,
                      allSelected: entry.value
                          .every((it) => _selected.contains(it.id)),
                      onToggleAll: () => _toggleGroupSelection(entry.value),
                    ),
                  ),
                  SliverGrid(
                    gridDelegate: _gridDelegate,
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final item = entry.value[index];
                        final selected = coverMode
                            ? _selectedPhotoName == item.name
                            : _selected.contains(item.id);
                        return AppearIn(
                          key: ValueKey(item.id),
                          animate: _newIds.contains(item.id),
                          child: _buildTile(
                            isRemote: false,
                            item: item,
                            selected: selected,
                            multiSelect: multi,
                            coverBorder: coverMode,
                            badge: (!multi && uploading.contains(item.path))
                                ? _uploadBadge()
                                : null,
                            onTap: () {
                              if (coverMode) {
                                setState(() {
                                  _selectedPhotoName =
                                      selected ? null : item.name;
                                });
                                return;
                              }
                              if (multi) {
                                _toggleSelect(item.id);
                                return;
                              }
                              _openViewer(items, item, isRemote: false);
                            },
                            onLongPress: coverMode
                                ? null
                                : () {
                                    if (!_multiSelect) {
                                      _enterMultiSelect(item.id);
                                    }
                                  },
                          ),
                        );
                      },
                      findChildIndexCallback: (key) =>
                          _indexByKey(entry.value, key),
                      childCount: entry.value.length,
                    ),
                  ),
                ],
                if (_loadingMoreLocal)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: palette.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
                const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
              ],
            );
          },
        ),
        bottomSheet: multi && _selected.isNotEmpty
            ? _SelectionActionBar(
                actions: [
                  _SelectionAction(Icons.ios_share, '发送', _shareSelected),
                  _SelectionAction(
                      Icons.auto_awesome, '创作', () => _notSupported('创作')),
                  _SelectionAction(Icons.add_box_outlined, '添加到',
                      () => _notSupported('添加到')),
                  _SelectionAction(Icons.delete_outline, '删除', _deleteSelected),
                ],
              )
            : null,
        floatingActionButton: coverMode && _selectedPhotoName != null
            ? _buildCoverFab(palette)
            : null,
      ),
    );
  }

  Widget _buildRemoteGrid() {
    final palette = MiPixPalette.of(context);
    final path = ref.watch(smbCurrentPathProvider);
    final pagedAsync =
        ref.watch(smbItemsPagedProvider((serverId: widget.albumId, path: path)));
    final multi = _multiSelect;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: MiPixTheme.overlayStyle(context),
      child: Scaffold(
        backgroundColor: palette.background,
        appBar: _buildAppBar(palette, multi),
        body: pagedAsync.when(
          loading: () {
            final progress = ref.watch(
              smbScanProgressProvider((serverId: widget.albumId, path: path)),
            );
            return _buildScanProgress(palette, progress);
          },
          error: (err, _) => Center(
            child: Text('加载失败: $err',
                style: TextStyle(color: palette.textSecondary)),
          ),
          data: (page) {
            final items = page.items;
            if (items.isEmpty) {
              return const EmptyStateWidget(
                icon: Icons.photo_library_outlined,
                title: '暂无照片',
                subtitle: '该相册里还没有可显示的内容',
              );
            }
            final grouped = _groupByDate(items);
            return NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollEndNotification) {
                  if (notification.metrics.pixels >=
                      notification.metrics.maxScrollExtent - 500) {
                    _loadMore();
                  }
                }
                return false;
              },
              child: CustomScrollView(
                controller: _scrollController,
                slivers: [
                  const SliverToBoxAdapter(child: SizedBox(height: 4)),
                  for (final entry in grouped.entries) ...[
                    SliverToBoxAdapter(
                      child: _GroupHeader(
                        text: _formatDateHeader(entry.key),
                        multiSelect: multi,
                        allSelected: entry.value
                            .every((it) => _selected.contains(it.id)),
                        onToggleAll: () => _toggleGroupSelection(entry.value),
                      ),
                    ),
                    SliverGrid(
                      gridDelegate: _gridDelegate,
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final item = entry.value[index];
                          final selected = _selected.contains(item.id);
                          return _buildTile(
                            isRemote: true,
                            item: item,
                            selected: selected,
                            multiSelect: multi,
                            onTap: () {
                              if (multi) {
                                _toggleSelect(item.id);
                                return;
                              }
                              _openViewer(items, item, isRemote: true);
                            },
                            onLongPress: () {
                              if (!_multiSelect) _enterMultiSelect(item.id);
                            },
                          );
                        },
                        childCount: entry.value.length,
                      ),
                    ),
                  ],
                  if (page.hasMore)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(
                          child: CircularProgressIndicator(
                            color: palette.accent,
                            strokeWidth: 2,
                          ),
                        ),
                      ),
                    ),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
                ],
              ),
            );
          },
        ),
        bottomSheet: multi && _selected.isNotEmpty
            ? _SelectionActionBar(
                actions: [
                  _SelectionAction(Icons.download_outlined, '下载', _downloadSelected),
                ],
              )
            : null,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 选中态操作
  // ---------------------------------------------------------------------------

  Future<void> _shareSelected() async {
    final selected =
        _localItems().where((it) => _selected.contains(it.id)).toList();
    if (selected.isEmpty) return;
    try {
      await Share.shareXFiles(selected.map((e) => XFile(e.path)).toList());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败: $e')));
      }
    }
  }

  Future<void> _deleteSelected() async {
    final messenger = ScaffoldMessenger.of(context);
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    try {
      final deleted = await PhotoManager.editor.deleteWithIds(ids);
      if (deleted.isEmpty) return;
      if (mounted) {
        setState(() {
          _multiSelect = false;
          _selected.clear();
        });
      }
      _refresh();
      messenger.showSnackBar(SnackBar(content: Text('已删除 ${deleted.length} 项')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('删除失败: $e')));
    }
  }

  Future<void> _downloadSelected() async {
    final messenger = ScaffoldMessenger.of(context);
    final selected =
        _remoteItems().where((it) => _selected.contains(it.id)).toList();
    if (selected.isEmpty) return;
    messenger.showSnackBar(
        SnackBar(content: Text('开始下载 ${selected.length} 项…')));
    var ok = 0;
    var fail = 0;
    try {
      final servers = await LocalStorageService().getSmbServers();
      final server = servers.firstWhere((s) => s.id == widget.albumId);
      for (final item in selected) {
        try {
          final data = await SmbService().readFile(server, item.path);
          if (data.isEmpty) throw Exception('文件内容为空');
          await PhotoService.saveBytesToGallery(
            data,
            filename: item.name,
            relativePath: 'Pictures/MiPix',
          );
          ok++;
        } catch (_) {
          fail++;
        }
      }
    } catch (_) {
      fail = selected.length;
    }
    if (mounted) {
      setState(() {
        _multiSelect = false;
        _selected.clear();
      });
    }
    messenger.showSnackBar(SnackBar(
      content: Text(
          fail == 0 ? '已下载 $ok 项到系统相册' : '下载完成：成功 $ok，失败 $fail'),
    ));
  }

  // ---------------------------------------------------------------------------
  // 网格单元与公共部件
  // ---------------------------------------------------------------------------

  Widget _buildTile({
    required bool isRemote,
    required MediaItem item,
    required bool selected,
    required bool multiSelect,
    Widget? badge,
    bool coverBorder = false,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    final palette = MiPixPalette.of(context);
    return BounceTap(
      onTap: onTap,
      onLongPress: onLongPress,
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (isRemote)
              _RemoteImage(serverId: widget.albumId, item: item)
            else
              LocalMediaThumb(item: item),
            // 设封面场景：选中瓦片加蓝色描边。
            if (coverBorder && selected)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: palette.accent, width: 3),
                    ),
                  ),
                ),
              ),
            if (badge != null) Positioned(right: 3, bottom: 3, child: badge),
            if (multiSelect) _selectionOverlay(selected, palette),
          ],
        ),
      ),
    );
  }

  Widget _selectionOverlay(bool selected, MiPixPalette palette) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            if (selected)
              Positioned.fill(
                child: Container(color: Colors.black.withValues(alpha: 0.32)),
              ),
            Positioned(
              right: 5,
              bottom: 5,
              child: selected
                  ? Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: palette.accent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check,
                          size: 15, color: Colors.white),
                    )
                  : Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.9),
                          width: 1.6,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _uploadBadge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Text(
          '上传中',
          style: TextStyle(fontSize: 10, height: 1.1, color: Colors.white),
        ),
      );

  Widget _buildCoverFab(MiPixPalette palette) {
    return FloatingActionButton.extended(
      onPressed: () async {
        if (widget.albumPath == null) return;
        try {
          final smbService = SmbService();
          final coverPath = widget.albumPath!.isEmpty
              ? _selectedPhotoName!
              : '${widget.albumPath}/$_selectedPhotoName!';
          await smbService.setCustomCover(
            widget.albumId,
            widget.albumPath!,
            coverPath,
          );
          if (mounted) {
            Navigator.pop(context, coverPath);
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('设置失败: $e'), backgroundColor: Colors.red),
            );
          }
        }
      },
      icon: const Icon(Icons.check),
      label: const Text('设为封面'),
      backgroundColor: palette.accent,
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
    return Map.fromEntries(
      map.entries.toList()..sort((a, b) => b.key.compareTo(a.key)),
    );
  }

  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    if (date == today) return '今天';
    if (date == yesterday) return '昨天';
    // 今年只显示「M月d日」；去年及更早必须带年份，否则 2025 年的照片
    // 会被误认为今年拍的（如只显示「8月23日」）。
    if (date.year != now.year) {
      return DateFormat('yyyy年M月d日').format(date);
    }
    return DateFormat('M月d日').format(date);
  }

  /// 远程相册首次进入需全量探测 EXIF 拍摄时间（大相册耗时较久），
  /// 用带百分比的进度条替代单纯转圈，让用户明确知道还要等多久。
  Widget _buildScanProgress(MiPixPalette palette, SmbScanProgress progress) {
    final hasTotal = progress.total > 0;
    final percent = (progress.fraction * 100).round();
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              hasTotal ? '正在读取拍摄时间' : '正在加载',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: palette.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: hasTotal ? progress.fraction : null,
                minHeight: 6,
                backgroundColor: palette.fill,
                valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              hasTotal ? '$percent%  ·  ${progress.done}/${progress.total}' : '',
              style: TextStyle(fontSize: 13, color: palette.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// 日期分组头：左对齐日期文本，多选时右侧带「全选」胶囊（对齐小米相册）。
class _GroupHeader extends StatelessWidget {
  final String text;
  final bool multiSelect;
  final bool allSelected;
  final VoidCallback? onToggleAll;

  const _GroupHeader({
    required this.text,
    required this.multiSelect,
    this.allSelected = false,
    this.onToggleAll,
  });

  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 8),
      child: Row(
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
              height: 1.2,
            ),
          ),
          const Spacer(),
          if (multiSelect)
            GestureDetector(
              onTap: onToggleAll,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: palette.fill,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  allSelected ? '取消' : '全选',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: palette.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单个选中操作。
class _SelectionAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SelectionAction(this.icon, this.label, this.onTap);
}

/// 多选底部操作栏：图标在上、文字在下（对齐小米相册）。
class _SelectionActionBar extends StatelessWidget {
  final List<_SelectionAction> actions;

  const _SelectionActionBar({required this.actions});

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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final action in actions)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: action.onTap,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(action.icon, size: 24, color: palette.textPrimary),
                        const SizedBox(height: 6),
                        Text(
                          action.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: palette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteImage extends StatefulWidget {
  final String serverId;
  final MediaItem item;

  const _RemoteImage({
    required this.serverId,
    required this.item,
  });

  @override
  State<_RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<_RemoteImage> {
  Uint8List? _imageData;
  bool _loading = true;
  static final _loadingController = _ImageLoadingController();

  /// 当前瓦片的请求令牌：瓦片销毁时置位，队列会跳过它。
  _ImageRequestToken? _requestToken;

  /// 队列满时请求可能被丢弃，这里在瓦片仍挂载时自动重试，避免留下裂图。
  Timer? _retryTimer;
  int _retryAttempt = 0;

  bool get _isVideo => widget.item.isVideo;

  @override
  void dispose() {
    _requestToken?.cancelled = true;
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (_isVideo) {
      _initVideoThumb();
      return;
    }
    // 内存缓存命中时同步展示，避免列表滚动/重建时重复加载。
    final cached = SmbService.peekThumbnail(widget.serverId, widget.item.path);
    if (cached != null && cached.isNotEmpty) {
      _imageData = cached;
      _loading = false;
    } else {
      _load();
    }
  }

  /// 视频瓦片：优先用视频缩略图服务的缓存，否则在后台抽帧。
  void _initVideoThumb() {
    final service = VideoThumbnailService.instance;
    final peeked = service.peek(serverId: widget.serverId, item: widget.item);
    if (peeked != null) {
      _imageData = peeked;
      _loading = false;
    } else if (service.knows(serverId: widget.serverId, item: widget.item)) {
      // 之前抽帧失败过：直接显示固定占位，避免滚动时反复重试。
      _loading = false;
    } else {
      _loadVideoThumb();
    }
  }

  Future<void> _loadVideoThumb() async {
    try {
      final servers = await LocalStorageService().getSmbServers();
      final server =
          servers.firstWhere((s) => s.id == widget.serverId);
      final data = await VideoThumbnailService.instance
          .load(server: server, item: widget.item);
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

  Future<void> _load() async {
    final token = _ImageRequestToken();
    _requestToken = token;
    try {
      final servers = await LocalStorageService().getSmbServers();
      final server = servers.firstWhere((s) => s.id == widget.serverId);
      final data = await _loadingController.loadImage(
        server,
        widget.item.path,
        token,
      );
      if (!mounted || token.cancelled) return;
      if (data.isEmpty && _retryAttempt < 2) {
        // 请求可能在队列已满时被丢弃；瓦片仍挂载就再试一次，而不是显示裂图。
        _retryAttempt++;
        _retryTimer?.cancel();
        _retryTimer = Timer(const Duration(milliseconds: 1200), () {
          if (mounted && !token.cancelled) _load();
        });
        return;
      }
      setState(() {
        _imageData = data;
        _loading = false;
      });
    } catch (_) {
      if (mounted && !token.cancelled) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    if (_isVideo) {
      if (_loading) {
        return Container(
          color: palette.fill,
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                color: palette.textSecondary.withValues(alpha: 0.5),
                strokeWidth: 1.6,
              ),
            ),
          ),
        );
      }
      final thumb = _imageData;
      if (thumb == null) {
        return Container(
          color: palette.fill,
          alignment: Alignment.center,
          child: Icon(
            Icons.play_circle_outline,
            size: 36,
            color: palette.textSecondary.withValues(alpha: 0.7),
          ),
        );
      }
      // 与本地视频瓦片一致：封面 + 居中播放角标。
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(
            thumb,
            fit: BoxFit.cover,
            cacheWidth: 256,
            errorBuilder: (_, __, ___) => Container(
              color: palette.fill,
              child: Icon(Icons.videocam,
                  color: palette.textSecondary.withValues(alpha: 0.6)),
            ),
          ),
          const Center(
            child: Icon(Icons.play_circle_fill,
                color: Colors.white70, size: 36),
          ),
        ],
      );
    }
    if (_loading) {
      return Container(
        color: palette.fill,
        child: Center(
          child: CircularProgressIndicator(color: palette.accent, strokeWidth: 2),
        ),
      );
    }
    if (_imageData == null) {
      return Container(
        color: palette.fill,
        child: Icon(Icons.broken_image,
            color: palette.textSecondary.withValues(alpha: 0.6)),
      );
    }
    return Image.memory(
      _imageData!,
      fit: BoxFit.cover,
      cacheWidth: 256,
      errorBuilder: (_, __, ___) => Container(
        color: palette.fill,
        child: Icon(Icons.broken_image,
            color: palette.textSecondary.withValues(alpha: 0.6)),
      ),
    );
  }
}

class _ImageRequestToken {
  /// 瓦片销毁后置位，队列出队时直接跳过，不再发起 SMB 读取。
  bool cancelled = false;
}

class _ImageLoadingController {
  // SMB requests are expensive and scrolling quickly can otherwise queue work
  // for thousands of tiles that are no longer on screen.
  static const int maxConcurrent = 3;

  /// 队列上限按「约 10 行可见 + 预加载」估算，太小会误伤当前可见的瓦片。
  static const int maxPendingRequests = 48;
  int _activeRequests = 0;
  final Queue<_PendingImageRequest> _queue = Queue<_PendingImageRequest>();

  Future<Uint8List> loadImage(
    SmbConfig server,
    String remotePath,
    _ImageRequestToken token,
  ) async {
    _dropCancelled();
    if (token.cancelled) return Uint8List(0);

    if (_activeRequests < maxConcurrent) {
      _activeRequests++;
      try {
        return await _doLoadImage(server, remotePath);
      } finally {
        _activeRequests--;
        _processQueue();
      }
    } else {
      // Keep the queue bounded. Complete the oldest request with an empty
      // result so its widget can settle; the tile schedules a short retry
      // while it is still mounted.
      if (_queue.length >= maxPendingRequests) {
        final stale = _queue.removeAt(0);
        if (!stale.completer.isCompleted) {
          stale.completer.complete(Uint8List(0));
        }
      }
      final completer = Completer<Uint8List>();
      _queue.add(_PendingImageRequest(server, remotePath, completer, token));
      return completer.future;
    }
  }

  /// 丢弃已销毁瓦片的排队请求；对应的 future 以空结果结束，调用方不再使用。
  void _dropCancelled() {
    _queue.removeWhere((request) {
      if (!request.token.cancelled) return false;
      if (!request.completer.isCompleted) {
        request.completer.complete(Uint8List(0));
      }
      return true;
    });
  }

  Future<Uint8List> _doLoadImage(SmbConfig server, String remotePath) async {
    final smbService = SmbService();
    try {
      // 网格只需缩略图，避免下载整张原图。
      return await smbService.readThumbnail(server, remotePath);
    } catch (e) {
      debugPrint('[smb] thumbLoad FAIL path=$remotePath ${e.runtimeType} $e');
      return Uint8List(0);
    }
  }

  void _processQueue() {
    while (_activeRequests < maxConcurrent && _queue.isNotEmpty) {
      final request = _queue.removeAt(0);
      if (request.token.cancelled) {
        if (!request.completer.isCompleted) {
          request.completer.complete(Uint8List(0));
        }
        continue;
      }
      _activeRequests++;
      _doLoadImage(request.server, request.remotePath).then((data) {
        request.completer.complete(data);
      }).catchError((e) {
        request.completer.completeError(e);
      }).whenComplete(() {
        _activeRequests--;
        _processQueue();
      });
    }
  }
}

class _PendingImageRequest {
  final SmbConfig server;
  final String remotePath;
  final Completer<Uint8List> completer;
  final _ImageRequestToken token;

  _PendingImageRequest(this.server, this.remotePath, this.completer, this.token);
}

class Queue<E> {
  final List<E> _list = [];
  void add(E e) => _list.add(e);
  E removeAt(int index) => _list.removeAt(index);
  void removeWhere(bool Function(E) test) => _list.removeWhere(test);
  bool get isEmpty => _list.isEmpty;
  bool get isNotEmpty => _list.isNotEmpty;
  int get length => _list.length;
}
