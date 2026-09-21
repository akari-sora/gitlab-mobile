import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  final instance = GitLabInstance.parse('https://example.com/gitlab');
  final patAccount = Account(
    instance: instance,
    user: const GitLabUser(id: 7, username: 'tester', name: 'Test User'),
    token: 'synthetic-pat-token',
  );
  final oauthAccount = Account(
    instance: instance,
    user: const GitLabUser(id: 8, username: 'oauth_user', name: 'OAuth User'),
    credential: const OAuthCredential(
      accessToken: 'access-123',
      refreshToken: 'refresh-456',
      clientId: 'app-client-id',
    ),
  );

  test('load on empty storage returns empty list', () async {
    final store = SecureAccountStore(const FlutterSecureStorage());
    final accounts = await store.load();
    expect(accounts, isEmpty);
  });

  test(
    'save writes v2 accounts and load deserializes both PAT and OAuth credentials',
    () async {
      const storage = FlutterSecureStorage();
      final store = SecureAccountStore(storage);

      await store.save([patAccount, oauthAccount]);

      final rawV2 = await storage.read(key: 'gitlab_mobile_accounts_v2');
      expect(rawV2, isNotNull);
      final rawV1 = await storage.read(key: 'gitlab_mobile_accounts_v1');
      expect(rawV1, isNull);

      final loaded = await store.load();
      expect(loaded, hasLength(2));

      expect(loaded[0].user.id, 7);
      expect(loaded[0].user.username, 'tester');
      expect(loaded[0].credential, isA<PatCredential>());
      expect(loaded[0].token, 'synthetic-pat-token');

      expect(loaded[1].user.id, 8);
      expect(loaded[1].user.username, 'oauth_user');
      expect(loaded[1].credential, isA<OAuthCredential>());
      final oauthCred = loaded[1].credential as OAuthCredential;
      expect(oauthCred.accessToken, 'access-123');
      expect(oauthCred.refreshToken, 'refresh-456');
      expect(oauthCred.clientId, 'app-client-id');
    },
  );

  test('saving empty list deletes both v1 and v2 keys', () async {
    const storage = FlutterSecureStorage();
    final store = SecureAccountStore(storage);

    await store.save([patAccount]);
    expect(await storage.read(key: 'gitlab_mobile_accounts_v2'), isNotNull);

    await store.save([]);
    expect(await storage.read(key: 'gitlab_mobile_accounts_v2'), isNull);
    expect(await storage.read(key: 'gitlab_mobile_accounts_v1'), isNull);
    expect(await store.load(), isEmpty);
  });

  test('load reads and migrates legacy v1 accounts payload', () async {
    const storage = FlutterSecureStorage();
    await storage.write(
      key: 'gitlab_mobile_accounts_v1',
      value: jsonEncode({
        'version': 1,
        'accounts': [
          {
            'instance': 'https://example.com/gitlab',
            'user': {'id': 10, 'username': 'legacy_user', 'name': 'Legacy'},
            'token': 'legacy-pat-token',
          },
        ],
      }),
    );

    final store = SecureAccountStore(storage);
    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.first.user.id, 10);
    expect(loaded.first.user.username, 'legacy_user');
    expect(loaded.first.token, 'legacy-pat-token');
    expect(loaded.first.credential, isA<PatCredential>());
  });

  test(
    'load throws FormatException on invalid version or corrupted data',
    () async {
      const storage = FlutterSecureStorage();
      await storage.write(
        key: 'gitlab_mobile_accounts_v2',
        value: jsonEncode({'version': 99, 'accounts': <dynamic>[]}),
      );
      final store = SecureAccountStore(storage);
      expect(() => store.load(), throwsA(isA<FormatException>()));

      await storage.write(
        key: 'gitlab_mobile_accounts_v2',
        value: jsonEncode({'version': 2, 'accounts': 'not-a-list'}),
      );
      expect(() => store.load(), throwsA(isA<FormatException>()));
    },
  );

  test('last active account key is stored separately from the account list', () async {
    const storage = FlutterSecureStorage();
    final store = SecureAccountStore(storage);
    expect(await store.loadLastActive(), isNull);

    await store.saveLastActive(patAccount.key);
    expect(
      await storage.read(key: 'gitlab_mobile_last_account_v1'),
      patAccount.key,
    );
    expect(await store.loadLastActive(), patAccount.key);
    expect(await store.load(), isEmpty);

    await store.saveLastActive(null);
    expect(await storage.read(key: 'gitlab_mobile_last_account_v1'), isNull);
    expect(await store.loadLastActive(), isNull);
    expect(await store.loadSignOutPending(), isFalse);
    await store.saveSignOutPending(true);
    expect(await storage.read(key: 'gitlab_mobile_sign_out_pending_v1'), '1');
    expect(await store.loadSignOutPending(), isTrue);
    await store.saveSignOutPending(false);
    expect(await storage.read(key: 'gitlab_mobile_sign_out_pending_v1'), isNull);
    expect(await store.loadSignOutPending(), isFalse);
  });

  test(
    'default constructor creates store successfully with hardware Keystore and Keychain',
    () {
      final store = SecureAccountStore();
      expect(store, isA<AccountStore>());
      expect(
        store.storage.aOptions.toMap()['keyCipherAlgorithm'],
        'RSA_ECB_OAEPwithSHA_256andMGF1Padding',
      );
      expect(
        store.storage.iOptions.accessibility,
        KeychainAccessibility.unlocked_this_device,
      );
    },
  );
}
