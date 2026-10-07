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

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final page = await SmbService().getMediaItems(
        server,
        path: path,
        offset: 0,
        limit: pageSize,
      );
      state = AsyncValue.data(page);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
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

/// 获取所有 SMB 服务器的相册（根目录下的直接子文件夹）
final allSmbAlbumsProvider = FutureProvider<List<Album>>((ref) async {
  final serversAsync = ref.watch(smbServersProvider);
  final servers = serversAsync.value ?? [];
  final List<Album> all = [];
  for (final server in servers) {
    final albums = await SmbService().getAlbums(server, currentPath: '');
    all.addAll(albums);
  }
  all.sort((a, b) => a.name.compareTo(b.name));
  return all;
});
