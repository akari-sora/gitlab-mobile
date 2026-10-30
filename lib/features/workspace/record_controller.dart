import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/failure.dart';

typedef RecordLoader = Future<ApiPage<Json>> Function(Uri? next);
typedef CachedRecordLoader = Future<CachedRead<ApiPage<Json>>> Function({
  required bool fresh,
  required bool background,
});

class RecordController extends ChangeNotifier {
  RecordController(this.loader, {this.cached});
  RecordLoader loader;
  CachedRecordLoader? cached;
  List<Json> items = [];
  Uri? next;
  ApiFailure? error;
  DateTime? fetchedAt;
  bool stale = false, revalidating = false;
  FailureKind? backgroundFailure;

  /// When a rate-limited background read may be retried, if GitLab said.
  DateTime? backgroundRetryAt;
  bool loading = false, loadingMore = false, failedMore = false;
  bool _disposed = false, _backgroundEnabled = true;
  int _generation = 0;
  int _loadedPages = 0;
  bool get hasLoaded => _loadedPages > 0 || items.isNotEmpty;
  bool _failedReconcile = false;
  bool _resumeWhenVisible = false;
  Future<void>? _revalidation;
  final Set<String> _seenCursors = {};
  bool _current(int generation) => !_disposed && generation == _generation;
  void _emit() { if (!_disposed) { notifyListeners(); } }
  Future<void> retry() => _failedReconcile ? reconcileLoadedWindow() : failedMore ? more() : refresh(fresh: cached != null);

  void setBackgroundEnabled(bool enabled) {
    if (enabled == _backgroundEnabled) return;
    _backgroundEnabled = enabled;
    if (!enabled && revalidating) {
      _resumeWhenVisible = true;
    }
    if (enabled) {
      _resumeIfVisible();
      _startRevalidation(_generation, _loadedPages);
    }
  }

  int _begin() {
    final generation = ++_generation;
    loading = true; loadingMore = false; failedMore = false;
    _failedReconcile = false; error = null; backgroundFailure = null;
    backgroundRetryAt = null;
    revalidating = false; _revalidation = null;
    _resumeWhenVisible = false;
    _emit();
    return generation;
  }

  // After one bounded retry, let the cache's existing write-quiet barrier
  // precede one final read. Sustained writes leave an explicit retry notice.
  Future<CachedRead<ApiPage<Json>>?> _readCached(
    int generation, {required bool fresh, required bool background}
  ) async {
    final source = cached!;
    Future<CachedRead<ApiPage<Json>>> readPage({
      required bool fresh, bool quiet = false,
    }) => CachedRead.run(
      () => source(fresh: fresh, background: background),
      mayStart: () => background ? _canContinue(generation) : _current(generation),
      waitForQuiet: quiet,
    );
    var read = await readPage(fresh: fresh);
    if (!_current(generation)) return null;
    if (background && !_backgroundEnabled) {
      stale = true; _resumeWhenVisible = true;
      return null;
    }
    if (read.superseded) {
      read = await readPage(fresh: true);
      if (!_current(generation)) return null;
      if (background && !_backgroundEnabled) {
        stale = true; _resumeWhenVisible = true;
        return null;
      }
      if (read.superseded) {
        read = await readPage(fresh: true, quiet: true);
        if (!_current(generation)) return null;
        if (background && !_backgroundEnabled) {
          stale = true; _resumeWhenVisible = true;
          return null;
        }
      }
      if (read.superseded) throw const ApiFailure(FailureKind.cancelled);
    }
    return read.dropped ? null : read;
  }

  void _applyFirst(ApiPage<Json> page) {
    items = page.items; next = page.next; _loadedPages = 1;
    _seenCursors.clear();
  }

  void _withdraw() {
    items = []; next = null; _loadedPages = 0; _seenCursors.clear();
    fetchedAt = null; stale = false;
  }

  bool _revoked(ApiFailure failure) => switch (failure.kind) {
    FailureKind.unauthenticated || FailureKind.forbidden || FailureKind.invisible => true,
    _ => false,
  };

