import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/models.dart';

/// The last project this account opened on this device. The id is what we
/// navigate to; the name is what the launcher shortcut shows.
final class RecentProject {
  const RecentProject({required this.id, required this.name});
  final int id;
  final String name;

  String encode() => jsonEncode({'id': id, 'name': name});

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
      if (id is! int || name is! String || name.trim().isEmpty) {
        return null;
      }
      return RecentProject(id: id, name: name);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RecentProject && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

abstract interface class RecentProjectStore {
  Future<RecentProject?> read(String accountKey);
  Future<void> write(String accountKey, RecentProject project);
  Future<void> clear(String accountKey);
}

/// One secure-storage record per account. Removing the account deletes only
/// that record.
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

  static String storageKey(String accountKey) =>
      '$prefix${base64Url.encode(utf8.encode(accountKey))}';

  @override
  Future<RecentProject?> read(String accountKey) async =>
      RecentProject.decode(await _storage.read(key: storageKey(accountKey)));

  @override
  Future<void> write(String accountKey, RecentProject project) =>
      _storage.write(key: storageKey(accountKey), value: project.encode());

  @override
  Future<void> clear(String accountKey) =>
      _storage.delete(key: storageKey(accountKey));
}

Future<void> clearRecentProject(Account account) =>
    SecureRecentProjectStore().clear(account.key);
