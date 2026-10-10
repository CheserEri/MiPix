import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../providers/smb_provider.dart';
import '../utils/mipix_theme.dart';

/// SMB 服务器切换器。
///
/// 室内/室外往往是同一份存储、只是 IP 不同，需要随时切换当前使用的服务器。
/// 切换只改变「用哪台服务器」，不影响已备份标记（同一份存储，备份状态通用），
/// 因此切换后不会出现「明明已备份却显示未备份」。
class SmbServerSwitcher extends ConsumerWidget {
  const SmbServerSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MiPixPalette.of(context);
    final servers =
        ref.watch(smbServersProvider).valueOrNull ?? const <SmbConfig>[];
    if (servers.isEmpty) return const SizedBox.shrink();

    final activeId = ref.watch(defaultServerProvider);
    final active = servers.firstWhere(
      (s) => s.id == activeId,
      orElse: () => servers.first,
    );
    final canSwitch = servers.length > 1;

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: canSwitch
          ? () => _showPicker(context, ref, servers, active.id)
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: palette.fill,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: palette.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 14, color: palette.accent),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: Text(
                active.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: palette.textPrimary),
              ),
            ),
            if (canSwitch) ...[
              const SizedBox(width: 4),
              Icon(Icons.swap_horiz, size: 14, color: palette.textSecondary),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showPicker(
    BuildContext context,
    WidgetRef ref,
    List<SmbConfig> servers,
    String activeId,
  ) async {
    final palette = MiPixPalette.of(context);
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '切换 SMB 服务器',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '室内/室外可能是同一份存储的不同 IP，切换不影响已备份标记',
              style: TextStyle(fontSize: 12, color: palette.textSecondary),
            ),
            const SizedBox(height: 8),
            ...servers.map((s) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.dns_outlined,
                    color: s.id == activeId
                        ? palette.accent
                        : palette.textSecondary,
                  ),
                  title: Text(
                    s.name,
                    style: TextStyle(
                      color: s.id == activeId
                          ? palette.accent
                          : palette.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    '${s.host}/${s.share}',
                    style:
                        TextStyle(fontSize: 11, color: palette.textSecondary),
                  ),
                  trailing: s.id == activeId
                      ? Icon(Icons.check, size: 20, color: palette.accent)
                      : null,
                  onTap: () => Navigator.pop(ctx, s.id),
                )),
          ],
        ),
      ),
    );
    if (chosen == null || chosen == activeId) return;
    await ref.read(defaultServerProvider.notifier).select(chosen);
    ref.invalidate(allSmbAlbumsProvider);
  }
}
