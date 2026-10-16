import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:smb_connect/smb_connect.dart';
import '../models/models.dart';
import '../services/local_storage_service.dart';
import '../services/keep_alive_service.dart';
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
  final DateTime? captureTime;
  /// 任务记录 id，在批量创建任务时才生成。
  String taskId = '';

  /// P2：上传前启动、上传期间并行完成的本地摘要预取；null 表示未预取。
  Future<String?>? prefetchedHash;

  /// P2：启动摘要与上传前记录的来源稳定锚点（size + modified 毫秒）。
  ///
  /// 仅用于改名前的**稳定性检查**（发现变化即 fail-closed），不是强一致性证明。
  int? sourceSize;
  int? sourceModifiedMs;

  _PendingUpload({
    required this.localPath,
    required this.remotePath,
    required this.albumName,
    required this.size,
    required this.captureTime,
  });
}

/// 单个任务当前阶段的追踪信息，仅用于阶段级耗时日志（不落盘）。
class _PhaseTrace {
  final TransferPhase phase;
  final DateTime startedAt;

  /// 该阶段最近一次上报的已处理字节数。
  int bytes;

  _PhaseTrace(this.phase, this.startedAt, this.bytes);
}

class BackupResult {
  final int successCount;
  final int failedCount;

  /// 远端已存在「同名同大小」文件而跳过上传的照片数（视为已备份）。
  final int skippedCount;

  /// 因同名冲突而**未备份**的照片数（远端更大 / 同大同哈希不同 / 同批次落选）。
  /// 与 [skippedCount] 语义不同：这些文件并未同步，需用户自行处理。
  final int conflictSkippedCount;

  const BackupResult({
    required this.successCount,
    required this.failedCount,
    this.skippedCount = 0,
    this.conflictSkippedCount = 0,
  });

  bool get allSucceeded => failedCount == 0;
  bool get allFailed => successCount == 0 && failedCount > 0;

  /// 本次全部被判定为「远端已备份」而跳过（无上传、无失败、无冲突未备份）。
  bool get allAlreadyBackedUp =>
      successCount == 0 &&
      failedCount == 0 &&
      skippedCount > 0 &&
      conflictSkippedCount == 0;
}

/// 批量上传的失败收敛控制。
///
/// 断网/服务端持续不可用时，若让队列里每个文件各自空转 15~30 秒（库内
/// 「3 秒响应超时 × 5 次重试」+ 写入卡死上限），进度条会冻结数小时，
/// 用户看到的就是「速度归零、进度不动」。这里统计**连续**的连接类失败，
/// 达到阈值即判定为「这条链路已经不可用」，让调度方尽快停止本批剩余项，
/// 转为可恢复状态（保留「重试失败」入口），而不是继续空转。
///
/// 独立成类以便单测：不依赖 SMB、存储与 Flutter。
class UploadFailureGuard {
  /// 连续连接类失败达到该值即停止本批。
  final int maxConsecutiveConnectionFailures;

  int _consecutive = 0;
  bool _stopped = false;

  UploadFailureGuard({this.maxConsecutiveConnectionFailures = 5});

  int get consecutiveFailures => _consecutive;

  /// 是否已判定为「链路不可用」，调度方应立即停止领取新文件。
  bool get shouldStop => _stopped;

  /// 记录一次失败：连接类失败累加，其它失败（如权限/重名）清零。
  void record(Object error) {
    if (SmbService.isConnectionError(error)) {
      _consecutive += 1;
      if (_consecutive >= maxConsecutiveConnectionFailures) {
        _stopped = true;
      }
    } else {
      _consecutive = 0;
    }
  }

  /// 记录一次成功：链路恢复可用，连续计数清零。
  void recordSuccess() {
    _consecutive = 0;
  }
}

/// 上传一个文件，连接类错误时先废弃旧连接、再有限次重试同一文件。
///
/// 返回值：`null` 表示成功；否则返回导致最终失败的异常。
///
/// 失败时的处理顺序严格为「标记失效 → 关闭并重建连接 → 重试」，见
/// [reconnect]：它由调用方提供，负责关掉已死的连接并新建一条。
/// 重连本身失败时立即收敛为失败，避免在没有可用连接的情况下继续空转重试。
///
/// 抽出为顶层函数以便单测：只依赖传入的闭包，不触碰 SMB 与存储。
Future<Object?> uploadWithRetry({
  required Future<void> Function() upload,
  required UploadFailureGuard guard,
  Future<void> Function()? reconnect,
  int maxRetries = 3,
}) async {
  var left = maxRetries;
  while (true) {
    try {
      await upload();
      guard.recordSuccess();
      return null;
    } catch (e) {
      guard.record(e);
      if (!SmbService.isConnectionError(e) || left <= 0 || guard.shouldStop) {
        return e;
      }
      left -= 1;
      if (reconnect != null) {
        try {
          await reconnect();
        } catch (reconnectError) {
          // 重建连接都失败了，说明链路确实不可用：立即收敛，不再重试。
          guard.record(reconnectError);
          return e;
        }
      }
      // 大文件（分片并行）没有外部连接可重建：uploadFileParallel 每次调用
      // 都会自行新建分片连接，直接重试即为「换一批新连接」。
    }
  }
}

