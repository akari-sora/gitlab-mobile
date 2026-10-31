import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Brightness;
import 'package:flutter/foundation.dart'
    show SynchronousFuture, compute, visibleForTesting;
import 'package:flutter/material.dart' show InlineSpan, TextSpan, TextStyle;
import 'ansi.dart';
import 'failure.dart';
import 'gitlab_api.dart';

/// GitLab CI traces, with `section_start` / `section_end` markers removed
/// and ANSI / SGR color styles parsed into styled spans.
final class JobTrace {
  /// Nested `section_start` markers past this depth stay plain text.
  static const maxDepth = 32;

  /// Further `section_start` markers are ignored once the lifetime section
  /// count (closed sections emitted so far, including any later evicted by the
  /// sliding window, plus currently open sections on the stack) reaches this
  /// limit, so a marker-dense trace cannot explode.
  static const maxSections = 1024;

  /// Cumulative characters fed into [AnsiStateMachine.parseSpans] across all
  /// [JobTrace.parse] and [JobTraceParser] committed and preview parses since
  /// the last [resetDebugCounters].
  @visibleForTesting
  static int debugCharactersProcessed = 0;

  /// Resets [debugCharactersProcessed] for deterministic test assertions.
  @visibleForTesting
  static void resetDebugCounters() {
    debugCharactersProcessed = 0;
  }

  const JobTrace({
    String? ansiStripped,
    required this.lines,
    required this.sections,
    this.truncated = false,
    this.windowStart = 0,
    this.charactersProcessed = 0,
    int? estimatedBytes,
  })  : _ansiStripped = ansiStripped,
        _estimatedBytes = estimatedBytes;

  final String? _ansiStripped;
  final int? _estimatedBytes;

  /// Plain text of the trace without ANSI sequences. For whole-string
  /// [JobTrace.parse], this is the raw trace with timestamps and CSI escapes
  /// stripped before section markers are removed; for incremental
  /// [JobTraceParser] snapshots, it is synthesized on demand by joining the
  /// retained window's [lines].
  String get ansiStripped =>
      _ansiStripped ??
      (lines.isEmpty ? '' : lines.map((line) => line.text).join('\n'));

  final List<JobTraceLine> lines;
  final List<JobTraceSection> sections;

  /// Whether earlier lines before [lines] were dropped by the sliding window.
  final bool truncated;

  /// Absolute line index of `lines[0]` in the parser stream (`0` when not
  /// truncated).
  final int windowStart;

  /// Total decoded characters fed into the parser that produced this trace.
  final int charactersProcessed;

  /// Approximate in-memory footprint in bytes of the retained parsed model.
  int get estimatedBytes {
    final cached = _estimatedBytes;
    if (cached != null) return cached;
    var total = (_ansiStripped?.length ?? 0) * 2;
    for (final line in lines) {
      total += line.estimatedBytes;
    }
    for (final section in sections) {
      total += section.estimatedBytes;
    }
    return total;
  }

  static const empty = JobTrace(
    ansiStripped: '',
    lines: <JobTraceLine>[],
    sections: <JobTraceSection>[],
    estimatedBytes: 0,
  );

  static final _ansi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  static final _marker = RegExp(
    r'section_(start|end):(\d+):([A-Za-z0-9_.-]+)(?:\[collapsed=(true|false)\])?\r?',
  );

  /// GitLab Runner's line header: UTC time, stream number, `E`/`O`, then `+`
  /// when the line continues the previous one. Like GitLab, a trace has
  /// headers only when its first line does.
  static final _timestampHeader = RegExp(
    r'\d{4}-[01]\d-[0-3]\dT[0-2]\d:[0-5]\d:[0-5]\d\.\d{6}Z [0-9a-f]{2}[EO][+ ]',
  );
  static const _timestampHeaderLength = 32;

  factory JobTrace.parse(String trace, {int maxLines = GitLabApi.maxTextLines}) {
    final raw = _withoutTimestamps(trace);
    final plain = raw.replaceAll(_ansi, '');
    if (plain.isEmpty) return JobTrace.empty;
    // Newlines are a fast lower bound. Inline section markers can still split
    // one physical line into many rows, so each emitted row is counted too.
    var newlines = 0;
    for (var i = 0; i < plain.length; i++) {
      if (plain.codeUnitAt(i) != 0x0A) continue;
      newlines++;
      if (newlines >= maxLines) throw const ApiFailure(FailureKind.tooLarge);
    }
    final lines = <JobTraceLine>[];
    final sections = <JobTraceSection>[];
    final stack = <_OpenSection>[];
    final stateMachine = AnsiStateMachine();
    var start = 0;
    for (var i = 0; i <= raw.length; i++) {
      if (i != raw.length && raw.codeUnitAt(i) != 0x0A) continue;
      var line = raw.substring(start, i);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      _takeLine(line, lines, sections, stack, stateMachine, maxLines);
      start = i + 1;
    }
    while (stack.isNotEmpty) {
      _close(stack.removeLast(), null, lines.length, sections);
    }
    return JobTrace(
      ansiStripped: plain,
      lines: List.unmodifiable(lines),
      sections: List.unmodifiable(sections),
      charactersProcessed: trace.length,
    );
  }
}

/// Incremental, sliding-window parser for GitLab CI job logs.
///
/// Only newly appended bytes or text chunks are decoded and parsed. Across
/// chunks, the parser preserves:
/// - the chunked UTF-8 decoder state (trailing incomplete multi-byte sequence);
/// - the [AnsiStateMachine] state (active SGR style and incomplete CSI escape);
/// - the open section stack;
/// - the trailing incomplete logical line and runner timestamp continuation.
///
/// Only the last [maxLines] lines are retained in memory. Closed sections that
/// end before the sliding window are dropped; sections that start before the
/// window and extend into it have their `startLine` clamped to `0`.
final class JobTraceParser {
  /// Appended byte chunks larger than 64 KiB are parsed on a background
  /// isolate by [addBytesAsync].
  static const isolateThresholdBytes = 64 * 1024;

  /// Maximum characters retained in an unterminated pending logical line
  /// (e.g. `\r`-only progress output without a newline).
  static const maxPendingLineChars = 64 * 1024;

  static const _blockSize = 512;

