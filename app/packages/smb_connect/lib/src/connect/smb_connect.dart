import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:smb_connect/src/connect/impl/base_configuration.dart';
import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/connect/impl/smb1/smb1_connect.dart';
import 'package:smb_connect/src/connect/impl/smb2/smb2_connect.dart';
import 'package:smb_connect/src/connect/smb_file.dart';
import 'package:smb_connect/src/connect/smb_session.dart';
import 'package:smb_connect/src/connect/smb_transport.dart';
import 'package:smb_connect/src/connect/smb_tree.dart';
import 'package:smb_connect/src/credentials.dart';
import 'package:smb_connect/src/dialect_version.dart';
import 'package:smb_connect/src/smb/authentication_type.dart';
import 'package:smb_connect/src/smb/file_entry.dart';
import 'package:smb_connect/src/smb/nt_status.dart';
import 'package:smb_connect/src/smb/ntlm_password_authenticator.dart';
import 'package:smb_connect/src/utils/base.dart';
import 'package:smb_connect/src/utils/extensions.dart';
import 'package:smb_connect/src/utils/strings.dart';

enum ForceProtocol { auto, smb1, smb2 }

abstract class SmbConnect {
  static Credentials _buildCredentials(
      String? username, String? password, String? domain) {
    if (username != null && password != null && domain != null) {
      return NtlmPasswordAuthenticator(
        type: AuthenticationType.USER,
        domain: domain,
        username: username,
        password: password,
      );
    } else {
      return NtlmPasswordAuthenticator();
    }
  }

  static Future<bool> pingConnection({
    required String host,
    required String username,
    required String password,
    required String domain,
  }) async {
    final config = BaseConfiguration(
      credentials: _buildCredentials(username, password, domain),
      username: username,
      password: password,
      domain: domain,
      bufferCacheSize: 0x1FFF,
      // debugPrint: debugPrint,
    );
    SmbTransport transport = SmbTransport(config, host);
    try {
      return await transport.ensureConnected();
    } finally {
      await transport.close();
    }
  }

  static Future<SmbConnect> connect(
    Configuration config,
    // Credentials credentials,
    String host, {
    Function(SmbConnect)? onDisconnect,
  }) async {
    SmbTransport transport = SmbTransport(config, host);
    // 建连（协商 / 会话建立）任一阶段失败都必须关闭底层 socket 再上抛。
    //
    // 否则每次失败的 connectAuth 都会泄漏一条已 ESTABLISHED 的 TCP 连接：
    // 服务端（Win7 等）会持续计数，几次抖动后即报
    // "No more connections can be made to this remote computer"，此后连正常
    // 读取也会因重试不断新建连接而雪崩。实测曾累积到 420 条泄漏连接。
    try {
      if (!await transport.ensureConnected()) {
        throw "Can't connect to $host";
      }
      SmbConnect connect;
      if (!transport.isSMB2()) {
        connect = Smb1Connect(config, transport);
      } else {
        connect = Smb2Connect(config, transport);
      }
      final session = connect.initSession();
      await session.setup();

      if (onDisconnect != null) {
        transport.onDisconnect = (_) {
          onDisconnect.call(connect);
        };
      }
      return connect;
    } catch (_) {
      try {
        await transport.close();
      } catch (_) {
        // socket 尚未建立时 close 可能抛 LateInitializationError，忽略即可。
      }
      rethrow;
    }
  }

  static Future<SmbConnect> connectAuth({
    required String host,
    required String username,
    required String password,
    required String domain,
    bool debugPrint = false,
    bool debugPrintLowLevel = false,
    bool forceSmb1 = false,
    Function(SmbConnect)? onDisconnect,
  }) async {
    final creds = _buildCredentials(username, password, domain);
    return await connect(
        BaseConfiguration(
          credentials: creds,
          username: username,
          password: password,
          domain: domain,
          bufferCacheSize: 0x1FFF,
          debugPrint: debugPrint,
          debugPrintLowLevel: debugPrintLowLevel,
          forceSmb1: forceSmb1,
          maximumVersion:
              forceSmb1 ? DialectVersion.SMB1 : DialectVersion.SMB210,
        ),
        host,
        onDisconnect: onDisconnect);
  }

