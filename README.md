# MiPix 米影相册

MiPix（米影相册）是一款纯本地运行的相册管理工具，采用**玻璃拟态 + OLED 沉浸**设计风格，支持浏览本地照片和通过 SMB 协议备份到远程服务器。

## 项目结构

```
MiPix/
└── app/                  # 前端 (Flutter Android)
    ├── lib/
    │   ├── main.dart
    │   ├── models/           # 数据模型
    │   ├── providers/        # Riverpod 状态管理
    │   ├── screens/          # 页面 (8个)
    │   ├── services/         # 本地服务 (SMB、照片、存储、缓存)
    │   ├── widgets/          # UI 组件 (玻璃容器、动画等)
    │   └── utils/           # 工具类
    └── android/             # Android 配置
```

## 功能特性

### 核心功能
- **本地相册**：按日期时间轴浏览手机本地照片
- **相册网格**：沉浸式网格浏览本地与远程相册
- **SMB 备份**：一键将本地照片同步到 SMB 共享目录
- **远程浏览**：在线浏览 SMB 服务器上的相册，支持子目录导航
- **传输队列**：管理上传任务，支持进度追踪和取消功能

### 性能优化
- **无限滚动**：分页加载远程相册，滚动到底部自动加载更多（每页50条）
- **多线程并发**：智能控制图片加载并发数（最大4个），避免网络拥塞
- **缩略图缓存**：自动生成并缓存 200x200 缩略图，大幅提升加载速度
- **本地缓存**：缓存相册列表、媒体文件列表和图片，减少重复网络请求

### UI/UX
- **玻璃拟态设计**：深色 OLED 沉浸风格，高斯模糊卡片，纯黑背景
- **流畅动画**：页面淡入淡出、列表 stagger 滑入、按钮弹性反馈、图片渐显
- **纯本地运行**：无需后端服务，SMB 直连
- **Android 16 适配**：targetSdk 36，支持最新 Android 特性

## 快速开始

### 运行前端

```bash
cd app
flutter run
```

### 构建 APK

```bash
cd app
flutter build apk --release
```

## 技术栈

- **框架**：Flutter + Riverpod
- **SMB 操作**：smb_connect (纯 Dart 实现)
- **本地照片**：photo_manager 插件
- **本地存储**：shared_preferences
- **UI 风格**：玻璃拟态 (Glassmorphism) + OLED 深色沉浸

## 依赖

| 依赖 | 版本 | 用途 |
|------|------|------|
| flutter_riverpod | ^2.6.1 | 状态管理 |
| photo_manager | ^3.6.0 | 本地相册访问 |
| smb_connect | ^0.0.8+1 | SMB 协议通信 |
| shared_preferences | ^2.2.0 | 本地数据存储 |
| share_plus | ^10.0.0 | 系统分享 |
| exif | ^3.3.0 | EXIF 信息读取 |
| intl | ^0.19.0 | 日期格式化 |
| path_provider | ^2.1.0 | 文件路径 |
| path | ^1.9.0 | 路径处理 |
| image | ^4.3.0 | 图片处理（缩略图生成） |

## License

MIT