  JobTraceParser({this.maxLines = GitLabApi.maxTextLines})
      : _inBackgroundIsolate = false {
    _initUtf8Sink();
  }

  JobTraceParser._fromCarryState(_IsolateParseRequest req)
      : maxLines = req.maxLines,
        _inBackgroundIsolate = true,
        _utf8Carry = req.utf8Carry,
        _committedAnsi = req.ansi.copy(),
        _committedStack = List<_OpenSection>.of(req.stack),
        _totalCommittedLines = req.totalCommittedLines,
        _totalCommittedSections = req.totalCommittedSections,
        _timestampsEnabled = req.timestampsEnabled,
        _initialBuffer = StringBuffer(req.initialBuffer),
        _inPhysicalHeader = req.inPhysicalHeader,
        _newlinePending = req.newlinePending,
        _pendingPhysicalHeader = req.pendingPhysicalHeader,
        _currentLogicalLine = StringBuffer(req.currentLogicalLine) {
    for (final section in req.committedSections) {
      _committedSections.add(section);
      _committedSectionsBytes += section.estimatedBytes;
    }
    _initUtf8Sink();
  }

  final int maxLines;
  final bool _inBackgroundIsolate;

  late ByteConversionSink _utf8Sink;
  Uint8List _utf8Carry = Uint8List(0);
  bool _suppressUtf8Callback = false;

  AnsiStateMachine _committedAnsi = AnsiStateMachine();
  List<_OpenSection> _committedStack = <_OpenSection>[];

  final List<List<JobTraceLine>> _blocks = <List<JobTraceLine>>[];
  int _firstBlockOffset = 0;
  int _bufferedLineCount = 0;
  int _totalCommittedLines = 0;
  int _committedLinesBytes = 0;

  int get _firstBufferedLineIndex => _totalCommittedLines - _bufferedLineCount;
  int get _globalWindowStart =>
      _totalCommittedLines > maxLines ? _totalCommittedLines - maxLines : 0;

  final List<JobTraceSection> _committedSections = <JobTraceSection>[];
  int _committedSectionsBytes = 0;
  int _totalCommittedSections = 0;

  bool? _timestampsEnabled;
  StringBuffer _initialBuffer = StringBuffer();
  bool _inPhysicalHeader = false;
  bool _newlinePending = false;
  String _pendingPhysicalHeader = '';
  StringBuffer _currentLogicalLine = StringBuffer();

  int _charactersProcessed = 0;
  int _spanCharactersProcessed = 0;
  int _mutationCount = 0;
  JobTrace? _cachedSnapshot;

  /// Total decoded characters processed by this parser instance.
  int get charactersProcessed => _charactersProcessed;

  /// Whether there is an incomplete multi-byte UTF-8 sequence waiting for
  /// continuation bytes or [finish].
  bool get hasPendingUtf8 => _utf8Carry.isNotEmpty;

  /// Approximate memory footprint in bytes of the retained parsed model and
  /// pending raw buffers.
  int get estimatedBytes =>
      (_cachedSnapshot ?? snapshot()).estimatedBytes;

  int get _rawBuffersEstimatedBytes =>
      _utf8Carry.length +
      (_initialBuffer.length +
              _pendingPhysicalHeader.length +
              _currentLogicalLine.length) *
          2;

  void _initUtf8Sink() {
    _utf8Sink = const Utf8Decoder(allowMalformed: true).startChunkedConversion(
      _ImmediateStringSink(_onUtf8Decoded),
    );
    if (_utf8Carry.isNotEmpty) {
      _suppressUtf8Callback = true;
      _utf8Sink.add(_utf8Carry);
      _suppressUtf8Callback = false;
    }
  }

  void _onUtf8Decoded(String chunk) {
    if (_suppressUtf8Callback || chunk.isEmpty) return;
    _feedDecodedText(chunk);
  }

  /// Appends a raw UTF-8 byte chunk synchronously and returns the current
  /// windowed [JobTrace] snapshot.
  JobTrace addBytes(List<int> bytes, {bool isLast = false}) {
    _mutationCount++;
    if (bytes.isNotEmpty) {
      _cachedSnapshot = null;
      _utf8Sink.add(bytes);
      _utf8Carry = _computeNextUtf8Carry(_utf8Carry, bytes, isLast: isLast);
    }
    if (isLast) {
      return finish();
    }
    return snapshot();
  }

  /// Appends a decoded text chunk synchronously and returns the current
  /// windowed [JobTrace] snapshot.
  JobTrace addText(String chunk, {bool isLast = false}) {
    _mutationCount++;
    if (chunk.isNotEmpty) {
      _cachedSnapshot = null;
      _feedDecodedText(chunk);
    }
    if (isLast) {
      return finish();
    }
    return snapshot();
  }

  /// Flushes any trailing incomplete UTF-8 sequence at EOF and returns the
  /// resulting [JobTrace] snapshot.
  JobTrace finish() {
    _mutationCount++;
    _cachedSnapshot = null;
    _utf8Sink.close();
    _utf8Carry = Uint8List(0);
    _initUtf8Sink();
    return snapshot();
  }

  /// Appends [bytes], running the parse on a background isolate via [compute]
  /// when `bytes.length > isolateThresholdBytes` (64 KiB).
  ///
  /// If [shouldCommit] is provided and returns `false` after the isolate
  /// completes, the parser state is left unchanged and `null` is returned.
  ///
  /// Throws a [StateError] if the parser is mutated synchronously (or by
  /// another [addBytesAsync] commit) while the background isolate is in flight.
  Future<JobTrace?> addBytesAsync(
    List<int> bytes, {
    bool isLast = false,
    bool Function()? shouldCommit,
  }) {
    if (bytes.length <= isolateThresholdBytes) {
      if (shouldCommit != null && !shouldCommit()) {
        return SynchronousFuture<JobTrace?>(null);
      }
      return SynchronousFuture<JobTrace?>(addBytes(bytes, isLast: isLast));
    }
    return _addBytesInIsolate(bytes, isLast: isLast, shouldCommit: shouldCommit);
  }

