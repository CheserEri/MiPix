import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

class LocalStorageService {
  static const _smbServersKey = 'smb_servers';
  static const _transfersKey = 'transfers';
  static const _syncedPhotosKey = 'synced_photos';

  /// 已成功备份到 SMB 的本地图片路径集合（用于区分已同步 / 未同步）。
  Future<Set<String>> getSyncedPhotos() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_syncedPhotosKey)?.toSet() ?? <String>{};
  }

  Future<bool> isSynced(String localPath) async {
    final synced = await getSyncedPhotos();
    return synced.contains(localPath);
  }

  Future<void> markSynced(List<String> localPaths) async {
    if (localPaths.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final synced = prefs.getStringList(_syncedPhotosKey)?.toSet() ?? <String>{};
    synced.addAll(localPaths);
    await prefs.setStringList(_syncedPhotosKey, synced.toList());
  }

  /// 用给定集合整体覆盖「已同步」记录。
  ///
  /// 调用方持有权威的内存集合，直接整表覆盖而非读-改-写，可避免并发调用
  /// 各自读旧值再写回、互相覆盖导致部分标记丢失（丢标记会让已备份的照片
  /// 重新显示为未同步，并可能在换 IP 连同一文件夹时重复上传）。
  Future<void> saveSyncedPhotos(Iterable<String> localPaths) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_syncedPhotosKey, localPaths.toList());
  }

  Future<void> clearSynced() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_syncedPhotosKey);
  }

  Future<List<SmbConfig>> getSmbServers() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_smbServersKey);
    if (data == null) return [];
    final list = jsonDecode(data) as List;
    return list.map((e) => SmbConfig.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> addSmbServer(SmbConfig config) async {
    final servers = await getSmbServers();
    servers.add(config);
    await _saveSmbServers(servers);
  }

  Future<void> deleteSmbServer(String id) async {
    final servers = await getSmbServers();
    servers.removeWhere((s) => s.id == id);
    await _saveSmbServers(servers);
  }

  Future<void> updateSmbServer(String id, SmbConfig config) async {
    final servers = await getSmbServers();
    final index = servers.indexWhere((s) => s.id == id);
    if (index != -1) {
      servers[index] = config;
      await _saveSmbServers(servers);
    }
  }

  Future<void> _saveSmbServers(List<SmbConfig> servers) async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(servers.map((e) => e.toJson()).toList());
    await prefs.setString(_smbServersKey, data);
  }

  Future<List<TransferTask>> getTransfers() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_transfersKey);
    if (data == null) return [];
    final list = jsonDecode(data) as List;
    return list.map((e) => TransferTask.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveTransfers(List<TransferTask> transfers) async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(transfers.map((e) => e.toJson()).toList());
    await prefs.setString(_transfersKey, data);
  }
}