import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  group('provider settings and keys', () {
    test(
      'round trips every provider field and its independent revision',
      () async {
        final store = MemoryAiStore();
        final providers = <AiProviderConfig>[
          _provider(id: 'first', revision: 3),
          _provider(id: 'second', revision: 9),
        ];

        await store.saveProviders(providers);
        final read = await store.loadProviders();

        expect(read.status, AiStoreReadStatus.found);
        expect(read.value, hasLength(2));
        expect(read.value![0].recipientRevision, 3);
        expect(read.value![1].recipientRevision, 9);
        expect(read.value![0].caps.includeEncryptedReasoning, isTrue);
        expect(read.value![0].modelsUrl, 'https://models.example.test/v1');
      },
    );

    test('provider payload is versioned and contains no API key', () async {
      const storage = FlutterSecureStorage();
      final store = SecureAiStore(storage);
      await store.saveProviders(<AiProviderConfig>[_provider()]);
      await store.saveProviderKey('provider/one', 'sk-secret-value-1234');

      final providers = await storage.read(
        key: SecureAiStore.providersStorageKey,
      );
      final decoded = jsonDecode(providers!) as Map<String, Object?>;
      expect(decoded['version'], 1);
      expect(providers, isNot(contains('sk-secret-value-1234')));
      expect(
        await storage.read(key: SecureAiStore.providerKey('provider/one')),
        'sk-secret-value-1234',
      );
    });

    test(
      'rejects keys shorter than four and gates warning-shaped keys',
      () async {
        final store = MemoryAiStore();

        expect(assessAiProviderKey('abc').accepted, isFalse);
        expect(
          () => store.saveProviderKey('p', 'abc'),
          throwsA(
            isA<AiStoreException>().having(
              (error) => error.failure.kind,
              'kind',
              AiStoreFailureKind.invalidValue,
            ),
          ),
        );
        expect(assessAiProviderKey('ordinaryword').warning, isNotNull);
        expect(
          () => store.saveProviderKey('p', 'ordinaryword'),
          throwsA(
            isA<AiStoreException>().having(
              (error) => error.failure.kind,
              'kind',
              AiStoreFailureKind.confirmationRequired,
            ),
          ),
        );

        await store.saveProviderKey(
          'p',
          'ordinaryword',
          acknowledgeWarning: true,
        );
        expect((await store.readProviderKey('p')).value, 'ordinaryword');
      },
    );

    test(
      'malformed or unknown provider version is absent with failure',
      () async {
        FlutterSecureStorage.setMockInitialValues(<String, String>{
          SecureAiStore.providersStorageKey:
              '{"version":2,"providers":[],"unexpected":true}',
        });

        final result = await SecureAiStore().loadProviders();

        expect(result.status, AiStoreReadStatus.absent);
        expect(result.failure?.kind, AiStoreFailureKind.malformed);
      },
    );
  });

  group('account consent and history settings', () {
    test('round trips consent summary, UTC grant time, and limits', () async {
      final store = MemoryAiStore();
      final grantedAt = DateTime.parse('2026-10-20T10:11:12+08:00');
      final account = AiAccountRecord(
        consents: <String, AiConsentRecord>{
          'provider/one': AiConsentRecord(
            hash: 'contract-hash',
            summary: <String, Object?>{
              'recipient': 'api.example.test',
              'categories': <Object?>['diff', 'job_log'],
              'toolsEnabled': true,
            },
            grantedAt: grantedAt,
          ),
        },
        historyEnabled: true,
        retentionDays: 90,
        conversationTokenCap: 123456,
      );

      await store.saveAccount('instance#7', account);
      final result = await store.loadAccount('instance#7');

      expect(result.status, AiStoreReadStatus.found);
      expect(result.value!.historyEnabled, isTrue);
      expect(result.value!.retentionDays, 90);
      expect(result.value!.conversationTokenCap, 123456);
      expect(
        result.value!.consents['provider/one']!.grantedAt,
        grantedAt.toUtc(),
      );
      expect(
        result.value!.consents['provider/one']!.summary['recipient'],
        'api.example.test',
      );
      expect(await store.listAccountKeys(), <String>['instance#7']);
    });

    test('copyWith supports enable-after-key-write ordering', () {
      final disabled = AiAccountRecord();
      final enabled = disabled.copyWith(historyEnabled: true);

      expect(disabled.historyEnabled, isFalse);
      expect(enabled.historyEnabled, isTrue);
      expect(enabled.retentionDays, 30);
      expect(enabled.conversationTokenCap, 500000);
    });

    test('strict decoder rejects missing, extra, and invalid fields', () async {
      for (final payload in <String>[
        '{"version":1,"consents":{},"history":{"enabled":false,"retentionDays":30}}',
        '{"version":1,"consents":{},"history":{"enabled":false,"retentionDays":30},"conversationTokenCap":500000,"extra":1}',
        '{"version":1,"consents":{},"history":{"enabled":false,"retentionDays":14},"conversationTokenCap":500000}',
      ]) {
        FlutterSecureStorage.setMockInitialValues(<String, String>{
          SecureAiStore.accountKey('account'): payload,
        });

        final result = await SecureAiStore().loadAccount('account');

        expect(result.status, AiStoreReadStatus.absent);
        expect(result.failure?.kind, AiStoreFailureKind.malformed);
      }
    });

    test('deleteAccount removes only the account record', () async {
      final store = MemoryAiStore();
      final historyKey = Uint8List.fromList(List<int>.generate(32, (i) => i));
      await store.saveAccount('account', AiAccountRecord());
      await store.writeHistoryKey('account', historyKey);
      await store.setTombstone('account');

      await store.deleteAccount('account');

      expect(
        (await store.loadAccount('account')).status,
        AiStoreReadStatus.absent,
      );
      expect(
        (await store.readHistoryKey('account')).status,
        AiStoreReadStatus.found,
      );
      expect(
        (await store.readTombstone('account')).status,
        AiStoreReadStatus.found,
      );
    });
  });

  group('history key and tombstone state', () {
    test('history key distinguishes found, absent, and malformed', () async {
      const storage = FlutterSecureStorage();
      final store = SecureAiStore(storage);

      expect(
        (await store.readHistoryKey('account')).status,
        AiStoreReadStatus.absent,
      );

      final key = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
      await store.writeHistoryKey('account', key);
      final found = await store.readHistoryKey('account');
      expect(found.status, AiStoreReadStatus.found);
      expect(found.value, orderedEquals(key));

      await storage.write(
        key: SecureAiStore.historyKey('account'),
        value: base64Url.encode(<int>[1, 2, 3]),
      );
      final malformed = await store.readHistoryKey('account');
      expect(malformed.status, AiStoreReadStatus.absent);
      expect(malformed.failure?.kind, AiStoreFailureKind.malformed);
    });

    test('history key writes require exactly 32 bytes', () async {
      final store = MemoryAiStore();

      expect(
        () => store.writeHistoryKey('account', Uint8List(31)),
        throwsA(
          isA<AiStoreException>().having(
            (error) => error.failure.kind,
            'kind',
            AiStoreFailureKind.invalidValue,
          ),
        ),
      );
    });

    test(
      'tombstones enumerate decoded account keys and clear explicitly',
      () async {
        final store = MemoryAiStore();
        await store.setTombstone('z.example#9');
        await store.setTombstone('a.example#1');

        expect(await store.listTombstones(), <String>[
          'a.example#1',
          'z.example#9',
        ]);
        expect((await store.readTombstone('a.example#1')).value, isTrue);

        await store.clearTombstone('a.example#1');
        expect(
          (await store.readTombstone('a.example#1')).status,
          AiStoreReadStatus.absent,
        );
        expect(await store.listTombstones(), <String>['z.example#9']);
      },
    );

    test('secure tombstone and account keys use base64url identifiers', () {
      expect(
        SecureAiStore.accountKey('host/path#7'),
        contains('aG9zdC9wYXRoIzc'),
      );
      expect(
        SecureAiStore.tombstoneKey('host/path#7'),
        startsWith('ai_history_tombstone.v1.'),
      );
    });

    test('secure enumeration fails closed on malformed tombstones', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        '${SecureAiStore.tombstonePrefix}%%%': '1',
      });
      await expectLater(
        SecureAiStore().listTombstones(),
        throwsA(
          isA<AiStoreException>().having(
            (error) => error.failure.kind,
            'kind',
            AiStoreFailureKind.malformed,
          ),
        ),
      );

      FlutterSecureStorage.setMockInitialValues(<String, String>{
        SecureAiStore.tombstoneKey('account'): '0',
      });
      await expectLater(
        SecureAiStore().listTombstones(),
        throwsA(
          isA<AiStoreException>().having(
            (error) => error.failure.kind,
            'kind',
            AiStoreFailureKind.malformed,
          ),
        ),
      );
    });

    test('memory enumeration has the same fail-closed behavior', () async {
      final tombstones = MemoryAiStore()
        ..debugPut('${SecureAiStore.tombstonePrefix}%%%', '1');
      await expectLater(
        tombstones.listTombstones(),
        throwsA(
          isA<AiStoreException>().having(
            (error) => error.failure.kind,
            'kind',
            AiStoreFailureKind.malformed,
          ),
        ),
      );

      final accounts = MemoryAiStore()
        ..debugPut('${SecureAiStore.accountPrefix}%%%', '{}');
      await expectLater(
        accounts.listAccountKeys(),
        throwsA(
          isA<AiStoreException>().having(
            (error) => error.failure.kind,
            'kind',
            AiStoreFailureKind.malformed,
          ),
        ),
      );
    });
  });

  group('settings lifecycle', () {
    test('only recipient changes increment provider revision', () async {
      final store = MemoryAiStore();
      await store.saveProviders(<AiProviderConfig>[_provider(revision: 7)]);
      final controller = AiSettingsController(store);
      await controller.initialize();

      final renamed = await controller.saveProvider(
        _provider(name: 'Renamed', revision: 999),
      );
      expect(renamed.recipientRevision, 7);

      final moved = await controller.saveProvider(
        _provider(
          name: 'Renamed',
          baseUrl: 'https://other.example.test/v1',
          revision: 0,
        ),
      );
      expect(moved.recipientRevision, 8);
      expect(controller.recipientRevision('provider/one'), 8);
    });

    test('key changes bump recipient and secret-set revisions', () async {
      final store = MemoryAiStore();
      await store.saveProviders(<AiProviderConfig>[_provider(revision: 2)]);
      final controller = AiSettingsController(store);
      await controller.initialize();

      await expectLater(
        controller.saveProviderKey('provider/one', 'ordinaryword'),
        throwsA(
          isA<AiStoreException>().having(
            (error) => error.failure.kind,
            'kind',
            AiStoreFailureKind.confirmationRequired,
          ),
        ),
      );
      expect(controller.recipientRevision('provider/one'), 2);
      expect(controller.secretSetId, 0);

      await controller.saveProviderKey('provider/one', 'first-secret-value');
      expect(controller.recipientRevision('provider/one'), 3);
      expect(controller.secretSetId, 1);
      expect(
        controller.knownProviderKeys['provider/one'],
        'first-secret-value',
      );

      await controller.saveProviderKey('provider/one', 'first-secret-value');
      expect(controller.recipientRevision('provider/one'), 3);
      expect(controller.secretSetId, 1);

      await controller.deleteProviderKey('provider/one');
      expect(controller.recipientRevision('provider/one'), 4);
      expect(controller.secretSetId, 2);
      expect(controller.knownProviderKeys, isEmpty);
    });

    test('providers that require no key cannot store one', () async {
      final store = MemoryAiStore();
      await store.saveProviders(<AiProviderConfig>[
        _provider(requiresKey: false),
      ]);
      final controller = AiSettingsController(store);
      await controller.initialize();

      expect(
        () => controller.saveProviderKey('provider/one', 'secret-value-1234'),
        throwsA(
          isA<AiStoreException>().having(
            (error) => error.failure.kind,
            'kind',
            AiStoreFailureKind.invalidValue,
          ),
        ),
      );
    });

    test('changing a configured provider to no-key removes its key', () async {
      final store = MemoryAiStore();
      await store.saveProviders(<AiProviderConfig>[_provider(revision: 5)]);
      await store.saveProviderKey('provider/one', 'secret-value-1234');
      final controller = AiSettingsController(store);
      await controller.initialize();

      final saved = await controller.saveProvider(
        _provider(revision: 5, requiresKey: false),
      );

      expect(saved.recipientRevision, 6);
      expect(controller.secretSetId, 1);
      expect(controller.knownProviderKeys, isEmpty);
      expect(
        (await store.readProviderKey('provider/one')).status,
        AiStoreReadStatus.absent,
      );
    });

    test('grant, validity check, and revoke update consent revision', () async {
      final store = MemoryAiStore();
      await store.saveProviders(<AiProviderConfig>[_provider()]);
      final controller = AiSettingsController(store);
      await controller.initialize();
      await controller.loadAccount('account');
      final contract = _contract();

      expect(controller.isValid('account', contract), isFalse);
      await controller.grantConsent('account', contract, <String, Object?>{
        'recipient': 'api.example.test',
      }, grantedAt: DateTime.utc(2026, 10, 20));
      expect(controller.isValid('account', contract), isTrue);
      expect(controller.consentRevision('account'), 1);

      final changed = _contract(toolsEnabled: false);
      expect(controller.isValid('account', changed), isFalse);

      await controller.revokeConsent('account', 'provider/one');
      expect(controller.isValid('account', contract), isFalse);
      expect(controller.consentRevision('account'), 2);
    });

    test(
      'consent mutation preserves newer external history settings',
      () async {
        final store = MemoryAiStore();
        await store.saveProviders(<AiProviderConfig>[_provider()]);
        await store.saveAccount('account', AiAccountRecord());
        final controller = AiSettingsController(store);
        await controller.initialize();
        await controller.loadAccount('account');
        await store.saveAccount(
          'account',
          AiAccountRecord(
            historyEnabled: true,
            retentionDays: 90,
            conversationTokenCap: 123456,
          ),
        );

        await controller.grantConsent(
          'account',
          _contract(),
          const <String, Object?>{'recipient': 'example'},
        );

        final persisted = (await store.loadAccount('account')).value!;
        expect(persisted.historyEnabled, isTrue);
        expect(persisted.retentionDays, 90);
        expect(persisted.conversationTokenCap, 123456);
      },
    );

    test(
      'concurrent same-account grants serialize without lost updates',
      () async {
        final store = MemoryAiStore();
        await store.saveProviders(<AiProviderConfig>[
          _provider(id: 'first'),
          _provider(id: 'second'),
        ]);
        final controller = AiSettingsController(store);
        await controller.initialize();

        await Future.wait(<Future<void>>[
          controller.grantConsent(
            'account',
            _contract(providerId: 'first'),
            const <String, Object?>{'recipient': 'first'},
          ),
          controller.grantConsent(
            'account',
            _contract(providerId: 'second'),
            const <String, Object?>{'recipient': 'second'},
          ),
        ]);

        final persisted = (await store.loadAccount('account')).value!;
        expect(
          persisted.consents.keys,
          containsAll(<String>['first', 'second']),
        );
        expect(controller.consentRevision('account'), 2);
      },
    );

    test('concurrent key changes serialize every revision', () async {
      final store = MemoryAiStore();
      await store.saveProviders(<AiProviderConfig>[_provider(revision: 10)]);
      final controller = AiSettingsController(store);
      await controller.initialize();

      await Future.wait(<Future<void>>[
        controller.saveProviderKey('provider/one', 'first-secret-value'),
        controller.saveProviderKey('provider/one', 'second-secret-value'),
      ]);

      expect(controller.recipientRevision('provider/one'), 12);
      expect(controller.secretSetId, 2);
      expect(
        (await store.readProviderKey('provider/one')).value,
        'second-secret-value',
      );
    });

    test(
      'provider deletion removes its key and every account consent',
      () async {
        final store = MemoryAiStore();
        await store.saveProviders(<AiProviderConfig>[_provider()]);
        await store.saveProviderKey('provider/one', 'secret-value-1234');
        final record = AiAccountRecord(
          consents: <String, AiConsentRecord>{
            'provider/one': AiConsentRecord(
              hash: _contract().hash,
              summary: const <String, Object?>{'recipient': 'example'},
              grantedAt: DateTime.utc(2026, 10, 20),
            ),
            'other': AiConsentRecord(
              hash: 'other-hash',
              summary: const <String, Object?>{'recipient': 'other'},
              grantedAt: DateTime.utc(2026, 10, 20),
            ),
          },
        );
        await store.saveAccount('account-a', record);
        await store.saveAccount('account-b', record);
        final controller = AiSettingsController(store);
        await controller.initialize();

        await controller.deleteProvider('provider/one');

        expect(controller.providers, isEmpty);
        expect(controller.knownProviderKeys, isEmpty);
        expect(controller.secretSetId, 1);
        for (final accountKey in <String>['account-a', 'account-b']) {
          final account = (await store.loadAccount(accountKey)).value!;
          expect(account.consents, isNot(contains('provider/one')));
          expect(account.consents, contains('other'));
          expect(controller.consentRevision(accountKey), 1);
        }
      },
    );

    test('disposed controller rejects later mutations', () async {
      final store = MemoryAiStore();
      await store.saveProviders(<AiProviderConfig>[_provider()]);
      final controller = AiSettingsController(store);
      await controller.initialize();
      controller.dispose();

      await expectLater(
        controller.saveProvider(_provider(name: 'late')),
        throwsStateError,
      );
    });
  });
}

AiProviderConfig _provider({
  String id = 'provider/one',
  String name = 'Provider',
  String baseUrl = 'https://api.example.test/v1',
  int revision = 4,
  bool requiresKey = true,
}) => AiProviderConfig(
  id: id,
  name: name,
  presetId: 'custom',
  baseUrl: baseUrl,
  modelsUrl: 'https://models.example.test/v1',
  format: AiFormat.responses,
  model: 'model-1',
  authStyle: AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    streamUsage: true,
    toolChoice: true,
    replayChatExtras: true,
    includeEncryptedReasoning: true,
    promptCaching: true,
    requiresKey: requiresKey,
    maxRequestChars: 345678,
  ),
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: revision,
);

AiConsentContract _contract({
  String providerId = 'provider/one',
  bool toolsEnabled = true,
}) => AiConsentContract(
  providerId: providerId,
  origin: 'https://api.example.test/v1',
  format: AiFormat.responses,
  cleartext: false,
  toolsEnabled: toolsEnabled,
  toolCatalogueVersion: 1,
  dataCategories: <String>{'diff'},
  policyIdentity: 'custom',
  dataUse: AiDataUse.unknown,
  disclosureVersion: 1,
);
