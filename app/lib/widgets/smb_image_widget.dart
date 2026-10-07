import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/smb_service.dart';
import '../services/local_storage_service.dart';

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
    _load();
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
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: const Color(0xFF1A1A2E),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        ),
      );
    }
    if (_imageData == null) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: const Color(0xFF1A1A2E),
        child: const Icon(Icons.broken_image, color: Colors.white24),
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
        color: const Color(0xFF1A1A2E),
        child: const Icon(Icons.broken_image, color: Colors.white24),
      ),
    );
  }
}
