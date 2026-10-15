import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../services/photo_service.dart';

/// 当前媒体库访问状态。
///
/// 由 [LocalAccessNotifier.ensure] 请求/刷新，供"照片"与"相册"两个页面共用，
/// 避免同一次启动重复弹出系统授权对话框。
final localAccessProvider =
    StateNotifierProvider<LocalAccessNotifier, AsyncValue<LocalAccess>>(
  (ref) => LocalAccessNotifier(ref),
);

/// 位置信息（GPS）读取权限是否已授予（`null` = 尚未申请；非 Android 恒为 true）。
///
/// 未授予时系统会云隐照片 EXIF 里的位置信息，备份端会丢 GPS —— 这是「备份不完整」，
/// 必须在界面上明确提示，不能静默通过。由 [LocalAccessNotifier.ensure] 同步。
final mediaLocationGrantedProvider = StateProvider<bool?>((ref) => null);

class LocalAccessNotifier extends StateNotifier<AsyncValue<LocalAccess>> {
  LocalAccessNotifier(this._ref) : super(const AsyncValue.loading());

  final Ref _ref;

  /// 请求（或读取当前）媒体权限，返回最新状态。
  Future<LocalAccess> ensure() async {
    try {
      final access = await PhotoService.ensurePermission();
      state = AsyncValue.data(access);
      _ref.read(mediaLocationGrantedProvider.notifier).state =
          PhotoService.mediaLocationGranted.value;
      return access;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return LocalAccess.denied;
    }
  }
}

/// 本地相册页面的完整状态：访问状态 + 相册列表。
class LocalLibrary {
  final LocalAccess access;

  /// 已授权但读不到任何资源（MIUI 空白权限）。
  final bool blank;

  /// 按「系统相册 / 我的相册 / 更多相册」分组的相册视图。
  final LocalLibraryView view;

  const LocalLibrary({
    required this.access,
    required this.blank,
    required this.view,
  });

  bool get canRead => access.canRead;
}

final localLibraryProvider =
    StateNotifierProvider<LocalLibraryNotifier, AsyncValue<LocalLibrary>>(
  (ref) => LocalLibraryNotifier(ref),
);

class LocalLibraryNotifier extends StateNotifier<AsyncValue<LocalLibrary>> {
  LocalLibraryNotifier(this._ref) : super(const AsyncValue.loading());

  final Ref _ref;

  /// 读取本地相册库。
  ///
  /// 已有数据时保持旧数据静默刷新（不回到 loading），
  /// 避免切页或手动刷新时闪出一次转圈。
  Future<void> load() async {
    if (!state.hasValue) state = const AsyncValue.loading();
    try {
      final access = await _ref.read(localAccessProvider.notifier).ensure();
      if (!access.canRead) {
        state = AsyncValue.data(LocalLibrary(
          access: access,
          blank: false,
          view: const LocalLibraryView(system: [], mine: [], more: []),
        ));
        return;
      }

      final hasAny = await PhotoService.hasAnyAsset();
      final view = hasAny
          ? await PhotoService.getLocalLibrary()
          : const LocalLibraryView(system: [], mine: [], more: []);
      state = AsyncValue.data(LocalLibrary(
        access: access,
        blank: !hasAny,
        view: view,
      ));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}

final albumItemsProvider = FutureProvider.family<List<MediaItem>, String>(
  (ref, albumId) async {
    return await PhotoService.getMediaItems(albumId);
  },
);
