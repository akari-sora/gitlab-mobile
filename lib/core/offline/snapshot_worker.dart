import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../gitlab_api.dart' show OfflineRequestFailure;
import 'git_object_id.dart';
import 'snapshot_schema.dart';
import 'snapshot_store.dart';
import 'tar_stream.dart';

/// A gzip member reader that checks framing and trailer itself. dart:io's
/// decoder alone accepts a truncated trailer and concatenated members.
final class StrictGzipStream {
  StrictGzipStream({
    required this.onData,
    this.maxCompressedBytes = 300 * 1024 * 1024,
  });
  final Future<void> Function(List<int>) onData;
  final int maxCompressedBytes;
  final RawZLibFilter _inflate = RawZLibFilter.inflateFilter(raw: true);
  final _DeflateBoundary _boundary = _DeflateBoundary();
  final _Crc32 _headerCrc = _Crc32();
  final _Crc32 _contentCrc = _Crc32();
  final List<int> _fixed = <int>[];
  final List<int> _trailer = <int>[];
  int _compressed = 0;
  int _expanded = 0;
  int _flags = 0;
  int _stage = 0;
  int _extraLength = 0;
  int _headerCrcRead = 0;
  int _headerCrcValue = 0;
  bool _complete = false;

  Future<void> add(List<int> bytes) async {
    if (_complete) throw const TarException(TarFailure.corruptArchive);
    _compressed += bytes.length;
    if (_compressed > maxCompressedBytes) {
      throw const TarException(TarFailure.archiveTooLarge);
    }
    var i = 0;
    while (i < bytes.length && _stage != 7) {
      final byte = bytes[i++];
      if (_stage != 6) _headerCrc.addByte(byte);
      switch (_stage) {
        case 0:
          _fixed.add(byte);
          if (_fixed.length == 10) {
            if (_fixed[0] != 0x1f ||
                _fixed[1] != 0x8b ||
                _fixed[2] != 8 ||
                (_fixed[3] & 0xe0) != 0) {
              throw const TarException(TarFailure.corruptArchive);
            }
            _flags = _fixed[3];
            _stage = (_flags & 4) != 0 ? 1 : 3;
            _skipAbsent();
          }
        case 1:
          _extraLength = byte;
          _stage = 2;
        case 2:
          _extraLength |= byte << 8;
          _stage = _extraLength == 0 ? 3 : 8;
          _skipAbsent();
        case 8:
          _extraLength--;
          if (_extraLength == 0) {
            _stage = 3;
            _skipAbsent();
          }
        case 3:
          if (byte == 0) {
            _stage = 4;
            _skipAbsent();
          }
        case 4:
          if (byte == 0) {
            _stage = 5;
            _skipAbsent();
          }
        case 6:
          _headerCrcValue |= byte << (8 * _headerCrcRead++);
          if (_headerCrcRead == 2) {
            if (_headerCrcValue != (_headerCrc.value & 0xffff)) {
              throw const TarException(TarFailure.corruptArchive);
            }
            _stage = 7;
          }
        default:
          throw const TarException(TarFailure.corruptArchive);
      }
    }
    if (i == bytes.length) return;
    // Limit zlib input to 16 KiB; each processed result is handed to the
    // parser immediately rather than accumulating inflated output.
    while (i < bytes.length) {
      final end = i + 16384 < bytes.length ? i + 16384 : bytes.length;
      final chunk = bytes.sublist(i, end);
      if (_boundary.done) {
        _trailer.addAll(chunk);
      } else {
        final tail = _boundary.add(chunk);
        try {
          _inflate.process(chunk, 0, chunk.length);
          while (true) {
            final out = _inflate.processed(flush: false);
            if (out == null) break;
            _expanded += out.length;
            _contentCrc.add(out);
            await onData(out);
          }
        } on TarException {
          rethrow;
        } catch (_) {
          throw const TarException(TarFailure.corruptArchive);
        }
        _trailer.addAll(tail);
      }
      if (_trailer.length > 8) {
        throw const TarException(TarFailure.corruptArchive);
      }
      i = end;
    }
  }

