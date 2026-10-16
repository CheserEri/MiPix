import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../providers/album_provider.dart';
import '../providers/app_provider.dart';
import '../providers/photo_provider.dart';
import '../providers/smb_provider.dart';
import '../providers/transfer_provider.dart';
import '../services/photo_service.dart';
import '../widgets/animations.dart';
import '../widgets/smb_server_switcher.dart';
import '../utils/mipix_theme.dart';

class TransfersScreen extends ConsumerStatefulWidget {
  const TransfersScreen({super.key});

  @override
  ConsumerState<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends ConsumerState<TransfersScreen>
    with AutomaticKeepAliveClientMixin {
  /// 标签页切换时不销毁本页，避免每次回到「传输」重新构建列表。
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 照片一般已由「照片」页加载完成。这里仅在尚无数据时补载，
      // 否则每次切到「传输」都会把照片 provider 重置为 loading，
      // 导致回到「照片」页重新转圈并重复扫描 500 张照片。
      if (mounted && !ref.read(localPhotosProvider).hasValue) {
        ref.read(localPhotosProvider.notifier).load();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 要求先调用
    final transfersAsync = ref.watch(transfersProvider);
    final unsynced = ref.watch(unsyncedPhotosProvider);

    final palette = MiPixPalette.of(context);
    // 失败的上传项数量：>0 时在队列标题处提供「重试失败」续传入口。
    final failedUploadCount = (transfersAsync.valueOrNull ?? const <TransferTask>[])
        .where((t) =>
            t.status == TransferStatus.failed &&
            t.transferType == TransferType.upload)
        .length;
    return Scaffold(
      backgroundColor: palette.background,
      body: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          // 未授予位置信息权限时，备份会丢掉照片的 GPS —— 属「备份不完整」，
          // 必须显式提示（此前只打印日志，用户无从得知）。
          if (ref.watch(mediaLocationGrantedProvider) == false)
            SliverToBoxAdapter(child: _locationWarning(palette)),
          SliverToBoxAdapter(
            child: _sectionHeader(
              '未同步',
              subtitle: '共 ${unsynced.length} 张',
              switcher: true,
              action: unsynced.isEmpty
                  ? null
                  : TextButton.icon(
                      onPressed: () => _backupAll(unsynced),
                      icon: Icon(Icons.cloud_upload,
                          size: 18, color: palette.accent),
                      label: Text('全部备份',
                          style: TextStyle(color: palette.accent)),
                    ),
            ),
          ),
          if (unsynced.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text('本地照片都已同步到 SMB 服务器',
                    style: TextStyle(color: palette.textSecondary, fontSize: 13)),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(
            child: Divider(height: 1, thickness: 1, color: palette.divider),
          ),
          SliverToBoxAdapter(
            child: _sectionHeader(
              '传输队列',
              action: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (failedUploadCount > 0)
                    TextButton.icon(
                      onPressed: _retryFailed,
                      icon: Icon(Icons.refresh,
                          size: 18, color: palette.accent),
                      label: Text('重试失败 $failedUploadCount',
                          style: TextStyle(color: palette.accent)),
                    ),
                  TextButton.icon(
                    onPressed: () =>
                        ref.read(transfersProvider.notifier).clearCompleted(),
                    icon: Icon(Icons.clear_all,
                        size: 18, color: palette.textSecondary),
                    label: Text('清除已完成',
                        style: TextStyle(color: palette.textSecondary)),
                  ),
                ],
              ),
            ),
          ),
          transfersAsync.when(
            loading: () => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                    child: CircularProgressIndicator(color: palette.accent)),
              ),
            ),
            error: (err, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text('加载失败: $err',
                      style: TextStyle(color: palette.textSecondary)),
                ),
              ),
            ),
            data: (tasks) {
              if (tasks.isEmpty) {
                return SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: Text('暂无传输任务',
                        style: TextStyle(
                            color: palette.textSecondary, fontSize: 13)),
                  ),
                );
              }
              // P1：运行中 > 等待中 > 近期终态 > 较早终态，保证当前批次一打开
              // 传输页就能看到正在跑的项，而不是被历史终态淹没。
              final sorted = [...tasks]..sort(compareTransferTasks);
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    return FadeSlideIn(
                      index: index,
                      child: _transferCard(sorted[index]),
                    );
                  },
                  childCount: sorted.length,
                ),
              );
            },
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title,
      {String? subtitle, Widget? action, bool switcher = false}) {
    final palette = MiPixPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(subtitle,
                  style: TextStyle(
                      fontSize: 12, color: palette.textSecondary)),
            ),
          ],
          const Spacer(),
          if (switcher) ...[
            // 备份目标是「当前服务器」，在此提供快速切换入口。
            const SmbServerSwitcher(),
            const SizedBox(width: 4),
          ],
          if (action != null) action,
        ],
      ),
    );
  }

  Widget _transferCard(TransferTask task) {
    final palette = MiPixPalette.of(context);
    final statusColor = _statusColor(task.status);
    final statusText = _statusText(task.status);
    final total = task.totalBytes > 0 ? task.totalBytes : 1;
    // 进度取自任务自身的 progress（上传 0~0.5、本地摘要 0.5~0.55、回读校验
    // 0.55~1.0）。用 writtenBytes/total 的话，大文件「已写完、正在回读校验」
    // 的几分钟里进度条会一动不动，看起来就是传输卡死。
    final progress = task.progress.clamp(0.0, 1.0).toDouble();
    final running = task.status == TransferStatus.running;
    final detail = running ? _phaseDetail(task) : '';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task.remotePath.split('/').last,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (task.status == TransferStatus.running)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: palette.divider,
                valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                minHeight: 4,
              ),
            ),
          const SizedBox(height: 6),
          Text(
            running
                ? (detail.isEmpty
                    ? _phaseLabel(task)
                    : '${_phaseLabel(task)} · $detail')
                : (task.status == TransferStatus.pending ||
                        task.status == TransferStatus.paused
                    ? _phaseLabel(task)
                    : '${_formatBytes(task.writtenBytes)} / ${_formatBytes(total)} · '
                        '${task.transferType == TransferType.upload ? '上传' : '下载'}'),
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 11,
            ),
          ),
          // 跳过/失败原因（此前从未渲染）：冲突跳过、清单/哈希不可知等都要让用户看到。
          if (task.errorMessage != null && task.errorMessage!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              task.errorMessage!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 未授予「位置信息」权限时的提示条。
  ///
  /// 缺少该权限时系统会云隐照片 EXIF 里的 GPS，备份能跑完但内容不完整。
  /// 这里明确告知并提供直达系统设置的入口，不阻断备份。
  Widget _locationWarning(MiPixPalette palette) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          color: const Color(0x1FF59E0B),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.location_off_outlined,
                size: 18, color: Color(0xFFF59E0B)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '未授予「位置信息」权限：备份不会包含照片的 GPS 位置。'
                '请在系统设置中为 米影相册 开启该权限后重新备份。',
                style: TextStyle(color: palette.textSecondary, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: () => PhotoService.openSettings(),
              child: Text('去授权',
                  style: TextStyle(color: palette.accent, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _backupAll(List<MediaItem> photos) async {
    await _backup(photos.map((p) => p.path).toList());
  }

  /// 续传：把队列里失败的上传项重新排队备份（断网恢复后使用）。
  Future<void> _retryFailed() async {
    final result =
        await ref.read(transfersProvider.notifier).retryFailedUploads();
    if (!mounted) return;
    final String message;
    if (result.successCount == 0 &&
        result.failedCount == 0 &&
        result.conflictSkippedCount > 0) {
      message = '${result.conflictSkippedCount} 项同名冲突未备份（详见传输列表）';
    } else if (result.successCount == 0 && result.failedCount == 0) {
      message = '没有可重试的失败项（本地文件可能已删除）';
    } else if (result.failedCount == 0) {
      message = '续传完成，成功 ${result.successCount} 项';
    } else {
      message = '续传：成功 ${result.successCount}，仍失败 ${result.failedCount}';
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _backup(List<String> paths) async {
    final servers = ref.read(smbServersProvider).valueOrNull ?? [];
    if (servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在「⋮ > SMB 服务器」中添加服务器')),
      );
      return;
    }
    var serverId = ref.read(defaultServerProvider);
    if (serverId == null || !servers.any((s) => s.id == serverId)) {
      serverId = servers.first.id;
    }

    final result = await ref.read(transfersProvider.notifier).backupPhotos(
          serverId,
          paths,
        );
    if (!mounted) return;
    final String message;
    if (result.allAlreadyBackedUp) {
      message = '所选照片均已在服务器上，无需重复备份（${result.skippedCount} 项）';
    } else if (result.successCount == 0 &&
        result.failedCount == 0 &&
        result.conflictSkippedCount > 0) {
      // 仅有冲突跳过时，不能误报「已加入备份队列 0 项」。
      message = '${result.conflictSkippedCount} 项同名冲突未备份（详见传输列表）';
    } else if (result.successCount == 0 && result.failedCount == 0) {
      message = '所选照片均在上传中，已跳过';
    } else if (result.allSucceeded) {
      message = [
        '已加入备份队列 ${result.successCount} 项',
        if (result.skippedCount > 0) '${result.skippedCount} 项已备份跳过',
        if (result.conflictSkippedCount > 0)
          '${result.conflictSkippedCount} 项冲突未备份',
      ].join('，');
    } else if (result.allFailed) {
      message = '备份失败，请检查 SMB 配置';
    } else {
      message = '部分备份成功：${[
        '成功 ${result.successCount}',
        '失败 ${result.failedCount}',
        if (result.skippedCount > 0) '跳过 ${result.skippedCount}',
        if (result.conflictSkippedCount > 0)
          '冲突未备份 ${result.conflictSkippedCount}',
      ].join('，')}';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Color _statusColor(TransferStatus status) {
    switch (status) {
      case TransferStatus.running:
        return const Color(0xFFF59E0B);
      case TransferStatus.done:
        return const Color(0xFF10B981);
      case TransferStatus.failed:
        return const Color(0xFFEF4444);
      case TransferStatus.paused:
        return const Color(0xFF3B82F6);
      case TransferStatus.skipped:
        return const Color(0xFF9CA3AF);
      default:
        return const Color(0xFF9CA3AF);
    }
  }

  String _statusText(TransferStatus status) {
    switch (status) {
      case TransferStatus.pending:
        return '等待中';
      case TransferStatus.running:
        return '传输中';
      case TransferStatus.paused:
        return '已暂停';
      case TransferStatus.done:
        return '完成';
      case TransferStatus.failed:
        return '失败';
      case TransferStatus.skipped:
        return '已跳过';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  /// 运行中任务的阶段文案：上传 / 本地摘要 / NAS 回读校验 / 改名回写；
  /// 等待中与暂停的任务单独给出文案，避免显示成「0 B / … · 上传」。
  String _phaseLabel(TransferTask task) {
    switch (task.status) {
      case TransferStatus.pending:
        return '准备 / 等待上传';
      case TransferStatus.paused:
        return '已暂停';
      default:
        break;
    }
    switch (task.phase) {
      case TransferPhase.preparing:
        return '准备 / 冲突比对';
      case TransferPhase.uploading:
        return '上传';
      case TransferPhase.localHash:
        return '本地摘要计算';
      case TransferPhase.verifying:
        return 'NAS 回读校验';
      case TransferPhase.finalizing:
        return '改名与时间戳回写';
    }
  }

  /// 运行中任务的阶段详情：已处理/总量 · 当前速度 · 阶段耗时。
  ///
  /// 校验阶段（本地摘要、NAS 回读）额外展示「已用时长」，避免大文件回读的
  /// 几分钟里只有字节数在涨、看不出还要多久。
  String _phaseDetail(TransferTask task) {
    final parts = <String>[];
    final total = task.totalBytes;
    final bytes = task.phase == TransferPhase.uploading
        ? task.writtenBytes
        : task.phaseBytes;
    if (task.phase != TransferPhase.finalizing && total > 0) {
      parts.add('${_formatBytes(bytes)} / ${_formatBytes(total)}');
    }
    final started = task.phaseStartedAt;
    if (started != null) {
      final secs = DateTime.now().difference(started).inMilliseconds / 1000.0;
      if (secs > 0.3) {
        if (bytes > 0) {
          parts.add('${(bytes / 1048576 / secs).toStringAsFixed(1)} MB/s');
        }
        if (task.phase != TransferPhase.uploading) {
          parts.add('已用 ${_formatDuration(secs)}');
        }
      }
    }
    return parts.join(' · ');
  }

  String _formatDuration(double seconds) {
    final s = seconds.round();
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    final r = s % 60;
    return r == 0 ? '${m}m' : '${m}m${r}s';
  }
}