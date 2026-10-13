import 'dart:convert' show ByteConversionSink;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart';
import 'package:smb_connect/src/exceptions.dart';
import 'package:smb_connect/src/connect/impl/smb2/smb2_constants.dart';
import 'package:smb_connect/src/connect/smb_util.dart';
import 'package:smb_connect/src/utils/extensions.dart';

import '../../common/common_server_message_block.dart';
import '../../common/smb_signing_digest.dart';
import 'smb3_key_derivation.dart';

/// 摘要算法的统一抽象，屏蔽 pointycastle `Mac` 与 `package:crypto` 的 API 差异。
abstract class _MacLike {
  int get macSize;
  void reset();
  void update(Uint8List data, int offset, int length);
  void doFinal(Uint8List out, int outOff);
}

/// 包装 pointycastle 的 [Mac]（SMB3 的 AES/CMAC 仍走这里）。
class _PointyMac implements _MacLike {
  _PointyMac(this._m);

  final Mac _m;

  @override
  int get macSize => _m.macSize;

  @override
  void reset() => _m.reset();

  @override
  void update(Uint8List data, int offset, int length) =>
      _m.update(data, offset, length);

  @override
  void doFinal(Uint8List out, int outOff) => _m.doFinal(out, outOff);
}

/// 基于 `package:crypto` 的 HMAC-SHA256。
///
/// 替换 pointycastle 的原因：pointycastle 的 SHA-256 把 8 字状态与消息缓冲
/// 存成装箱 `List<int>`，每个 32 位运算都过 `clip32`/`rotr32` 包装，且输入按
/// 4 字节逐字解包，导致 64 KiB 报文签名耗时约 9.1–9.8 ms（≈6.8 MB/s），成为
/// 备份吞吐的瓶颈。`package:crypto` 的 SHA-256 全程使用 `Uint32List`，同样
/// 输入下快约一个数量级。
class _CryptoHmac implements _MacLike {
  _CryptoHmac(this._hmac) {
    _restart();
  }

  final c.Hmac _hmac;

  /// `package:crypto` 的 `DigestSink` 未对外导出，这里用等价的极小收集器。
  late _DigestCollector _collector;
  late ByteConversionSink _sink;

  /// 开一轮新的摘要计算。[crypto] 的 `Hmac.convert` 内部就是
  /// `startChunkedConversion` + `add` + `close`，因此这里改用流式 sink
  /// 不会改变热路径的开销，却天然支持分段追加输入。
  void _restart() {
    _collector = _DigestCollector();
    _sink = _hmac.startChunkedConversion(_collector);
  }

  /// HMAC-SHA256 输出恒为 32 字节（调用方按 [Smb2SigningDigest.SIGNATURE_LENGTH]
  /// 取前 16 字节）。
  @override
  int get macSize => 32;

  @override
  void reset() => _restart();

  @override
  void update(Uint8List data, int offset, int length) {
    if (length == 0) return;
    // 零拷贝：把 `[offset, offset+length)` 的视图交给 crypto，不复制数据。
    // 因为是流式 sink，同一报文分成多段依次传入也会被正确累加，
    // 不再有「只记住最后一次 update」的隐式约束。
    _sink.add(Uint8List.view(data.buffer, data.offsetInBytes + offset, length));
  }

  @override
  void doFinal(Uint8List out, int outOff) {
    try {
      _sink.close();
      out.setRange(outOff, outOff + 32, _collector.value!.bytes);
    } finally {
      // 算完立即重建内部状态：不再把报文缓冲区的引用或中间状态留到下一次签名。
      _restart();
    }
  }
}

/// 收集 HMAC 结果的极小 sink。
class _DigestCollector implements Sink<c.Digest> {
  c.Digest? value;

  @override
  void add(c.Digest data) => value = data;

  @override
  void close() {}
}

class Smb2SigningDigest implements SMBSigningDigest {
  static const int SIGNATURE_OFFSET = 48;
  static const int SIGNATURE_LENGTH = 16;

  late final _MacLike _digest;

