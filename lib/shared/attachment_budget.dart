import 'dart:async';
import 'dart:typed_data';

import 'attachment_ref.dart';

/// Page-wide cap for Markdown upload previews.
///
/// One budget is shared by every image in a [MarkdownView]. A parent can pass
/// the same instance into several views so the whole page shares the cap.
final class AttachmentBudget {
  AttachmentBudget({
    this.maxImages = 20,
    this.maxTotalBytes = 24 * 1024 * 1024,
    this.maxConcurrent = 2,
  }) : assert(maxImages > 0),
       assert(maxTotalBytes > 0),
       assert(maxConcurrent > 0);

  final int maxImages;
  final int maxTotalBytes;
  final int maxConcurrent;

  /// In-flight and finished fetches, including failures. A failed entry stays
  /// until [evict] so a rebuild does not retry on its own.
  final Map<ProjectUploadRef, Future<Uint8List>> requests = {};

  final Map<ProjectUploadRef, Uint8List> _bytes = {};
  int _shown = 0;
  int _usedBytes = 0;
  int _inFlight = 0;
  int _turn = 0;
  int _accountedTurn = 0;
  final List<Completer<void>> _waiters = [];
  final Map<int, Completer<void>> _turns = {};

  /// False once this page already has [maxImages] previews.
  bool claimImage() {
    if (_shown >= maxImages) return false;
    _shown++;
    return true;
  }

  Uint8List? cachedBytes(ProjectUploadRef ref) => _bytes[ref];

  void evict(ProjectUploadRef ref) {
    requests.remove(ref);
    final removed = _bytes.remove(ref);
    if (removed == null) return;
    _usedBytes -= removed.length;
    if (_usedBytes < 0) _usedBytes = 0;
  }

  Future<Uint8List> fetch(ProjectUploadRef ref, Future<Uint8List> Function() load) {
    final pending = requests[ref];
    if (pending != null) return pending;
    final future = _load(ref, load);
    requests[ref] = future;
    return future;
  }

  Future<Uint8List> _load(ProjectUploadRef ref, Future<Uint8List> Function() load) async {
    final turn = _turn++;
    await _enter();
    try {
      if (turn == _accountedTurn && _usedBytes >= maxTotalBytes) {
        _finishTurn(turn);
        throw const AttachmentBudgetExceeded();
      }
      Object? error;
      StackTrace? stack;
      Uint8List? bytes;
      try {
        bytes = await load();
      } catch (caught, caughtStack) {
        error = caught;
        stack = caughtStack;
      }
      await _waitTurn(turn);
      try {
        if (error != null) {
          Error.throwWithStackTrace(error, stack ?? StackTrace.empty);
        }
        final data = bytes;
        if (data == null) {
          throw StateError('upload produced no bytes');
        }
        if (_usedBytes + data.length > maxTotalBytes) {
          _usedBytes += data.length;
          throw const AttachmentBudgetExceeded();
        }
        _usedBytes += data.length;
        _bytes[ref] = data;
        return data;
      } finally {
        _finishTurn(turn);
      }
    } finally {
      _leave();
    }
  }

  Future<void> _enter() {
    if (_inFlight < maxConcurrent) {
      _inFlight++;
      return Future<void>.value();
    }
    final gate = Completer<void>();
    _waiters.add(gate);
    return gate.future;
  }

  void _leave() {
    final next = _waiters.isEmpty ? null : _waiters.removeAt(0);
    if (next != null) {
      if (!next.isCompleted) next.complete();
      return;
    }
    _inFlight--;
  }

  Future<void> _waitTurn(int turn) {
    if (turn <= _accountedTurn) return Future<void>.value();
    final gate = _turns.putIfAbsent(turn, Completer<void>.new);
    return gate.future;
  }

  void _finishTurn(int turn) {
    if (turn != _accountedTurn) return;
    _accountedTurn++;
    final next = _turns.remove(_accountedTurn);
    if (next != null && !next.isCompleted) next.complete();
  }
}

/// The next image would push the page past [AttachmentBudget.maxTotalBytes].
final class AttachmentBudgetExceeded implements Exception {
  const AttachmentBudgetExceeded();
}
