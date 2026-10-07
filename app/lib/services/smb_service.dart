import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smb_connect/smb_connect.dart';
import 'package:smb_connect/src/exceptions.dart' show SmbException;
import '../models/models.dart';
import 'cache_service.dart';

class _ConnectionWrapper {
  final SmbConnect connect;
  DateTime lastUsed;
  bool isValid;

  _ConnectionWrapper(this.connect, this.lastUsed, {this.isValid = true});
}

class MediaItemPage {
  final List<MediaItem> items;
  final int total;
  final bool hasMore;

  MediaItemPage({required this.items, required this.total, required this.hasMore});
}

class SmbService {
  final Map<String, _ConnectionWrapper> _connections = {};
  static const _maxConnectionAge = Duration(minutes: 1);
  SharedPreferences? _prefs;
  final CacheService _cacheService = CacheService();
  bool _cacheInitialized = false;
  static const int _pageSize = 50;

  Future<void> _ensureCacheInitialized() async {
    if (!_cacheInitialized) {
      await _cacheService.init();
      _cacheInitialized = true;
    }
  }

  Future<SharedPreferences> _getPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  String _normalizePath(String path) {
    if (path.isEmpty) return '';
    final trimmed = path.replaceAll(RegExp(r'^/+|/+$'), '');
    return '/$trimmed';
  }

  String _buildSMBPath(SmbConfig config, String path) {
    final share = config.share.replaceAll(RegExp(r'^/+|/+$'), '');
    final root = config.rootPath.replaceAll(RegExp(r'^/+|/+$'), '');
    final p = path.replaceAll(RegExp(r'^/+|/+$'), '');

    final buffer = StringBuffer('/$share');
    if (root.isNotEmpty) {
      buffer.write('/$root');
    }
    if (p.isNotEmpty) {
      buffer.write('/$p');
    }
    return buffer.toString();
  }

  Future<SmbConnect> _getConnection(SmbConfig config) async {
    final key = '${config.host}:${config.username}';
    final now = DateTime.now();

    if (_connections.containsKey(key)) {
      final wrapper = _connections[key]!;
      if (wrapper.isValid && now.difference(wrapper.lastUsed) < _maxConnectionAge) {
        try {
          await wrapper.connect.listShares();
          wrapper.lastUsed = now;
          return wrapper.connect;
        } catch (_) {
          await wrapper.connect.close();
          _connections.remove(key);
        }
      } else {
        await wrapper.connect.close();
        _connections.remove(key);
      }
    }

    try {
      final connect = await SmbConnect.connectAuth(
        host: config.host,
        domain: config.domain,
        username: config.username,
        password: config.password ?? '',
        onDisconnect: (c) {
          _connections[key]?.isValid = false;
          _connections.remove(key);
        },
      );
      _connections[key] = _ConnectionWrapper(connect, now);
      return connect;
    } catch (e) {
      _connections.remove(key);
      rethrow;
    }
  }

  void _invalidateConnection(String host, String username) {
    final key = '$host:$username';
    _connections[key]?.isValid = false;
    _connections.remove(key);
  }

