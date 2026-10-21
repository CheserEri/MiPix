# MiPix 米影相册

纯本地运行的 Android 相册应用：浏览手机照片与视频，并通过 SMB 协议把照片备份到 NAS。无后端服务、无账号体系，数据只在本机与自有 SMB 服务器之间流动。

- Flutter + Riverpod，仅 Android
- 版本 `1.0.12+13`（Dart SDK `^3.11.0`）
- compileSdk 36 / targetSdk 35 / minSdk 跟随 `flutter.minSdkVersion`
- applicationId `com.chesereri.mipix`

> 历史问题、根因分析与真机验证记录见 [技术问题与方案.md](./app/技术问题与方案.md)。

## 功能

### 本地相册

- **照片**：读取最近 500 张照片，按修改时间倒序、按日期分组，4 列网格展示；支持多选后直接备份。
- **相册**：按 MIUI 习惯分为「系统相册 / 我的相册 / 更多相册」。`Pictures/Gallery/` 下的目录归入「我的相册」，其余目录归入「更多相册」。
- **查看器**：左右滑动切换、双指缩放、视频播放、分享、删除本地照片、查看 EXIF 信息。

### SMB 相册

- 服务器管理：添加 / 编辑 / 测试连接 / 删除 / 设为默认；支持填写共享名与根目录。
- 相册扫描：从根目录递归扫描（最大 8 层），跳过 `Android/`、隐藏目录与 `.mipix_covers`；封面优先使用自定义封面，否则取第一个可读缩略图。
- 远程浏览：图片与视频分页加载，每页 50 条，滚动到底自动加载更多；读取 EXIF 拍摄时间用于排序。
- 远程操作：查看原图、播放视频、另存到系统相册 `Pictures/MiPix`、把任意照片设为相册封面。

### 备份

- 选择照片备份（单张或多选），或在传输页对「全部未备份照片」发起整批备份；远端结构为 `<rootPath>/<相册名>/<文件名>`，相册名取本地目录名并按相册列表的规则本地化（如 `Camera` → `相机`），无法识别目录时写入根目录。
- 同批次内同名文件只保留最大的一份，其余标记为跳过。
- 「已备份」记录按服务器分别保存；切换服务器时，待备份数量以当前服务器为准。
- 传输页按批次展示阶段、速度、进度；支持「重试失败」与「清除已完成」。

## 备份冲突规则

同名文件先比较大小，只有「同名同大小」才会继续计算 SHA-256；哈希探针串行执行（先读远端，再读本地）。

| 条件 | 结论 | 行为 |
|---|---|---|
| 远端没有同名文件 | `upload` | 正常上传 |
| 同名、同大小、SHA-256 相同 | `skipSynced` | 视为已备份，记入同步记录 |
| 远端同名文件更大，或同大小但哈希不同 | `skipKeepRemote` | 保留远端文件，标记为跳过 |
| 同批次内多个候选映射到同一远端路径，当前项更小 | `skipBatchCollision` | 跳过并被更大的一份取代 |
| 该本地路径已在传输队列中 | `skipAlreadyActive` | 不重复建任务 |
| 远端清单或远端哈希读取失败 | `failUnknown` | 不写入，保留为可重试失败 |
| 本地文件或本地哈希不可读 | `failLocalUnreadable` | 不写入，保留为可重试失败 |

远端清单读取失败时整组按 `failUnknown` 处理（fail-closed），不会为了「尽量传上去」而覆盖远端内容。

## 上传与可靠性

1. **准备**：读取目标相册的远端清单（文件名 → 大小），执行冲突规划并建立传输任务。
2. **上传**：内容先写入 `.mipixtmp` 临时文件，按 64936 字节分块。
   - 单连接：若临时文件已存在且长度在 `(0, 本地大小)` 之间，从该偏移续传。
   - 大文件（≥ 8 MiB 且上传并发 ≥ 2）：按区间拆成多条连接并行写入同一临时文件，默认 4 条分片连接；单条分片断链最多重连 20 次后交给上层重试。
3. **收尾**：用远端 `stat` 比对临时文件长度与本地文件长度，一致才 `rename` 覆盖正式文件，并回写拍摄时间。
   - 长度不一致会删除临时文件并报错，正式文件名上始终保留旧文件。
   - **不做整份回读重算 SHA-256**：全量回读大文件耗时数分钟，且查不出「长度不变、内容静默变化」。

重试与熔断：

- 只有连接类错误才重试；每个文件最多 3 次重试（共 4 次尝试），退避 1s → 2s → 4s → 8s 封顶。
- 同一批次连续 5 次连接类失败即停止本批剩余文件，避免网络不可用时把整批拖死。
- 每个 worker 使用独立连接，断链后重建；小文件走 worker 池并发（并发数由设置页控制），大文件串行独占多连接，避免连接争抢。
- 上传失败会立即写入传输队列，批次结束再统一落盘；重建连接、续传偏移与最终失败原因都有结构化日志。
- 批次期间通过 MethodChannel `mipix/keepalive` 持有 `PARTIAL_WAKE_LOCK` 与 `WifiLock`，引用计数归零时释放。

## 缓存与并发

| 项 | 取值 |
|---|---|
| 相册 / 媒体列表 / EXIF 缓存有效期 | 7 天 |
| 缓存上限 | 默认 500 MiB，可在设置页选择 200 MiB / 500 MiB / 1 GiB / 2 GiB |
| 淘汰顺序 | 先淘汰原图，再淘汰缩略图；同类按最后修改时间升序 |
| 缩略图 | 约 200 px，优先使用远端 EXIF 内嵌缩略图，否则从原图生成 |
| 缩略图内存缓存 | 400 项 |
| 图片加载并发 | 8 |
| 上传并发 | 默认 4，最高 8（设置页 1–8） |
| 远程分页 | 50 条/页 |
| SMB 建连闸门 | 最多 3 条并发连接 |
| 超时 | 建连 20s、关闭 5s、读写停滞 30s；连接最长复用 1 分钟 |