  Future<JobTrace?> _addBytesInIsolate(
    List<int> bytes, {
    required bool isLast,
    bool Function()? shouldCommit,
  }) async {
    final startMutation = ++_mutationCount;
    final payload = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final req = _IsolateParseRequest(
      bytes: payload,
      isLast: isLast,
      maxLines: maxLines,
      utf8Carry: Uint8List.fromList(_utf8Carry),
      ansi: _committedAnsi.copy(),
      stack: List<_OpenSection>.of(_committedStack),
      totalCommittedLines: _totalCommittedLines,
      totalCommittedSections: _totalCommittedSections,
      committedSections: List<JobTraceSection>.of(_committedSections),
      timestampsEnabled: _timestampsEnabled,
      initialBuffer: _initialBuffer.toString(),
      inPhysicalHeader: _inPhysicalHeader,
      newlinePending: _newlinePending,
      pendingPhysicalHeader: _pendingPhysicalHeader,
      currentLogicalLine: _currentLogicalLine.toString(),
    );
    final res = await compute(_parseChunkInIsolate, req);
    if (shouldCommit != null && !shouldCommit()) {
      return null;
    }
    if (_mutationCount != startMutation) {
      throw StateError(
        'JobTraceParser was mutated while addBytesAsync isolate was in flight.',
      );
    }
    _mutationCount++;
    _cachedSnapshot = null;
    _charactersProcessed += res.charsProcessed;
    _spanCharactersProcessed += res.spanCharsProcessed;
    JobTrace.debugCharactersProcessed += res.spanCharsProcessed;
    _utf8Carry = res.utf8Carry;
    _initUtf8Sink();
    _committedAnsi = res.ansi;
    _committedStack = res.stack;
    _timestampsEnabled = res.timestampsEnabled;
    _initialBuffer = StringBuffer(res.initialBuffer);
    _inPhysicalHeader = res.inPhysicalHeader;
    _newlinePending = res.newlinePending;
    _pendingPhysicalHeader = res.pendingPhysicalHeader;
    _currentLogicalLine = StringBuffer(res.currentLogicalLine);

    if (res.discardExistingCommittedLines) {
      _blocks.clear();
      _firstBlockOffset = 0;
      _bufferedLineCount = 0;
      _committedLinesBytes = 0;
    }
    _totalCommittedLines = res.totalCommittedLines;
    for (final line in res.newCommittedLines) {
      _appendBufferedLine(line);
    }
    _evictCommittedLinesIfNeeded();

    _committedSections
      ..clear()
      ..addAll(res.committedSections);
    _committedSectionsBytes = res.committedSectionsBytes;
    _totalCommittedSections = res.totalCommittedSections;
    _evictCommittedSectionsIfNeeded();

    return snapshot();
  }

  void _capCurrentLogicalLine() {
    if (_currentLogicalLine.length <= maxPendingLineChars) return;
    final s = _currentLogicalLine.toString();
    final searchEnd = s.endsWith('\r') ? s.length - 1 : s.length;
    final lastCr = searchEnd > 0 ? s.lastIndexOf('\r', searchEnd - 1) : -1;
    String kept;
    if (lastCr >= 0) {
      kept = s.substring(lastCr + 1);
      if (kept.length > maxPendingLineChars) {
        kept = kept.substring(kept.length - maxPendingLineChars);
      }
    } else {
      kept = s.substring(s.length - maxPendingLineChars);
    }
    _currentLogicalLine
      ..clear()
      ..write(kept);
  }

  void _feedDecodedText(String chunk) {
    if (chunk.isEmpty) return;
    _charactersProcessed += chunk.length;
    var i = 0;
    if (_timestampsEnabled == null) {
      while (i < chunk.length && _timestampsEnabled == null) {
        final cu = chunk.codeUnitAt(i);
        if (cu == 0x0A) {
          _timestampsEnabled = false;
          final buffered = _initialBuffer.toString();
          _initialBuffer.clear();
          _feedPlainNoTimestamps(buffered);
          break;
        }
        _initialBuffer.writeCharCode(cu);
        i++;
        if (_initialBuffer.length == JobTrace._timestampHeaderLength) {
          final headerStr = _initialBuffer.toString();
          _initialBuffer.clear();
          if (JobTrace._timestampHeader.matchAsPrefix(headerStr) != null) {
            _timestampsEnabled = true;
            _inPhysicalHeader = false;
            _newlinePending = false;
            _pendingPhysicalHeader = '';
          } else {
            _timestampsEnabled = false;
            _feedPlainNoTimestamps(headerStr);
          }
        }
      }
      if (i >= chunk.length) return;
    }
    if (_timestampsEnabled == false) {
      _feedPlainNoTimestamps(chunk, startOffset: i);
    } else {
      _feedWithTimestamps(chunk, startOffset: i);
    }
  }

  void _feedPlainNoTimestamps(String chunk, {int startOffset = 0}) {
    var start = startOffset;
    while (start < chunk.length) {
      final nl = chunk.indexOf('\n', start);
      if (nl < 0) {
        _currentLogicalLine.write(chunk.substring(start));
        _capCurrentLogicalLine();
        return;
      }
      if (nl > start) {
        _currentLogicalLine.write(chunk.substring(start, nl));
      }
      _commitLogicalLine(_currentLogicalLine.toString());
      _currentLogicalLine.clear();
      start = nl + 1;
    }
  }

