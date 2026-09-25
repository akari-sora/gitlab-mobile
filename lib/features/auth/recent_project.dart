import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/models.dart';
import 'session_controller.dart';

/// A recent project opened on this device. The id is what we navigate to;
/// the name is what displays in UI; path is optional path with namespace.
final class RecentProject {
  const RecentProject({
    required this.id,
    required this.name,
    this.path,
  });

  final int id;
  final String name;
  final String? path;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (path != null) 'path': path,
  };

  factory RecentProject.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final path = json['path'];
    if (id is! int || name is! String || name.trim().isEmpty) {
      throw const FormatException('Invalid RecentProject');
    }
    return RecentProject(
      id: id,
      name: name,
      path: path is String && path.trim().isNotEmpty ? path : null,
    );
  }

  String encode() => jsonEncode(toJson());

  static RecentProject? decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      final id = decoded['id'];
      final name = decoded['name'];
      final path = decoded['path'];
      if (id is! int || name is! String || name.trim().isEmpty) {
        return null;
      }
      return RecentProject(
        id: id,
        name: name,
        path: path is String && path.trim().isNotEmpty ? path : null,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecentProject &&
          other.id == id &&
          other.name == name &&
          other.path == path;

  @override
  int get hashCode => Object.hash(id, name, path);

  @override
  String toString() => 'RecentProject(id: $id, name: $name, path: $path)';
}

abstract interface class RecentProjectStore {
  Future<RecentProject?> read(String accountKey);
  Future<List<RecentProject>> readList(String accountKey);
  Future<void> write(String accountKey, RecentProject project);
  Future<void> touch(String accountKey, RecentProject project);
  Future<void> clear(String accountKey);
}

typedef RecentProjectsStore = RecentProjectStore;

/// Secure storage implementation of [RecentProjectStore] with v2 10-item LRU,
/// v1 migration, per-account serialization queues, and clear-wins epoch fencing.
final class SecureRecentProjectStore implements RecentProjectStore {
  SecureRecentProjectStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );

  final FlutterSecureStorage _storage;
  static const prefix = 'recent_project.v1.';
  static const v2Prefix = 'recent_projects.v2.';
  static const maxItems = 10;

  static String storageKey(String accountKey) =>
      '$prefix${base64Url.encode(utf8.encode(accountKey))}';

  static String v2StorageKey(String accountKey) {
    final digest = sha256.convert(utf8.encode(accountKey));
    return '$v2Prefix$digest';
  }

  final Map<String, Future<void>> _tails = {};
  final Map<String, int> _epochs = {};

  int _epoch(String accountKey) => _epochs[accountKey] ?? 0;

  Future<T> _enqueue<T>(String accountKey, Future<T> Function() action) {
    final prev = _tails[accountKey] ?? Future<void>.value();
    final completer = Completer<T>();
    _tails[accountKey] = prev.then((_) => action()).then(
      (val) => completer.complete(val),
      onError: (Object err, StackTrace st) => completer.completeError(err, st),
    );
    return completer.future;
  }

  @override
  Future<RecentProject?> read(String accountKey) async {
    final list = await readList(accountKey);
    return list.isEmpty ? null : list.first;
  }

  @override
  Future<List<RecentProject>> readList(String accountKey) =>
      _enqueue(accountKey, () => _readListInternal(accountKey));

  Future<List<RecentProject>> _readListInternal(String accountKey) async {
    try {
      // 1. Try reading v2 format
      final rawV2 = await _storage.read(key: v2StorageKey(accountKey));
      if (rawV2 != null && rawV2.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawV2);
          if (decoded is Map && decoded['version'] == 2 && decoded['items'] is List) {
            final items = <RecentProject>[];
            for (final rawItem in (decoded['items'] as List)) {
              if (items.length >= maxItems) break;
              try {
                if (rawItem is Map) {
                  final id = rawItem['id'];
                  final name = rawItem['name'];
                  final path = rawItem['path'];
                  if (id is int && name is String && name.trim().isNotEmpty) {
                    if (!items.any((p) => p.id == id)) {
                      items.add(RecentProject(
                        id: id,
                        name: name,
                        path: path is String && path.trim().isNotEmpty ? path : null,
                      ));
                    }
                  }
                }
              } catch (_) {}
            }
            return List.unmodifiable(items);
          }
        } catch (_) {
          // Corrupted v2 payload, fall through
        }
      }

      // 2. Fall back to v1 format and migrate
      final rawV1 = await _storage.read(key: storageKey(accountKey));
      final old = RecentProject.decode(rawV1);
      if (old != null) {
        final migrated = [old];
        await _writeV2Internal(accountKey, migrated);
        try {
          await _storage.delete(key: storageKey(accountKey));
        } catch (_) {}
        return List.unmodifiable(migrated);
      }
    } catch (_) {
      return const [];
    }

    return const [];
  }

  Future<void> _writeV2Internal(String accountKey, List<RecentProject> items) async {
    try {
      final payload = jsonEncode({
        'version': 2,
        'items': [
          for (final p in items)
            {
              'id': p.id,
              'name': p.name,
              if (p.path != null) 'path': p.path,
            },
        ],
      });
      await _storage.write(key: v2StorageKey(accountKey), value: payload);
    } catch (_) {}
  }

  @override
  Future<void> touch(String accountKey, RecentProject project) {
    final epoch = _epoch(accountKey);
    return _enqueue(accountKey, () async {
      try {
        if (_epoch(accountKey) != epoch) return;
        final current = await _readListInternal(accountKey);
        if (_epoch(accountKey) != epoch) return;

        final updated = <RecentProject>[
          project,
          for (final p in current) if (p.id != project.id) p,
        ];
        if (updated.length > maxItems) {
          updated.removeRange(maxItems, updated.length);
        }

        if (_epoch(accountKey) != epoch) return;
        await _writeV2Internal(accountKey, updated);
      } catch (_) {}
    });
  }

  @override
  Future<void> write(String accountKey, RecentProject project) =>
      touch(accountKey, project);

  @override
  Future<void> clear(String accountKey) {
    final nextEpoch = (_epochs[accountKey] ?? 0) + 1;
    _epochs[accountKey] = nextEpoch;
    return _enqueue(accountKey, () async {
      try {
        await _storage.delete(key: v2StorageKey(accountKey));
        await _storage.delete(key: storageKey(accountKey));
      } catch (_) {}
    });
  }
}

