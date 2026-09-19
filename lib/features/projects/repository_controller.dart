import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';

/// One controller belongs to one immutable account API and project locator.
/// Directory snapshots are memory-only and bound to one resolved commit SHA.
final class RepositoryController extends ChangeNotifier {
  RepositoryController(this.api, this.locator);
  final GitLabApi api;
  final String locator;
  Project? project;
  String? sha;
  String path = '';
  List<TreeEntry> entries = const [];
  Uri? next;
  ApiFailure? error;
  ApiFailure? pageError;
  DateTime? fetchedAt;
  bool loading = false;
  bool loadingMore = false;
  int _epoch = 0;
  bool _disposed = false;
  final _directories = LinkedHashMap<String, _DirectorySnapshot>();
  static const maxCachedDirectories = 8;
  static const maxCachedEntries = 1000;

  bool get isEmptyRepository => project != null &&
      (project!.defaultBranch == null || project!.defaultBranch!.isEmpty);
  bool _current(int epoch) => !_disposed && epoch == _epoch;
  void _emit() { if (!_disposed) notifyListeners(); }

  Future<void> initialize() async {
    if (_disposed) return;
    final epoch = ++_epoch;
    project = null; sha = null; path = ''; entries = const []; next = null;
    error = null; pageError = null; fetchedAt = null;
    loading = true; loadingMore = false; _directories.clear(); _emit();
    try {
      final found = await api.project(locator);
      if (!_current(epoch)) return;
      project = found;
      if (isEmptyRepository) return;
      final commit = await api.defaultBranchSha(found);
      if (!_current(epoch)) return;
      sha = commit;
      final first = await api.tree(found.id, commit);
      if (!_current(epoch)) return;
      entries = first.items; next = first.next; fetchedAt = DateTime.now();
    } catch (failure) {
      if (_current(epoch)) error = safeFailure(failure);
    } finally {
      if (_current(epoch)) { loading = false; _emit(); }
    }
  }

  Future<void> openDirectory(String folder) async {
    if (_disposed || project == null || sha == null) return;
    if (folder == path && fetchedAt != null) return;
    _rememberDirectory();
    ++_epoch; path = folder; error = null; pageError = null; loadingMore = false;
    final cached = _directories.remove(folder);
    if (cached != null) {
      entries = cached.entries; next = cached.next; fetchedAt = cached.fetchedAt;
      loading = false; _emit();
      return;
    }
    entries = const []; next = null; fetchedAt = null;
    await refresh();
  }

  /// Refresh failure keeps the current rows, cursor and last-success timestamp.
  Future<void> refresh() async {
    if (_disposed) return;
    final currentProject = project;
    final commit = sha;
    if (currentProject == null || commit == null) {
      await initialize();
      return;
    }
    final epoch = ++_epoch;
    final folder = path;
    loading = true; loadingMore = false; error = null; pageError = null; _emit();
    try {
      final first = await api.tree(currentProject.id, commit, path: folder);
      if (!_current(epoch)) return;
      entries = first.items; next = first.next; fetchedAt = DateTime.now();
    } catch (failure) {
      if (_current(epoch)) error = safeFailure(failure);
    } finally {
      if (_current(epoch)) { loading = false; _emit(); }
    }
  }

  Future<void> loadMore() async {
    final cursor = next;
    final currentProject = project;
    final commit = sha;
    if (_disposed || loading || loadingMore || cursor == null ||
        currentProject == null || commit == null) return;
    final epoch = _epoch;
    final folder = path;
    loadingMore = true; pageError = null; _emit();
    try {
      final page = await api.tree(currentProject.id, commit, path: folder, next: cursor);
      if (!_current(epoch)) return;
      final seen = entries.map((entry) => entry.path).toSet();
      entries = List.unmodifiable([...entries, ...page.items.where((entry) => seen.add(entry.path))]);
      next = page.next;
    } catch (failure) {
      if (_current(epoch)) pageError = safeFailure(failure);
    } finally {
      if (_current(epoch)) { loadingMore = false; _emit(); }
    }
  }

  void _rememberDirectory() {
    if (fetchedAt == null || entries.length > maxCachedEntries) return;
    _directories.remove(path);
    _directories[path] = _DirectorySnapshot(List.unmodifiable(entries), next, fetchedAt!);
    while (_directories.length > maxCachedDirectories ||
        _directories.values.fold(0, (count, item) => count + item.entries.length) > maxCachedEntries) {
      _directories.remove(_directories.keys.first);
    }
  }

  @override
  void dispose() {
    _disposed = true; ++_epoch; _directories.clear(); entries = const [];
    super.dispose();
  }
}

final class _DirectorySnapshot {
  const _DirectorySnapshot(this.entries, this.next, this.fetchedAt);
  final List<TreeEntry> entries;
  final Uri? next;
  final DateTime fetchedAt;
}
