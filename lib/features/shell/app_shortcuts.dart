import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:quick_actions/quick_actions.dart';

import '../auth/recent_project.dart';

import '../../l10n/l10n.dart';
/// Launcher shortcuts registered after sign-in.
abstract final class ShortcutTypes {
  static const inbox = 'inbox';
  static const search = 'search';
  static const recent = 'recent';
}

enum ShortcutKind { inbox, search, recent }

final class PendingShortcut {
  const PendingShortcut(this.kind, {this.accountKey, this.projectId, this.token});
  final ShortcutKind kind;
  /// Set for inbox and search from the account bound when the shortcut arrived.
  /// Null when it arrived while signed out. Recent ownership lives in [token].
  final String? accountKey;
  final int? projectId;
  final String? token;
}

/// Opaque launcher id for one account and project. The account key is not
/// recoverable from the id; receipt recomputes it and rejects a mismatch.
String recentShortcutType(String accountKey, int projectId) {
  final token = sha256.convert(utf8.encode('$accountKey#$projectId')).toString();
  return '${ShortcutTypes.recent}:$projectId:$token';
}

final class _ParsedRecent {
  const _ParsedRecent(this.projectId, this.token);
  final int projectId;
  final String token;
}

_ParsedRecent? _parseRecent(String type) {
  const prefix = '${ShortcutTypes.recent}:';
  if (!type.startsWith(prefix)) return null;
  final rest = type.substring(prefix.length);
  final separator = rest.indexOf(':');
  if (separator <= 0 || separator >= rest.length - 1) return null;
  final id = int.tryParse(rest.substring(0, separator));
  final token = rest.substring(separator + 1);
  if (id == null || id <= 0 || token.length != 64) return null;
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(token)) return null;
  return _ParsedRecent(id, token);
}

bool _ownsRecent(String accountKey, int projectId, String token) =>
    recentShortcutType(accountKey, projectId) == '${ShortcutTypes.recent}:$projectId:$token';

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
  RecentProjectStore get recentStore => _recent;
  PendingShortcut? pending;
  String? _accountKey;
  bool _started = false;
  bool _disposed = false;
  int _epoch = 0;
  Future<void>? _queue;

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    await _host.initialize(_handle);
  }

  /// Binds launcher updates to the signed-in account. A change drops in-flight
  /// publishes and any pending shortcut, except a null-key shortcut that
  /// arrived while already signed out (it may apply to the account that signs
  /// in next, after ownership is checked).
  void bind(String? accountKey) {
    if (accountKey == _accountKey) return;
    final previous = _accountKey;
    _accountKey = accountKey;
    _epoch++;
    final current = pending;
    if (current == null) return;
    if (current.accountKey == null && previous == null) return;
    pending = null;
  }

  Future<void> publish(String accountKey) {
    // A foreign account must not bump the epoch: that would cancel a valid
    // publish for the bound account and then reject itself.
    if (_disposed || accountKey != _accountKey) return Future<void>.value();
    final epoch = ++_epoch;
    return _enqueue(() async {
      if (!_current(epoch, accountKey)) return;
      RecentProject? project;
      try {
        project = await _recent.read(accountKey);
      } catch (_) {
        project = null;
      }
      if (!_current(epoch, accountKey)) return;
      await _host.setItems(_items(accountKey, project));
    });
  }

  Future<void> clearPublished() {
    _epoch++;
    return _enqueue(() async {
      if (_disposed) return;
      await _host.clear();
    });
  }

  Future<void> rememberOpened({
    required String accountKey,
    required int id,
    required String name,
  }) {
    // Captured at call time, not when the queued work starts: a request that
    // waits behind an in-flight write must not adopt a session that began
    // after it (sign-out, or the same account returning with a new epoch).
    final epoch = _epoch;
    if (!_current(epoch, accountKey)) return Future<void>.value();
    return _enqueue(() async {
      if (!_current(epoch, accountKey)) return;
      try {
        await _recent.write(accountKey, RecentProject(id: id, name: name));
      } catch (_) {
        return;
      }
      if (!_current(epoch, accountKey)) return;
      await _host.setItems(_items(accountKey, RecentProject(id: id, name: name)));
    });
  }

  Future<RecentProject?> readRecent(String accountKey) => _recent.read(accountKey);

  /// Drops a recent-project shortcut whose published token does not match
  /// [accountKey]. A recent shortcut without a token is rejected.
  PendingShortcut? takeFor(String accountKey) {
    final current = pending;
    if (current == null || _disposed) {
      return null;
    }
    pending = null;
    if (current.kind == ShortcutKind.recent) {
      final id = current.projectId;
      final token = current.token;
      if (id == null || token == null || !_ownsRecent(accountKey, id, token)) {
        return null;
      }
      return current;
    }
    if (current.accountKey != null && current.accountKey != accountKey) {
      return null;
    }
    return current;
  }

  bool _current(int epoch, String accountKey) =>
      !_disposed && epoch == _epoch && accountKey == _accountKey;

  Future<void> _enqueue(Future<void> Function() action) {
    final previous = _queue ?? Future<void>.value();
    final result = previous.then((_) => action());
    _queue = result.then((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  List<AppShortcutItem> _items(String accountKey, RecentProject? project) => [
    AppShortcutItem(type: ShortcutTypes.inbox, title: l10n.inboxTab),
    AppShortcutItem(type: ShortcutTypes.search, title: l10n.searchProjects),
    AppShortcutItem(
      type: project == null ? ShortcutTypes.recent : recentShortcutType(accountKey, project.id),
      title: l10n.lastProject,
      subtitle: project?.name,
    ),
  ];

  void _handle(String type) {
    if (_disposed) {
      return;
    }
    if (type == ShortcutTypes.inbox || type == ShortcutTypes.search) {
      pending = PendingShortcut(
        type == ShortcutTypes.inbox ? ShortcutKind.inbox : ShortcutKind.search,
        accountKey: _accountKey,
      );
      notifyListeners();
      return;
    }
    final parsed = _parseRecent(type);
    if (parsed == null) return;
    // Ownership is the token published with the shortcut, not the account that
    // happens to be signed in when the tap is delivered.
    pending = PendingShortcut(ShortcutKind.recent, projectId: parsed.projectId, token: parsed.token);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}
