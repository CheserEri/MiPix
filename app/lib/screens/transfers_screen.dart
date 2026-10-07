import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../providers/transfer_provider.dart';
import '../widgets/glass_container.dart';
import '../widgets/animations.dart';

class TransfersScreen extends ConsumerWidget {
  const TransfersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfersAsync = ref.watch(transfersProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  const Text(
                    '传输队列',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -1.2,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => ref.read(transfersProvider.notifier).clearCompleted(),
                    icon: const Icon(Icons.clear_all, size: 18, color: Color(0x99FFFFFF)),
                    label: const Text('清除已完成', style: TextStyle(color: Color(0x99FFFFFF))),
                  ),
                ],
              ),
            ),
          ),
          transfersAsync.when(
            loading: () => SliverFillRemaining(
              child: Center(
                child: EmptyStateWidget(
                  icon: Icons.sync,
                  title: '正在加载...',
                ),
              ),
            ),
            error: (err, _) => SliverFillRemaining(
              child: Center(
                child: EmptyStateWidget(
                  icon: Icons.error_outline,
                  title: '加载失败',
                  subtitle: err.toString(),
                ),
              ),
            ),
            data: (tasks) {
              if (tasks.isEmpty) {
                return SliverFillRemaining(
                  child: EmptyStateWidget(
                    icon: Icons.swap_vert,
                    title: '暂无传输任务',
                    subtitle: '从照片备份到 SMB 服务器',
                  ),
                );
              }
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final task = tasks[index];
                    final statusColor = _statusColor(task.status);
                    final statusText = _statusText(task.status);
                    final progress = (task.totalBytes > 0 ? task.totalBytes : 1) > 0
                        ? task.writtenBytes / (task.totalBytes > 0 ? task.totalBytes : 1)
                        : 0.0;

                    return FadeSlideIn(
                      index: index,
                      child: StatusCard(
                        statusColor: statusColor,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    task.remotePath.split('/').last,
                                    style: const TextStyle(
                                      color: Colors.white,
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
                                    color: statusColor.withValues(alpha: 0.15),
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
                                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                                  valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                                  minHeight: 4,
                                ),
                              ),
                            const SizedBox(height: 6),
                            Text(
                              '${_formatBytes(task.writtenBytes)} / ${_formatBytes((task.totalBytes > 0 ? task.totalBytes : 1))} · ${task.transferType == TransferType.upload ? '上传' : '下载'}',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.4),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ),
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

  Color _statusColor(TransferStatus status) {
    switch (status) {
      case TransferStatus.running:
        return const Color(0xFFFBBF24);
      case TransferStatus.done:
        return const Color(0xFF34D399);
      case TransferStatus.failed:
        return const Color(0xFFF87171);
      case TransferStatus.paused:
        return const Color(0xFF60A5FA);
      default:
        return const Color(0xFF94A3B8);
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
