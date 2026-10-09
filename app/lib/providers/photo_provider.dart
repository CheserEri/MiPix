import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers/album_provider.dart';
import '../services/photo_service.dart';

final localPhotosProvider =
    StateNotifierProvider<LocalPhotosNotifier, AsyncValue<List<MediaItem>>>(
  (ref) => LocalPhotosNotifier(ref),
);

class LocalPhotosNotifier extends StateNotifier<AsyncValue<List<MediaItem>>> {
  LocalPhotosNotifier(this._ref) : super(const AsyncValue.loading());

  final Ref _ref;

  /// 读取本地照片。
  ///
  /// 已有数据时保持旧数据静默刷新（不回到 loading），
  /// 避免切页或手动刷新时闪出一次转圈。
  Future<void> load() async {
    if (!state.hasValue) state = const AsyncValue.loading();
    try {
      final access = await _ref.read(localAccessProvider.notifier).ensure();
      if (!access.canRead) {
        state = const AsyncValue.data([]);
        return;
      }
      final photos = await PhotoService.getRecentPhotos(count: 500);
      state = AsyncValue.data(photos);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}

final selectedPhotosProvider = StateProvider<Set<String>>((ref) => {});
final isMultiSelectProvider = StateProvider<bool>((ref) => false);

void toggleMultiSelect(WidgetRef ref) {
  final current = ref.read(isMultiSelectProvider);
  ref.read(isMultiSelectProvider.notifier).state = !current;
  if (!current == false) {
    ref.read(selectedPhotosProvider.notifier).state = {};
  }
}

void togglePhotoSelection(WidgetRef ref, String id) {
  final current = Set<String>.from(ref.read(selectedPhotosProvider));
  if (current.contains(id)) {
    current.remove(id);
  } else {
    current.add(id);
  }
  ref.read(selectedPhotosProvider.notifier).state = current;
}