  Smb2SigningDigest(
      Uint8List sessionKey, int dialect, Uint8List? preauthIntegrityHash) {
    _MacLike m;
    Uint8List signingKey;
    switch (dialect) {
      case Smb2Constants.SMB2_DIALECT_0202:
      case Smb2Constants.SMB2_DIALECT_0210:
        // 改用 package:crypto 的 HMAC-SHA256：pointycastle 的同名实现把
        // 状态与消息缓冲存成装箱 List<int>，64 KiB 报文签名约 9~11ms，
        // 是备份吞吐的瓶颈；crypto 实现全程 Uint32List，快约一个数量级。
        m = _CryptoHmac(c.Hmac(c.sha256, sessionKey));
        signingKey = sessionKey;
        break;
      case Smb2Constants.SMB2_DIALECT_0300:
      case Smb2Constants.SMB2_DIALECT_0302:
        signingKey = Smb3KeyDerivation.deriveSigningKey(
            dialect, sessionKey, Uint8List(0) /* unimplemented */);
        m = _PointyMac(Mac("AES/CMAC")..init(KeyParameter(signingKey)));
        break;
      case Smb2Constants.SMB2_DIALECT_0311:
        if (preauthIntegrityHash == null) {
          throw SmbIllegalArgumentException(
              "Missing preauthIntegrityHash for SMB 3.1");
        }
        signingKey = Smb3KeyDerivation.deriveSigningKey(
            dialect, sessionKey, preauthIntegrityHash);
        m = _PointyMac(Mac("AES/CMAC")..init(KeyParameter(signingKey)));
        break;
      default:
        throw SmbIllegalArgumentException("Unknown dialect");
    }
    _digest = m;
  }

  /// 按 SMB2 规范对待签缓冲区做一次签名（清签名域 → 置 SIGNED 标志 →
  /// 计算 MAC → 写入前 16 字节）。所有方言共用同一套流程。
  static void _signWith(
      _MacLike mac, Uint8List data, int offset, int length) {
    mac.reset();

    // zero out signature field
    final int index = offset + SIGNATURE_OFFSET;
    for (int i = 0; i < SIGNATURE_LENGTH; i++) {
      data[index + i] = 0;
    }

    // set signed flag
    int oldFlags = SMBUtil.readInt4(data, offset + 16);
    SMBUtil.writeInt4(oldFlags | Smb2Constants.SMB2_FLAGS_SIGNED, data, offset + 16);

    mac.update(data, offset, length);

    Uint8List sig = Uint8List(mac.macSize);
    mac.doFinal(sig, 0);
    byteArrayCopy(
        src: sig,
        srcOffset: 0,
        dst: data,
        dstOffset: index,
        length: SIGNATURE_LENGTH);
  }

  @override
  void sign(Uint8List data, int offset, int length,
      CommonServerMessageBlock? request, CommonServerMessageBlock? response) {
    _signWith(_digest, data, offset, length);
  }

  @override
  bool verify(Uint8List data, int offset, int length, int extraPad,
      CommonServerMessageBlock msg) {
    _digest.reset();

    int flags = SMBUtil.readInt4(data, offset + 16);
    if ((flags & Smb2Constants.SMB2_FLAGS_SIGNED) == 0) {
      // log.error("The server did not sign a message we expected to be signed");
      return true;
    }

    Uint8List sig = Uint8List(SIGNATURE_LENGTH);
    byteArrayCopy(
        src: data,
        srcOffset: offset + SIGNATURE_OFFSET,
        dst: sig,
        dstOffset: 0,
        length: SIGNATURE_LENGTH);

    int index = offset + SIGNATURE_OFFSET;
    for (int i = 0; i < SIGNATURE_LENGTH; i++) {
      data[index + i] = 0;
    }

    _digest.update(data, offset, length);

    Uint8List cmp = Uint8List(SIGNATURE_LENGTH);
    Uint8List sig2 = Uint8List(_digest.macSize);
    _digest.doFinal(sig2, 0);
    byteArrayCopy(
        src: sig2,
        srcOffset: 0,
        dst: cmp,
        dstOffset: 0,
        length: SIGNATURE_LENGTH);
    if (!isEqualMessageDigest(sig, cmp)) {
      return true;
    }
    return false;
  }
}