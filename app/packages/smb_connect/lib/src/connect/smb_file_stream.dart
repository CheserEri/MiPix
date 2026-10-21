import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:smb_connect/src/connect/smb_file.dart';
import 'package:smb_connect/src/connect/smb_tree.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_blank_response.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_close.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_read_and_x.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_read_and_x_response.dart';
import 'package:smb_connect/src/connect/impl/smb2/create/smb2_close_request.dart';
import 'package:smb_connect/src/connect/impl/smb2/create/smb2_close_response.dart';
import 'package:smb_connect/src/connect/impl/smb2/io/smb2_read_request.dart';
import 'package:smb_connect/src/connect/impl/smb2/io/smb2_read_response.dart';
import 'package:smb_connect/src/smb/request_param.dart';
import 'package:smb_connect/src/smb_constants.dart';

int openReadNextNum = 0;

/// 单次 SMB READ 请求可携带的最大负载。
///
/// 上游实现把读缓冲固定成 4095 字节，于是每个 4 KiB 都要一次完整往返，
/// 实测吞吐只有约 0.7 MB/s（写路径用同量级的 64 KiB 块且有 19 MB/s）。
/// 与服务端单次请求上限对齐后，读吞吐提升一个数量级。取值与写路径
/// （[SmbStreamConsumer.blockSize]）一致：Samba 4.19 实测可接受的最大块。
const int smbReadBlockSize = 64936;

Stream<Uint8List> smbOpenRead(
    SmbFile file, SmbTree tree, Uint8List? fileId, int fid, int start,
    [int? length]) async* {
  // int openReadNum = openReadNextNum++;
  length = length ?? (file.size - start);
  var buffSize = min(length, smbReadBlockSize);
  var position = 0;
  Uint8List buff = Uint8List(buffSize);
  try {
    do {
      var remain = length - position;
      var readLen = min(buff.length, remain);
      var res = await smbReadFromFile(
          file, tree, fileId, fid, buff, position + start, 0, readLen);
      // 服务端可能短读甚至返回 0：必须按真实读到的字节数上报。原来的实现只要
      // 请求长度等于缓冲区长度就整块 yield，短读时会把缓冲区里遗留的旧字节
      // 当作新数据（长度不变、内容错位），这在「上传后回读校验」里是致命的。
      if (res <= 0) break;
      yield res == buff.length ? buff : Uint8List.view(buff.buffer, 0, res);
      position += res;
    } while (position < length);
  } finally {
    // 消费者提前取消订阅（如视频播放器断开、拖动进度条）时也必须关闭句柄，
    // 否则共享连接上的未关闭句柄会不断累积，最终让服务端拒绝后续 CREATE。
    try {
      await smbCloseFile(file, tree, fileId, fid);
    } catch (_) {
      // 连接已断开时关闭失败无需处理，句柄随连接一起回收。
    }
  }
}

void readAsync(SmbFile file, SmbTree tree, Uint8List? fileId, int fid,
    int start, int? length, StreamController<Uint8List> controller) async {
  length ??= (file.size - start);
  var buffSize = min(length, smbReadBlockSize);
  // var index = 0;
  var position = 0;
  Uint8List buff = Uint8List(buffSize);
  do {
    var remain = length - position;
    var readLen = min(buff.length, remain);
    var res = await smbReadFromFile(
        file, tree, fileId, fid, buff, start + position, 0, readLen);
    // 与 [smbOpenRead] 一致：短读按真实字节数上报，返回 0 时结束，避免死循环。
    if (res <= 0) break;
    if (res == buff.length) {
      controller.add(buff);
    } else {
      var lastBuff = Uint8List.view(buff.buffer, 0, res);
      controller.add(lastBuff);
    }
    position += res;
  } while (position < length);
  await smbCloseFile(file, tree, fileId, fid);
  await controller.close();
}

Stream<Uint8List> smbOpenRead2(
    SmbFile file, SmbTree tree, Uint8List? fileId, int fid, int start,
    [int? length]) {
  var controller = StreamController<Uint8List>.broadcast();
  readAsync(file, tree, fileId, fid, start, length, controller);
  return controller.stream;
}

