import 'dart:async';
import 'dart:typed_data';

/// Page-wide cap for Markdown image previews.
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
  final Map<Object, Future<Uint8List>> requests = {};

  final Map<Object, Uint8List> _bytes = {};
  final Set<Object> _slots = {};
  int _usedBytes = 0;
  int _inFlight = 0;
  final List<Completer<void>> _waiters = [];

  /// False once this page already previews [maxImages] distinct uploads.
  /// A reference that already holds a slot keeps it, so a preview that is
  /// rebuilt or remounted (a collapsed thread reopening) is not counted again.
  bool claimImage(Object ref) {
    if (_slots.contains(ref)) return true;
    if (_slots.length >= maxImages) return false;
    _slots.add(ref);
    return true;
  }

  Uint8List? cachedBytes(Object ref) => _bytes[ref];

  void evict(Object ref) {
    requests.remove(ref);
    final removed = _bytes.remove(ref);
    if (removed == null) return;
    _usedBytes -= removed.length;
    if (_usedBytes < 0) _usedBytes = 0;
  }

  Future<Uint8List> fetch(Object ref, Future<Uint8List> Function() load) {
    final pending = requests[ref];
    if (pending != null) return pending;
    final future = _load(ref, load);
    requests[ref] = future;
    return future;
  }

  Future<Uint8List> _load(Object ref, Future<Uint8List> Function() load) async {
    await _enter();
    try {
      if (_usedBytes >= maxTotalBytes) {
        throw const AttachmentBudgetExceeded();
      }
      final data = await load();
      // A payload that does not fit is dropped and not charged, so later
      // images that still fit are not refused for bytes nobody holds.
      if (_usedBytes + data.length > maxTotalBytes) {
        throw const AttachmentBudgetExceeded();
      }
      _usedBytes += data.length;
      _bytes[ref] = data;
      return data;
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
}

/// The next image would push the page past [AttachmentBudget.maxTotalBytes].
final class AttachmentBudgetExceeded implements Exception {
  const AttachmentBudgetExceeded();
}
