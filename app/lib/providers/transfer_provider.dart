import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:smb_connect/smb_connect.dart';
import '../models/models.dart';
import '../services/local_storage_service.dart';
import '../services/photo_service.dart';
import '../services/smb_service.dart';
import 'app_provider.dart';
import 'photo_provider.dart';
import 'smb_provider.dart';

/// 一次备份中待上传的单个文件。
class _PendingUpload {
  final String localPath;
  final String remotePath;
  final String albumName;
  final int size;
  /// 任务记录 id，在批量创建任务时才生成。
  String taskId = '';

  _PendingUpload({
    required this.localPath,
    required this.remotePath,
    required this.albumName,
    required this.size,
  });
}

class BackupResult {
  final int successCount;
  final int failedCount;

  /// 远端已存在「同名同大小」文件而跳过上传的照片数（视为已备份）。
  final int skippedCount;

  const BackupResult({
    required this.successCount,
    required this.failedCount,
    this.skippedCount = 0,
  });

  bool get allSucceeded => failedCount == 0;
  bool get allFailed => successCount == 0 && failedCount > 0;

  /// 本次全部被判定为「远端已备份」而跳过（无上传、无失败）。
  bool get allAlreadyBackedUp =>
      successCount == 0 && failedCount == 0 && skippedCount > 0;
}

final transfersProvider = StateNotifierProvider<TransfersNotifier, AsyncValue<List<TransferTask>>>(
  (ref) => TransfersNotifier(ref),
);

/// 已成功备份到 SMB 的本地图片路径集合（按服务器区分：serverId → 路径集合）。
final syncedPhotosProvider =
    StateNotifierProvider<SyncedPhotosNotifier, Map<String, Set<String>>>(
  (ref) => SyncedPhotosNotifier(),
);

/// 当前选中服务器的「已备份」路径集合，供界面判定单张照片是否已同步。
final syncedForCurrentServerProvider = Provider<Set<String>>((ref) {
  final current = ref.watch(defaultServerProvider);
  final all = ref.watch(syncedPhotosProvider);
  if (current == null) return const <String>{};
  return all[current] ?? const <String>{};
});

/// 正在上传（排队中/传输中）的本地图片路径集合，作为「上传锁」供 UI 使用。
///
/// 同一路径一旦进入该集合，界面显示「上传中」并阻止重复提交，避免并发上传
/// 同一目标文件触发 SMB 服务端共享冲突（"being used by another process"）。
final uploadingPathsProvider = Provider<Set<String>>((ref) {
  final tasks = ref.watch(transfersProvider).valueOrNull ?? const <TransferTask>[];
  return tasks
      .where((t) =>
          t.status == TransferStatus.running ||
          t.status == TransferStatus.pending)
      .map((t) => t.localPath)
      .toSet();
});

/// 「已同步」标记的唯一权威来源（按服务器区分）。
///
/// 内存中的 [state] 是权威映射，磁盘只作持久化镜像：
/// - [load] 采用并集合并而非整体覆盖，避免异步载入覆盖掉运行中新增的标记；
/// - [markSynced] 立即更新内存（界面即时收缩），落盘去抖后整表覆盖写，
///   杜绝并发读-改-写互相覆盖导致丢标记；
/// - [replaceSynced] 供「与服务器核对」后整体回写某台服务器的集合。
class SyncedPhotosNotifier extends StateNotifier<Map<String, Set<String>>> {
  final _storage = LocalStorageService();

  Timer? _flushTimer;
  bool _writing = false;
  bool _flushAgain = false;

  SyncedPhotosNotifier() : super(<String, Set<String>>{}) {
    load();
  }

  Future<void> load() async {
    try {
      final stored = await _storage.getAllSynced();
      // 并集合并：绝不删除内存中已有的标记。
      final next = Map<String, Set<String>>.from(state);
      stored.forEach((serverId, paths) {
        next[serverId] = {...?next[serverId], ...paths};
      });
      state = next;
    } catch (_) {
      // 读取失败时保留当前内存状态，避免把已标记的清空。
    }
  }

  /// 某台服务器当前的「已备份」路径集合。
  Set<String> of(String serverId) => state[serverId] ?? const <String>{};