  Future<void> refresh({bool fresh = false, bool reset = false}) async {
    if (_disposed) return;
    if (reset) _withdraw();
    final targetPages = fresh ? 1 : _loadedPages;
    final generation = _begin();
    try {
      if (cached == null) {
        if (!_current(generation)) return;
        final page = await loader(null);
        if (!_current(generation)) return;
        _applyFirst(page);
        stale = false;
      } else {
        final read = await _readCached(generation, fresh: fresh, background: false);
        if (!_current(generation)) return;
        if (read == null) {
          if (items.isEmpty) {
            error = const ApiFailure(FailureKind.cancelled);
          }
          return;
        }
        if (targetPages > 1) {
          // Keep the complete old window until its replacement is ready.
          if (!read.stale) {
            if (!await _reconcileLoadedWindow(generation, targetPages, read.value)) return;
          }
        } else {
          _applyFirst(read.value);
        }
        if (targetPages <= 1 || !read.stale) fetchedAt = read.fetchedAt;
        stale = read.stale;
        loading = false; _emit();
        _startRevalidation(generation, targetPages);
      }
    } catch (e) {
      if (_current(generation)) {
        error = safeFailure(e);
        if (cached != null && _revoked(error!)) _withdraw();
      }
    } finally {
      if (_current(generation)) { loading = false; _emit(); _resumeIfVisible(); }
    }
  }

  void _startRevalidation(int generation, int targetPages) {
    if (!_current(generation) || !_backgroundEnabled || loading || loadingMore || cached == null ||
        !stale || revalidating || backgroundFailure != null) { return; }
    revalidating = true;
    _resumeWhenVisible = false;
    _revalidation = _revalidate(generation, targetPages);
    unawaited(_revalidation);
    _emit();
  }

  Future<void> _revalidate(int generation, int targetPages) async {
    try {
      final read = await _readCached(generation, fresh: true, background: true);
      if (!_current(generation) || read == null) return;
      if (targetPages > 1) {
        if (!read.stale) {
          if (!await _reconcileLoadedWindow(generation, targetPages, read.value, background: true)) return;
        }
      } else {
        _applyFirst(read.value);
      }
      if (targetPages <= 1 || !read.stale) fetchedAt = read.fetchedAt;
      stale = read.stale;
    } catch (e) {
      if (_current(generation)) {
        final failure = safeFailure(e);
        if (_revoked(failure)) {
          _withdraw(); error = failure;
        } else if (!_backgroundEnabled) {
          stale = true; _resumeWhenVisible = true;
        } else {
          backgroundFailure = failure.kind; backgroundRetryAt = failure.retryAt;
        }
      }
    } finally {
      if (_current(generation)) {
        revalidating = false; _revalidation = null; _emit(); _resumeIfVisible();
      }
    }
  }

  Future<void> more() async {
    final generation = _generation;
    if (!_current(generation) || loading || loadingMore) return;
    final pending = _revalidation;
    if (pending != null) {
      await pending;
      if (!_current(generation)) return;
    }
    if (loading || loadingMore ||
        (next == null && !(cached != null && stale))) { return; }
    loadingMore = true; failedMore = false; _failedReconcile = false; error = null; _emit();
    try {
      if (cached != null && stale) {
        backgroundFailure = null; backgroundRetryAt = null;
        final read = await _readCached(generation, fresh: true, background: false);
        if (!_current(generation)) return;
        if (read == null || read.stale) throw const ApiFailure(FailureKind.cancelled);
        if (_loadedPages > 1) {
          if (!await _reconcileLoadedWindow(generation, _loadedPages, read.value)) return;
        } else {
          _applyFirst(read.value);
        }
        fetchedAt = read.fetchedAt; stale = false;
      }
      final cursor = next;
      if (cursor == null) return;
      final page = await loader(cursor);
      if (!_current(generation)) return;
      final ids = items.map(_identity).toSet();
      items = [...items, ...page.items.where((item) => ids.add(_identity(item)))];
      _loadedPages++;
      _seenCursors.add(cursor.toString()); next = page.next;
      if (next != null && _seenCursors.contains(next.toString())) {
        next = null; error = const ApiFailure(FailureKind.invalidResponse);
      }
    } catch (e) {
      if (_current(generation)) {
        error = safeFailure(e);
        final revoked = cached != null && _revoked(error!);
        if (revoked) _withdraw();
        failedMore = !revoked;
      }
    } finally {
      if (_current(generation)) { loadingMore = false; _emit(); _resumeIfVisible(); }
    }
  }