  void _skipAbsent() {
    if (_stage == 3 && (_flags & 8) == 0) _stage = 4;
    if (_stage == 4 && (_flags & 16) == 0) _stage = 5;
    if (_stage == 5) _stage = (_flags & 2) == 0 ? 7 : 6;
  }

  Future<void> finish() async {
    _complete = true;
    if (_stage != 7 || !_boundary.done || _trailer.length != 8) {
      throw const TarException(TarFailure.corruptArchive);
    }
    try {
      while (true) {
        final out = _inflate.processed(end: true);
        if (out == null) break;
        _expanded += out.length;
        _contentCrc.add(out);
        await onData(out);
      }
    } on TarException {
      rethrow;
    } catch (_) {
      throw const TarException(TarFailure.corruptArchive);
    }
    final crc = _little32(_trailer, 0);
    final size = _little32(_trailer, 4);
    if (crc != _contentCrc.value || size != (_expanded & 0xffffffff)) {
      throw const TarException(TarFailure.corruptArchive);
    }
  }

  int _little32(List<int> bytes, int at) =>
      bytes[at] |
      bytes[at + 1] << 8 |
      bytes[at + 2] << 16 |
      bytes[at + 3] << 24;
}

final class _Crc32 {
  static final List<int> _table = List<int>.generate(256, (n) {
    var value = n;
    for (var i = 0; i < 8; i++) {
      value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1;
    }
    return value;
  }, growable: false);
  int _crc = 0xffffffff;
  int get value => (_crc ^ 0xffffffff) & 0xffffffff;
  void addByte(int byte) => _crc = _table[(_crc ^ byte) & 0xff] ^ (_crc >> 8);
  void add(List<int> bytes) {
    for (final b in bytes) {
      addByte(b);
    }
  }
}

final class _NeedBits implements Exception {
  const _NeedBits();
}

/// Parses deflate framing without materializing output, to locate the exact
/// end of its final block. zlib still validates and inflates the data itself.
final class _DeflateBoundary {
  final List<int> _input = <int>[];
  int _bit = 0;
  int _state = 0;
  bool _final = false;
  int _stored = 0;
  int _hlit = 0, _hdist = 0, _hclen = 0, _codeAt = 0;
  final List<int> _codeLengths = List<int>.filled(19, 0);
  final List<int> _lengths = <int>[];
  _Huffman? _codeTree, _literalTree, _distanceTree;
  bool get done => _state == 6;
  static const List<int> _order = <int>[
    16,
    17,
    18,
    0,
    8,
    7,
    9,
    6,
    10,
    5,
    11,
    4,
    12,
    3,
    13,
    2,
    14,
    1,
    15,
  ];
  static const List<int> _lengthExtra = <int>[
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
    1,
    1,
    1,
    2,
    2,
    2,
    2,
    3,
    3,
    3,
    3,
    4,
    4,
    4,
    4,
    5,
    5,
    5,
    5,
    0,
  ];
  static const List<int> _distanceExtra = <int>[
    0,
    0,
    0,
    0,
    1,
    1,
    2,
    2,
    3,
    3,
    4,
    4,
    5,
    5,
    6,
    6,
    7,
    7,
    8,
    8,
    9,
    9,
    10,
    10,
    11,
    11,
    12,
    12,
    13,
    13,
  ];

  List<int> add(List<int> bytes) {
    _input.addAll(bytes);
    try {
      while (!done) {
        _step();
      }
    } on _NeedBits {
      final consumed = _bit ~/ 8;
      if (consumed > 0) {
        _input.removeRange(0, consumed);
        _bit -= consumed * 8;
      }
      return const <int>[];
    }
    final used = (_bit + 7) ~/ 8;
    final tail = _input.sublist(used);
    _input.clear();
    _bit = 0;
    return tail;
  }

  int _read(int count) {
    if (_bit + count > _input.length * 8) throw const _NeedBits();
    var value = 0;
    for (var i = 0; i < count; i++) {
      value |= ((_input[_bit >> 3] >> (_bit & 7)) & 1) << i;
      _bit++;
    }
    return value;
  }

