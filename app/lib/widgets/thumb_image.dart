import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 是否为可能包含多帧动画的图片格式。
///
/// 这些格式若用 [Image.file] 直接解码，会走
/// [MultiFrameImageStreamCompleter] 并持续注册帧回调，
/// 在界面静止时仍以满帧率出帧、空耗 CPU。
bool _isAnimatedImage(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.apng');
}

/// 缩略图 / 相册封面用的图片组件。
///
/// 与 [Image.file] 的唯一区别：动图只解码首帧并立即释放解码器，
/// 因此不会再产生自续帧回调。查看大图的场景仍应使用 [Image.file]，
/// 以保留动图播放能力。
class ThumbImage extends StatelessWidget {
  final String path;
  final BoxFit fit;
  final int cacheWidth;
  final ImageErrorWidgetBuilder? errorBuilder;

  const ThumbImage({
    super.key,
    required this.path,
    this.fit = BoxFit.cover,
    this.cacheWidth = 400,
    this.errorBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (_isAnimatedImage(path)) {
      return Image(
        image: FirstFrameImageProvider(path, targetWidth: cacheWidth),
        fit: fit,
        errorBuilder: errorBuilder,
      );
    }
    return Image.file(
      File(path),
      fit: fit,
      cacheWidth: cacheWidth,
      errorBuilder: errorBuilder,
    );
  }
}

/// 只取图片首帧的 [ImageProvider]。
///
/// 解码后立即 `codec.dispose()`，通过 [OneFrameImageStreamCompleter]
/// 只发送一次帧，之后不会再请求新帧（对比 [MultiFrameImageStreamCompleter]
/// 会在无限循环动图上永不停止地调度下一帧）。
class FirstFrameImageProvider extends ImageProvider<FirstFrameImageProvider> {
  final String path;
  final int targetWidth;
  final double scale;

  const FirstFrameImageProvider(
    this.path, {
    required this.targetWidth,
    this.scale = 1.0,
  });

  @override
  Future<FirstFrameImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<FirstFrameImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    FirstFrameImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      _loadFirstFrame(key, decode),
      informationCollector: () => <DiagnosticsNode>[
        ErrorDescription('Path: ${key.path}'),
      ],
    );
  }

  Future<ImageInfo> _loadFirstFrame(
    FirstFrameImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final file = File(key.path);
    final int lengthInBytes = await file.length();
    if (lengthInBytes == 0) {
      PaintingBinding.instance.imageCache.evict(key);
      throw StateError('${key.path} is empty and cannot be loaded as an image.');
    }
    final ui.Codec codec = await decode(
      await ui.ImmutableBuffer.fromFilePath(file.path),
      getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
        // 与 Image.file(cacheWidth: ...) 的 ResizeImagePolicy.exact 行为一致：
        // 不放大，仅在目标宽度大于原图宽度时收敛到原图宽度。
        final int width =
            key.targetWidth > intrinsicWidth ? intrinsicWidth : key.targetWidth;
        return ui.TargetImageSize(width: width, height: null);
      },
    );
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      return ImageInfo(image: frame.image, scale: key.scale, debugLabel: key.path);
    } finally {
      codec.dispose();
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }
    return other is FirstFrameImageProvider &&
        other.path == path &&
        other.targetWidth == targetWidth &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(path, targetWidth, scale);

  @override
  String toString() =>
      'FirstFrameImageProvider("$path", targetWidth: $targetWidth)';
}
