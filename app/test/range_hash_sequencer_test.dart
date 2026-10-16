import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mipix_app/services/range_hash_sequencer.dart';

/// 生成可复现的「文件字节」，避免依赖随机数。
Uint8List _payload(int len) {
  final b = Uint8List(len);
  for (var i = 0; i < len; i++) {
    b[i] = (i * 31 + 7) & 0xff;
  }
  return b;
}

void main() {
  group('planRanges', () {
    test('覆盖 [0,total) 且连续、无洞、无重叠，末段吃余数', () {
      const total = 1000;
      const rangeBytes = 300;
      final ranges = planRanges(total: total, rangeBytes: rangeBytes);

      expect(ranges, isNotEmpty);
      expect(ranges.first.start, 0);
      expect(ranges.last.end, total);

      var cursor = 0;
      for (final r in ranges) {
        // 每段的起点必须紧接上一段的终点：既无洞也无重叠。
        expect(r.start, cursor);
        expect(r.end, greaterThan(r.start));
        cursor = r.end;
      }
      expect(cursor, total);
      expect(ranges.last.length, total - rangeBytes * 3);
    });

    test('rangeBytes 大于 total 时只有一段', () {
      final ranges = planRanges(total: 10, rangeBytes: 4096);
      expect(ranges.length, 1);
      expect(ranges.single.start, 0);
      expect(ranges.single.end, 10);
    });

    test('total <= 0 返回空', () {
      expect(planRanges(total: 0, rangeBytes: 10), isEmpty);
      expect(planRanges(total: -5, rangeBytes: 10), isEmpty);
    });

    test('rangeBytes 非正数抛错', () {
      expect(() => planRanges(total: 10, rangeBytes: 0), throwsArgumentError);
      expect(() => planRanges(total: 10, rangeBytes: -1), throwsArgumentError);
    });
  });

  group('RangeHashSequencer', () {
    test('顺序喂入后拼接字节与摘要等于原文件', () {
      final data = _payload(5000);
      final out = BytesBuilder(copy: false);
      final seq = RangeHashSequencer(
        totalBytes: data.length,
        onOrdered: out.add,
      );

      for (final r in planRanges(total: data.length, rangeBytes: 1000)) {
        seq.accept(r.start, Uint8List.sublistView(data, r.start, r.end));
      }

      expect(seq.aborted, isFalse);
      expect(seq.isComplete, isTrue);
      expect(seq.bytesConsumed, data.length);
      expect(out.toBytes(), data);
      expect(
        sha256.convert(out.toBytes()).toString(),
        sha256.convert(data).toString(),
      );
    });

    test('窗口内乱序喂入后，emit 仍严格按偏移升序', () {
      final data = _payload(5000);
      final out = BytesBuilder(copy: false);
      final emitted = <int>[];
      final seq = RangeHashSequencer(
        totalBytes: data.length,
        onOrdered: (chunk) {
          emitted.add(chunk.length);
          out.add(chunk);
        },
      );

      // 故意整体倒序喂入：所有后序区间先到，进入有界缓冲等待前序补齐。
      final ranges = planRanges(total: data.length, rangeBytes: 1000);
      for (final r in ranges.reversed) {
        seq.accept(r.start, Uint8List.sublistView(data, r.start, r.end));
      }

      expect(seq.isComplete, isTrue);
      expect(seq.bufferedBytes, 0);
      expect(out.toBytes(), data);
      expect(
        sha256.convert(out.toBytes()).toString(),
        sha256.convert(data).toString(),
      );
    });

    test('复用同一块读缓冲（上层 SMB 流语义）时缓冲内容不被覆写', () {
      final data = _payload(3000);
      const block = 1000;
      final out = BytesBuilder(copy: false);
      final seq = RangeHashSequencer(totalBytes: data.length, onOrdered: out.add);

      // 模拟 smbOpenRead：整条流的每个整块都借用同一个 Uint8List，写满即 yield。
      // 倒序喂入时后序块会进入有界缓冲；若按引用缓存，后续写入会把已缓冲内容覆写。
      final shared = Uint8List(block);
      for (var off = data.length - block; off >= 0; off -= block) {
        shared.setRange(0, block, data, off);
        seq.accept(off, shared);
      }

      expect(seq.aborted, isFalse);
      expect(seq.isComplete, isTrue);
      expect(out.toBytes(), data);
    });

    test('offset < expected（重复 / 重叠）即 fatal 并中止', () {
      final data = _payload(4000);
      final seq = RangeHashSequencer(totalBytes: data.length, onOrdered: (_) {});
      seq.accept(0, Uint8List.sublistView(data, 0, 1000));

      expect(
        () => seq.accept(500, Uint8List.sublistView(data, 500, 1500)),
        throwsStateError,
      );
      expect(seq.aborted, isTrue);
      expect(seq.bytesConsumed, 1000);
      expect(seq.isComplete, isFalse);
    });

    test('越界（落在 [0,total) 之外）即 fatal', () {
      final data = _payload(1000);
      final seq = RangeHashSequencer(totalBytes: data.length, onOrdered: (_) {});
      expect(() => seq.accept(900, Uint8List(200)), throwsStateError);
      expect(seq.aborted, isTrue);
    });

    test('偏移领先超过 maxOffsetLead 即 fatal（内存有界）', () {
      final data = _payload(10000);
      final seq = RangeHashSequencer(
        totalBytes: data.length,
        onOrdered: (_) {},
        maxOffsetLead: 1000,
      );
      expect(
        () => seq.accept(2000, Uint8List.sublistView(data, 2000, 3000)),
        throwsStateError,
      );
      expect(seq.aborted, isTrue);
    });

    test('缓冲字节超过 maxBufferedBytes 即 fatal（内存有界）', () {
      final data = _payload(10000);
      final seq = RangeHashSequencer(
        totalBytes: data.length,
        onOrdered: (_) {},
        maxBufferedBytes: 500,
      );
      // 领先仍在窗口内（默认 maxOffsetLead 足够大），但缓冲字节超硬界。
      expect(
        () => seq.accept(1000, Uint8List.sublistView(data, 1000, 2000)),
        throwsStateError,
      );
      expect(seq.aborted, isTrue);
    });

    test('短读（少喂一段）导致 isComplete == false，不得 rename', () {
      final data = _payload(4000);
      final out = BytesBuilder(copy: false);
      final seq = RangeHashSequencer(totalBytes: data.length, onOrdered: out.add);
      seq.accept(0, Uint8List.sublistView(data, 0, 1000));
      // 第二段只读到一半（模拟 SMB 短读）。
      seq.accept(1000, Uint8List.sublistView(data, 1000, 2000));

      expect(seq.isComplete, isFalse);
      expect(seq.bytesConsumed, lessThan(data.length));
    });

    test('abort 后拒绝后续块且 bytesConsumed < total', () {
      final data = _payload(4000);
      final seq = RangeHashSequencer(totalBytes: data.length, onOrdered: (_) {});
      seq.accept(0, Uint8List.sublistView(data, 0, 1000));
      seq.abort();

      expect(seq.aborted, isTrue);
      expect(seq.isComplete, isFalse);
      expect(seq.bytesConsumed, lessThan(data.length));
      expect(
        () => seq.accept(1000, Uint8List.sublistView(data, 1000, 2000)),
        throwsStateError,
      );
    });
  });

  group('RangeScheduler', () {
    test('按偏移升序派发且并发受上限约束', () {
      final ranges = planRanges(total: 1000, rangeBytes: 100);
      final scheduler = RangeScheduler(ranges: ranges, concurrency: 3);

      final first = <HashRange>[
        scheduler.take()!,
        scheduler.take()!,
        scheduler.take()!,
      ];
      expect(first.map((r) => r.start).toList(), [0, 100, 200]);
      expect(scheduler.inFlight, 3);
      // 已达并发上限：不再派发。
      expect(scheduler.take(), isNull);

      scheduler.finish(first[0]);
      expect(scheduler.take()!.start, 300);
    });

    test('全部派发并结束后 hasWork == false', () {
      final ranges = planRanges(total: 200, rangeBytes: 100);
      final scheduler = RangeScheduler(ranges: ranges, concurrency: 2);
      while (true) {
        final r = scheduler.take();
        if (r == null) break;
        scheduler.finish(r);
      }
      expect(scheduler.hasWork, isFalse);
      expect(scheduler.inFlight, 0);
    });
  });
}