  void _feedWithTimestamps(String chunk, {int startOffset = 0}) {
    var pos = startOffset;
    while (pos < chunk.length) {
      if (!_inPhysicalHeader) {
        final nl = chunk.indexOf('\n', pos);
        if (nl < 0) {
          _currentLogicalLine.write(chunk.substring(pos));
          _capCurrentLogicalLine();
          return;
        }
        if (nl > pos) {
          _currentLogicalLine.write(chunk.substring(pos, nl));
          _capCurrentLogicalLine();
        }
        _inPhysicalHeader = true;
        _newlinePending = true;
        _pendingPhysicalHeader = '';
        pos = nl + 1;
      } else {
        final needed =
            JobTrace._timestampHeaderLength - _pendingPhysicalHeader.length;
        final avail = chunk.length - pos;
        final take = needed < avail ? needed : avail;
        final nl = chunk.indexOf('\n', pos);
        if (nl >= 0 && nl < pos + take) {
          _commitLogicalLine(_currentLogicalLine.toString());
          _currentLogicalLine
            ..clear()
            ..write(_pendingPhysicalHeader);
          if (nl > pos) {
            _currentLogicalLine.write(chunk.substring(pos, nl));
          }
          _pendingPhysicalHeader = '';
          _inPhysicalHeader = true;
          _newlinePending = true;
          pos = nl + 1;
        } else {
          _pendingPhysicalHeader += chunk.substring(pos, pos + take);
          pos += take;
          if (_pendingPhysicalHeader.length ==
              JobTrace._timestampHeaderLength) {
            final header =
                JobTrace._timestampHeader.matchAsPrefix(_pendingPhysicalHeader) !=
                    null;
            if (header) {
              final continued = _pendingPhysicalHeader.codeUnitAt(
                    JobTrace._timestampHeaderLength - 1,
                  ) ==
                  0x2B;
              if (!continued) {
                _commitLogicalLine(_currentLogicalLine.toString());
                _currentLogicalLine.clear();
              }
            } else {
              _commitLogicalLine(_currentLogicalLine.toString());
              _currentLogicalLine
                ..clear()
                ..write(_pendingPhysicalHeader);
            }
            _pendingPhysicalHeader = '';
            _inPhysicalHeader = false;
            _newlinePending = false;
          }
        }
      }
    }
  }

  void _commitLogicalLine(String rawLine) {
    var line = rawLine;
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    _parseLineIntoCommitted(line);
    _evictCommittedLinesIfNeeded();
    _evictCommittedSectionsIfNeeded();
  }

  void _parseLineIntoCommitted(String line) {
    var cursor = 0;
    var sawMarker = false;
    for (final match in JobTrace._marker.allMatches(line)) {
      sawMarker = true;
      final before = line.substring(cursor, match.start);
      if (before.isNotEmpty) {
        _emitSegmentIntoCommitted(before, allowEmpty: false);
      }
      _applyMarkerCounted(
        match,
        currentLineCount: _totalCommittedLines,
        currentSectionCount: _totalCommittedSections,
        stack: _committedStack,
        onClose: _addCommittedSection,
      );
      cursor = match.end;
    }
    final rest = line.substring(cursor);
    if (!sawMarker || rest.isNotEmpty) {
      _emitSegmentIntoCommitted(rest, allowEmpty: !sawMarker);
    }
  }

  void _emitSegmentIntoCommitted(String rawText, {required bool allowEmpty}) {
    _spanCharactersProcessed += rawText.length;
    if (!_inBackgroundIsolate) {
      JobTrace.debugCharactersProcessed += rawText.length;
    }
    final spans = _committedAnsi.parseSpans(rawText);
    final plainText = spans.isEmpty ? '' : spans.map((s) => s.text).join();
    if (plainText.isEmpty) {
      if (!allowEmpty) return;
      _addCommittedLine(
        JobTraceLine(
          '',
          lowerText: '',
          section: _committedStack.isEmpty ? null : _committedStack.last.name,
        ),
      );
      return;
    }
    final sectionName =
        _committedStack.isEmpty ? null : _committedStack.last.name;
    if (plainText.length <= _committedAnsi.maxLineLength) {
      _addCommittedLine(
        JobTraceLine(plainText, section: sectionName, spans: spans),
      );
    } else {
      _emitChunkedSpansWithCallback(
        plainText,
        spans,
        sectionName,
        _committedAnsi.maxLineLength,
        _addCommittedLine,
      );
    }
  }

  void _addCommittedLine(JobTraceLine line) {
    _totalCommittedLines++;
    _appendBufferedLine(line);
  }

  void _appendBufferedLine(JobTraceLine line) {
    if (_blocks.isEmpty || _blocks.last.length == _blockSize) {
      _blocks.add(<JobTraceLine>[]);
    }
    _blocks.last.add(line);
    _bufferedLineCount++;
    _committedLinesBytes += line.estimatedBytes;
  }

  void _evictCommittedLinesIfNeeded() {
    final overflow = _bufferedLineCount - maxLines;
    if (overflow <= 0) return;
    var toDrop = overflow;
    while (toDrop > 0 && _blocks.isNotEmpty) {
      final first = _blocks.first;
      final availInFirst = first.length - _firstBlockOffset;
      if (toDrop >= availInFirst) {
        for (var i = _firstBlockOffset; i < first.length; i++) {
          _committedLinesBytes -= first[i].estimatedBytes;
        }
        _blocks.removeAt(0);
        _firstBlockOffset = 0;
        _bufferedLineCount -= availInFirst;
        toDrop -= availInFirst;
      } else {
        for (var i = _firstBlockOffset; i < _firstBlockOffset + toDrop; i++) {
          _committedLinesBytes -= first[i].estimatedBytes;
        }
        _firstBlockOffset += toDrop;
        _bufferedLineCount -= toDrop;
        toDrop = 0;
      }
    }
  }

  void _addCommittedSection(JobTraceSection section) {
    _committedSections.add(section);
    _committedSectionsBytes += section.estimatedBytes;
    _totalCommittedSections++;
  }

  void _evictCommittedSectionsIfNeeded() {
    final windowStart = _globalWindowStart;
    if (windowStart <= 0) return;
    while (_committedSections.isNotEmpty) {
      final first = _committedSections.first;
      if (first.startLine < windowStart && first.endLine <= windowStart) {
        _committedSectionsBytes -= first.estimatedBytes;
        _committedSections.removeAt(0);
      } else {
        break;
      }
    }
  }

