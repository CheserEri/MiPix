# MiPix 米影相册

MiPix（米影相册）是一款**纯本地运行**的 Android 相册管理工具，采用**玻璃拟态 + OLED 沉浸**设计风格，界面严格对齐 MIUI 系统相册。支持浏览本地照片，并通过 SMB 协议一键备份到远程服务器（NAS）。

- 无需后端服务，SMB 直连
- 框架：Flutter + Riverpod
- 目标平台：Android（targetSdk 36 / minSdk 24）

> 技术问题、根因分析与解决方案的整合记录见 [技术问题与方案.md](./app/技术问题与方案.md)。

## 项目结构

```
MiPix/
├── README.md                       # 本文件
├── LICENSE
└── app/                            # Flutter Android 工程
    ├── lib/
    │   ├── main.dart
    │   ├── models/                 # 数据模型（含 TransferStatus 等）
    │   ├── providers/              # Riverpod 状态管理（app/photo/album/smb/transfer）
    │   ├── screens/                # 页面
    │   ├── services/               # 本地服务（SMB、照片、存储、缓存、保活）
    │   ├── widgets/                # UI 组件（玻璃容器、动画等）
    │   └── utils/                  # 工具类
    ├── android/                    # Android 配置（MethodChannel 保活、权限）
    ├── assets/                     # 应用资源
    ├── packages/smb_connect/       # 本地补丁的 SMB 协议实现（纯 Dart）
    ├── test/                       # 单元测试
    ├── 技术问题与方案.md            # 本项目技术问题整合文档
    └── pubspec.yaml
```

## 功能特性

### 核心功能
- **本地相册**：按日期时间轴浏览手机本地照片
- **相册网格**：沉浸式网格浏览本地与远程相册
- **SMB 备份**：一键将本地照片同步到 SMB 共享目录
- **远程浏览**：在线浏览 SMB 服务器上的相册，支持子目录导航
- **传输队列**：管理上传任务，支持进度追踪、取消与「重试失败」；按阶段展示 `上传 / 本地摘要 / 校验 / 收尾` 进度
- **增量备份**：同名文件冲突按「远端路径 + 大小 + SHA-256」判定，安全失败并给出可理解原因
- **上传后回读校验（fail-closed）**：`.mipixtmp` 临时文件写完后，先算本地 SHA-256、再回读远端实算 SHA-256，两者与远端实际大小同时吻合才改名；任一不符即删临时文件并报错，**绝不 rename**。本地摘要复用 `PhotoService.hashFile`（isolate 内流式哈希），并**与上传并行预取**，把原先「上传后再顺序重读整份文件」的耗时吸收进上传阶段。

### 性能优化
- **无限滚动**：分页加载远程相册，滚动到底部自动加载更多（每页 50 条）
- **多线程并发**：智能控制图片加载并发数（最大 4 个），避免网络拥塞
- **缩略图三级缓存**：内存 → 磁盘 → 远端 EXIF 内嵌缩略图（7 天 TTL + 上限淘汰）
- **本地缓存**：缓存相册列表、媒体文件列表和图片，减少重复网络请求
- **SMB 签名优化**：SMB2.1 HMAC-SHA256 改用 `package:crypto`，大文件备份吞吐由 5.0 提升到约 19.5 MB/s
- **SMB 读取块对齐**：读缓冲由上游固定的 4095 字节对齐到服务端单次请求上限（`smbReadBlockSize = 64936`），读吞吐由约 0.7 MB/s 提升到约 19 MB/s，且短读按真实字节数上报（否则会把残留旧字节当成新数据，对回读校验是致命的）
- **多连接区间回读（P3 原型，默认关闭）**：把远端回读按 4 MiB 区间切分、最多 4 条连接并发，乱序块经有界重排缓冲后按偏移升序喂入**唯一** SHA-256 sink。实测同机 / 同 NAS / 同文件：校验吞吐 4.25 → 13–15 MB/s（约 **3.1–3.6 倍**），端到端关键路径 ≈193 s → ≈84–95 s（**−51% ~ −57%**），内存无增长。因主 isolate CPU 偏高、故障注入未覆盖，`rangeReadbackConcurrency` 仍为 **0**（详见技术文档 13.10）

### UI/UX
- **玻璃拟态设计**：深色 OLED 沉浸风格，高斯模糊卡片，纯黑背景
- **流畅动画**：页面淡入淡出、列表 stagger 滑入、按钮弹性反馈、图片渐显
- **Android 16 适配**：targetSdk 36，支持最新 Android 特性

## 快速开始

```bash
cd app
flutter run
```

### 构建 APK

```bash
cd app
flutter build apk --release
```

> Windows 上构建/运行如遇进程静默卡死，请关闭命令沙箱后执行。

### 运行测试

```bash
cd app
flutter test
```

## 技术栈与依赖

| 依赖 | 版本 | 用途 |
|------|------|------|
| flutter_riverpod | ^2.6.1 | 状态管理 |
| photo_manager | ^3.6.0 | 本地相册访问（MediaStore） |
| smb_connect | 本地 patch 包 | SMB 协议通信（纯 Dart） |
| shared_preferences | ^2.2.0 | 本地数据存储 |
| share_plus | ^10.0.0 | 系统分享 |
| exif | ^3.3.0 | EXIF 信息读取 |
| intl | ^0.19.0 | 日期格式化 |
| path_provider | ^2.1.0 | 文件路径 |
| path | ^1.9.0 | 路径处理 |
| image | ^4.3.0 | 图片处理（缩略图生成） |
| crypto | ^3.0.6 | SHA-256 / HMAC（哈希校验、SMB 签名） |

## 配置说明（SMB 备份）

- 服务器地址：`192.168.31.184`（示例 NAS），共享名如 `MyDoc`，`rootPath` 决定备份根目录。
- 远端实际路径规则：`/<共享名>/<rootPath>/<相册名>/<文件名>`。
- 单次写入硬上限 **64 KiB**（Samba 4.19），客户端分块 `64936` 字节；上传使用 `.mipixtmp` 临时文件、全部写完后再原子改名。
- 传输期间通过 MethodChannel（`mipix/keepalive`）持有 `WifiLock` + `PARTIAL_WAKE_LOCK`，避免息屏后连接中断；采用引用计数，仅在 0→1 申请、1→0 释放。
- 增量备份清单读取失败时 **fail-closed**：不写入该目录下任何文件，并提示可重试原因。

## License

MIT
