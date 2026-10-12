import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

class LocalStorageService {
  static const _smbServersKey = 'smb_servers';
  static const _transfersKey = 'transfers';
  // v2：按服务器分别记录（serverId → 已备份的本地路径集合），切换服务器时
  // 「已备份」状态以对应服务器为准。旧的全局 key 直接废弃，不做迁移。
  static const _syncedPhotosKey = 'synced_photos_v2';

  /// 全部服务器的「已备份」记录。
  Future<Map<String, Set<String>>> getAllSynced() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_syncedPhotosKey);
    if (data == null) return <String, Set<String>>{};
    final map = jsonDecode(data) as Map<String, dynamic>;
    return map.map<String, Set<String>>(
        (k, v) => MapEntry(k, (v as List).cast<String>().toSet()));
  }

  /// 某台服务器的「已备份」本地路径集合。
  Future<Set<String>> getSyncedPhotos(String serverId) async {
    return (await getAllSynced())[serverId] ?? <String>{};
  }

  /// 整表覆盖持久化（调用方持有权威内存集合，避免并发读-改-写互相覆盖）。
  Future<void> saveAllSynced(Map<String, Set<String>> all) async {
    final prefs = await SharedPreferences.getInstance();
    final enc = all.map<String, List<String>>(
        (k, v) => MapEntry(k, v.toList()));
    await prefs.setString(_syncedPhotosKey, jsonEncode(enc));
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