/// 计算「与服务器核对后仍视为已备份」的本地路径集合。
///
/// 返回 `null` 表示**本轮清单不完整**：只要有任一相册的远端清单读取失败
/// （[SmbService.listFilesWithSize] 返回 null），就不能判定这些照片「远端已删」，
/// 必须放弃本轮、保留现有记录——否则一次抖动会把「已备份」误清成 0。
///
/// 独立成顶层纯函数以便单测：不依赖 SMB、存储与 Flutter。
Set<String>? reconcileSynced({
  required Iterable<String> candidates,
  /// 本地路径 → 相册名（识别不出相册的为空串，不参与对账）。
  required Map<String, String> albumOf,
  /// 相册名 → 远端清单；`null` 表示该相册读取失败。
  required Map<String, Map<String, int>?> remoteIndex,
  /// 本地路径 → 文件大小；缺失表示文件已删除或不可读（丢弃记录）。
  required Map<String, int> localSizes,
}) {
  // 清单完整性检查放最前：任一相册读取失败即放弃，绝不产出部分结果。
  for (final album in albumOf.values) {
    if (album.isEmpty) continue;
    if (!remoteIndex.containsKey(album) || remoteIndex[album] == null) {
      return null;
    }
  }

  final stillSynced = <String>{};
  for (final p in candidates) {
    final album = albumOf[p] ?? '';
    if (album.isEmpty) continue;
    final size = localSizes[p];
    if (size == null) continue; // 本地已删/不可读：丢弃记录。
    final remoteSize = remoteIndex[album]?[p.split('/').last];
    // 远端已有「同名同大小」才算已备份；同名不同大小不能误标。
    if (size > 0 && remoteSize != null && remoteSize == size) {
      stillSynced.add(p);
    }
  }
  return stillSynced;
}

/// [clearCompleted] 之后仍保留在队列里的状态：未终结（pending/running/paused）
/// 或可重试（failed）。done 与 skipped 都属于确定终态，一并清除。
bool keepAfterClearCompleted(TransferStatus status) =>
    status != TransferStatus.done &&
    status != TransferStatus.skipped &&
    status != TransferStatus.failed;

/// 从队列中移除「与本次将重新上传的目标身份相同」的历史失败上传记录。
///
/// 身份 = `serverId + localPath`。只移除「该服务器 + 该本地路径 + 上传类型 +
/// failed」的记录：这样新批次的 pending 任务不会被上批遗留的失败项压在后面，
/// 又不会误删其他服务器、其他路径的失败项（它们各自是「重试失败」的入口）。
///
/// 「全部备份」与「重试失败」共用本函数，保证两条入口的清理规则不分叉。
/// 独立成顶层纯函数以便单测。
List<TransferTask> dropStaleFailedUploads({
  required List<TransferTask> tasks,
  required String serverId,
  required Set<String> localPaths,
}) {
  return tasks
      .where((t) =>
          !(t.transferType == TransferType.upload &&
              t.status == TransferStatus.failed &&
              t.serverId == serverId &&
              localPaths.contains(t.localPath)))
      .toList();
}

/// 队列显示顺序的排序权重：运行中(0) > 等待中(1) > 终态(2)。
int transferSortRank(TransferStatus status) {
  switch (status) {
    case TransferStatus.running:
      return 0;
    case TransferStatus.pending:
    case TransferStatus.paused:
      return 1;
    case TransferStatus.done:
    case TransferStatus.failed:
    case TransferStatus.skipped:
      return 2;
  }
}

/// 队列排序：运行中 > 等待中 > 近期终态 > 较早终态。
///
/// 保证当前批次一打开传输页就能看到正在跑的项，而不是被历史终态淹没。
/// 进行中/等待中按提交时间升序（先提交先处理）；终态按最近更新降序（近期优先）。
/// 独立成顶层纯函数以便单测。
int compareTransferTasks(TransferTask a, TransferTask b) {
  final ra = transferSortRank(a.status);
  final rb = transferSortRank(b.status);
  if (ra != rb) return ra.compareTo(rb);
  if (ra < 2) return a.createdAt.compareTo(b.createdAt);
  return b.updatedAt.compareTo(a.updatedAt);
}

// ---------------------------------------------------------------------------
// 「同名文件冲突」判定（纯逻辑，可单测：不依赖 SMB、存储与 Flutter）
// ---------------------------------------------------------------------------

/// 冲突判定给出的处置动作。
///
/// - [upload]：正常上传（远端没有该文件 / 远端更小）；
/// - [skipSynced]：同大同哈希相同 → 视为已备份，标记已同步；
/// - [skipKeepRemote]：远端更大、或同大同哈希不同 → 保留远端，不覆盖；
/// - [skipBatchCollision]：同批次内被更大的同名文件顶掉；
/// - [skipAlreadyActive]：该文件正在上传中；
/// - [failUnknown]：远端清单/哈希不可知（fail-closed，可重试）；
/// - [failLocalUnreadable]：本地文件或本地哈希不可读（可重试）。
enum PlanAction {
  upload,
  skipSynced,
  skipKeepRemote,
  skipBatchCollision,
  skipAlreadyActive,
  failUnknown,
  failLocalUnreadable,
}

/// 用户可见的固定原因文案（同一条文案三处 UI 共用，便于测试与保持一致）。
const String conflictMsgRemoteManifestFailed = '无法读取远端文件清单，未备份，请检查连接或权限后重试';
const String conflictMsgRemoteHashFailed = '校验远端文件内容失败，未备份，请检查连接后重试';
const String conflictMsgLocalReadFailed = '无法读取本地文件，未备份，请检查文件后重试';
const String conflictMsgRemoteLarger = '远端已有更大的同名文件，本次未覆盖';
const String conflictMsgSameSizeDifferent = '同名同大小但内容不同，远端文件已保留';
const String conflictMsgAlreadyActive = '该文件正在上传，本次未重复加入';

/// 同批次冲突落选文案：胜出者是「更大」还是「同大小按规则择一」要说清楚。
String conflictMsgBatchCollision({required bool winnerLarger, required String winnerName}) {
  return winnerLarger
      ? '同批另有更大的同名文件（$winnerName）已选用，本文件未备份'
      : '同批多个同名文件大小相同，已按固定规则选择 $winnerName，本文件未备份';
}

/// 参与冲突判定的一个本地候选文件。
class ConflictCandidate {
  final String localPath;
  final String albumName;

  /// 扁平结构下的远端相对路径：相册名为空时直接放在备份根目录下。
  final String remotePath;
  final int size;

  const ConflictCandidate({
    required this.localPath,
    required this.albumName,
    required this.remotePath,
    required this.size,
  });
}

/// 冲突判定对单个候选文件的结论。
class ConflictDecision {
  final ConflictCandidate candidate;
  final PlanAction action;

  /// 用户可见原因；[PlanAction.upload] / [PlanAction.skipSynced] 为 null。
  final String? message;

