import 'dart:collection';
import 'dart:typed_data';

/// 一段连续的回读区间 `[start, end)`。
class HashRange {
  final int start;
  final int end;

  const HashRange(this.start, this.end);

  int get length => end - start;

  @override
  String toString() => '[$start,$end)';
}

/// 把 `[0, total)` 切成连续、无洞、无重叠的区间，末段吃掉余数。
///
/// 区间粒度 [rangeBytes] 取底层读块（`smbReadBlockSize` ≈ 64 KiB）的整数倍，
/// 区间内仍按底层小块读，只是不再每个小块都重开一次远端文件句柄；具体取值
/// 属于待测参数（句柄开销量随粒度变化），不做既定假设。
List<HashRange> planRanges({required int total, required int rangeBytes}) {
  if (total <= 0) return const [];
  if (rangeBytes <= 0) {
    throw ArgumentError.value(rangeBytes, 'rangeBytes', '区间粒度必须为正数');
  }
  final ranges = <HashRange>[];
  var start = 0;
  while (start < total) {
    final end = start + rangeBytes > total ? total : start + rangeBytes;
    ranges.add(HashRange(start, end));
    start = end;
  }
  return ranges;
}

/// 有序重排缓冲：把乱序到达的回读数据按偏移升序喂给唯一的摘要 sink。
///
/// 只按「期望偏移」判定，乱序数据绝不直接进摘要：
///  * `offset == expected`：立即 emit，并继续 drain 缓冲里紧随其后的块；
///  * `offset > expected`：进入有界 pending，等待前序补齐；
///  * `offset < expected`（重复 / 重叠）：fatal；
///  * 越界（落在 `[0, total)` 之外）：fatal。
///
/// 内存有硬界，不随文件大小增长：pending 字节数超过 [maxBufferedBytes]，
/// 或某个块的偏移领先「期望偏移」超过 [maxOffsetLead]，立即 fatal。两者都应由
/// 调用方按「最大并发数 × 区间长度」算出可计算上界后传入。
class RangeHashSequencer {
  RangeHashSequencer({
    required this.totalBytes,
    required this.onOrdered,
    this.maxBufferedBytes = 32 * 1024 * 1024,
    this.maxOffsetLead = 64 * 1024 * 1024,
  }) {
    if (totalBytes < 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', '不能为负数');
    }
  }

  /// 整份文件的总字节数。
  final int totalBytes;

  /// 按偏移升序 emit 的唯一出口；调用方在此喂入唯一的 `sha256` sink。
  final void Function(Uint8List chunk) onOrdered;

  /// 乱序缓冲的字节上界（硬界）。
  final int maxBufferedBytes;

  /// 单个块允许领先「期望偏移」的最大字节数（硬界）。
  final int maxOffsetLead;

  int _expected = 0;
  int _buffered = 0;
  bool _aborted = false;

  /// 期望偏移 → 已到达但尚未按序 emit 的数据（按键升序）。
  final SplayTreeMap<int, Uint8List> _pending = SplayTreeMap<int, Uint8List>();

  /// 已按序 emit 的字节数（单调不减）。
  int get bytesConsumed => _expected;

  /// 已到达但尚未 emit 的缓冲字节数。
  int get bufferedBytes => _buffered;

  /// 是否已收齐整份文件（不多不少）。
  bool get isComplete => _expected == totalBytes;

  /// 是否已中止；收齐前中止即表示「不得 rename」。
  bool get aborted => _aborted;

  /// 接受一段定位在 [offset]、长度为 `data.length` 的数据。
  ///
  /// 时序 / 边界异常一律 fatal：先置 [aborted]，再抛 [StateError]；调用方据此
  /// 收敛为「校验失败、清掉临时文件、绝不 rename」。
  ///
  /// **调用方可复用传入的缓冲区**：立即 emit 的数据由 [onOrdered] 同步消费、不留存；
  /// 需要延后使用的数据会被复制后再缓冲，因此上层 SMB 流复用同一块读缓冲
  /// （`smbOpenRead` 每个整块都 yield 同一个 `Uint8List`）不会污染已缓冲的内容。
  void accept(int offset, Uint8List data) {
    if (_aborted) {
      throw StateError('RangeHashSequencer 已中止，拒绝后续数据');
    }
    if (data.isEmpty) return;
    final end = offset + data.length;
    if (offset < 0 || end > totalBytes) {
      _fail('越界 offset=$offset bytes=${data.length} total=$totalBytes');
    }
    if (offset < _expected) {
      _fail('重叠/重复 offset=$offset expected=$_expected');
    }
    if (offset == _expected) {
      _emit(data);
      _drain();
      return;
    }
    // offset > _expected：乱序，进入有界缓冲。
    if (_overlapsPending(offset, end)) {
      _fail('缓冲区间重叠 offset=$offset end=$end');
    }
    if (_buffered + data.length > maxBufferedBytes) {
      _fail('重排缓冲超界 buffered=$_buffered +${data.length} > $maxBufferedBytes');
    }
    if (offset - _expected > maxOffsetLead) {
      _fail('偏移领先超窗 lead=${offset - _expected} > $maxOffsetLead');
    }
    _pending[offset] = Uint8List.fromList(data);
    _buffered += data.length;
  }

  /// 主动中止（超时 / 连接失败 / 短读等）：拒绝后续数据，[isComplete] 保持 false。
  void abort() {
    _aborted = true;
  }

  void _emit(Uint8List data) {
    _expected += data.length;
    onOrdered(data);
  }

  void _drain() {
    while (true) {
      final next = _pending.remove(_expected);
      if (next == null) break;
      _buffered -= next.length;
      _emit(next);
    }
  }

  /// [start, end) 是否与已缓冲的任一区间重叠（重叠会破坏有序重排）。
  bool _overlapsPending(int start, int end) {
    final pred = _pending.lastKeyBefore(start);
    if (pred != null && pred + _pending[pred]!.length > start) return true;
    final atOrAfter =
        _pending.containsKey(start) ? start : _pending.firstKeyAfter(start);
    return atOrAfter != null && atOrAfter < end;
  }

  Never _fail(String reason) {
    _aborted = true;
    throw StateError('RangeHashSequencer fatal: $reason');
  }
}

/// 按偏移升序派发区间、并发度受限的调度器。
///
/// 只从队首（偏移最小者）取区间，因此同一时刻在飞行的区间最多 [concurrency]
/// 个，乱序缓冲的最坏值不超过 `concurrency × 区间长度` —— 配合
/// [RangeHashSequencer] 的缓冲上界，内存有可计算上界。
class RangeScheduler {
  RangeScheduler({required List<HashRange> ranges, required this.concurrency})
      : assert(concurrency > 0),
        _queue = List<HashRange>.of(ranges);

  /// 允许同时在飞行的区间数上限。
  final int concurrency;

  final List<HashRange> _queue;
  int _inFlight = 0;

  /// 是否还有未派发或未结束的区间。
  bool get hasWork => _queue.isNotEmpty || _inFlight > 0;

  /// 正在飞行（已派发未结束）的区间数。
  int get inFlight => _inFlight;

  /// 领取下一个待派发区间（偏移升序）；已达并发上限或无剩余时返回 null。
  HashRange? take() {
    if (_inFlight >= concurrency || _queue.isEmpty) return null;
    _inFlight += 1;
    return _queue.removeAt(0);
  }

  /// 标记一个区间已结束（无论成功失败）。
  void finish(HashRange range) {
    if (_inFlight > 0) _inFlight -= 1;
  }
}