  /// Returns the current [JobTrace] without mutating parser state.
  JobTrace snapshot() {
    final cached = _cachedSnapshot;
    if (cached != null) return cached;

    final List<String> uncommittedRawLines;
    if (_timestampsEnabled == null) {
      uncommittedRawLines = <String>[_initialBuffer.toString()];
    } else if (_timestampsEnabled == true && _newlinePending) {
      uncommittedRawLines = <String>[
        _currentLogicalLine.toString(),
        _pendingPhysicalHeader,
      ];
    } else {
      uncommittedRawLines = <String>[_currentLogicalLine.toString()];
    }

    if (_totalCommittedLines == 0 &&
        _committedSections.isEmpty &&
        _committedStack.isEmpty &&
        uncommittedRawLines.length == 1) {
      final single = uncommittedRawLines.first;
      if (single.isEmpty || single.replaceAll(JobTrace._ansi, '').isEmpty) {
        if (single.isNotEmpty) {
          _spanCharactersProcessed += single.length;
          if (!_inBackgroundIsolate) {
            JobTrace.debugCharactersProcessed += single.length;
          }
        }
        final emptyResult = JobTrace(
          ansiStripped: '',
          lines: const <JobTraceLine>[],
          sections: const <JobTraceSection>[],
          charactersProcessed: _charactersProcessed,
          estimatedBytes: _rawBuffersEstimatedBytes,
        );
        _cachedSnapshot = emptyResult;
        return emptyResult;
      }
    }

    final previewAnsi = _committedAnsi.copy();
    final previewStack = List<_OpenSection>.of(_committedStack);
    final previewLines = <JobTraceLine>[];
    final previewClosedSections = <JobTraceSection>[];

    for (var rawLine in uncommittedRawLines) {
      if (rawLine.endsWith('\r')) {
        rawLine = rawLine.substring(0, rawLine.length - 1);
      }
      _parsePreviewLine(
        rawLine,
        previewAnsi: previewAnsi,
        previewStack: previewStack,
        previewLines: previewLines,
        previewClosedSections: previewClosedSections,
      );
    }

    final totalAbsLines = _totalCommittedLines + previewLines.length;
    while (previewStack.isNotEmpty) {
      _close(
        previewStack.removeLast(),
        null,
        totalAbsLines,
        previewClosedSections,
      );
    }

    if (totalAbsLines == 0 &&
        _committedSections.isEmpty &&
        previewClosedSections.isEmpty) {
      final emptyResult = JobTrace(
        ansiStripped: '',
        lines: const <JobTraceLine>[],
        sections: const <JobTraceSection>[],
        charactersProcessed: _charactersProcessed,
        estimatedBytes: _rawBuffersEstimatedBytes,
      );
      _cachedSnapshot = emptyResult;
      return emptyResult;
    }

    final truncated = totalAbsLines > maxLines;
    final effectiveWindowStart = truncated ? totalAbsLines - maxLines : 0;

    final List<JobTraceLine> windowLines;
    var windowLinesBytes = 0;
    if (previewLines.length >= maxLines) {
      final tailSlice = previewLines.sublist(previewLines.length - maxLines);
      for (final line in tailSlice) {
        windowLinesBytes += line.estimatedBytes;
      }
      windowLines = List<JobTraceLine>.unmodifiable(tailSlice);
    } else {
      final firstBuffered = _firstBufferedLineIndex;
      final skipInBuffered = effectiveWindowStart > firstBuffered
          ? effectiveWindowStart - firstBuffered
          : 0;
      final committedShown = _bufferedLineCount - skipInBuffered;
      windowLinesBytes = _committedLinesBytes;
      if (skipInBuffered > 0 && _blocks.isNotEmpty) {
        var remainingSkip = skipInBuffered;
        var bIdx = 0;
        var offset = _firstBlockOffset;
        while (remainingSkip > 0 && bIdx < _blocks.length) {
          final block = _blocks[bIdx];
          final avail = block.length - offset;
          final take = remainingSkip < avail ? remainingSkip : avail;
          for (var i = offset; i < offset + take; i++) {
            windowLinesBytes -= block[i].estimatedBytes;
          }
          remainingSkip -= take;
          bIdx++;
          offset = 0;
        }
      }
      for (final line in previewLines) {
        windowLinesBytes += line.estimatedBytes;
      }
      windowLines = _WindowedLineList(
        blocks: List<List<JobTraceLine>>.of(_blocks),
        firstBlockOffset: _firstBlockOffset + skipInBuffered,
        committedCount: committedShown,
        tail: previewLines,
      );
    }

    final windowSections = <JobTraceSection>[];
    var windowSectionsBytes = 0;
    for (final section in _committedSections) {
      if (effectiveWindowStart > 0 &&
          section.startLine < effectiveWindowStart &&
          section.endLine <= effectiveWindowStart) {
        continue;
      }
      final shifted = effectiveWindowStart > 0
          ? section.shift(effectiveWindowStart)
          : section;
      windowSections.add(shifted);
      windowSectionsBytes += shifted.estimatedBytes;
    }
    for (final section in previewClosedSections) {
      if (effectiveWindowStart > 0 &&
          section.startLine < effectiveWindowStart &&
          section.endLine <= effectiveWindowStart) {
        continue;
      }
      final shifted = effectiveWindowStart > 0
          ? section.shift(effectiveWindowStart)
          : section;
      windowSections.add(shifted);
      windowSectionsBytes += shifted.estimatedBytes;
    }

    final result = JobTrace(
      lines: windowLines,
      sections: List<JobTraceSection>.unmodifiable(windowSections),
      truncated: truncated,
      windowStart: effectiveWindowStart,
      charactersProcessed: _charactersProcessed,
      estimatedBytes:
          windowLinesBytes + windowSectionsBytes + _rawBuffersEstimatedBytes,
    );
    _cachedSnapshot = result;
    return result;
  }

  void _parsePreviewLine(
    String line, {
    required AnsiStateMachine previewAnsi,
    required List<_OpenSection> previewStack,
    required List<JobTraceLine> previewLines,
    required List<JobTraceSection> previewClosedSections,
  }) {
    var cursor = 0;
    var sawMarker = false;
    for (final match in JobTrace._marker.allMatches(line)) {
      sawMarker = true;
      final before = line.substring(cursor, match.start);
      if (before.isNotEmpty) {
        _emitPreviewSegment(
          before,
          previewAnsi: previewAnsi,
          previewStack: previewStack,
          previewLines: previewLines,
          allowEmpty: false,
        );
      }
      _applyMarkerCounted(
        match,
        currentLineCount: _totalCommittedLines + previewLines.length,
        currentSectionCount:
            _totalCommittedSections + previewClosedSections.length,
        stack: previewStack,
        onClose: previewClosedSections.add,
      );
      cursor = match.end;
    }
    final rest = line.substring(cursor);
    if (!sawMarker || rest.isNotEmpty) {
      _emitPreviewSegment(
        rest,
        previewAnsi: previewAnsi,
        previewStack: previewStack,
        previewLines: previewLines,
        allowEmpty: !sawMarker,
      );
    }
  }

