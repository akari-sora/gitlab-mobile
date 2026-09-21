import 'package:gitlab_mobile/features/auth/recent_project.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';

class MemoryRecentProjectStore implements RecentProjectStore {
  final Map<String, RecentProject> values = {};
  @override
  Future<RecentProject?> read(String accountKey) async => values[accountKey];
  @override
  Future<void> write(String accountKey, RecentProject project) async {
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
  @override
  Future<void> initialize(void Function(String type) onType) async {
    this.onType = onType;
  }

  @override
  Future<void> setItems(List<AppShortcutItem> items) async {
    published.add(items);
  }

  @override
  Future<void> clear() async {
    clears++;
    published.add(const []);
  }

  void emit(String type) => onType?.call(type);
}
