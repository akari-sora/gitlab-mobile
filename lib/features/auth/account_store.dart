import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/models.dart';

abstract interface class AccountStore {
  Future<List<Account>> load();
  Future<void> save(List<Account> accounts);
  Future<String?> loadLastActive();
  Future<void> saveLastActive(String? key);

  /// True after a sign-out whose remembered-key deletion did not finish.
  /// Auto-resume must not run while this marker is stored.
  Future<bool> loadSignOutPending();
  Future<void> saveSignOutPending(bool pending);
}

/// Persists credentials and minimum identity metadata.
/// See CLAUDE.md's Persistence section for the complete disk-write contract,
/// including the separate opt-in encrypted AI chat history.
final class SecureAccountStore implements AccountStore {
  SecureAccountStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );
  final FlutterSecureStorage _storage;
  FlutterSecureStorage get storage => _storage;
  static const _key = 'gitlab_mobile_accounts_v1';
  static const _keyV2 = 'gitlab_mobile_accounts_v2';
  static const _lastAccountKey = 'gitlab_mobile_last_account_v1';
  static const _signOutPendingKey = 'gitlab_mobile_sign_out_pending_v1';
  @override
  Future<List<Account>> load() async {
    final text =
        await _storage.read(key: _keyV2) ?? await _storage.read(key: _key);
    if (text == null) return [];
    final decoded = objectJson(jsonDecode(text));
    final version = decoded['version'];
    if ((version != 1 && version != 2) ||
        decoded['accounts'] is! List<dynamic>) {
      throw const FormatException('Unsupported account store');
    }
    return (decoded['accounts'] as List<dynamic>)
        .map((v) => Account.fromSecureJson(objectJson(v)))
        .toList();
  }

  @override
  Future<void> save(List<Account> accounts) async {
    if (accounts.isEmpty) {
      await _storage.delete(key: _keyV2);
      await _storage.delete(key: _key);
      return;
    }
    await _storage.write(
      key: _keyV2,
      value: jsonEncode({
        'version': 2,
        'accounts': accounts.map((a) => a.toSecureJson()).toList(),
      }),
    );
    await _storage.delete(key: _key);
  }

  @override
  Future<String?> loadLastActive() async {
    final value = await _storage.read(key: _lastAccountKey);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  @override
  Future<void> saveLastActive(String? key) async {
    if (key == null || key.isEmpty) {
      await _storage.delete(key: _lastAccountKey);
      return;
    }
    await _storage.write(key: _lastAccountKey, value: key);
  }

  @override
  Future<bool> loadSignOutPending() async =>
      await _storage.read(key: _signOutPendingKey) == '1';

  @override
  Future<void> saveSignOutPending(bool pending) async {
    if (!pending) {
      await _storage.delete(key: _signOutPendingKey);
      return;
    }
    await _storage.write(key: _signOutPendingKey, value: '1');
  }
}