  void _step() {
    final saved = _bit;
    try {
      switch (_state) {
        case 0:
          _final = _read(1) != 0;
          final type = _read(2);
          if (type == 0) {
            _bit = (_bit + 7) & ~7;
            _state = 1;
          } else if (type == 1) {
            _literalTree = _Huffman(<int>[
              ...List<int>.filled(144, 8),
              ...List<int>.filled(112, 9),
              ...List<int>.filled(24, 7),
              ...List<int>.filled(8, 8),
            ]);
            _distanceTree = _Huffman(List<int>.filled(32, 5));
            _state = 5;
          } else if (type == 2) {
            _state = 2;
          } else {
            throw const TarException(TarFailure.corruptArchive);
          }
        case 1:
          final length = _read(16);
          final complement = _read(16);
          if ((length ^ 0xffff) != complement) {
            throw const TarException(TarFailure.corruptArchive);
          }
          _stored = length;
          _state = 7;
        case 7:
          final available = (_input.length * 8 - _bit) ~/ 8;
          if (available == 0 && _stored != 0) throw const _NeedBits();
          final n = available < _stored ? available : _stored;
          _bit += n * 8;
          _stored -= n;
          if (_stored == 0) _state = _final ? 6 : 0;
        case 2:
          _hlit = _read(5) + 257;
          _hdist = _read(5) + 1;
          _hclen = _read(4) + 4;
          _codeAt = 0;
          _codeLengths.fillRange(0, _codeLengths.length, 0);
          _lengths.clear();
          _state = 3;
        case 3:
          if (_codeAt < _hclen) {
            final next = _read(3);
            _codeLengths[_order[_codeAt++]] = next;
          }
          if (_codeAt == _hclen) {
            _codeTree = _Huffman(_codeLengths);
            _state = 4;
          }
        case 4:
          final symbol = _codeTree!.read(_read);
          if (symbol <= 15) {
            _lengths.add(symbol);
          } else {
            final count = switch (symbol) {
              16 => _read(2) + 3,
              17 => _read(3) + 3,
              18 => _read(7) + 11,
              _ => throw const TarException(TarFailure.corruptArchive),
            };
            if (symbol == 16 && _lengths.isEmpty ||
                _lengths.length + count > _hlit + _hdist) {
              throw const TarException(TarFailure.corruptArchive);
            }
            _lengths.addAll(
              List<int>.filled(count, symbol == 16 ? _lengths.last : 0),
            );
          }
          if (_lengths.length == _hlit + _hdist) {
            _literalTree = _Huffman(_lengths.sublist(0, _hlit));
            _distanceTree = _Huffman(_lengths.sublist(_hlit));
            _state = 5;
          }
        case 5:
          final symbol = _literalTree!.read(_read);
          if (symbol == 256) {
            _state = _final ? 6 : 0;
          } else if (symbol >= 257 && symbol <= 285) {
            _read(_lengthExtra[symbol - 257]);
            final distance = _distanceTree!.read(_read);
            if (distance >= _distanceExtra.length) {
              throw const TarException(TarFailure.corruptArchive);
            }
            _read(_distanceExtra[distance]);
          } else if (symbol > 285) {
            throw const TarException(TarFailure.corruptArchive);
          }
        default:
          throw const TarException(TarFailure.corruptArchive);
      }
    } on _NeedBits {
      _bit = saved;
      rethrow;
    }
  }
}

final class _Huffman {
  _Huffman(List<int> lengths) {
    final counts = List<int>.filled(16, 0);
    for (final length in lengths) {
      if (length < 0 || length > 15) {
        throw const TarException(TarFailure.corruptArchive);
      }
      if (length > 0) counts[length]++;
    }
    var code = 0;
    final next = List<int>.filled(16, 0);
    for (var bits = 1; bits <= 15; bits++) {
      code = (code + counts[bits - 1]) << 1;
      if (code + counts[bits] > 1 << bits) {
        throw const TarException(TarFailure.corruptArchive);
      }
      next[bits] = code;
    }
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final bits = lengths[symbol];
      if (bits == 0) continue;
      final canonical = next[bits]++;
      var reversed = 0;
      for (var i = 0; i < bits; i++) {
        reversed = (reversed << 1) | ((canonical >> i) & 1);
      }
      _codes[(1 << bits) | reversed] = symbol;
    }
  }
  final Map<int, int> _codes = <int, int>{};
  int read(int Function(int) read) {
    var code = 0;
    for (var bits = 1; bits <= 15; bits++) {
      code |= read(1) << (bits - 1);
      final value = _codes[(1 << bits) | code];
      if (value != null) return value;
    }
    throw const TarException(TarFailure.corruptArchive);
  }
}