  /// 把若干本地路径记为某台服务器的「已同步」。立即反映到界面，落盘去抖。
  void markSynced(String serverId, Iterable<String> localPaths) {
    final incoming = localPaths.where((p) => p.isNotEmpty).toSet();
    if (incoming.isEmpty) return;
    final cur = state[serverId] ?? <String>{};
    final merged = {...cur, ...incoming};
    if (merged.length == cur.length) return; // 无新增，无需刷新与落盘
    final next = Map<String, Set<String>>.from(state);
    next[serverId] = merged;
    state = next;
    _scheduleFlush();
  }

  /// 整体覆盖某台服务器的「已同步」集合（核对远端后回写）。
  void replaceSynced(String serverId, Set<String> paths) {
    final cur = state[serverId] ?? <String>{};
    if (cur.length == paths.length && cur.containsAll(paths)) return;
    final next = Map<String, Set<String>>.from(state);
    if (paths.isEmpty) {
      next.remove(serverId);
    } else {
      next[serverId] = paths;
    }
    state = next;
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 300), _flush);
  }

  /// 立即把当前映射写入磁盘（备份批次 / 核对结束时调用，确保进程被杀也不丢）。
  Future<void> flushNow() => _flush();

  Future<void> _flush() async {
    if (_writing) {
      _flushAgain = true;
      return;
    }
    _writing = true;
    try {
      await _storage.saveAllSynced(state);
    } catch (_) {
      // 落盘失败忽略：后续标记或下次启动载入会再尝试。
    } finally {
      _writing = false;
    }
    if (_flushAgain) {
      _flushAgain = false;
      await _flush();
    }
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }
}

class TransfersNotifier extends StateNotifier<AsyncValue<List<TransferTask>>> {
  final Ref _ref;
  final _storage = LocalStorageService();
  final _smbService = SmbService();
  final Map<String, StreamController<double>> _progressControllers = {};

  /// 进度落盘的最小间隔，避免高频进度回调把整表反复写入磁盘。
  static const Duration _progressPersistInterval = Duration(milliseconds: 500);
  DateTime _lastProgressPersist = DateTime.fromMillisecondsSinceEpoch(0);

  /// 进度界面刷新的最小间隔（按任务）。
  ///
  /// 进度回调每 64KB 一次，若每次都重建整个传输列表，这些重建会与 SMB 网络
  /// I/O 争抢同一个 UI isolate 的时间片，反过来拖慢上传本身。
  static const Duration _progressUiInterval = Duration(milliseconds: 150);
  final Map<String, DateTime> _lastProgressUiAt = {};

  TransfersNotifier(this._ref) : super(const AsyncValue.loading()) {
    _init();
  }

