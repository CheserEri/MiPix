import 'dart:io';
import 'dart:typed_data';

import 'package:smb_connect/src/utils/socket/socket_writer.dart';
import 'package:test/test.dart';

/// 回归测试：`SocketWriter.write` 必须**同步**抛出 socket 关闭错误。
///
/// 若它被声明为 `async`（历史实现），异常会挂到一个无人 await 的 Future 上，
/// 最终以 `Unhandled Exception: Bad state: StreamSink is closed` 逃逸到顶层，
/// `SmbTransport.sendrecv` 与业务层都无法感知，批量备份因此空转不收敛。
void main() {
  late ServerSocket server;
  late Socket client;

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    client = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
  });

  tearDown(() async {
    client.destroy();
    await server.close();
  });

  test('正常写入并 flush 不抛错', () async {
    final writer = SocketWriter(client);
    writer.write(Uint8List.fromList([1, 2, 3]), 0, 3);
    await writer.flush();
    expect(writer.lastWrite, 0);
  });

  test('socket 关闭后写入：同步抛出 StateError，而不是被 async 吞掉', () async {
    final writer = SocketWriter(client);
    writer.write(Uint8List.fromList([1]), 0, 1);
    await writer.flush();
    await client.close();

    expect(
      () => writer.write(Uint8List.fromList([2]), 0, 1),
      throwsA(isA<StateError>()),
    );
  });
}
