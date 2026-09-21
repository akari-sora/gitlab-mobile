import 'package:gitlab_mobile/features/auth/recent_project.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';

class MemoryRecentProjectStore implements RecentProjectStore {
  final Map<String, RecentProject> values = {};
  Future<void>? readDelay;
  Future<void>? writeDelay;
  @override
  Future<RecentProject?> read(String accountKey) async {
    final delay = readDelay;
    if (delay != null) await delay;
    return values[accountKey];
  }

  @override
  Future<void> write(String accountKey, RecentProject project) async {
    final delay = writeDelay;
    if (delay != null) await delay;
    values[accountKey] = project;
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