  void _emitPreviewSegment(
    String rawText, {
    required AnsiStateMachine previewAnsi,
    required List<_OpenSection> previewStack,
    required List<JobTraceLine> previewLines,
    required bool allowEmpty,
  }) {
    _spanCharactersProcessed += rawText.length;
    if (!_inBackgroundIsolate) {
      JobTrace.debugCharactersProcessed += rawText.length;
    }
    final spans = previewAnsi.parseSpans(rawText);
    final plainText = spans.isEmpty ? '' : spans.map((s) => s.text).join();
    if (plainText.isEmpty) {
      if (!allowEmpty) return;
      previewLines.add(
        JobTraceLine(
          '',
          lowerText: '',
          section: previewStack.isEmpty ? null : previewStack.last.name,
        ),
      );
      return;
    }
    final sectionName = previewStack.isEmpty ? null : previewStack.last.name;
    if (plainText.length <= previewAnsi.maxLineLength) {
      previewLines.add(
        JobTraceLine(plainText, section: sectionName, spans: spans),
      );
    } else {
      _emitChunkedSpansWithCallback(
        plainText,
        spans,
        sectionName,
        previewAnsi.maxLineLength,
        previewLines.add,
      );
    }
  }
}

final class _WindowedLineList extends ListBase<JobTraceLine> {
  _WindowedLineList({
    required List<List<JobTraceLine>> blocks,
    required int firstBlockOffset,
    required int committedCount,
    required List<JobTraceLine> tail,
  })  : _blocks = blocks,
        _firstBlockOffset = firstBlockOffset,
        _committedCount = committedCount,
        _tail = tail;

  final List<List<JobTraceLine>> _blocks;
  final int _firstBlockOffset;
  final int _committedCount;
  final List<JobTraceLine> _tail;

  @override
  int get length => _committedCount + _tail.length;

  @override
  set length(int newLength) =>
      throw UnsupportedError('Cannot modify an unmodifiable JobTraceLine list');

  @override
  JobTraceLine operator [](int index) {
    RangeError.checkValidIndex(index, this);
    if (index >= _committedCount) {
      return _tail[index - _committedCount];
    }
    final offset = _firstBlockOffset + index;
    final blockIndex = offset ~/ JobTraceParser._blockSize;
    final inBlock = offset % JobTraceParser._blockSize;
    return _blocks[blockIndex][inBlock];
  }

  @override
  void operator []=(int index, JobTraceLine value) =>
      throw UnsupportedError('Cannot modify an unmodifiable JobTraceLine list');
}

Uint8List _computeNextUtf8Carry(
  Uint8List prevCarry,
  List<int> bytes, {
  required bool isLast,
}) {
  if (isLast) return Uint8List(0);
  if (bytes.isEmpty) return prevCarry;
  final totalLen = prevCarry.length + bytes.length;
  final tailLen = totalLen < 3 ? totalLen : 3;
  final tail = Uint8List(tailLen);
  for (var i = 0; i < tailLen; i++) {
    final srcIdx = totalLen - tailLen + i;
    tail[i] = srcIdx < prevCarry.length
        ? prevCarry[srcIdx]
        : bytes[srcIdx - prevCarry.length];
  }
  var leadPos = -1;
  for (var i = tailLen - 1; i >= 0; i--) {
    final b = tail[i];
    if ((b & 0xC0) != 0x80) {
      leadPos = i;
      break;
    }
  }
  if (leadPos < 0) return Uint8List(0);
  final lead = tail[leadPos];
  if (lead < 0xC2 || lead > 0xF4) return Uint8List(0);
  final candidate = Uint8List.sublistView(tail, leadPos);
  var emitted = false;
  const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(
        _ImmediateStringSink((chunk) {
          if (chunk.isNotEmpty) emitted = true;
        }),
      )
      .add(candidate);
  return emitted ? Uint8List(0) : Uint8List.fromList(candidate);
}

final class _ImmediateStringSink extends StringConversionSinkBase {
  _ImmediateStringSink(this._onChunk);

  final void Function(String chunk) _onChunk;

  @override
  void add(String str) {
    if (str.isNotEmpty) _onChunk(str);
  }

  @override
  void addSlice(String str, int start, int end, bool isLast) {
    if (end > start) {
      _onChunk(str.substring(start, end));
    }
  }

  @override
  void close() {}
}

final class _IsolateParseRequest {
  const _IsolateParseRequest({
    required this.bytes,
    required this.isLast,
    required this.maxLines,
    required this.utf8Carry,
    required this.ansi,
    required this.stack,
    required this.totalCommittedLines,
    required this.totalCommittedSections,
    required this.committedSections,
    required this.timestampsEnabled,
    required this.initialBuffer,
    required this.inPhysicalHeader,
    required this.newlinePending,
    required this.pendingPhysicalHeader,
    required this.currentLogicalLine,
  });

  final Uint8List bytes;
  final bool isLast;
  final int maxLines;
  final Uint8List utf8Carry;
  final AnsiStateMachine ansi;
  final List<_OpenSection> stack;
  final int totalCommittedLines;
  final int totalCommittedSections;
  final List<JobTraceSection> committedSections;
  final bool? timestampsEnabled;
  final String initialBuffer;
  final bool inPhysicalHeader;
  final bool newlinePending;
  final String pendingPhysicalHeader;
  final String currentLogicalLine;
}

final class _IsolateParseResult {
  const _IsolateParseResult({
    required this.charsProcessed,
    required this.spanCharsProcessed,
    required this.utf8Carry,
    required this.ansi,
    required this.stack,
    required this.totalCommittedLines,
    required this.totalCommittedSections,
    required this.newCommittedLines,
    required this.discardExistingCommittedLines,
    required this.committedSections,
    required this.committedSectionsBytes,
    required this.timestampsEnabled,
    required this.initialBuffer,
    required this.inPhysicalHeader,
    required this.newlinePending,
    required this.pendingPhysicalHeader,
    required this.currentLogicalLine,
  });

