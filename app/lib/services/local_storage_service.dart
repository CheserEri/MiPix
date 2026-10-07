import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

class LocalStorageService {
  static const _smbServersKey = 'smb_servers';
  static const _transfersKey = 'transfers';

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