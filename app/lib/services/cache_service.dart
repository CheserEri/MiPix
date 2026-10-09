import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

class CacheService {
  static const _cacheMetadataKey = 'cache_metadata';
  static const _albumCachePrefix = 'album_cache_';
  static const _imageCachePrefix = 'image_cache_';
  static const _thumbnailCachePrefix = 'thumb2_cache_';
  static const _defaultCacheDuration = Duration(days: 7);
  static const _thumbnailSize = 200;
  static const _cacheLimitKey = 'cache_limit_bytes';

  /// 相册媒体列表缓存版本：排序依据切换为 EXIF 拍摄时间时递增，
  /// 使旧的 mtime 缓存失效并触发一次重新探测。
  static const _albumMediaCacheVersion = 'v3';

  /// 默认缓存上限：500 MB。
  static const int defaultCacheLimitBytes = 500 * 1024 * 1024;

  Directory? _cacheDirRef;
  Directory get _cacheDir => _cacheDirRef!;
  SharedPreferences? _prefs;
  bool _initialized = false;

  Future<void> init() => ensureInitialized();

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _prefs ??= await SharedPreferences.getInstance();
    // 使用 Application Support 目录（应用私有、不会被系统随意清理），
    // 保证缩略图/原图缓存在应用重启后依然可用。
    final dir = await getApplicationSupportDirectory();
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _cacheDirRef = dir;
    _initialized = true;
  }

  /// 当前缓存占用（原图 + 缩略图，字节）。
  Future<int> getCacheSize() async {
    await ensureInitialized();
    var total = 0;
    for (final entity in _cacheDir.listSync()) {
      if (entity is File && _isCacheFile(entity.path)) {
        total += await entity.length();
      }
    }
    return total;
  }

  Future<int> getCacheLimit() async {
    await ensureInitialized();
    return _prefs!.getInt(_cacheLimitKey) ?? defaultCacheLimitBytes;
  }

  Future<void> setCacheLimit(int bytes) async {
    await ensureInitialized();
    await _prefs!.setInt(_cacheLimitKey, bytes);
    await enforceCacheLimit();
  }

  bool _isCacheFile(String filePath) =>
      filePath.contains(_imageCachePrefix) || filePath.contains(_thumbnailCachePrefix);

  /// 超出上限时按「最久未修改优先」删除缓存文件。
  /// 缩略图体积很小、命中收益高，优先淘汰原图。
  Future<void> enforceCacheLimit() async {
    await ensureInitialized();
    final limit = await getCacheLimit();
    final files = _cacheDir
        .listSync()
        .whereType<File>()
        .where((f) => _isCacheFile(f.path))
        .toList();
    if (files.isEmpty) return;

    final entries = <MapEntry<File, int>>[];
    var total = 0;
    for (final file in files) {
      final length = await file.length();
      total += length;
      entries.add(MapEntry(file, length));
    }
    if (total <= limit) return;

    // 先淘汰原图（大且可从 SMB 重新获取），再淘汰缩略图；同类按最后修改时间升序。
    entries.sort((a, b) {
      final aOriginal = a.key.path.contains(_imageCachePrefix);
      final bOriginal = b.key.path.contains(_imageCachePrefix);
      if (aOriginal != bOriginal) return aOriginal ? -1 : 1;
      return a.key.lastModifiedSync().compareTo(b.key.lastModifiedSync());
    });

    for (final entry in entries) {
      if (total <= limit) break;
      try {
        await entry.key.delete();
        total -= entry.value;
      } catch (_) {
        // 忽略单个文件删除失败，继续清理其余文件。
      }
    }
  }

  Future<void> cacheAlbumMediaItems(String serverId, String albumPath, List<MediaItem> items) async {
    await ensureInitialized();
    final key = '$_albumCachePrefix${serverId}_${albumPath}_$_albumMediaCacheVersion';
    final data = {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'items': items.map((e) => e.toJson()).toList(),
    };
    await _prefs!.setString(key, jsonEncode(data));
  }

  Future<List<MediaItem>?> getCachedAlbumMediaItems(String serverId, String albumPath) async {
    await ensureInitialized();
    final key = '$_albumCachePrefix${serverId}_${albumPath}_$_albumMediaCacheVersion';
    final data = _prefs!.getString(key);
    if (data == null) return null;

    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      final timestamp = json['timestamp'] as int;
      if (DateTime.now().millisecondsSinceEpoch - timestamp > _defaultCacheDuration.inMilliseconds) {
        await _prefs!.remove(key);
        return null;
      }
      final itemsJson = json['items'] as List;
      return itemsJson.map((e) => MediaItem.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return null;
    }
  }

  /// EXIF 拍摄时间缓存：记录「文件路径 → 拍摄时间(毫秒)」。
  ///
  /// 大相册全量探测 EXIF 耗时较久，扫描过程中分批增量写入，
  /// 若中途退出，下次进入可跳过已探测的文件继续，避免重复劳动。
  /// 键前缀复用 `album_cache_`，可被既有的过期清理逻辑一并回收。
  String _exifDatesKey(String serverId, String albumPath) =>
      '${_albumCachePrefix}exif_${serverId}_$albumPath';

  Future<Map<String, int>> getCachedExifDates(String serverId, String albumPath) async {
    await ensureInitialized();
    final key = _exifDatesKey(serverId, albumPath);
    final data = _prefs!.getString(key);
    if (data == null) return <String, int>{};
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      final timestamp = json['timestamp'] as int;
      if (DateTime.now().millisecondsSinceEpoch - timestamp > _defaultCacheDuration.inMilliseconds) {
        await _prefs!.remove(key);
        return <String, int>{};
      }
      final dates = json['dates'] as Map<String, dynamic>;
      return dates.map((k, v) => MapEntry(k, v as int));
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> cacheExifDates(String serverId, String albumPath, Map<String, int> dates) async {
    await ensureInitialized();
    final key = _exifDatesKey(serverId, albumPath);
    final data = {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'dates': dates,
    };
    await _prefs!.setString(key, jsonEncode(data));
  }

  Future<void> cacheAlbums(String serverId, List<Album> albums) async {
    await ensureInitialized();
    final key = '${_albumCachePrefix}list_$serverId';
    final data = {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'albums': albums.map((e) => e.toJson()).toList(),
    };
    await _prefs!.setString(key, jsonEncode(data));
  }

  Future<List<Album>?> getCachedAlbums(String serverId) async {
    await ensureInitialized();
    final key = '${_albumCachePrefix}list_$serverId';
    final data = _prefs!.getString(key);
    if (data == null) return null;

    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      final timestamp = json['timestamp'] as int;
      if (DateTime.now().millisecondsSinceEpoch - timestamp > _defaultCacheDuration.inMilliseconds) {
        await _prefs!.remove(key);
        return null;
      }
      final albumsJson = json['albums'] as List;
      return albumsJson.map((e) => Album.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return null;
    }
  }

  Future<File?> cacheImage(String serverId, String imagePath, Uint8List bytes) async {
    await ensureInitialized();
    final safeName = _sanitizePath(imagePath);
    final file = File(path.join(_cacheDir.path, '$_imageCachePrefix${serverId}_$safeName'));
    await file.writeAsBytes(bytes);
    await _maybeEnforceLimit();
    return file;
  }

  Future<File?> getCachedImage(String serverId, String imagePath) async {
    await ensureInitialized();
    final safeName = _sanitizePath(imagePath);
    final file = File(path.join(_cacheDir.path, '$_imageCachePrefix${serverId}_$safeName'));
    if (!file.existsSync()) return null;
    final stat = await file.stat();
    if (DateTime.now().difference(stat.modified) > _defaultCacheDuration) {
      await file.delete();
      return null;
    }
    return file;
  }

  Future<Uint8List?> getCachedThumbnail(String serverId, String imagePath) async {
    await ensureInitialized();
    final safeName = _sanitizePath(imagePath);
    final file = File(path.join(_cacheDir.path, '$_thumbnailCachePrefix${serverId}_$safeName'));
    if (!file.existsSync()) return null;
    final stat = await file.stat();
    if (DateTime.now().difference(stat.modified) > _defaultCacheDuration) {
      await file.delete();
      return null;
    }
    return await file.readAsBytes();
  }

  Future<void> cacheThumbnail(String serverId, String imagePath, Uint8List bytes) async {
    await ensureInitialized();
    final safeName = _sanitizePath(imagePath);
    final file = File(path.join(_cacheDir.path, '$_thumbnailCachePrefix${serverId}_$safeName'));
    await file.writeAsBytes(bytes);
    await _maybeEnforceLimit();
  }

  /// 每写入若干次才检查一次上限，避免批量下载时反复扫描目录。
  int _writesSinceLimitCheck = 0;
  static const _limitCheckInterval = 20;

  Future<void> _maybeEnforceLimit() async {
    _writesSinceLimitCheck++;
    if (_writesSinceLimitCheck < _limitCheckInterval) return;
    _writesSinceLimitCheck = 0;
    await enforceCacheLimit();
  }

  Future<Uint8List> generateAndCacheThumbnail(String serverId, String imagePath, Uint8List originalBytes) async {
    await ensureInitialized();
    try {
      // 解码+缩放+编码是 CPU 密集操作，在主线程执行会造成网格滚动掉帧。
      // 整体搬到独立 Isolate，主线程只收发字节，避免卡顿。
      final thumbnailBytes = await Isolate.run(
        () => _generateThumbnailInIsolate(originalBytes, _thumbnailSize),
      );
      // 空列表表示解码失败，回退原图。
      if (thumbnailBytes.isEmpty) return originalBytes;

      final safeName = _sanitizePath(imagePath);
      final file = File(path.join(_cacheDir.path, '$_thumbnailCachePrefix${serverId}_$safeName'));
      await file.writeAsBytes(thumbnailBytes);
      await _maybeEnforceLimit();
      return thumbnailBytes;
    } catch (_) {
      return originalBytes;
    }
  }

  Future<void> clearExpiredCache() async {
    await ensureInitialized();
    final keys = _prefs!.getKeys().where((k) => k.startsWith(_albumCachePrefix));
    for (final key in keys) {
      final data = _prefs!.getString(key);
      if (data != null) {
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final timestamp = json['timestamp'] as int;
          if (DateTime.now().millisecondsSinceEpoch - timestamp > _defaultCacheDuration.inMilliseconds) {
            await _prefs!.remove(key);
          }
        } catch (_) {
          await _prefs!.remove(key);
        }
      }
    }
    final files = _cacheDir.listSync().where((f) => 
      f.path.contains(_imageCachePrefix) || f.path.contains(_thumbnailCachePrefix)
    );
    for (final file in files) {
      final stat = await file.stat();
      if (DateTime.now().difference(stat.modified) > _defaultCacheDuration) {
        await file.delete();
      }
    }
  }

  Future<void> clearAllCache() async {
    await ensureInitialized();
    final keys = _prefs!.getKeys().where((k) => k.startsWith(_albumCachePrefix) || k.startsWith(_cacheMetadataKey));
    for (final key in keys) {
      await _prefs!.remove(key);
    }
    final files = _cacheDir.listSync().where((f) => 
      f.path.contains(_imageCachePrefix) || f.path.contains(_thumbnailCachePrefix)
    );
    for (final file in files) {
      await file.delete();
    }
  }

  String _sanitizePath(String input) {
    return input.replaceAll(RegExp(r'[^\w\-_\. ]'), '_');
  }
}

/// 在独立 Isolate 中解码原图并缩放生成缩略图 JPEG。
///
/// 必须为顶层函数（不可捕获实例状态），供 [Isolate.run] 调用。
/// 按原始宽高比缩放到 [thumbnailSize] 以内、不补齐成正方形，
/// 避免 copyResize 的 maintainAspect 产生上下黑边。
/// 解码失败返回空列表，由调用方回退原图。
Uint8List _generateThumbnailInIsolate(Uint8List originalBytes, int thumbnailSize) {
  final image = img.decodeImage(originalBytes);
  if (image == null) return Uint8List(0);

  final srcW = image.width;
  final srcH = image.height;
  final int targetW;
  final int targetH;
  if (srcW >= srcH) {
    targetW = thumbnailSize;
    targetH = (srcH * thumbnailSize / srcW).round().clamp(1, thumbnailSize);
  } else {
    targetH = thumbnailSize;
    targetW = (srcW * thumbnailSize / srcH).round().clamp(1, thumbnailSize);
  }

  final thumbnail = img.copyResize(
    image,
    width: targetW,
    height: targetH,
    interpolation: img.Interpolation.average,
  );
  return Uint8List.fromList(img.encodeJpg(thumbnail, quality: 70));
}
