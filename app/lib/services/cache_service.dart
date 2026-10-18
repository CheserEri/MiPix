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
  /// 缩略图缓存文件名前缀。
  ///
  /// v3：动画格式（GIF/APNG/WebP）缩略图由「GIF→JPEG」改为「取首帧→PNG」，
  /// 旧 v2 的 JPEG 缩略图存在颜色失真，递增前缀使旧缓存整体失效。
  static const _thumbnailCachePrefix = 'thumb3_cache_';

  /// 历史缩略图前缀，仅用于清理/失效，避免旧版本文件长期残留占用空间。
  static const _legacyThumbnailCachePrefixes = ['thumb2_cache_'];

  /// 文件名是否属于缩略图缓存（含历史前缀）。
  static bool _isThumbnailCacheFile(String filePath) =>
      filePath.contains(_thumbnailCachePrefix) ||
      _legacyThumbnailCachePrefixes.any(filePath.contains);
  static const _defaultCacheDuration = Duration(days: 7);
  static const _thumbnailSize = 200;
  static const _cacheLimitKey = 'cache_limit_bytes';

  /// 相册媒体列表缓存版本：排序依据切换为 EXIF 拍摄时间时递增，
  /// 使旧的 mtime 缓存失效并触发一次重新探测。
  ///
  /// v4：修复「上传备份后 SMB 相册不显示新照片」——此前上传成功后从不失效
  /// 缓存，旧的媒体列表会存活满 7 天 TTL。递增版本号可让升级后的首次
  /// 加载强制重新扫描一次（EXIF 时间缓存不带版本，因此不会被重复探测）。
  /// v5：媒体白名单纳入视频扩展名，旧缓存只含图片，需重新扫描才能显示视频。
  static const _albumMediaCacheVersion = 'v5';

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
      filePath.contains(_imageCachePrefix) || _isThumbnailCacheFile(filePath);

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

  /// 相册列表缓存键。
  ///
  /// 必须把 [albumPath] 纳入键：`getAlbums` 支持浏览子目录，只用 serverId
  /// 做键会让子目录错误地命中根目录的缓存列表。
  String _albumsKey(String serverId, String albumPath) =>
      '${_albumCachePrefix}list_${serverId}_${albumPath.isEmpty ? '__root__' : albumPath}';

  Future<void> cacheAlbums(String serverId, String albumPath, List<Album> albums) async {
    await ensureInitialized();
    final key = _albumsKey(serverId, albumPath);
    final data = {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'albums': albums.map((e) => e.toJson()).toList(),
    };
    await _prefs!.setString(key, jsonEncode(data));
  }

  Future<List<Album>?> getCachedAlbums(String serverId, String albumPath) async {
    await ensureInitialized();
    final key = _albumsKey(serverId, albumPath);
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

  /// 失效某台服务器的相册列表缓存（含其所有子目录层级）。
  ///
  /// 上传备份会新建目录、改变相册计数与封面，缓存必须整体作废，
  /// 否则新相册要等满 7 天 TTL 才会出现。
  Future<void> invalidateAlbums(String serverId) async {
    await ensureInitialized();
    final prefix = '${_albumCachePrefix}list_$serverId';
    final keys = _prefs!
        .getKeys()
        .where((k) => k == prefix || k.startsWith('${prefix}_'))
        .toList();
    for (final key in keys) {
      await _prefs!.remove(key);
    }
  }

  /// 失效某个相册目录的媒体列表缓存与 EXIF 拍摄时间缓存。
  ///
  /// 上传后该目录多出新文件、或已有文件被同名覆盖，两者都不能再复用。
  Future<void> invalidateAlbumMediaItems(String serverId, String albumPath) async {
    await ensureInitialized();
    await _prefs!.remove(
      '$_albumCachePrefix${serverId}_${albumPath}_$_albumMediaCacheVersion',
    );
    await _prefs!.remove(_exifDatesKey(serverId, albumPath));
  }

  /// 失效单张图片的原图与缩略图缓存。
  ///
  /// 备份同名覆盖上传时，路径不变但内容已变，若不清理会一直显示旧图。
  Future<void> invalidateImage(String serverId, String imagePath) async {
    await ensureInitialized();
    final safeName = _sanitizePath(imagePath);
    for (final prefix in [_imageCachePrefix, _thumbnailCachePrefix, ..._legacyThumbnailCachePrefixes]) {
      final file = File(path.join(_cacheDir.path, '$prefix${serverId}_$safeName'));
      if (file.existsSync()) {
        try {
          await file.delete();
        } catch (_) {
          // 单个缓存文件删除失败不影响整体失效流程。
        }
      }
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
      // 动画格式（GIF/APNG/WebP）取首帧并编码为 PNG，避免颜色失真（见
      // [_isAnimatedPath] 与 [_generateThumbnailInIsolate]）。
      final animated = _isAnimatedPath(imagePath);
      final thumbnailBytes = await Isolate.run(
        () => _generateThumbnailInIsolate(originalBytes, _thumbnailSize, animated: animated),
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
      f.path.contains(_imageCachePrefix) || _isThumbnailCacheFile(f.path)
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
      f.path.contains(_imageCachePrefix) || _isThumbnailCacheFile(f.path)
    );
    for (final file in files) {
      await file.delete();
    }
  }

  String _sanitizePath(String input) {
    return input.replaceAll(RegExp(r'[^\w\-_\. ]'), '_');
  }
}

/// 是否为动画图像格式。这些格式多为调色板 + 透明像素，
/// 直接走「解码原图 → 缩放 → encodeJpg」会因 JPEG 无 alpha 通道且色度二次
/// 采样，出现透明区变黑、纯色块边缘渗出绿/紫色块等颜色失真。
bool _isAnimatedPath(String imagePath) {
  final lower = imagePath.toLowerCase();
  return lower.endsWith('.gif') || lower.endsWith('.apng') || lower.endsWith('.webp');
}

/// 在独立 Isolate 中解码原图并缩放生成缩略图。
///
/// 必须为顶层函数（不可捕获实例状态），供 [Isolate.run] 调用。
/// 按原始宽高比缩放到 [thumbnailSize] 以内、不补齐成正方形，
/// 避免 copyResize 的 maintainAspect 产生上下黑边。
/// [animated] 为真时只取首帧并编码为 PNG（保留调色板原色与 alpha，规避
/// JPEG 颜色失真），同时避免网格内动图持续出帧空耗 CPU。
/// 解码失败返回空列表，由调用方回退原图。
Uint8List _generateThumbnailInIsolate(
  Uint8List originalBytes,
  int thumbnailSize, {
  bool animated = false,
}) {
  final image = animated
      ? img.decodeImage(originalBytes, frame: 0)
      : img.decodeImage(originalBytes);
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
  return Uint8List.fromList(
    animated ? img.encodePng(thumbnail) : img.encodeJpg(thumbnail, quality: 70),
  );
}