## 项目结构

```
MiPix/
├── README.md
├── LICENSE
└── app/
    ├── lib/
    │   ├── main.dart                # 初始化保活与本地存储，装配主题
    │   ├── models/                  # MediaItem / Album / SmbConfig / TransferTask
    │   ├── providers/               # app / photo / album / smb / transfer 状态
    │   ├── screens/                 # 照片、相册、网格、查看器、传输、设置、SMB 管理
    │   ├── services/                # SMB、照片、缓存、本地存储、保活
    │   ├── utils/                   # MIUI 风格主题、SMB 表单纯函数
    │   └── widgets/                 # 缩略图、卡片、动画、服务器选择等
    ├── android/                     # compileSdk 36、权限、WakeLock/WifiLock、纯白启动窗
    ├── assets/branding/             # 品牌源文件（不参与打包）
    ├── packages/smb_connect/        # 本地补丁的 SMB2/3 纯 Dart 实现
    ├── test/                        # 传输恢复、缩略图、保活单元测试
    ├── 技术问题与方案.md
    └── pubspec.yaml
```

## 开发与构建

```bash
cd app
flutter pub get
flutter run

# Release APK
flutter build apk --release

# 单元测试
flutter test
```

需要 Flutter SDK（Dart `^3.11.0`）与 Android SDK 36。Windows 上如遇 Flutter 进程静默卡死，请关闭命令沙箱后执行。

依赖要点：

| 依赖 | 用途 |
|---|---|
| flutter_riverpod `^2.6.1` | 状态管理 |
| photo_manager `^3.6.0` | 本地相册与媒体读取 |
| smb_connect `^0.0.8+1` | SMB2/3 通信；通过 `dependency_overrides` 指向本地 `packages/smb_connect` |
| shared_preferences `^2.2.0` | 配置、同步记录、传输队列、缓存元数据 |
| crypto `^3.0.6` | SHA-256 与 SMB 签名 |
| image `^4.0.0` | 远程缩略图生成 |
| video_player `^2.9.0` | 视频播放 |
| share_plus `^10.0.0` | 系统分享 |
| exif `^3.3.0` | EXIF 信息展示 |
| path_provider / path | 缓存目录与路径处理 |
| intl `^0.19.0` | 日期格式化 |

## 权限

| 权限 | 用途 |
|---|---|
| `INTERNET` / `ACCESS_NETWORK_STATE` / `ACCESS_WIFI_STATE` | SMB 连接与网络状态 |
| `WAKE_LOCK` | 备份期间保持 CPU 唤醒 |
| `READ_MEDIA_IMAGES` | Android 13+ 读取图片 |
| `READ_MEDIA_VIDEO` | Android 13+ 读取视频（必须与图片权限同时声明，否则查询不到任何视频） |
| `READ_MEDIA_VISUAL_USER_SELECTED` | Android 14+ 部分授权 |
| `READ_EXTERNAL_STORAGE`（maxSdk 32） | Android 12 及以下读取媒体 |
| `WRITE_EXTERNAL_STORAGE`（maxSdk 29） | Android 10 及以下保存到相册 |
| `ACCESS_MEDIA_LOCATION` | 读取 EXIF 中的 GPS，避免备份后位置信息被系统抹零 |

## 本地数据

使用 SharedPreferences 保存，均不涉及云端：

| 键 | 内容 |
|---|---|
| `smb_servers` | SMB 服务器配置 JSON 数组，**密码以明文随配置保存** |
| `synced_photos_v2` | `serverId → 已备份本地路径集合`；旧版全局键不迁移 |
| `transfers` | 传输任务队列 |
| `theme_mode` | `system` / `light` / `dark` |
| `upload_concurrency`、`cache_limit_bytes` | 上传并发与缓存上限 |
| `cache_metadata` / `album_cache_*` | 缓存元数据、相册媒体列表与 EXIF 拍摄时间；缩略图与原图分别以 `thumb3_cache_*` / `image_cache_*` 文件存放在应用私有目录 |

## 已知限制

- 暂停 / 取消只会改变任务状态并停止上报进度，**不会中断已经进入 SMB 写入的文件**。
- `SmbConfig.port` 目前不参与连接，底层始终使用默认 445 端口。
- 对账（`reconcileSynced`）只按「同名 + 同大小」判断，不校验哈希；同名同大小的不同内容可能被误记为已备份。
- 跨批次没有按「服务器 + 远端路径」互斥，两个重叠批次仍可能争用同一远端路径。
- 保活锁的并发 `acquire` 存在计数竞态，极端情况下原生锁状态与引用计数可能不一致。
- 远端视频通过本地回环 HTTP 代理在线播放，容器支持取决于 ExoPlayer：AVI / WMV 无法播放。
- 本地照片列表只读取最近 500 张，更早的照片不会出现在「照片」页。
- 远端相册扫描最多 8 层，深层目录不会继续展开。

## License

[MIT](./LICENSE)

## 致谢

MiPix 的开发过程中，Mimo 与 DeepSeek 两个大模型提供了实实在在的帮助：从 SMB 视频流式播放的链路设计、视频缩略图的原生抽帧方案，到进度条手势冲突的逐层排查、Android 媒体权限的定位，以及大量代码审查、文档整理与真机问题分析，都离不开它们的支持。它们帮助这个纯本地、无后端的小项目一步步走到今天，在此致以诚挚的感谢。

同时也感谢 Flutter、Riverpod、photo_manager、video_player、smb_connect 等开源项目的作者与维护者——没有这些扎实的基础设施，MiPix 无从开始。
