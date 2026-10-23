import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/models.dart';
import '../providers/album_provider.dart';
import '../services/photo_service.dart';

final localPhotosProvider =
    StateNotifierProvider<LocalPhotosNotifier, AsyncValue<List<MediaItem>>>(
  (ref) => LocalPhotosNotifier(ref),
);

/// 本次动态刷新相对上次列表「新增」的照片 id。
///
/// 由 [LocalPhotosNotifier.load] 在变更触发的刷新中填充，供照片网格为新插入的
/// 瓦片播放一次入场动画；页面消费后立即清空，避免重复播放。
final newlyAddedPhotoIdsProvider = StateProvider<Set<String>>((ref) => {});

class LocalPhotosNotifier extends StateNotifier<AsyncValue<List<MediaItem>>> {
  LocalPhotosNotifier(this._ref) : super(const AsyncValue.loading());

  final Ref _ref;

  /// 媒体库总数，用于判断是否还有更早的照片未加载。
  int _total = 0;
  bool _loadingMore = false;

  bool get hasMore => (state.valueOrNull?.length ?? 0) < _total;

  bool get loadingMore => _loadingMore;

  /// 读取本地照片。
  ///
  /// 首屏只取 [PhotoService.recentPhotoPageSize] 张，其余靠 [loadMore] 滚动追加；
  /// 已有数据时保持旧数据静默刷新（不回到 loading），避免切页或手动刷新时闪出
  /// 一次转圈。
  ///
  /// [fromChange] 为 true 表示这次刷新由系统媒体库变更（如截图）触发，
  /// 此时会记录相对上次列表新增的照片 id，让界面只让「新照片」淡入。
  Future<void> load({bool fromChange = false}) async {
    if (!state.hasValue) state = const AsyncValue.loading();
    try {
      final access = await _ref.read(localAccessProvider.notifier).ensure();
      if (!access.canRead) {
        _total = 0;
        state = const AsyncValue.data([]);
        return;
      }
      // 已经加载过更早的内容时，刷新保持当前窗口大小，避免滚动位置被抽走。
      final previous = state.valueOrNull?.length ?? 0;
      final count = previous > PhotoService.recentPhotoPageSize
          ? previous
          : PhotoService.recentPhotoPageSize;
      final results = await Future.wait([
        PhotoService.getMediaRange(start: 0, count: count),
        PhotoService.totalMediaCount(),
      ]);
      final photos = results[0] as List<MediaItem>;
      _total = results[1] as int;
      if (fromChange && state.hasValue) {
        final oldIds = state.value!.map((p) => p.id).toSet();
        final added = photos
            .where((p) => !oldIds.contains(p.id))
            .map((p) => p.id)
            .toSet();
        if (added.isNotEmpty) {
          _ref.read(newlyAddedPhotoIdsProvider.notifier).state = added;
        }
      }
      state = AsyncValue.data(photos);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// 追加下一页更早的照片（按创建时间倒序）。
  Future<void> loadMore() async {
    if (_loadingMore || !hasMore) return;
    final current = state.valueOrNull;
    if (current == null) return;
    _loadingMore = true;
    try {
      final next = await PhotoService.getMediaRange(
        start: current.length,
        count: PhotoService.mediaPageSize,
      );
      if (!mounted) return;
      if (next.isEmpty) {
        _total = current.length;
        return;
      }
      // 期间可能有新照片插入导致偏移，按 id 去重避免重复瓦片。
      final seen = current.map((e) => e.id).toSet();
      final appended = next.where((e) => seen.add(e.id)).toList();
      state = AsyncValue.data([...current, ...appended]);
    } catch (e) {
      debugPrint('[photos] 加载更多失败：$e');
    } finally {
      _loadingMore = false;
    }
  }
}

/// 媒体库变更序号：系统媒体库发生图片/视频变化（新增/删除/修改）并去抖后 +1。
///
/// 需要感知变化的页面（照片 / 相册 / 相册内页）监听该值并刷新自身数据，
/// 把「何时变化」与「如何刷新」解耦，避免各处重复注册底层回调。
final mediaChangeTickProvider = StateProvider<int>((ref) => 0);

/// 应用级媒体库变更监听器，随 [MainScreen] 存活。
///
/// 截图 / 拍照 / 下载图片后系统会写入 MediaStore，photo_manager 通过
/// ContentObserver 上报变化；去抖合并连续变更后递增 [mediaChangeTickProvider]，
/// 使应用内产生的新图片无需重开应用或手动刷新即可出现。
final mediaWatcherProvider = Provider<MediaWatcher>((ref) {
  final watcher = MediaWatcher(ref);
  watcher.start();
  ref.onDispose(watcher.dispose);
  return watcher;
});

/// 见 [mediaWatcherProvider]。
class MediaWatcher {
  MediaWatcher(this._ref);

  final Ref _ref;
  Timer? _debounce;
  bool _running = false;

  /// Android MediaStore 资源类型：1=图片、2=视频、3=音频。
  static const int _image = 1;
  static const int _video = 2;

  void start() {
    if (_running) return;
    _running = true;
    PhotoManager.addChangeCallback(_onChange);
    // 平台不支持监听时静默忽略，不影响其它功能。
    PhotoManager.startChangeNotify().catchError((_) {});
  }

  void _onChange(MethodCall call) {
    if (call.method != 'change') return;
    final args = call.arguments;
    if (args is Map) {
      final mediaType = args['mediaType'];
      // 音频变化与相册无关，忽略。
      if (mediaType is int && mediaType != _image && mediaType != _video) {
        return;
      }
    }
    // 去抖：截图 / 连拍会在短时间内触发多条变更，合并为一次刷新。
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _notify);
  }

  void _notify() {
    _ref.read(mediaChangeTickProvider.notifier).state++;
  }

  void dispose() {
    _debounce?.cancel();
    if (!_running) return;
    _running = false;
    PhotoManager.removeChangeCallback(_onChange);
    PhotoManager.stopChangeNotify().catchError((_) {});
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