final class SnapshotWorkerProgress {
  const SnapshotWorkerProgress({
    required this.receivedBytes,
    required this.processedPaths,
    required this.totalBlobPaths,
    required this.inFlightBytes,
  });
  final int receivedBytes, processedPaths, totalBlobPaths, inFlightBytes;
}

final class SnapshotWorkerResult {
  const SnapshotWorkerResult({
    required this.tree,
    required this.storedBytes,
    required this.unmatched,
    required this.reused,
  });
  final SnapshotTree tree;
  final int storedBytes, unmatched, reused;
}

final class SnapshotWorkerException implements Exception {
  const SnapshotWorkerException(this.failure);
  final SnapshotFailure failure;
}

final class _WorkerStart {
  const _WorkerStart(
    this.output,
    this.supportRoot,
    this.accountKey,
    this.keys,
    this.tree,
    this.format,
    this.epoch,
  );
  final SendPort output;
  final String supportRoot, accountKey;
  final SnapshotKeyMaterial keys;
  final SnapshotTree tree;
  final SnapshotObjectFormat format;
  final int epoch;
}

/// Owns exactly one isolated archive job. All network reads remain on the
/// caller's isolate. A credit is returned only after the worker processes data.
final class SnapshotWorker {
  SnapshotWorker._(
    this._events,
    this._exit,
    this._errors,
    this.epoch,
    this.idleTimeout,
    this.stopTimeout,
  );
  final ReceivePort _events, _exit, _errors;
  final int epoch;
  final Duration idleTimeout, stopTimeout;
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Completer<SnapshotWorkerResult> _result =
      Completer<SnapshotWorkerResult>();
  final Completer<void> _exited = Completer<void>();
  Completer<void>? _creditWaiter;
  StreamIterator<Uint8List>? _iterator;
  late final Isolate _isolate;
  int _credits = 0;
  int _inFlight = 0;
  int _received = 0;
  int _processed = 0;
  int _total = 0;
  bool _stopRequested = false, _started = false;
  SendPort? _workerPort;
  void Function(SnapshotWorkerProgress)? _onProgress;