  /// 加载历史记录，并把上次进程被杀死时残留的 running/pending 任务标记为失败。
  ///
  /// 上传只存在于内存中，进程重启后不可能还在传输；若不清理，它们会被
  /// 「上传锁」（uploadingPathsProvider）判定为仍在传输，导致对应照片
  /// 永远显示「上传中」且无法再次备份。状态只在清理完成后一次性写入，
  /// 避免与启动期间新发起的备份产生竞态。
  Future<void> _init() async {
    try {
      final tasks = await _storage.getTransfers();
      var changed = false;
      final reconciled = tasks.map((t) {
        if (t.status != TransferStatus.running &&
            t.status != TransferStatus.pending) {
          return t;
        }
        changed = true;
        return TransferTask(
          id: t.id,
          serverId: t.serverId,
          transferType: t.transferType,
          remotePath: t.remotePath,
          localPath: t.localPath,
          totalBytes: t.totalBytes,
          writtenBytes: t.writtenBytes,
          progress: t.progress,
          status: TransferStatus.failed,
          errorMessage: 'Interrupted',
          createdAt: t.createdAt,
          updatedAt: DateTime.now(),
        );
      }).toList();
      if (changed) await _storage.saveTransfers(reconciled);
      state = AsyncValue.data(reconciled);

      // 把「已完成」的传输任务与「已同步」集合对齐。
      //
      // 早期版本没有上传锁，并发备份时 markSynced 的「读-改-写」会互相覆盖，
      // 导致部分已成功上传的照片没有写回同步集合，被一直算作「未同步」——
      // 这正是传输页「全部备份」显示出偏大的待备份数量的原因。
      // 以任务记录为准补齐缺失项，幂等且不会误标（done 即上传成功）。
      // 以任务记录为准、按服务器补齐缺失的「已同步」标记（done 即上传成功）。
      final doneByServer = <String, Set<String>>{};
      for (final t in reconciled) {
        if (t.status == TransferStatus.done && t.localPath.isNotEmpty) {
          doneByServer.putIfAbsent(t.serverId, () => <String>{})
              .add(t.localPath);
        }
      }
      if (doneByServer.isNotEmpty) {
        final notifier = _ref.read(syncedPhotosProvider.notifier);
        final allSynced = await _storage.getAllSynced();
        doneByServer.forEach((serverId, paths) {
          final synced = allSynced[serverId] ?? const <String>{};
          final missing = paths.where((p) => !synced.contains(p)).toList();
          if (missing.isNotEmpty) notifier.markSynced(serverId, missing);
        });
      }
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  @override
  void dispose() {
    for (final controller in _progressControllers.values) {
      controller.close();
    }
    super.dispose();
  }

  Future<void> load() async {
    try {
      final tasks = await _storage.getTransfers();
      state = AsyncValue.data(tasks);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> cancel(String id) async {
    _progressControllers[id]?.close();
    _progressControllers.remove(id);

    final tasks = state.valueOrNull ?? [];
    final updated = tasks.map((t) {
      if (t.id == id) {
        return TransferTask(
          id: t.id,
          serverId: t.serverId,
          transferType: t.transferType,
          remotePath: t.remotePath,
          localPath: t.localPath,
          totalBytes: t.totalBytes,
          writtenBytes: t.writtenBytes,
          progress: t.progress,
          status: TransferStatus.failed,
          errorMessage: 'Cancelled by user',
          createdAt: t.createdAt,
          updatedAt: DateTime.now(),
        );
      }
      return t;
    }).toList();
    await _storage.saveTransfers(updated);
    await load();
  }

  Future<void> pause(String id) async {
    final tasks = state.valueOrNull ?? [];
    final updated = tasks.map((t) {
      if (t.id == id) {
        return TransferTask(
          id: t.id,
          serverId: t.serverId,
          transferType: t.transferType,
          remotePath: t.remotePath,
          localPath: t.localPath,
          totalBytes: t.totalBytes,
          writtenBytes: t.writtenBytes,
          progress: t.progress,
          status: TransferStatus.paused,
          errorMessage: null,
          createdAt: t.createdAt,
          updatedAt: DateTime.now(),
        );
      }
      return t;
    }).toList();
    await _storage.saveTransfers(updated);
    await load();
  }

  Future<void> resume(String id) async {
    final tasks = state.valueOrNull ?? [];
    final updated = tasks.map((t) {
      if (t.id == id) {
        return TransferTask(
          id: t.id,
          serverId: t.serverId,
          transferType: t.transferType,
          remotePath: t.remotePath,
          localPath: t.localPath,
          totalBytes: t.totalBytes,
          writtenBytes: t.writtenBytes,
          progress: t.progress,
          status: TransferStatus.pending,
          errorMessage: null,
          createdAt: t.createdAt,
          updatedAt: DateTime.now(),
        );
      }
      return t;
    }).toList();
    await _storage.saveTransfers(updated);
    await load();
  }

  Future<void> clearCompleted() async {
    final tasks = state.valueOrNull ?? [];
    final active = tasks.where((t) => t.status != TransferStatus.done && t.status != TransferStatus.failed).toList();
    await _storage.saveTransfers(active);
    await load();
  }

  /// 手动续传：把「上传失败」的照片重新排队备份。
  ///
  /// 断网/服务器不可达会让该批次内相关文件标记为失败并留在传输队列里。
  /// 用户在网络恢复后点「重试失败」即可一次性续传，无需重新挑选照片。
  /// 按服务器分组，各自续传到原本的目标服务器。
  Future<BackupResult> retryFailedUploads() async {
    final tasks = state.valueOrNull ?? const <TransferTask>[];
    final failed = tasks
        .where((t) =>
            t.status == TransferStatus.failed &&
            t.transferType == TransferType.upload &&
            t.localPath.isNotEmpty)
        .toList();
    if (failed.isEmpty) {
      return const BackupResult(successCount: 0, failedCount: 0);
    }

    // 先移除这些失败记录，避免续传时与新建的同名任务重复。
    final failedIds = failed.map((t) => t.id).toSet();
    final remaining = tasks.where((t) => !failedIds.contains(t.id)).toList();
    await _storage.saveTransfers(remaining);
    state = AsyncValue.data(remaining);

    final byServer = <String, List<String>>{};
    for (final t in failed) {
      // 本地文件可能已被删除，跳过不存在的项。
      if (!await File(t.localPath).exists()) continue;
      byServer.putIfAbsent(t.serverId, () => []).add(t.localPath);
    }

    var success = 0;
    var fail = 0;
    var skipped = 0;
    final servers = await _storage.getSmbServers();
    for (final entry in byServer.entries) {
      if (!servers.any((s) => s.id == entry.key)) continue; // 服务器已被删除
      final result = await backupPhotos(entry.key, entry.value);
      success += result.successCount;
      fail += result.failedCount;
      skipped += result.skippedCount;
    }
    return BackupResult(
      successCount: success,
      failedCount: fail,
      skippedCount: skipped,
    );
  }

  Future<BackupResult> backupPhotos(String serverId, List<String> localPaths) async {
    final servers = await _storage.getSmbServers();
    final server = servers.firstWhere((s) => s.id == serverId);
    final syncedPhotosNotifier = _ref.read(syncedPhotosProvider.notifier);
    var successCount = 0;
    var failedCount = 0;
    var skippedCount = 0;
    final syncedPaths = <String>[];
    // 本次成功上传的远端路径，用于上传结束后一次性失效相关缓存。
    final uploadedRemotePaths = <String>[];
    // 已在传输中的同一文件直接跳过：并发上传同一目标文件会被 SMB 服务端
    // （Windows）判定为共享冲突（"being used by another process"）导致失败。
    final activePaths = (state.valueOrNull ?? [])
        .where((t) =>
            t.status == TransferStatus.running ||
            t.status == TransferStatus.pending)
        .map((t) => t.localPath)
        .toSet();

    // 每个本地文件所属的相册名（扁平结构：直接用手机相册名作远端文件夹名）。
    final albumNames = <String, String>{};
    for (final path in localPaths) {
      if (path.isEmpty) continue;
      albumNames[path] = PhotoService.albumNameOf(path);
    }

    // 上传前按相册一次性拉取远端文件清单（文件名 → 大小），用于跨设备去重：
    // 同一小米账号下的多台设备（小米云同步）会有相同照片，若远端已存在
    // 「同名且同大小」的文件，说明这张已备份过，直接跳过并标记为已同步，
    // 既不重复上传，也不会把已备份的照片显示成未备份。
    final remoteIndex = <String, Map<String, int>>{};
    for (final album in albumNames.values.toSet()) {
      if (album.isEmpty) continue;
      remoteIndex[album] = await _smbService.listFilesWithSize(server, album);
    }

    // 组装本次真正需要上传的项（已排除远端已有、批次内重名）。
    final pending = <_PendingUpload>[];
    final batchRemotePaths = <String>{};
    for (final path in localPaths) {
      // add 返回 false 表示该路径已在传输中或本次列表内重复。
      if (path.isEmpty || !activePaths.add(path)) continue;

      final albumName = albumNames[path] ?? '';
      final fileName = path.split('/').last;
      final fileSize = await File(path).length();

      // 远端已有同名文件：大小一致才判定为「同一张、已备份」并跳过；
      // 同名但大小不同很可能是不同的照片，不能误标为已备份，需正常上传。
      final remoteSize = remoteIndex[albumName]?[fileName];
      if (fileSize > 0 && remoteSize != null && remoteSize == fileSize) {
        skippedCount += 1;
        syncedPaths.add(path);
        // 即时标记：远端已有即视为已备份，界面立刻从未同步栏移除，无需等整批结束。
        syncedPhotosNotifier.markSynced(serverId, [path]);
        continue;
      }

      // 扁平结构：<相册名>/<文件名>；相册名为空时直接放在备份根目录下。
      final remotePath = albumName.isEmpty ? fileName : '$albumName/$fileName';
      // 同一批次内多个本地文件落到同一远端路径时只上传一次，避免自相覆盖。
      if (!batchRemotePaths.add(remotePath)) continue;

      pending.add(_PendingUpload(
        localPath: path,
        remotePath: remotePath,
        albumName: albumName,
        size: fileSize,
      ));
    }

    if (pending.isNotEmpty) {
      // 大文件（视频）走「多连接分片并行」，小文件（照片）继续用 worker 池并发。
      // 两者分开调度：大文件靠自身分片提速，小文件靠多文件并发提速，
      // 互不争抢——否则一个大视频会把 worker 池的连接全部占住。
      final large = <_PendingUpload>[];
      final small = <_PendingUpload>[];
      for (final item in pending) {
        if (item.size >= SmbService.uploadParallelThresholdBytes) {
          large.add(item);
        } else {
          small.add(item);
        }
      }

      // 并发度取自设置（默认 4，最高 8）。
      final concurrency =
          normalizeUploadConcurrency(_ref.read(uploadConcurrencyProvider));
      // 小文件 worker 池大小，不超过实际待传的小文件数量。
      final workerCount =
          concurrency < small.length ? concurrency : small.length;
      // 大文件分片并行度：直接取设置里的并发数，不能按待传数量截断——
      // 否则「只备份一个视频」时会退化成单连接，恰好是最需要提速的场景。
      final largeParallelism = concurrency;

      // 先一次性落任务记录（pending），再由 worker 逐个领取转为 running。
      // id 用「毫秒_序号」保证批量创建时不重号（同一毫秒内会重复）。
      final base = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < pending.length; i++) {
        pending[i].taskId = '${base}_$i';
      }
      final existing = state.valueOrNull ?? const <TransferTask>[];
      final now = DateTime.now();
      await _storage.saveTransfers([
        ...existing,
        for (final item in pending)
          TransferTask(
            id: item.taskId,
            serverId: serverId,
            transferType: TransferType.upload,
            remotePath: item.remotePath,
            localPath: item.localPath,
            totalBytes: item.size,
            writtenBytes: 0,
            progress: 0,
            status: TransferStatus.pending,
            errorMessage: null,
            createdAt: now,
            updatedAt: now,
          ),
      ]);
      await load();

      // 为每个 worker 建立一条独立连接；NAS 限制并发连接数时按实际数量降级。
      // 至少建一条：即使本次全是分片上传的大文件（小文件 worker 池为空），
      // 建目录也需要一条连接，同时这条连接也充当「服务器是否可达」的探针。
      // 大文件的分片连接由 uploadFileParallel 自行建立，不占用这里的池。
      final poolSize = workerCount > 0 ? workerCount : 1;
      final connections = <SmbConnect>[];
      for (var i = 0; i < poolSize; i++) {
        try {
          connections.add(await _smbService
              .createConnection(server)
              .timeout(_connectTimeout));
        } catch (_) {
          break;
        }
      }

      if (connections.isEmpty) {
        for (final item in pending) {
          _updateTaskComplete(item.taskId, TransferStatus.failed,
              errorMessage: '无法连接服务器');
        }
        failedCount += pending.length;
      } else {
        try {
          // 目录先串行建好（用第一条连接），避免并发建目录相互冲突。
          final dirs = <String>{
            for (final item in pending)
              if (item.albumName.isNotEmpty) item.albumName,
          };
          for (final dir in dirs) {
            await _smbService.createDirectoryVia(connections.first, server, dir);
          }

          /// 上传一个待传项并登记结果；[upload] 只负责把字节送达远端。
          ///
          /// 连接类错误（含卡死超时）重试同一文件；[onRetry] 供调用方重建自己
          /// 持有的连接，大文件分片上传的连接由 uploadFileParallel 自行管理，
          /// 无需重建，因此可以不传。
          Future<void> runItem(
            _PendingUpload item,
            Future<void> Function() upload, {
            Future<void> Function()? onRetry,
          }) async {
            var attempts = 3;
            while (true) {
              try {
                await upload();
                _updateTaskComplete(item.taskId, TransferStatus.done);
                successCount += 1;
                syncedPaths.add(item.localPath);
                uploadedRemotePaths.add(item.remotePath);
                return;
              } catch (e) {
                if (attempts-- > 0 && SmbService.isConnectionError(e)) {
                  if (onRetry == null) continue;
                  // 连接可能已失效：重建本 worker 的连接后重试当前文件。
                  try {
                    await onRetry();
                    continue;
                  } catch (_) {
                    // 重连失败，落回失败处理。
                  }
                }
                _updateTaskComplete(item.taskId, TransferStatus.failed,
                    errorMessage: e.toString());
                failedCount += 1;
                return;
              }
            }
          }

          // 大文件串行处理：同一时刻只跑一个视频，让它独占 [largeParallelism] 条
          // 连接做分片并行。多个大文件同时跑只会互相抢带宽、把连接数顶到上限。
          for (final item in large) {
            _updateTaskStatus(item.taskId, TransferStatus.running);
            await runItem(
              item,
              () => _smbService.uploadFileParallel(
                server,
                item.remotePath,
                item.localPath,
                parallelism: largeParallelism,
                onProgress: (progress) => _updateTaskProgress(
                  item.taskId,
                  (progress * item.size).round(),
                  progress,
                ),
              ),
            );
          }

          // 小文件沿用 worker 池并发上传（每个 worker 独占一条连接）。
          var next = 0;
          Future<void> worker(int index) async {
            while (true) {
              // 无 await 间隔，索引分配在事件循环中天然原子，无并发竞争。
              final local = next;
              if (local >= small.length) break;
              next = local + 1;

              final item = small[local];
              _updateTaskStatus(item.taskId, TransferStatus.running);

              await runItem(
                item,
                () => _smbService.uploadFileVia(
                  connections[index],
                  server,
                  item.remotePath,
                  item.localPath,
                  onProgress: (progress) => _updateTaskProgress(
                    item.taskId,
                    (progress * item.size).round(),
                    progress,
                  ),
                ),
                onRetry: () async {
                  await _closeQuietly(connections[index]);
                  connections[index] = await _smbService
                      .createConnection(server)
                      .timeout(_connectTimeout);
                },
              );
            }
          }

          await Future.wait([
            for (var i = 0; i < connections.length; i++) worker(i),
          ]);
        } finally {
          for (final conn in connections) {
            await _closeQuietly(conn);
          }
        }
      }
    }

    // 兜底落盘：完成类记录在 _updateTaskComplete 里是按时间节流的，
    // 批次结束时必须整表写一次，否则 load() 会把内存中刚变成 done 的记录读回旧值。
    await _storage.saveTransfers(state.valueOrNull ?? const <TransferTask>[]);
    await load();
    // 兜底：把「成功上传」与「远端已存在而跳过」两类一并标记为已同步。
    // 单个文件成功/跳过时已即时标记（见 _updateTaskComplete 与跳过分支），
    // 这里再做一次并集兜底并强制落盘，保证进程被杀也不丢。
    if (syncedPaths.isNotEmpty) {
      syncedPhotosNotifier.markSynced(serverId, syncedPaths);
    }
    await syncedPhotosNotifier.flushNow();

    // 上传改变了远端目录结构与文件内容，必须失效 SMB 侧缓存并让界面重新拉取，
    // 否则新建的相册要等满 7 天缓存 TTL 才会出现在「SMB 相册」里。
    if (uploadedRemotePaths.isNotEmpty) {
      try {
        await _smbService.invalidateAfterUploads(server, uploadedRemotePaths);
      } catch (_) {
        // 缓存失效失败不应让备份整体失败；最坏情况是沿用旧缓存直到 TTL 过期。
      }
      _ref.invalidate(allSmbAlbumsProvider);
      _ref.invalidate(smbItemsPagedProvider);
    }

    return BackupResult(
      successCount: successCount,
      failedCount: failedCount,
      skippedCount: skippedCount,
    );
  }

  /// 建立一条 SMB 连接的上限：网络断开时底层同样可能一直等，
  /// 不设上限会让 worker 卡在重连上，队列整体停摆。
  static const Duration _connectTimeout = Duration(seconds: 20);

  /// 关闭一条 SMB 连接；底层 `Socket.close()` 会等待未发完的数据，
  /// 断链时可能永久挂住，因此加上限：连接本就已废弃，关不掉就直接放弃。
  static Future<void> _closeQuietly(SmbConnect connect) async {
    try {
      await connect.close().timeout(const Duration(seconds: 5));
    } catch (_) {
      // 连接已失效或被挂住，无需处理。
    }
  }

  /// 更新任务状态（并发上传的 worker 领取任务时把 pending 置为 running）。
  void _updateTaskStatus(String taskId, TransferStatus status) {
    state.whenData((tasks) {
      final updated = tasks.map((t) {
        if (t.id != taskId) return t;
        return TransferTask(
          id: t.id,
          serverId: t.serverId,
          transferType: t.transferType,
          remotePath: t.remotePath,
          localPath: t.localPath,
          totalBytes: t.totalBytes,
          writtenBytes: t.writtenBytes,
          progress: t.progress,
          status: status,
          errorMessage: t.errorMessage,
          createdAt: t.createdAt,
          updatedAt: DateTime.now(),
        );
      }).toList();
      state = AsyncValue.data(updated);
      _storage.saveTransfers(updated);
    });
  }

  void _updateTaskProgress(String taskId, int writtenBytes, double progress) {
    // 按任务节流界面刷新：进度条 6~7Hz 已足够顺滑，而每次刷新都要重建整个
    // 任务列表，过密只会挤占上传循环的时间片。
    final now = DateTime.now();
    final last = _lastProgressUiAt[taskId];
    if (last != null && now.difference(last) < _progressUiInterval) return;
    _lastProgressUiAt[taskId] = now;

    state.whenData((tasks) {
      final updated = tasks.map((t) {
        if (t.id == taskId && t.status == TransferStatus.running) {
          return TransferTask(
            id: t.id,
            serverId: t.serverId,
            transferType: t.transferType,
            remotePath: t.remotePath,
            localPath: t.localPath,
            totalBytes: t.totalBytes,
            writtenBytes: writtenBytes,
            progress: progress,
            status: t.status,
            errorMessage: t.errorMessage,
            createdAt: t.createdAt,
            updatedAt: DateTime.now(),
          );
        }
        return t;
      }).toList();
      state = AsyncValue.data(updated);
      // 进度回调节奏很高（每 64KB 一次），整表落盘过密会拖慢上传并卡顿 UI。
      // 内存状态按上面的节流更新（界面流畅），磁盘持久化再按时间节流；
      // 任务完成时会由 _updateTaskComplete 落一次最终状态，不会丢进度。
      if (now.difference(_lastProgressPersist) >= _progressPersistInterval) {
        _lastProgressPersist = now;
        _storage.saveTransfers(updated);
      }
    });
  }

  void _updateTaskComplete(String taskId, TransferStatus status, {String? errorMessage}) {
    state.whenData((tasks) {
      String? donePath;
      String? doneServerId;
      final updated = tasks.map((t) {
        if (t.id == taskId) {
          if (status == TransferStatus.done) {
            donePath = t.localPath;
            doneServerId = t.serverId;
          }
          return TransferTask(
            id: t.id,
            serverId: t.serverId,
            transferType: t.transferType,
            remotePath: t.remotePath,
            localPath: t.localPath,
            totalBytes: t.totalBytes,
            writtenBytes: status == TransferStatus.done ? t.totalBytes : t.writtenBytes,
            progress: status == TransferStatus.done ? 1.0 : t.progress,
            status: status,
            errorMessage: errorMessage,
            createdAt: t.createdAt,
            updatedAt: DateTime.now(),
          );
        }
        return t;
      }).toList();
      state = AsyncValue.data(updated);
      _lastProgressUiAt.remove(taskId);
      // 「完成」记录随批量上传逐条产生，每次都整表 JSON 落盘会退化成 O(n²)
      // 的序列化开销（长队列时单次可达数百毫秒），直接卡住同 isolate 的上传循环。
      // 完成项改为按时间节流落盘、批量结束再统一兜底（见 backupPhotos）；
      // 失败项必须立即落盘，否则进程被杀会丢掉「重试失败」的入口。
      final now = DateTime.now();
      if (status != TransferStatus.done ||
          now.difference(_lastProgressPersist) >= _progressPersistInterval) {
        _lastProgressPersist = now;
        _storage.saveTransfers(updated);
      }
      // 单张上传成功即标记已同步：界面「未同步」栏实时收缩，无需等整批结束或手动刷新。
      if (donePath != null &&
          donePath!.isNotEmpty &&
          doneServerId != null) {
        _ref
            .read(syncedPhotosProvider.notifier)
            .markSynced(doneServerId!, [donePath!]);
      }
    });
  }

  /// 把某台服务器的「已备份」记录与远端实际内容核对一致。
  ///
  /// 用于：启动时、切换服务器时。对每条「已记录为已备份」的本地路径，按
  /// 「<相册名>/<文件名>」去远端查同名同大小文件：远端缺失或大小不符 →
  /// 从该服务器的已备份集合移除（界面重新显示为待备份）；本地文件已被删除
  /// 的记录也一并清理。任何网络异常都直接放弃、不改记录，避免误清空。
  Future<void> reconcileWithServer(String serverId) async {
    final servers = await _storage.getSmbServers();
    SmbConfig? server;
    for (final s in servers) {
      if (s.id == serverId) {
        server = s;
        break;
      }
    }
    if (server == null) return;

    final notifier = _ref.read(syncedPhotosProvider.notifier);
    final recorded = notifier.of(serverId).toList();
    if (recorded.isEmpty) return;

    // 先确认服务器可达。listFilesWithSize 在「连不上」与「目录为空」两种情况下
    // 都返回空表，若不先探活，一次网络抖动会把所有记录误判为「远端已删」而清空。
    if (!await _smbService.testConnection(server)) {
      debugPrint('[reconcile] $serverId 不可达，跳过核对');
      return;
    }

    // 相册名 → 远端文件清单（文件名 → 大小）。
    final albumOf = <String, String>{};
    for (final p in recorded) {
      albumOf[p] = PhotoService.albumNameOf(p);
    }
    final remoteIndex = <String, Map<String, int>>{};
    for (final album in albumOf.values.toSet()) {
      remoteIndex[album] = await _smbService.listFilesWithSize(server, album);
    }

    final stillSynced = <String>{};
    for (final p in recorded) {
      if (!File(p).existsSync()) continue; // 本地已删，丢弃记录。
      final album = albumOf[p] ?? '';
      final fileName = p.split('/').last;
      int size;
      try {
        size = await File(p).length();
      } catch (_) {
        continue;
      }
      final remoteSize = remoteIndex[album]?[fileName];
      if (size > 0 && remoteSize != null && remoteSize == size) {
        stillSynced.add(p);
      }
    }
    debugPrint('[reconcile] $serverId 记录 ${recorded.length} 条 → 仍已备份 '
        '${stillSynced.length} 条');
    notifier.replaceSynced(serverId, stillSynced);
    await notifier.flushNow();
  }
}

/// 本地尚未备份到 SMB 的照片（待备份列表）。
///
/// 导航栏「传输」标签与传输页的「未同步」均以此为准，保证两处数量一致。
final unsyncedPhotosProvider = Provider<List<MediaItem>>((ref) {
  final photos = ref.watch(localPhotosProvider).valueOrNull ?? const [];
  // 以「当前服务器」的已备份集合判定：切换服务器后待备份数量随之变化。
  final synced = ref.watch(syncedForCurrentServerProvider);
  return photos.where((p) => !synced.contains(p.path)).toList();
});

/// 待备份照片数量，供导航栏「传输」标签展示。
final unsyncedCountProvider =
    Provider<int>((ref) => ref.watch(unsyncedPhotosProvider).length);
