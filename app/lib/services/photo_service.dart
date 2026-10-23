import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/models.dart';

/// 收集流式哈希的最终摘要（`startChunkedConversion` 需要 `Sink<Digest>`）。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 本地媒体库的访问状态。
enum LocalAccess {
  /// 完全授权。
  authorized,

  /// 部分授权（Android 14+ 用户仅选择了部分照片）。
  limited,

  /// 未授权 / 被用户拒绝。
  denied,

  /// 被系统限制（如家长控制），用户无法自行修改。
  restricted,
}

/// 扩展：是否可读取资源。
extension LocalAccessX on LocalAccess {
  bool get canRead =>
      this == LocalAccess.authorized || this == LocalAccess.limited;
}

/// 系统相册中的虚拟相册 id（MediaStore 里并不存在对应的 bucket）。
///
/// 与 MIUI 相册的「系统相册」区保持一致：全部照片 / 视频 / 截屏录屏。
class SystemAlbum {
  static const String all = 'sys:all';
  static const String videos = 'sys:videos';
  static const String screenshots = 'sys:screens';

  const SystemAlbum._();
}

/// 本地媒体库分组视图，对齐 MIUI 相册的三段结构。
class LocalLibraryView {
  /// 系统相册：全部照片 / 相机 / 视频 / 截屏录屏。
  final List<Album> system;

  /// 我的相册：位于 `Pictures/Gallery/` 下的相册。
  final List<Album> mine;

  /// 更多相册：其余目录（DCIM/Download/Pictures 等）。
  final List<Album> more;

  const LocalLibraryView({
    required this.system,
    required this.mine,
    required this.more,
  });

  bool get isEmpty => system.isEmpty && mine.isEmpty && more.isEmpty;
}

/// 本地相册 / 照片的读取与写入。
///
/// 设计目标：与 MIUI 系统相册保持一致
///  * 只返回真实的相册目录，不合成"全部 / 最近"相册；
///  * 读取类型为 [RequestType.common]（图片 + 视频），数量与系统相册一致；
///  * 相册按"最近一张照片的时间"倒序排列；
///  * 相册内资源按创建时间倒序（最新在前）。
class PhotoService {
  PhotoService._();

  /// 统一排序：创建时间倒序。
  ///
  /// 注意：[FilterOptionGroup.createTimeCond] 默认是 `DateTimeCond.def()`，其
  /// `max` 为「构造那一刻」的 `DateTime.now()`。而 `_descOrder` 是 `static final`
  /// 只会构造一次，原生查询便会带上 `DATE_ADDED <= 启动时刻` 的条件，导致应用
  /// 启动之后新拍 / 新截图的照片被永久过滤掉（表现为动态刷新失效）。这里必须
  /// 显式忽略创建时间约束。
  static final FilterOptionGroup _descOrder = FilterOptionGroup(
    orders: const [OrderOption(type: OrderOptionType.createDate, asc: false)],
    createTimeCond: DateTimeCond.def().copyWith(ignore: true),
  );

  /// 位置信息权限的通道（原生侧实现见 MainActivity.ensureMediaLocation）。
  static const MethodChannel _permissionChannel = MethodChannel('mipix/permission');

  /// `ACCESS_MEDIA_LOCATION` 的授予状态（`null` = 尚未申请过；非 Android 恒为 true）。
  ///
  /// 未授予时 MediaProvider 会云隐照片 EXIF 里的 GPS（长度不变），备份端会静默丢失
  /// 位置信息——这属于「备份不完整」，必须在界面上给出可见提示；只打印日志正是
  /// 本问题最初被漏掉的原因。
  static final ValueNotifier<bool?> mediaLocationGranted =
      ValueNotifier<bool?>(null);