  final Configuration configuration;
  final SmbTransport transport;

  final String host;
  SmbSession? session;
  final Map<String, SmbTree> _trees = {};

  SmbConnect(this.configuration, this.transport) : host = transport.host;

  SmbSession initSession();

  SmbTree initTree(String share);

  @protected
  Future<SmbTree> shareTree(String share) async {
    var tree = _trees[share];
    if (tree == null) {
      tree = initTree(share);
      await tree.setup();
      _trees[share] = tree;
    }
    return tree;
  }

  Future close() async {
    var trees = _trees.values.toList();
    if (configuration.debugPrint) {
      print("Close SmbConnect $host/${trees.map((e) => e.share)}");
    }
    _trees.clear();
    for (var tree in trees) {
      await tree.close();
    }
    await transport.close();
  }

  Future<SmbFile> file(String path);

  Future<SmbFile> create(SmbFile file) async {
    return await createFile(file.path);
  }

  Future<SmbFile> createFile(String path);

  Future<SmbFile> createFolder(String path);

  Future<SmbFile> delete(SmbFile file);

  // Future<SmbFile> copyTo(SmbFile srcFile, String dstPath,
  //     {bool replace = false});

  Future<SmbFile> rename(SmbFile srcFile, String dstPath,
      {bool replace = false});

  /// 设置远端文件的创建/最后写入/最后访问时间（自 1970 起的毫秒数）。
  ///
  /// [createTime] 默认沿用 [lastWriteTime]；[lastAccessTime] 与 [changeTime]
  /// 默认不修改。可选字段传 0 表示不修改，符合 FILE_BASIC_INFORMATION 语义。
  /// 默认实现不支持该方法，SMB2 实现已覆盖。
  Future<void> setFileTime(
    SmbFile file, {
    required int lastWriteTime,
    int? createTime,
    int? lastAccessTime,
    int? changeTime,
  }) {
    throw UnsupportedError('setFileTime is not supported');
  }

  Future<Stream<Uint8List>> openRead(SmbFile file, [int? start, int? end]);

  Future<IOSink> openWrite(SmbFile file, {bool append = false});

  Future<RandomAccessFile> open(SmbFile file, {FileMode mode = FileMode.read});

  Future<List<SmbFile>> listShares();

  Future<List<SmbFile>> listFiles(SmbFile folder, [String wildcard = "*"]);

  List<SmbFile> mapFileEntries(SmbFile folder, List<FileEntry> entries) {
    return entries.mapNotNull((e) {
      var name = e.getName();
      if (name == SmbFile.NAME_DOT || name == SmbFile.NAME_DOT_DOT) {
        return null;
      }
      return SmbFile(
          folder.path.addToken('/', name, ignoreDivIfSame: true),
          folder.uncPath.addToken("\\", name, ignoreDivIfSame: true),
          folder.share,
          e.createTime(),
          e.lastModified(),
          e.lastAccess(),
          e.getAttributes(),
          e.length(),
          true);
    });
  }

  static String getUncPath(String path) {
    path = path.replaceAll("/", "\\");
    if (path.startsWith("\\")) {
      return "\\${path.afterToken("\\").afterToken("\\")}";
    } else {
      return "\\${path.afterToken("\\")}";
    }
  }

  static String getShare(String path) {
    if (path.startsWith('/')) {
      var path2 = path.afterToken("/");
      return path2.beforeToken("/", def: path2);
    } else {
      return path.beforeToken('/');
    }
  }

  static bool responseStatusNotFound(int status) {
    return status == NtStatus.NT_STATUS_NO_SUCH_DEVICE ||
        status == NtStatus.NT_STATUS_NO_SUCH_FILE ||
        status == NtStatus.NT_STATUS_OBJECT_NAME_NOT_FOUND ||
        status == NtStatus.NT_STATUS_OBJECT_PATH_NOT_FOUND ||
        status == NtStatus.NT_STATUS_NETWORK_NAME_DELETED;
  }

  static const IPC_SHARE = "IPC\$";
  static const IPC_PATH = "/IPC\$/srvsvc";
}
