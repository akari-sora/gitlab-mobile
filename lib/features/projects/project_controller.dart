import 'package:flutter/foundation.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';

/// Page-2 failures keep existing rows. Search/refresh generations prevent old
/// responses overwriting newer filters. Never uses mock data in production.
final class ProjectController extends ChangeNotifier {
  ProjectController(this.api);
  final GitLabApi api;
  ProjectScope scope = ProjectScope.member;
  String query = '';
  List<Project> items = [];
  Uri? next;
  ApiFailure? error;
  ApiFailure? pageError;
  bool loading = false;
  bool loadingMore = false;
  DateTime? fetchedAt;
  int _epoch = 0;
  bool _disposed = false;
  void _emit() { if (!_disposed) notifyListeners(); }

  Future<void> search(ProjectScope value, String text) async {
    if (scope != value || query != text) {
      scope = value; query = text; items = []; next = null; fetchedAt = null;
    }
    await refresh();
  }

  Future<void> refresh() async {
    final epoch = ++_epoch;
    loading = true; loadingMore = false; error = null; pageError = null; _emit();
    try {
      final page = await api.projects(scope: scope, search: query);
      if (_disposed || epoch != _epoch) return;
      items = page.items; next = page.next; fetchedAt = DateTime.now();
    } catch (e) {
      if (_disposed || epoch != _epoch) return;
      error = safeFailure(e);
    } finally {
      if (!_disposed && epoch == _epoch) { loading = false; _emit(); }
    }
  }

  Future<void> loadMore() async {
    final cursor = next;
    if (cursor == null || loading || loadingMore) return;
    final epoch = _epoch;
    loadingMore = true; pageError = null; _emit();
    try {
      final page = await api.projects(scope: scope, search: query, next: cursor);
      if (_disposed || epoch != _epoch) return;
      final seen = items.map((p) => p.id).toSet();
      items = [...items, ...page.items.where((p) => seen.add(p.id))];
      next = page.next;
    } catch (e) {
      if (!_disposed && epoch == _epoch) pageError = safeFailure(e);
    } finally {
      if (!_disposed && epoch == _epoch) { loadingMore = false; _emit(); }
    }
  }
  @override
  void dispose() { _disposed = true; _epoch++; super.dispose(); }
}
