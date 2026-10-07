import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';
import '../services/local_storage_service.dart';
import '../services/smb_service.dart';

class BackupResult {
  final int successCount;
  final int failedCount;

  const BackupResult({required this.successCount, required this.failedCount});

  bool get allSucceeded => failedCount == 0;
  bool get allFailed => successCount == 0 && failedCount > 0;
}

final transfersProvider = StateNotifierProvider<TransfersNotifier, AsyncValue<List<TransferTask>>>(
  (ref) => TransfersNotifier(),
);

class TransfersNotifier extends StateNotifier<AsyncValue<List<TransferTask>>> {
  final _storage = LocalStorageService();
  final _smbService = SmbService();
  final Map<String, StreamController<double>> _progressControllers = {};

  TransfersNotifier() : super(const AsyncValue.loading()) {
    load();
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

  Future<BackupResult> backupPhotos(String serverId, List<String> localPaths, String remoteDir) async {
    final servers = await _storage.getSmbServers();
    final server = servers.firstWhere((s) => s.id == serverId);
    var successCount = 0;
    var failedCount = 0;

    for (final path in localPaths) {
      final taskId = DateTime.now().millisecondsSinceEpoch.toString();
      final file = File(path);
      final fileSize = await file.length();

      final task = TransferTask(
        id: taskId,
        serverId: serverId,
        transferType: TransferType.upload,
        remotePath: '$remoteDir/${path.split('/').last}',
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

        final bytes = await file.readAsBytes();
        int lastWrittenBytes = 0;

        await _smbService.uploadFile(
          server,
          '$remoteDir/${path.split('/').last}',
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
      } catch (e) {
        _updateTaskComplete(taskId, TransferStatus.failed, errorMessage: e.toString());
        failedCount += 1;
      } finally {
        _progressControllers.remove(taskId)?.close();
      }
    }

    await load();
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
