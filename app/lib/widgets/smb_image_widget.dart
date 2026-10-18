import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/smb_service.dart';
import '../services/local_storage_service.dart';
import '../utils/mipix_theme.dart';

/// SMB 远程图片加载Widget（用于显示 SMB 服务器上的图片封面）
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

  @override
  void initState() {
    super.initState();
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
      Uint8List data;
      if (widget.useThumbnail) {
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
