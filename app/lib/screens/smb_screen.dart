import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../providers/smb_provider.dart';
import '../widgets/glass_container.dart';
import '../widgets/animations.dart';
import '../widgets/smb_server_dialog.dart';
import '../utils/mipix_theme.dart';
import 'photo_grid_screen.dart';

class SmbScreen extends ConsumerWidget {
  const SmbScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MiPixPalette.of(context);
    final serversAsync = ref.watch(smbServersProvider);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: MiPixTheme.overlayStyle(context),
      child: Scaffold(
        backgroundColor: palette.background,
        appBar: AppBar(
          backgroundColor: palette.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(
            'SMB 服务器',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          iconTheme: IconThemeData(color: palette.textPrimary),
          actions: [
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '添加服务器',
              onPressed: () => _showAddDialog(context, ref),
            ),
          ],
        ),
        body: serversAsync.when(
          loading: () => Center(
            child: CircularProgressIndicator(color: palette.accent),
          ),
          error: (err, _) => Center(
            child: EmptyStateWidget(
              icon: Icons.error_outline,
              title: '加载失败',
              subtitle: err.toString(),
            ),
          ),
          data: (servers) {
            if (servers.isEmpty) {
              return EmptyStateWidget(
                icon: Icons.cloud_off,
                title: '暂无 SMB 服务器',
                subtitle: '点击右上角 + 添加服务器',
                action: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.accent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => _showAddDialog(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('添加服务器'),
                ),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: servers.length,
              itemBuilder: (context, index) {
                final server = servers[index];
                return FadeSlideIn(
                  index: index,
                  child: _serverCard(context, ref, server),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _serverCard(BuildContext context, WidgetRef ref, SmbConfig server) {
    final palette = MiPixPalette.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        ref.read(selectedSmbServerProvider.notifier).state = server.id;
        ref.read(smbCurrentPathProvider.notifier).state = '';
        Navigator.push(
          context,
          PageSlideTransition(
            child: PhotoGridScreen(
              albumId: server.id,
              albumName: server.name,
              isLocal: false,
            ),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.computer,
                  color: palette.accent, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    server.name,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${server.host}:${server.port}/${server.share}',
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert,
                  color: palette.textSecondary, size: 20),
              color: palette.surface,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'test',
                    child: Text('测试连接',
                        style: TextStyle(color: palette.textPrimary))),
                PopupMenuItem(
                    value: 'browse',
                    child: Text('浏览目录',
                        style: TextStyle(color: palette.textPrimary))),
                PopupMenuItem(
                    value: 'edit',
                    child: Text('编辑',
                        style: TextStyle(color: palette.textPrimary))),
                PopupMenuItem(
                    value: 'delete',
                    child: Text('删除',
                        style: TextStyle(color: const Color(0xFFF87171)))),
              ],
              onSelected: (value) {
                if (value == 'test') _testConnection(context, ref, server);
                if (value == 'browse') {
                  ref.read(selectedSmbServerProvider.notifier).state = server.id;
                  ref.read(smbCurrentPathProvider.notifier).state = '';
                  Navigator.push(
                    context,
                    PageSlideTransition(
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

  Future<void> _testConnection(
      BuildContext context, WidgetRef ref, SmbConfig server) async {
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
    final palette = MiPixPalette.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('删除服务器', style: TextStyle(color: palette.textPrimary)),
        content: Text('确定删除 "${server.name}" 吗？',
            style: TextStyle(color: palette.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消',
                style: TextStyle(color: palette.textSecondary)),
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