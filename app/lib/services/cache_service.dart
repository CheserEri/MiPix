import 'dart:convert';
import 'dart:io';
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
  static const _thumbnailCachePrefix = 'thumb_cache_';
  static const _defaultCacheDuration = Duration(days: 7);
  static const _thumbnailSize = 200;

  late Directory _cacheDir;
  SharedPreferences? _prefs;

  Future<void> init() async {
    _cacheDir = await getTemporaryDirectory();
    _prefs = await SharedPreferences.getInstance();
  }

  Future<void> ensureInitialized() async {
    _prefs ??= await SharedPreferences.getInstance();
    if (!_cacheDir.existsSync()) {
      await _cacheDir.create(recursive: true);
    }
  }

  Future<void> cacheAlbumMediaItems(String serverId, String albumPath, List<MediaItem> items) async {
    await ensureInitialized();
    final key = '$_albumCachePrefix${serverId}_$albumPath';
    final data = {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'items': items.map((e) => e.toJson()).toList(),
    };
    await _prefs!.setString(key, jsonEncode(data));
  }

  Future<List<MediaItem>?> getCachedAlbumMediaItems(String serverId, String albumPath) async {
    await ensureInitialized();
    final key = '$_albumCachePrefix${serverId}_$albumPath';
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

  Future<Uint8List> generateAndCacheThumbnail(String serverId, String imagePath, Uint8List originalBytes) async {
    await ensureInitialized();
    try {
      final image = img.decodeImage(originalBytes);
      if (image == null) return originalBytes;

      final thumbnail = img.copyResize(
        image,
        width: _thumbnailSize,
        height: _thumbnailSize,
        maintainAspect: true,
        interpolation: img.Interpolation.average,
      );

      final thumbnailBytes = img.encodeJpg(thumbnail, quality: 70);
      final safeName = _sanitizePath(imagePath);
      final file = File(path.join(_cacheDir.path, '$_thumbnailCachePrefix${serverId}_$safeName'));
      await file.writeAsBytes(thumbnailBytes);
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
