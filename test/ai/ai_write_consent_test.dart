import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';

const _account = 'https://gitlab.example.test/team#42';

// Original account v1 shape, deliberately not produced by the v2 encoder.
const _v1 = '''{
  "version": 1,
  "consents": {
    "a": {"hash": "legacy-a", "summary": {"origin": "https://a.test/v1"},
          "grantedAt": "2026-10-21T12:00:00Z"},
    "b": {"hash": "legacy-b", "summary": {"origin": "https://b.test/v1"},
          "grantedAt": "2026-10-21T13:00:00Z"}
  },
  "history": {"enabled": true, "retentionDays": 90},
  "conversationTokenCap": 765432
}''';

AiProviderConfig _provider(String id, {bool tools = true}) => AiProviderConfig(
  id: id,
  name: 'Synthetic $id',
  presetId: 'custom',
  baseUrl: 'https://$id.example.test/v1',
  format: AiFormat.responses,
  model: 'synthetic',
  authStyle: AiAuthStyle.none,
  caps: const AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    requiresKey: false,
  ),
  allowLanCleartext: false,
  toolsEnabled: tools,
  recipientRevision: 1,
);

AiWritePolicy _policy({
  AiAutonomyLevel ceiling = AiAutonomyLevel.lowRiskAuto,
  Set<String> operations = const {'create_note', 'star_project'},
  Set<String> hardLine = const {'create_project'},
  Set<String> fixed = const {'mark_all_todos_done'},
  int version = 1,
  Duration window = aiWriteResetConfirmWindow,
}) => AiWritePolicy(
  policyVersion: version,
  agreedCeiling: ceiling,
  catalogueVersion: aiToolCatalogueVersion,
  operationIds: operations,
  hardLineOperationIds: hardLine,
  fixedConfirmOperationIds: fixed,
  resetConfirmWindow: window,
);

Matcher _failure(String operation) => throwsA(
  isA<AiStoreException>().having(
    (error) => error.failure.operation,
    'operation',
    operation,
  ),
);