  static Future<SnapshotWorker> start({
    required SnapshotStore store,
    required SnapshotTree tree,
    required SnapshotObjectFormat format,
    required int jobEpoch,
    Duration idleTimeout = const Duration(seconds: 60),
    Duration stopTimeout = const Duration(seconds: 5),
  }) async {
    tree.validate(format: format);
    final events = ReceivePort();
    final exit = ReceivePort();
    final errors = ReceivePort();
    final worker = SnapshotWorker._(
      events,
      exit,
      errors,
      jobEpoch,
      idleTimeout,
      stopTimeout,
    );
    errors.listen((_) {});
    worker._total = tree.entries
        .where((entry) => entry.type == SnapshotEntryType.blob)
        .length;
    events.listen(worker._handleEvent);
    exit.listen((_) {
      if (!worker._exited.isCompleted) worker._exited.complete();
      if (!worker._ready.isCompleted) {
        worker._ready.completeError(
          const SnapshotWorkerException(SnapshotFailure.storageError),
        );
      }
      if (!worker._result.isCompleted) {
        worker._result.completeError(
          const SnapshotWorkerException(SnapshotFailure.sessionEnded),
        );
      }
      worker._wakeCredit();
    });
    final keys = await store.workerKeys;
    worker._isolate = await Isolate.spawn<_WorkerStart>(
      _workerMain,
      _WorkerStart(
        events.sendPort,
        store.supportRoot.path,
        store.accountKey,
        keys,
        tree,
        format,
        jobEpoch,
      ),
      onExit: exit.sendPort,
      onError: errors.sendPort,
      errorsAreFatal: true,
    );
    unawaited(
      worker._result.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace stack) {},
      ),
    );
    await worker._ready.future;
    return worker;
  }

  void _handleEvent(Object? event) {
    if (event is! List<Object?> || event.isEmpty) return;
    switch (event[0]) {
      case 'ready':
        _credits = 16;
        _workerPort = event[1]! as SendPort;
        if (!_ready.isCompleted) _ready.complete(_workerPort!);
        _wakeCredit();
      case 'credit':
        _credits++;
        _inFlight -= event[1]! as int;
        _processed = event[2]! as int;
        _progress();
        _wakeCredit();
      case 'done':
        _workerPort?.send(<Object?>['exit', epoch]);
        if (!_result.isCompleted) {
          _result.complete(event[1]! as SnapshotWorkerResult);
        }
        _wakeCredit();
      case 'failed':
        _workerPort?.send(<Object?>['exit', epoch]);
        if (!_result.isCompleted) {
          _result.completeError(
            SnapshotWorkerException(event[1]! as SnapshotFailure),
          );
        }
        _wakeCredit();
      case 'stopped':
        _workerPort?.send(<Object?>['exit', epoch]);
        if (!_result.isCompleted) {
          _result.completeError(
            const SnapshotWorkerException(SnapshotFailure.sessionEnded),
          );
        }
        _wakeCredit();
    }
  }

  void _progress() => _onProgress?.call(
    SnapshotWorkerProgress(
      receivedBytes: _received,
      processedPaths: _processed,
      totalBlobPaths: _total,
      inFlightBytes: _inFlight,
    ),
  );
  void _wakeCredit() {
    final waiter = _creditWaiter;
    _creditWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<SnapshotWorkerResult> run(
    Stream<Uint8List> input, {
    void Function(SnapshotWorkerProgress)? onProgress,
  }) async {
    if (_started) throw StateError('Worker already started');
    _started = true;
    _onProgress = onProgress;
    final iterator = _iterator = StreamIterator<Uint8List>(input);
    final port = await _ready.future;
    var remainingIdle = idleTimeout;
    try {
      while (!_stopRequested && !_result.isCompleted) {
        while (_credits == 0 && !_stopRequested && !_result.isCompleted) {
          final waiter = _creditWaiter = Completer<void>();
          await waiter.future;
        }
        if (_stopRequested || _result.isCompleted) break;
        final watch = Stopwatch()..start();
        final next = iterator.moveNext().timeout(remainingIdle);
        final hasNext = await Future.any<bool>(<Future<bool>>[
          next,
          _result.future.then<bool>(
            (_) => false,
            onError: (Object _, StackTrace stack) => false,
          ),
        ]);
        watch.stop();
        remainingIdle -= watch.elapsed;
        if (!hasNext) {
          if (!_result.isCompleted && !_stopRequested) {
            port.send(<Object?>['end', epoch]);
          }
          break;
        }
        final chunk = iterator.current;
        if (chunk.isNotEmpty) remainingIdle = idleTimeout;
        for (var offset = 0; offset < chunk.length; offset += 65536) {
          while (_credits == 0 && !_stopRequested && !_result.isCompleted) {
            final waiter = _creditWaiter = Completer<void>();
            await waiter.future;
          }
          if (_stopRequested || _result.isCompleted) break;
          final end = offset + 65536 < chunk.length
              ? offset + 65536
              : chunk.length;
          final slice = Uint8List.sublistView(chunk, offset, end);
          _credits--;
          _inFlight += slice.length;
          _received += slice.length;
          _progress();
          port.send(<Object?>[
            'chunk',
            epoch,
            TransferableTypedData.fromList(<Uint8List>[slice]),
          ]);
        }
      }
      return await _result.future;
    } on TimeoutException {
      await stop();
      throw const SnapshotWorkerException(SnapshotFailure.network);
    } on SnapshotWorkerException {
      if (!_result.isCompleted) await stop();
      rethrow;
    } on OfflineRequestFailure {
      await stop();
      rethrow;
    } catch (_) {
      await stop();
      throw const SnapshotWorkerException(SnapshotFailure.network);
    } finally {
      await iterator.cancel();
      await _exited.future;
      _events.close();
      _exit.close();
      _errors.close();
    }
  }

  /// Acknowledgement or forced isolate termination precedes return.
  Future<void> stop() async {
    if (_stopRequested) {
      await _exited.future;
      return;
    }
    _stopRequested = true;
    _wakeCredit();
    final port = await _ready.future;
    port.send(<Object?>['stop', epoch]);
    final iterator = _iterator;
    if (iterator != null) unawaited(iterator.cancel());
    try {
      await _exited.future.timeout(stopTimeout);
    } on TimeoutException {
      _isolate.kill(priority: Isolate.immediate);
      await _exited.future;
    }
  }
}

