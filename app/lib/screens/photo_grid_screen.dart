import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../providers/album_provider.dart';
import '../providers/smb_provider.dart';
import '../providers/transfer_provider.dart';
import '../services/smb_service.dart';
import '../services/local_storage_service.dart';
import '../utils/mipix_theme.dart';
import '../widgets/animations.dart';
import '../widgets/glass_container.dart';
import '../widgets/local_media_thumb.dart';
import 'photo_viewer_screen.dart';

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
  String? _selectedPhotoName;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 500) {
      if (!widget.isLocal) {
        _loadMore();
      }
    }
  }

  void _loadMore() {
    if (!widget.isLocal) {
      final path = ref.read(smbCurrentPathProvider);
      ref.read(smbItemsPagedProvider((serverId: widget.albumId, path: path)).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLocal) {
      return _buildLocalGrid();
    } else {
      return _buildRemoteGrid();
    }
  }

  Widget _buildLocalGrid() {
    final palette = MiPixPalette.of(context);
    final itemsAsync = ref.watch(albumItemsProvider(widget.albumId));
    final uploading = ref.watch(uploadingPathsProvider);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: MiPixTheme.overlayStyle(context),
      child: Scaffold(
        backgroundColor: palette.background,
        appBar: AppBar(
          backgroundColor: palette.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(
            widget.albumName,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          iconTheme: IconThemeData(color: palette.textPrimary),
        ),
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
              return EmptyStateWidget(
                icon: Icons.photo_library_outlined,
                title: '暂无照片',
                subtitle: '该相册里还没有可显示的内容',
              );
            }
            return GridView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(2, 2, 2, 24),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 2,
                mainAxisSpacing: 2,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final isSelected = _selectedPhotoName == item.name;
                return BounceTap(
                  onTap: widget.isSettingCover
                      ? () {
                          setState(() {
                            if (isSelected) {
                              _selectedPhotoName = null;
                            } else {
                              _selectedPhotoName = item.name;
                            }
                          });
                        }
                      : () {
                          Navigator.push(
                            context,
                            PageFadeTransition(
                              child: PhotoViewerScreen(
                                photos: items,
                                initialIndex: index,
                                isRemote: false,
                              ),
                            ),
                          );
                        },
                  child: RepaintBoundary(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            border: isSelected
                                ? Border.all(color: palette.accent, width: 3)
                                : null,
                          ),
                          child: LocalMediaThumb(item: item),
                        ),
                        // 上传锁命中时显示「上传中」。
                        if (uploading.contains(item.path))
                          Positioned(
                            right: 3,
                            bottom: 3,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                '上传中',
                                style: TextStyle(
                                  fontSize: 10,
                                  height: 1.1,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
        floatingActionButton: widget.isSettingCover && _selectedPhotoName != null
            ? FloatingActionButton.extended(
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
              )
            : null,
      ),
    );
  }

  Widget _buildRemoteGrid() {
    final palette = MiPixPalette.of(context);
    final path = ref.watch(smbCurrentPathProvider);
    final pagedAsync = ref.watch(smbItemsPagedProvider((serverId: widget.albumId, path: path)));

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: MiPixTheme.overlayStyle(context),
      child: Scaffold(
        backgroundColor: palette.background,
        appBar: AppBar(
          backgroundColor: palette.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(
            widget.albumName,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          iconTheme: IconThemeData(color: palette.textPrimary),
        ),
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
              return EmptyStateWidget(
                icon: Icons.photo_library_outlined,
                title: '暂无照片',
                subtitle: '该相册里还没有可显示的内容',
              );
            }
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
              child: GridView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(2, 2, 2, 24),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 2,
                  mainAxisSpacing: 2,
                ),
                itemCount: items.length + (page.hasMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= items.length) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: CircularProgressIndicator(
                          color: palette.accent,
                          strokeWidth: 2,
                        ),
                      ),
                    );
                  }
                  final item = items[index];
                  final isSelected = _selectedPhotoName == item.name;
                  return BounceTap(
                    onTap: widget.isSettingCover
                        ? () {
                            setState(() {
                              if (isSelected) {
                                _selectedPhotoName = null;
                              } else {
                                _selectedPhotoName = item.name;
                              }
                            });
                          }
                        : () {
                            Navigator.push(
                              context,
                              PageFadeTransition(
                                child: PhotoViewerScreen(
                                  photos: items,
                                  initialIndex: index,
                                  isRemote: true,
                                  serverId: widget.albumId,
                                ),
                              ),
                            );
                          },
                    child: RepaintBoundary(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: isSelected
                              ? Border.all(
                                  color: palette.accent, width: 3)
                              : null,
                        ),
                        child: _RemoteImage(
                          serverId: widget.albumId,
                          remotePath: item.path,
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      floatingActionButton: widget.isSettingCover && _selectedPhotoName != null
          ? FloatingActionButton.extended(
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
            )
          : null,
      ),
    );
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

class _RemoteImage extends StatefulWidget {
  final String serverId;
  final String remotePath;

  const _RemoteImage({
    required this.serverId,
    required this.remotePath,
  });

  @override
  State<_RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<_RemoteImage> {
  Uint8List? _imageData;
  bool _loading = true;
  static final _loadingController = _ImageLoadingController();

  @override
  void initState() {
    super.initState();
    // 内存缓存命中时同步展示，避免列表滚动/重建时重复加载。
    final cached = SmbService.peekThumbnail(widget.serverId, widget.remotePath);
    if (cached != null && cached.isNotEmpty) {
      _imageData = cached;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final servers = await LocalStorageService().getSmbServers();
      final server = servers.firstWhere((s) => s.id == widget.serverId);
      final data = await _loadingController.loadImage(server, widget.remotePath);
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
    final palette = MiPixPalette.of(context);
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
      cacheWidth: 400,
      errorBuilder: (_, __, ___) => Container(
        color: palette.fill,
        child: Icon(Icons.broken_image,
            color: palette.textSecondary.withValues(alpha: 0.6)),
      ),
    );
  }
}

class _ImageLoadingController {
  static const int maxConcurrent = 8;
  int _activeRequests = 0;
  final Queue<_PendingImageRequest> _queue = Queue<_PendingImageRequest>();

  Future<Uint8List> loadImage(SmbConfig server, String remotePath) async {
    if (_activeRequests < maxConcurrent) {
      _activeRequests++;
      try {
        return await _doLoadImage(server, remotePath);
      } finally {
        _activeRequests--;
        _processQueue();
      }
    } else {
      final completer = Completer<Uint8List>();
      _queue.add(_PendingImageRequest(server, remotePath, completer));
      return completer.future;
    }
  }

  Future<Uint8List> _doLoadImage(SmbConfig server, String remotePath) async {
    final smbService = SmbService();
    try {
      // 网格只需缩略图，避免下载整张原图。
      return await smbService.readThumbnail(server, remotePath);
    } catch (_) {
      return Uint8List(0);
    }
  }

  void _processQueue() {
    while (_activeRequests < maxConcurrent && _queue.isNotEmpty) {
      final request = _queue.removeAt(0);
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

  _PendingImageRequest(this.server, this.remotePath, this.completer);
}

class Queue<E> {
  final List<E> _list = [];
  void add(E e) => _list.add(e);
  E removeAt(int index) => _list.removeAt(index);
  bool get isEmpty => _list.isEmpty;
  bool get isNotEmpty => _list.isNotEmpty;
}
