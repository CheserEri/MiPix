import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';
import '../providers/transfer_provider.dart';
import '../providers/smb_provider.dart';
import '../services/smb_service.dart';
import '../services/photo_service.dart';
import '../services/local_storage_service.dart';
import '../widgets/glass_container.dart';
import 'package:share_plus/share_plus.dart';
import 'package:exif/exif.dart' as exif_pkg;
import 'package:video_player/video_player.dart';

/// 查看页专用系统 UI 样式：状态栏/导航栏全透明且关闭强制对比度，
/// 避免 Android 在底部手势条区域叠加黑色蒙层或白色分隔线（即“小白条黑边”）。
const SystemUiOverlayStyle _viewerOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarContrastEnforced: false,
  systemStatusBarContrastEnforced: false,
);

class PhotoViewerScreen extends StatefulWidget {
  final List<MediaItem> photos;
  final int initialIndex;
  final bool isRemote;

  /// 远程照片所属的 SMB 服务器 id（本地照片为 null）。
  final String? serverId;

  const PhotoViewerScreen({
    super.key,
    required this.photos,
    required this.initialIndex,
    this.isRemote = false,
    this.serverId,
  });

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final PageController _pageController;
  late int _currentIndex;
  bool _showUI = false;

  /// 当前页是否处于放大状态。放大时禁用 PageView 翻页，
  /// 否则拖动图片会误触发左右翻页。
  bool _isZoomed = false;

  void _handlePageChanged(int index) {
    setState(() {
      _currentIndex = index;
      _isZoomed = false; // 翻页后回到 1x，恢复左右滑动
    });
  }