  Future<bool> testConnection(SmbConfig config) async {
    try {
      final connect = await _getConnection(config);
      await connect.listShares();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> listShares(SmbConfig config) async {
    try {
      final connect = await _getConnection(config);
      final shares = await connect.listShares();
      return shares.map((s) => s.name).toList();
    } catch (_) {
      rethrow;
    }
  }

  Future<List<String>> listDirectories(SmbConfig config, String path) async {
    int retries = 3;
    while (retries-- > 0) {
      try {
        final connect = await _getConnection(config);
        final smbPath = _buildSMBPath(config, path);
        final folder = await connect.file(smbPath);
        final files = await connect.listFiles(folder);
        return files.where((f) => f.isDirectory()).map((f) => f.name).toList();
      } on SmbException catch (e) {
        final msg = e.toString().toLowerCase();
        final isConnectionError = msg.contains('network name') ||
                                   msg.contains('nt_status') ||
                                   msg.contains('not available') ||
                                   msg.contains('disconnected') ||
                                   msg.contains('connection reset') ||
                                   msg.contains('reset by peer');
        if (!isConnectionError) {
          rethrow;
        }
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
      } on Exception {
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
      }
    }
    return [];
  }

  Future<List<MediaItem>> getAllMediaItems(SmbConfig config, {String path = '', bool useCache = true}) async {
    await _ensureCacheInitialized();
    if (useCache) {
      final cached = await _cacheService.getCachedAlbumMediaItems(config.id, path);
      if (cached != null) {
        return cached;
      }
    }

    int retries = 3;
    while (retries-- > 0) {
      try {
        final connect = await _getConnection(config);
        final smbPath = _buildSMBPath(config, path);
        final folder = await connect.file(smbPath);
        final files = await connect.listFiles(folder);

        final items = <MediaItem>[];
        for (final file in files) {
          if (!file.isDirectory() && _isImage(file.name)) {
            items.add(MediaItem(
              id: file.path,
              name: file.name,
              path: '${config.id}/$path/${file.name}',
              source: SmbSource(config.id),
              mimeType: _getMimeType(file.name),
              size: file.size ?? 0,
              width: 0,
              height: 0,
              modifiedAt: file.lastModified != 0
                  ? DateTime.fromMillisecondsSinceEpoch(file.lastModified * 1000)
                  : DateTime.now(),
            ));
          }
        }
        await _cacheService.cacheAlbumMediaItems(config.id, path, items);
        return items;
      } on SmbException catch (e) {
        final msg = e.toString().toLowerCase();
        final isConnectionError = msg.contains('network name') ||
                                   msg.contains('nt_status') ||
                                   msg.contains('not available') ||
                                   msg.contains('disconnected') ||
                                   msg.contains('connection reset') ||
                                   msg.contains('reset by peer');
        if (!isConnectionError) rethrow;
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
      } on Exception {
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
      }
    }
    return [];
  }

  Future<MediaItemPage> getMediaItems(
    SmbConfig config, {
    String path = '',
    int offset = 0,
    int limit = _pageSize,
    bool useCache = true,
  }) async {
    final allItems = await getAllMediaItems(config, path: path, useCache: useCache);

    final total = allItems.length;
    final end = (offset + limit > total) ? total : offset + limit;
    final pageItems = (offset < total) ? allItems.sublist(offset, end) : <MediaItem>[];

    return MediaItemPage(
      items: pageItems,
      total: total,
      hasMore: end < total,
    );
  }

  Future<void> createDirectory(SmbConfig config, String path) async {
    int retries = 3;
    while (retries-- > 0) {
      try {
        final connect = await _getConnection(config);
        final smbPath = _buildSMBPath(config, path);
        await connect.createFolder(smbPath);
        return;
      } on SmbException catch (e) {
        final msg = e.toString().toLowerCase();
        final isConnectionError = msg.contains('network name') ||
                                   msg.contains('nt_status') ||
                                   msg.contains('not available') ||
                                   msg.contains('disconnected') ||
                                   msg.contains('connection reset') ||
                                   msg.contains('reset by peer');
        if (!isConnectionError) rethrow;
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
      } on Exception {
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
      }
    }
  }

  Future<List<Album>> getAlbums(SmbConfig config, {String currentPath = '', bool useCache = true}) async {
    await _ensureCacheInitialized();
    if (useCache) {
      final cached = await _cacheService.getCachedAlbums(config.id);
      if (cached != null) {
        return cached;
      }
    }

    int retries = 3;
    while (retries-- > 0) {
      try {
        final connect = await _getConnection(config);
        final smbPath = _buildSMBPath(config, currentPath);
        final folder = await connect.file(smbPath);
        final files = await connect.listFiles(folder);

        final albums = <Album>[];
        for (final file in files) {
          if (!file.isDirectory()) continue;

          final albumFolderName = file.name;
          final albumFullPath = currentPath.isEmpty
              ? albumFolderName
              : '$currentPath/$albumFolderName';

          try {
            final subFolder = await connect.file(_buildSMBPath(config, albumFullPath));
            final subFiles = await connect.listFiles(subFolder);

            final imageFiles = subFiles.where((f) => !f.isDirectory() && _isImage(f.name)).toList();

            if (imageFiles.isEmpty) {
              continue;
            }

            String? coverPath;
            final prefs = await _getPrefs();
            final customCoverKey = 'custom_cover_${config.id}_$albumFullPath';
            final customCover = prefs.getString(customCoverKey);

            if (customCover != null) {
              try {
                final coverFile = await connect.file(_buildSMBPath(config, customCover));
                coverPath = customCover;
              } catch (_) {
                coverPath = null;
                prefs.remove(customCoverKey);
              }
            }

            if (coverPath == null) {
              SmbFile? latestImage;
              for (final img in imageFiles) {
                if (latestImage == null ||
                    (img.lastModified != null && img.lastModified > (latestImage.lastModified ?? 0))) {
                  latestImage = img;
                }
              }
              coverPath = latestImage != null
                  ? '$albumFullPath/${latestImage!.name}'
                  : null;
            }

            albums.add(Album(
              id: albumFullPath,
              name: albumFolderName,
              source: SmbSource(config.id),
              coverPath: coverPath,
              count: imageFiles.length,
              parentPath: currentPath,
            ));
          } catch (e) {
            continue;
          }
        }

        albums.sort((a, b) => a.name.compareTo(b.name));
        await _cacheService.cacheAlbums(config.id, albums);
        return albums;
      } on SmbException catch (e) {
        final msg = e.toString().toLowerCase();
        final isConnectionError = msg.contains('network name') ||
                                   msg.contains('nt_status') ||
                                   msg.contains('not available') ||
                                   msg.contains('disconnected') ||
                                   msg.contains('connection reset') ||
                                   msg.contains('reset by peer');
        if (!isConnectionError) rethrow;
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
      } on Exception {
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
      }
    }
    return [];
  }

  Future<Uint8List> readFile(SmbConfig config, String remotePath, {bool useCache = true}) async {
    await _ensureCacheInitialized();
    if (useCache) {
      final cachedFile = await _cacheService.getCachedImage(config.id, remotePath);
      if (cachedFile != null) {
        return await cachedFile.readAsBytes();
      }
    }

    int retries = 3;
    while (retries-- > 0) {
      try {
        final connect = await _getConnection(config);
        String fullPath;
        if (remotePath.startsWith('/')) {
          fullPath = _buildSMBPath(config, remotePath.substring(1));
        } else {
          fullPath = _buildSMBPath(config, remotePath);
        }
        final file = await connect.file(fullPath);
        final stream = await connect.openRead(file);
        final bytes = <int>[];
        await for (final chunk in stream) {
          bytes.addAll(chunk);
        }
        final result = Uint8List.fromList(bytes);
        await _cacheService.cacheImage(config.id, remotePath, result);
        return result;
      } on SmbException catch (e) {
        final msg = e.toString().toLowerCase();
        final isConnectionError = msg.contains('network name') ||
                                   msg.contains('nt_status') ||
                                   msg.contains('not available') ||
                                   msg.contains('disconnected') ||
                                   msg.contains('connection reset') ||
                                   msg.contains('reset by peer');
        if (!isConnectionError) rethrow;
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
      } on Exception {
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
      }
    }
    return Uint8List(0);
  }

  Future<Uint8List> readThumbnail(SmbConfig config, String remotePath) async {
    await _ensureCacheInitialized();
    final cachedThumb = await _cacheService.getCachedThumbnail(config.id, remotePath);
    if (cachedThumb != null) {
      return cachedThumb;
    }

    final originalData = await readFile(config, remotePath, useCache: true);
    final thumbnail = await _cacheService.generateAndCacheThumbnail(
      config.id,
      remotePath,
      originalData,
    );
    return thumbnail;
  }

  Future<void> uploadFile(SmbConfig config, String remotePath, Uint8List data, {Function(double)? onProgress}) async {
    int retries = 3;
    while (retries-- > 0) {
      try {
        final connect = await _getConnection(config);
        String fullPath;
        if (remotePath.startsWith('/')) {
          fullPath = _buildSMBPath(config, remotePath.substring(1));
        } else {
          fullPath = _buildSMBPath(config, remotePath);
        }
        final file = await connect.createFile(fullPath);
        final writer = await connect.openWrite(file);

        const chunkSize = 64 * 1024;
        int offset = 0;
        while (offset < data.length) {
          final end = (offset + chunkSize > data.length) ? data.length : offset + chunkSize;
          final chunk = data.sublist(offset, end);
          writer.add(chunk);
          await writer.flush();
          offset = end;

          if (onProgress != null) {
            onProgress(offset / data.length);
          }
        }
        await writer.close();
        return;
      } on SmbException catch (e) {
        final msg = e.toString().toLowerCase();
        final isConnectionError = msg.contains('network name') ||
                                   msg.contains('nt_status') ||
                                   msg.contains('not available') ||
                                   msg.contains('disconnected') ||
                                   msg.contains('connection reset') ||
                                   msg.contains('reset by peer');
        if (!isConnectionError) rethrow;
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
      } on Exception {
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
      }
    }
  }

  Future<void> closeConnection(String serverId) async {
    final keysToRemove = <String>[];
    for (final entry in _connections.entries) {
      if (entry.key.contains(serverId)) {
        keysToRemove.add(entry.key);
      }
    }
    for (final key in keysToRemove) {
      final wrapper = _connections.remove(key);
      if (wrapper != null) {
        await wrapper.connect.close();
      }
    }
  }

  Future<void> closeAllConnections() async {
    for (final wrapper in _connections.values) {
      await wrapper.connect.close();
    }
    _connections.clear();
  }

  Future<void> setCustomCover(String serverId, String albumPath, String coverPath) async {
    final prefs = await _getPrefs();
    final key = 'custom_cover_${serverId}_$albumPath';
    await prefs.setString(key, coverPath);
  }

  Future<String?> getCustomCover(String serverId, String albumPath) async {
    final prefs = await _getPrefs();
    final key = 'custom_cover_${serverId}_$albumPath';
    return prefs.getString(key);
  }

  Future<void> clearCustomCover(String serverId, String albumPath) async {
    final prefs = await _getPrefs();
    final key = 'custom_cover_${serverId}_$albumPath';
    await prefs.remove(key);
  }

  bool _isImage(String name) {
    final ext = name.toLowerCase().split('.').last;
    return ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif'].contains(ext);
  }

  String _getMimeType(String name) {
    final ext = name.toLowerCase().split('.').last;
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'bmp':
        return 'image/bmp';
      case 'webp':
        return 'image/webp';
      case 'heic':
      case 'heif':
        return 'image/heic';
      default:
        return 'application/octet-stream';
    }
  }
}
