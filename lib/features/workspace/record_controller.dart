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
  final Set<String> _seenCursors = {};
  bool _current(int generation) => !_disposed && generation == _generation;
  void _emit() { if (!_disposed) { notifyListeners(); } }
  Future<void> retry() => failedMore ? more() : refresh();
  Future<void> refresh() async {
    final generation = ++_generation;
    loading = true; loadingMore = false; failedMore = false; error = null; _emit();
    try {
      final page = await loader(null);
      if (!_current(generation)) { return; }
      items = page.items; next = page.next; _seenCursors.clear();
    } catch (e) { if (_current(generation)) { error = safeFailure(e); } }
    finally { if (_current(generation)) { loading = false; _emit(); } }
  }
  Future<void> more() async {
    final cursor = next;
    if (_disposed || loading || loadingMore || cursor == null) { return; }
    final generation = _generation;
    loadingMore = true; failedMore = false; error = null; _emit();
    try {
      final page = await loader(cursor);
      if (!_current(generation)) { return; }
      final ids = items.map(_identity).toSet();
      items = [...items, ...page.items.where((item) => ids.add(_identity(item)))];
      _seenCursors.add(cursor.toString()); next = page.next;
      if (next != null && _seenCursors.contains(next.toString())) {
        next = null; error = const ApiFailure(FailureKind.invalidResponse);
      }
    } catch (e) { if (_current(generation)) { error = safeFailure(e); failedMore = true; } }
    finally { if (_current(generation)) { loadingMore = false; _emit(); } }
  }
  String _identity(Json value) => '${value['id'] ?? value['tag_name'] ?? value['path'] ?? value['name'] ?? value}';
  @override
  void dispose() { _disposed = true; _generation++; items = []; super.dispose(); }
}