  final int charsProcessed;
  final int spanCharsProcessed;
  final Uint8List utf8Carry;
  final AnsiStateMachine ansi;
  final List<_OpenSection> stack;
  final int totalCommittedLines;
  final int totalCommittedSections;
  final List<JobTraceLine> newCommittedLines;
  final bool discardExistingCommittedLines;
  final List<JobTraceSection> committedSections;
  final int committedSectionsBytes;
  final bool? timestampsEnabled;
  final String initialBuffer;
  final bool inPhysicalHeader;
  final bool newlinePending;
  final String pendingPhysicalHeader;
  final String currentLogicalLine;
}

_IsolateParseResult _parseChunkInIsolate(_IsolateParseRequest req) {
  final parser = JobTraceParser._fromCarryState(req);
  if (req.bytes.isNotEmpty) {
    parser._utf8Sink.add(req.bytes);
    parser._utf8Carry = _computeNextUtf8Carry(
      parser._utf8Carry,
      req.bytes,
      isLast: req.isLast,
    );
  }
  if (req.isLast) {
    parser._utf8Sink.close();
    parser._utf8Carry = Uint8List(0);
  }
  final newLines = <JobTraceLine>[];
  for (var b = 0; b < parser._blocks.length; b++) {
    final block = parser._blocks[b];
    final start = b == 0 ? parser._firstBlockOffset : 0;
    for (var i = start; i < block.length; i++) {
      newLines.add(block[i]);
    }
  }
  final producedCount = parser._totalCommittedLines - req.totalCommittedLines;
  return _IsolateParseResult(
    charsProcessed: parser._charactersProcessed,
    spanCharsProcessed: parser._spanCharactersProcessed,
    utf8Carry: parser._utf8Carry,
    ansi: parser._committedAnsi,
    stack: parser._committedStack,
    totalCommittedLines: parser._totalCommittedLines,
    totalCommittedSections: parser._totalCommittedSections,
    newCommittedLines: newLines,
    discardExistingCommittedLines: producedCount >= req.maxLines,
    committedSections: parser._committedSections,
    committedSectionsBytes: parser._committedSectionsBytes,
    timestampsEnabled: parser._timestampsEnabled,
    initialBuffer: parser._initialBuffer.toString(),
    inPhysicalHeader: parser._inPhysicalHeader,
    newlinePending: parser._newlinePending,
    pendingPhysicalHeader: parser._pendingPhysicalHeader,
    currentLogicalLine: parser._currentLogicalLine.toString(),
  );
}

/// [trace] without the runner's timestamp headers, with continued lines joined
/// back, as GitLab's own log view shows it.
String _withoutTimestamps(String trace) {
  if (JobTrace._timestampHeader.matchAsPrefix(trace) == null) return trace;
  final out = StringBuffer();
  var start = 0;
  var newlinePending = false;
  while (start < trace.length) {
    final newline = trace.indexOf('\n', start);
    final end = newline < 0 ? trace.length : newline;
    final header = JobTrace._timestampHeader.matchAsPrefix(trace, start) != null;
    final continued = header &&
        trace.codeUnitAt(start + JobTrace._timestampHeaderLength - 1) == 0x2B;
    if (newlinePending && !continued) out.writeCharCode(0x0A);
    out.write(trace.substring(header ? start + JobTrace._timestampHeaderLength : start, end));
    newlinePending = newline >= 0;
    start = end + 1;
  }
  if (newlinePending) out.writeCharCode(0x0A);
  return out.toString();
}

final class JobTraceLine {
  JobTraceLine(
    this.text, {
    String? lowerText,
    this.section,
    this.spans = const <AnsiSpan>[],
  }) : lowerText = lowerText ?? text.toLowerCase();

  /// Plain text with ANSI sequences and section markers removed.
  final String text;

  /// Lowercase copy of [text] built incrementally when the line is created.
  final String lowerText;

  /// Innermost open section name, when this line is inside one.
  final String? section;

  /// Styled ANSI segments for this line.
  final List<AnsiSpan> spans;

  /// Approximate heap footprint in bytes for bounded-memory checks.
  int get estimatedBytes =>
      64 + (text.length + lowerText.length) * 2 + spans.length * 48;

  /// Builds a Flutter InlineSpan (TextSpan) for rendering in Text.rich.
  InlineSpan toInlineSpan({
    required Brightness brightness,
    TextStyle? baseStyle,
  }) {
    if (spans.isEmpty) {
      return TextSpan(text: text.isEmpty ? ' ' : text, style: baseStyle);
    }
    if (spans.length == 1 && spans.first.style.isPlain) {
      final t = spans.first.text;
      return TextSpan(text: t.isEmpty ? ' ' : t, style: baseStyle);
    }
    return TextSpan(
      style: baseStyle,
      children: [
        for (final span in spans)
          span.toTextSpan(brightness: brightness, baseStyle: baseStyle),
      ],
    );
  }
}

final class JobTraceSection {
  const JobTraceSection({
    required this.name,
    required this.start,
    required this.end,
    required this.collapsed,
    required this.startLine,
    required this.endLine,
    required this.depth,
  });

  final String name;
  final int start;
  final int? end;
  final bool collapsed;

  /// Inclusive start and exclusive end into [JobTrace.lines].
  final int startLine;
  final int endLine;
  final int depth;

  String get label => name.replaceAll(RegExp(r'[_-]+'), ' ').trim();

  int? get durationSeconds {
    final finished = end;
    if (finished == null || finished < start) return null;
    return finished - start;
  }

  /// Approximate heap footprint in bytes for bounded-memory checks.
  int get estimatedBytes => 64 + name.length * 2;

  /// Shifts line indices by [windowStart], clamping [startLine] to `0` when the
  /// section began before the sliding window.
  JobTraceSection shift(int windowStart) {
    if (windowStart <= 0) return this;
    return JobTraceSection(
      name: name,
      start: start,
      end: end,
      collapsed: collapsed,
      startLine: startLine <= windowStart ? 0 : startLine - windowStart,
      endLine: endLine <= windowStart ? 0 : endLine - windowStart,
      depth: depth,
    );
  }
}

final class _OpenSection {
  const _OpenSection({
    required this.name,
    required this.start,
    required this.collapsed,
    required this.startLine,
    required this.depth,
  });
  final String name;
  final int start;
  final bool collapsed;
  final int startLine;
  final int depth;
}