  /// 仅「同一远端路径 + 同大小」需要进一步哈希定案。
  final bool needsHash;

  const ConflictDecision({
    required this.candidate,
    required this.action,
    this.message,
    this.needsHash = false,
  });
}

/// 阶段一产出：待上传、待哈希定案、以及已有确定结论的三类决定。
class ConflictPlan {
  /// 明确要上传的项（[ConflictDecision.needsHash] 的项不在其中）。
  final List<ConflictDecision> uploads;

  /// 需要哈希定案的项（同一远端路径先合并为一个）。
  final List<ConflictDecision> probes;

  /// 已确定结论的项（skipSynced / skipKeepRemote / skipBatchCollision / fail*）。
  final List<ConflictDecision> settled;

  const ConflictPlan({
    required this.uploads,
    required this.probes,
    required this.settled,
  });
}

/// 阶段一：按远端路径分组 → 组内取最大本地文件（并列用 localPath 字典序打破，
/// 保证与输入顺序无关）→ 对照远端清单产出计划。
///
/// 清单不可知一律 fail-closed：相册值为 `null`（读取失败）、或根目录
/// （`albumName == ''`）没有对应索引结果时，该相册的文件全部判 [PlanAction.failUnknown]，
/// 绝不假设「远端不存在」而上传覆盖。
ConflictPlan planConflicts({
  required List<ConflictCandidate> candidates,
  /// 相册名 → 远端清单（文件名 → 大小）。`null` 表示该相册清单读取失败；
  /// 根目录用空串 key。
  required Map<String, Map<String, int>?> remoteIndex,
}) {
  final uploads = <ConflictDecision>[];
  final probes = <ConflictDecision>[];
  final settled = <ConflictDecision>[];

  // 按远端路径分组：同一批次内多个本地文件落到同一远端路径时只上传一次。
  final groups = <String, List<ConflictCandidate>>{};
  for (final c in candidates) {
    groups.putIfAbsent(c.remotePath, () => []).add(c);
  }

  // 组按远端路径字典序处理，组内先按大小降序、并列按 localPath 升序，
  // 使结果与输入顺序完全无关（反转输入得到同一结论）。
  final remotePaths = groups.keys.toList()..sort();
  for (final remotePath in remotePaths) {
    final group = groups[remotePath]!;
    group.sort((a, b) {
      if (a.size != b.size) return b.size.compareTo(a.size);
      return a.localPath.compareTo(b.localPath);
    });
    final winner = group.first;
    final remoteMap = remoteIndex[winner.albumName];
    if (remoteMap == null) {
      // 远端状态未知时，不能把组内其他候选当作已处理的批次冲突；
      // 整组都必须保留为可重试失败，待清单可用后重新择优。
      for (final candidate in group) {
        settled.add(ConflictDecision(
          candidate: candidate,
          action: PlanAction.failUnknown,
          message: conflictMsgRemoteManifestFailed,
        ));
      }
      continue;
    }

    // 文案里用本地文件名（用户选中的那个文件）；远端清单查找必须用**远端**文件名
    // （remotePath 的最后一段），因为清单是按远端目录里的名字建的。
    final winnerName = winner.localPath.split('/').last;
    for (var i = 1; i < group.length; i++) {
      final loser = group[i];
      settled.add(ConflictDecision(
        candidate: loser,
        action: PlanAction.skipBatchCollision,
        message: conflictMsgBatchCollision(
          winnerLarger: winner.size > loser.size,
          winnerName: winnerName,
        ),
      ));
    }

    final remoteSize = remoteMap[remotePath.split('/').last];
    if (remoteSize == null) {
      // 远端确实没有同名文件：正常上传。
      uploads.add(ConflictDecision(candidate: winner, action: PlanAction.upload));
    } else if (remoteSize == winner.size) {
      // 同名同大小：必须双方 SHA-256 定案，不能仅凭大小就判「已备份」。
      probes.add(ConflictDecision(
        candidate: winner,
        action: PlanAction.upload,
        needsHash: true,
      ));
    } else if (winner.size > remoteSize) {
      // 本地更大：上传替换远端旧文件。
      uploads.add(ConflictDecision(candidate: winner, action: PlanAction.upload));
    } else {
      // 远端更大：拒绝上传并提示，绝不覆盖远端更大的文件。
      settled.add(ConflictDecision(
        candidate: winner,
        action: PlanAction.skipKeepRemote,
        message: conflictMsgRemoteLarger,
      ));
    }
  }

  return ConflictPlan(uploads: uploads, probes: probes, settled: settled);
}

/// 阶段二：回填哈希结果。任一哈希为 `null`（未能确认内容）→ 绝不当作「相同」：
/// 远端哈希失败记 [PlanAction.failUnknown]，本地哈希失败记 [PlanAction.failLocalUnreadable]。
List<ConflictDecision> resolveHashProbes({
  required List<ConflictDecision> probes,
  /// 远端路径 → 远端 SHA-256；`null`/缺失表示未能确认。
  required Map<String, String?> remoteHashes,
  /// 远端路径 → 本地 SHA-256；`null`/缺失表示未能确认。
  required Map<String, String?> localHashes,
}) {
  final out = <ConflictDecision>[];
  for (final probe in probes) {
    final remotePath = probe.candidate.remotePath;
    final remoteHash = remoteHashes[remotePath];
    if (remoteHash == null) {
      out.add(ConflictDecision(
        candidate: probe.candidate,
        action: PlanAction.failUnknown,
        message: conflictMsgRemoteHashFailed,
      ));
      continue;
    }
    final localHash = localHashes[remotePath];
    if (localHash == null) {
      out.add(ConflictDecision(
        candidate: probe.candidate,
        action: PlanAction.failLocalUnreadable,
        message: conflictMsgLocalReadFailed,
      ));
      continue;
    }
    if (remoteHash == localHash) {
      out.add(ConflictDecision(
        candidate: probe.candidate,
        action: PlanAction.skipSynced,
      ));
    } else {
      out.add(ConflictDecision(
        candidate: probe.candidate,
        action: PlanAction.skipKeepRemote,
        message: conflictMsgSameSizeDifferent,
      ));
    }
  }
  return out;
}