Future<void> smbCloseFile(
    SmbFile file, SmbTree tree, Uint8List? fileId, int fid) async {
  if (tree.transport.isSMB2()) {
    Smb2CloseRequest closeReq =
        Smb2CloseRequest(tree.config, fileId: fileId, fileName: file.uncPath);
    closeReq.setCloseFlags(Smb2CloseResponse.SMB2_CLOSE_FLAG_POSTQUERY_ATTRIB);
    tree.prepare(closeReq);
    await tree.transport.sendrecv(closeReq, params: {RequestParam.NO_RETRY});
  } else {
    var lastWriteTime = 0;
    var closeReq = SmbComClose(tree.config, fid, lastWriteTime);
    var closeResp = SmbComBlankResponse(tree.config);
    tree.prepare(closeReq);
    await tree.transport.sendrecv(closeReq,
        response: closeResp, params: {RequestParam.NO_RETRY});
  }
}

Future<int> smbReadFromFile(SmbFile file, SmbTree tree, Uint8List? fileId,
    int fid, Uint8List b, int position, int off, int len,
    {bool largeReadX = false}) async {
  int fp = position;
  int start = fp;
  int type = SmbConstants.TYPE_FILESYSTEM; //file.getType();

  SmbComReadAndXResponse response = SmbComReadAndXResponse(tree.config, b, off);
  int r, n;
  int blockSize = 64936;
  // (type == SmbConstants.TYPE_FILESYSTEM) ? readSizeFile : readSize;
  do {
    r = len > blockSize ? blockSize : len;

    // try {
    if (tree.transport.isSMB2()) {
      Smb2ReadRequest request = Smb2ReadRequest(
        tree.config,
        fileId!,
        b,
        off,
        readLength: r,
        offset: type == SmbConstants.TYPE_NAMED_PIPE ? 0 : fp,
        remainingBytes: len - r,
      );
      // request.setOffset(type == SmbConstants.TYPE_NAMED_PIPE ? 0 : fp);
      // request.setReadLength(r);
      // request.setRemainingBytes(len - r);

      // try {
      tree.prepare(request);
      Smb2ReadResponse resp = await tree.transport
          .sendrecv(request, params: {RequestParam.NO_RETRY});
      n = resp.dataLength;
      // } catch (e) {
      //   //SmbException
      //   if (e.getNtStatus() == 0xC0000011) {
      //     // log.debug("Reached end of file", e);
      //     n = -1;
      //   } else {
      //     throw e;
      //   }
      // }
      if (n <= 0) {
        return ((fp - start) > 0 ? fp - start : -1);
      }
      fp += n;
      off += n;
      len -= n;
      continue;
    }

    SmbComReadAndX request =
        SmbComReadAndX(tree.config, fid, fp, r, andx: null);
    if (type == SmbConstants.TYPE_NAMED_PIPE) {
      request.minCount = 1024;
      request.maxCount = 1024;
      request.remaining = 1024;
    } else if (largeReadX) {
      request.maxCount = r & 0xFFFF;
      request.setOpenTimeout((r >> 16) & 0xFFFF);
    }
    tree.prepare(request);
    response = await tree.transport
        .sendrecv(request, response: response, params: {RequestParam.NO_RETRY});
    // th.send(request, response: response, params: {RequestParam.NO_RETRY});
    n = response.getDataLength();
    // } catch (se) {
    //   //SmbException
    //   if (type == SmbConstants.TYPE_NAMED_PIPE &&
    //       se.getNtStatus() == NtStatus.NT_STATUS_PIPE_BROKEN) {
    //     return -1;
    //   }
    //   throw seToIoe(se);
    // }
    if (n <= 0) {
      return ((fp - start) > 0 ? fp - start : -1);
    }
    fp += n;
    len -= n;
    response.adjustOffset(n);
  } while (len > blockSize && n == r);
  // this used to be len > 0, but this is BS:
  // - InputStream.read gives no such guarantee
  // - otherwise the caller would need to figure out the block size, or otherwise might end up with very small
  // reads
  return (fp - start);
}
