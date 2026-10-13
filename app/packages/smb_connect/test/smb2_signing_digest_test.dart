import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block.dart';
import 'package:smb_connect/src/connect/impl/smb2/smb2_constants.dart';
import 'package:smb_connect/src/connect/impl/smb2/smb2_signing_digest.dart';
import 'package:smb_connect/src/connect/smb_util.dart';
import 'package:test/test.dart';

/// 与实现无关的测试替身：`verify` 不读取 [CommonServerMessageBlock] 的参数。
class _FakeMessage implements CommonServerMessageBlock {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const int _dialect0210 = Smb2Constants.SMB2_DIALECT_0210;

/// 造一条确定性的报文：偏移 16 起 4 字节是 flags，偏移 48 起 16 字节是签名域。
Uint8List _newMessage(int size, {int seed = 7}) {
  final buf = Uint8List(size);
  var x = seed;
  for (var i = 0; i < size; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    buf[i] = x >> 16;
  }
  return buf;
}

/// 按 SMB2 规范准备待签数据（签名域清零 + 置 SIGNED 标志），
/// 独立于实现手写，用于交叉验证。
void _applySpecPrep(Uint8List buf, int offset) {
  for (var i = 0; i < Smb2SigningDigest.SIGNATURE_LENGTH; i++) {
    buf[offset + Smb2SigningDigest.SIGNATURE_OFFSET + i] = 0;
  }
  final flags = SMBUtil.readInt4(buf, offset + 16);
  SMBUtil.writeInt4(
      flags | Smb2Constants.SMB2_FLAGS_SIGNED, buf, offset + 16);
}

/// 独立实现（pointycastle）算出的 HMAC-SHA256，取前 16 字节。
Uint8List _refHmacSha256(Uint8List key, Uint8List buf, int offset, int length) {
  final mac = Mac('SHA-256/HMAC')..init(KeyParameter(key));
  mac.update(buf, offset, length);
  final out = Uint8List(32);
  mac.doFinal(out, 0);
  return Uint8List.sublistView(out, 0, Smb2SigningDigest.SIGNATURE_LENGTH);
}

/// 取出报文里写入的签名字节。
Uint8List _sigOf(Uint8List signed, int offset) => Uint8List.sublistView(
      signed,
      offset + Smb2SigningDigest.SIGNATURE_OFFSET,
      offset +
          Smb2SigningDigest.SIGNATURE_OFFSET +
          Smb2SigningDigest.SIGNATURE_LENGTH,
    );

void main() {
  final key = Uint8List.fromList(List<int>.generate(16, (i) => 0xA0 + i));

  test('SMB 2.1 签名字节与 pointycastle 的 HMAC-SHA256 完全一致', () {
    final digest = Smb2SigningDigest(key, _dialect0210, null);

    final signed = _newMessage(1024);
    digest.sign(signed, 0, signed.length, null, null);

    final expected = _newMessage(1024);
    _applySpecPrep(expected, 0);

    expect(_sigOf(signed, 0), _refHmacSha256(key, expected, 0, expected.length));
  });

  test('非零偏移：只对 [offset, offset + length) 计算签名', () {
    final digest = Smb2SigningDigest(key, _dialect0210, null);

    const prefix = 512;
    const size = 1024;
    final total = prefix + size + 512;
    final pristine = _newMessage(total, seed: 11);

    final signed = _newMessage(total, seed: 11);
    digest.sign(signed, prefix, size, null, null);

    final expected = _newMessage(total, seed: 11);
    _applySpecPrep(expected, prefix);

    expect(_sigOf(signed, prefix), _refHmacSha256(key, expected, prefix, size));
    // 签名范围之外（前缀与后缀）必须原样不动。
    expect(Uint8List.sublistView(signed, 0, prefix),
        Uint8List.sublistView(pristine, 0, prefix));
    expect(Uint8List.sublistView(signed, prefix + size),
        Uint8List.sublistView(pristine, prefix + size));
  });

  test('同一实例重复签名结果稳定', () {
    final digest = Smb2SigningDigest(key, _dialect0210, null);

    final first = _newMessage(1024);
    digest.sign(first, 0, first.length, null, null);
    final second = _newMessage(1024);
    digest.sign(second, 0, second.length, null, null);

    expect(_sigOf(first, 0), _sigOf(second, 0));
  });

  test('正文被改动后签名随之改变', () {
    final digest = Smb2SigningDigest(key, _dialect0210, null);
    const bodyByte = 128; // 落在正文里，既非 flags 也非签名域

    final original = _newMessage(1024);
    digest.sign(original, 0, original.length, null, null);

    final modified = _newMessage(1024);
    modified[bodyByte] ^= 0xFF;
    digest.sign(modified, 0, modified.length, null, null);

    expect(_sigOf(modified, 0), isNot(_sigOf(original, 0)));
  });

  test('验签：完好报文通过，被篡改报文失败', () {
    final digest = Smb2SigningDigest(key, _dialect0210, null);
    final msg = _FakeMessage();

    // verify() 的约定：返回 false 表示校验通过，true 表示校验失败
    // （调用方 server_message_block2_response 里为 `verifyFailed = verify`）。
    final good = _newMessage(1024);
    digest.sign(good, 0, good.length, null, null);
    expect(digest.verify(good, 0, good.length, 0, msg), isFalse);

    final tampered = _newMessage(1024);
    digest.sign(tampered, 0, tampered.length, null, null);
    tampered[128] ^= 0xFF;
    expect(digest.verify(tampered, 0, tampered.length, 0, msg), isTrue);
  });

  test('SMB 3.0 仍走 AES-CMAC，不因 HMAC 改造回归', () {
    final hmac = Smb2SigningDigest(key, _dialect0210, null);
    final cmac =
        Smb2SigningDigest(key, Smb2Constants.SMB2_DIALECT_0300, Uint8List(0));

    final hmacSigned = _newMessage(1024);
    hmac.sign(hmacSigned, 0, hmacSigned.length, null, null);

    final cmacSigned = _newMessage(1024);
    cmac.sign(cmacSigned, 0, cmacSigned.length, null, null);

    expect(_sigOf(cmacSigned, 0).length, Smb2SigningDigest.SIGNATURE_LENGTH);
    // 方言分支若被错误地都路由到 HMAC-SHA256，两者就会相同。
    expect(_sigOf(cmacSigned, 0), isNot(_sigOf(hmacSigned, 0)));

    final cmacAgain = _newMessage(1024);
    cmac.sign(cmacAgain, 0, cmacAgain.length, null, null);
    expect(_sigOf(cmacAgain, 0), _sigOf(cmacSigned, 0));
  });
}