void _takeLine(
  String line,
  List<JobTraceLine> lines,
  List<JobTraceSection> sections,
  List<_OpenSection> stack,
  AnsiStateMachine stateMachine,
  int maxLines,
) {
  var cursor = 0;
  var sawMarker = false;
  for (final match in JobTrace._marker.allMatches(line)) {
    sawMarker = true;
    final before = line.substring(cursor, match.start);
    if (before.isNotEmpty) {
      _emitSegment(before, lines, stack, stateMachine, maxLines, allowEmpty: false);
    }
    _applyMarker(match, lines, sections, stack);
    cursor = match.end;
  }
  final rest = line.substring(cursor);
  if (!sawMarker || rest.isNotEmpty) {
    _emitSegment(rest, lines, stack, stateMachine, maxLines, allowEmpty: !sawMarker);
  }
}

void _emitSegment(
  String rawText,
  List<JobTraceLine> lines,
  List<_OpenSection> stack,
  AnsiStateMachine stateMachine,
  int maxLines, {
  required bool allowEmpty,
}) {
  JobTrace.debugCharactersProcessed += rawText.length;
  final spans = stateMachine.parseSpans(rawText);
  final plainText = spans.isEmpty ? '' : spans.map((s) => s.text).join();
  if (plainText.isEmpty) {
    if (!allowEmpty) return;
    if (lines.length >= maxLines) throw const ApiFailure(FailureKind.tooLarge);
    lines.add(JobTraceLine('', lowerText: '', section: stack.isEmpty ? null : stack.last.name));
    return;
  }

  final sectionName = stack.isEmpty ? null : stack.last.name;
  if (plainText.length <= stateMachine.maxLineLength) {
    if (lines.length >= maxLines) throw const ApiFailure(FailureKind.tooLarge);
    lines.add(JobTraceLine(plainText, section: sectionName, spans: spans));
  } else {
    _emitChunkedSpans(plainText, spans, sectionName, lines, maxLines, stateMachine.maxLineLength);
  }
}

void _emitChunkedSpans(
  String plainText,
  List<AnsiSpan> spans,
  String? sectionName,
  List<JobTraceLine> lines,
  int maxLines,
  int maxLineLength,
) {
  _emitChunkedSpansWithCallback(
    plainText,
    spans,
    sectionName,
    maxLineLength,
    (line) {
      if (lines.length >= maxLines) throw const ApiFailure(FailureKind.tooLarge);
      lines.add(line);
    },
  );
}

void _emitChunkedSpansWithCallback(
  String plainText,
  List<AnsiSpan> spans,
  String? sectionName,
  int maxLineLength,
  void Function(JobTraceLine line) onLine,
) {
  var charIndex = 0;
  var spanIndex = 0;
  var spanCharOffset = 0;

  while (charIndex < plainText.length) {
    final chunkEnd = (charIndex + maxLineLength < plainText.length)
        ? charIndex + maxLineLength
        : plainText.length;
    final chunkText = plainText.substring(charIndex, chunkEnd);
    final chunkSpans = <AnsiSpan>[];
    var chunkRemaining = chunkText.length;

    while (spanIndex < spans.length && chunkRemaining > 0) {
      final currentSpan = spans[spanIndex];
      final spanAvail = currentSpan.text.length - spanCharOffset;
      if (spanAvail <= chunkRemaining) {
        final slice = currentSpan.text.substring(spanCharOffset);
        if (slice.isNotEmpty) {
          chunkSpans.add(AnsiSpan(slice, currentSpan.style));
        }
        chunkRemaining -= spanAvail;
        spanIndex++;
        spanCharOffset = 0;
      } else {
        final slice = currentSpan.text.substring(
          spanCharOffset,
          spanCharOffset + chunkRemaining,
        );
        chunkSpans.add(AnsiSpan(slice, currentSpan.style));
        spanCharOffset += chunkRemaining;
        chunkRemaining = 0;
      }
    }

    onLine(JobTraceLine(chunkText, section: sectionName, spans: chunkSpans));
    charIndex = chunkEnd;
  }
}

void _applyMarker(
  RegExpMatch match,
  List<JobTraceLine> lines,
  List<JobTraceSection> sections,
  List<_OpenSection> stack,
) {
  _applyMarkerCounted(
    match,
    currentLineCount: lines.length,
    currentSectionCount: sections.length,
    stack: stack,
    onClose: sections.add,
  );
}

void _applyMarkerCounted(
  RegExpMatch match, {
  required int currentLineCount,
  required int currentSectionCount,
  required List<_OpenSection> stack,
  required void Function(JobTraceSection section) onClose,
}) {
  final kind = match.group(1)!;
  final timestamp = int.parse(match.group(2)!);
  final name = match.group(3)!;
  if (kind == 'start') {
    if (stack.length >= JobTrace.maxDepth ||
        currentSectionCount + stack.length >= JobTrace.maxSections) {
      return;
    }
    stack.add(
      _OpenSection(
        name: name,
        start: timestamp,
        collapsed: match.group(4) == 'true',
        startLine: currentLineCount,
        depth: stack.length,
      ),
    );
    return;
  }
  final index = stack.lastIndexWhere((section) => section.name == name);
  if (index < 0) return;
  while (stack.length - 1 > index) {
    final open = stack.removeLast();
    onClose(
      JobTraceSection(
        name: open.name,
        start: open.start,
        end: null,
        collapsed: open.collapsed,
        startLine: open.startLine,
        endLine: currentLineCount,
        depth: open.depth,
      ),
    );
  }
  final open = stack.removeLast();
  onClose(
    JobTraceSection(
      name: open.name,
      start: open.start,
      end: timestamp,
      collapsed: open.collapsed,
      startLine: open.startLine,
      endLine: currentLineCount,
      depth: open.depth,
    ),
  );
}

void _close(
  _OpenSection open,
  int? end,
  int endLine,
  List<JobTraceSection> sections,
) {
  sections.add(
    JobTraceSection(
      name: open.name,
      start: open.start,
      end: end,
      collapsed: open.collapsed,
      startLine: open.startLine,
      endLine: endLine,
      depth: open.depth,
    ),
  );
}
