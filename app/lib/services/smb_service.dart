import 'dart:async';
import 'dart:io';
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

/// 相册扫描进度回调：`done` 为已处理项数，`total` 为总项数。
typedef ScanProgressCallback = void Function(int done, int total);

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
        // 不再每次调用都做一次 listShares() 探活：该往返在批量扫描（如逐文件读头）
        // 时会被放大成主要开销。连接失效由各调用方的重试与 _invalidateConnection 兜底。
        wrapper.lastUsed = now;
        return wrapper.connect;
      }
      await wrapper.connect.close();
      _connections.remove(key);
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

  /// 列出远端目录下所有文件的「文件名 → 大小」，供上传前跨设备去重。
  ///
  /// 目录不存在 / 无权限 / 网络异常时返回空表，调用方据此视为「远端还没有」，
  /// 不会因去重探测失败而阻断备份。
  Future<Map<String, int>> listFilesWithSize(SmbConfig config, String path) async {
    try {
      final connect = await _getConnection(config);
      final smbPath = _buildSMBPath(config, path);
      final folder = await connect.file(smbPath);
      final files = await connect.listFiles(folder);
      return {
        for (final f in files)
          if (!f.isDirectory()) f.name: f.size,
      };
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<List<MediaItem>> getAllMediaItems(
    SmbConfig config, {
    String path = '',
    bool useCache = true,
    ScanProgressCallback? onProgress,
  }) async {
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
          if (!file.isDirectory() && _isMedia(file.name)) {
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
        await _enrichWithExifDates(config, path, items, onProgress: onProgress);
        final sorted = _sortByDateDesc(items);
        await _cacheService.cacheAlbumMediaItems(config.id, path, sorted);
        return sorted;
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

  /// 扫描时同时建立的独立连接数。同一条 SMB 连接上的读操作无法真正并行，
  /// 必须用多条连接才能把逐文件读头的耗时分摊开（NAS 连接数上限较低时会自动降级）。
  static const int _exifScanConnections = 8;

  /// 扫描进度落盘间隔（每处理这么多项写一次 EXIF 缓存），
  /// 兼顾中断续传与避免高频序列化整个映射表。
  static const int _exifPersistEvery = 256;

  /// 用 EXIF 拍摄时间校准列表中各项的 modifiedAt（仅 JPEG 才有 EXIF）。
  ///
  /// - 已缓存的探测结果直接复用，只处理尚未知的文件；
  /// - 用一组独立连接并行读文件头，真正分摊网络耗时；
  /// - 每处理若干项即增量写入缓存，扫描被中断后下次可续传；
  /// - 通过 [onProgress] 汇报进度，供 UI 显示进度条。
  /// 任一项失败都静默回退到已有的文件 mtime，不影响列表可用性。
  Future<void> _enrichWithExifDates(
    SmbConfig config,
    String albumPath,
    List<MediaItem> items, {
    ScanProgressCallback? onProgress,
  }) async {
    if (items.isEmpty) return;
    final total = items.length;

    final dates = await _cacheService.getCachedExifDates(config.id, albumPath);

    // 先应用缓存结果，并筛出仍需探测的项；非 JPEG 无 EXIF，直接算作已处理。
    final needProbe = <int>[];
    var done = 0;
    for (var i = 0; i < items.length; i++) {
      final ms = dates[items[i].path];
      if (ms != null) {
        items[i] = items[i].copyWith(modifiedAt: DateTime.fromMillisecondsSinceEpoch(ms));
        done++;
      } else if (items[i].mimeType.startsWith('image/jpeg')) {
        needProbe.add(i);
      } else {
        done++;
      }
    }
    onProgress?.call(done, total);
    if (needProbe.isEmpty) return;

    // 为本次扫描建立一批独立连接。若 NAS 限制并发连接数，则用已建立的数量降级运行。
    final connections = <SmbConnect>[];
    try {
      for (var i = 0; i < _exifScanConnections; i++) {
        try {
          connections.add(await SmbConnect.connectAuth(
            host: config.host,
            domain: config.domain,
            username: config.username,
            password: config.password ?? '',
          ));
        } catch (_) {
          break;
        }
      }
      // 一条连接都建不起来时（网络异常等）直接放弃探测，列表仍按 mtime 展示。
      if (connections.isEmpty) return;

      var next = 0;
      var sincePersist = 0;

      Future<void> worker(SmbConnect conn) async {
        while (true) {
          // 无 await 间隔，索引分配在事件循环中天然原子，无并发竞争。
          final local = next;
          if (local >= needProbe.length) break;
          next = local + 1;

          final idx = needProbe[local];
          try {
            final date = await _probeExifDateVia(conn, config, items[idx]);
            if (date != null) {
              items[idx] = items[idx].copyWith(modifiedAt: date);
              dates[items[idx].path] = date.millisecondsSinceEpoch;
            }
          } catch (_) {
            // 单个文件探测失败静默回退文件 mtime，不中断整体扫描。
          }

          done++;
          onProgress?.call(done, total);
          if (++sincePersist >= _exifPersistEvery) {
            sincePersist = 0;
            await _cacheService.cacheExifDates(config.id, albumPath, dates);
          }
        }
      }

      await Future.wait(connections.map(worker));
      await _cacheService.cacheExifDates(config.id, albumPath, dates);
    } finally {
      for (final conn in connections) {
        try {
          await conn.close();
        } catch (_) {
          // 关闭失败无需处理，连接已随扫描结束废弃。
        }
      }
    }
  }

  /// 用指定连接读取文件头部并解析 EXIF 拍摄时间；失败/无 EXIF 时返回 null。
  Future<DateTime?> _probeExifDateVia(SmbConnect connect, SmbConfig config, MediaItem item) async {
    if (!item.mimeType.startsWith('image/jpeg')) return null;
    final header = await _readHeaderVia(connect, config, item.path, _exifDateProbeBytes);
    if (header.isEmpty) return null;
    return _parseExifDateTime(header);
  }

  Future<MediaItemPage> getMediaItems(
    SmbConfig config, {
    String path = '',
    int offset = 0,
    int limit = _pageSize,
    bool useCache = true,
    ScanProgressCallback? onProgress,
  }) async {
    final allItems = await getAllMediaItems(
      config,
      path: path,
      useCache: useCache,
      onProgress: onProgress,
    );

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

  /// 递归创建远端目录（已存在时忽略），供备份时复刻手机相册目录结构。
  ///
  /// 逐级创建 `DCIM`、`DCIM/Camera`，保证 [uploadFile] 的目标父目录已存在。
  /// 单级创建失败（多半是目录已存在）不抛出，真正的写入失败会在上传阶段暴露。
  Future<void> ensureRemoteDirectory(SmbConfig config, String path) async {
    final normalized = path.replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) return;
    final parts = normalized.split('/');
    var current = '';
    for (final part in parts) {
      current = current.isEmpty ? part : '$current/$part';
      try {
        await createDirectory(config, current);
      } catch (_) {
        // 目录已存在等情况忽略；若确实无权限，上传时会失败并计入任务错误。
      }
    }
  }

  /// 递归扫描相册目录的最大深度。
  ///
  /// 现在备份是扁平的（直接用手机相册名在根目录下建文件夹），新相册都在
  /// 第 1 层。但根目录里可能残留旧版按手机绝对路径复刻的深层结构
  /// （如 `Pictures/Gallery/owner/生活`），保留一个递归上限既能扫到这些
  /// 历史目录，又可避免误入更深的归档目录导致扫描爆炸。
  static const int _maxAlbumDepth = 8;

  /// 读取 [currentPath] 下的相册列表。
  ///
  /// [refresh] 为 true 时跳过缓存读取、强制重新扫描（仍会回写缓存），
  /// 供界面的「刷新」按钮使用——否则刷新只会重新命中同一份磁盘缓存。
  Future<List<Album>> getAlbums(
    SmbConfig config, {
    String currentPath = '',
    bool useCache = true,
    bool refresh = false,
  }) async {
    await _ensureCacheInitialized();
    if (useCache && !refresh) {
      final cached = await _cacheService.getCachedAlbums(config.id, currentPath);
      if (cached != null) {
        return cached;
      }
    }

    int retries = 3;
    while (retries-- > 0) {
      try {
        final connect = await _getConnection(config);
        final albums = <Album>[];
        await _collectAlbums(
          connect,
          config,
          basePath: currentPath,
          relative: '',
          depth: 0,
          out: albums,
        );

        albums.sort((a, b) => a.name.compareTo(b.name));
        await _cacheService.cacheAlbums(config.id, currentPath, albums);
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

  /// 递归收集 [basePath] 下所有「直接包含媒体文件」的目录作为相册。
  ///
  /// 之前只扫描一层，导致 `DCIM/Camera`、`Pictures/Weixin` 这类
  /// 二级目录永远不会出现在相册列表里。现在按深度递归，任一目录只要
  /// 直接含有图片或视频就算作相册；只含子目录的目录继续向下查找。
  Future<void> _collectAlbums(
    SmbConnect connect,
    SmbConfig config, {
    required String basePath,
    required String relative,
    required int depth,
    required List<Album> out,
  }) async {
    if (depth > _maxAlbumDepth) return;

    final currentPath = _joinRemotePath(basePath, relative);
    final folder = await connect.file(_buildSMBPath(config, currentPath));
    final files = await connect.listFiles(folder);

    final mediaFiles =
        files.where((f) => !f.isDirectory() && _isMedia(f.name)).toList();
    // 相册封面只能是图片：视频无法直接解码成缩略图。
    final coverCandidates = mediaFiles.where((f) => _isImage(f.name)).toList();

    // basePath 自身是当前浏览位置，不作为它自己的子相册。
    if (mediaFiles.isNotEmpty && relative.isNotEmpty) {
      try {
        out.add(Album(
          id: currentPath,
          name: relative.split('/').last,
          source: SmbSource(config.id),
          coverPath: await _resolveAlbumCover(
            connect,
            config,
            currentPath,
            coverCandidates,
          ),
          count: mediaFiles.length,
          parentPath: _parentOfRemotePath(currentPath),
        ));
      } catch (_) {
        // 单张封面读取失败不影响该相册入列。
      }
    }

    if (depth == _maxAlbumDepth) return;
    for (final dir in files.where((f) => f.isDirectory())) {
      if (_isIgnoredDirectory(dir.name)) continue;
      final childRelative = relative.isEmpty ? dir.name : '$relative/${dir.name}';
      try {
        await _collectAlbums(
          connect,
          config,
          basePath: basePath,
          relative: childRelative,
          depth: depth + 1,
          out: out,
        );
      } catch (_) {
        // 单个子目录读取失败（无权限等）不阻断其余目录的扫描。
      }
    }
  }

  /// 相册封面：优先使用用户自定义封面，否则取目录内最后修改时间最新的图片。
  Future<String?> _resolveAlbumCover(
    SmbConnect connect,
    SmbConfig config,
    String albumPath,
    List<SmbFile> imageFiles,
  ) async {
    final prefs = await _getPrefs();
    final customCoverKey = 'custom_cover_${config.id}_$albumPath';
    final customCover = prefs.getString(customCoverKey);

    if (customCover != null) {
      try {
        await connect.file(_buildSMBPath(config, customCover));
        return customCover;
      } catch (_) {
        await prefs.remove(customCoverKey);
      }
    }

    SmbFile? latest;
    for (final image in imageFiles) {
      if (latest == null ||
          (image.lastModified != null &&
              image.lastModified > (latest.lastModified ?? 0))) {
        latest = image;
      }
    }
    return latest == null ? null : '$albumPath/${latest.name}';
  }

  /// 拼接远端相对路径，任一段为空时自动省略分隔符。
  String _joinRemotePath(String base, String child) {
    if (base.isEmpty) return child;
    if (child.isEmpty) return base;
    return '$base/$child';
  }

  /// 取相对路径的父目录，位于顶层时返回空串。
  String _parentOfRemotePath(String path) {
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '' : path.substring(0, slash);
  }

  /// 扫描时跳过的系统目录（Windows 回收站、卷信息、macOS 元数据等）。
  bool _isIgnoredDirectory(String name) {
    if (name.startsWith('.')) return true;
    final lower = name.toLowerCase();
    return lower == '\$recycle.bin' ||
        lower == 'system volume information' ||
        lower == 'lost+found' ||
        lower == 'node_modules';
  }

  /// 上传成功后批量失效相关缓存。
  ///
  /// 上传会新建目录（新相册）、改变相册计数与封面、并可能同名覆盖已有文件。
  /// 此前这些操作完全不触碰缓存，导致新相册要等满 7 天 TTL 才出现——
  /// 这正是「上传备份后 SMB 相册不显示更新内容」的根因。
  Future<void> invalidateAfterUploads(
    SmbConfig config,
    Iterable<String> uploadedRemotePaths,
  ) async {
    await _ensureCacheInitialized();

    final dirs = <String>{};
    for (final remotePath in uploadedRemotePaths) {
      dirs.add(_parentOfRemotePath(remotePath));
      // 进程内缩略图内存缓存同样会残留旧图。
      _thumbnailMemoryCache.remove('${config.id}|$remotePath');
      await _cacheService.invalidateImage(config.id, remotePath);
    }

    // 目录结构可能新增层级，整台服务器的相册列表一律作废。
    await _cacheService.invalidateAlbums(config.id);

    for (final dir in dirs) {
      // 该目录自身的媒体列表与 EXIF 时间已过期。
      var current = dir;
      while (true) {
        await _cacheService.invalidateAlbumMediaItems(config.id, current);
        if (current.isEmpty) break;
        current = _parentOfRemotePath(current);
      }
    }
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

  /// EXIF 拍摄时间探测的读取上限。DateTimeOriginal 位于 APP1 的 IFD 结构中，
  /// 紧邻文件头部，64KB 足以覆盖；比缩略图探测的缓冲区小得多，
  /// 在大相册逐文件扫描时可显著降低网络开销。
  static const int _exifDateProbeBytes = 64 * 1024;

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
        return await _readHeaderVia(connect, config, remotePath, maxBytes);
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

  /// 用指定连接读取文件开头 [maxBytes] 字节。不负责重试与连接失效处理，
  /// 便于扫描阶段用各自的独立连接直接调用。
  Future<Uint8List> _readHeaderVia(
    SmbConnect connect,
    SmbConfig config,
    String remotePath,
    int maxBytes,
  ) async {
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

  /// 判断异常是否为可重试的连接类错误。
  ///
  /// 备份并发上传时，某个 worker 的连接可能中途失效；据此决定是否需重连重试。
  /// 超时（见 [_stallTimeout]）同样视为连接异常：它意味着这条连接已经写不动了，
  /// 只能弃用重连，而不是把文件标记为永久失败。
  ///
  /// `connection abort` 与 `cant send request` 是服务端重置连接后的两种典型报文：
  /// 前者来自 Socket 写失败，后者是 smb_connect 在 5 次无响应重试后的兜底异常。
  /// 二者都意味着这条连接已死，必须重连而不是把文件判为失败。
  static bool isConnectionError(Object error) {
    if (error is TimeoutException) return true;
    final msg = error.toString().toLowerCase();
    return msg.contains('network name') ||
        msg.contains('nt_status') ||
        msg.contains('not available') ||
        msg.contains('disconnected') ||
        msg.contains('connection reset') ||
        msg.contains('reset by peer') ||
        msg.contains('connection abort') ||
        msg.contains('cant send request');
  }

  /// 建立一条独立的 SMB 连接（不进入连接缓存池），由调用方负责关闭。
  ///
  /// 同一条连接上的读写无法真正并行，因此并行上传必须为每个 worker
  /// 单独建连接，否则只是逻辑并发、实际仍在串行。
  Future<SmbConnect> createConnection(SmbConfig config) {
    return SmbConnect.connectAuth(
      host: config.host,
      domain: config.domain,
      username: config.username,
      password: config.password ?? '',
    );
  }

  /// 用指定连接创建单级远端目录（已存在时忽略）。
  Future<void> createDirectoryVia(
    SmbConnect connect,
    SmbConfig config,
    String path,
  ) async {
    final normalized = path.replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) return;
    try {
      await connect.createFolder(_buildSMBPath(config, normalized));
    } catch (_) {
      // 目录已存在等情况忽略；真正的写入失败会在上传阶段暴露。
    }
  }

  /// 上传时先写入的临时后缀。
  ///
  /// 整份文件写完后才改名为正式文件名。上传中途被打断时只会留下 `.mipixtmp`，
  /// 不会在正式文件名上留半截文件——那种半截文件在服务端会变成打不开、也删不掉的
  /// “锁死”文件，导致该文件此后永远报 “Access is denied.” 传不上去。
  static const String uploadTempSuffix = '.mipixtmp';

  /// 上传分块大小。
  ///
  /// 取 smb_connect 单次 SMB2 写请求能承载的最大数据量（`SmbStreamConsumer.blockSize`
  /// = 64936）。**注意：实测服务端（Samba 4.19）单次写入硬性上限为 64KiB——
  /// 65536 能写、65537 即被服务端以 STATUS_INVALID_PARAMETER 拒绝**，库协商出来的
  /// maxWriteSize（按客户端缓冲区算出的 1MiB）是虚高的、不可信。因此分块不能超过
  /// 64KiB，必须与 blockSize 对齐，否则每个分块都会被拆/被拒，大视频直接备份失败。
  static const int _uploadChunkSize = 64936;

  /// 单文件分片并行上传的连接数。
  ///
  /// 一条 SMB 连接上的写请求在库内部严格串行（`SmbTransport.sendrecv` 全程持有
  /// 互斥锁），所以单个文件无论多大都只能跑出一条约 5~6MB/s 的串行流，大视频
  /// 因此慢得难以接受。这里把文件按字节区间切给多条独立连接并行写入同一个
  /// 临时文件，写完再统一改名，用并发突破单连接的吞吐上限。
  static const int _uploadChunkParallelism = 4;

  /// 启用 [uploadFileParallel] 的文件大小阈值。
  ///
  /// 小文件不启用分片：连接建立 + 认证的固定开销会超过省下的时间，反而更慢。
  static const int uploadParallelThresholdBytes = 8 * 1024 * 1024;

  /// 单次 SMB 写入调用的「卡死」上限。
  ///
  /// 底层 Socket.flush() 自身没有任何超时：WiFi 静默断开（对端不再回 ACK、
  /// 也不发 RST）时，内核只会不断重传，这个 await 能被挂住十几分钟——界面一直
  /// 停在「传输中」不动，用户看到的就是「传输卡死 / 慢得离谱」。这里统一给每次
  /// 写入加上限，超时按连接类错误上抛，交由调用方的重连重试逻辑处理。
  static const Duration _stallTimeout = Duration(seconds: 30);

  /// 给单次 SMB 调用加卡死上限。
  static Future<T> _guard<T>(Future<T> future) => future.timeout(_stallTimeout);

  /// 用指定连接上传一个本地文件。
  ///
  /// 供并行备份的 worker 复用其独占连接；连接的创建/重连/关闭由调用方管理。
  /// 逐块从磁盘读取，不会把整个文件（视频可达 GB 级）读进内存。
  Future<void> uploadFileVia(
    SmbConnect connect,
    SmbConfig config,
    String remotePath,
    String localPath, {
    Function(double)? onProgress,
  }) async {
    final tempFull = _buildSMBPath(config, '$remotePath$uploadTempSuffix');

    // 清掉上次中断可能残留的临时文件，保证本次从零写入（否则写短了会留旧内容的尾巴）。
    await _guard(_deleteRemoteIfExists(connect, tempFull));

    final tempFile = await _guard(connect.createFile(tempFull));
    final writer = await _guard(connect.openWrite(tempFile));
    final source = File(localPath);
    final total = await source.length();
    final reader = await source.open();

    try {
      var written = 0;
      while (true) {
        final chunk = await reader.read(_uploadChunkSize);
        if (chunk.isEmpty) break;
        writer.add(chunk);
        await _guard(writer.flush());
        written += chunk.length;
        if (onProgress != null && total > 0) onProgress(written / total);
      }
      await _guard(writer.close());
    } finally {
      await reader.close();
    }

    // 整份写完才改名到正式文件名，同名旧文件由 replace 覆盖。
    try {
      await _guard(connect.rename(
        tempFile,
        _buildSMBPath(config, remotePath),
        replace: true,
      ));
    } catch (e) {
      // 改名失败（例如目的地已被服务端句柄锁死）时清掉临时文件，
      // 否则会在远端堆积一份与正式文件等大的残片。
      await _guard(_deleteRemoteIfExists(connect, tempFull));
      rethrow;
    }
  }

  /// 上传单个本地文件；大文件自动改用多连接分片并行，突破单连接吞吐上限。
  ///
  /// 与 [uploadFileVia] 保持同一套原子性语义：内容一律先写 `.mipixtmp` 临时文件，
  /// 全部写完才改名为正式文件名，中途失败只会留下临时文件（并在此处清掉），
  /// 不会在正式文件名上留半截「锁死」文件。
  ///
  /// 低于 [uploadParallelThresholdBytes] 或 [parallelism] < 2 时直接回落到单连接
  /// [uploadFileVia]，避免小文件被连接建立/认证开销拖累。
  Future<void> uploadFileParallel(
    SmbConfig config,
    String remotePath,
    String localPath, {
    int parallelism = _uploadChunkParallelism,
    Function(double)? onProgress,
  }) async {
    final total = await File(localPath).length();
    if (total < uploadParallelThresholdBytes || parallelism < 2) {
      final connect = await createConnection(config);
      try {
        await uploadFileVia(connect, config, remotePath, localPath,
            onProgress: onProgress);
      } finally {
        await _closeQuietly(connect);
      }
      return;
    }

    final tempFull = _buildSMBPath(config, '$remotePath$uploadTempSuffix');

    // 用一条独立连接做「准备 + 收尾」：先清掉上次中断残留的临时文件，再建出一个
    // 空文件。分片写入要以 FileMode.write 打开已存在的文件（该库的 open 只发
    // FILE_OPEN，不会创建），且各连接共用同一个文件——默认共享模式允许这样做。
    final setup = await createConnection(config);

    try {
      try {
        await _guard(_deleteRemoteIfExists(setup, tempFull));
        await _guard(setup.createFile(tempFull));
      } catch (e) {
        await _closeQuietly(setup);
        rethrow;
      }

      // 按字节区间均分，最后一个分片吃掉余数。
      final chunkSize = (total + parallelism - 1) ~/ parallelism;
      final ranges = <List<int>>[];
      for (int i = 0; i < parallelism; i++) {
        final start = i * chunkSize;
        if (start >= total) break;
        final end = (start + chunkSize > total) ? total : start + chunkSize;
        ranges.add([start, end]);
      }

      var written = 0;
      void report(int n) {
        written += n;
        if (onProgress != null && total > 0) onProgress(written / total);
      }

      // 每条分片各用一条全新连接（同一条连接上的写请求严格串行，共用连接等于串行）。
      final connections = <SmbConnect>[];
      try {
        await Future.wait(
          ranges.map((r) => _writeRange(
                config: config,
                tempFull: tempFull,
                localPath: localPath,
                start: r[0],
                end: r[1],
                connections: connections,
                report: report,
              )),
        );
      } catch (e) {
        // 任一分片失败：先关掉所有连接与远端句柄，再清掉临时文件，
        // 否则会在远端堆积一份与正式文件等大的残片。
        for (final connect in connections) {
          await _closeQuietly(connect);
        }
        try {
          await _guard(_deleteRemoteIfExists(setup, tempFull));
        } catch (_) {
          // 清理失败无需上抛：原始错误更有诊断价值。
        }
        rethrow;
      }

      // 全部写完、且远端句柄全部关闭后才改名：句柄未关时改名会被服务端拒绝。
      for (final connect in connections) {
        await _closeQuietly(connect);
      }

      try {
        final tempFile = await _guard(setup.file(tempFull));
        await _guard(setup.rename(
          tempFile,
          _buildSMBPath(config, remotePath),
          replace: true,
        ));
      } catch (e) {
        try {
          await _guard(_deleteRemoteIfExists(setup, tempFull));
        } catch (_) {
          // 同上传失败路径：忽略清理错误，保留原始异常。
        }
        rethrow;
      }
    } finally {
      await _closeQuietly(setup);
    }
  }

  /// 把本地文件 [start, end) 字节区间写入远端 [tempFull] 的对应偏移。
  ///
  /// 自己新建一条连接并登记到 [connections]，由调用方在全部结束后统一关闭；
  /// 逐块读写，不会把整个文件读进内存。
  Future<void> _writeRange({
    required SmbConfig config,
    required String tempFull,
    required String localPath,
    required int start,
    required int end,
    required List<SmbConnect> connections,
    required void Function(int) report,
  }) async {
    final connect = await _guard(createConnection(config));
    connections.add(connect);
    final reader = await File(localPath).open();
    try {
      final file = await _guard(connect.file(tempFull));
      final remote = await _guard(connect.open(file, mode: FileMode.write));
      try {
        // 本地读取必须定位到本分片起点：RandomAccessFile 从当前位置顺序读，
        // 不定位的话每个分片都会从文件头开始读，把前段数据写到自己的偏移上，
        // 结果就是整份文件内容错位。
        await reader.setPosition(start);
        var offset = start;
        while (offset < end) {
          final remaining = end - offset;
          final want = remaining < _uploadChunkSize ? remaining : _uploadChunkSize;
          final chunk = await reader.read(want);
          if (chunk.isEmpty) break;
          // 该库的 writeFrom 不会自行推进位置，每次写入前都要显式定位。
          await remote.setPosition(offset);
          await _guard(remote.writeFrom(chunk));
          offset += chunk.length;
          report(chunk.length);
        }
      } finally {
        // 连接可能已被服务端重置：不加超时的话，这条 tree disconnect 会在
        // 库内部按「3 秒响应超时 × 5 次重试」空转 15 秒，把整批传输拖停。
        await _guard(remote.close());
      }
    } finally {
      await reader.close();
    }
  }

  /// 关闭一条独立连接；失败静默忽略（连接可能已因出错而断开）。
  ///
  /// 必须加超时：连接断开后 `close()` 内部仍会发 tree disconnect 并等响应，
  /// 无上限时每条死连接都要空转十几秒，几条例连接就能让一批备份「卡住不动」。
  Future<void> _closeQuietly(SmbConnect connect) async {
    try {
      await connect.close().timeout(const Duration(seconds: 5));
    } catch (_) {
      // 关闭失败或超时均无需处理：连接本就要废弃。
    }
  }

  /// 删除远端文件；不存在或无权限时静默忽略。
  Future<void> _deleteRemoteIfExists(SmbConnect connect, String fullPath) async {
    try {
      final existing = await connect.file(fullPath);
      if (!existing.isExists) return;
      await connect.delete(existing);
    } catch (_) {
      // 不存在或被占用都无需在此处理：真正的问题会在后续 createFile 时暴露。
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

  static const Set<String> _imageExtensions = {
    'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif',
  };

  static const Set<String> _videoExtensions = {
    'mp4', 'mov', 'm4v', 'mkv', 'avi', '3gp', '3gpp', 'ts', 'webm', 'flv', 'wmv',
  };

  static String _extOf(String name) => name.toLowerCase().split('.').last;

  /// 是否为图片扩展名（相册封面、SMB 图片展示用）。
  bool _isImage(String name) => _imageExtensions.contains(_extOf(name));

  /// 是否为可展示的媒体扩展名（图片或视频）。
  bool _isMedia(String name) =>
      _imageExtensions.contains(_extOf(name)) ||
      _videoExtensions.contains(_extOf(name));

  /// 文件名是否为视频。SMB 相册网格据此渲染播放占位图标，
  /// 而不是去下载整段视频再当作图片解码。
  static bool isVideoName(String name) =>
      _videoExtensions.contains(_extOf(name));

  String _getMimeType(String name) {
    final ext = _extOf(name);
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
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mkv':
        return 'video/x-matroska';
      case 'avi':
        return 'video/x-msvideo';
      case '3gp':
      case '3gpp':
        return 'video/3gpp';
      case 'ts':
        return 'video/mp2t';
      case 'webm':
        return 'video/webm';
      case 'flv':
        return 'video/x-flv';
      case 'wmv':
        return 'video/x-ms-wmv';
      default:
        return 'application/octet-stream';
    }
  }
}