  void _handleZoomChanged(int index, bool zoomed) {
    if (!mounted || index != _currentIndex) return;
    if (zoomed != _isZoomed) {
      setState(() => _isZoomed = zoomed);
    }
  }

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _showUI = true);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _showUI = false);
      });
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_currentIndex];
    // 限制解码尺寸：原图（如 4032×2268）全分辨率解码会产生数十 MB 位图，
    // 翻页时多页并存会拖垮光栅线程。按屏幕宽度的 2 倍解码，
    // 既大幅降低内存/解码开销，又保留一定放大画质。
    final mq = MediaQuery.of(context);
    final maxDecodeWidth = (mq.size.width * mq.devicePixelRatio * 2).round();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _viewerOverlayStyle,
      child: Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showUI = !_showUI),
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              controller: _pageController,
              // 放大时禁用翻页，避免拖动图片时误翻页；
              // 未放大时交还 PageView，保证左右滑动顺畅切换上一张/下一张。
              physics: _isZoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              onPageChanged: _handlePageChanged,
              itemCount: widget.photos.length,
              itemBuilder: (context, index) {
                final item = widget.photos[index];
                if (!widget.isRemote && item.isVideo) {
                  return Center(child: _LocalVideoPlayer(path: item.path));
                }
                return RepaintBoundary(
                  child: _ZoomableImage(
                    key: ValueKey(index),
                    index: index,
                    isActive: index == _currentIndex,
                    onZoomChanged: _handleZoomChanged,
                    child: widget.isRemote
                        ? _RemotePhotoViewer(
                            serverId: widget.serverId ?? '',
                            remotePath: item.path,
                            name: item.name,
                            maxDecodeWidth: maxDecodeWidth)
                        : Image.file(
                            File(item.path),
                            fit: BoxFit.contain,
                            cacheWidth: maxDecodeWidth,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.black,
                              child: const Icon(Icons.broken_image,
                                  size: 64, color: Color(0x1FFFFFFF)),
                            ),
                          ),
                  ),
                );
              },
            ),
            // 该渐变层只是装饰，必须显式忽略指针：
            // Opacity 即便为 0 仍会把命中测试交给子节点，若子层可命中
            // 就会整体遮挡下方 PageView 的翻页与捏合手势。
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: _showUI ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.6),
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.7),
                      ],
                      stops: const [0.0, 0.2, 0.7, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            // UI 隐藏时完全不参与命中测试，避免遮挡 PageView 的翻页与缩放手势。
            IgnorePointer(
              ignoring: !_showUI,
              child: AnimatedOpacity(
              opacity: _showUI ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: SafeArea(
                child: Column(
                  children: [
                    // 顶部栏：使用轻量半透明容器替代 BackdropFilter 玻璃层。
                    // BackdropFilter 每帧都要 saveLayer + 高斯模糊整个背景，
                    // 翻页/缩放时会持续触发重模糊，是查看页主要掉帧来源。
                    Container(
                      margin: const EdgeInsets.all(12),
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_back,
                                  color: Colors.white),
                              onPressed: () => Navigator.pop(context),
                            ),
                            Expanded(
                              child: Text(
                                '${_currentIndex + 1} / ${widget.photos.length}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w500),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(width: 48),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    // 底部操作栏同样去掉玻璃模糊，改为半透明纯色。
                    Container(
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      // 外层 Column 已用 SafeArea 避开底部手势条，这里不再嵌套 SafeArea，
                      // 否则底部安全区会被叠加两次，在小白条上方形成一条多余的黑边。
                      child: _BottomActionBar(
                        photo: photo,
                        isRemote: widget.isRemote,
                        serverId: widget.serverId,
                      ),
                    ),
                  ],
                ),
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

/// 支持双指捏合缩放、双击放大/还原、放大后单指平移的图片容器。
///
/// 这里刻意不使用 [InteractiveViewer]：它内部会无条件注册
/// [ScaleGestureRecognizer]（即便把 panEnabled/scaleEnabled 关掉，识别器依然
/// 参与手势竞技场）。由于它处于命中路径最内层，会在竞技场中抢走点击与横向拖动，
/// 导致外层 PageView 无法翻页、点击也无法切换 UI。
///
/// 因此改用原始指针事件（[Listener]）自行实现缩放/平移：Listener 不参与手势
/// 竞技场，天然不会与 PageView 的水平拖动竞争，翻页与单击都能正常响应。
class _ZoomableImage extends StatefulWidget {
  final int index;
  final bool isActive;
  final Widget child;
  final void Function(int index, bool zoomed) onZoomChanged;

  const _ZoomableImage({
    super.key,
    required this.index,
    required this.isActive,
    required this.child,
    required this.onZoomChanged,
  });

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage>
    with SingleTickerProviderStateMixin {
  static const double _maxScale = 5.0;
  static const double _doubleTapScale = 2.5;
  static const double _zoomedThreshold = 1.01;

  /// 当前变换：屏幕坐标 = _offset + _scale × 内容坐标。
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  Size _viewport = Size.zero;

  /// 当前按下的指针（pointer id → 局部坐标）。
  final Map<int, Offset> _pointers = <int, Offset>{};

  // 一次捏合手势的起始快照。
  double _startScale = 1.0;
  double _startDistance = 1.0;
  Offset _startFocal = Offset.zero;
  Offset _startOffset = Offset.zero;

  /// 单指平移时的上一个位置。
  Offset? _lastPan;

  /// 双击锚点（局部坐标）。
  Offset _doubleTapPosition = Offset.zero;

  late final AnimationController _animation;
  double _animFromScale = 1.0, _animToScale = 1.0;
  Offset _animFromOffset = Offset.zero, _animToOffset = Offset.zero;

  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(_onAnimationTick);
  }

  @override
  void didUpdateWidget(covariant _ZoomableImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 翻页离开该页时复位，避免再次回到此页仍处于放大态而无法左右滑动。
    if (!widget.isActive && (_zoomed || _scale != 1.0)) {
      _animation.stop();
      _zoomed = false;
      _scale = 1.0;
      _offset = Offset.zero;
      _pointers.clear();
      _lastPan = null;
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  /// 将平移量限制在内容边界内，保证放大后不会拖出空白。
  Offset _clampOffset(Offset o, double scale) {
    final minX = _viewport.width * (1 - scale);
    final minY = _viewport.height * (1 - scale);
    return Offset(o.dx.clamp(minX, 0.0), o.dy.clamp(minY, 0.0));
  }

  /// 仅在跨越 1x 边界时通知外层，避免每帧都触发 PageView 重建。
  void _notifyZoom(bool zoomed) {
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged(widget.index, zoomed);
  }

  void _onAnimationTick() {
    final t = Curves.easeOutCubic.transform(_animation.value);
    setState(() {
      _scale = _animFromScale + (_animToScale - _animFromScale) * t;
      _offset = Offset.lerp(_animFromOffset, _animToOffset, t)!;
    });
    _notifyZoom(_scale > _zoomedThreshold);
  }

  void _animateTo(double scale, Offset offset) {
    _animFromScale = _scale;
    _animToScale = scale;
    _animFromOffset = _offset;
    _animToOffset = offset;
    _animation.forward(from: 0);
  }

  void _onPointerDown(PointerDownEvent e) {
    _animation.stop();
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length >= 2) {
      // 进入捏合：立即通知外层禁用翻页，避免手势被 PageView 抢走。
      _notifyZoom(true);
      final pts = _pointers.values.toList(growable: false);
      final d = (pts[0] - pts[1]).distance;
      _startDistance = d < 1.0 ? 1.0 : d;
      _startScale = _scale;
      _startFocal = (pts[0] + pts[1]) / 2;
      _startOffset = _offset;
      _lastPan = null;
    } else {
      _lastPan = e.localPosition;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    _pointers[e.pointer] = e.localPosition;

    if (_pointers.length >= 2) {
      final pts = _pointers.values.toList(growable: false);
      final focal = (pts[0] + pts[1]) / 2;
      final dist = (pts[0] - pts[1]).distance;
      final newScale =
          (_startScale * dist / _startDistance).clamp(1.0, _maxScale).toDouble();
      // 保持捏合起始中心下的内容不漂移：o1 = f1 - (s1/s0) × (f0 - o0)。
      final ratio = newScale / _startScale;
      final newOffset = focal - (_startFocal - _startOffset) * ratio;
      setState(() {
        _scale = newScale;
        _offset = _clampOffset(newOffset, newScale);
      });
      _notifyZoom(newScale > _zoomedThreshold);
    } else if (_pointers.length == 1 && _scale > 1.0) {
      // 放大后单指拖动即为平移图片。
      final last = _lastPan;
      if (last != null) {
        setState(() =>
            _offset = _clampOffset(_offset + (e.localPosition - last), _scale));
      }
      _lastPan = e.localPosition;
    }
  }

  void _onPointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length == 1) {
      // 从双指降到单指：以当前位置继续单指平移。
      _lastPan = _pointers.values.first;
    } else if (_pointers.isEmpty) {
      _lastPan = null;
      if (_scale <= 1.02) {
        // 基本回到 1x，吸附并恢复左右滑动。
        _animateTo(1.0, Offset.zero);
        _notifyZoom(false);
      } else {
        _notifyZoom(true);
      }
    }
  }

  void _handleDoubleTap() {
    if (_scale > _zoomedThreshold) {
      _animateTo(1.0, Offset.zero);
      _notifyZoom(false);
      return;
    }
    // 以双击点为锚点放大，保持该点在屏幕上的位置不变。
    const s = _doubleTapScale;
    final scene = (_doubleTapPosition - _offset) / _scale;
    _animateTo(s, _clampOffset(_doubleTapPosition - scene * s, s));
    _notifyZoom(true);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        return GestureDetector(
          // 整个页面区域都要能接收双击/指针事件：图片按 BoxFit.contain 显示时
          // 上下会留出黑边，若用默认的 deferToChild，黑边区域不参与命中测试，
          // 导致在留白处捏合/双击完全无响应。这里显式声明 opaque。
          behavior: HitTestBehavior.opaque,
          onDoubleTapDown: (d) => _doubleTapPosition = d.localPosition,
          onDoubleTap: _handleDoubleTap,
          child: Listener(
            // Listener 不参与手势竞技场，但命中测试仍遵循 behavior。
            // 必须设为 opaque，保证整页（含黑边留白）都能收到原始指针事件，
            // 否则双指捏合时若有一指落在留白处会收不到该指，缩放整体失效。
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerUp,
            child: ClipRect(
              // 以左上角为原点缩放，再整体平移：屏幕 = 内容 × scale + offset。
              child: Transform.translate(
                offset: _offset,
                child: Transform.scale(
                  scale: _scale,
                  alignment: Alignment.topLeft,
                  child: widget.child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BottomActionBar extends ConsumerWidget {
  final MediaItem photo;
  final bool isRemote;
  final String? serverId;

  const _BottomActionBar({required this.photo, required this.isRemote, this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(smbServersProvider).valueOrNull ?? [];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ActionButton(
            icon: Icons.share,
            label: '分享',
            onTap: () => _sharePhoto(context),
          ),
          if (!isRemote && servers.isNotEmpty)
            _ActionButton(
              icon: Icons.cloud_upload,
              label: '备份',
              onTap: () => _backup(context, ref, servers.first.id),
            ),
          if (isRemote)
            _ActionButton(
              icon: Icons.download,
              label: '下载',
              onTap: () => _downloadRemote(context),
            ),
          _ActionButton(
            icon: Icons.info_outline,
            label: '信息',
            onTap: () => _showInfo(context),
          ),
        ],
      ),
    );
  }

  Future<void> _backup(BuildContext context, WidgetRef ref, String serverId) async {
    final result = await ref.read(transfersProvider.notifier).backupPhotos(
          serverId,
          [photo.path],
          '/MiPixBackup',
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.allSucceeded
              ? '已加入备份队列'
              : result.allFailed
                  ? '备份失败，请检查 SMB 配置'
                  : '部分备份成功：成功 ${result.successCount}，失败 ${result.failedCount}',
        ),
      ),
    );
  }

  Future<void> _sharePhoto(BuildContext context) async {
    try {
      if (isRemote) {
        final servers = await LocalStorageService().getSmbServers();
        final server = servers.firstWhere((s) => s.id == serverId);
        final data = await SmbService().readFile(server, photo.path);
        final tempDir = await getTemporaryDirectory();
        final tempFile = File('${tempDir.path}/${photo.name}');
        await tempFile.writeAsBytes(data);
        await Share.shareXFiles([XFile(tempFile.path)], text: photo.name);
      } else {
        await Share.shareXFiles([XFile(photo.path)], text: photo.name);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失败: $e')),
        );
      }
    }
  }

  Future<void> _downloadRemote(BuildContext context) async {
    try {
      final servers = await LocalStorageService().getSmbServers();
      final server = servers.firstWhere((s) => s.id == serverId);
      final data = await SmbService().readFile(server, photo.path);
      if (data.isEmpty) {
        throw Exception('文件内容为空');
      }
      // 写入系统相册（MediaStore），这样 MIUI 相册也能看到下载的图片。
      final saved = await PhotoService.saveBytesToGallery(
        data,
        filename: photo.name,
        relativePath: 'Pictures/MiPix',
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(saved != null ? '已保存到系统相册 Pictures/MiPix' : '保存完成')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e')),
        );
      }
    }
  }

  void _showInfo(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ExifInfoSheet(photo: photo, isRemote: isRemote, serverId: serverId),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedScale(
        scale: 1.0,
        duration: const Duration(milliseconds: 100),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(height: 6),
            Text(label,
                style: const TextStyle(
                    color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

/// 本地视频内联播放器。
class _LocalVideoPlayer extends StatefulWidget {
  final String path;

  const _LocalVideoPlayer({required this.path});

  @override
  State<_LocalVideoPlayer> createState() => _LocalVideoPlayerState();
}

class _LocalVideoPlayerState extends State<_LocalVideoPlayer> {
  VideoPlayerController? _controller;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final controller = VideoPlayerController.file(File(widget.path));
    try {
      await controller.initialize();
      await controller.setLooping(true);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      await controller.play();
    } catch (_) {
      await controller.dispose();
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_error) {
      return const Icon(Icons.broken_image, size: 64, color: Color(0x1FFFFFFF));
    }
    if (controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
      );
    }

    return AspectRatio(
      aspectRatio: controller.value.aspectRatio == 0
          ? 16 / 9
          : controller.value.aspectRatio,
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          return Stack(
            fit: StackFit.expand,
            children: [
              VideoPlayer(controller),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => value.isPlaying ? controller.pause() : controller.play(),
                child: value.isPlaying
                    ? const SizedBox.expand()
                    : Container(
                        color: Colors.black26,
                        child: const Icon(Icons.play_arrow,
                            color: Colors.white, size: 56),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RemotePhotoViewer extends StatefulWidget {
  final String serverId;
  final String remotePath;
  final String name;

  /// 解码宽度上限，避免原图全分辨率解码产生巨大位图。
  final int maxDecodeWidth;

  const _RemotePhotoViewer(
      {required this.serverId,
      required this.remotePath,
      required this.name,
      required this.maxDecodeWidth});

  @override
  State<_RemotePhotoViewer> createState() => _RemotePhotoViewerState();
}

class _RemotePhotoViewerState extends State<_RemotePhotoViewer> {
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
      if (mounted)
        setState(() {
          _imageData = data;
          _loading = false;
        });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: Colors.black,
        child: const Center(
            child: CircularProgressIndicator(
          color: Colors.white,
          strokeWidth: 2,
        )),
      );
    }
    if (_imageData == null) {
      return Container(
        color: Colors.black,
        child: const Icon(Icons.broken_image,
            size: 64, color: Color(0x1FFFFFFF)),
      );
    }
    return Image.memory(
      _imageData!,
      fit: BoxFit.contain,
      cacheWidth: widget.maxDecodeWidth,
      errorBuilder: (_, __, ___) => Container(
        color: Colors.black,
        child: const Icon(Icons.broken_image,
            size: 64, color: Color(0x1FFFFFFF)),
      ),
    );
  }
}

class _ExifInfoSheet extends StatefulWidget {
  final MediaItem photo;
  final bool isRemote;
  final String? serverId;

  const _ExifInfoSheet({required this.photo, required this.isRemote, this.serverId});

  @override
  State<_ExifInfoSheet> createState() => _ExifInfoSheetState();
}

class _ExifInfoSheetState extends State<_ExifInfoSheet> {
  Map<String, dynamic>? _exif;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadExif();
  }

  Future<void> _loadExif() async {
    try {
      if (!widget.isRemote) {
        final fileBytes = await File(widget.photo.path).readAsBytes();
        final data = await exif_pkg.readExifFromBytes(fileBytes);
        _exif = data.map((k, v) => MapEntry(k, v.toString()));
      } else {
        final servers = await LocalStorageService().getSmbServers();
        final server = servers.firstWhere((s) => s.id == widget.serverId);
        final data = await SmbService().readFile(server, widget.photo.path);
        final exifData = await exif_pkg.readExifFromBytes(data);
        _exif = exifData.map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024)
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      builder: (_, controller) {
        return GlassContainer(
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(24)),
          blur: 30,
          tint: const Color(0xFF0F172A).withValues(alpha: 0.9),
          child: Container(
            padding: const EdgeInsets.all(20),
            child: ListView(
              controller: controller,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('文件信息',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(color: Colors.white)),
                const SizedBox(height: 16),
                _InfoRow('名称', widget.photo.name),
                _InfoRow('路径', widget.photo.path),
                _InfoRow('大小', _formatSize(widget.photo.size)),
                _InfoRow('类型', widget.photo.mimeType),
                _InfoRow('时间', widget.photo.modifiedAt.toString()),
                _InfoRow('分辨率',
                    '${widget.photo.width} x ${widget.photo.height}'),
                const SizedBox(height: 20),
                if (_loading)
                  const Center(
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                else if (_exif != null && _exif!.isNotEmpty) ...[
                  Text('EXIF',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(color: Colors.white)),
                  const SizedBox(height: 10),
                  ..._exif!.entries
                      .take(20)
                      .map((e) => _InfoRow(e.key, e.value)),
                ] else
                  const Text('无 EXIF 数据',
                      style: TextStyle(color: Colors.white38)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text('$label:',
                style: const TextStyle(
                    color: Color(0x99FFFFFF), fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}