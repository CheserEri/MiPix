import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mipix_app/services/keep_alive_service.dart';

/// 回归测试：保活锁必须按「持有者计数」申请/释放。
///
/// 真机曾实测到：用户连点「全部备份」产生多个重叠批次时，先结束的那批会把
/// 原生锁释放掉，仍在跑的那批随后 2.5 分钟上传全程无锁——正是这里要防住的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('mipix/keepalive');
  late List<String> calls;

  setUp(() {
    calls = <String>[];
    KeepAliveService.debugForcePlatform = true;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() async {
    // 把计数清空，避免用例之间互相影响。
    while (KeepAliveService.isHeld) {
      await KeepAliveService.release();
    }
    KeepAliveService.debugForcePlatform = false;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('单批次：申请一次、释放一次', () async {
    await KeepAliveService.acquire();
    expect(KeepAliveService.isHeld, isTrue);
    await KeepAliveService.release();
    expect(KeepAliveService.isHeld, isFalse);
    expect(calls, ['acquire', 'release']);
  });

  test('批次重叠：先结束的批次不得释放他人仍在使用的锁', () async {
    await KeepAliveService.acquire(); // 批次 A
    await KeepAliveService.acquire(); // 批次 B 重叠，不应重复申请
    expect(calls, ['acquire']);

    await KeepAliveService.release(); // A 结束
    expect(KeepAliveService.isHeld, isTrue);
    expect(calls, ['acquire'], reason: 'A 结束时 B 还在跑，锁必须保持');

    await KeepAliveService.release(); // B 结束
    expect(KeepAliveService.isHeld, isFalse);
    expect(calls, ['acquire', 'release']);
  });

  test('多余的 release 不应把锁提前放掉', () async {
    await KeepAliveService.acquire();
    await KeepAliveService.release();
    await KeepAliveService.release(); // 多余的释放
    await KeepAliveService.release();
    expect(calls, ['acquire', 'release']);
  });
}
