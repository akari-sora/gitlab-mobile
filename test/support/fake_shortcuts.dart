import 'package:gitlab_mobile/features/auth/recent_project.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';

class MemoryRecentProjectStore implements RecentProjectStore {
  final Map<String, List<RecentProject>> values = {};
  Future<void>? readDelay;
  Future<void>? writeDelay;

  @override
  Future<RecentProject?> read(String accountKey) async {
    final list = await readList(accountKey);
    return list.isEmpty ? null : list.first;
  }

  @override
  Future<List<RecentProject>> readList(String accountKey) async {
    final delay = readDelay;
    if (delay != null) await delay;
    return List.unmodifiable(values[accountKey] ?? const []);
  }

  @override
  Future<void> write(String accountKey, RecentProject project) =>
      touch(accountKey, project);

  @override
  Future<void> touch(String accountKey, RecentProject project) async {
    final delay = writeDelay;
    if (delay != null) await delay;
    final current = values[accountKey] ?? [];
    final updated = [
      project,
      for (final p in current) if (p.id != project.id) p,
    ];
    if (updated.length > 10) {
      updated.removeRange(10, updated.length);
    }
    values[accountKey] = updated;
  }

  @override
  Future<void> clear(String accountKey) async {
    values.remove(accountKey);
  }
}

class FakeAppShortcutHost implements AppShortcutHost {
  void Function(String type)? onType;
  final List<List<AppShortcutItem>> published = [];
  int clears = 0;
  Future<void>? setItemsDelay;
  @override
  Future<void> initialize(void Function(String type) onType) async {
    this.onType = onType;
  }

  @override
  Future<void> setItems(List<AppShortcutItem> items) async {
    final delay = setItemsDelay;
    if (delay != null) await delay;
    published.add(items);
  }

  @override
  Future<void> clear() async {
    clears++;
    published.add(const []);
  }

  void emit(String type) => onType?.call(type);
}
