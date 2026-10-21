import 'dart:io';
import 'package:flutter/gestures.dart';
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
import '../services/remote_video_proxy.dart';
import '../utils/mipix_theme.dart';
import 'package:share_plus/share_plus.dart';
import 'package:photo_manager/photo_manager.dart';
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

/// 视频播放页的系统 UI 样式：顶部白色栏、底部白色操作栏，图标需为深色。
const SystemUiOverlayStyle _videoChromeOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.dark,
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

  /// 两位数补零，用于时间显示。
  String _two(int v) => v.toString().padLeft(2, '0');

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
    // 视频页拥有独立的小米风格白色栏与播放控制，因此不再叠加通用黑色 UI。
    final isVideo = photo.isVideo;
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
                if (item.isVideo) {
                  // 视频页自己负责白底顶栏、控制胶囊与底部操作栏，
                  // 因此查看页的通用黑色半透明 UI 不再叠加。
                  return widget.isRemote
                      ? _RemoteVideoPlayer(
                          key: ValueKey(index),
                          photo: item,
                          serverId: widget.serverId ?? '',
                          isActive: index == _currentIndex,
                          index: index,
                          count: widget.photos.length,
                        )
                      : _LocalVideoPlayer(
                          key: ValueKey(index),
                          photo: item,
                          isActive: index == _currentIndex,
                          index: index,
                          count: widget.photos.length,
                        );
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
            if (!isVideo) ...[
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
                              // 两行居中标题（对齐小米相册）：上行日期，下行时间 · 序号。
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${photo.modifiedAt.year}年${photo.modifiedAt.month}月${photo.modifiedAt.day}日',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    '${_two(photo.modifiedAt.hour)}:${_two(photo.modifiedAt.minute)} · '
                                    '${_currentIndex + 1}/${widget.photos.length}',
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w400),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
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

  /// 视频页使用白底操作栏（对齐小米相册），图标与文字改为深色。
  final bool light;

  const _BottomActionBar({
    required this.photo,
    required this.isRemote,
    this.serverId,
    this.light = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // SMB 云相册：只保留「下载」。
    if (isRemote) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ActionButton(
              icon: Icons.download_outlined,
              label: '下载',
              light: light,
              onTap: () => _downloadRemote(context),
            ),
          ],
        ),
      );
    }

    // 本地相册：对齐小米相册五键（发送 / 编辑 / 收藏 / 删除 / 更多）。
    final servers = ref.watch(smbServersProvider).valueOrNull ?? [];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ActionButton(
            icon: Icons.ios_share,
            label: '发送',
            light: light,
            onTap: () => _sharePhoto(context),
          ),
          _ActionButton(
            icon: Icons.edit_outlined,
            label: '编辑',
            light: light,
            onTap: () => _notSupported(context, '编辑'),
          ),
          _ActionButton(
            icon: Icons.favorite_border,
            label: '收藏',
            light: light,
            onTap: () => _notSupported(context, '收藏'),
          ),
          _ActionButton(
            icon: Icons.delete_outline,
            label: '删除',
            light: light,
            onTap: () => _deleteLocal(context),
          ),
          _ActionButton(
            icon: Icons.more_horiz,
            label: '更多',
            light: light,
            onTap: () => _showMore(context, ref, servers),
          ),
        ],
      ),
    );
  }

  void _notSupported(BuildContext context, String name) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$name 暂不支持')));
  }

  /// 「更多」菜单：对齐小米相册——纯文字列表、大圆角弹层、无图标。
  void _showMore(BuildContext context, WidgetRef ref, List<SmbConfig> servers) {
    final palette = MiPixPalette.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 6),
            if (servers.isNotEmpty)
              _MoreMenuItem(
                label: '备份到 SMB',
                onTap: () {
                  Navigator.pop(ctx);
                  _backup(context, ref, servers.first.id);
                },
              ),
            _MoreMenuItem(
              label: '详情',
              onTap: () {
                Navigator.pop(ctx);
                _showInfo(context);
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  /// 删除本地照片（走系统 MediaStore，会弹出系统确认框）。
  Future<void> _deleteLocal(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final deleted = await PhotoManager.editor.deleteWithIds([photo.id]);
      if (deleted.isEmpty) return; // 用户在系统确认框中取消
      if (context.mounted) Navigator.pop(context, true);
      messenger.showSnackBar(const SnackBar(content: Text('已删除')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('删除失败: $e')));
    }
  }

  Future<void> _backup(BuildContext context, WidgetRef ref, String serverId) async {
    final result = await ref.read(transfersProvider.notifier).backupPhotos(
          serverId,
          [photo.path],
        );
    final String message;
    if (result.allAlreadyBackedUp) {
      message = '该照片已在服务器上，无需重复备份';
    } else if (result.successCount == 0 &&
        result.failedCount == 0 &&
        result.conflictSkippedCount > 0) {
      message = '${result.conflictSkippedCount} 项同名冲突未备份（详见传输列表）';
    } else if (result.successCount == 0 && result.failedCount == 0) {
      message = '该照片正在上传中';
    } else if (result.allSucceeded) {
      message = '已加入备份队列';
    } else if (result.allFailed) {
      message = '备份失败，请检查 SMB 配置';
    } else {
      message = '部分备份成功：成功 ${result.successCount}，失败 ${result.failedCount}';
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
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
      if (photo.isVideo) {
        // 视频改为流式落盘后写入 MediaStore，避免整段视频先塞进内存。
        final total = await SmbService().remoteFileSize(server, photo.path);
        if (total <= 0) throw Exception('无法读取文件大小');
        final tempDir = await getTemporaryDirectory();
        final tempFile = File('${tempDir.path}/${photo.name}');
        final sink = tempFile.openWrite();
        try {
          await for (final chunk in SmbService()
              .openRemoteVideoRange(server, photo.path, 0, total)) {
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        await PhotoManager.editor.saveVideo(
          tempFile,
          relativePath: 'Movies/MiPix',
        );
        try {
          await tempFile.delete();
        } catch (_) {}
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已保存到系统相册 Movies/MiPix')),
          );
        }
        return;
      }
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

  /// 打开照片详情页（对齐小米相册「详情」：整页、返回 + 居中标题 + 标签/值行）。
  void _showInfo(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _PhotoDetailScreen(photo: photo)),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool light;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.light = false,
  });

  @override
  Widget build(BuildContext context) {
    // 对齐小米相册：图标在上、文字在下，无背景框。
    final color = light ? const Color(0xFF1A1A1A) : Colors.white;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    color: color, fontSize: 11, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

/// 本地视频页。
class _LocalVideoPlayer extends StatelessWidget {
  final MediaItem photo;
  final bool isActive;
  final int index;
  final int count;

  const _LocalVideoPlayer({
    super.key,
    required this.photo,
    required this.isActive,
    required this.index,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return _VideoPage(
      photo: photo,
      index: index,
      count: count,
      isActive: isActive,
      createController: () async =>
          VideoPlayerController.file(File(photo.path)),
      errorText: '无法播放该视频',
    );
  }
}

/// 远端（SMB）视频页：经本地 HTTP 代理按需读取字节，边下边播。
class _RemoteVideoPlayer extends StatefulWidget {
  final MediaItem photo;
  final String serverId;
  final bool isActive;
  final int index;
  final int count;

  const _RemoteVideoPlayer({
    super.key,
    required this.photo,
    required this.serverId,
    required this.isActive,
    required this.index,
    required this.count,
  });

  @override
  State<_RemoteVideoPlayer> createState() => _RemoteVideoPlayerState();
}

class _RemoteVideoPlayerState extends State<_RemoteVideoPlayer> {
  /// ExoPlayer 不支持这些容器，初始化会直接失败，提前给出下载提示。
  static const Set<String> _unsupportedExtensions = {'avi', 'wmv'};

  String? _token;

  Future<VideoPlayerController> _create() async {
    final ext = widget.photo.name.toLowerCase().split('.').last;
    if (_unsupportedExtensions.contains(ext)) {
      throw UnsupportedError('unsupported video container: $ext');
    }
    final servers = await LocalStorageService().getSmbServers();
    final server = servers.firstWhere((s) => s.id == widget.serverId);
    final handle = await RemoteVideoProxy.instance
        .register(server, widget.photo.path, widget.photo.name);
    _token = handle.token;
    return VideoPlayerController.networkUrl(handle.url);
  }

  void _teardown() {
    final token = _token;
    _token = null;
    if (token != null) RemoteVideoProxy.instance.unregister(token);
  }

  @override
  Widget build(BuildContext context) {
    return _VideoPage(
      photo: widget.photo,
      index: widget.index,
      count: widget.count,
      isActive: widget.isActive,
      isRemote: true,
      serverId: widget.serverId,
      createController: _create,
      onTeardown: _teardown,
      errorText: '该视频暂不支持在线播放\n可点击下方「下载」离线观看',
    );
  }
}

/// 视频页统一外壳（对齐小米相册）：
/// 黑色画面区 + 白底日期顶栏 + 悬浮胶囊控制条 + 白底底部操作栏。
class _VideoPage extends StatefulWidget {
  final MediaItem photo;
  final int index;
  final int count;
  final bool isActive;
  final bool isRemote;
  final String? serverId;
  final Future<VideoPlayerController> Function() createController;
  final VoidCallback? onTeardown;
  final String errorText;

  const _VideoPage({
    required this.photo,
    required this.index,
    required this.count,
    required this.isActive,
    required this.createController,
    required this.errorText,
    this.isRemote = false,
    this.serverId,
    this.onTeardown,
  });

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;
  bool _showUI = true;
  bool _locked = false;
  bool _muted = false;

  /// 异步初始化序号：翻页/销毁后旧任务的结果必须丢弃。
  int _serial = 0;

  @override
  void initState() {
    super.initState();
    _loading = widget.isActive;
    if (widget.isActive) _start();
  }

  @override
  void didUpdateWidget(covariant _VideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive == oldWidget.isActive) return;
    if (widget.isActive) {
      _start();
    } else {
      // 离开该页即销毁播放器：释放解码器与 SMB 连接，回来时重新初始化。
      _stop();
    }
  }

  Future<void> _start() async {
    final serial = ++_serial;
    // 只会在 initState / didUpdateWidget 里触发，本帧随后就会 build，
    // 直接改字段即可，不必在构建阶段调用 setState。
    _loading = true;
    _error = null;
    _showUI = true;

    VideoPlayerController? created;
    try {
      created = await widget.createController();
      await created.initialize();
    } catch (_) {
      if (serial == _serial && mounted) {
        setState(() {
          _loading = false;
          _error = widget.errorText;
        });
      }
      await created?.dispose();
      widget.onTeardown?.call();
      return;
    }

    final controller = created;
    if (!mounted || serial != _serial) {
      await controller.dispose();
      widget.onTeardown?.call();
      return;
    }

    await controller.setLooping(false);
    await controller.setVolume(_muted ? 0 : 1);
    setState(() {
      _controller = controller;
      _loading = false;
    });
    await controller.play();
  }

  void _stop() {
    _serial++;
    final controller = _controller;
    _controller = null;
    controller?.dispose();
    widget.onTeardown?.call();
    _loading = false;
    _error = null;
  }

  @override
  void dispose() {
    _serial++;
    _controller?.dispose();
    widget.onTeardown?.call();
    super.dispose();
  }

  void _toggleMute() {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _muted = !_muted);
    controller.setVolume(_muted ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final controller = _controller;
    final showChrome = widget.isActive && _showUI;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: showChrome ? _videoChromeOverlayStyle : _viewerOverlayStyle,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_locked) return;
          setState(() => _showUI = !_showUI);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            if (controller != null)
              Center(
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio == 0
                      ? 16 / 9
                      : controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              )
            else if (_error != null)
              _buildError()
            else if (widget.isActive && _loading)
              const Center(
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              ),
            IgnorePointer(
              ignoring: !showChrome,
              child: AnimatedOpacity(
                opacity: showChrome ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _VideoTopBar(
                        photo: widget.photo,
                        index: widget.index,
                        count: widget.count,
                        locked: _locked,
                        onToggleLock: () =>
                            setState(() => _locked = !_locked),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (controller != null) ...[
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 24),
                              child: _VideoControls(
                                controller: controller,
                                muted: _muted,
                                onToggleMute: _toggleMute,
                              ),
                            ),
                            const SizedBox(height: 16),
                          ] else
                            const SizedBox(height: 24),
                          Container(
                            color: Colors.white,
                            padding:
                                EdgeInsets.only(bottom: mq.padding.bottom),
                            child: _BottomActionBar(
                              photo: widget.photo,
                              isRemote: widget.isRemote,
                              serverId: widget.serverId,
                              light: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_outlined,
                size: 56, color: Color(0x66FFFFFF)),
            const SizedBox(height: 14),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Color(0xCCFFFFFF)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 视频页顶栏：白底、左对齐日期/时间、右上角锁定。
class _VideoTopBar extends StatelessWidget {
  final MediaItem photo;
  final int index;
  final int count;
  final bool locked;
  final VoidCallback onToggleLock;

  const _VideoTopBar({
    required this.photo,
    required this.index,
    required this.count,
    required this.locked,
    required this.onToggleLock,
  });

  String _two(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final date = photo.modifiedAt;
    return Container(
      color: Colors.white,
      padding: EdgeInsets.only(top: topInset),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_ios_new,
                  size: 20, color: Color(0xFF1A1A1A)),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${date.year}年${date.month}月${date.day}日',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_two(date.hour)}:${_two(date.minute)} · '
                    '${index + 1}/$count',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF8A8A8A),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onToggleLock,
              icon: Icon(
                locked ? Icons.lock : Icons.lock_outline,
                size: 22,
                color: const Color(0xFF1A1A1A),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 进度条专用拖动识别器：按下即接受手势。
///
/// 进度条位于 PageView 内，普通 `PanGestureRecognizer` 会与外层的横向
/// 拖动识别器争夺手势；一旦外层先达到拖动阈值，就会误触发切换上一/下一
/// 个视频。这里在指针按下时立刻赢得竞技场，让 PageView 收不到本次手势。
class _EagerPanGestureRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// 悬浮胶囊控制条：播放/暂停 + 细进度条 + 静音（对齐小米相册）。
class _VideoControls extends StatefulWidget {
  final VideoPlayerController controller;
  final bool muted;
  final VoidCallback onToggleMute;

  const _VideoControls({
    required this.controller,
    required this.muted,
    required this.onToggleMute,
  });

  @override
  State<_VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<_VideoControls> {
  bool _dragging = false;
  bool _fine = false;
  bool _resumeAfterDrag = false;
  double _dragStartFraction = 0;
  double _dragFraction = 0;
  double _accumulatedDx = 0;

  /// 进度条根节点必须使用 GlobalKey：拖动开始/结束时胶囊会在
  /// 「收起 Row」与「展开 Column」之间切换，若没有 GlobalKey，进度条元素会被
  /// 重建，正在跟踪指针的手势识别器随之销毁，拖动后半程的事件就丢给了外层
  /// PageView，导致误切换上/下一个视频，且控件卡在拖动展开态。
  final GlobalKey _trackKey = GlobalKey();

  /// 当前进度条宽度（逻辑像素），由 LayoutBuilder 在每次布局时更新。
  /// 展开态与收起态宽度不同，闭包里不能缓存旧值。
  double _trackWidth = 0;

  /// 开始拖动：把按下点当作新的进度起点（同时兼容点击定位）。
  void _beginDrag(double fraction) {
    final value = widget.controller.value;
    _resumeAfterDrag = value.isPlaying;
    if (_resumeAfterDrag) widget.controller.pause();
    final start = fraction.clamp(0.0, 1.0);
    setState(() {
      _dragging = true;
      _fine = false;
      _accumulatedDx = 0;
      _dragStartFraction = start;
      _dragFraction = start;
    });
    _seekTo(start);
  }

  void _updateDrag(DragUpdateDetails details) {
    _accumulatedDx += details.delta.dx;
    // 上滑后把横向位移缩小到 1/5，方便逐秒微调。
    if (details.delta.dy < -2) _fine = true;
    final factor = _fine ? 5.0 : 1.0;
    final width = _trackWidth <= 0 ? 1.0 : _trackWidth;
    final fraction =
        (_dragStartFraction + _accumulatedDx / width / factor).clamp(0.0, 1.0);
    setState(() => _dragFraction = fraction);
    _seekTo(fraction);
  }

  void _endDrag() {
    setState(() {
      _dragging = false;
      _fine = false;
    });
    if (_resumeAfterDrag) {
      _resumeAfterDrag = false;
      widget.controller.play();
    }
  }

  void _seekTo(double fraction) {
    final total = widget.controller.value.duration;
    if (total <= Duration.zero) return;
    widget.controller.seekTo(
      Duration(milliseconds: (total.inMilliseconds * fraction).round()),
    );
  }

  String _format(Duration d, {bool withCentis = false}) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    final base = '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
    if (!withCentis) return base;
    final cs = (d.inMilliseconds.remainder(1000) ~/ 10)
        .toString()
        .padLeft(2, '0');
    return '$base.$cs';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final total = value.duration;
        final position = _dragging
            ? Duration(
                milliseconds:
                    (total.inMilliseconds * _dragFraction).round())
            : value.position;
        final fraction = total.inMilliseconds <= 0
            ? 0.0
            : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_dragging)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Text(
                    '上滑进入精细调节',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: _dragging ? 78 : 46,
              padding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: _dragging ? 10 : 0,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.93),
                borderRadius: BorderRadius.circular(_dragging ? 20 : 23),
              ),
              child: _dragging
                  ? Column(
                      children: [
                        Row(
                          children: [
                            Text(
                              _format(position, withCentis: true),
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF1A1A1A),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _format(total),
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF8A8A8A),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Expanded(child: _buildTrack(fraction)),
                      ],
                    )
                  : Row(
                      // 让进度条的命中区域占满胶囊高度，手指按在细条附近
                      // （而非正好压在线条上）也能拖动进度，而不是触发翻页。
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _playPauseButton(value),
                        const SizedBox(width: 12),
                        Expanded(child: _buildTrack(fraction)),
                        const SizedBox(width: 12),
                        _muteButton(),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _playPauseButton(VideoPlayerValue value) {
    return IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      splashRadius: 18,
      onPressed: () {
        final controller = widget.controller;
        if (value.isPlaying) {
          controller.pause();
        } else {
          if (value.duration > Duration.zero &&
              value.position >= value.duration) {
            controller.seekTo(Duration.zero);
          }
          controller.play();
        }
      },
      icon: Icon(
        value.isPlaying ? Icons.pause : Icons.play_arrow,
        size: 22,
        color: const Color(0xFF2B2B2B),
      ),
    );
  }

  Widget _muteButton() {
    return IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      splashRadius: 18,
      onPressed: widget.onToggleMute,
      icon: Icon(
        widget.muted ? Icons.volume_off_outlined : Icons.volume_up_outlined,
        size: 20,
        color: const Color(0xFF2B2B2B),
      ),
    );
  }

  Widget _buildTrack(double fraction) {
    return LayoutBuilder(
      key: _trackKey,
      builder: (context, constraints) {
        _trackWidth = constraints.maxWidth;
        return RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            _EagerPanGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<_EagerPanGestureRecognizer>(
              _EagerPanGestureRecognizer.new,
              (recognizer) {
                recognizer.onStart = (d) => _beginDrag(
                    (d.localPosition.dx / _trackWidth).clamp(0.0, 1.0));
                recognizer.onUpdate = _updateDrag;
                recognizer.onEnd = (_) => _endDrag();
                recognizer.onCancel = _endDrag;
              },
            ),
          },
          child: Center(
            child: SizedBox(
              height: 14,
              child: Stack(
                alignment: Alignment.centerLeft,
                clipBehavior: Clip.none,
                children: [
                  Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: const Color(0xFFC7C7C5),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: fraction,
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: const Color(0xFF767677),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  if (_dragging)
                    Align(
                      alignment: Alignment(-1 + 2 * fraction, 0),
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: const BoxDecoration(
                          color: Color(0xFF767677),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
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

/// 照片详情页：对齐小米相册「详情」——整页、返回 + 居中标题，标签/值分行排布。
class _PhotoDetailScreen extends StatefulWidget {
  final MediaItem photo;

  const _PhotoDetailScreen({required this.photo});

  @override
  State<_PhotoDetailScreen> createState() => _PhotoDetailScreenState();
}

class _PhotoDetailScreenState extends State<_PhotoDetailScreen> {
  Map<String, exif_pkg.IfdTag>? _exif;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadExif();
  }

  Future<void> _loadExif() async {
    try {
      final bytes = await File(widget.photo.path).readAsBytes();
      _exif = await exif_pkg.readExifFromBytes(bytes);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  String? _str(String key) {
    final tag = _exif?[key];
    if (tag == null) return null;
    final s = tag.printable.trim();
    return s.isEmpty ? null : s;
  }

  /// 取 EXIF 数值（Ratio / int 统一转 double）。
  double? _num(String key, [int index = 0]) {
    final tag = _exif?[key];
    if (tag == null) return null;
    final list = tag.values.toList();
    if (index >= list.length) return null;
    final v = list[index];
    if (v is exif_pkg.Ratio) return v.toDouble();
    if (v is int) return v.toDouble();
    if (v is double) return v;
    return null;
  }

  /// 去掉无意义的小数尾零（1.60 → 1.6，6.55 → 6.55）。
  String _trimNum(double v) {
    final s = v.toStringAsFixed(2);
    return s.endsWith('0') ? s.substring(0, s.length - 1) : s;
  }

  /// 拍摄时间：优先 EXIF 拍摄时间，回退到文件修改时间。
  String _shootingTime() {
    DateTime? dt;
    final raw = _str('EXIF DateTimeOriginal') ?? _str('Image DateTime');
    if (raw != null) {
      final m =
          RegExp(r'(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2})').firstMatch(raw);
      if (m != null) {
        dt = DateTime(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          int.parse(m.group(4)!),
          int.parse(m.group(5)!),
        );
      }
    }
    dt ??= widget.photo.modifiedAt;
    const week = ['一', '二', '三', '四', '五', '六', '日'];
    return '${dt.year}年${dt.month}月${dt.day}日\n'
        '星期${week[dt.weekday - 1]} ${_two(dt.hour)}:${_two(dt.minute)}';
  }

  /// 拍摄参数：机型 / 光圈·快门·ISO / 焦距·闪光灯。
  String? _cameraParams() {
    final lines = <String>[];

    final model = _str('Image Model');
    final make = _str('Image Make');
    String maker = '';
    if (model != null && make != null) {
      final head = model.toLowerCase().startsWith(make.toLowerCase())
          ? model
          : '$make $model';
      maker = '$head, $make';
    } else {
      maker = model ?? make ?? '';
    }
    if (maker.isNotEmpty) lines.add(maker);

    final f = _num('EXIF FNumber');
    final exposure = _num('EXIF ExposureTime');
    final iso = _num('EXIF ISOSpeedRatings');
    final line2 = <String>[];
    if (f != null) line2.add('f/${_trimNum(f)}');
    if (exposure != null && exposure > 0) {
      line2.add(exposure >= 1
          ? '${_trimNum(exposure)}s'
          : '1/${(1 / exposure).round()}s');
    }
    if (iso != null) line2.add('ISO${iso.round()}');
    if (line2.isNotEmpty) lines.add(line2.join('  '));

    final focal = _num('EXIF FocalLength');
    final flash = _num('EXIF Flash');
    final line3 = <String>[];
    if (focal != null) line3.add('${_trimNum(focal)}mm');
    if (flash != null) {
      line3.add((flash.toInt() & 1) == 1 ? '已使用闪光灯' : '未使用闪光灯');
    }
    if (line3.isNotEmpty) lines.add(line3.join('  '));

    return lines.isEmpty ? null : lines.join('\n');
  }

  /// 拍摄地点：由 GPS EXIF 换算为度分秒；无 GPS 时返回 null 隐藏该行。
  String? _location() {
    final lat = _gps('GPS GPSLatitude', _str('GPS GPSLatitudeRef'));
    final lon = _gps('GPS GPSLongitude', _str('GPS GPSLongitudeRef'));
    if (lat == null || lon == null) return null;
    return '${_dms(lat, 'NS')}  ${_dms(lon, 'EW')}';
  }

  double? _gps(String key, String? ref) {
    final tag = _exif?[key];
    if (tag == null) return null;
    final list = tag.values.toList();
    if (list.length < 3) return null;
    double comp(int i) {
      final v = list[i];
      if (v is exif_pkg.Ratio) return v.toDouble();
      if (v is int) return v.toDouble();
      return 0;
    }

    final deg = comp(0) + comp(1) / 60 + comp(2) / 3600;
    final r = (ref ?? '').trim().toUpperCase();
    return (r.startsWith('S') || r.startsWith('W')) ? -deg : deg;
  }

  String _dms(double v, String refs) {
    final abs = v.abs();
    final d = abs.floor();
    final mFull = (abs - d) * 60;
    final m = mFull.floor();
    final s = (mFull - m) * 60;
    return '$d°$m\'${s.round()}"${v >= 0 ? refs[0] : refs[1]}';
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  /// 路径按小米习惯以「内部存储/」呈现，去掉 Android 绝对前缀。
  String _displayPath() {
    const prefix = '/storage/emulated/0/';
    final p = widget.photo.path;
    return p.startsWith(prefix) ? '内部存储/${p.substring(prefix.length)}' : p;
  }

  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    final valueStyle = TextStyle(
      fontSize: 14,
      height: 1.55,
      color: palette.textPrimary,
    );
    final subStyle = TextStyle(
      fontSize: 13.5,
      height: 1.55,
      color: palette.textSecondary,
    );
    final params = _cameraParams();
    final location = _location();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: MiPixTheme.overlayStyle(context),
      child: Scaffold(
        backgroundColor: palette.background,
        appBar: AppBar(
          backgroundColor: palette.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: palette.textPrimary),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
            '详情',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            _DetailRow(
              label: '拍摄时间',
              value: Text(_shootingTime(), style: valueStyle),
            ),
            _DetailRow(
              label: '文件信息',
              value: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: widget.photo.name, style: valueStyle),
                    TextSpan(
                      text: '\n${_formatSize(widget.photo.size)}  '
                          '${widget.photo.width}×${widget.photo.height}px',
                      style: subStyle,
                    ),
                  ],
                ),
              ),
            ),
            if (params != null)
              _DetailRow(
                label: '拍摄参数',
                value: Text(params, style: valueStyle),
              ),
            _DetailRow(
              label: '文件路径',
              value: Text(_displayPath(), style: valueStyle),
            ),
            if (location != null)
              _DetailRow(
                label: '拍摄地点',
                value: Text(location, style: valueStyle),
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 详情页的一行：左标签 + 右值（值可多行）。
class _DetailRow extends StatelessWidget {
  final String label;
  final Widget value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                height: 1.55,
                color: palette.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: value),
        ],
      ),
    );
  }
}

/// 「更多」菜单项：纯文字、大间距（对齐小米相册）。
class _MoreMenuItem extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _MoreMenuItem({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        child: Text(
          label,
          style: TextStyle(fontSize: 16, color: palette.textPrimary),
        ),
      ),
    );
  }
}