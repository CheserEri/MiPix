import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mipix_app/models/models.dart';
import 'package:mipix_app/providers/transfer_provider.dart';
import 'package:mipix_app/services/smb_service.dart';

/// 构造一个冲突候选，减少测试噪音。
ConflictCandidate _cand(String localPath, String album, String remotePath, int size) {
  return ConflictCandidate(
    localPath: localPath,
    albumName: album,
    remotePath: remotePath,
    size: size,
  );
}

/// 断连恢复相关单测：识别 socket 已关闭类错误、以及单文件「重连 + 有限重试」
/// 与整批「连续失败快速收敛」的策略。
void main() {
  group('SmbService.isConnectionError', () {
    test('识别本地 socket 已关闭类错误', () {
      expect(
        SmbService.isConnectionError(StateError('Bad state: StreamSink is closed')),
        isTrue,
      );
      expect(
        SmbService.isConnectionError(StateError('Bad state: Socket is closed')),
        isTrue,
      );
      expect(
        SmbService.isConnectionError("Can't read 8024 from Socket!"),
        isTrue,
      );
      expect(
        SmbService.isConnectionError(const SocketException('Connection reset by peer')),
        isTrue,
      );
      expect(
        SmbService.isConnectionError(TimeoutException('stall')),
        isTrue,
      );
    });

    test('不把宽泛的 bad state 与程序性错误误判为连接问题', () {
      expect(
        SmbService.isConnectionError(StateError('Bad state: parser is not ready')),
        isFalse,
      );
      expect(SmbService.isConnectionError(ArgumentError('invalid argument')), isFalse);
      expect(SmbService.isConnectionError(Exception('Access is denied.')), isFalse);
    });
  });

  group('UploadFailureGuard', () {
    test('连续连接类失败达到阈值即停止本批', () {
      final guard = UploadFailureGuard(maxConsecutiveConnectionFailures: 3);
      guard.record(TimeoutException('t'));
      guard.record(StateError('Bad state: StreamSink is closed'));
      expect(guard.shouldStop, isFalse);
      guard.record(const SocketException('down'));
      expect(guard.shouldStop, isTrue);
    });

    test('非连接类失败会清零连续计数', () {
      final guard = UploadFailureGuard(maxConsecutiveConnectionFailures: 3);
      guard.record(TimeoutException('t'));
      guard.record(TimeoutException('t'));
      guard.record(Exception('Access is denied.'));
      guard.record(TimeoutException('t'));
      expect(guard.shouldStop, isFalse);
      expect(guard.consecutiveFailures, 1);
    });

    test('成功会清零连续计数', () {
      final guard = UploadFailureGuard(maxConsecutiveConnectionFailures: 2);
      guard.record(TimeoutException('t'));
      guard.recordSuccess();
      guard.record(TimeoutException('t'));
      expect(guard.shouldStop, isFalse);
    });
  });

  group('uploadWithRetry', () {
    test('连接类错误：先重建连接再重试，最终成功', () async {
      final guard = UploadFailureGuard();
      final calls = <String>[];
      var attempts = 0;
      final error = await uploadWithRetry(
        guard: guard,
        upload: () async {
          attempts += 1;
          calls.add('upload$attempts');
          if (attempts < 3) {
            throw StateError('Bad state: StreamSink is closed');
          }
        },
        reconnect: () async => calls.add('reconnect'),
      );
      expect(error, isNull);
      // 顺序必须是「上传失败 → 重建连接 → 再重试」，不是拿旧连接硬试。
      expect(calls, ['upload1', 'reconnect', 'upload2', 'reconnect', 'upload3']);
    });

    test('重连失败立即收敛为失败，不再空转重试', () async {
      final guard = UploadFailureGuard();
      var uploads = 0;
      var reconnects = 0;
      final error = await uploadWithRetry(
        guard: guard,
        upload: () async {
          uploads += 1;
          throw TimeoutException('stall');
        },
        reconnect: () async {
          reconnects += 1;
          throw const SocketException('no route to host');
        },
      );
      expect(error, isA<TimeoutException>());
      expect(uploads, 1);
      expect(reconnects, 1);
    });

    test('非连接类错误不重试（如权限不足）', () async {
      final guard = UploadFailureGuard();
      var uploads = 0;
      var reconnects = 0;
      final error = await uploadWithRetry(
        guard: guard,
        upload: () async {
          uploads += 1;
          throw Exception('Access is denied.');
        },
        reconnect: () async => reconnects += 1,
      );
      expect(error, isNotNull);
      expect(uploads, 1);
      expect(reconnects, 0);
    });

    test('大文件分片（无重连回调）：连接类错误直接换一批新连接重试', () async {
      final guard = UploadFailureGuard();
      var attempts = 0;
      final error = await uploadWithRetry(
        guard: guard,
        upload: () async {
          attempts += 1;
          if (attempts < 2) throw const SocketException('reset');
        },
      );
      expect(error, isNull);
      expect(attempts, 2);
    });

    test('重试次数耗尽即收敛为失败', () async {
      final guard = UploadFailureGuard();
      var uploads = 0;
      final error = await uploadWithRetry(
        guard: guard,
        upload: () async {
          uploads += 1;
          throw TimeoutException('stall');
        },
        reconnect: () async {},
        maxRetries: 2,
      );
      expect(error, isA<TimeoutException>());
      expect(uploads, 3); // 首次 + 2 次重试
    });

    test('链路被判不可用后不再继续重试，队列尽快停止', () async {
      final guard = UploadFailureGuard(maxConsecutiveConnectionFailures: 1);
      var uploads = 0;
      var reconnects = 0;
      final error = await uploadWithRetry(
        guard: guard,
        upload: () async {
          uploads += 1;
          throw TimeoutException('stall');
        },
        reconnect: () async => reconnects += 1,
      );
      expect(error, isNotNull);
      expect(uploads, 1);
      expect(reconnects, 0);
      expect(guard.shouldStop, isTrue);
    });
  });

  group('reconcileSynced', () {
    test('任一相册清单为 null 即返回 null（放弃本轮，不清空记录）', () {
      final result = reconcileSynced(
        candidates: ['/s/DCIM/Camera/a.jpg', '/s/DCIM/X/b.jpg'],
        albumOf: {'/s/DCIM/Camera/a.jpg': '相机', '/s/DCIM/X/b.jpg': 'X'},
        remoteIndex: {'相机': {'a.jpg': 10}, 'X': null},
        localSizes: {'/s/DCIM/Camera/a.jpg': 10, '/s/DCIM/X/b.jpg': 20},
      );
      expect(result, isNull);
    });

    test('清单缺失（key 不存在）同样视为不完整', () {
      final result = reconcileSynced(
        candidates: ['/s/DCIM/Camera/a.jpg'],
        albumOf: {'/s/DCIM/Camera/a.jpg': '相机'},
        remoteIndex: {},
        localSizes: {'/s/DCIM/Camera/a.jpg': 10},
      );
      expect(result, isNull);
    });

    test('相册清单为空 map：该相册全部判为未备份', () {
      final result = reconcileSynced(
        candidates: ['/s/DCIM/Camera/a.jpg'],
        albumOf: {'/s/DCIM/Camera/a.jpg': '相机'},
        remoteIndex: {'相机': <String, int>{}},
        localSizes: {'/s/DCIM/Camera/a.jpg': 10},
      );
      expect(result, isNotNull);
      expect(result, isEmpty);
    });

    test('命中「同名同大小」保留；同名不同大小不保留', () {
      final result = reconcileSynced(
        candidates: ['/s/DCIM/Camera/a.jpg', '/s/DCIM/Camera/b.jpg'],
        albumOf: {
          '/s/DCIM/Camera/a.jpg': '相机',
          '/s/DCIM/Camera/b.jpg': '相机',
        },
        remoteIndex: {
          '相机': {'a.jpg': 10, 'b.jpg': 999},
        },
        localSizes: {'/s/DCIM/Camera/a.jpg': 10, '/s/DCIM/Camera/b.jpg': 20},
      );
      expect(result, {'/s/DCIM/Camera/a.jpg'});
    });

    test('本地文件已删除/不可读：丢弃记录', () {
      final result = reconcileSynced(
        candidates: ['/s/DCIM/Camera/gone.jpg'],
        albumOf: {'/s/DCIM/Camera/gone.jpg': '相机'},
        remoteIndex: {
          '相机': {'gone.jpg': 10},
        },
        localSizes: {},
      );
      expect(result, isEmpty);
    });

    test('识别不出相册（空串）不参与对账，也不影响清单完整性判定', () {
      final result = reconcileSynced(
        candidates: ['/other/x.jpg'],
        albumOf: {'/other/x.jpg': ''},
        remoteIndex: {},
        localSizes: {'/other/x.jpg': 5},
      );
      expect(result, isEmpty);
    });
  });

  group('TransferStatus 终态语义', () {
    test('skipped 可 JSON round-trip 且保留原因', () {
      final task = TransferTask(
        id: '1',
        serverId: 's',
        transferType: TransferType.upload,
        remotePath: '相机/a.jpg',
        localPath: '/s/DCIM/Camera/a.jpg',
        totalBytes: 100,
        writtenBytes: 0,
        progress: 0,
        status: TransferStatus.skipped,
        errorMessage: conflictMsgRemoteLarger,
        createdAt: DateTime.parse('2026-01-01T00:00:00.000'),
        updatedAt: DateTime.parse('2026-01-01T00:00:00.000'),
      );
      final back = TransferTask.fromJson(task.toJson());
      expect(back.status, TransferStatus.skipped);
      expect(back.errorMessage, conflictMsgRemoteLarger);
    });

    test('clearCompleted：skipped 与 done/failed 清除，活动态保留', () {
      // 与既有语义一致：done 与 failed 都可被「清除已完成」清掉，现在 skipped 一并清除。
      expect(keepAfterClearCompleted(TransferStatus.skipped), isFalse);
      expect(keepAfterClearCompleted(TransferStatus.done), isFalse);
      expect(keepAfterClearCompleted(TransferStatus.failed), isFalse);
      expect(keepAfterClearCompleted(TransferStatus.pending), isTrue);
      expect(keepAfterClearCompleted(TransferStatus.running), isTrue);
      expect(keepAfterClearCompleted(TransferStatus.paused), isTrue);
    });
  });

  group('planConflicts', () {
    test('6.1 远端清单无该文件 → 正常上传', () {
      final plan = planConflicts(
        candidates: [_cand('/s/DCIM/Camera/a.jpg', '相机', '相机/a.jpg', 100)],
        remoteIndex: {'相机': <String, int>{}},
      );
      expect(plan.uploads.length, 1);
      expect(plan.uploads.single.action, PlanAction.upload);
      expect(plan.uploads.single.needsHash, isFalse);
      expect(plan.probes, isEmpty);
      expect(plan.settled, isEmpty);
    });

    test('6.2 不同相册同名 → 各自上传', () {
      final plan = planConflicts(
        candidates: [
          _cand('/s/DCIM/A/x.jpg', 'A', 'A/x.jpg', 100),
          _cand('/s/DCIM/B/x.jpg', 'B', 'B/x.jpg', 200),
        ],
        remoteIndex: {'A': <String, int>{}, 'B': <String, int>{}},
      );
      expect(
        plan.uploads.map((d) => d.candidate.remotePath).toList(),
        ['A/x.jpg', 'B/x.jpg'],
      );
    });

    test('6.3 本地更大 → 上传替换', () {
      final plan = planConflicts(
        candidates: [_cand('/s/DCIM/Camera/a.jpg', '相机', '相机/a.jpg', 200)],
        remoteIndex: {
          '相机': {'a.jpg': 100},
        },
      );
      expect(plan.uploads.single.action, PlanAction.upload);
      expect(plan.uploads.single.needsHash, isFalse);
      expect(plan.settled, isEmpty);
    });

    test('6.4 远端更大 → 拒绝覆盖并给出原因', () {
      final plan = planConflicts(
        candidates: [_cand('/s/DCIM/Camera/a.jpg', '相机', '相机/a.jpg', 100)],
        remoteIndex: {
          '相机': {'a.jpg': 200},
        },
      );
      expect(plan.uploads, isEmpty);
      expect(plan.probes, isEmpty);
      expect(plan.settled.single.action, PlanAction.skipKeepRemote);
      expect(plan.settled.single.message, conflictMsgRemoteLarger);
    });

    test('6.5/6.6 同名同大小 → 进入哈希探针（不直接判已备份）', () {
      final plan = planConflicts(
        candidates: [_cand('/s/DCIM/Camera/a.jpg', '相机', '相机/a.jpg', 100)],
        remoteIndex: {
          '相机': {'a.jpg': 100},
        },
      );
      expect(plan.uploads, isEmpty);
      expect(plan.probes.single.needsHash, isTrue);
    });

    test('6.7 同批次同远端路径 → 取大者，落选带原因，反转输入结果一致', () {
      final small = _cand('/s/DCIM/Camera/a.jpg', '相机', '相机/a.jpg', 100);
      final big = _cand('/s/DCIM/Camera/a copy.jpg', '相机', '相机/a.jpg', 300);
      ConflictPlan run(List<ConflictCandidate> input) => planConflicts(
            candidates: input,
            remoteIndex: {'相机': <String, int>{}},
          );
      final p1 = run([small, big]);
      final p2 = run([big, small]);
      expect(p1.uploads.single.candidate.localPath, '/s/DCIM/Camera/a copy.jpg');
      expect(p1.settled.single.action, PlanAction.skipBatchCollision);
      expect(
        p1.settled.single.message,
        conflictMsgBatchCollision(winnerLarger: true, winnerName: 'a copy.jpg'),
      );
      expect(p2.uploads.single.candidate.localPath, p1.uploads.single.candidate.localPath);
      expect(p2.settled.single.message, p1.settled.single.message);
    });

    test('6.8 清单读取失败（null）→ fail-closed，全部不写', () {
      final plan = planConflicts(
        candidates: [
          _cand('/s/DCIM/Camera/a.jpg', '相机', '相机/a.jpg', 100),
          _cand('/s/DCIM/Camera/b.jpg', '相机', '相机/b.jpg', 200),
        ],
        remoteIndex: {'相机': null},
      );
      expect(plan.uploads, isEmpty);
      expect(plan.probes, isEmpty);
      expect(plan.settled.length, 2);
      expect(plan.settled.every((d) => d.action == PlanAction.failUnknown), isTrue);
      expect(plan.settled.first.message, conflictMsgRemoteManifestFailed);
    });

    test('清单 key 缺失同样视为不可知（fail-closed）', () {
      final plan = planConflicts(
        candidates: [_cand('/s/DCIM/Camera/a.jpg', '相机', '相机/a.jpg', 100)],
        remoteIndex: {},
      );
      expect(plan.uploads, isEmpty);
      expect(plan.settled.single.action, PlanAction.failUnknown);
    });

    test('同批次同远端路径遇到清单读取失败时整组都可重试', () {
      final plan = planConflicts(
        candidates: [
          _cand('/s/DCIM/Camera/a.jpg', '相机', '相机/x.jpg', 100),
          _cand('/s/DCIM/Camera/b.jpg', '相机', '相机/x.jpg', 200),
        ],
        remoteIndex: {'相机': null},
      );

      expect(plan.uploads, isEmpty);
      expect(plan.probes, isEmpty);
      expect(plan.settled, hasLength(2));
      expect(plan.settled.every((d) => d.action == PlanAction.failUnknown), isTrue);
      expect(
        plan.settled.every((d) => d.message == conflictMsgRemoteManifestFailed),
        isTrue,
      );
    });

    test('6.10 同批次同路径同大小 → 按固定规则择一，落选不称胜者更大', () {
      final a = _cand('/s/DCIM/Camera/a.jpg', '相机', '相机/x.jpg', 100);
      final b = _cand('/s/DCIM/Camera/b.jpg', '相机', '相机/x.jpg', 100);
      ConflictPlan run(List<ConflictCandidate> input) => planConflicts(
            candidates: input,
            remoteIndex: {'相机': <String, int>{}},
          );
      final p1 = run([a, b]);
      final p2 = run([b, a]);
      expect(p1.uploads.single.candidate.localPath, '/s/DCIM/Camera/a.jpg');
      expect(p2.uploads.single.candidate.localPath, '/s/DCIM/Camera/a.jpg');
      expect(
        p1.settled.single.message,
        conflictMsgBatchCollision(winnerLarger: false, winnerName: 'a.jpg'),
      );
      expect(p1.settled.single.message!.contains('更大'), isFalse);
    });

    test('同路径同大小合并为单个 probe（避免重复哈希同一远端文件）', () {
      final plan = planConflicts(
        candidates: [
          _cand('/s/DCIM/Camera/a.jpg', '相机', '相机/x.jpg', 100),
          _cand('/s/DCIM/Camera/b.jpg', '相机', '相机/x.jpg', 100),
        ],
        remoteIndex: {
          '相机': {'x.jpg': 100},
        },
      );
      expect(plan.probes.length, 1);
      expect(plan.settled.single.action, PlanAction.skipBatchCollision);
    });

    test('根目录候选（albumName == ""）可正确读取远端索引', () {
      final plan = planConflicts(
        candidates: [_cand('/storage/emulated/0/root.jpg', '', 'root.jpg', 100)],
        remoteIndex: {
          '': {'root.jpg': 200},
        },
      );
      expect(plan.uploads, isEmpty);
      expect(plan.settled.single.action, PlanAction.skipKeepRemote);
    });

    test('根目录索引为 null → fail-closed', () {
      final plan = planConflicts(
        candidates: [_cand('/storage/emulated/0/root.jpg', '', 'root.jpg', 100)],
        remoteIndex: {'': null},
      );
      expect(plan.uploads, isEmpty);
      expect(plan.settled.single.action, PlanAction.failUnknown);
    });
  });

  group('resolveHashProbes', () {
    test('6.5 同大同哈希相同 → skipSynced（视为已备份）', () {
      final plan = planConflicts(
        candidates: [_cand('/s/DCIM/Camera/a.jpg', '相机', '相机/a.jpg', 100)],
        remoteIndex: {
          '相机': {'a.jpg': 100},
        },
      );
      final res = resolveHashProbes(
        probes: plan.probes,
        remoteHashes: {'相机/a.jpg': 'abc'},
        localHashes: {'相机/a.jpg': 'abc'},
      );
      expect(res.single.action, PlanAction.skipSynced);
      expect(res.single.message, isNull);
    });

    test('6.6 同大同哈希不同 → 保留远端并提示', () {
      final plan = planConflicts(
        candidates: [_cand('/s/DCIM/Camera/a.jpg', '相机', '相机/a.jpg', 100)],
        remoteIndex: {
          '相机': {'a.jpg': 100},
        },
      );
      final res = resolveHashProbes(
        probes: plan.probes,
        remoteHashes: {'相机/a.jpg': 'remote'},
        localHashes: {'相机/a.jpg': 'local'},
      );
      expect(res.single.action, PlanAction.skipKeepRemote);
      expect(res.single.message, conflictMsgSameSizeDifferent);
    });

    test('6.9 远端哈希失败（null）→ failUnknown，绝不误判相同', () {
      final plan = planConflicts(
        candidates: [_cand('/s/DCIM/Camera/a.jpg', '相机', '相机/a.jpg', 100)],
        remoteIndex: {
          '相机': {'a.jpg': 100},
        },
      );
      final res = resolveHashProbes(
        probes: plan.probes,
        remoteHashes: {'相机/a.jpg': null},
        localHashes: {'相机/a.jpg': 'abc'},
      );
      expect(res.single.action, PlanAction.failUnknown);
      expect(res.single.message, conflictMsgRemoteHashFailed);
    });

    test('6.9 远端哈希缺失（未回填）同样 failUnknown', () {
      final plan = planConflicts(
        candidates: [_cand('/s/DCIM/Camera/a.jpg', '相机', '相机/a.jpg', 100)],
        remoteIndex: {
          '相机': {'a.jpg': 100},
        },
      );
      final res = resolveHashProbes(
        probes: plan.probes,
        remoteHashes: {},
        localHashes: {},
      );
      expect(res.single.action, PlanAction.failUnknown);
    });

    test('6.11 本地哈希失败 → failLocalUnreadable（本地文件错误文案）', () {
      final plan = planConflicts(
        candidates: [_cand('/s/DCIM/Camera/a.jpg', '相机', '相机/a.jpg', 100)],
        remoteIndex: {
          '相机': {'a.jpg': 100},
        },
      );
      final res = resolveHashProbes(
        probes: plan.probes,
        remoteHashes: {'相机/a.jpg': 'abc'},
        localHashes: {'相机/a.jpg': null},
      );
      expect(res.single.action, PlanAction.failLocalUnreadable);
      expect(res.single.message, conflictMsgLocalReadFailed);
    });
  });
}
