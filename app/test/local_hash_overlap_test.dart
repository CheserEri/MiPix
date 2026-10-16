import 'package:flutter_test/flutter_test.dart';
import 'package:mipix_app/services/smb_service.dart';

/// P2 回读校验判定 [decideVerify] 的各分支：只有「四个条件全部确定且相符」
/// 才允许 rename，任一「不知道 / 不等 / 不稳定」都必须 fail-closed。
void main() {
  const localHash = 'aaaa';
  const remoteHash = 'aaaa';

  VerifyOutcome judge({
    String? local = localHash,
    String? remote = remoteHash,
    int remoteSize = 100,
    int expectedSize = 100,
    bool sourceStable = true,
  }) {
    return decideVerify(
      localHash: local,
      remoteHash: remote,
      remoteSize: remoteSize,
      expectedSize: expectedSize,
      sourceStable: sourceStable,
    );
  }

  test('摘要一致 + 长度相符 + 来源稳定 → rename', () {
    expect(judge(), VerifyOutcome.rename);
  });

  test('远端摘要为 null（回读失败 / 长度不符）→ deleteAndFail', () {
    expect(judge(remote: null), VerifyOutcome.deleteAndFail);
  });

  test('本地摘要为 null（预取未能确认内容）→ deleteAndFail', () {
    expect(judge(local: null), VerifyOutcome.deleteAndFail);
  });

  test('两摘要不符 → deleteAndFail', () {
    expect(judge(remote: 'bbbb'), VerifyOutcome.deleteAndFail);
  });

  test('远端 size 与来源不符 → deleteAndFail', () {
    expect(judge(remoteSize: 99), VerifyOutcome.deleteAndFail);
    // 远端不存在（stat 失败 / 已被删除）以 -1 表示。
    expect(judge(remoteSize: -1), VerifyOutcome.deleteAndFail);
  });

  test('来源不稳定（size / modified 变化）→ deleteAndFail', () {
    expect(judge(sourceStable: false), VerifyOutcome.deleteAndFail);
  });

  test('来源不稳定优先于摘要一致：仍不 rename', () {
    expect(
      judge(sourceStable: false, remoteSize: 100),
      VerifyOutcome.deleteAndFail,
    );
  });
}
