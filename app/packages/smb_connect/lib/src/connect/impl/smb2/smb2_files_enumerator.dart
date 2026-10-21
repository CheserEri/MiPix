import 'dart:async';
import 'dart:typed_data';

import 'package:smb_connect/src/exceptions.dart';
import 'package:smb_connect/src/connect/smb_file_stream.dart';
import 'package:smb_connect/src/connect/smb_files_enumerator.dart';
import 'package:smb_connect/src/connect/impl/smb2/create/smb2_create_request.dart';
import 'package:smb_connect/src/connect/impl/smb2/create/smb2_create_response.dart';
import 'package:smb_connect/src/connect/impl/smb2/info/smb2_query_directory_request.dart';
import 'package:smb_connect/src/connect/impl/smb2/info/smb2_query_directory_response.dart';
import 'package:smb_connect/src/connect/impl/smb2/smb2_constants.dart';
import 'package:smb_connect/src/smb/file_entry.dart';
import 'package:smb_connect/src/smb/nt_status.dart';
import 'package:smb_connect/src/smb_constants.dart';

class Smb2FilesEnumerator extends SmbFilesEnumerator {
  int _num = 0;
  Uint8List? _fileId;
  bool _canMore = true;

  Smb2FilesEnumerator(
    super.tree,
    super.transport,
    super.folder,
    super.wildcard,
    super.searchAttributes,
  );

  @override
  bool canNext() => _canMore;

  @override
  Future<void> close() async {
    await smbCloseFile(folder, tree, _fileId, 0);
  }

  Future<List<FileEntry>?> _first() async {
    final createReq = Smb2CreateRequest(transport.config, folder.uncPath);
    createReq.setCreateOptions(Smb2Constants.FILE_DIRECTORY_FILE);
    createReq.setDesiredAccess(
        SmbConstants.FILE_READ_DATA | SmbConstants.FILE_READ_ATTRIBUTES);

    final queryReq = Smb2QueryDirectoryRequest(transport.config);
    queryReq.setFileName(wildcard);
    // 首次查询必须从头开始枚举，否则服务端会沿用目录句柄上遗留的游标。
    queryReq.setQueryFlags(Smb2QueryDirectoryRequest.SMB2_RESTART_SCANS);
    createReq.chain(queryReq);

    tree.prepare(createReq);
    final Smb2CreateResponse createResp =
        await tree.transport.sendrecv(createReq);

    if (createResp.status != NtStatus.NT_STATUS_OK) {
      throw SmbException.getMessageByCode(createResp.status);
    }
    _fileId = createResp.fileId;
    final qr = queryReq.getResponse();
    final status = qr?.getStatus();
    if (status != null &&
        status != NtStatus.NT_STATUS_OK &&
        status != NtStatus.NT_STATUS_NO_MORE_FILES) {
      throw SmbException.getMessageByCode(status);
    }
    return qr?.getResults();
  }

  Future<List<FileEntry>?> _more() async {
    Smb2QueryDirectoryRequest queryReq =
        Smb2QueryDirectoryRequest(transport.config, fileId: _fileId);
    queryReq.setFileName(wildcard);
    // 不设置 SMB2_INDEX_SPECIFIED / SMB2_RESTART_SCANS：SMB2 的枚举游标
    // 挂在目录句柄上，后续查询不带 flag 即从上次位置继续。
    // 旧实现依赖服务端回传的 FileIndex 续传，但大量 NAS（实测 Samba）
    // 返回的 FileIndex 恒为 0；目录同时被写入时，服务端会提前回
    // NO_MORE_FILES，客户端只拿到第一批条目就结束枚举——表现为大相册
    // 「张数对得上但列表只显示到某一天」。
    tree.prepare(queryReq);
    Smb2QueryDirectoryResponse queryResp =
        await tree.transport.sendrecv(queryReq);

    final status = queryResp.getStatus();
    // NO_MORE_FILES 才是正常结束；其余错误必须抛出，交给上层重试整轮扫描，
    // 不能静默当成「目录到底了」，否则会把半截列表写进缓存。
    if (status != NtStatus.NT_STATUS_OK &&
        status != NtStatus.NT_STATUS_NO_MORE_FILES) {
      throw SmbException.getMessageByCode(status);
    }
    return queryResp.getResults();
  }

  @override
  Future<List<FileEntry>?> next() async {
    final prevNum = _num;
    _num++;
    final List<FileEntry>? res;
    if (prevNum == 0) {
      res = await _first();
    } else {
      res = await _more();
    }
    _canMore = res?.isNotEmpty == true;
    return res;
  }
}
