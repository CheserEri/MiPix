import 'dart:typed_data';
import 'package:image/image.dart' as img;
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
        return _sortByDateDesc(cached);
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
              // 只保存相对路径：readFile/readThumbnail 会自行拼接 share/rootPath，
              // 若把 serverId 混入路径会拼出无效的 SMB 地址导致图片全部加载失败。
              path: path.isEmpty ? file.name : '$path/${file.name}',
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
        // 按 EXIF 拍摄时间校准排序：优先 DateTimeOriginal，回退文件 mtime。
        await _enrichWithExifDates(config, items);
        await _cacheService.cacheAlbumMediaItems(config.id, path, _sortByDateDesc(items));
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

  /// 按拍摄/修改时间倒序排列（越新的越靠前），并原地返回该列表。
  List<MediaItem> _sortByDateDesc(List<MediaItem> items) {
    items.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return items;
  }

  /// 用 EXIF 拍摄时间校准列表中各项的 modifiedAt（JPEG 才有 EXIF）。
  ///
  /// 仅探测文件头部（与缩略图探测共用同一局部读取），并发数受限以免压垮 SMB。
  /// 任一项失败都静默回退到已有的文件 mtime，不影响列表可用性。
  Future<void> _enrichWithExifDates(SmbConfig config, List<MediaItem> items) async {
    if (items.isEmpty) return;
    const concurrency = 4;
    var cursor = 0;
    while (cursor < items.length) {
      final end = (cursor + concurrency > items.length) ? items.length : cursor + concurrency;
      final results = await Future.wait(
        List.generate(end - cursor, (i) => _probeExifDate(config, items[cursor + i])),
      );
      for (var i = 0; i < results.length; i++) {
        if (results[i] != null) {
          items[cursor + i] = items[cursor + i].copyWith(modifiedAt: results[i]);
        }
      }
      cursor = end;
    }
  }

  /// 读取文件头部并解析 EXIF 拍摄时间；失败/无 EXIF 时返回 null。
  Future<DateTime?> _probeExifDate(SmbConfig config, MediaItem item) async {
    if (!item.mimeType.startsWith('image/jpeg')) return null;
    try {
      final header = await _readHeader(config, item.path, _thumbnailProbeBytes);
      if (header.isEmpty) return null;
      return _parseExifDateTime(header);
    } catch (_) {
      return null;
    }
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

  /// 单文件分块并行下载的连接数，以及启用该策略的文件大小阈值。
  /// 小文件分块反而被连接建立/认证开销拖累，仅对超过阈值的文件启用，
  /// 借此用多连接并发突破单 SMB 连接的吞吐瓶颈。
  static const int _rangeChunkParallelism = 4;
  static const int _rangeParallelThresholdBytes = 512 * 1024;

  Future<Uint8List> readFile(SmbConfig config, String remotePath, {bool useCache = true}) async {
    await _ensureCacheInitialized();
    if (useCache) {
      final cachedFile = await _cacheService.getCachedImage(config.id, remotePath);
      if (cachedFile != null) {
        return await cachedFile.readAsBytes();
      }
    }

    final fullPath = remotePath.startsWith('/')
        ? _buildSMBPath(config, remotePath.substring(1))
        : _buildSMBPath(config, remotePath);

    int retries = 3;
    while (retries-- > 0) {
      try {
        final connect = await _getConnection(config);
        final file = await connect.file(fullPath);
        final size = file.size;

        Uint8List result;
        if (size > 0 && size >= _rangeParallelThresholdBytes) {
          // 大文件：多连接并行分块下载。
          result = await _readFileParallel(config, fullPath, size);
        } else {
          // 小文件或大小未知：单连接顺序读取。
          final stream = await connect.openRead(file);
          final bytes = <int>[];
          await for (final chunk in stream) {
            bytes.addAll(chunk);
          }
          result = Uint8List.fromList(bytes);
        }

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

  /// 用 [_rangeChunkParallelism] 个独立连接并行下载文件各分块后按序拼接。
  Future<Uint8List> _readFileParallel(SmbConfig config, String fullPath, int size) async {
    final chunkSize = (size + _rangeChunkParallelism - 1) ~/ _rangeChunkParallelism;
    final futures = <Future<Uint8List>>[];
    for (int i = 0; i < _rangeChunkParallelism; i++) {
      final start = i * chunkSize;
      if (start >= size) break;
      final end = (start + chunkSize > size) ? size : start + chunkSize;
      futures.add(_readRange(config, fullPath, start, end));
    }
    final parts = await Future.wait(futures);
    final total = parts.fold<int>(0, (s, p) => s + p.length);
    final result = Uint8List(total);
    var offset = 0;
    for (final p in parts) {
      result.setRange(offset, offset + p.length, p);
      offset += p.length;
    }
    return result;
  }

  /// 用全新（不进连接池）的 SMB 连接读取 [start, end) 字节，读完即关闭连接，
  /// 保证各分块互不干扰、可真正并行。
  Future<Uint8List> _readRange(SmbConfig config, String fullPath, int start, int end) async {
    final connect = await SmbConnect.connectAuth(
      host: config.host,
      domain: config.domain,
      username: config.username,
      password: config.password ?? '',
    );
    try {
      final file = await connect.file(fullPath);
      final stream = await connect.openRead(file, start, end);
      final bytes = <int>[];
      await for (final chunk in stream) {
        bytes.addAll(chunk);
        if (bytes.length >= end - start) break;
      }
      return Uint8List.fromList(bytes);
    } finally {
      await connect.close();
    }
  }

  /// 缩略图大小上限。仅读取文件头部这么多字节，用于寻找 EXIF 内嵌缩略图，
  /// 避免为了显示网格而下载整张原图。
  static const int _thumbnailProbeBytes = 256 * 1024;

  /// 进程内缩略图内存缓存：避免列表重建时反复走「内存→磁盘→网络」全流程。
  static final Map<String, Uint8List> _thumbnailMemoryCache = {};
  static const int _thumbnailMemoryCacheLimit = 400;

  /// 同步读取内存中的缩略图（供列表在 initState 中立即展示，避免重新加载闪烁）。
  static Uint8List? peekThumbnail(String serverId, String remotePath) {
    return _thumbnailMemoryCache['$serverId|$remotePath'];
  }

  static void clearThumbnailMemoryCache() => _thumbnailMemoryCache.clear();

  void _putThumbnailMemoryCache(String key, Uint8List bytes) {
    if (bytes.isEmpty) return;
    if (_thumbnailMemoryCache.length >= _thumbnailMemoryCacheLimit) {
      _thumbnailMemoryCache.clear();
    }
    _thumbnailMemoryCache[key] = bytes;
  }

  Future<Uint8List> readThumbnail(SmbConfig config, String remotePath) async {
    final memKey = '${config.id}|$remotePath';
    final inMemory = _thumbnailMemoryCache[memKey];
    if (inMemory != null) return inMemory;

    await _ensureCacheInitialized();
    final cachedThumb = await _cacheService.getCachedThumbnail(config.id, remotePath);
    if (cachedThumb != null) {
      _putThumbnailMemoryCache(memKey, cachedThumb);
      return cachedThumb;
    }

    // 1) 先局部读取文件头，尝试提取 EXIF 内嵌缩略图（通常只有几十 KB）。
    try {
      final header = await _readHeader(config, remotePath, _thumbnailProbeBytes);
      if (header.isNotEmpty) {
        final embedded = _extractEmbeddedThumbnail(header);
        // 校验为可解码的图像后才使用，避免把误匹配的字节当成缩略图缓存。
        if (embedded != null && img.decodeImage(embedded) != null) {
          await _cacheService.cacheThumbnail(config.id, remotePath, embedded);
          _putThumbnailMemoryCache(memKey, embedded);
          return embedded;
        }
      }
    } catch (_) {
      // 局部读取失败时回退到全量读取。
    }

    // 2) 回退：全量读取原图后再缩放生成缩略图（原图本身也会被缓存）。
    final originalData = await readFile(config, remotePath, useCache: true);
    final thumbnail = await _cacheService.generateAndCacheThumbnail(
      config.id,
      remotePath,
      originalData,
    );
    _putThumbnailMemoryCache(memKey, thumbnail);
    return thumbnail;
  }

  /// 只读取文件开头 [maxBytes] 字节，用于探测 EXIF 缩略图。
  Future<Uint8List> _readHeader(SmbConfig config, String remotePath, int maxBytes) async {
    int retries = 3;
    while (retries-- > 0) {
      try {
        final connect = await _getConnection(config);
        final fullPath = remotePath.startsWith('/')
            ? _buildSMBPath(config, remotePath.substring(1))
            : _buildSMBPath(config, remotePath);
        final file = await connect.file(fullPath);
        final size = file.size;
        final end = (size > 0 && size < maxBytes) ? size : maxBytes;
        final stream = await connect.openRead(file, 0, end);
        final bytes = <int>[];
        await for (final chunk in stream) {
          bytes.addAll(chunk);
          if (bytes.length >= end) break;
        }
        return Uint8List.fromList(bytes);
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

  /// 从 JPEG 头部字节中提取 EXIF 内嵌缩略图。
  ///
  /// 严格按 EXIF/TIFF 规范解析，而不是在字节流里盲扫 FFD8…FFD9：
  ///   1. 校验 SOI(FFD8)，顺序遍历 JPEG 段定位以 "Exif\0\0" 开头的 APP1；
  ///   2. 解析 TIFF 头（字节序 II/MM、魔数 0x002A、IFD0 偏移）；
  ///   3. 由 IFD0 的 next-IFD 指针跳到 IFD1；
  ///   4. 读取 IFD1 中的 JPEGInterchangeFormat(0x0201)/Length(0x0202) 截取缩略图。
  /// 相比盲扫可避免 XMP/图像数据中偶然出现的 FFD8 误匹配，
  /// 也避免因首个误匹配失败而错过真正的内嵌缩略图。无内嵌缩略图时返回 null。
  Uint8List? _extractEmbeddedThumbnail(Uint8List data) {
    if (data.length < 8 || data[0] != 0xFF || data[1] != 0xD8) return null;

    // 1) 定位 Exif APP1 段
    int? tiffStart;
    int pos = 2;
    while (pos + 4 <= data.length) {
      if (data[pos] != 0xFF) {
        pos++;
        continue;
      }
      final marker = data[pos + 1];
      // SOS / EOI：之后为压缩图像数据，元数据段已结束
      if (marker == 0xDA || marker == 0xD9) break;
      // 无长度字段的独立标记（RST/TEM 等）
      if (marker < 0x02 || (marker >= 0xD0 && marker <= 0xD8)) {
        pos += 2;
        continue;
      }
      final segLen = (data[pos + 2] << 8) | data[pos + 3];
      if (segLen < 2) break;
      // 先判断是否为 Exif APP1：即使该段超出读取缓冲区（被截断），
      // 只要 TIFF 头在缓冲区内就仍可继续解析（后续访问均有越界保护）。
      final isExif = marker == 0xE1 &&
          segLen >= 8 &&
          pos + 10 <= data.length &&
          data[pos + 4] == 0x45 && // 'E'
          data[pos + 5] == 0x78 && // 'x'
          data[pos + 6] == 0x69 && // 'i'
          data[pos + 7] == 0x66 && // 'f'
          data[pos + 8] == 0x00 &&
          data[pos + 9] == 0x00;
      if (isExif) {
        tiffStart = pos + 10;
        break;
      }
      if (pos + 2 + segLen > data.length) break;
      pos += 2 + segLen;
    }
    if (tiffStart == null || tiffStart + 8 > data.length) return null;

    // 2) 解析 TIFF 头
    final b0 = data[tiffStart];
    final b1 = data[tiffStart + 1];
    final bool littleEndian;
    if (b0 == 0x49 && b1 == 0x49) {
      littleEndian = true; // 'II'
    } else if (b0 == 0x4D && b1 == 0x4D) {
      littleEndian = false; // 'MM'
    } else {
      return null;
    }

    int u16(int off) {
      if (off < 0 || off + 2 > data.length) return -1;
      return littleEndian
          ? data[off] | (data[off + 1] << 8)
          : (data[off] << 8) | data[off + 1];
    }

    int u32(int off) {
      if (off < 0 || off + 4 > data.length) return -1;
      return littleEndian
          ? data[off] |
              (data[off + 1] << 8) |
              (data[off + 2] << 16) |
              (data[off + 3] << 24)
          : (data[off] << 24) |
              (data[off + 1] << 16) |
              (data[off + 2] << 8) |
              data[off + 3];
    }

    if (u16(tiffStart + 2) != 0x002A) return null;
    final ifd0Offset = u32(tiffStart + 4);
    if (ifd0Offset < 8) return null;

    // 3) 由 IFD0 的 next-IFD 指针跳到 IFD1
    final ifd0Pos = tiffStart + ifd0Offset;
    final ifd0Count = u16(ifd0Pos);
    if (ifd0Count < 0) return null;
    final ifd1Offset = u32(ifd0Pos + 2 + ifd0Count * 12);
    if (ifd1Offset <= 0) return null;

    // 4) 在 IFD1 中读取内嵌缩略图的偏移与长度
    final ifd1Pos = tiffStart + ifd1Offset;
    final ifd1Count = u16(ifd1Pos);
    if (ifd1Count <= 0) return null;
    int? thumbOffset;
    int? thumbLength;
    for (int i = 0; i < ifd1Count; i++) {
      final entry = ifd1Pos + 2 + i * 12;
      if (entry + 12 > data.length) break;
      final tag = u16(entry);
      if (tag == 0x0201) {
        thumbOffset = u32(entry + 8);
      } else if (tag == 0x0202) {
        thumbLength = u32(entry + 8);
      }
    }
    if (thumbOffset == null || thumbLength == null) return null;
    if (thumbOffset <= 0 || thumbLength <= 0) return null;

    final start = tiffStart + thumbOffset;
    final end = start + thumbLength;
    if (end > data.length || end - start < 1024) return null;
    // 内嵌缩略图必须是独立 JPEG
    if (data[start] != 0xFF || data[start + 1] != 0xD8) return null;
    return data.sublist(start, end);
  }

  /// 从 JPEG 头部解析 EXIF 拍摄时间。
  ///
  /// 优先取 Exif IFD 的 DateTimeOriginal(0x9003)，回退 IFD0 的 DateTime(0x0132)。
  /// 格式为 ASCII "YYYY:MM:DD HH:MM:SS"。解析失败返回 null（调用方回退文件 mtime）。
  DateTime? _parseExifDateTime(Uint8List data) {
    if (data.length < 8 || data[0] != 0xFF || data[1] != 0xD8) return null;

    int? tiffStart;
    int pos = 2;
    while (pos + 4 <= data.length) {
      if (data[pos] != 0xFF) {
        pos++;
        continue;
      }
      final marker = data[pos + 1];
      if (marker == 0xDA || marker == 0xD9) break;
      if (marker < 0x02 || (marker >= 0xD0 && marker <= 0xD8)) {
        pos += 2;
        continue;
      }
      final segLen = (data[pos + 2] << 8) | data[pos + 3];
      if (segLen < 2) break;
      final isExif = marker == 0xE1 &&
          segLen >= 8 &&
          pos + 10 <= data.length &&
          data[pos + 4] == 0x45 &&
          data[pos + 5] == 0x78 &&
          data[pos + 6] == 0x69 &&
          data[pos + 7] == 0x66 &&
          data[pos + 8] == 0x00 &&
          data[pos + 9] == 0x00;
      if (isExif) {
        tiffStart = pos + 10;
        break;
      }
      if (pos + 2 + segLen > data.length) break;
      pos += 2 + segLen;
    }
    if (tiffStart == null || tiffStart + 8 > data.length) return null;

    final b0 = data[tiffStart];
    final b1 = data[tiffStart + 1];
    final bool littleEndian;
    if (b0 == 0x49 && b1 == 0x49) {
      littleEndian = true;
    } else if (b0 == 0x4D && b1 == 0x4D) {
      littleEndian = false;
    } else {
      return null;
    }

    int u16(int off) {
      if (off < 0 || off + 2 > data.length) return -1;
      return littleEndian
          ? data[off] | (data[off + 1] << 8)
          : (data[off] << 8) | data[off + 1];
    }

    int u32(int off) {
      if (off < 0 || off + 4 > data.length) return -1;
      return littleEndian
          ? data[off] |
              (data[off + 1] << 8) |
              (data[off + 2] << 16) |
              (data[off + 3] << 24)
          : (data[off] << 24) |
              (data[off + 1] << 16) |
              (data[off + 2] << 8) |
              data[off + 3];
    }

    if (u16(tiffStart + 2) != 0x002A) return null;
    final ifd0Offset = u32(tiffStart + 4);
    if (ifd0Offset < 8) return null;

    String? readAscii(int ifdPos, int wantedTag) {
      final count = u16(ifdPos);
      if (count <= 0) return null;
      for (int i = 0; i < count; i++) {
        final entry = ifdPos + 2 + i * 12;
        if (entry + 12 > data.length) break;
        if (u16(entry) != wantedTag) continue;
        final type = u16(entry + 2);
        final n = u32(entry + 4);
        if (type != 2 || n <= 0) return null; // ASCII
        int valuePos;
        if (n <= 4) {
          valuePos = entry + 8;
        } else {
          final off = u32(entry + 8);
          if (off < 0) return null;
          valuePos = tiffStart! + off;
        }
        if (valuePos + n > data.length) return null;
        return String.fromCharCodes(
          data.sublist(valuePos, valuePos + n),
        ).trim();
      }
      return null;
    }

    final ifd0Pos = tiffStart + ifd0Offset;
    // DateTimeOriginal 位于 Exif IFD，其在 IFD0 中的指针标签为 0x8769。
    final ifd0Count = u16(ifd0Pos);
    int? exifIfdOffset;
    for (int i = 0; i < ifd0Count; i++) {
      final entry = ifd0Pos + 2 + i * 12;
      if (entry + 12 > data.length) break;
      if (u16(entry) == 0x8769) {
        exifIfdOffset = u32(entry + 8);
        break;
      }
    }
    String? raw;
    if (exifIfdOffset != null && exifIfdOffset > 0) {
      raw = readAscii(tiffStart + exifIfdOffset, 0x9003); // DateTimeOriginal
    }
    raw ??= readAscii(ifd0Pos, 0x0132); // DateTime 回退

    if (raw == null) return null;
    // "YYYY:MM:DD HH:MM:SS"
    try {
      final parts = raw.split(RegExp(r'[: ]'));
      if (parts.length < 6) return null;
      return DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
        int.parse(parts[3]),
        int.parse(parts[4]),
        int.parse(parts[5]),
      );
    } catch (_) {
      return null;
    }
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
