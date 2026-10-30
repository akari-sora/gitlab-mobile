import 'dart:io';
import 'dart:typed_data';

import '../../core/models.dart';
import '../ai/ai_write_journal.dart';
import '../auth/account_store.dart';
import '../auth/recent_project.dart';
import '../shell/app_shortcuts.dart';
import '../shell/appearance.dart';

/// The demo's account list. It lives and dies with one demo visit; the
/// device's account list never learns about the demo account.
final class DemoAccountStore implements AccountStore {
  DemoAccountStore(Account account) : _accounts = [account];

  List<Account> _accounts;
  String? _lastActive;
  bool _signOutPending = false;

  @override
  Future<List<Account>> load() async => List.of(_accounts);

  @override
  Future<void> save(List<Account> accounts) async =>
      _accounts = List.of(accounts);

  @override
  Future<String?> loadLastActive() async => _lastActive;

  @override
  Future<void> saveLastActive(String? key) async => _lastActive = key;

  @override
  Future<bool> loadSignOutPending() async => _signOutPending;

  @override
  Future<void> saveSignOutPending(bool pending) async =>
      _signOutPending = pending;
}

/// Recent projects for Home and the launcher, kept in memory.
final class DemoRecentProjectStore implements RecentProjectStore {
  final Map<String, List<RecentProject>> _projects = {};

  @override
  Future<RecentProject?> read(String accountKey) async =>
      _projects[accountKey]?.firstOrNull;

  @override
  Future<List<RecentProject>> readList(String accountKey) async =>
      List.unmodifiable(_projects[accountKey] ?? const <RecentProject>[]);

  @override
  Future<void> write(String accountKey, RecentProject project) =>
      touch(accountKey, project);

  @override
  Future<void> touch(String accountKey, RecentProject project) async {
    _projects[accountKey] = [
      project,
      for (final other in _projects[accountKey] ?? const <RecentProject>[])
        if (other.id != project.id) other,
    ].take(10).toList();
  }

  @override
  Future<void> clear(String accountKey) async => _projects.remove(accountKey);
}

/// The demo publishes no launcher shortcuts: they would outlive the visit.
final class DemoShortcutHost implements AppShortcutHost {
  @override
  Future<void> initialize(void Function(String type) onType) async {}

  @override
  Future<void> setItems(List<AppShortcutItem> items) async {}

  @override
  Future<void> clear() async {}
}

/// Starts from the device's appearance; a change in the demo stays in it.
final class DemoAppearanceStore implements AppearanceStore {
  DemoAppearanceStore(this._value);

  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String? value) async => _value = value;
}

/// The AI write journal's file, kept in memory. Every method of
/// [AiJournalFiles] that touches the file system is replaced, so the
/// directory given to the base class is never resolved or created.
final class DemoJournalFiles extends AiJournalFiles {
  DemoJournalFiles() : super(Directory.systemTemp);

  final Map<String, Uint8List> _files = {};

  @override
  Future<bool> exists(String account) async => _files.containsKey(account);

  @override
  Future<Uint8List?> read(String account) async => _files[account];

  @override
  Future<void> write(
    String account,
    Uint8List bytes, {
    required bool Function() mayCommit,
  }) async {
    if (!mayCommit()) throw const AiJournalException('staleOwner');
    _files[account] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> cleanupTemporary(String account) async {}

  @override
  Future<void> delete(String account) async => _files.remove(account);

  @override
  Future<void> deleteHash(String hash) async => _files.removeWhere(
    (account, _) => AiJournalFiles.accountHash(account) == hash,
  );

  @override
  Future<Set<String>> accountHashes() async =>
      _files.keys.map(AiJournalFiles.accountHash).toSet();
}