void main() {
  test(
    '§15 row 11 original v1 migrates to v2 without resetting preferences',
    () {
      final migrated = AiAccountRecord.decode(_v1);
      expect(migrated.toJson()['version'], 2);
      expect(migrated.historyEnabled, isTrue);
      expect(migrated.retentionDays, 90);
      expect(migrated.conversationTokenCap, 765432);
      expect(migrated.ceiling, AiAutonomyLevel.lowRiskAuto);
      expect(migrated.startingLevel, AiAutonomyLevel.lowRiskAuto);
      expect(migrated.writePolicyRevision, 0);
      expect(migrated.aiAttribution, isFalse);
      expect(migrated.consents.keys, ['a', 'b']);
      for (final consent in migrated.consents.values) {
        expect(consent.agreedCeiling, AiAutonomyLevel.readOnly);
      }
      expect(migrated.consents['a']!.hash, 'legacy-a');
      expect(migrated.consents['b']!.summary['origin'], 'https://b.test/v1');
      final consents = Map<String, AiConsentRecord>.of(migrated.consents);
      consents['b'] = AiConsentRecord(
        hash: 'renewed-b',
        summary: {'writePolicy': _policy().toCanonicalJson()},
        grantedAt: DateTime.utc(2026, 10, 22),
        agreedCeiling: AiAutonomyLevel.lowRiskAuto,
      );
      final v2 = migrated.copyWith(consents: consents, aiAttribution: true);
      final restored = AiAccountRecord.decode(jsonEncode(v2.toJson()));
      expect(restored.toJson(), v2.toJson());
      expect(restored.consents['a']!.agreedCeiling, AiAutonomyLevel.readOnly);
      expect(
        restored.consents['b']!.agreedCeiling,
        AiAutonomyLevel.lowRiskAuto,
      );
    },
  );

  test('§15 row 11 strict v2 rejects invalid autonomy settings', () {
    final valid = AiAccountRecord().toJson();
    for (final changed in <Map<String, Object?>>[
      {'ceiling': 'unrecognized'},
      {'writePolicyRevision': -1},
      {'writePolicyRevision': 1.5},
      {'aiAttribution': 'true'},
      {'ceiling': 'readOnly', 'startingLevel': 'lowRiskAuto'},
      {'ceiling': 'bypass', 'startingLevel': 'conversationGrant'},
      {'version': 3},
    ]) {
      expect(
        () => AiAccountRecord.decode(jsonEncode({...valid, ...changed})),
        throwsFormatException,
        reason: '$changed',
      );
    }
    expect(
      () => AiAccountRecord(startingLevel: AiAutonomyLevel.conversationGrant),
      throwsArgumentError,
    );
  });

  test(
    '§15 row 11 canonical policy hashes every policy field and sorts sets',
    () {
      final provider = _provider('a');
      String hash(AiWritePolicy policy) =>
          aiConsentContractFor(provider, writePolicy: policy).hash;
      final original = hash(_policy());
      expect(
        hash(_policy(operations: {'star_project', 'create_note'})),
        original,
      );
      for (final changed in [
        _policy(ceiling: AiAutonomyLevel.bypass),
        _policy(operations: {'create_note'}),
        _policy(hardLine: {'delete_project'}),
        _policy(fixed: {'other_fixed_confirmation'}),
        _policy(version: 2),
        _policy(window: const Duration(hours: 25)),
      ]) {
        expect(hash(changed), isNot(original));
      }
      expect(
        hash(_policy(hardLine: {'z', 'a'}, fixed: {'last', 'first'})),
        hash(_policy(hardLine: {'a', 'z'}, fixed: {'first', 'last'})),
      );
      final levels =
          _policy().toCanonicalJson()['levels']! as Map<String, Object?>;
      expect(levels['readOnly'], {
        't1': 'deny',
        't2': 'deny',
        't3': 'deny',
        't4': 'deny',
        'hardLine': 'deny',
      });
      expect(levels['lowRiskAuto'], {
        't1': 'automatic',
        't2': 'confirm',
        't3': 'confirm',
        't4': 'confirmName',
        'hardLine': 'confirmName',
      });
      expect(
        (levels['bypass']! as Map<String, Object?>)['hardLine'],
        'confirmName',
      );
      final operations = {'create_note'};
      final contract = aiConsentContractFor(
        provider,
        writePolicy: _policy(operations: operations),
      );
      operations.add('delete_project');
      expect(contract.writePolicy!.operationIds, {'create_note'});
      expect(
        contract.writePolicy!.resetConfirmWindow,
        const Duration(hours: 24),
      );
      expect(
        () => contract.writePolicy!.operationIds.add('unsafe'),
        throwsUnsupportedError,
      );
    },
  );

  test(
    '§15 rows 11 and 12 read-only and tools-off contracts expose no writes',
    () {
      final readOnly = aiConsentContractFor(
        _provider('a'),
        writePolicy: _policy(ceiling: AiAutonomyLevel.readOnly),
      );
      expect(readOnly.writePolicy!.operationIds, isEmpty);
      expect(readOnly.writePolicy!.toCanonicalJson()['operationIds'], isEmpty);
      expect(
        effectiveCeiling(
          ceiling: AiAutonomyLevel.bypass,
          agreedCeiling: AiAccountRecord.decode(
            _v1,
          ).consents['a']!.agreedCeiling,
        ),
        AiAutonomyLevel.readOnly,
      );
      final off = aiConsentContractFor(
        _provider('a', tools: false),
        dataCategories: {
          'source',
          'tool_reads',
          'write_results',
          'attachment_metadata',
        },
        writePolicy: _policy(ceiling: AiAutonomyLevel.bypass),
      );
      expect(off.dataCategories, {'source'});
      expect(off.writePolicy!.agreedCeiling, AiAutonomyLevel.readOnly);
      expect(off.writePolicy!.operationIds, isEmpty);
      final on = aiConsentContractFor(
        _provider('a'),
        dataCategories: {'source'},
      );
      expect(on.dataCategories, {
        'source',
        'write_results',
        'attachment_metadata',
      });
      for (final ceiling in AiAutonomyLevel.values) {
        for (final agreed in AiAutonomyLevel.values) {
          expect(
            effectiveCeiling(ceiling: ceiling, agreedCeiling: agreed).index,
            ceiling.index < agreed.index ? ceiling.index : agreed.index,
          );
        }
      }
    },
  );

  test('§15 row 11 versions 1 through 5 require different consent', () {
    expect(aiToolCatalogueVersion, 5);
    expect(aiDisclosureVersion, 2);
    final provider = _provider('a');
    final current = aiConsentContractFor(provider, writePolicy: _policy());
    final hashes = <String>{
      for (final version in [1, 2, 3, 4, 5])
        aiConsentContractFor(
          provider,
          toolCatalogueVersion: version,
          writePolicy: _policy(),
        ).hash,
    };
    expect(hashes, hasLength(5));
    expect(
      aiConsentContractFor(
        provider,
        disclosureVersion: 1,
        writePolicy: _policy(),
      ).hash,
      isNot(current.hash),
    );
  });

  test(
    '§15 row 11 provider B renewal preserves A and non-default settings',
    () async {
      final store = MemoryAiStore();
      final settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      final a = await settings.saveProvider(_provider('a'));
      final b = await settings.saveProvider(_provider('b'));
      await store.saveAccount(_account, AiAccountRecord.decode(_v1));
      await settings.loadAccount(_account);
      final oldA = settings.accountRecord(_account)!.consents['a']!.toJson();
      final aReadOnly = settings.consentContractFor(
        _account,
        a,
        writePolicy: _policy(),
      );
      expect(aReadOnly.writePolicy!.agreedCeiling, AiAutonomyLevel.readOnly);
      expect(settings.isValid(_account, aReadOnly), isFalse);
      await settings.grantConsent(_account, aReadOnly, {});
      final grantedA = settings
          .accountRecord(_account)!
          .consents['a']!
          .toJson();
      expect(grantedA['hash'], isNot(oldA['hash']));
      final bHigher = settings.consentContractFor(
        _account,
        b,
        writePolicy: _policy(),
        agreedCeiling: AiAutonomyLevel.bypass,
      );
      await settings.grantConsent(_account, bHigher, {});
      final saved = (await store.loadAccount(_account)).value!;
      expect(saved.consents['a']!.toJson(), grantedA);
      expect(saved.consents['b']!.agreedCeiling, AiAutonomyLevel.bypass);
      expect(saved.historyEnabled, isTrue);
      expect(saved.retentionDays, 90);
      expect(saved.conversationTokenCap, 765432);
      expect(settings.isValid(_account, aReadOnly), isTrue);
      expect(settings.isValid(_account, bHigher), isTrue);
      expect(
        saved.consents['b']!.summary['writePolicy'],
        bHigher.writePolicy!.toCanonicalJson(),
      );
    },
  );

  test(
    '§15 row 11 lowering ceiling retains consent; higher consent needs new hash',
    () async {
      final store = MemoryAiStore();
      final settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      final provider = await settings.saveProvider(_provider('a'));
      final contract = settings.consentContractFor(
        _account,
        provider,
        writePolicy: _policy(),
      );
      await settings.grantConsent(_account, contract, {});
      final consentRevision = settings.consentRevision(_account);
      await settings.setAutonomySettings(
        _account,
        startingLevel: AiAutonomyLevel.confirmEach,
      );
      expect(settings.accountRecord(_account)!.writePolicyRevision, 0);
      expect(
        settings
            .consentContractFor(_account, provider, writePolicy: _policy())
            .hash,
        contract.hash,
      );

      await settings.setAutonomySettings(
        _account,
        ceiling: AiAutonomyLevel.readOnly,
      );
      final lowered = settings.accountRecord(_account)!;
      expect(lowered.ceiling, AiAutonomyLevel.readOnly);
      expect(lowered.startingLevel, AiAutonomyLevel.readOnly);
      expect(lowered.writePolicyRevision, 1);
      expect(settings.consentRevision(_account), consentRevision);
      final same = settings.consentContractFor(
        _account,
        provider,
        writePolicy: _policy(),
      );
      expect(same.hash, contract.hash);
      expect(settings.isValid(_account, same), isTrue);
      await settings.setAutonomySettings(_account, aiAttribution: true);
      expect(settings.accountRecord(_account)!.writePolicyRevision, 1);
      expect(settings.isValid(_account, same), isTrue);
      await settings.setAutonomySettings(
        _account,
        ceiling: AiAutonomyLevel.bypass,
      );
      final higher = settings.consentContractFor(
        _account,
        provider,
        writePolicy: _policy(),
        agreedCeiling: AiAutonomyLevel.bypass,
      );
      expect(higher.hash, isNot(contract.hash));
      expect(settings.isValid(_account, higher), isFalse);
      expect(
        effectiveCeiling(
          ceiling: AiAutonomyLevel.bypass,
          agreedCeiling: lowered.consents['a']!.agreedCeiling,
        ),
        AiAutonomyLevel.lowRiskAuto,
      );
      await settings.grantConsent(_account, higher, {});
      expect(settings.isValid(_account, higher), isTrue);
      expect(
        settings
            .accountRecord(_account)!
            .consents['a']!
            .summary['aiAttribution'],
        isTrue,
      );
    },
  );

  test(
    '§15 row 11 captured policy revision rejects a stale disclosure',
    () async {
      final settings = AiSettingsController(MemoryAiStore());
      addTearDown(settings.dispose);
      final provider = await settings.saveProvider(_provider('a'));
      final contract = settings.consentContractFor(
        _account,
        provider,
        writePolicy: _policy(),
      );
      await settings.setAutonomySettings(
        _account,
        ceiling: AiAutonomyLevel.confirmEach,
      );
      await expectLater(
        settings.grantConsent(
          _account,
          contract,
          {},
          expectedWritePolicyRevision: 0,
        ),
        _failure('writePolicyChanged'),
      );
      expect(settings.accountRecord(_account)!.consents, isEmpty);
    },
  );

  test(
    '§15 row 11 policy change during grant load rejects before writing',
    () async {
      final store = _PausedStore();
      final settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      final provider = await settings.saveProvider(_provider('a'));
      final contract = settings.consentContractFor(
        _account,
        provider,
        writePolicy: _policy(),
      );
      final loadPause = store.loadPause = Completer<void>();
      final grant = settings.grantConsent(_account, contract, {});
      final assertion = expectLater(grant, _failure('writePolicyChanged'));
      await store.loadStarted.future;
      await store.delegate.saveAccount(
        _account,
        AiAccountRecord().copyWith(ceiling: AiAutonomyLevel.readOnly),
      );
      loadPause.complete();
      await assertion;
      expect(
        (await store.delegate.loadAccount(_account)).value!.consents,
        isEmpty,
      );
    },
  );

  test(
    '§15 row 11 generation changes during secure save roll back only the grant',
    () async {
      final store = _PausedStore();
      final settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      final provider = await settings.saveProvider(_provider('a'));
      final contract = settings.consentContractFor(
        _account,
        provider,
        writePolicy: _policy(),
      );
      await settings.grantConsent(_account, contract, {'previous': true});
      final before = settings.accountRecord(_account)!.toJson();
      final savePause = store.savePause = Completer<void>();
      var generation = 1;
      final grant = settings.grantConsent(_account, contract, {
        'previous': false,
      }, isCurrent: () => generation == 1);
      final assertion = expectLater(grant, _failure('accountChanged'));
      await store.saveStarted.future;
      generation++;
      savePause.complete();
      await assertion;
      expect(
        (await store.delegate.loadAccount(_account)).value!.toJson(),
        before,
      );
      expect(settings.accountRecord(_account)!.toJson(), before);
    },
  );
}

/// Only the consent/settings persistence seam is implemented. Any unrelated
/// store use fails through noSuchMethod rather than returning blanket success.
final class _PausedStore implements AiStore {
  final delegate = MemoryAiStore();
  Completer<void>? loadPause;
  Completer<void>? savePause;
  final loadStarted = Completer<void>();
  final saveStarted = Completer<void>();

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() =>
      delegate.loadProviders();

  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) =>
      delegate.saveProviders(providers);

  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) =>
      delegate.readProviderKey(providerId);

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) =>
      delegate.readTombstone(accountKey);

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) async {
    if (loadPause case final pause?) {
      loadPause = null;
      loadStarted.complete();
      await pause.future;
    }
    return delegate.loadAccount(accountKey);
  }

  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) async {
    if (savePause case final pause?) {
      savePause = null;
      saveStarted.complete();
      await pause.future;
    }
    await delegate.saveAccount(accountKey, account);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
