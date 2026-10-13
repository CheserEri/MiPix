import 'dart:io';
import 'dart:typed_data';

import 'package:smb_connect/src/utils/extensions.dart';

class SocketWriter {
  final bool debugPrint;
  final Socket _socket;

  SocketWriter(this._socket, {this.debugPrint = false});

  int lastWrite = 0;

  /// 同步写入；**刻意不声明为 `async`**。
  ///
  /// socket 被关闭（对端断开或本端 close）后，`_socket.add` 会抛出
  /// `StateError: Bad state: StreamSink is closed`。若本方法声明为 `async`，
  /// 这个异常只会挂到一个无人 `await` 的 Future 上，最终以
  /// `Unhandled Exception: Bad state: StreamSink is closed` 逃逸到顶层——
  /// `SmbTransport.doSend` / `sendrecv` 与业务层全都感知不到，既无法重连，
  /// 也无法把文件判为失败，批量任务由此空转不收敛。
  ///
  /// 保持同步抛出，异常就能沿 doSend → sendrecv 正常上抛，交给调用方的
  /// 连接类错误重试/重连逻辑处理。
  void write(Uint8List buffer, int offset, int length) {
    var buf = Uint8List.view(buffer.buffer, offset, length);
    _socket.add(buf);
    lastWrite += buf.length;
    if (debugPrint) {
      print("write[$length]: ${buf.toHexString2(offset, length)}");
    }
  }

  Future<void> flush() async {
    if (debugPrint) {
      print("write flush $lastWrite");
    }
    await _socket.flush();
    lastWrite = 0;
  }
}
