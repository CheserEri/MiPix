import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mipix_app/widgets/thumb_image.dart';

/// 回归测试：缩略图对动图只能取首帧。
///
/// 真机曾实测到：时间轴上两个无限循环 GIF 的缩略图被 `Image.file` 当作动图解码，
/// `MultiFrameImageStreamCompleter._handleAppFrame` 成为全局唯一的 transient frame
/// callback 并每帧自续，导致界面完全静止时仍以约 47fps 出帧、空烧约 0.85 核 CPU。
/// 这里锁死「动图缩略图不得产生 MultiFrameImageStreamCompleter」这一不变量。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 最小合法 GIF89a：1x1、两帧（黑帧 + 白帧）。
  final Uint8List animatedGif = Uint8List.fromList(<int>[
    ...'GIF89a'.codeUnits,
    0x01, 0x00, 0x01, 0x00, // 逻辑屏幕：1x1
    0x80, 0x00, 0x00, // 有全局色表，2 个颜色
    0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, // 黑 / 白
    0x21, 0xF9, 0x04, 0x04, 0x0A, 0x00, 0x00, 0x00, // 图形控制扩展（帧 1）
    0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, // 图像描述符
    0x02, 0x02, 0x44, 0x01, 0x00, // LZW 数据（索引 0）
    0x21, 0xF9, 0x04, 0x04, 0x0A, 0x00, 0x00, 0x00, // 图形控制扩展（帧 2）
    0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, // 图像描述符
    0x02, 0x02, 0x4C, 0x01, 0x00, // LZW 数据（索引 1）
    0x3B, // 结束
  ]);

  late File gifFile;

  setUp(() async {
    gifFile = File('${Directory.systemTemp.path}/mipix_thumb_regression.gif');
    await gifFile.writeAsBytes(animatedGif, flush: true);
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (gifFile.existsSync()) await gifFile.delete();
  });

  test('测试素材本身确实是多帧动图（否则断言会失真）', () async {
    final ui.Codec codec = await PaintingBinding.instance
        .instantiateImageCodecWithSize(
      await ui.ImmutableBuffer.fromFilePath(gifFile.path),
    );
    expect(codec.frameCount, greaterThan(1));
    codec.dispose();
  });

  test('FirstFrameImageProvider 只取首帧，不产生 MultiFrameImageStreamCompleter',
      () async {
    final provider =
        FirstFrameImageProvider(gifFile.path, targetWidth: 400);
    final completer = provider.loadImage(
      provider,
      PaintingBinding.instance.instantiateImageCodecWithSize,
    );

    expect(completer, isNot(isA<MultiFrameImageStreamCompleter>()));
    expect(completer, isA<OneFrameImageStreamCompleter>());

    // 首帧确实能解出来，且只回调一次。
    int callbacks = 0;
    ui.Image? decoded;
    final completerDone = Completer<void>();
    completer.addListener(
      ImageStreamListener((ImageInfo info, bool synchronousCall) {
        callbacks += 1;
        decoded = info.image;
        if (!completerDone.isCompleted) completerDone.complete();
      }),
    );
    await completerDone.future;
    expect(callbacks, 1);
    expect(decoded!.width, 1);
  });

  test('ThumbImage 对动图走 FirstFrameImageProvider，对静态图仍走 Image.file',
      () async {
    final animated = ThumbImage(path: 'x/y/animated.GIF', cacheWidth: 400);
    expect((animated.build(_FakeContext()) as Image).image,
        isA<FirstFrameImageProvider>());

    final still = ThumbImage(path: 'x/y/still.jpg', cacheWidth: 400);
    expect((still.build(_FakeContext()) as Image).image, isA<ResizeImage>());
  });
}

class _FakeContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
