import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/models.dart';

abstract interface class AccountStore {
  Future<List<Account>> load();
  Future<void> save(List<Account> accounts);
}

/// Only credentials and minimum identity metadata persist in this milestone.
/// No repository data, logs, code, drafts, or private search history on disk.
final class SecureAccountStore implements AccountStore {
  SecureAccountStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage(
          iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device),
        );
  final FlutterSecureStorage _storage;
  static const _key = 'gitlab_mobile_accounts_v1';
  @override
  Future<List<Account>> load() async {
    final text = await _storage.read(key: _key);
    if (text == null) return [];
    final decoded = objectJson(jsonDecode(text));
    if (decoded['version'] != 1 || decoded['accounts'] is! List<dynamic>) {
      throw const FormatException('Unsupported account store');
    }
    return (decoded['accounts'] as List<dynamic>)
        .map((v) => Account.fromSecureJson(objectJson(v))).toList();
  }
  @override
  Future<void> save(List<Account> accounts) async {
    if (accounts.isEmpty) { await _storage.delete(key: _key); return; }
    await _storage.write(key: _key, value: jsonEncode({
      'version': 1, 'accounts': accounts.map((a) => a.toSecureJson()).toList(),
    }));
  }
}
