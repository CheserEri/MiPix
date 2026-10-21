import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'remote_video_proxy.dart';

/// 远端视频缩略图服务。
///
/// 视频不能像图片那样直接解码，这里借助 Android 原生
/// `MediaMetadataRetriever`，从回环代理地址读取后抽取一帧。为保证网格滚动
/// 流畅：
///  * 同一个视频只解码一次（内存 + 磁盘两级缓存）；
///  * 解码并发限制为 2，其余请求排队；
///  * 解码失败也记入内存（不写磁盘），避免滚动时反复重试同一文件。
class VideoThumbnailService {
  VideoThumbnailService._();

  static final VideoThumbnailService instance = VideoThumbnailService._();

  static const MethodChannel _channel = MethodChannel('mipix/video_thumbnail');

  static const int _maxConcurrent = 2;
  static const int _memoryLimit = 300;

  /// 抽帧时刻：跳过开头可能存在的黑屏/片头，1 秒处通常已有正常画面。
  static const int _frameTimeMs = 1000;

  final Map<String, Uint8List?> _memory = {};
  final List<Completer<void>> _waiters = [];
  int _active = 0;

  Future<Directory>? _cacheDirFuture;

  /// 同步读取内存缓存（命中失败时返回 null，用 [knows] 区分“没查过”）。
  Uint8List? peek({required String serverId, required MediaItem item}) =>
      _memory[_key(serverId, item)];

  /// 该视频是否已经尝试过抽帧（无论成功与否）。
  bool knows({required String serverId, required MediaItem item}) =>
      _memory.containsKey(_key(serverId, item));

  Future<Uint8List?> load({
    required SmbConfig server,
    required MediaItem item,
  }) async {
    final key = _key(server.id, item);
    if (_memory.containsKey(key)) return _memory[key];

    final cached = await _readDisk(key);
    if (cached != null) {
      _remember(key, cached);
      return cached;
    }

    await _acquire();
    try {
      // 排队期间同文件可能已被其他瓦片解码完成，直接复用。
      if (_memory.containsKey(key)) return _memory[key];
      final bytes = await _extract(server, item);
      if (bytes == null) {
        _remember(key, null);
      } else {
        _remember(key, bytes);
        await _writeDisk(key, bytes);
      }
      return bytes;
    } finally {
      _release();
    }
  }

  Future<Uint8List?> _extract(SmbConfig server, MediaItem item) async {
    String? token;
    try {
      final session = await RemoteVideoProxy.instance
          .register(server, item.path, item.name);
      token = session.token;
      final data = await _channel.invokeMethod<Uint8List>(
        'frame',
        <String, Object>{
          'url': session.url.toString(),
          'timeMs': _frameTimeMs,
        },
      );
      if (data == null || data.isEmpty) return null;
      return data;
    } on MissingPluginException {
      // 非 Android 平台或未接入原生通道时退化为占位图。
      return null;
    } on PlatformException catch (e) {
      debugPrint('[videoThumb] ${item.name} ${e.code} ${e.message}');
      return null;
    } catch (e) {
      debugPrint('[videoThumb] ${item.name} $e');
      return null;
    } finally {
      if (token != null) RemoteVideoProxy.instance.unregister(token);
    }
  }

  Future<void> _acquire() {
    if (_active < _maxConcurrent) {
      _active++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      // 直接把名额移交给下一个等待者，_active 保持不变。
      _waiters.removeAt(0).complete();
    } else {
      _active--;
    }
  }

  void _remember(String key, Uint8List? bytes) {
    if (_memory.length >= _memoryLimit) _memory.clear();
    _memory[key] = bytes;
  }

  /// 缓存键包含文件修改时间：远端文件被替换后不会继续显示旧封面。
  String _key(String serverId, MediaItem item) => sha1
      .convert(utf8.encode(
          '$serverId|${item.path}|${item.modifiedAt.millisecondsSinceEpoch}'))
      .toString();

  Future<Directory> _cacheDir() {
    return _cacheDirFuture ??= () async {
      final base = await getTemporaryDirectory();
      final dir =
          Directory('${base.path}${Platform.pathSeparator}video_thumbs');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }();
  }

  Future<Uint8List?> _readDisk(String key) async {
    try {
      final dir = await _cacheDir();
      final file =
          File('${dir.path}${Platform.pathSeparator}$key.jpg');
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(String key, Uint8List bytes) async {
    try {
      final dir = await _cacheDir();
      final file =
          File('${dir.path}${Platform.pathSeparator}$key.jpg');
      await file.writeAsBytes(bytes, flush: false);
    } catch (_) {
      // 磁盘缓存失败不影响本次显示，下次进入仍可重新抽帧。
    }
  }
}
