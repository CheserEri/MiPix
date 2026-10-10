import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';
import '../services/local_storage_service.dart';
import '../services/photo_service.dart';
import '../services/smb_service.dart';

class BackupResult {
  final int successCount;
  final int failedCount;

  const BackupResult({required this.successCount, required this.failedCount});

  bool get allSucceeded => failedCount == 0;
  bool get allFailed => successCount == 0 && failedCount > 0;
}

final transfersProvider = StateNotifierProvider<TransfersNotifier, AsyncValue<List<TransferTask>>>(
  (ref) => TransfersNotifier(ref),
);

/// 已成功备份到 SMB 的本地图片路径集合。
final syncedPhotosProvider =
    StateNotifierProvider<SyncedPhotosNotifier, Set<String>>(
  (ref) => SyncedPhotosNotifier(),
);

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

class SyncedPhotosNotifier extends StateNotifier<Set<String>> {
  final _storage = LocalStorageService();

  SyncedPhotosNotifier() : super(<String>{}) {
    load();
  }

  Future<void> load() async {
    state = await _storage.getSyncedPhotos();
  }

  Future<void> markSynced(List<String> localPaths) async {
    if (localPaths.isEmpty) return;
    await _storage.markSynced(localPaths);
    state = {...state, ...localPaths};
  }
}

class TransfersNotifier extends StateNotifier<AsyncValue<List<TransferTask>>> {
  final Ref _ref;
  final _storage = LocalStorageService();
  final _smbService = SmbService();
  final Map<String, StreamController<double>> _progressControllers = {};

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

  Future<BackupResult> backupPhotos(String serverId, List<String> localPaths) async {
    final servers = await _storage.getSmbServers();
    final server = servers.firstWhere((s) => s.id == serverId);
    var successCount = 0;
    var failedCount = 0;
    final syncedPaths = <String>[];
    // 同一次备份中，同一相册目录只需要在远端创建一次。
    final ensuredDirs = <String>{};
    // 已在传输中的同一文件直接跳过：并发上传同一目标文件会被 SMB 服务端
    // （Windows）判定为共享冲突（"being used by another process"）导致失败。
    final activePaths = (state.valueOrNull ?? [])
        .where((t) =>
            t.status == TransferStatus.running ||
            t.status == TransferStatus.pending)
        .map((t) => t.localPath)
        .toSet();

    for (final path in localPaths) {
      // add 返回 false 表示该路径已在传输中或本次列表内重复。
      if (path.isEmpty || !activePaths.add(path)) continue;

      final taskId = DateTime.now().millisecondsSinceEpoch.toString();
      final file = File(path);
      final fileSize = await file.length();

      // 复刻手机相册目录结构：/storage/emulated/0/DCIM/Camera/a.jpg
      // 备份为 <rootPath>/DCIM/Camera/a.jpg，保证远端文件夹与手机相册同名。
      final albumDir = PhotoService.albumDirOf(path);
      final fileName = path.split('/').last;
      final remotePath = albumDir.isEmpty ? fileName : '$albumDir/$fileName';

      final task = TransferTask(
        id: taskId,
        serverId: serverId,
        transferType: TransferType.upload,
        remotePath: remotePath,
        localPath: path,
        totalBytes: fileSize,
        writtenBytes: 0,
        progress: 0,
        status: TransferStatus.running,
        errorMessage: null,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final tasks = state.valueOrNull ?? [];
      await _storage.saveTransfers([...tasks, task]);
      await load();

      try {
        final progressController = StreamController<double>.broadcast();
        _progressControllers[taskId] = progressController;

        if (albumDir.isNotEmpty && !ensuredDirs.contains(albumDir)) {
          await _smbService.ensureRemoteDirectory(server, albumDir);
          ensuredDirs.add(albumDir);
        }

        final bytes = await file.readAsBytes();
        int lastWrittenBytes = 0;

        await _smbService.uploadFile(
          server,
          remotePath,
          bytes,
          onProgress: (progress) {
            final writtenBytes = (progress * fileSize).round();
            if (writtenBytes != lastWrittenBytes) {
              lastWrittenBytes = writtenBytes;
              _updateTaskProgress(taskId, writtenBytes, progress);
            }
          },
        );

        _updateTaskComplete(taskId, TransferStatus.done);
        successCount += 1;
        syncedPaths.add(path);
      } catch (e) {
        _updateTaskComplete(taskId, TransferStatus.failed, errorMessage: e.toString());
        failedCount += 1;
      } finally {
        _progressControllers.remove(taskId)?.close();
      }
    }

    await load();
    // 标记成功备份（上传）的本地图片为「已同步」。
    if (syncedPaths.isNotEmpty) {
      await _ref.read(syncedPhotosProvider.notifier).markSynced(syncedPaths);
    }
    return BackupResult(successCount: successCount, failedCount: failedCount);
  }

  void _updateTaskProgress(String taskId, int writtenBytes, double progress) {
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
      _storage.saveTransfers(updated);
    });
  }

  void _updateTaskComplete(String taskId, TransferStatus status, {String? errorMessage}) {
    state.whenData((tasks) {
      final updated = tasks.map((t) {
        if (t.id == taskId) {
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
      _storage.saveTransfers(updated);
    });
  }
}

final activeTransferCountProvider = Provider<int>((ref) {
  final tasks = ref.watch(transfersProvider);
  return tasks.valueOrNull?.where((t) => t.status == TransferStatus.running).length ?? 0;
});
