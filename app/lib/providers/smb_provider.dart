import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/models.dart';
import '../services/smb_service.dart';
import '../services/local_storage_service.dart';

final smbServersProvider =
    StateNotifierProvider<SmbServersNotifier, AsyncValue<List<SmbConfig>>>(
  (ref) => SmbServersNotifier(),
);

class SmbServersNotifier extends StateNotifier<AsyncValue<List<SmbConfig>>> {
  final _storage = LocalStorageService();
  final _smbService = SmbService();

  SmbServersNotifier() : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final servers = await _storage.getSmbServers();
      state = AsyncValue.data(servers);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> addServer(SmbConfig config) async {
    await _storage.addSmbServer(config);
    await load();
  }

  Future<void> deleteServer(String id) async {
    await _storage.deleteSmbServer(id);
    await load();
  }

  Future<bool> testConnection(String id) async {
    final servers = state.value ?? [];
    final server = servers.firstWhere((s) => s.id == id);
    return await _smbService.testConnection(server);
  }

  Future<bool> testDraftConnection(SmbConfig config) async {
    return await _smbService.testConnection(config);
  }

  Future<List<String>> probeShares(SmbConfig config) async {
    return await _smbService.listShares(config);
  }

  Future<List<String>> probeDirectories(SmbConfig config, String path) async {
    return await _smbService.listDirectories(config, path);
  }

  Future<void> updateServer(String id, SmbConfig config) async {
    await _storage.updateSmbServer(id, config);
    await load();
  }
}

final selectedSmbServerProvider = StateProvider<String?>((ref) => null);
final smbCurrentPathProvider = StateProvider<String>((ref) => '');

/// SMB 相册首次加载时的扫描（EXIF 拍摄时间探测）进度。
class SmbScanProgress {
  /// 是否正在扫描。
  final bool scanning;

  /// 已处理项数。
  final int done;

  /// 总项数；未知时为 0（进度条显示为不确定态）。
  final int total;

  const SmbScanProgress({this.scanning = false, this.done = 0, this.total = 0});

  double get fraction => total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
}

final smbScanProgressProvider =
    StateProvider.family<SmbScanProgress, ({String serverId, String path})>(
  (ref, params) => const SmbScanProgress(),
);

final smbAlbumsProvider = FutureProvider.family<List<Album>, String>(
  (ref, serverId) async {
    final path = ref.watch(smbCurrentPathProvider);
    final servers = ref.watch(smbServersProvider).value ?? [];
    final server = servers.firstWhere((s) => s.id == serverId);
    return await SmbService().getAlbums(server, currentPath: path);
  },
);

class SmbItemsPagedNotifier extends StateNotifier<AsyncValue<MediaItemPage>> {
  final SmbConfig server;
  final String path;
  final Ref ref;
  static const int pageSize = 50;

  SmbItemsPagedNotifier({
    required this.server,
    required this.path,
    required this.ref,
  }) : super(const AsyncValue.loading()) {
    load();
  }

  ({String serverId, String path}) get _progressKey =>
      (serverId: server.id, path: path);

  void _setProgress(SmbScanProgress progress) {
    ref.read(smbScanProgressProvider(_progressKey).notifier).state = progress;
  }

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final page = await SmbService().getMediaItems(
        server,
        path: path,
        offset: 0,
        limit: pageSize,
        onProgress: (done, total) {
          _setProgress(SmbScanProgress(
            scanning: done < total,
            done: done,
            total: total,
          ));
        },
      );
      state = AsyncValue.data(page);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    } finally {
      _setProgress(const SmbScanProgress());
    }
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore) return;

    final loadingState = state;
    if (loadingState is AsyncLoading) return;

    try {
      final page = await SmbService().getMediaItems(
        server,
        path: path,
        offset: current.items.length,
        limit: pageSize,
      );
      state = AsyncValue.data(MediaItemPage(
        items: [...current.items, ...page.items],
        total: page.total,
        hasMore: page.hasMore,
      ));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  bool get hasMore => state.valueOrNull?.hasMore ?? true;
}

final smbItemsPagedProvider = StateNotifierProvider.family<SmbItemsPagedNotifier,
    AsyncValue<MediaItemPage>, ({String serverId, String path})>(
  (ref, params) {
    final servers = ref.watch(smbServersProvider).value ?? [];
    final server = servers.firstWhere((s) => s.id == params.serverId);
    return SmbItemsPagedNotifier(
      server: server,
      path: params.path,
      ref: ref,
    );
  },
);

/// 指定服务器的 SMB 相册（根目录递归子文件夹）。
///
/// 按 serverId 拆成 family：切换服务器时界面 watch 的是另一个 provider 实例，
/// 会立即进入 loading 并加载新服务器的相册，而不是沿用上一台服务器的数据。
/// 旧实现是单个 provider，切换后重跑时 `AsyncValue.when` 默认
/// `skipLoadingOnRefresh` 会继续展示旧相册，大目录重新扫描期间看起来
/// 「切换服务器没反应」。
final allSmbAlbumsProvider = FutureProvider.family<List<Album>, String>(
  (ref, serverId) async {
    final servers = ref.watch(smbServersProvider).value ?? const <SmbConfig>[];
    if (servers.isEmpty) return const [];
    final server = servers.firstWhere(
      (s) => s.id == serverId,
      orElse: () => servers.first,
    );
    return SmbService().getAlbums(server, currentPath: '');
  },
);

/// 强制跳过缓存重新扫描各服务器的相册列表，供「刷新」按钮使用。
///
/// 只调用 `ref.invalidate(allSmbAlbumsProvider)` 是不够的：provider 重跑后
/// `getAlbums` 依然会命中同一份磁盘缓存，界面看起来「刷新没反应」。
/// 这里先以 refresh 模式真实扫描一遍并回写缓存，再由调用方失效 provider。
Future<void> rescanSmbAlbums(List<SmbConfig> servers) async {
  for (final server in servers) {
    try {
      await SmbService().getAlbums(server, currentPath: '', refresh: true);
    } catch (_) {
      // 单台服务器失败不影响其余服务器刷新。
    }
  }
}