  /// 申请 `ACCESS_MEDIA_LOCATION`（Android 10+）。
  ///
  /// 缺少该权限时，MediaProvider 的 FUSE 层会在应用读取照片时把 EXIF 中的位置
  /// 信息数值区间替换为 0——文件长度与其余字节完全不变。于是应用会「忠实地」
  /// 把被云隐过的字节上传到 NAS，导致备份端丢 GPS，而「同名同大小」去重与
  /// 本地哈希校验都察觉不到。必须在读文件之前就持有该权限。
  ///
  /// 拿不到权限不应让备份整体失败，但结果会记入 [mediaLocationGranted]，
  /// 由 UI 明确告知用户「本次备份可能不含位置信息」。
  static Future<bool> ensureMediaLocationAccess() async {
    if (!Platform.isAndroid) {
      mediaLocationGranted.value = true;
      return true;
    }
    try {
      final granted =
          await _permissionChannel.invokeMethod<bool>('ensureMediaLocation') ??
              false;
      mediaLocationGranted.value = granted;
      return granted;
    } catch (e) {
      debugPrint('[permission] ACCESS_MEDIA_LOCATION 申请失败：$e');
      mediaLocationGranted.value = false;
      return false;
    }
  }

  /// 请求（必要时弹出系统授权对话框）并返回媒体访问状态。
  static Future<LocalAccess> ensurePermission() async {
    final PermissionState state = await PhotoManager.requestPermissionExtend();
    switch (state) {
      case PermissionState.authorized:
        // 读文件前补申请位置信息权限，否则读到的 EXIF 会被系统云隐掉 GPS。
        await ensureMediaLocationAccess();
        return LocalAccess.authorized;
      case PermissionState.limited:
        await ensureMediaLocationAccess();
        return LocalAccess.limited;
      case PermissionState.restricted:
        return LocalAccess.restricted;
      case PermissionState.notDetermined:
      case PermissionState.denied:
        return LocalAccess.denied;
    }
  }

