import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../providers/photo_provider.dart';
import '../providers/smb_provider.dart';
import '../providers/transfer_provider.dart';
import '../widgets/animations.dart';
import '../widgets/local_media_thumb.dart';
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

    // 正在排队/上传的本地文件 → 任务，用于在对应缩略图底部叠加进度条。
    final uploadsByPath = <String, TransferTask>{};
    for (final t in transfersAsync.valueOrNull ?? const <TransferTask>[]) {
      if (t.status == TransferStatus.running ||
          t.status == TransferStatus.pending) {
        uploadsByPath[t.localPath] = t;
      }
    }

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
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  crossAxisSpacing: 3,
                  mainAxisSpacing: 3,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final photo = unsynced[index];
                    return BounceTap(
                      onTap: () => _backupOne(photo),
                      child: _thumbWithProgress(
                        photo,
                        uploadsByPath[photo.path],
                        palette,
                      ),
                    );
                  },
                  childCount: unsynced.length,
                ),
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
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    return FadeSlideIn(
                      index: index,
                      child: _transferCard(tasks[index]),
                    );
                  },
                  childCount: tasks.length,
                ),
              );
            },
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
        ],
      ),
    );
  }

  /// 缩略图底部叠加上传进度条：直观显示这张照片的备份进度。
  ///
  /// [task] 为 null 表示该照片当前不在传输中，直接显示原缩略图。
  Widget _thumbWithProgress(
    MediaItem photo,
    TransferTask? task,
    MiPixPalette palette,
  ) {
    final thumb = LocalMediaThumb(item: photo);
    if (task == null) return thumb;

    // 排队阶段进度未知，显示不确定态（来回滚动）的进度条。
    final value = task.status == TransferStatus.pending ? null : task.progress;
    return Stack(
      fit: StackFit.expand,
      children: [
        thumb,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(3, 6, 3, 3),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black54],
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 3,
                backgroundColor: Colors.white24,
                valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
              ),
            ),
          ),
        ),
      ],
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
    final progress = task.writtenBytes / total;

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
            '${_formatBytes(task.writtenBytes)} / ${_formatBytes(total)} · '
            '${task.transferType == TransferType.upload ? '上传' : '下载'}',
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _backupAll(List<MediaItem> photos) async {
    await _backup(photos.map((p) => p.path).toList());
  }

  Future<void> _backupOne(MediaItem photo) async {
    await _backup([photo.path]);
  }

  /// 续传：把队列里失败的上传项重新排队备份（断网恢复后使用）。
  Future<void> _retryFailed() async {
    final result =
        await ref.read(transfersProvider.notifier).retryFailedUploads();
    if (!mounted) return;
    final String message;
    if (result.successCount == 0 && result.failedCount == 0) {
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
    } else if (result.allSucceeded) {
      message = result.skippedCount > 0
          ? '已加入备份队列 ${result.successCount} 项，${result.skippedCount} 项已备份跳过'
          : '已加入备份队列 ${result.successCount} 项';
    } else if (result.allFailed) {
      message = '备份失败，请检查 SMB 配置';
    } else {
      message = '部分备份成功：成功 ${result.successCount}，失败 ${result.failedCount}'
          '${result.skippedCount > 0 ? '，跳过 ${result.skippedCount}' : ''}';
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
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}