import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';

const _account = 'https://synthetic.example/gitlab#7';
final _stamp = DateTime.utc(2026, 10, 21);

AiProviderConfig _provider(
  String origin, {
  AiAuthStyle authStyle = AiAuthStyle.bearer,
  int requestChars = 400000,
  int outputTokens = 4096,
  bool requiresKey = true,
}) => AiProviderConfig(
  id: 'stable-editor-id',
  name: 'Synthetic provider',
  presetId: 'custom',
  baseUrl: origin,
  format: AiFormat.responses,
  model: 'synthetic-model',
  authStyle: authStyle,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    maxRequestChars: requestChars,
    maxOutputTokens: outputTokens,
    requiresKey: requiresKey,
  ),
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: 0,
);

AiSavedConversation _conversation(String id) => AiSavedConversation(
  id: id * 32,
  updatedAt: _stamp,
  conversation: AiConversation(
    items: <AiUserItem>[AiUserItem(text: 'synthetic prompt')],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('controller refuses caps that its decoder would reject', () async {
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    addTearDown(settings.dispose);

    for (final provider in <AiProviderConfig>[
      _provider('https://provider.example/v1', requestChars: 0),
      _provider('https://provider.example/v1', outputTokens: 511),
      _provider('https://provider.example/v1', outputTokens: 65537),
    ]) {
      await expectLater(
        settings.saveProvider(provider),
        throwsA(
          isA<AiStoreException>().having(
            (error) => error.failure.operation,
            'operation',
            'saveProviderCaps',
          ),
        ),
      );
      expect((await store.loadProviders()).value ?? const [], isEmpty);
    }

    await settings.saveProvider(
      _provider('https://provider.example/v1', requestChars: 7999),
    );
    await settings.saveProvider(
      _provider('https://provider.example/v1', requestChars: 400001),
    );
    expect(
      (await store.loadProviders()).value?.single.caps.maxRequestChars,
      400001,
    );
  });

  test(
    'initialization state retains a typed load failure until recovery',
    () async {
      final store = _FailingKeyStore()..failNextProviderLoad = true;
      final settings = AiSettingsController(store);
      addTearDown(settings.dispose);

      expect(settings.initialized, isFalse);
      await expectLater(
        settings.initialize(),
        throwsA(isA<AiStoreException>()),
      );
      expect(settings.initializing, isFalse);
      expect(settings.initialized, isFalse);
      expect(
        settings.initializationFailure?.kind,
        AiStoreFailureKind.unavailable,
      );

      await settings.initialize();
      expect(settings.initialized, isTrue);
      expect(settings.initializationFailure, isNull);
    },
  );

  test(
    'failed replacement key write preserves old recipient across restart',
    () async {
      final store = _FailingKeyStore();
      var settings = AiSettingsController(store);
      await settings.initialize();
      await settings.saveProviderWithKey(
        _provider('https://old.example/v1'),
        key: 'synthetic-old-secret',
      );
      store.failNextKeyWrite = true;

      await expectLater(
        settings.saveProviderWithKey(
          _provider('https://new.example/v1'),
          key: 'synthetic-new-secret',
        ),
        throwsA(isA<AiStoreException>()),
      );
      expect(settings.providers.single.baseUrl, 'https://old.example/v1');
      expect(settings.knownProviderKeys.values.single, 'synthetic-old-secret');

      settings.dispose();
      await Future<void>.delayed(Duration.zero);
      settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      await settings.initialize();
      expect(settings.providers.single.baseUrl, 'https://old.example/v1');
      expect(settings.knownProviderKeys.values.single, 'synthetic-old-secret');
    },
  );

  test(
    'interrupted provider commit cannot expose the replacement key after restart',
    () async {
      final store = _FailingKeyStore();
      var settings = AiSettingsController(store);
      await settings.initialize();
      await settings.saveProviderWithKey(
        _provider('https://old.example/v1'),
        key: 'synthetic-old-secret',
      );
      store
        ..failNextProviderSave = true
        ..failRollbackKeyWrite = true;

      await expectLater(
        settings.saveProviderWithKey(
          _provider('https://new.example/v1'),
          key: 'synthetic-new-secret',
        ),
        throwsA(anything),
      );
      settings.dispose();
      await Future<void>.delayed(Duration.zero);
      settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      await settings.initialize();

      expect(settings.providers.single.baseUrl, 'https://old.example/v1');
      expect(settings.knownProviderKeys, isEmpty);
      expect(
        settings.providerKeyFor(_provider('https://old.example/v1')),
        isNull,
      );
    },
  );

  test(
    'keyless old recipient cannot adopt a key written for a new recipient',
    () async {
      final store = _FailingKeyStore();
      var settings = AiSettingsController(store);
      await settings.initialize();
      await settings.saveProvider(_provider('https://old.example/v1'));
      store
        ..writeThenFailNextKey = true
        ..failNextKeyDelete = true;

      await expectLater(
        settings.saveProviderWithKey(
          _provider('https://new.example/v1'),
          key: 'synthetic-new-secret',
        ),
        throwsA(anything),
      );
      settings.dispose();
      await Future<void>.delayed(Duration.zero);
      settings = AiSettingsController(store);
      addTearDown(settings.dispose);
      await settings.initialize();

      expect(settings.providers.single.baseUrl, 'https://old.example/v1');
      expect(settings.knownProviderKeys, isEmpty);
    },
  );

  test('stored key is bound to normalized origin and auth style', () async {
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    addTearDown(settings.dispose);
    final original = _provider('https://provider.example:443/v1/');
    await settings.saveProviderWithKey(original, key: 'synthetic-old-secret');

    expect(
      settings.providerKeyFor(_provider('https://provider.example/v1')),
      'synthetic-old-secret',
    );
    final changedOrigin = _provider('https://other.example/v1');
    final changedAuth = _provider(
      'https://provider.example/v1',
      authStyle: AiAuthStyle.apiKey,
    );
    expect(settings.providerKeyFor(changedOrigin), isNull);
    expect(settings.providerKeyFor(changedAuth), isNull);
    expect(settings.providerKeyFor(_provider('not a URL')), isNull);
    expect(
      settings.providerKeyFor(
        _provider('https://provider.example/v1', requiresKey: false),
      ),
      isNull,
    );
    await expectLater(
      settings.saveProviderWithKey(changedOrigin),
      throwsA(isA<AiStoreException>()),
    );
    await expectLater(
      settings.saveProviderWithKey(changedAuth),
      throwsA(isA<AiStoreException>()),
    );

    await settings.saveProviderWithKey(
      changedOrigin,
      key: 'synthetic-new-secret',
    );
    expect(
      (await store.readProviderKey(original.id)).value,
      'synthetic-new-secret',
    );
  });

  test('same key is rebound when its recipient changes', () async {
    final store = MemoryAiStore();
    var settings = AiSettingsController(store);
    await settings.saveProviderWithKey(
      _provider('https://old.example/v1'),
      key: 'synthetic-shared-secret',
    );
    await settings.saveProviderWithKey(
      _provider('https://new.example/v1'),
      key: 'synthetic-shared-secret',
    );
    settings.dispose();

    settings = AiSettingsController(store);
    addTearDown(settings.dispose);
    await settings.initialize();
    expect(
      settings.providerKeyFor(_provider('https://new.example/v1')),
      'synthetic-shared-secret',
    );
  });

  test('legacy recipient change deletes its key before publication', () async {
    final store = _FailingKeyStore();
    var settings = AiSettingsController(store);
    await settings.initialize();
    final original = _provider('https://old.example/v1');
    final changed = _provider('https://new.example/v1');
    await settings.saveProviderWithKey(original, key: 'synthetic-old-secret');
    store.failNextKeyDelete = true;

    await expectLater(
      settings.saveProvider(changed),
      throwsA(isA<AiStoreException>()),
    );
    expect(settings.providers.single.baseUrl, original.baseUrl);
    expect(settings.knownProviderKeys, contains(original.id));
    expect(
      (await store.memory.loadProviders()).value!.single.baseUrl,
      original.baseUrl,
    );
    expect(
      (await store.memory.readProviderKey(original.id)).value,
      'synthetic-old-secret',
    );

    await settings.saveProvider(changed);
    expect(settings.providers.single.baseUrl, changed.baseUrl);
    expect(settings.knownProviderKeys, isEmpty);
    expect((await store.memory.readProviderKey(original.id)).isFound, isFalse);
    expect(
      (await store.memory.readProviderKeyBinding(original.id)).isFound,
      isFalse,
    );
    settings.dispose();

    settings = AiSettingsController(store);
    addTearDown(settings.dispose);
    await settings.initialize();
    expect(settings.providers.single.baseUrl, changed.baseUrl);
    expect(settings.knownProviderKeys, isEmpty);
  });

  test(
    'history-only clear marker survives restart, blocks enable, and resets notices',
    () async {
      final root = Directory.systemTemp.createTempSync('ai-fix1-clear-');
      addTearDown(() {
        removeAiHistoryDirectory = (directory) =>
            directory.deleteSync(recursive: true);
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = MemoryAiStore();
      var history = AiHistoryCoordinator(
        store: store,
        files: AiHistoryFileStore(root: () async => root, clock: () => _stamp),
      );
      addTearDown(history.dispose);
      await history.enable(_account);
      await history.save(_account, _conversation('a'));

      removeAiHistoryDirectory = (_) =>
          throw const FileSystemException('synthetic clear failure');
      await expectLater(history.clearHistory(_account), throwsA(anything));
      expect((await store.readHistoryClearMarker(_account)).value, isTrue);

      history.dispose();
      history = AiHistoryCoordinator(
        store: store,
        files: AiHistoryFileStore(root: () async => root, clock: () => _stamp),
      );
      expect(await history.load(_account), AiHistoryState.readFailed);
      expect(await history.enable(_account), AiHistoryState.readFailed);

      removeAiHistoryDirectory = (directory) =>
          directory.deleteSync(recursive: true);
      await history.clearHistory(_account);
      expect((await store.readHistoryClearMarker(_account)).isFound, isFalse);
      expect(history.state(_account), AiHistoryState.disabled);
      expect(history.removedUnreadable(_account), isFalse);
      expect(history.notice(_account), isNull);
    },
  );

  test(
    'successful clear resets recovery notices in the same coordinator',
    () async {
      final root = Directory.systemTemp.createTempSync('ai-fix1-notices-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = MemoryAiStore();
      final history = AiHistoryCoordinator(
        store: store,
        files: AiHistoryFileStore(root: () async => root, clock: () => _stamp),
      );
      addTearDown(history.dispose);
      await history.enable(_account);
      await history.save(_account, _conversation('a'));
      final directory = await history.files.directory(_account);
      final conversation = File('${directory.path}/c_${'a' * 32}.v1.bin');
      final corrupted = conversation.readAsBytesSync()..[15] ^= 1;
      conversation.writeAsBytesSync(corrupted);
      await history.save(_account, _conversation('b'));
      expect(history.removedUnreadable(_account), isTrue);

      await history.clearHistory(_account);

      expect(history.removedUnreadable(_account), isFalse);
      expect(history.canClearUnsupportedIndex(_account), isFalse);
      expect(history.notice(_account), isNull);
    },
  );

  test('failed initial clear-marker write preserves enabled history', () async {
    final root = Directory.systemTemp.createTempSync('ai-fix1-marker-');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final store = _FailingHistoryStore();
    final history = AiHistoryCoordinator(
      store: store,
      files: AiHistoryFileStore(root: () async => root, clock: () => _stamp),
    );
    addTearDown(history.dispose);
    await history.enable(_account);
    await history.save(_account, _conversation('a'));
    final directory = await history.files.directory(_account);
    store.failNextMarkerWrite = true;

    await expectLater(history.clearHistory(_account), throwsA(anything));

    expect(history.state(_account), AiHistoryState.ready);
    expect(
      (await store.memory.loadAccount(_account)).value!.historyEnabled,
      isTrue,
    );
    expect((await store.memory.readHistoryKey(_account)).isFound, isTrue);
    expect(
      (await store.memory.readHistoryClearMarker(_account)).isFound,
      isFalse,
    );
    expect(directory.existsSync(), isTrue);
    expect(
      await history.save(_account, _conversation('b')),
      AiHistorySaveResult.saved,
    );
  });

  test(
    'marker success followed by account-write failure blocks saves and retries',
    () async {
      final root = Directory.systemTemp.createTempSync('ai-fix1-account-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final store = _FailingHistoryStore();
      var history = AiHistoryCoordinator(
        store: store,
        files: AiHistoryFileStore(root: () async => root, clock: () => _stamp),
      );
      addTearDown(history.dispose);
      await history.enable(_account);
      await history.save(_account, _conversation('a'));
      store.failNextAccountSave = true;

      await expectLater(history.clearHistory(_account), throwsA(anything));

      expect(history.state(_account), AiHistoryState.readFailed);
      expect((await store.readHistoryClearMarker(_account)).value, isTrue);
      expect(
        await history.save(_account, _conversation('b')),
        AiHistorySaveResult.cancelled,
      );

      history.dispose();
      history = AiHistoryCoordinator(
        store: store,
        files: AiHistoryFileStore(root: () async => root, clock: () => _stamp),
      );
      expect(await history.load(_account), AiHistoryState.readFailed);
      await history.clearHistory(_account);
      expect(history.state(_account), AiHistoryState.disabled);
      expect((await store.readHistoryClearMarker(_account)).isFound, isFalse);
    },
  );
}

final class _FailingKeyStore implements AiStore, AiProviderKeyBindingStore {
  final MemoryAiStore memory = MemoryAiStore();
  bool failNextKeyWrite = false;
  bool failNextProviderLoad = false;
  bool failNextProviderSave = false;
  bool failRollbackKeyWrite = false;
  bool writeThenFailNextKey = false;
  bool failNextKeyDelete = false;

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() async {
    if (failNextProviderLoad) {
      failNextProviderLoad = false;
      return const AiStoreRead<List<AiProviderConfig>>.unavailable(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'loadProviders'),
      );
    }
    return memory.loadProviders();
  }

  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) async {
    if (failNextProviderSave) {
      failNextProviderSave = false;
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'saveProviders'),
      );
    }
    await memory.saveProviders(providers);
  }

  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) =>
      memory.readProviderKey(providerId);

  @override
  Future<Map<String, String>> readAllProviderKeys(Iterable<String> ids) =>
      memory.readAllProviderKeys(ids);

  @override
  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  }) async {
    if (failNextKeyWrite) {
      failNextKeyWrite = false;
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'saveProviderKey'),
      );
    }
    if (failRollbackKeyWrite && key == 'synthetic-old-secret') {
      failRollbackKeyWrite = false;
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'saveProviderKey'),
      );
    }
    if (writeThenFailNextKey) {
      writeThenFailNextKey = false;
      await memory.saveProviderKey(
        providerId,
        key,
        acknowledgeWarning: acknowledgeWarning,
      );
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'saveProviderKey'),
      );
    }
    await memory.saveProviderKey(
      providerId,
      key,
      acknowledgeWarning: acknowledgeWarning,
    );
  }

  @override
  Future<void> deleteProviderKey(String providerId) async {
    if (failNextKeyDelete) {
      failNextKeyDelete = false;
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'deleteProviderKey'),
      );
    }
    await memory.deleteProviderKey(providerId);
  }

  @override
  Future<AiStoreRead<String>> readProviderKeyBinding(String providerId) =>
      memory.readProviderKeyBinding(providerId);

  @override
  Future<void> saveProviderKeyBinding(String providerId, String binding) =>
      memory.saveProviderKeyBinding(providerId, binding);

  @override
  Future<void> deleteProviderKeyBinding(String providerId) =>
      memory.deleteProviderKeyBinding(providerId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FailingHistoryStore implements AiStore, AiHistoryClearMarkerStore {
  final MemoryAiStore memory = MemoryAiStore();
  bool failNextMarkerWrite = false;
  bool failNextAccountSave = false;

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) =>
      memory.loadAccount(accountKey);
  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) async {
    if (failNextAccountSave) {
      failNextAccountSave = false;
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'saveAccount'),
      );
    }
    await memory.saveAccount(accountKey, account);
  }

  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) =>
      memory.readHistoryKey(accountKey);
  @override
  Future<void> writeHistoryKey(String accountKey, Uint8List key) =>
      memory.writeHistoryKey(accountKey, key);
  @override
  Future<void> deleteHistoryKey(String accountKey) =>
      memory.deleteHistoryKey(accountKey);
  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) =>
      memory.readTombstone(accountKey);
  @override
  Future<AiStoreRead<bool>> readHistoryClearMarker(String accountKey) =>
      memory.readHistoryClearMarker(accountKey);
  @override
  Future<void> setHistoryClearMarker(String accountKey) async {
    if (failNextMarkerWrite) {
      failNextMarkerWrite = false;
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'setHistoryClearMarker'),
      );
    }
    await memory.setHistoryClearMarker(accountKey);
  }

  @override
  Future<void> clearHistoryClearMarker(String accountKey) =>
      memory.clearHistoryClearMarker(accountKey);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
