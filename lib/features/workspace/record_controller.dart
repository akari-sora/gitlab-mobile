import 'package:flutter/foundation.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/failure.dart';

typedef RecordLoader = Future<ApiPage<Json>> Function(Uri? next);
class RecordController extends ChangeNotifier {
  RecordController(this.loader);
  RecordLoader loader;
  List<Json> items = [];
  Uri? next;
  ApiFailure? error;
  bool loading = false, loadingMore = false, failedMore = false;
  bool _disposed = false;
  int _generation = 0;
  int _loadedPages = 0;
  bool _failedReconcile = false;
  final Set<String> _seenCursors = {};
  bool _current(int generation) => !_disposed && generation == _generation;
  void _emit() { if (!_disposed) { notifyListeners(); } }
  Future<void> retry() => _failedReconcile ? reconcileLoadedWindow() : failedMore ? more() : refresh();
  Future<void> refresh() async {
    final generation = ++_generation;
    loading = true; loadingMore = false; failedMore = false; _failedReconcile = false; error = null; _emit();
    try {
      final page = await loader(null);
      if (!_current(generation)) { return; }
      items = page.items; next = page.next; _loadedPages = 1; _seenCursors.clear();
    } catch (e) { if (_current(generation)) { error = safeFailure(e); } }
    finally { if (_current(generation)) { loading = false; _emit(); } }
  }
  Future<void> more() async {
    final cursor = next;
    if (_disposed || loading || loadingMore || cursor == null) { return; }
    final generation = _generation;
    loadingMore = true; failedMore = false; _failedReconcile = false; error = null; _emit();
    try {
      final page = await loader(cursor);
      if (!_current(generation)) { return; }
      final ids = items.map(_identity).toSet();
      items = [...items, ...page.items.where((item) => ids.add(_identity(item)))];
      _loadedPages++;
      _seenCursors.add(cursor.toString()); next = page.next;
      if (next != null && _seenCursors.contains(next.toString())) {
        next = null; error = const ApiFailure(FailureKind.invalidResponse);
      }
    } catch (e) { if (_current(generation)) { error = safeFailure(e); failedMore = true; } }
    finally { if (_current(generation)) { loadingMore = false; _emit(); } }
  }
  Future<void> reconcileLoadedWindow() async {
    if (_disposed) return;
    final targetPages = _loadedPages > 0 ? _loadedPages : 1;
    final generation = ++_generation;
    loading = true; loadingMore = false; failedMore = false; _failedReconcile = false; error = null; _emit();
    try {
      final refreshed = <Json>[];
      final ids = <String>{};
      final requestedCursors = <String>{};
      Uri? cursor;
      Uri? refreshedNext;
      var loadedPages = 0;
      for (var index = 0; index < targetPages; index++) {
        if (cursor != null) requestedCursors.add(cursor.toString());
        final page = await loader(cursor);
        if (!_current(generation)) return;
        loadedPages++;
        refreshed.addAll(page.items.where((item) => ids.add(_identity(item))));
        refreshedNext = page.next;
        if (refreshedNext != null && requestedCursors.contains(refreshedNext.toString())) {
          throw const ApiFailure(FailureKind.invalidResponse);
        }
        if (refreshedNext == null || index + 1 == targetPages) break;
        cursor = refreshedNext;
      }
      if (!_current(generation)) return;
      items = refreshed;
      next = refreshedNext;
      _loadedPages = loadedPages;
      _seenCursors
        ..clear()
        ..addAll(requestedCursors);
    } catch (e) {
      if (_current(generation)) {
        error = safeFailure(e);
        _failedReconcile = true;
      }
    } finally {
      if (_current(generation)) { loading = false; _emit(); }
    }
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
