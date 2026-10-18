import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smb_connect/smb_connect.dart';
import 'package:smb_connect/src/exceptions.dart'
    show SmbException, SmbAuthException;
import '../models/models.dart';
import 'cache_service.dart';

/// 收集流式哈希的最终摘要（`startChunkedConversion` 需要 `Sink<Digest>`）。
/// 每次哈希都新建一个实例，避免复用上次的部分结果。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class _ConnectionWrapper {
  final SmbConnect connect;
  DateTime lastUsed;
  bool isValid = true;

  _ConnectionWrapper(this.connect, this.lastUsed);
}

class MediaItemPage {
  final List<MediaItem> items;
  final int total;
  final bool hasMore;

  MediaItemPage({required this.items, required this.total, required this.hasMore});
}

/// 相册扫描进度回调：`done` 为已处理项数，`total` 为总项数。
typedef ScanProgressCallback = void Function(int done, int total);

/// 上传流程中的阶段进度回调：阶段 + 该阶段已处理字节 + 该阶段总量。
///
/// 上传分成多个阶段上报，界面才能显示独立文案与「已处理/总量、速度、耗时」。
/// [total] 为 0 表示该阶段总量未知（如收尾阶段）。
typedef UploadPhaseCallback = void Function(
    TransferPhase phase, int bytes, int total);

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

  /// 建连串行锁。
  ///
  /// 库里 `SmbConnect.shareTree(share)` 是懒加载且**非并发安全**的：
  /// `initTree()` 每次都新建一个 `Smb2Session`，且 `_trees[share] = tree` 是在
  /// `await tree.setup()`（整段 NTLM 会话建立 + TREE_CONNECT）**之后**才赋值。
  /// 于是多个并发首次调用都会看到 `_trees[share] == null`，各自在同一条
  /// transport 上跑一遍会话建立、报文交错，服务端直接拒绝 → `SmbAuthException`。
  /// 这正是「8 路并发加载缩略图 → 只有前几张成功，其余全部碎图」的根因。
  /// 因此建连必须串行，并在对外发布连接前把 session/tree 预热好。
  Future<void> _connectLock = Future<void>.value();

  Future<T> _withConnectLock<T>(Future<T> Function() action) {
    final result = _connectLock.then((_) => action());
    _connectLock =
        result.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return result;
  }

  /// 同时进行中的「新建连接」上限。
  ///
  /// 部分 Windows 服务器（家用版尤其明显）对同一客户端的并发 SMB 连接数上限很低，
  /// 一旦瞬时新建的连接数超过上限，服务端会直接拒绝并回
  /// "No more connections can be made to this remote computer…"；而失败后的重试
  /// 又会继续新建连接，形成雪崩（实测峰值曾冲到 17 条）。
  /// 因此所有 [SmbConnect.connectAuth] 统一经过此闸门限流，把建连峰值压到服务端可接受的范围。
  static const int _maxConcurrentConnects = 3;
  int _activeConnects = 0;
  Completer<void>? _connectGate;

  Future<void> _acquireConnectSlot() async {
    while (_activeConnects >= _maxConcurrentConnects) {
      final gate = _connectGate ??= Completer<void>();
      await gate.future;
    }
    _activeConnects++;
  }

  void _releaseConnectSlot() {
    _activeConnects--;
    final gate = _connectGate;
    _connectGate = null;
    gate?.complete();
  }

  /// 经 [_maxConcurrentConnects] 闸门限流的建连入口，替代直接调用
  /// [SmbConnect.connectAuth]。
  Future<SmbConnect> _connectAuthGated(
    SmbConfig config, {
    void Function(SmbConnect)? onDisconnect,
  }) async {
    await _acquireConnectSlot();
    try {
      return await SmbConnect.connectAuth(
        host: config.host,
        domain: config.domain,
        username: config.username,
        password: config.password ?? '',
        onDisconnect: onDisconnect,
      );
    } finally {
      _releaseConnectSlot();
    }
  }

  /// 连接类错误重试前的退避等待：让瞬时并发峰值自然消散，
  /// 避免失败重试在几十毫秒内叠加成更大的连接风暴。
  Future<void> _retryBackoff(int retriesLeft) =>
      Future<void>.delayed(Duration(milliseconds: 200 * (3 - retriesLeft)));

  /// 诊断用字符串：`SmbException.toString()` 未覆写，直接打印只会得到
  /// "Instance of 'SmbAuthException'"，因此取其 `message`（内含 NT 状态名）。
  static String _errStr(Object e) => e is SmbException
      ? '${e.runtimeType}(${e.message})'
      : '${e.runtimeType} $e';

  Future<SmbConnect> _getConnection(SmbConfig config) async {
    final key = '${config.host}:${config.username}';
    final cached = _connections[key];
    if (cached != null &&
        cached.isValid &&
        DateTime.now().difference(cached.lastUsed) < _maxConnectionAge) {
      // 不再每次调用都做一次 listShares() 探活：该往返在批量扫描（如逐文件读头）
      // 时会被放大成主要开销。连接失效由各调用方的重试与 _invalidateConnection 兜底。
      cached.lastUsed = DateTime.now();
      return cached.connect;
    }

    return _withConnectLock(() async {
      // 双检：锁内再判一次，避免并发调用重复建连。
      final existing = _connections[key];
      if (existing != null &&
          existing.isValid &&
          DateTime.now().difference(existing.lastUsed) < _maxConnectionAge) {
        existing.lastUsed = DateTime.now();
        return existing.connect;
      }
      if (existing != null) {
        _connections.remove(key);
        await _closeQuietly(existing.connect);
      }

      final connect = await _connectAuthGated(
        config,
        onDisconnect: (c) {
          _connections[key]?.isValid = false;
          _connections.remove(key);
        },
      );
      // 预热：先 touch 一次共享根目录，把 session + tree 建好再发布。
      // 目录路径本就被 `_collectAlbums` / `getAllMediaItems` 用 FILE_OPEN 打开过，
      // 是安全调用；只有预热成功才发布，否则上抛交由调用方重试。
      try {
        await connect.file(_buildSMBPath(config, '')).timeout(_stallTimeout);
      } catch (e) {
        debugPrint('[smb] warmup FAIL host=${config.host} ${_errStr(e)}');
        await _closeQuietly(connect);
        _connections.remove(key);
        rethrow;
      }
      _connections[key] = _ConnectionWrapper(connect, DateTime.now());
      return connect;
    });
  }

  void _invalidateConnection(String host, String username) {
    final key = '$host:$username';
    final wrapper = _connections[key];
    _connections.remove(key);
    if (wrapper == null) return;
    wrapper.isValid = false;
    // 必须真正关闭被废弃的连接：只从池里摘掉会让 socket 与远端会话一直挂着，
    // 服务端会话迟迟不释放，累积到上限后连新建会话都会被拒（SmbAuthException）。
    unawaited(_closeQuietly(wrapper.connect));
  }

  /// 判定 SMB 异常是否属于「重建连接后可重试」的连接层面错误。
  ///
  /// 注意：库内 `SmbException extends Error`（**不是** [Exception]），因此调用方
  /// 的重试分支必须额外用 `catch (e)` 兜住 [Error]，否则
  /// `StateError: Bad state: StreamSink is closed` 这类连接崩坏会直接穿透重试、
  /// 让读取一次性失败（表现为 SMB 缩略图显示碎图占位）。
  ///
  /// [SmbAuthException] 也按可重试处理：Win7 服务端在并发会话较多时会瞬时拒绝
  /// 新建会话，重建连接重试即可成功（离线探针复现过该瞬时失败）。
  bool _isConnectionError(SmbException e) {
    if (e is SmbAuthException) return true;
    final msg = e.toString().toLowerCase();
    return msg.contains('network name') ||
        msg.contains('nt_status') ||
        msg.contains('not available') ||
        msg.contains('disconnected') ||
        msg.contains('connection reset') ||
        msg.contains('reset by peer');
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

  /// 列出远端目录下所有文件的「文件名 → 大小」，供上传前跨设备去重与对账。
  ///
  /// 返回值语义（区分「远端为空」与「读取失败」，两者后果完全不同）：
  /// - 非空 map / 空 map：读取成功。目录不存在或为空时返回空表，表示远端确实没有；
  /// - `null`：读取失败（连接异常、重试耗尽）。调用方**不得**把它当作「远端为空」——
  ///   对账会据此放弃本轮，避免一次抖动把所有「已备份」记录误清成 0。
  ///
  /// 该调用复用共享缓存连接（[_getConnection]）。历史上它对连接异常零重试、
  /// 并把异常吞成空表，导致「瞬时读取失败」被伪装成「远端没有」。这里与
  /// 其它方法保持一致：失败即废弃连接并重建，重试耗尽才判定为读取失败。
  Future<Map<String, int>?> listFilesWithSize(SmbConfig config, String path) async {
    final smbPath = _buildSMBPath(config, path);
    var retries = 3;
    Object? lastError;
    while (retries-- > 0) {
      try {
        final connect = await _getConnection(config);
        final folder = await connect.file(smbPath);
        // 目录不存在属于正常语义（该相册尚未备份过），不是读取失败。
        if (!folder.isExists) {
          return <String, int>{};
        }
        final files = await connect.listFiles(folder);
        final result = {
          for (final f in files)
            if (!f.isDirectory()) f.name: f.size,
        };
        return result;
      } catch (e) {
        lastError = e;
        if (retries == 0) break;
        _invalidateConnection(config.host, config.username);
      }
    }
    debugPrint('[smb] listFilesWithSize FAIL path="$path" smbPath="$smbPath" '
        'err=$lastError');
    return null;
  }

  /// 流式读取远端文件并计算 SHA-256。返回 `null` 表示**未能确认内容**，
  /// 调用方不得当作「相同」。
  ///
  /// 实现要点：
  /// - 对远端文件只调用一次 [SmbConnect.openRead]（默认读整份文件），逐个消费
  ///   stream chunk 并喂给 SHA-256 的 chunked sink；**不要**每 256KiB 再调用一次
  ///   `openRead(start, end)`——每次调用都会重新打开远端文件并增加 SMB 往返/句柄开销。
  /// - 哈希前后核对远端大小，且累计读取字节数必须等于预期大小；若文件在清单扫描后
  ///   被并发改写、删除或读取不完整，返回 `null`，绝不把部分摘要用于决策。
  /// - 每次重试都新建摘要状态，丢弃上次部分结果；不以反复 `openRead` 分窗来控制内存。
  /// - 连接类异常按既有范式重试并失效重建；非连接类错误立即返回 `null`。
  ///
  /// 不复用 [readFile]：它整文件入内存 + 4 连接并行分块 + 图片缓存，都不适用。
  Future<String?> hashRemoteFile(SmbConfig config, String remotePath) async {
    final smbPath = _buildSMBPath(config, remotePath);
    var retries = 3;
    Object? lastError;
    while (retries-- > 0) {
      try {
        final connect = await _getConnection(config);
        final file = await connect.file(smbPath);
        if (!file.isExists || file.isDirectory()) {
          debugPrint('[backup][hash] FAIL remote="$remotePath" reason=absent');
          return null;
        }
        final expected = file.size;
        debugPrint('[backup][hash] START remote="$remotePath" size=$expected');
        final digestSink = _DigestSink();
        final hasher = sha256.startChunkedConversion(digestSink);
        var read = 0;
        final stream = await connect.openRead(file);
        // 加「无新数据即判卡死」的看门狗：这里整份读大文件，链路静默断开时若
        // 没有看门狗，整批备份会停在比对阶段不动。
        await for (final chunk in stream.timeout(_stallTimeout)) {
          hasher.add(chunk);
          read += chunk.length;
        }
        hasher.close();
        final digest = digestSink.value;
        if (digest == null || read != expected) {
          debugPrint('[backup][hash] FAIL remote="$remotePath" '
              'expected=$expected read=$read');
          return null;
        }
        debugPrint('[backup][hash] remote="$remotePath" bytes=$read hash=$digest');
        return digest.toString();
      } catch (e) {
        lastError = e;
        if (!isConnectionError(e)) {
          debugPrint('[backup][hash] FAIL remote="$remotePath" err=$e');
          return null;
        }
        if (retries == 0) break;
        _invalidateConnection(config.host, config.username);
      }
    }
    debugPrint('[backup][hash] FAIL remote="$remotePath" err=$lastError');
    return null;
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
              size: file.size,
              width: 0,
              height: 0,
              // 库的 SMBUtil.readTime 返回的已经是「自 1970 起的毫秒数」，
              // 不要再乘 1000，否则日期会被放大 1000 倍（显示成公元数万年）。
              modifiedAt: file.lastModified != 0
                  ? DateTime.fromMillisecondsSinceEpoch(file.lastModified)
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
  /// 必须用多条连接才能把逐文件读头的耗时分摊开。
  ///
  /// 取 3 是折中：更低会让大相册的首屏日期校准明显变慢，更高则会在部分
  /// Windows 服务器（家用版并发连接上限很低）上与缩略图抢耗尽连接配额，
  /// 反而导致整屏碎图（详见 [_maxConcurrentConnects]）。
  static const int _exifScanConnections = 3;

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
          connections.add(await _connectAuthGated(config));
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
      if (latest == null || image.lastModified > latest.lastModified) {
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

  Future<Uint8List> readFile(
    SmbConfig config,
    String remotePath, {
    bool useCache = true,
    bool useParallel = true,
  }) async {
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
        if (useParallel && size > 0 && size >= _rangeParallelThresholdBytes) {
          // 大文件：多连接并行分块下载。
          result = await _readFileParallel(config, fullPath, size);
        } else {
          // 小文件或大小未知：单连接顺序读取。
          final stream = await connect.openRead(file);
          final bytes = <int>[];
          await for (final chunk in stream.timeout(_stallTimeout)) {
            bytes.addAll(chunk);
          }
          result = Uint8List.fromList(bytes);
        }

        await _cacheService.cacheImage(config.id, remotePath, result);
        return result;
      } on SmbException catch (e) {
        debugPrint('[smb] readFile smbErr retries=$retries path=$remotePath ${_errStr(e)}');
        if (!_isConnectionError(e)) rethrow;
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
        await _retryBackoff(retries);
      } catch (e) {
        debugPrint('[smb] readFile err retries=$retries path=$remotePath ${_errStr(e)}');
        // 库内 SmbConnectException / StateError / SocketException / TimeoutException
        // 均属 [Error] 或非连接异常：读取幂等，一律失效连接后重试，避免一次性碎图。
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
    final connect = await _connectAuthGated(config);
    try {
      final file = await connect.file(fullPath);
      final stream = await connect.openRead(file, start, end);
      final bytes = <int>[];
      await for (final chunk in stream.timeout(_stallTimeout)) {
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
    } catch (e) {
      debugPrint('[smb] readThumbnail header FAIL path=$remotePath ${_errStr(e)}');
      // 局部读取失败时回退到全量读取。
    }

    // 2) 回退：全量读取原图后再缩放生成缩略图（原图本身也会被缓存）。
    //
    // 这里必须走单连接（[readFile] 的 useParallel: false）：网格会 8 路并发加载
    // 缩略图，若比照原图查看走 4 连接并行分块，8 路并发将同时新建 32 条 SMB
    // 会话，Win7 服务端会因会话耗尽而拒绝（SmbAuthException/断链），
    // 结果就是「无内嵌 EXIF 缩略图且 ≥512KiB 的照片」缩略图全部碎图。
    // 缩略图只需把整图缩到 200px，走共享池连接顺序读取即可，且天然受益于
    // 连接复用与请求串行化。
    final originalData = await readFile(
      config,
      remotePath,
      useCache: true,
      useParallel: false,
    );
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
        debugPrint('[smb] readHeader smbErr retries=$retries path=$remotePath ${_errStr(e)}');
        if (!_isConnectionError(e)) rethrow;
        if (retries == 0) rethrow;
        _invalidateConnection(config.host, config.username);
        await _retryBackoff(retries);
      } catch (e) {
        debugPrint('[smb] readHeader err retries=$retries path=$remotePath ${_errStr(e)}');
        // 库内 SmbConnectException / StateError / TimeoutException 都属 [Error]：
        // 不能用 `on Exception` 兜，否则会穿透重试直接碎图。
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
    // 【不能提前 break】底层 smbOpenRead 是 async* 生成器，`smbCloseFile(...)`
    // 位于最后一个 yield 之后：消费者一旦提前取消订阅（break），该方法就不会执行，
    // 远端文件句柄只在连接销毁时才回收。共享连接上会不断累积未关闭句柄，最终
    // 让服务端拒绝后续 CREATE，表现为读取/缩略图失败。该流只产出 end 字节
    // （length = end - start），完整消费即可自然结束。
    await for (final chunk in stream.timeout(_stallTimeout)) {
      bytes.addAll(chunk);
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
  ///
  /// 「本地 socket 已被关闭」是息屏断连场景下实际观测到的异常（`Bad state:
  /// StreamSink is closed`），它同样说明这条连接已经废了。这里只匹配**明确的
  /// socket 关闭报文**，不匹配宽泛的 `bad state`——否则任何程序性 StateError
  /// 都会被误判成网络问题而白等一轮重连。
  static bool isConnectionError(Object error) {
    if (error is TimeoutException) return true;
    if (error is SocketException) return true;
    final msg = error.toString().toLowerCase();
    return msg.contains('network name') ||
        msg.contains('nt_status') ||
        msg.contains('not available') ||
        msg.contains('disconnected') ||
        msg.contains('connection reset') ||
        msg.contains('reset by peer') ||
        msg.contains('connection abort') ||
        msg.contains('cant send request') ||
        // 本地 socket/sink 已关闭（SocketWriter.write / SocketReader2）
        msg.contains('streamsink is closed') ||
        msg.contains('stream sink is closed') ||
        msg.contains('socket is closed') ||
        msg.contains('connection closed') ||
        msg.contains('broken pipe') ||
        (msg.contains("can't read") && msg.contains('from socket')) ||
        (msg.contains('cant read') && msg.contains('from socket'));
  }

  /// 建立一条独立的 SMB 连接（不进入连接缓存池），由调用方负责关闭。
  ///
  /// 同一条连接上的读写无法真正并行，因此并行上传必须为每个 worker
  /// 单独建连接，否则只是逻辑并发、实际仍在串行。
  ///
  /// [onDisconnect] 与缓存连接（见 [_getConnection]）保持一致：socket 一旦
  /// 断开（对端断开、链路中断）立即回调，调用方据此把该连接标记为失效并在
  /// 下一个文件前重建，而不是等到某次写入失败才发现。
  Future<SmbConnect> createConnection(
    SmbConfig config, {
    Function(SmbConnect)? onDisconnect,
  }) {
    return _connectAuthGated(config, onDisconnect: onDisconnect);
  }

  /// 用指定连接创建单级远端目录（已存在时忽略）。
  ///
  /// 建目录也纳入 [_stallTimeout] 看门狗：服务端因残留锁不回 ACK 时，不能把这个
  /// await 无限挂住（否则整批卡死且无日志）。超时即按连接类错误抛出，由调用方收敛。
  Future<void> createDirectoryVia(
    SmbConnect connect,
    SmbConfig config,
    String path,
  ) async {
    final normalized = path.replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) return;
    try {
      await _guard(connect.createFolder(_buildSMBPath(config, normalized)));
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

  /// 单条上传连接（分片或单连接）在断链后允许的最大重连续传次数。
  ///
  /// 实测服务端（Win7 / SMB2）在写入过程中会偶发长时间不响应：库内
  /// `SmbTransport.waitResponseTimeout`（3 秒）一到就会**重发同一个请求**，
  /// 服务端随即断开该连接，客户端随后的写入命中已关闭的 socket，抛出
  /// `Bad state: StreamSink is closed`。这是服务端行为，客户端无法避免；
  /// 能做的只有在断链后重建连接、从**最后一个已确认写入的偏移**继续，
  /// 而不是把整个文件判失败（大文件从头重来等于永远传不完）。
  ///
  /// 实测 200MB 分片约需 3~4 次重连，这里给到 20 次，覆盖数 GB 级单文件；
  /// 重连本身失败（服务端不可达）会直接上抛，不会消耗这个次数。
  static const int _shardMaxReconnects = 20;

  /// 单次 SMB 写入调用的「卡死」上限。
  ///
  /// 底层 Socket.flush() 自身没有任何超时：WiFi 静默断开（对端不再回 ACK、
  /// 也不发 RST）时，内核只会不断重传，这个 await 能被挂住十几分钟——界面一直
  /// 停在「传输中」不动，用户看到的就是「传输卡死 / 慢得离谱」。这里统一给每次
  /// 写入加上限，超时按连接类错误上抛，交由调用方的重连重试逻辑处理。
  static const Duration _stallTimeout = Duration(seconds: 30);

  /// 给单次 SMB 调用加卡死上限。
  static Future<T> _guard<T>(Future<T> future) => future.timeout(_stallTimeout);

  /// 上传后、改名前的落盘完整性校验。
  ///
  /// 「写入 API 返回成功」并不等于字节全部落盘——写入过程中若链路中断，服务端
  /// 可能只收到部分字节，临时文件长度就会小于来源。因此改名之前比对远端临时文件
  /// 长度与本地源文件长度，不等即删掉临时文件并抛错，由上层按失败处理，正式文件
  /// 名上始终保留旧文件（fail-closed）。
  ///
  /// 这里只做一次远端 stat（成本近似为零），不再回读整份内容重算 SHA-256：全量
  /// 回读在大文件上耗时数分钟且失败率高，而它查不出「长度不变、内容静默变化」
  /// 这一类问题（GPS 丢失发生在手机端读取阶段，与上传落盘无关）。
  Future<void> _verifyUploadedTemp(
    SmbConnect connect,
    String tempFull,
    String localPath,
  ) async {
    final total = File(localPath).lengthSync();
    final remoteSize = await _remoteFileSize(connect, tempFull);
    if (remoteSize != total) {
      debugPrint('[backup][verify] SIZE MISMATCH local="$localPath" '
          'remote=$remoteSize expected=$total');
      try {
        await _guard(_deleteRemoteIfExists(connect, tempFull));
      } catch (_) {
        // 清理失败不掩盖真正的校验失败原因。
      }
      throw Exception('上传后校验失败：NAS 端文件长度与手机端不一致（已丢弃临时文件）');
    }
    debugPrint('[backup][verify] SIZE OK local="$localPath" size=$total');
  }

  /// 远端临时文件的真实大小；不存在或读取失败返回 -1（判定为不一致，fail-closed）。
  Future<int> _remoteFileSize(SmbConnect connect, String smbPath) async {
    try {
      final file = await _guard(connect.file(smbPath));
      return file.isExists ? file.size : -1;
    } catch (e) {
      debugPrint('[backup][verify] remote stat error: $e');
      return -1;
    }
  }

  /// 用指定连接上传一个本地文件。
  ///
  /// 供并行备份的 worker 复用其独占连接；连接的创建 / 关闭由调用方管理。
  /// 逐块从磁盘读取，不会把整个文件（视频可达 GB 级）读进内存。
  ///
  /// 支持**断链续传**：内容一律先写 `.mipixtmp` 临时文件；单连接从 0 顺序写保证
  /// 远端已写偏移之前的字节必然正确，因此重试 / 重连时若临时文件已存在且长度落在
  /// `(0, total)` 之间，就从该长度（≈ 服务端当前大小）继续写，而不是从 0 重来。
  /// 服务端偶发断链（见 [_shardMaxReconnects]）时，若提供 [reconnect] 会在本函数内
  /// 重建连接续传；未提供 [reconnect] 时按连接类错误上抛，由调用方重试再次进入本
  /// 函数（临时文件仍在，同样会续传）。
  Future<void> uploadFileVia(
    SmbConnect connect,
    SmbConfig config,
    String remotePath,
    String localPath, {
    DateTime? sourceTime,
    UploadPhaseCallback? onPhase,
    Future<SmbConnect> Function()? reconnect,
  }) async {
    final tempFull = _buildSMBPath(config, '$remotePath$uploadTempSuffix');
    final total = await File(localPath).length();
    final reader = await File(localPath).open();
    // 捕获为 final 局部变量，便于在 catch 之后保持非空提升（参数在跨块时会失效）。
    final reconnectFn = reconnect;

    var activeConnect = connect;
    var offset = 0;
    var reconnects = 0;
    try {
      // 先探测远端临时文件：存在且长度 ∈ (0, total) 即从该处续传；否则清掉重写，
      // 既避免上次中断留下的旧内容变成后缀尾巴，也避免长度已满时越写越错。
      final existing = await _guard(_remoteFileSize(activeConnect, tempFull));
      if (existing > 0 && existing < total) {
        offset = existing;
        debugPrint('[backup][resume] 单连接续传 remote="$remotePath" '
            'offset=$offset total=$total');
      } else {
        await _guard(_deleteRemoteIfExists(activeConnect, tempFull));
        await _guard(activeConnect.createFile(tempFull));
      }

      while (offset < total) {
        // 本地读取位置同步到续传偏移：断链时已读过的那一块要重读。
        await reader.setPosition(offset);
        try {
          // 每轮（首传 / 重连续传）都重开远端句柄并定位到续传偏移：新句柄位置是 0，
          // 不定位就会把后续数据全部写回文件头。
          final file = await _guard(activeConnect.file(tempFull));
          final remote =
              await _guard(activeConnect.open(file, mode: FileMode.write));
          await remote.setPosition(offset);
          try {
            while (offset < total) {
              final remaining = total - offset;
              final want =
                  remaining < _uploadChunkSize ? remaining : _uploadChunkSize;
              final chunk = await reader.read(want);
              if (chunk.isEmpty) break;
              // 该库的 writeFrom 不会自行推进位置，每次写入前都要显式定位。
              await remote.setPosition(offset);
              await _guard(remote.writeFrom(chunk));
              offset += chunk.length;
              onPhase?.call(TransferPhase.uploading, offset, total);
            }
          } finally {
            // 连接可能已被服务端重置：句柄关闭同样加超时兜底，避免空转拖停整批。
            try {
              await _guard(remote.close());
            } catch (_) {}
          }
        } catch (e) {
          // 非连接类错误（权限 / 逻辑）直接上抛；连接类错误才值得重建续传。
          if (reconnectFn == null || !SmbService.isConnectionError(e)) rethrow;
          reconnects += 1;
          if (reconnects > _shardMaxReconnects) rethrow;
          debugPrint('[backup][resume] 单连接断链 remote="$remotePath" '
              'offset=$offset reconnect=$reconnects type=${e.runtimeType} err=$e');
          // 重建一条可用连接后继续续传（偏移不变，只换连接与句柄）。
          activeConnect = await reconnectFn();
          continue;
        }
        // 内层已把 [offset, total) 全部写完，无需再续传。
        break;
      }
    } finally {
      await reader.close();
    }

    // 落盘长度比对通过后才允许改名（见 _verifyUploadedTemp）。
    await _verifyUploadedTemp(activeConnect, tempFull, localPath);

    // 收尾阶段：改名到正式文件名、再回写拍摄时间。
    onPhase?.call(TransferPhase.finalizing, 0, 0);
    // 整份写完才改名到正式文件名，同名旧文件由 replace 覆盖。
    final finalFile = await _guard(activeConnect.file(tempFull));
    final swRename = Stopwatch()..start();
    try {
      await _guard(activeConnect.rename(
        finalFile,
        _buildSMBPath(config, remotePath),
        replace: true,
      ));
    } catch (e) {
      // 改名失败（例如目的地已被服务端句柄锁死）时清掉临时文件，
      // 否则会在远端堆积一份与正式文件等大的残片。
      await _guard(_deleteRemoteIfExists(activeConnect, tempFull));
      rethrow;
    }
    swRename.stop();
    debugPrint('[backup][stage] phase=rename remote="$remotePath" '
        'ms=${swRename.elapsedMilliseconds}');

    await _applySourceTime(
        activeConnect, config, remotePath, localPath, sourceTime);
  }

  /// 把远端正式文件的创建与修改时间回写为手机相册的拍摄时间。
  ///
  /// SMB 写入会让服务端把文件时间设成「写入时刻」，不显式回写的话，备份端
  /// 时间戳就变成备份时间而不是照片的原始时间。回写失败只记录日志，
  /// 不影响「上传已成功」的结论。
  Future<void> _applySourceTime(SmbConnect connect, SmbConfig config,
      String remotePath, String localPath, DateTime? sourceTime) async {
    try {
      final time = (sourceTime ?? await File(localPath).lastModified())
          .millisecondsSinceEpoch;
      final remoteFile =
          await _guard(connect.file(_buildSMBPath(config, remotePath)));
      final sw = Stopwatch()..start();
      // setFileTime 同样加卡死上限：服务端持锁不回 ACK 时不能无限挂住收尾阶段。
      await _guard(connect.setFileTime(
        remoteFile,
        lastWriteTime: time,
        createTime: time,
      ));
      sw.stop();
      debugPrint('[backup][stage] phase=setFileTime remote="$remotePath" '
          'ms=${sw.elapsedMilliseconds}');
    } catch (e) {
      print('[backup][time] FAIL remote="$remotePath" err=$e');
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
    DateTime? sourceTime,
    int parallelism = _uploadChunkParallelism,
    UploadPhaseCallback? onPhase,
  }) async {
    final total = await File(localPath).length();
    if (total < uploadParallelThresholdBytes || parallelism < 2) {
      // 单连接路径（含并发=1 时的大文件）：断链时由本函数负责重建连接并续传，
      // 新建的连接全部登记在 [conns] 里，结束时统一关闭。
      // 建连也加卡死上限：服务端残留锁 / 不响应时不能把整个上传挂死在这里。
      final conns = <SmbConnect>[await _guard(createConnection(config))];
      try {
        await uploadFileVia(conns.first, config, remotePath, localPath,
            sourceTime: sourceTime, onPhase: onPhase, reconnect: () async {
          final next = await _guard(createConnection(config));
          conns.add(next);
          return next;
        });
      } finally {
        for (final c in conns) {
          await _closeQuietly(c);
        }
      }
      return;
    }

    final tempFull = _buildSMBPath(config, '$remotePath$uploadTempSuffix');

    // 用一条独立连接做「准备 + 收尾」：先清掉上次中断残留的临时文件，再建出一个
    // 空文件。分片写入要以 FileMode.write 打开已存在的文件（该库的 open 只发
    // FILE_OPEN，不会创建），且各连接共用同一个文件——默认共享模式允许这样做。
    final setup = await _guard(createConnection(config));

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
        onPhase?.call(TransferPhase.uploading, written, total);
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

      // 落盘长度比对通过后才允许改名（见 _verifyUploadedTemp）。
      await _verifyUploadedTemp(setup, tempFull, localPath);

      // 收尾阶段：改名到正式文件名、再回写拍摄时间。
      onPhase?.call(TransferPhase.finalizing, 0, 0);
      final swRename = Stopwatch()..start();
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
      swRename.stop();
      debugPrint('[backup][stage] phase=rename remote="$remotePath" '
          'ms=${swRename.elapsedMilliseconds}');

      await _applySourceTime(setup, config, remotePath, localPath, sourceTime);
    } finally {
      await _closeQuietly(setup);
    }
  }

  /// 把本地文件 [start, end) 字节区间写入远端 [tempFull] 的对应偏移。
  ///
  /// 每轮（首传或重连续传）都新建一条连接并登记到 [connections]，写完当前区间
  /// 后自行关闭句柄与连接；调用方也会在整批结束后统一关闭 [connections]，对已关
  /// 连接是幂等的 no-op。逐块读写，不会把整个文件读进内存。
  ///
  /// 写入过程中连接被服务端断开时（见 [_shardMaxReconnects]），不把整个文件
  /// 判失败，而是重建连接、重新打开远端句柄，从**最后一个已确认写入的偏移**
  /// 继续写——已确认的字节不会重写，未写完的部分接着写。
  Future<void> _writeRange({
    required SmbConfig config,
    required String tempFull,
    required String localPath,
    required int start,
    required int end,
    required List<SmbConnect> connections,
    required void Function(int) report,
  }) async {
    final source = await File(localPath).open();
    var offset = start;
    var reconnects = 0;
    try {
      await source.setPosition(start);
      while (offset < end) {
        // 每轮（首传或重连续传）都重新建连、重新打开远端句柄，并定位到续传偏移：
        // 新句柄的位置是 0，不定位就会把后续数据全部写回文件头。
        final connect = await _guard(createConnection(config));
        connections.add(connect);
        final file = await _guard(connect.file(tempFull));
        final remote = await _guard(connect.open(file, mode: FileMode.write));
        await remote.setPosition(offset);
        // 本地读取位置也要同步回续传偏移（断链时已读过的那一块要重读）。
        await source.setPosition(offset);

        var failed = false;
        try {
          while (offset < end) {
            final remaining = end - offset;
            final want =
                remaining < _uploadChunkSize ? remaining : _uploadChunkSize;
            final chunk = await source.read(want);
            if (chunk.isEmpty) break;
            // 该库的 writeFrom 不会自行推进位置，每次写入前都要显式定位。
            await remote.setPosition(offset);
            await _guard(remote.writeFrom(chunk));
            offset += chunk.length;
            report(chunk.length);
          }
        } catch (e) {
          reconnects += 1;
          if (reconnects > _shardMaxReconnects) rethrow;
          failed = true;
          debugPrint('[backup][resume] 分片 $start..$end 断链 offset=$offset '
              'reconnect=$reconnects type=${e.runtimeType} err=$e');
        } finally {
          // 连接可能已被服务端重置：不加超时的话，这条 tree disconnect 会在
          // 库内部按「3 秒响应超时 × 5 次重试」空转 15 秒，把整批传输拖停。
          try {
            await _guard(remote.close());
          } catch (_) {}
          await _closeQuietly(connect);
        }
        // 本轮没失败即该分片已写完。
        if (!failed) break;
      }
    } finally {
      await source.close();
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