final transfersProvider = StateNotifierProvider<TransfersNotifier, AsyncValue<List<TransferTask>>>(
  (ref) => TransfersNotifier(ref),
);

/// 已成功备份到 SMB 的本地图片路径集合（按服务器区分：serverId → 路径集合）。
final syncedPhotosProvider =
    StateNotifierProvider<SyncedPhotosNotifier, Map<String, Set<String>>>(
  (ref) => SyncedPhotosNotifier(),
);

/// 「有效当前服务器」：优先用用户显式选择的服务器；未选择（或所选已失效）时
/// 回退到第一个已配置的服务器。
///
/// 备份流程本身就有这个回退（transfers_screen 里 `servers.first`），但显示端先前
/// 没有，导致 `active_server_id` 为空时：显示端把「已备份」记录全部当作未备份
/// （待备份数量恒为全部照片），且启动对账也永不触发。统一走这里以保证三处一致。
final effectiveServerIdProvider = Provider<String?>((ref) {
  final selected = ref.watch(defaultServerProvider);
  final servers = ref.watch(smbServersProvider).valueOrNull ?? const <SmbConfig>[];
  if (selected != null && servers.any((s) => s.id == selected)) return selected;
  return servers.isEmpty ? null : servers.first.id;
});

/// 当前服务器的「已备份」路径集合，供界面判定单张照片是否已同步。
final syncedForCurrentServerProvider = Provider<Set<String>>((ref) {
  final current = ref.watch(effectiveServerIdProvider);
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

  /// 各任务当前阶段及其开始时刻，仅用于阶段级耗时日志；任务结束即移除。
  final Map<String, _PhaseTrace> _phaseTraces = {};

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
    // done 与 skipped 都是「不再变化」的终态：一次性清掉，避免冲突跳过项
    // 在队列里越积越多。failed 保留，作为「重试失败」的入口。
    final active = tasks.where((t) => keepAfterClearCompleted(t.status)).toList();
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

    // 按服务器分组待续传项；本地文件已删除的项无法重传，单独记下来随本次移除。
    final byServer = <String, List<String>>{};
    final missingIds = <String>{};
    for (final t in failed) {
      if (!await File(t.localPath).exists()) {
        missingIds.add(t.id);
        continue;
      }
      byServer.putIfAbsent(t.serverId, () => []).add(t.localPath);
    }

    // 按「目标身份」清理失败记录：与「全部备份」共用 dropStaleFailedUploads，
    // 保证两条入口的清理规则一致（只动同服务器+同路径的失败上传项）。
    var remaining = tasks;
    for (final entry in byServer.entries) {
      remaining = dropStaleFailedUploads(
        tasks: remaining,
        serverId: entry.key,
        localPaths: entry.value.toSet(),
      );
    }
    if (missingIds.isNotEmpty) {
      remaining = remaining.where((t) => !missingIds.contains(t.id)).toList();
    }
    await _storage.saveTransfers(remaining);
    state = AsyncValue.data(remaining);

    var success = 0;
    var fail = 0;
    var skipped = 0;
    var conflictSkipped = 0;
    final servers = await _storage.getSmbServers();
    for (final entry in byServer.entries) {
      if (!servers.any((s) => s.id == entry.key)) continue; // 服务器已被删除
      final result = await backupPhotos(entry.key, entry.value);
      success += result.successCount;
      fail += result.failedCount;
      skipped += result.skippedCount;
      conflictSkipped += result.conflictSkippedCount;
    }
    return BackupResult(
      successCount: success,
      failedCount: fail,
      skippedCount: skipped,
      conflictSkippedCount: conflictSkipped,
    );
  }

  Future<BackupResult> backupPhotos(String serverId, List<String> localPaths) async {
    // 传输批次期间持有保活锁（PARTIAL_WAKE_LOCK + WifiLock），抑制息屏后
    // WiFi 省电导致的 SMB 会话停顿/断开。无论正常完成、异常还是提前停止，
    // 都必须释放，避免锁泄漏。
    await KeepAliveService.acquire();
    try {
      return await _backupPhotosImpl(serverId, localPaths);
    } finally {
      await KeepAliveService.release();
    }
  }

  Future<BackupResult> _backupPhotosImpl(
    String serverId,
    List<String> localPaths,
  ) async {
    final servers = await _storage.getSmbServers();
    final server = servers.firstWhere((s) => s.id == serverId);
    final syncedPhotosNotifier = _ref.read(syncedPhotosProvider.notifier);
    var successCount = 0;
    var failedCount = 0;
    var skippedCount = 0;
    var conflictSkippedCount = 0;
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

    // P1：本次将重新上传的文件，先把它们的历史失败记录从队列移除，避免新批次的
    // pending 任务被上批遗留的失败项压在后面（老记录插在新任务之前，当前批次
    // 一打开传输页根本看不到）。只移除「同服务器 + 同本地路径」的失败上传项，
    // 其他服务器/其他路径的失败项保留，作为各自的「重试失败」入口。
    final currentTasks = state.valueOrNull ?? const <TransferTask>[];
    final cleaned = dropStaleFailedUploads(
      tasks: currentTasks,
      serverId: serverId,
      localPaths: localPaths.toSet(),
    );
    if (cleaned.length != currentTasks.length) {
      state = AsyncValue.data(cleaned);
      await _storage.saveTransfers(cleaned);
    }

    // 每个本地文件所属的相册名（扁平结构：直接用手机相册名作远端文件夹名）。
    final albumNames = <String, String>{};
    for (final path in localPaths) {
      if (path.isEmpty) continue;
      albumNames[path] = PhotoService.albumNameOf(path);
    }
    Map<String, DateTime> captureTimes = const {};
    final swCapture = Stopwatch()..start();
    try {
      captureTimes = await PhotoService.captureTimesForPaths(localPaths);
    } catch (e) {
      debugPrint('[backup][time] 无法读取手机相册拍摄时间，将回退文件修改时间：$e');
    }
    swCapture.stop();
    debugPrint('[backup][stage] phase=captureTime paths=${localPaths.length} '
        'matched=${captureTimes.length} ms=${swCapture.elapsedMilliseconds}');
    DateTime? captureTimeFor(String path) =>
        captureTimes[path.replaceAll('\\', '/').toLowerCase()];

    // 上传前按相册一次性拉取远端文件清单（文件名 → 大小），用于冲突判定：
    // 同名同大小 → 双方 SHA-256 定案；远端更大 → 拒绝覆盖；本地更大 → 替换上传；
    // 远端确实没有 → 正常新增。
    // 值为 null 表示该目录清单读取失败：fail-closed，受影响文件全部不写、提示可重试，
    // 绝不假设「远端不存在」而上传覆盖。
    // 注意：根目录（albumName == ""）也必须查询 share/rootPath 下的清单，
    // 否则根目录同名文件会被误判为「远端不存在」。
    final remoteIndex = <String, Map<String, int>?>{};
    final swManifest = Stopwatch()..start();
    var manifestFailed = 0;
    for (final album in albumNames.values.toSet()) {
      final entries = await _smbService.listFilesWithSize(server, album);
      if (entries == null) {
        manifestFailed += 1;
        debugPrint('[backup] 目录 "${album.isEmpty ? '<根目录>' : album}" 远端清单读取失败，'
            '本次不写该目录下任何文件');
      }
      remoteIndex[album] = entries;
    }
    swManifest.stop();
    debugPrint('[backup][stage] phase=manifest albums=${remoteIndex.length} '
        'failed=$manifestFailed ms=${swManifest.elapsedMilliseconds}');

    // 组装冲突候选：正在传输中的文件、本地不可读的文件先落成确定结论，
    // 其余交给纯函数 planConflicts 做「同远端路径分组 + 远端清单」判定。
    final candidates = <ConflictCandidate>[];
    final preSettled = <ConflictDecision>[];
    for (final path in localPaths) {
      if (path.isEmpty) continue;
      final albumName = albumNames[path] ?? '';
      final fileName = path.split('/').last;
      // 扁平结构：<相册名>/<文件名>；相册名为空时直接放在备份根目录下。
      final remotePath = albumName.isEmpty ? fileName : '$albumName/$fileName';

      // add 返回 false 表示该路径已在传输中或本次列表内重复：不新建任务、不计数。
      if (!activePaths.add(path)) {
        preSettled.add(ConflictDecision(
          candidate: ConflictCandidate(
            localPath: path,
            albumName: albumName,
            remotePath: remotePath,
            size: 0,
          ),
          action: PlanAction.skipAlreadyActive,
          message: conflictMsgAlreadyActive,
        ));
        continue;
      }

      int fileSize;
      try {
        fileSize = await File(path).length();
      } catch (_) {
        preSettled.add(ConflictDecision(
          candidate: ConflictCandidate(
            localPath: path,
            albumName: albumName,
            remotePath: remotePath,
            size: 0,
          ),
          action: PlanAction.failLocalUnreadable,
          message: conflictMsgLocalReadFailed,
        ));
        continue;
      }

      candidates.add(ConflictCandidate(
        localPath: path,
        albumName: albumName,
        remotePath: remotePath,
        size: fileSize,
      ));
    }

    final plan = planConflicts(candidates: candidates, remoteIndex: remoteIndex);

    // 同大同路径：串行哈希定案。先读远端（socket 只能留在主 isolate），远端读失败
    // 就不必再算本地哈希——resolveHashProbes 会判 failUnknown，绝不视为「相同」。
    final remoteHashes = <String, String?>{};
    final localHashes = <String, String?>{};
    final swProbe = Stopwatch()..start();
    var probedBytes = 0;
    for (final probe in plan.probes) {
      final remotePath = probe.candidate.remotePath;
      final remoteHash = await _smbService.hashRemoteFile(server, remotePath);
      remoteHashes[remotePath] = remoteHash;
      if (remoteHash == null) continue;
      probedBytes += probe.candidate.size;
      localHashes[remotePath] =
          await PhotoService.hashFile(probe.candidate.localPath);
    }
    swProbe.stop();
    if (plan.probes.isNotEmpty) {
      debugPrint('[backup][stage] phase=conflictHash probes=${plan.probes.length} '
          'bytes=$probedBytes ms=${swProbe.elapsedMilliseconds}');
    }
    final probeResults = resolveHashProbes(
      probes: plan.probes,
      remoteHashes: remoteHashes,
      localHashes: localHashes,
    );

    final allSettled = <ConflictDecision>[
      ...preSettled,
      ...plan.settled,
      ...probeResults,
    ];

    // 已备份（同大同哈希相同）：计入成功跳过并即时标记已同步，从未同步栏移除。
    for (final d in allSettled) {
      if (d.action != PlanAction.skipSynced) continue;
      skippedCount += 1;
      syncedPaths.add(d.candidate.localPath);
      syncedPhotosNotifier.markSynced(serverId, [d.candidate.localPath]);
    }

    // 冲突跳过 / 不可知失败：落一条终态任务记录（保留可读原因），但不计入
    // 「已备份」集合——文件并未同步；skipAlreadyActive 不新建任务、不计数。
    final settledAt = DateTime.now();
    final settledRecords = <TransferTask>[];
    var settledSeq = 0;
    for (final d in allSettled) {
      switch (d.action) {
        case PlanAction.skipKeepRemote:
        case PlanAction.skipBatchCollision:
          conflictSkippedCount += 1;
          settledRecords.add(_settledTask(
            id: '${settledAt.millisecondsSinceEpoch}_x${settledSeq++}',
            serverId: serverId,
            decision: d,
            status: TransferStatus.skipped,
            at: settledAt,
          ));
          break;
        case PlanAction.failUnknown:
        case PlanAction.failLocalUnreadable:
          failedCount += 1;
          settledRecords.add(_settledTask(
            id: '${settledAt.millisecondsSinceEpoch}_x${settledSeq++}',
            serverId: serverId,
            decision: d,
            status: TransferStatus.failed,
            at: settledAt,
          ));
          break;
        case PlanAction.skipAlreadyActive:
        case PlanAction.skipSynced:
        case PlanAction.upload:
          break;
      }
    }
    if (settledRecords.isNotEmpty) {
      final existing = state.valueOrNull ?? const <TransferTask>[];
      await _storage.saveTransfers([...existing, ...settledRecords]);
      await load();
    }

    // 待上传项（纯函数已按同远端路径去重，无需再自行去重）。
    final pending = <_PendingUpload>[
      for (final d in plan.uploads)
        _PendingUpload(
          localPath: d.candidate.localPath,
          remotePath: d.candidate.remotePath,
          albumName: d.candidate.albumName,
          size: d.candidate.size,
          captureTime: captureTimeFor(d.candidate.localPath),
        ),
    ];

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
      // 每条 worker 连接的存活标记：socket 断开时 onDisconnect 立刻置为 false。
      // worker 领取下一个文件前先把失效的连接关掉重建，避免继续往一条已经
      // 死掉的 socket 上写——那正是「息屏后每个文件都在空转」的直接原因。
      final connAlive = List<bool>.filled(poolSize, false);
      Future<SmbConnect> openConnection(int slot) async {
        final connect = await _smbService
            .createConnection(server, onDisconnect: (_) => connAlive[slot] = false)
            .timeout(_connectTimeout);
        connAlive[slot] = true;
        return connect;
      }

      final connections = <SmbConnect>[];
      for (var i = 0; i < poolSize; i++) {
        try {
          connections.add(await openConnection(i));
        } catch (_) {
          break;
        }
      }

      // 本批的失败收敛控制：连续连接类失败达到阈值即停止本批剩余项。
      final guard = UploadFailureGuard();

      /// 把本批仍处于 pending/running 的任务一次性转为失败（可恢复）态。
      ///
      /// 失败记录会立即落盘，从而保留「重试失败」入口；一次性整表更新避免了
      /// 逐条调用 _updateTaskComplete 造成的 O(n²) 序列化开销。
      Future<void> failRemaining(String message) async {
        final batchIds = {for (final item in pending) item.taskId};
        final tasks = state.valueOrNull ?? const <TransferTask>[];
        var changed = 0;
        final updated = tasks.map((t) {
          if (!batchIds.contains(t.id)) return t;
          if (t.status != TransferStatus.pending &&
              t.status != TransferStatus.running) {
            return t;
          }
          changed += 1;
          _lastProgressUiAt.remove(t.id);
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
            errorMessage: message,
            createdAt: t.createdAt,
            updatedAt: DateTime.now(),
          );
        }).toList();
        if (changed == 0) return;
        failedCount += changed;
        state = AsyncValue.data(updated);
        await _storage.saveTransfers(updated);
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
          /// 连接类错误（含卡死超时）先废弃并重建本 worker 的连接，再有限次重试
          /// 同一文件；重试次数耗尽、重连失败或链路被判定为不可用即收敛为失败。
          /// 无论成功失败都会写入终态，单文件异常不会逃逸成未处理异常。
          Future<void> runItem(
            _PendingUpload item,
            Future<void> Function() upload, {
            Future<void> Function()? reconnect,
          }) async {
            final error = await uploadWithRetry(
              upload: upload,
              guard: guard,
              reconnect: reconnect,
            );
            // 结算最后一个阶段的耗时日志（上传/校验/收尾）。
            _finishPhaseTrace(item.taskId, item.remotePath);
            if (error == null) {
              _updateTaskComplete(item.taskId, TransferStatus.done);
              successCount += 1;
              syncedPaths.add(item.localPath);
              uploadedRemotePaths.add(item.remotePath);
            } else {
              _updateTaskComplete(item.taskId, TransferStatus.failed,
                  errorMessage: error.toString());
              failedCount += 1;
            }
          }

          // 大文件串行处理：同一时刻只跑一个视频，让它独占 [largeParallelism] 条
          // 连接做分片并行。多个大文件同时跑只会互相抢带宽、把连接数顶到上限。
          for (final item in large) {
            // 链路已被判定不可用：立即停止领取新文件，剩余项转入失败待续传。
            if (guard.shouldStop) break;
            _updateTaskStatus(item.taskId, TransferStatus.running);
            // P2：上传前启动摘要预取，与上传并行；锚点用于改名前的稳定性复核。
            _startHashPrefetch(item);
            await runItem(
              item,
              () => _smbService.uploadFileParallel(
                server,
                item.remotePath,
                item.localPath,
                sourceTime: item.captureTime,
                parallelism: largeParallelism,
                prefetchedHash: item.prefetchedHash,
                sourceSize: item.sourceSize,
                sourceModifiedMs: item.sourceModifiedMs,
                // 分阶段上报：上传 → 本地摘要 → NAS 回读校验 → 改名回写，
                // 避免大视频校验的几分钟里进度条冻住被误认为卡死。
                onPhase: (phase, bytes, total) =>
                    _onUploadPhase(item, phase, bytes, total),
              ),
            );
          }

          // 小文件沿用 worker 池并发上传（每个 worker 独占一条连接）。
          var next = 0;
          Future<void> worker(int index) async {
            while (true) {
              if (guard.shouldStop) break;
              // 无 await 间隔，索引分配在事件循环中天然原子，无并发竞争。
              final local = next;
              if (local >= small.length) break;
              next = local + 1;

              final item = small[local];

              // 这条连接在上一轮已断开（onDisconnect 已回调）：先关掉再重建，
              // 不要拿一条死连接去写下一个文件。
              if (!connAlive[index]) {
                await _closeQuietly(connections[index]);
                try {
                  connections[index] = await openConnection(index);
                } catch (e) {
                  guard.record(e);
                  _updateTaskComplete(item.taskId, TransferStatus.failed,
                      errorMessage: '重连失败：$e');
                  failedCount += 1;
                  continue;
                }
              }

              _updateTaskStatus(item.taskId, TransferStatus.running);
              // P2：上传前启动摘要预取，与上传并行；锚点用于改名前的稳定性复核。
              _startHashPrefetch(item);

              await runItem(
                item,
                () => _smbService.uploadFileVia(
                  connections[index],
                  server,
                  item.remotePath,
                  item.localPath,
                  sourceTime: item.captureTime,
                  prefetchedHash: item.prefetchedHash,
                  sourceSize: item.sourceSize,
                  sourceModifiedMs: item.sourceModifiedMs,
                  onPhase: (phase, bytes, total) =>
                      _onUploadPhase(item, phase, bytes, total),
                ),
                reconnect: () async {
                  // 超时/写失败后旧连接上的请求可能仍有残留：先废弃关闭它，
                  // 保证旧请求不会和重试请求并行写同一个 .mipixtmp。
                  await _closeQuietly(connections[index]);
                  connections[index] = await openConnection(index);
                },
              );
            }
          }

          await Future.wait([
            for (var i = 0; i < connections.length; i++) worker(i),
          ]);
        } catch (e) {
          // 兜底：任何未预见的异常都不允许逃逸成未处理异常，否则整批会既没有
          // 完成也没有失败提示。本批剩余项一并转入可恢复的失败态。
          debugPrint('[backup] 批量上传异常，已停止本批：$e');
          await failRemaining('本批已中断：$e');
        } finally {
          for (final conn in connections) {
            await _closeQuietly(conn);
          }
        }

        // 连续连接类失败达到阈值而提前停止：剩余未开始项转入失败，
        // 保留「重试失败」入口，等网络恢复后由用户一键续传。
        if (guard.shouldStop) {
          await failRemaining('连接持续失败，已停止本批；网络恢复后可点「重试失败」续传');
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
      conflictSkippedCount: conflictSkippedCount,
    );
  }

  /// 把一条「已确定结论」的冲突记录落成终态任务（skipped / failed）。
  TransferTask _settledTask({
    required String id,
    required String serverId,
    required ConflictDecision decision,
    required TransferStatus status,
    required DateTime at,
  }) {
    return TransferTask(
      id: id,
      serverId: serverId,
      transferType: TransferType.upload,
      remotePath: decision.candidate.remotePath,
      localPath: decision.candidate.localPath,
      totalBytes: decision.candidate.size,
      writtenBytes: 0,
      progress: 0,
      status: status,
      errorMessage: decision.message,
      createdAt: at,
      updatedAt: at,
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

  void _updateTaskProgress(
    String taskId,
    int writtenBytes,
    double progress, {
    TransferPhase? phase,
    int? phaseBytes,
  }) {
    // 按任务节流界面刷新：进度条 6~7Hz 已足够顺滑，而每次刷新都要重建整个
    // 任务列表，过密只会挤占上传循环的时间片。
    final now = DateTime.now();
    final last = _lastProgressUiAt[taskId];
    if (last != null && now.difference(last) < _progressUiInterval) return;
    _lastProgressUiAt[taskId] = now;

    state.whenData((tasks) {
      final updated = tasks.map((t) {
        if (t.id == taskId && t.status == TransferStatus.running) {
          // 阶段切换时重置「阶段起点/已处理字节」，供界面展示阶段耗时与速度。
          final phaseChanged = phase != null && phase != t.phase;
          // 总进度单调不减：事件顺序变化（如预取把 localHash 吸收进上传、或
          // 失败重试重新进入上传阶段）都不能让进度条回退。
          final monotonic = progress < t.progress ? t.progress : progress;
          return TransferTask(
            id: t.id,
            serverId: t.serverId,
            transferType: t.transferType,
            remotePath: t.remotePath,
            localPath: t.localPath,
            totalBytes: t.totalBytes,
            writtenBytes: writtenBytes,
            progress: monotonic,
            status: t.status,
            errorMessage: t.errorMessage,
            phase: phase ?? t.phase,
            phaseBytes: phaseBytes ?? (phaseChanged ? 0 : t.phaseBytes),
            phaseStartedAt: phaseChanged ? now : (t.phaseStartedAt ?? now),
            createdAt: t.createdAt,
            updatedAt: now,
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

  /// P2：在上传前启动本地摘要预取，并记录来源稳定锚点。
  ///
  /// 摘要在独立 isolate 内与上传并行计算（[PhotoService.hashFile]），把「上传
  /// 完成后才顺序重读整份文件」的耗时吸收进上传阶段。锚点（size + modified）
  /// 供改名前的稳定性复核使用；预取结果为 null（读取失败 / 期间文件被改动）
  /// 由校验阶段 fail-closed，**不回退**二次顺序重读。
  void _startHashPrefetch(_PendingUpload item) {
    try {
      final stat = File(item.localPath).statSync();
      item.sourceSize = stat.size;
      item.sourceModifiedMs = stat.modified.millisecondsSinceEpoch;
    } catch (e) {
      debugPrint('[backup][hash] stat 失败 local="${item.localPath}" err=$e');
      item.sourceSize = item.size;
      item.sourceModifiedMs = null;
    }
    final sw = Stopwatch()..start();
    item.prefetchedHash = PhotoService.hashFile(item.localPath).then((hash) {
      debugPrint('[backup][hash] local="${item.localPath}" '
          'ms=${sw.elapsedMilliseconds} prefetched=true ok=${hash != null}');
      return hash;
    });
  }

  /// 上传阶段的进度回调：把阶段/已处理字节写入任务，并把合成的总进度换算出来。
  ///
  /// 进度分布：上传占 0~0.5，本地摘要占 0.5~0.55，NAS 回读校验占 0.55~1.0，
  /// 只有这样大文件在「写完、正在回读」的几分钟里进度条才持续前进。
  void _onUploadPhase(
    _PendingUpload item,
    TransferPhase phase,
    int bytes,
    int total,
  ) {
    _tracePhase(item.taskId, item.remotePath, phase, bytes);
    final t = total > 0 ? total.toDouble() : 0.0;
    double progress;
    switch (phase) {
      case TransferPhase.preparing:
        progress = 0.0;
        break;
      case TransferPhase.uploading:
        progress = t > 0 ? 0.5 * bytes / t : 0.0;
        break;
      case TransferPhase.localHash:
        progress = 0.5 + (t > 0 ? 0.05 * bytes / t : 0.0);
        break;
      case TransferPhase.verifying:
        progress = 0.55 + (t > 0 ? 0.45 * bytes / t : 0.0);
        break;
      case TransferPhase.finalizing:
        progress = 1.0;
        break;
    }
    _updateTaskProgress(
      item.taskId,
      // 校验/收尾阶段整份文件已写完：writtenBytes 保持等于总大小，
      // 已读回字节单独走 phaseBytes。
      phase == TransferPhase.uploading ? bytes : item.size,
      progress,
      phase: phase,
      phaseBytes: bytes,
    );
  }

  /// 记录任务阶段并输出阶段级耗时日志（阶段切换时结算上一阶段）。
  void _tracePhase(
      String taskId, String remotePath, TransferPhase phase, int bytes) {
    final trace = _phaseTraces[taskId];
    if (trace == null) {
      _phaseTraces[taskId] = _PhaseTrace(phase, DateTime.now(), bytes);
      return;
    }
    if (trace.phase != phase) {
      _logStage(taskId, trace.phase, remotePath, trace.bytes,
          DateTime.now().difference(trace.startedAt));
      _phaseTraces[taskId] = _PhaseTrace(phase, DateTime.now(), bytes);
      return;
    }
    trace.bytes = bytes;
  }

  /// 任务结束时结算最后一个阶段（上传/校验/收尾均会经过这里）。
  void _finishPhaseTrace(String taskId, String remotePath) {
    final trace = _phaseTraces.remove(taskId);
    if (trace == null) return;
    _logStage(taskId, trace.phase, remotePath, trace.bytes,
        DateTime.now().difference(trace.startedAt));
  }

  /// 阶段级耗时日志：任务 ID + 远端路径 + 字节数 + 有效吞吐，便于真机定位慢在哪一段。
  void _logStage(String taskId, TransferPhase phase, String remotePath,
      int bytes, Duration elapsed) {
    final secs = elapsed.inMicroseconds / 1e6;
    final mbps = secs > 0 ? bytes / 1048576 / secs : 0.0;
    debugPrint('[backup][stage] task=$taskId phase=${phase.name} '
        'remote="$remotePath" bytes=$bytes ms=${elapsed.inMilliseconds} '
        'mbps=${mbps.toStringAsFixed(2)}');
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

  /// 双向核对：让某台服务器的「已备份」记录与远端实际内容一致。
  ///
  /// 用于：启动时、切换服务器时。覆盖两个方向：
  ///  - 本地存在、远端「同名同大小」也在 → 标记为已备份（从待备份移除）。
  ///    这正是「重装 App / 切换到同文件夹的新 IP 后，仍能认出已备份」的关键——
  ///    即便本地记录是空的，也能从远端反推恢复。
  ///  - 已记录为已备份、但远端已不存在或大小不符 → 退回待备份。
  ///
  /// 服务器只增不减（手机删文件不影响服务器），所以远端是权威；任何网络异常
  /// 都直接放弃、不改记录，避免一次抖动把「已备份」误清空。
  Future<void> reconcileWithServer(String serverId) async {
    final servers = await _storage.getSmbServers();
    SmbConfig? server;
    for (final s in servers) {
      if (s.id == serverId) {
        server = s;
        break;
      }
    }
    if (server == null) {
      return;
    }

    // 待核对的本地路径 = 本地照片列表 ∪ 已记录的已备份（覆盖 500 张之外的旧记录）。
    // 直接从数据源取一次，避免启动竞态：重装后 recorded 为空，若 provider 还在
    // 异步加载，reconcile 会拿到空列表直接 return，从而识别不出已备份。
    final notifier = _ref.read(syncedPhotosProvider.notifier);
    final candidates = <String>{};
    List<MediaItem> photos =
        _ref.read(localPhotosProvider).valueOrNull ?? const <MediaItem>[];
    if (photos.isEmpty) {
      try {
        photos = await PhotoService.getRecentPhotos();
      } catch (_) {
        photos = const [];
      }
    }
    for (final p in photos) {
      if (p.path.isNotEmpty) candidates.add(p.path);
    }
    candidates.addAll(notifier.of(serverId));
    if (candidates.isEmpty) {
      return;
    }

    // 先确认服务器可达。listFilesWithSize 用 `null` 区分「读取失败」与「目录为空」，
    // 但这里仍保留一道探活：连接不可用时能更早退出，不必逐个相册重试到底。
    if (!await _smbService.testConnection(server)) {
      debugPrint('[reconcile] $serverId 不可达，跳过核对');
      return;
    }

    // 相册名 → 远端文件清单（文件名 → 大小）。仅查非空相册，与备份时一致。
    // `null` 表示该相册清单读取失败，本轮不可信。
    final albumOf = <String, String>{};
    for (final p in candidates) {
      albumOf[p] = PhotoService.albumNameOf(p);
    }
    final remoteIndex = <String, Map<String, int>?>{};
    for (final album in albumOf.values.toSet()) {
      if (album.isEmpty) continue;
      remoteIndex[album] = await _smbService.listFilesWithSize(server, album);
    }

    // 本地文件大小（对账需要与远端大小比对）。读取失败的项按「本地不可用」跳过。
    final localSizes = <String, int>{};
    for (final p in candidates) {
      try {
        final f = File(p);
        if (!f.existsSync()) continue;
        localSizes[p] = f.lengthSync();
      } catch (_) {
        // 读取失败按「本地不可用」处理，不参与对账。
      }
    }

    final result = reconcileSynced(
      candidates: candidates,
      albumOf: albumOf,
      remoteIndex: remoteIndex,
      localSizes: localSizes,
    );
    if (result == null) {
      // 任一相册清单读取失败：清单不完整，放弃本轮并保留现有记录。
      // 绝不能把「读不到」当成「远端已删」而清空「已备份」。
      debugPrint('[reconcile] $serverId 清单不完整（存在读取失败的相册），放弃本轮，保留现有记录');
      return;
    }
    debugPrint('[reconcile] $serverId 候选 ${candidates.length} → 已备份 '
        '${result.length}');
    notifier.replaceSynced(serverId, result);
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
