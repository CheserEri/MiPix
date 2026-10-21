import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/smb_service.dart';
import '../services/local_storage_service.dart';
import '../services/video_thumbnail_service.dart';
import '../utils/mipix_theme.dart';

/// SMB 远程图片加载Widget（用于显示 SMB 服务器上的图片封面）
///
/// 若 [remotePath] 是视频，则通过 [VideoThumbnailService] 抽一帧作为封面，
/// 而不是把视频当图片解码（那会整份读入内存并直接失败）。
class SmbRemoteImage extends StatefulWidget {
  final String serverId;
  final String remotePath;
  final double? width;
  final double? height;
  final BoxFit fit;
  final bool useThumbnail;

  const SmbRemoteImage({
    required this.serverId,
    required this.remotePath,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.useThumbnail = true,
    super.key,
  });

  @override
  State<SmbRemoteImage> createState() => _SmbRemoteImageState();
}

class _SmbRemoteImageState extends State<SmbRemoteImage> {
  Uint8List? _imageData;
  bool _loading = true;

  bool get _isVideo => SmbService.isVideoName(widget.remotePath);

  /// 供缩略图服务使用的媒体条目。
  ///
  /// 相册扫描阶段只有文件名与远端路径，没有修改时间；这里使用固定时间戳，
  /// 使封面缓存键稳定。封面本身允许用户随时改成自定义封面，不需要自动失效。
  MediaItem get _coverItem => MediaItem(
        id: widget.remotePath,
        name: widget.remotePath.split('/').last,
        path: widget.remotePath,
        source: MediaSource.smb(widget.serverId),
        mimeType: 'video/mp4',
        size: 0,
        width: 0,
        height: 0,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

  @override
  void initState() {
    super.initState();
    if (_isVideo) {
      final peeked = VideoThumbnailService.instance
          .peek(serverId: widget.serverId, item: _coverItem);
      if (peeked != null) {
        _imageData = peeked;
        _loading = false;
      } else {
        _load();
      }
      return;
    }
    // 内存缓存命中时同步展示，避免列表重建时重复加载。
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
      Uint8List? data;
      if (_isVideo) {
        data = await VideoThumbnailService.instance
            .load(server: server, item: _coverItem);
      } else if (widget.useThumbnail) {
        data = await SmbService().readThumbnail(server, widget.remotePath);
      } else {
        data = await SmbService().readFile(server, widget.remotePath);
      }
      if (mounted) {
        setState(() {
          _imageData = data;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('[smb] coverLoad FAIL path=${widget.remotePath} ${e.runtimeType} $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = MiPixPalette.of(context);
    if (_loading) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: palette.fill,
        child: Center(
          child: CircularProgressIndicator(color: palette.accent, strokeWidth: 2),
        ),
      );
    }
    if (_imageData == null) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: palette.fill,
        child: Icon(Icons.broken_image,
            color: palette.textSecondary.withValues(alpha: 0.6)),
      );
    }
    return Image.memory(
      _imageData!,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      errorBuilder: (_, __, ___) => Container(
        width: widget.width,
        height: widget.height,
        color: palette.fill,
        child: Icon(Icons.broken_image,
            color: palette.textSecondary.withValues(alpha: 0.6)),
      ),
    );
  }
}
