import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/models.dart';
import 'smb_service.dart';

/// 远端（SMB）视频的本地 HTTP 代理。
///
/// ExoPlayer 只能读取 http/https/file 等 URI，无法直接访问 SMB。
/// 这里在回环地址上起一个极小的 HTTP 服务，把播放器的 `Range` 请求
/// 翻译成 SMB 区间读取：服务器端不需要安装任何额外服务，也不必先把
/// 整段视频下载到本地。
class RemoteVideoProxy {
  RemoteVideoProxy._();

  static final RemoteVideoProxy instance = RemoteVideoProxy._();

  final SmbService _smb = SmbService();
  final Map<String, _VideoSession> _sessions = {};
  final Random _random = Random.secure();
  HttpServer? _server;
  Future<void>? _starting;

  /// 登记一个视频会话，返回播放器可用的本地地址与用于注销的 token。
  Future<({Uri url, String token})> register(
    SmbConfig config,
    String remotePath,
    String name,
  ) async {
    await (_starting ??= _startServer());
    final token = List<int>.generate(12, (_) => _random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    _sessions[token] = _VideoSession(config, remotePath, name);
    // 文件名只用于让播放器/日志辨认，服务端一律按 token 查真实路径，
    // 因此 URL 里不会暴露共享目录结构。
    final fileName = Uri.encodeComponent(name.isEmpty ? 'video' : name);
    return (
      url: Uri.parse('http://127.0.0.1:${_server!.port}/v/$token/$fileName'),
      token: token,
    );
  }

  /// 播放页销毁时注销会话（服务本身常驻，开销可忽略）。
  void unregister(String token) {
    _sessions.remove(token);
  }

  Future<void> _startServer() async {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: true,
    );
    server.listen((request) {
      unawaited(_handle(request));
    });
    _server = server;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    // 关闭输出缓冲：让每个 SMB 分块立即到达播放器，起播/拖动更跟手。
    response.bufferOutput = false;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length < 2 || segments[0] != 'v') {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final session = _sessions[segments[1]];
      if (session == null) {
        response.statusCode = HttpStatus.gone;
        return;
      }

      var total = session.size ?? 0;
      if (total <= 0) {
        total = await _smb.remoteFileSize(session.config, session.remotePath);
        if (total <= 0) {
          response.statusCode = HttpStatus.notFound;
          return;
        }
        session.size = total;
      }

      var start = 0;
      var end = total - 1;
      var partial = false;
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null && rangeHeader.trim().isNotEmpty) {
        final range = _parseRange(rangeHeader, total);
        if (range == null) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers
              .set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          return;
        }
        start = range.$1;
        end = range.$2;
        partial = true;
      }

      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers
          .set(HttpHeaders.contentTypeHeader, _contentType(session.name));
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (partial) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      } else {
        response.statusCode = HttpStatus.ok;
      }

      // HEAD 只回响应头；不设置 contentLength，避免 close 时校验长度。
      if (request.method == 'HEAD') return;

      response.contentLength = end - start + 1;

      // 播放器退出或拖动进度条时会断开连接，此时停止读取 SMB，
      // 让底层连接随流取消一起关闭。
      var clientGone = false;
      unawaited(response.done.then<void>((_) {}, onError: (_) {
        clientGone = true;
      }));

      await for (final chunk in _smb.openRemoteVideoRange(
        session.config,
        session.remotePath,
        start,
        end + 1,
      )) {
        if (clientGone) break;
        response.add(chunk);
        try {
          // 逐块 flush 形成背压，避免把整段视频堆进内存。
          await response.flush();
        } catch (_) {
          break;
        }
      }
    } catch (e) {
      debugPrint('[videoProxy] ERR ${request.uri.path} $e');
    } finally {
      try {
        await response.close();
      } catch (_) {
        // 客户端已断开时关闭失败属于正常现象。
      }
    }
  }

  /// 解析 `Range: bytes=a-b` / `a-` / `-N`，返回闭区间 `(start, end)`。
  /// 返回 null 表示请求区间无效（应回 416）。
  (int, int)? _parseRange(String header, int total) {
    if (!header.toLowerCase().startsWith('bytes=')) return null;
    final spec = header.substring(6).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final startPart = spec.substring(0, dash).trim();
    final endPart = spec.substring(dash + 1).trim();

    if (startPart.isEmpty) {
      // 后缀区间：最后 N 字节。
      final suffix = int.tryParse(endPart);
      if (suffix == null || suffix <= 0) return null;
      return (max(0, total - suffix), total - 1);
    }

    final start = int.tryParse(startPart);
    if (start == null || start < 0 || start >= total) return null;
    if (endPart.isEmpty) return (start, total - 1);
    final parsedEnd = int.tryParse(endPart);
    if (parsedEnd == null || parsedEnd < start) return null;
    return (start, min(parsedEnd, total - 1));
  }

  static String _contentType(String name) {
    final ext = name.toLowerCase().split('.').last;
    switch (ext) {
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mkv':
        return 'video/x-matroska';
      case 'webm':
        return 'video/webm';
      case 'ts':
        return 'video/mp2t';
      case 'flv':
        return 'video/x-flv';
      case '3gp':
      case '3gpp':
        return 'video/3gpp';
      case 'avi':
        return 'video/x-msvideo';
      case 'wmv':
        return 'video/x-ms-wmv';
      default:
        return 'application/octet-stream';
    }
  }
}

class _VideoSession {
  final SmbConfig config;
  final String remotePath;
  final String name;

  /// 文件大小缓存：一次会话内长度不会变化，避免每个 Range 请求都探测一次。
  int? size;

  _VideoSession(this.config, this.remotePath, this.name);
}