final class _Stopped implements Exception {
  const _Stopped();
}

void _workerMain(_WorkerStart args) {
  final input = ReceivePort();
  args.output.send(<Object?>['ready', input.sendPort]);
  var stopped = false;
  var processing = false;
  var terminal = false;
  final queue = Queue<List<Object?>>();
  final store = SnapshotStore.withKeys(
    supportRoot: Directory(args.supportRoot),
    accountKey: args.accountKey,
    keys: args.keys,
  );
  final entries = <String, SnapshotTreeEntry>{
    for (final entry in args.tree.entries) entry.path: entry,
  };
  final seen = <String>{};
  var unmatched = 0, processed = 0, storedBytes = 0, reused = 0;

  void checkStop() {
    if (stopped) throw const _Stopped();
  }

  bool inside(String path) =>
      args.tree.subPath.isEmpty || path.startsWith('${args.tree.subPath}/');
  int? retain(TarEntry entry) {
    final item = entry.path == null ? null : entries[entry.path];
    if (entry.type != TarEntryType.file ||
        item == null ||
        item.type != SnapshotEntryType.blob ||
        item.mode == '120000' ||
        !inside(item.path)) {
      return null;
    }
    return isSnapshotImagePath(item.path)
        ? maxSnapshotImageBytes
        : maxSnapshotTextBytes;
  }

  final parser = TarStreamParser(
    expectedSha: args.tree.sha,
    retainLimit: retain,
    onEntry: (tar, bytes) async {
      checkStop();
      final path = tar.path;
      if (path == null) {
        unmatched++;
        return;
      }
      if (tar.type == TarEntryType.directory &&
          args.tree.subPath.isNotEmpty &&
          (path == args.tree.subPath ||
              args.tree.subPath.startsWith('$path/'))) {
        return;
      }
      final item = entries[path];
      if (item == null || !inside(path)) {
        unmatched++;
        return;
      }
      if (tar.type == TarEntryType.directory) {
        if (item.type == SnapshotEntryType.commit) {
          entries[path] = item.copyWith(state: SnapshotEntryState.submodule);
        } else if (item.type != SnapshotEntryType.tree) {
          unmatched++;
        }
        return;
      }
      if (item.type != SnapshotEntryType.blob) {
        unmatched++;
        return;
      }
      if (tar.type == TarEntryType.symlink) {
        if (item.mode == '120000') {
          entries[path] = item.copyWith(state: SnapshotEntryState.symlink);
          seen.add(path);
          processed++;
        } else {
          unmatched++;
        }
        return;
      }
      seen.add(path);
      processed++;
      if (tar.type == TarEntryType.unsupported) {
        entries[path] = item.copyWith(
          state: SnapshotEntryState.unsupportedType,
        );
        return;
      }
      if (item.mode == '120000') {
        entries[path] = item.copyWith(state: SnapshotEntryState.mismatch);
        return;
      }
      final result = verifyArchiveBlob(
        path: path,
        mode: item.mode,
        id: item.id,
        objectFormat: args.format.name,
        size: tar.size,
        bytes: bytes,
      );
      if (result.state != ArchiveBlobState.saved) {
        entries[path] = item.copyWith(
          state: SnapshotEntryState.values.byName(result.state.name),
        );
        return;
      }
      final plain = result.bytes!;
      storedBytes += plain.length;
      if (storedBytes > snapshotStoredLimit) {
        throw const SnapshotWorkerException(SnapshotFailure.storageFull);
      }
      final wasReused = await store.writeBlob(
        args.format,
        item.id,
        plain,
        mayCommit: () => !stopped,
      );
      checkStop();
      if (wasReused) reused++;
      entries[path] = item.copyWith(
        state: SnapshotEntryState.saved,
        kind: SnapshotContentKind.values.byName(result.kind!.name),
        size: plain.length,
        lines: result.lines,
      );
    },
  );
  final gzip = StrictGzipStream(
    onData: (bytes) async {
      checkStop();
      await parser.add(bytes);
      await Future<void>.delayed(Duration.zero);
      checkStop();
    },
  );

  void deliver(List<Object?> message) {
    terminal = true;
    args.output.send(message);
  }

  Future<void> pump() async {
    if (processing) return;
    processing = true;
    try {
      while (queue.isNotEmpty) {
        checkStop();
        final msg = queue.removeFirst();
        if (msg[0] == 'chunk') {
          final chunk = (msg[2]! as TransferableTypedData)
              .materialize()
              .asUint8List();
          await gzip.add(chunk);
          checkStop();
          args.output.send(<Object?>['credit', chunk.length, processed]);
          await Future<void>.delayed(Duration.zero);
        } else if (msg[0] == 'end') {
          await gzip.finish();
          parser.finish();
          checkStop();
          for (final item in args.tree.entries) {
            if (item.type == SnapshotEntryType.blob &&
                !seen.contains(item.path)) {
              entries[item.path] = item.copyWith(
                state: SnapshotEntryState.missing,
              );
            } else if (item.type == SnapshotEntryType.commit) {
              entries[item.path] = item.copyWith(
                state: SnapshotEntryState.submodule,
              );
            } else if (item.type == SnapshotEntryType.tree) {
              entries[item.path] = item.copyWith(
                state: SnapshotEntryState.saved,
              );
            }
          }
          final resultTree = SnapshotTree(
            snapshotId: args.tree.snapshotId,
            sha: args.tree.sha,
            subPath: args.tree.subPath,
            entries: <SnapshotTreeEntry>[
              for (final item in args.tree.entries) entries[item.path]!,
            ],
          );
          resultTree.validate(format: args.format, complete: true);
          final result = SnapshotWorkerResult(
            tree: resultTree,
            storedBytes: storedBytes,
            unmatched: unmatched,
            reused: reused,
          );
          deliver(<Object?>['done', result]);
          return;
        }
      }
      if (stopped) deliver(<Object?>['stopped', args.epoch]);
    } on _Stopped {
      deliver(<Object?>['stopped', args.epoch]);
    } on TarException catch (error) {
      final failure = switch (error.failure) {
        TarFailure.archiveTooLarge => SnapshotFailure.archiveTooLarge,
        TarFailure.corruptArchive => SnapshotFailure.corruptArchive,
        TarFailure.shaMismatch => SnapshotFailure.shaMismatch,
      };
      deliver(<Object?>['failed', failure]);
    } on SnapshotWorkerException catch (error) {
      deliver(<Object?>['failed', error.failure]);
    } on SnapshotStoreException catch (error) {
      final failure = switch (error.code) {
        SnapshotStoreError.deviceFull => SnapshotFailure.deviceFull,
        SnapshotStoreError.capacity => SnapshotFailure.storageFull,
        SnapshotStoreError.revoked => SnapshotFailure.sessionEnded,
        _ => SnapshotFailure.storageError,
      };
      deliver(<Object?>['failed', failure]);
    } catch (_) {
      deliver(<Object?>['failed', SnapshotFailure.storageError]);
    } finally {
      processing = false;
    }
  }

  input.listen((Object? raw) {
    if (raw is! List<Object?> || raw.length < 2 || raw[1] != args.epoch) return;
    if (raw[0] == 'exit') {
      input.close();
      Isolate.exit();
    }
    if (terminal) return;
    if (raw[0] == 'stop') {
      stopped = true;
    } else {
      queue.add(raw);
    }
    unawaited(pump());
  });
}
