import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../providers/photo_provider.dart';
import '../providers/smb_provider.dart';
import '../providers/transfer_provider.dart';
import '../widgets/animations.dart';
import '../widgets/local_media_thumb.dart';
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
    final photos = ref.watch(localPhotosProvider).valueOrNull ?? [];
    final synced = ref.watch(syncedPhotosProvider);
    final unsynced = photos.where((p) => !synced.contains(p.path)).toList();

    final palette = MiPixPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      body: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          SliverToBoxAdapter(
            child: _sectionHeader(
              '未同步',
              subtitle: '共 ${unsynced.length} 张',
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
                      child: LocalMediaThumb(item: photo),
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
              action: TextButton.icon(
                onPressed: () => ref.read(transfersProvider.notifier).clearCompleted(),
                icon: Icon(Icons.clear_all,
                    size: 18, color: palette.textSecondary),
                label: Text('清除已完成',
                    style: TextStyle(color: palette.textSecondary)),
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

  Widget _sectionHeader(String title, {String? subtitle, Widget? action}) {
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
    final remoteDir = ref.read(defaultBackupPathProvider);

    final result = await ref.read(transfersProvider.notifier).backupPhotos(
          serverId,
          paths,
          remoteDir,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.allSucceeded
              ? '已加入备份队列 ${result.successCount} 项'
              : result.allFailed
                  ? '备份失败，请检查 SMB 配置'
                  : '部分备份成功：成功 ${result.successCount}，失败 ${result.failedCount}',
        ),
      ),
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