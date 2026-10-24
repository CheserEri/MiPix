import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/app_provider.dart';
import 'services/cache_service.dart';
import 'services/video_thumbnail_service.dart';
import 'screens/main_screen.dart';
import 'utils/mipix_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 首帧前不做任何 await：系统 UI 配置通过平台通道异步下发，不阻塞渲染。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.transparent,
  ));

  runApp(const ProviderScope(child: MiPixApp()));
  unawaited(CacheService().clearExpiredCache().catchError((_) {}));
  unawaited(VideoThumbnailService.instance.clearExpiredCache().catchError((_) {}));
}

class MiPixApp extends ConsumerWidget {
  const MiPixApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);

    return MaterialApp(
      title: '米影相册',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: MiPixTheme.lightTheme,
      darkTheme: MiPixTheme.darkTheme,
      home: const MainScreen(),
    );
  }
}