  /// 是否能读到任意一张图片。
  ///
  /// MIUI 上存在"显示已授权、实际读不到任何资源"的情况（用户授予了空白权限），
  /// 借助该检查可以识别并引导用户到系统设置中重新授权。
  static Future<bool> hasAnyAsset() async {
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        hasAll: true,
        onlyAll: true,
      );
      if (paths.isEmpty) return false;
      return await paths.first.assetCountAsync > 0;
    } catch (_) {
      return false;
    }
  }

  /// 跳转到系统的应用权限设置页。
  static Future<void> openSettings() => PhotoManager.openSetting();

  /// 读取本地媒体库，并按 MIUI 相册的结构分为「系统 / 我的 / 更多」三组。
  static Future<LocalLibraryView> getLocalLibrary() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: false,
      filterOption: _descOrder,
    );

    Album? cameraAlbum;
    final screenshotAlbums = <Album>[];
    final mineEntries = <({Album album, DateTime? at})>[];
    final moreEntries = <({Album album, DateTime? at})>[];

    for (final path in paths) {
      final name = path.name.trim();
      // 跳过没有名字的桶（例如根目录 / 或 bucket_display_name 为空的项）。
      if (name.isEmpty) continue;

      final count = await path.assetCountAsync;
      if (count <= 0) continue;

      String? coverPath;
      DateTime? latestAt;
      String? relativePath;
      final assets = await path.getAssetListRange(start: 0, end: 1);
      if (assets.isNotEmpty) {
        final asset = assets.first;
        latestAt = asset.modifiedDateTime;
        relativePath = asset.relativePath;
        coverPath = await _coverThumbPath(asset);
      }

      final rawName = name.toLowerCase();
      final album = Album(
        id: path.id,
        name: _displayName(name),
        source: MediaSource.local(),
        coverPath: coverPath,
        count: count,
      );

      if (rawName == 'camera') {
        // 相机归入「系统相册」并本地化名称。
        cameraAlbum = album;
      } else if (rawName == 'screenshots' ||
          rawName == 'screenrecorder' ||
          _isScreenshotPath(relativePath)) {
        // 截屏与录屏在 MIUI 中合并为一个"截屏录屏"相册。
        screenshotAlbums.add(album);
      } else if (_isMinePath(relativePath)) {
        mineEntries.add((album: album, at: latestAt));
      } else {
        moreEntries.add((album: album, at: latestAt));
      }
    }

    final system = await _buildSystemAlbums(cameraAlbum, screenshotAlbums);
    return LocalLibraryView(
      system: system,
      mine: _sortedAlbums(mineEntries),
      more: _sortedAlbums(moreEntries),
    );
  }

  /// 本地浏览每页数量（相册内页与「照片」页加载更多均使用）。
  static const int mediaPageSize = 200;

  /// 「照片」页首屏数量，之后按 [mediaPageSize] 滚动追加。
  static const int recentPhotoPageSize = 500;

  /// 读取某个相册下的一页资源，按时间倒序。
  ///
  /// 虚拟相册与普通相册都按 `page × pageSize` 的**绝对区间**取数，返回的永远
  /// 是单页数据。此前虚拟相册用「前缀」语义（取 0..(page+1)*size），分页追加
  /// 时会把前面的数据重复返回，且截屏录屏被写死为最多 2000 条。
  static Future<List<MediaItem>> getMediaItems(
    String albumId, {
    int page = 0,
    int pageSize = mediaPageSize,
  }) async {
    if (pageSize <= 0 || page < 0) return [];
    final start = page * pageSize;

    switch (albumId) {
      case SystemAlbum.all:
        return _toMediaItems(
          await _assetsOfAll(RequestType.common, start, pageSize),
        );
      case SystemAlbum.videos:
        return _toMediaItems(await _videoAssetsRange(start, pageSize));
      case SystemAlbum.screenshots:
        // 截屏录屏合并自 Screenshots + ScreenRecorder 两个桶。
        return _toMediaItems(await _screenshotAssetsRange(start, pageSize));
    }

    final path = await AssetPathEntity.fromId(
      albumId,
      filterOption: _descOrder,
    );
    final assets = await path.getAssetListPaged(page: page, size: pageSize);
    return _toMediaItems(assets);
  }

  /// 相册（含虚拟相册）的资源总数，用于判断分页是否还有更多。
  static Future<int> mediaCountOf(String albumId) async {
    switch (albumId) {
      case SystemAlbum.all:
        return totalMediaCount();
      case SystemAlbum.videos:
        return _videoCount();
      case SystemAlbum.screenshots:
        return _screenshotCount();
    }
    try {
      final path = await AssetPathEntity.fromId(
        albumId,
        filterOption: _descOrder,
      );
      return await path.assetCountAsync;
    } catch (_) {
      return 0;
    }
  }

  /// 全库媒体（图片 + 视频）总数。
  static Future<int> totalMediaCount() async {
    try {
      final path = await _allPath(RequestType.common);
      return path == null ? 0 : await path.assetCountAsync;
    } catch (_) {
      return 0;
    }
  }

  /// 读取全库媒体的一段（按创建时间倒序），供「照片」页滚动分页。
  static Future<List<MediaItem>> getMediaRange({
    required int start,
    int count = mediaPageSize,
  }) async {
    if (count <= 0 || start < 0) return [];
    return _toMediaItems(
      await _assetsOfAll(RequestType.common, start, count),
    );
  }

  /// 读取"所有照片"（含视频），按时间倒序。
  static Future<List<MediaItem>> getRecentPhotos({int count = 500}) async {
    if (count <= 0) return [];
    return _allMedia(RequestType.common, count: count);
  }

  /// 全量枚举本地媒体（图片 + 视频）的绝对路径，供「全部备份」使用。
  ///
  /// 只解析路径，不读取尺寸与文件大小，避免上万张时产生大量跨端调用和 stat；
  /// 分批读取，调用方无需一次性持有整库的 [MediaItem]。
  static Future<List<String>> getAllMediaPaths({
    int batchSize = 200,
    void Function(int loaded, int total)? onProgress,
  }) async {
    final path = await _allPath(RequestType.common);
    if (path == null) return [];
    final total = await path.assetCountAsync;
    final result = <String>[];
    final seen = <String>{};
    for (var start = 0; start < total; start += batchSize) {
      final assets = await path.getAssetListRange(
        start: start,
        end: (start + batchSize).clamp(0, total),
      );
      if (assets.isEmpty) break;
      for (final asset in assets) {
        final direct = _directPath(asset);
        final p = direct ?? await _resolvePath(asset);
        if (p != null && p.isNotEmpty && seen.add(p)) result.add(p);
      }
      onProgress?.call(start + assets.length, total);
    }
    return result;
  }

  /// 返回指定本地文件在系统媒体库中的拍摄时间（MediaStore DATE_TAKEN）。
  /// 未匹配到的文件不返回，由调用方回退到文件修改时间。
  static Future<Map<String, DateTime>> captureTimesForPaths(
      Iterable<String> filePaths) async {
    final wanted = filePaths.map(_normalizeMediaPath).toSet();
    if (wanted.isEmpty) return {};
    final result = <String, DateTime>{};
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: true,
      onlyAll: true,
      filterOption: _descOrder,
    );
    if (paths.isEmpty) return result;
    final album = paths.first;
    final count = await album.assetCountAsync;
    for (var start = 0; start < count && result.length < wanted.length; start += 200) {
      final assets = await album.getAssetListRange(
        start: start,
        end: (start + 200).clamp(0, count).toInt(),
      );
      for (final asset in assets) {
        final direct = _directPath(asset);
        if (direct == null) continue;
        final normalized = _normalizeMediaPath(direct);
        if (wanted.contains(normalized)) {
          result[normalized] = asset.createDateTime;
        }
      }
    }
    return result;
  }

  static String _normalizeMediaPath(String path) =>
      path.replaceAll('\\', '/').toLowerCase();

  /// 把磁盘上的文件写入系统相册（写入 MediaStore），使 MIUI 相册也能看到。
  ///
  /// [relativePath] 形如 `Pictures/MiPix`；不传则使用系统默认目录。
  static Future<MediaItem?> saveFileToGallery({
    required String filePath,
    String? relativePath,
  }) async {
    final asset = await PhotoManager.editor.saveImageWithPath(
      filePath,
      relativePath: relativePath,
    );
    return _toMediaItem(asset);
  }

  /// 把内存中的图片写入系统相册（写入 MediaStore）。
  ///
  /// [filename] 需要带扩展名以便推断 MIME 类型。
  static Future<MediaItem?> saveBytesToGallery(
    Uint8List data, {
    required String filename,
    String? relativePath,
  }) async {
    final asset = await PhotoManager.editor.saveImage(
      data,
      filename: filename,
      relativePath: relativePath,
    );
    return _toMediaItem(asset);
  }

  /// 组装「系统相册」区：全部照片 / 相机 / 视频 / 截屏录屏。
  static Future<List<Album>> _buildSystemAlbums(
    Album? cameraAlbum,
    List<Album> screenshotAlbums,
  ) async {
    final albums = <Album>[];

    final allPath = await _allPath(RequestType.common);
    if (allPath != null) {
      final count = await allPath.assetCountAsync;
      if (count > 0) {
        albums.add(Album(
          id: SystemAlbum.all,
          name: '全部照片',
          source: MediaSource.local(),
          coverPath: await _coverPath(allPath),
          count: count,
        ));
      }
    }

    if (cameraAlbum != null) albums.add(cameraAlbum);

    // 视频相册：与 MIUI 保持一致地保留该入口。
    // 注意：部分 MIUI 版本并不提供「全部视频」虚拟相册（或计数恒为 0），
    // 因此计数改为「虚拟相册优先、回退遍历所有视频目录」。
    final videoCount = await _videoCount();
    albums.add(Album(
      id: SystemAlbum.videos,
      name: '视频',
      source: MediaSource.local(),
      coverPath: await _videoCoverPath(),
      count: videoCount,
    ));

    final screensCount =
        screenshotAlbums.fold<int>(0, (sum, a) => sum + a.count);
    if (screensCount > 0) {
      albums.add(Album(
        id: SystemAlbum.screenshots,
        name: '截屏录屏',
        source: MediaSource.local(),
        coverPath: screenshotAlbums.first.coverPath,
        count: screensCount,
      ));
    }

    return albums;
  }

  static Future<AssetPathEntity?> _allPath(RequestType type) async {
    final paths = await PhotoManager.getAssetPathList(
      type: type,
      hasAll: true,
      onlyAll: true,
      filterOption: _descOrder,
    );
    return paths.isEmpty ? null : paths.first;
  }

  /// 视频总数：先试「全部视频」虚拟相册，读不到时遍历所有视频目录求和。
  static Future<int> _videoCount() async {
    final allPath = await _allPath(RequestType.video);
    if (allPath != null) {
      final count = await allPath.assetCountAsync;
      if (count > 0) return count;
    }
    final buckets = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      hasAll: false,
      filterOption: _descOrder,
    );
    var total = 0;
    for (final bucket in buckets) {
      total += await bucket.assetCountAsync;
    }
    return total;
  }

  /// 取视频资源（时间倒序）：同样优先虚拟相册，为空则合并所有视频目录。
  static Future<List<AssetEntity>> _videoAssets(int count) async {
    if (count <= 0) return [];

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      hasAll: true,
      onlyAll: true,
      filterOption: _descOrder,
    );
    if (paths.isNotEmpty) {
      final assets = await paths.first.getAssetListRange(start: 0, end: count);
      if (assets.isNotEmpty) return assets;
    }

    final buckets = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      hasAll: false,
      filterOption: _descOrder,
    );
    final merged = <AssetEntity>[];
    for (final bucket in buckets) {
      merged.addAll(await bucket.getAssetListRange(start: 0, end: count));
    }
    merged.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    return merged.length > count ? merged.sublist(0, count) : merged;
  }

  /// 全库媒体的绝对区间取数（`[start, start + count)`）。
  static Future<List<AssetEntity>> _assetsOfAll(
    RequestType type,
    int start,
    int count,
  ) async {
    if (count <= 0 || start < 0) return [];
    final path = await _allPath(type);
    if (path == null) return [];
    return path.getAssetListRange(start: start, end: start + count);
  }

  /// 视频的绝对区间取数：优先「全部视频」虚拟相册，否则合并各视频目录。
  static Future<List<AssetEntity>> _videoAssetsRange(int start, int count) async {
    if (count <= 0 || start < 0) return [];
    final allPath = await _allPath(RequestType.video);
    if (allPath != null && await allPath.assetCountAsync > 0) {
      return allPath.getAssetListRange(start: start, end: start + count);
    }
    final merged = await _videoAssets(start + count);
    if (start >= merged.length) return [];
    return merged.sublist(start, (start + count).clamp(0, merged.length));
  }

  /// 截屏 / 录屏对应的系统桶（MIUI 上为 Screenshots、ScreenRecorder）。
  static Future<List<AssetPathEntity>> _screenshotBuckets() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: false,
      filterOption: _descOrder,
    );
    return paths.where((p) {
      final name = p.name.trim().toLowerCase();
      return name == 'screenshots' || name == 'screenrecorder';
    }).toList();
  }

  static Future<int> _screenshotCount() async {
    var total = 0;
    for (final bucket in await _screenshotBuckets()) {
      try {
        total += await bucket.assetCountAsync;
      } catch (_) {
        // 单个桶读取失败不影响总数统计。
      }
    }
    return total;
  }

  /// 截屏录屏的绝对区间取数：两个桶各取前缀，合并排序后切片。
  static Future<List<AssetEntity>> _screenshotAssetsRange(
    int start,
    int count,
  ) async {
    if (count <= 0) return [];
    final buckets = await _screenshotBuckets();
    if (buckets.isEmpty) return [];
    final merged = <AssetEntity>[];
    for (final bucket in buckets) {
      merged.addAll(
        await bucket.getAssetListRange(start: 0, end: start + count),
      );
    }
    merged.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    if (start >= merged.length) return [];
    return merged.sublist(start, (start + count).clamp(0, merged.length));
  }

  /// 相册封面路径：图片直接返回其文件路径；**视频必须先抽帧落盘成 JPEG**。
  ///
  /// 视频文件本身不能交给图片解码器：`Image.file` 会先把整个文件读进内存再解码，
  /// 几百 MB 的视频会直接 OOM 让进程 abort（实测 673 MB 视频 → 703,742,088 字节
  /// 分配失败）。因此视频封面一律先抽帧、缓存成一张小 JPEG 再返回。
  static Future<String?> _coverThumbPath(AssetEntity asset) async {
    if (asset.type == AssetType.video) return _videoFramePath(asset);
    final file = await _resolveFile(asset);
    return file?.path;
  }

  /// 视频相册封面：取最新一个视频的首帧缩略图，缓存到应用临时目录。
  ///
  /// 视频文件本身无法直接被 Image 渲染，因此需要先用 photo_manager
  /// 抽帧并落盘成一张图片，再作为相册封面路径返回。
  static Future<String?> _videoCoverPath() async {
    final assets = await _videoAssets(1);
    if (assets.isEmpty) return null;
    return _videoFramePath(assets.first);
  }

  /// 抽取视频首帧并缓存为 JPEG，返回其路径；失败返回 null。
  static Future<String?> _videoFramePath(AssetEntity asset,
      {int size = 512}) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/mipix_video_cover_${asset.id}_$size.jpg');
      if (await file.exists() && await file.length() > 0) return file.path;

      final data = await asset.thumbnailDataWithSize(
        ThumbnailSize(size, size),
        quality: 85,
      );
      if (data == null || data.isEmpty) return null;
      await file.writeAsBytes(data, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _coverPath(AssetPathEntity path) async {
    final assets = await path.getAssetListRange(start: 0, end: 1);
    if (assets.isEmpty) return null;
    if (assets.first.type == AssetType.video) return null;
    final file = await _resolveFile(assets.first);
    return file?.path;
  }

  static Future<List<MediaItem>> _allMedia(
    RequestType type, {
    required int count,
    bool Function(String?)? filter,
  }) async {
    final paths = await PhotoManager.getAssetPathList(
      type: type,
      hasAll: true,
      onlyAll: true,
      filterOption: _descOrder,
    );
    if (paths.isEmpty) return [];

    final album = paths.first;
    final assets = await album.getAssetListRange(start: 0, end: count);
    if (filter == null) return _toMediaItems(assets);

    final items = <MediaItem>[];
    for (final asset in assets) {
      if (!filter(asset.relativePath)) continue;
      final item = await _toMediaItem(asset);
      if (item != null) items.add(item);
    }
    return items;
  }

  static List<Album> _sortedAlbums(
      List<({Album album, DateTime? at})> entries) {
    // 与系统相册一致：最近有更新的相册排在前面。
    entries.sort((a, b) {
      final x = a.at;
      final y = b.at;
      if (x == null && y == null) return b.album.count.compareTo(a.album.count);
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });
    return entries.map((e) => e.album).toList();
  }

  /// 相册名本地化，与 MIUI 相册显示一致。
  static String _displayName(String raw) {
    switch (raw.toLowerCase()) {
      case 'camera':
        return '相机';
      case 'screenshots':
      case 'screenrecorder':
        return '截屏录屏';
      case 'weixin':
      case 'wechat':
        return '微信';
      default:
        return raw;
    }
  }

  /// 我的相册：位于 Pictures/Gallery/ 下的目录。
  static bool _isMinePath(String? relativePath) {
    if (relativePath == null) return false;
    final r = relativePath.toLowerCase();
    return r.startsWith('pictures/gallery/') || r == 'pictures/gallery';
  }

  /// 截屏 / 录屏目录。
  static bool _isScreenshotPath(String? relativePath) {
    if (relativePath == null) return false;
    final r = relativePath.toLowerCase();
    return r.startsWith('dcim/screenshots') ||
        r.startsWith('dcim/screenrecorder');
  }

  static Future<List<MediaItem>> _toMediaItems(List<AssetEntity> assets) async {
    final items = <MediaItem>[];
    for (final asset in assets) {
      final item = await _toMediaItem(asset);
      if (item != null) items.add(item);
    }
    return items;
  }

  static Future<MediaItem?> _toMediaItem(AssetEntity asset) async {
    final path = await _resolvePath(asset);
    if (path == null) return null;

    int bytes = 0;
    try {
      bytes = await File(path).length();
    } catch (_) {
      bytes = 0;
    }

    final size = asset.size;
    return MediaItem(
      id: asset.id,
      name: (asset.title != null && asset.title!.isNotEmpty)
          ? asset.title!
          : path.split(Platform.pathSeparator).last,
      path: path,
      source: MediaSource.local(),
      mimeType: asset.mimeType ?? 'image/jpeg',
      size: bytes,
      width: size.width.toInt(),
      height: size.height.toInt(),
      modifiedAt: asset.modifiedDateTime,
    );
  }

  /// Android 主存储根目录，用于把相册相对路径拼成绝对路径。
  static const String _primaryStorageRoot = '/storage/emulated/0';

  /// 流式计算本地文件的 SHA-256（在独立 isolate 内执行，避免大文件哈希阻塞 UI）。
  ///
  /// 返回 `null` 表示**未能确认内容**：文件读取失败，或哈希过程中文件被改动
  /// 导致累计字节数与开始时记录的大小不一致。调用方不得把它当作「相同」。
  /// 只消费一次 [File.openRead] 流并流式喂给摘要，不缓存整文件。
  ///
  /// 注：远端读必须留在主 isolate（socket 不可跨 isolate），只有本地哈希下放。
  static Future<String?> hashFile(String path) {
    return Isolate.run<String?>(() async {
      try {
        final file = File(path);
        final expected = await file.length();
        final digestSink = _DigestSink();
        final hasher = sha256.startChunkedConversion(digestSink);
        var read = 0;
        await for (final chunk in file.openRead()) {
          hasher.add(chunk);
          read += chunk.length;
        }
        hasher.close();
        final digest = digestSink.value;
        if (digest == null || read != expected) return null;
        return digest.toString();
      } catch (_) {
        return null;
      }
    });
  }

  /// 由本地文件绝对路径推导其所属相册的显示名称（如 `相机`、`生活`、`微信`）。
  ///
  /// 备份到 SMB 时用相册名在远端直接创建同名文件夹（扁平结构），
  /// 与手机相册列表里看到的名称一致；不再复刻 `DCIM/Camera`、
  /// `Pictures/Gallery/owner/生活` 这类深层绝对路径。
  ///
  /// 识别不出目录时返回空串（调用方回退到备份根目录）。
  static String albumNameOf(String absolutePath) {
    final dir = albumDirOf(absolutePath);
    if (dir.isEmpty) return '';
    // 相册名取路径最后一段，再套用与相册列表一致的本地化规则（Camera→相机 等）。
    return _displayName(dir.split('/').last);
  }

  /// 由本地文件绝对路径推导其所属相册目录（相对存储根，如 `DCIM/Camera`）。
  ///
  /// 识别不出存储根时返回空串（调用方回退到备份根目录）。
  static String albumDirOf(String absolutePath) {
    final normalized = absolutePath.replaceAll('\\', '/');
    String? relative;
    if (normalized.startsWith('$_primaryStorageRoot/')) {
      relative = normalized.substring(_primaryStorageRoot.length + 1);
    } else {
      // 外置存储（SD 卡）形如 /storage/<VOLUME_ID>/...
      final match = RegExp(r'^/storage/([^/]+)/').firstMatch(normalized);
      if (match != null && match.group(1) != 'emulated') {
        relative = normalized.substring(match.end);
      }
    }
    if (relative == null) return '';
    final slash = relative.lastIndexOf('/');
    return slash <= 0 ? '' : relative.substring(0, slash);
  }

  /// 解析资源在磁盘上的绝对路径。
  ///
  /// 优先用 `relativePath` + `title` 直接拼出路径：photo_manager 的
  /// `AssetEntity.file` 每张都要单独向 MediaStore 查一次记录，逐张解析
  /// 几百张照片会让首屏多等好几秒。拼接结果不存在时（例如外置存储卡）
  /// 再回退到 `asset.file`。
  static Future<String?> _resolvePath(AssetEntity asset) async {
    final direct = _directPath(asset);
    if (direct != null) {
      try {
        if (File(direct).existsSync()) return direct;
      } catch (_) {
        // 忽略，继续回退。
      }
    }
    final file = await _resolveFile(asset);
    return file?.path;
  }

  /// 由 `relativePath` 与 `title`（Android 上为 DISPLAY_NAME）拼出绝对路径。
  ///
  /// * Android 10+：`relativePath` 形如 `DCIM/Camera/`；
  /// * Android 9 及以下：`relativePath` 是 `_data` 的父目录，本身已带盘符。
  static String? _directPath(AssetEntity asset) {
    final rel = asset.relativePath;
    final title = asset.title;
    if (rel == null || rel.isEmpty || title == null || title.isEmpty) {
      return null;
    }
    if (rel.startsWith('/')) {
      return rel.endsWith('/') ? '$rel$title' : '$rel/$title';
    }
    final dir = rel.endsWith('/') ? rel : '$rel/';
    return '$_primaryStorageRoot/$dir$title';
  }

  /// 获取资源的真实文件路径，优先使用可直接显示的文件，失败时回退到原图。
  static Future<File?> _resolveFile(AssetEntity asset) async {
    try {
      final file = await asset.file;
      if (file != null && file.path.isNotEmpty) return file;
    } catch (_) {
      // 忽略，继续尝试 originFile。
    }
    try {
      final origin = await asset.originFile;
      if (origin != null && origin.path.isNotEmpty) return origin;
    } catch (_) {
      // 忽略。
    }
    return null;
  }
}
