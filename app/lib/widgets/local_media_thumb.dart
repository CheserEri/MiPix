import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/models.dart';

/// 本地媒体缩略图。
///
/// * 图片：直接读取文件；
/// * 视频：通过 photo_manager 生成缩略图，并叠加播放角标。
class LocalMediaThumb extends StatefulWidget {
  final MediaItem item;
  final BoxFit fit;
  final int cacheWidth;

  const LocalMediaThumb({
    super.key,
    required this.item,
    this.fit = BoxFit.cover,
    this.cacheWidth = 400,
  });

  @override
  State<LocalMediaThumb> createState() => _LocalMediaThumbState();
}

class _LocalMediaThumbState extends State<LocalMediaThumb> {
  Uint8List? _thumb;

  @override
  void initState() {
    super.initState();
    if (widget.item.isVideo) _loadThumb();
  }

  @override
  void didUpdateWidget(covariant LocalMediaThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.id != oldWidget.item.id) {
      _thumb = null;
      if (widget.item.isVideo) _loadThumb();
    }
  }

  Future<void> _loadThumb() async {
    try {
      final asset = await AssetEntity.fromId(widget.item.id);
      final data = await asset?.thumbnailDataWithSize(
        ThumbnailSize(widget.cacheWidth, widget.cacheWidth),
      );
      if (mounted) setState(() => _thumb = data);
    } catch (_) {
      if (mounted) setState(() => _thumb = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.item.isVideo) {
      return Image.file(
        File(widget.item.path),
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
        errorBuilder: (_, __, ___) => _fallback(),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (_thumb != null)
          Image.memory(
            _thumb!,
            fit: widget.fit,
            cacheWidth: widget.cacheWidth,
            errorBuilder: (_, __, ___) => _fallback(),
          )
        else
          _fallback(),
        const Center(
          child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 36),
        ),
      ],
    );
  }

  Widget _fallback() => Container(
        color: const Color(0xFF1A1A2E),
        child: Icon(
          widget.item.isVideo ? Icons.videocam : Icons.image,
          color: Colors.white24,
        ),
      );
}
