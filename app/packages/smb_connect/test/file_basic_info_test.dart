import 'dart:typed_data';

import 'package:smb_connect/src/connect/fscc/file_basic_info.dart';
import 'package:smb_connect/src/connect/fscc/file_information.dart';
import 'package:smb_connect/src/connect/smb_util.dart';
import 'package:test/test.dart';

/// 2026 年附近的某个毫秒时间戳，用来验证「毫秒 ↔ FILETIME」往返。
const int _t = 1786000000000;

void main() {
  group('SMBUtil 时间编码', () {
    test('writeTime/readTime 毫秒往返一致', () {
      final buf = Uint8List(8);
      SMBUtil.writeTime(_t, buf, 0);
      expect(SMBUtil.readTime(buf, 0), _t);
    });
  });

  group('FileBasicInfo 时间回写', () {
    test('信息级别与长度为 FILE_BASIC_INFORMATION 规范值', () {
      final info = FileBasicInfo(lastWriteTime: _t);
      expect(info.getFileInformationLevel(), FileInformation.FILE_BASIC_INFO);
      expect(info.size(), 40);
    });

    test('encode 写入的字节可被 decode 还原（SET_INFO 写 → QUERY 读回）', () {
      final info = FileBasicInfo(
        createTime: _t,
        lastAccessTime: _t,
        lastWriteTime: _t,
        changeTime: _t,
        attributes: 0,
      );

      final buf = Uint8List(info.size());
      expect(info.encode(buf, 0), info.size());

      final back = FileBasicInfo();
      back.decode(buf, 0, buf.length);
      expect(back.createTime, _t);
      expect(back.lastAccessTime, _t);
      expect(back.lastWriteTime, _t);
      expect(back.changeTime, _t);
      // attributes 传 0 = 不修改文件属性，编码后仍为 0。
      expect(back.attributes, 0);
    });
  });
}
