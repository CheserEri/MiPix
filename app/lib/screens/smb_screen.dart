import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../providers/smb_provider.dart';
import '../widgets/glass_container.dart';
import '../widgets/animations.dart';
import '../widgets/smb_server_dialog.dart';
import 'photo_grid_screen.dart';

class SmbScreen extends ConsumerWidget {
  const SmbScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serversAsync = ref.watch(smbServersProvider);

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
                    'SMB 服务器',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -1.2,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline, color: Colors.white),
                    onPressed: () => _showAddDialog(context, ref),
                  ),
                ],
              ),
            ),
          ),
          serversAsync.when(
            loading: () => SliverFillRemaining(
              child: Center(
                child: EmptyStateWidget(
                  icon: Icons.cloud_sync,
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
            data: (servers) {
              if (servers.isEmpty) {
                return SliverFillRemaining(
                  child: EmptyStateWidget(
                    icon: Icons.cloud_off,
                    title: '暂无 SMB 服务器',
                    subtitle: '点击右上角 + 添加服务器',
                    action: FilledButton.icon(
                      onPressed: () => _showAddDialog(context, ref),
                      icon: const Icon(Icons.add),
                      label: const Text('添加服务器'),
                    ),
                  ),
                );
              }
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final server = servers[index];
                    return FadeSlideIn(
                      index: index,
                      child: StatusCard(
                      statusColor: const Color(0xFF60A5FA),
                      onTap: () {
                        ref.read(selectedSmbServerProvider.notifier).state = server.id;
                        ref.read(smbCurrentPathProvider.notifier).state = '';
                        Navigator.push(
                          context,
                          PageFadeTransition(
                            child: PhotoGridScreen(
                              albumId: server.id,
                              albumName: server.name,
                              isLocal: false,
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: const Color(0xFF60A5FA).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.computer, color: Color(0xFF60A5FA), size: 22),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    server.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${server.host}:${server.port}/${server.share}',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.5),
                                      fontSize: 12,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert, color: Color(0xB3FFFFFF), size: 20),
                              color: const Color(0xFF0F172A),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              itemBuilder: (_) => [
                                const PopupMenuItem(value: 'test', child: Text('测试连接', style: TextStyle(color: Colors.white))),
                                const PopupMenuItem(value: 'browse', child: Text('浏览目录', style: TextStyle(color: Colors.white))),
                                const PopupMenuItem(value: 'edit', child: Text('编辑', style: TextStyle(color: Colors.white))),
                                const PopupMenuItem(value: 'delete', child: Text('删除', style: TextStyle(color: Color(0xFFF87171)))),
                              ],
                              onSelected: (value) {
                                if (value == 'test') _testConnection(context, ref, server);
                                if (value == 'browse') {
                                  ref.read(selectedSmbServerProvider.notifier).state = server.id;
                                  ref.read(smbCurrentPathProvider.notifier).state = '';
                                  Navigator.push(
                                    context,
                                    PageFadeTransition(
                                      child: PhotoGridScreen(
                                        albumId: server.id,
                                        albumName: server.name,
                                        isLocal: false,
                                      ),
                                    ),
                                  );
                                }
                                if (value == 'edit') _showEditDialog(context, ref, server);
                                if (value == 'delete') _confirmDelete(context, ref, server);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                  },
                  childCount: servers.length,
                ),
              );
            },
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
        ],
      ),
    );
  }

  void _showAddDialog(BuildContext context, WidgetRef ref) {
    showSmbServerDialog(
      context,
      onSubmit: (config) async {
        try {
          await ref.read(smbServersProvider.notifier).addServer(config);
          if (context.mounted) {
            _showMessage(context, 'SMB 服务器已添加');
          }
        } catch (_) {
          if (context.mounted) {
            _showMessage(context, '添加失败，请检查后端连接或服务器配置', isError: true);
          }
          rethrow;
        }
      },
    );
  }

  void _showEditDialog(BuildContext context, WidgetRef ref, SmbConfig server) {
    showSmbServerDialog(
      context,
      initial: server,
      onSubmit: (config) async {
        try {
          await ref.read(smbServersProvider.notifier).updateServer(server.id, config);
          if (context.mounted) {
            _showMessage(context, 'SMB 服务器已更新');
          }
        } catch (_) {
          if (context.mounted) {
            _showMessage(context, '保存失败，请检查后端连接或服务器配置', isError: true);
          }
          rethrow;
        }
      },
    );
  }

  Future<void> _testConnection(BuildContext context, WidgetRef ref, SmbConfig server) async {
    final ok = await ref.read(smbServersProvider.notifier).testConnection(server.id);
    if (context.mounted) {
      _showMessage(
        context,
        ok ? '连接成功' : '连接失败',
        isError: !ok,
      );
    }
  }

  void _showMessage(BuildContext context, String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? const Color(0xFFF87171) : const Color(0xFF34D399),
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, SmbConfig server) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('删除服务器', style: TextStyle(color: Colors.white)),
        content: Text('确定删除 "${server.name}" 吗？', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF87171)),
            onPressed: () async {
              try {
                await ref.read(smbServersProvider.notifier).deleteServer(server.id);
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                  _showMessage(context, 'SMB 服务器已删除');
                }
              } catch (_) {
                if (ctx.mounted) {
                  _showMessage(context, '删除失败，请稍后重试', isError: true);
                }
              }
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