  Future<void> reconcileLoadedWindow() async {
    if (_disposed) return;
    final targetPages = _loadedPages > 0 ? _loadedPages : 1;
    final generation = _begin();
    try {
      CachedRead<ApiPage<Json>>? read;
      ApiPage<Json> first;
      if (cached == null) {
        if (!_current(generation)) return;
        first = await loader(null);
        if (!_current(generation)) return;
      } else {
        read = await _readCached(generation, fresh: true, background: false);
        if (!_current(generation) || read == null) return;
        if (read.stale) {
          if (targetPages == 1) _applyFirst(read.value);
          if (targetPages == 1) fetchedAt = read.fetchedAt;
          stale = true;
          return;
        }
        first = read.value;
      }
      if (!await _reconcileLoadedWindow(generation, targetPages, first)) return;
      if (read != null) { fetchedAt = read.fetchedAt; stale = read.stale; }
      else { stale = false; }
    } catch (e) {
      if (_current(generation)) {
        error = safeFailure(e); _failedReconcile = true;
        if (cached != null && _revoked(error!)) _withdraw();
      }
    } finally {
      if (_current(generation)) { loading = false; _emit(); _resumeIfVisible(); }
    }
  }

  void _resumeIfVisible() {
    if (!_disposed && _resumeWhenVisible && _backgroundEnabled &&
        !loading && !loadingMore && !revalidating) {
      _startRevalidation(_generation, _loadedPages);
    }
  }

  bool _canContinue(int generation) {
    if (!_current(generation)) return false;
    if (!_backgroundEnabled) {
      stale = true; _resumeWhenVisible = true;
      return false;
    }
    return true;
  }

  // Both explicit and background reconciliation stage all pages atomically.
  Future<bool> _reconcileLoadedWindow(
    int generation, int targetPages, ApiPage<Json> first, {bool background = false}
  ) async {
    bool canContinue() => background ? _canContinue(generation) : _current(generation);
    final refreshed = <Json>[];
    final ids = <String>{};
    final requestedCursors = <String>{};
    var page = first;
    var loadedPages = 0;
    while (true) {
      if (!canContinue()) return false;
      loadedPages++;
      refreshed.addAll(page.items.where((item) => ids.add(_identity(item))));
      final following = page.next;
      if (following != null && requestedCursors.contains(following.toString())) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (following == null || loadedPages >= targetPages) break;
      requestedCursors.add(following.toString());
      page = await loader(following);
      if (!canContinue()) return false;
    }
    if (!canContinue()) return false;
    items = refreshed; next = page.next; _loadedPages = loadedPages;
    _seenCursors..clear()..addAll(requestedCursors);
    return true;
  }
  void patchItem(Json item) {
    if (_disposed) return;
    final id = _identity(item);
    final index = items.indexWhere((element) => _identity(element) == id);
    if (index != -1) {
      items = List<Json>.from(items)..[index] = item;
      _emit();
    }
  }
  void removeItem(String id) {
    if (_disposed) return;
    final prevLen = items.length;
    items = items.where((element) {
      final iid = element['iid'];
      return _identity(element) != id && (iid == null || '$iid' != id);
    }).toList();
    if (items.length != prevLen) {
      _emit();
    }
  }
  void prependItem(Json item) {
    if (_disposed) return;
    final id = _identity(item);
    final index = items.indexWhere((element) => _identity(element) == id);
    if (index != -1) {
      items = List<Json>.from(items)..[index] = item;
    } else {
      items = [item, ...items];
    }
    _emit();
  }
  String _identity(Json value) => '${value['id'] ?? value['tag_name'] ?? value['path'] ?? value['name'] ?? value}';
  @override
  void dispose() { _disposed = true; _generation++; items = []; super.dispose(); }
}