/// Controller managing the recent projects list for the active session account,
/// ensuring account switching and session generation boundaries are strictly respected.
final class RecentProjectsController extends ChangeNotifier {
  RecentProjectsController({
    required this.store,
    required this.session,
  });

  final RecentProjectStore store;
  final SessionController session;

  List<RecentProject> _items = const [];
  List<RecentProject> get items => _items;

  bool _loading = false;
  bool get loading => _loading;

  int _epoch = 0;

  Future<void> load() async {
    final active = session.active;
    if (active == null) {
      _items = const [];
      notifyListeners();
      return;
    }
    final accountKey = active.key;
    final generation = session.generation;
    final epoch = ++_epoch;
    _loading = true;
    notifyListeners();

    try {
      final list = await store.readList(accountKey);
      if (_epoch == epoch &&
          session.active?.key == accountKey &&
          session.generation == generation) {
        _items = list;
        _loading = false;
        notifyListeners();
      }
    } catch (_) {
      if (_epoch == epoch &&
          session.active?.key == accountKey &&
          session.generation == generation) {
        _items = const [];
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> remember(Project project) async {
    final active = session.active;
    if (active == null) return;
    final accountKey = active.key;
    final generation = session.generation;
    final epoch = ++_epoch;

    final item = RecentProject(
      id: project.id,
      name: project.name,
      path: project.path,
    );

    await store.touch(accountKey, item);

    if (_epoch == epoch &&
        session.active?.key == accountKey &&
        session.generation == generation) {
      final list = await store.readList(accountKey);
      if (_epoch == epoch &&
          session.active?.key == accountKey &&
          session.generation == generation) {
        _items = list;
        notifyListeners();
      }
    }
  }

  void clearVisible() {
    _items = const [];
    _epoch++;
    notifyListeners();
  }
}

Future<void> clearRecentProject(Account account) =>
    SecureRecentProjectStore().clear(account.key);
