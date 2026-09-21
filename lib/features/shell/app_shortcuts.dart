import 'package:flutter/foundation.dart';
import 'package:quick_actions/quick_actions.dart';

import '../auth/recent_project.dart';

/// Launcher shortcuts registered after sign-in.
abstract final class ShortcutTypes {
  static const inbox = 'inbox';
  static const search = 'search';
  static const recent = 'recent';
}

enum ShortcutKind { inbox, search, recent }

final class PendingShortcut {
  const PendingShortcut(this.kind, {this.accountKey});
  final ShortcutKind kind;
  final String? accountKey;
}

final class AppShortcutItem {
  const AppShortcutItem({required this.type, required this.title, this.subtitle});
  final String type;
  final String title;
  final String? subtitle;
}

/// The quick-actions plugin, behind an interface so tests can emit a shortcut
/// without a platform channel.
abstract interface class AppShortcutHost {
  Future<void> initialize(void Function(String type) onType);
  Future<void> setItems(List<AppShortcutItem> items);
  Future<void> clear();
}

final class QuickActionsHost implements AppShortcutHost {
  QuickActionsHost([QuickActions? actions]) : _actions = actions ?? const QuickActions();
  final QuickActions _actions;

  @override
  Future<void> initialize(void Function(String type) onType) async {
    try {
      await _actions.initialize(onType);
    } catch (_) {
      // The plugin is absent in widget tests and on an engine that has not
      // registered it. Shortcuts stay unavailable; the rest of the app runs.
    }
  }

  @override
  Future<void> setItems(List<AppShortcutItem> items) async {
    try {
      await _actions.setShortcutItems([
        for (final item in items)
          ShortcutItem(
            type: item.type,
            localizedTitle: item.title,
            localizedSubtitle: item.subtitle,
          ),
      ]);
    } catch (_) {
      // Same as initialize: a missing plugin must not take down sign-in.
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _actions.clearShortcutItems();
    } catch (_) {
      // Clearing shortcuts is best-effort when the plugin is absent.
    }
  }
}

/// Remembers a shortcut tapped before sign-in and publishes the three
/// launcher actions for the active account.
class LauncherShortcuts extends ChangeNotifier {
  LauncherShortcuts(this._host, this._recent);
  final AppShortcutHost _host;
  final RecentProjectStore _recent;
  PendingShortcut? pending;
  String? _accountKey;
  bool _started = false;
  bool _disposed = false;
  int _epoch = 0;

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    await _host.initialize(_handle);
  }

  void bind(String? accountKey) => _accountKey = accountKey;

  Future<void> publish(String accountKey) async {
    final epoch = ++_epoch;
    RecentProject? project;
    try {
      project = await _recent.read(accountKey);
    } catch (_) {
      project = null;
    }
    if (_disposed || epoch != _epoch) {
      return;
    }
    await _host.setItems([
      const AppShortcutItem(type: ShortcutTypes.inbox, title: '收件匣'),
      const AppShortcutItem(type: ShortcutTypes.search, title: '搜尋專案'),
      AppShortcutItem(
        type: ShortcutTypes.recent,
        title: '上次的專案',
        subtitle: project?.name,
      ),
    ]);
  }

  Future<void> clearPublished() => _host.clear();

  Future<void> rememberOpened({
    required String accountKey,
    required int id,
    required String name,
  }) async {
    try {
      await _recent.write(accountKey, RecentProject(id: id, name: name));
      await publish(accountKey);
    } catch (_) {}
  }

  Future<RecentProject?> readRecent(String accountKey) => _recent.read(accountKey);

  /// Drops a recent-project shortcut that was captured for a different account.
  PendingShortcut? takeFor(String accountKey) {
    final current = pending;
    if (current == null || _disposed) {
      return null;
    }
    pending = null;
    if (current.kind == ShortcutKind.recent &&
        current.accountKey != null &&
        current.accountKey != accountKey) {
      return null;
    }
    return current;
  }

  void _handle(String type) {
    if (_disposed) {
      return;
    }
    final kind = switch (type) {
      ShortcutTypes.inbox => ShortcutKind.inbox,
      ShortcutTypes.search => ShortcutKind.search,
      ShortcutTypes.recent => ShortcutKind.recent,
      _ => null,
    };
    if (kind == null) {
      return;
    }
    pending = PendingShortcut(kind, accountKey: _accountKey);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
