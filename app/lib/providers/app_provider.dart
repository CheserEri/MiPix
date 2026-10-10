import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeMode>((ref) {
  return ThemeNotifier();
});

class ThemeNotifier extends StateNotifier<ThemeMode> {
  ThemeNotifier() : super(ThemeMode.system) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString('theme_mode');
    if (mode == 'dark') state = ThemeMode.dark;
    if (mode == 'light') state = ThemeMode.light;
  }

  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    final name = mode == ThemeMode.dark
        ? 'dark'
        : mode == ThemeMode.light
            ? 'light'
            : 'system';
    await prefs.setString('theme_mode', name);
  }
}

/// 当前使用的 SMB 服务器。
///
/// 室内/室外往往是同一份存储、只是 IP 不同，用户需要随时切换。选择结果
/// 持久化保存，重启后继续沿用；备份目标与 SMB 相册浏览都以它为准。
final defaultServerProvider =
    StateNotifierProvider<ActiveServerNotifier, String?>(
  (ref) => ActiveServerNotifier(),
);

class ActiveServerNotifier extends StateNotifier<String?> {
  ActiveServerNotifier() : super(null) {
    _load();
  }

  static const _key = 'active_server_id';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved != null && saved.isNotEmpty) state = saved;
  }

  Future<void> select(String serverId) async {
    state = serverId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, serverId);
  }
}

/// 备份并发数：默认 4，可在设置中调整，上限 8。
const int defaultUploadConcurrency = 4;
const int maxUploadConcurrency = 8;

/// 将任意输入规整到 [1, maxUploadConcurrency] 区间。
int normalizeUploadConcurrency(int value) {
  if (value < 1) return 1;
  if (value > maxUploadConcurrency) return maxUploadConcurrency;
  return value;
}

/// 同时上传的文件数（并行备份的 worker 数量）。
final uploadConcurrencyProvider =
    StateNotifierProvider<UploadConcurrencyNotifier, int>(
  (ref) => UploadConcurrencyNotifier(),
);

class UploadConcurrencyNotifier extends StateNotifier<int> {
  UploadConcurrencyNotifier() : super(defaultUploadConcurrency) {
    _load();
  }

  static const _key = 'upload_concurrency';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_key);
    if (value != null) state = normalizeUploadConcurrency(value);
  }

  Future<void> setConcurrency(int value) async {
    final normalized = normalizeUploadConcurrency(value);
    state = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, normalized);
  }
}
