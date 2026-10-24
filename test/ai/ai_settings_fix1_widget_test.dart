import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_settings_page.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

AiProviderConfig _provider(
  String id, {
  bool toolsEnabled = true,
  int recipientRevision = 1,
}) => AiProviderConfig(
  id: id,
  name: 'Synthetic $id',
  presetId: 'openai',
  baseUrl: 'https://example.test/v1',
  format: AiFormat.responses,
  model: 'synthetic-model',
  authStyle: AiAuthStyle.bearer,
  caps: const AiCaps(tokenLimitField: AiTokenLimitField.maxOutputTokens),
  allowLanCleartext: false,
  toolsEnabled: toolsEnabled,
  recipientRevision: recipientRevision,
);

Account _account() => Account(
  instance: GitLabInstance.parse('https://gitlab.example.test/team'),
  user: const GitLabUser(id: 42, username: 'river', name: 'River Lin'),
  token: 'synthetic-token',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => useLanguage(sourceLanguage));

  testWidgets('provider menu sets the selected provider as default', (
    tester,
  ) async {
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(store: store);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);
    await settings.saveProvider(_provider('first'));
    await settings.saveProvider(_provider('second'));
    await _pump(tester, settings, history);

    await tester.tap(find.byType(PopupMenuButton<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.aiMakeDefault));
    await tester.pumpAndSettle();

    expect(settings.providers.first.id, 'second');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-provider-second')),
        matching: find.text(l10n.aiDefaultProvider),
      ),
      findsOneWidget,
    );
  });

  testWidgets('revoke consent requires confirmation and removes it', (
    tester,
  ) async {
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(store: store);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);
    final account = _account();
    final provider = _provider('provider');
    await settings.saveProvider(provider);
    await settings.grantConsent(
      account.key,
      aiConsentContractFor(provider),
      const <String, Object?>{},
    );
    await _pump(tester, settings, history, account: account);

    await tester.tap(find.byTooltip(l10n.aiRevokeConsent));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiRevokeConsentDetail), findsOneWidget);
    await tester.tap(find.text(l10n.cancelAction));
    await tester.pumpAndSettle();
    expect(settings.accountRecord(account.key)!.consents, hasLength(1));

    final revision = settings.consentRevision(account.key);
    await tester.tap(find.byTooltip(l10n.aiRevokeConsent));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.confirmAction));
    await tester.pumpAndSettle();
    expect(settings.accountRecord(account.key)!.consents, isEmpty);
    expect(settings.consentRevision(account.key), revision + 1);
  });

  testWidgets('shows account identity without exposing the internal key', (
    tester,
  ) async {
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(store: store);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);
    final account = _account();
    await _pump(tester, settings, history, account: account);

    expect(find.text('River Lin'), findsOneWidget);
    expect(find.textContaining('@river'), findsOneWidget);
    expect(find.textContaining('gitlab.example.test'), findsOneWidget);
    expect(find.textContaining('#42'), findsNothing);
  });

  testWidgets('history retention is disabled off and shortening confirms', (
    tester,
  ) async {
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(store: store);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);
    final account = _account();
    await _pump(tester, settings, history, account: account);
    var retention = tester.widget<DropdownButtonFormField<int>>(
      find.byType(DropdownButtonFormField<int>),
    );
    expect(retention.onChanged, isNull);

    await tester.tap(find.byKey(const ValueKey('ai-history-switch')));
    await tester.pumpAndSettle();
    retention = tester.widget<DropdownButtonFormField<int>>(
      find.byType(DropdownButtonFormField<int>),
    );
    expect(retention.onChanged, isNotNull);
    await tester.ensureVisible(find.byType(DropdownButtonFormField<int>));
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.aiHistorySevenDays).last);
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiShortenRetentionDetail), findsOneWidget);
    await tester.tap(find.text(l10n.cancelAction));
    await tester.pumpAndSettle();
    expect((await store.loadAccount(account.key)).value!.retentionDays, 30);
  });

  testWidgets('changed provider marks saved consent for re-consent', (
    tester,
  ) async {
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(store: store);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);
    final account = _account();
    final provider = _provider('provider');
    await settings.saveProvider(provider);
    await settings.grantConsent(
      account.key,
      aiConsentContractFor(provider),
      const <String, Object?>{},
    );
    await settings.saveProvider(
      _provider('provider', toolsEnabled: false, recipientRevision: 2),
    );
    await _pump(tester, settings, history, account: account);

    expect(find.text(l10n.aiConsentNeedsReconsent), findsOneWidget);
  });

  testWidgets('a write consent a conversation would accept is not flagged', (
    tester,
  ) async {
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(store: store);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);
    final account = _account();
    final provider = _provider('provider');
    await settings.saveProvider(provider);
    await settings.loadAccount(account.key);
    // What the chat page grants: the write contract up to the ceiling.
    final contract = aiConversationConsentContract(
      settings,
      account.key,
      provider,
    );
    expect(contract.writePolicy, isNotNull);
    await settings.grantConsent(
      account.key,
      contract,
      const <String, Object?>{},
    );
    await _pump(tester, settings, history, account: account);

    expect(find.text(l10n.aiConsentNeedsReconsent), findsNothing);
  });

  testWidgets('invalid token cap text is not normalized into a saved value', (
    tester,
  ) async {
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(store: store);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);
    final account = _account();
    await store.saveAccount(account.key, AiAccountRecord());
    await _pump(tester, settings, history, account: account);
    final field = find.byKey(ValueKey('ai-token-cap-${account.key}'));

    await tester.ensureVisible(field);
    await tester.enterText(field, '-75000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      (await store.loadAccount(account.key)).value!.conversationTokenCap,
      500000,
    );

    await tester.tap(field);
    await tester.enterText(field, '75000garbage');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      (await store.loadAccount(account.key)).value!.conversationTokenCap,
      500000,
    );
  });

  testWidgets('cleanup retry reopens a retained account after page disposal', (
    tester,
  ) async {
    final account = _account();
    final store = _PausedCleanupStore();
    await store.inner.saveAccount(account.key, AiAccountRecord());
    await store.inner.setTombstone(account.key);
    final root = Directory.systemTemp.createTempSync('ai-settings-cleanup-');
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(
      store: store,
      files: AiHistoryFileStore(root: () async => root),
    );
    addTearDown(() {
      history.dispose();
      settings.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    var retainedChecks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AiSettingsPage(
          settings: settings,
          accountKey: account.key,
          account: account,
          history: history,
          isAccountRetained: (key) {
            retainedChecks += 1;
            return key == account.key;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(history.state(account.key), AiHistoryState.cleaning);

    final retry = find.widgetWithText(TextButton, l10n.aiHistoryRetryCleanup);
    tester.widget<TextButton>(retry).onPressed!.call();
    await tester.pump();
    await store.deleteStarted.future;
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    store.releaseDelete.complete();
    await tester.pumpAndSettle();

    expect(retainedChecks, 1);
    final mutations = AiAccountMutationCoordinator.forStore(store);
    expect(mutations.isCleaning(account.key), isFalse);
    final reopened = await mutations.mutate(
      account.key,
      (current) => current.copyWith(conversationTokenCap: 600000),
    );
    expect(reopened?.conversationTokenCap, 600000);
  });

  testWidgets(
    'malformed provider list offers confirmed reset and clears keys',
    (tester) async {
      final store = _MalformedProviderStore();
      await store.inner.saveProviderKey(
        'orphan',
        'synthetic-provider-key',
        acknowledgeWarning: true,
      );
      final settings = AiSettingsController(store);
      final history = AiHistoryCoordinator(store: store);
      addTearDown(settings.dispose);
      addTearDown(history.dispose);
      await _pump(tester, settings, history);

      expect(find.text(l10n.aiResetProviders), findsOneWidget);
      await tester.tap(find.text(l10n.aiResetProviders));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiResetProvidersDetail), findsOneWidget);
      await tester.tap(find.text(l10n.confirmAction));
      await tester.pumpAndSettle();

      expect(settings.providers, isEmpty);
      expect((await store.inner.readProviderKey('orphan')).isFound, isFalse);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  AiSettingsController settings,
  AiHistoryCoordinator history, {
  Account? account,
}) async {
  final selected = account ?? _account();
  await tester.pumpWidget(
    MaterialApp(
      home: AiSettingsPage(
        settings: settings,
        accountKey: selected.key,
        account: account,
        isAccountRetained: (key) => key == selected.key,
        history: history,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _MalformedProviderStore implements AiStore, AiStoreSecureInventory {
  final MemoryAiStore inner = MemoryAiStore();
  bool malformed = true;

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() async => malformed
      ? const AiStoreRead<List<AiProviderConfig>>.absent(
          AiStoreFailure(AiStoreFailureKind.malformed, 'loadProviders'),
        )
      : inner.loadProviders();

  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) async {
    malformed = false;
    await inner.saveProviders(providers);
  }

  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) =>
      inner.readProviderKey(providerId);

  @override
  Future<Map<String, String>> readAllProviderKeys(
    Iterable<String> providerIds,
  ) => inner.readAllProviderKeys(providerIds);

  @override
  Future<void> deleteProviderKey(String providerId) =>
      inner.deleteProviderKey(providerId);

  @override
  Future<List<String>> listProviderKeyIds() => inner.listProviderKeyIds();

  @override
  Future<List<String>> listAccountKeys() => inner.listAccountKeys();

  @override
  Future<AiSecureInventory> readSecureInventory() =>
      inner.readSecureInventory();

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) =>
      inner.loadAccount(accountKey);

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) =>
      inner.readTombstone(accountKey);

  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) =>
      inner.readHistoryKey(accountKey);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _PausedCleanupStore implements AiStore {
  final MemoryAiStore inner = MemoryAiStore();
  final Completer<void> deleteStarted = Completer<void>();
  final Completer<void> releaseDelete = Completer<void>();

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() =>
      inner.loadProviders();

  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) =>
      inner.saveProviders(providers);

  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) =>
      inner.readProviderKey(providerId);

  @override
  Future<Map<String, String>> readAllProviderKeys(
    Iterable<String> providerIds,
  ) => inner.readAllProviderKeys(providerIds);

  @override
  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  }) => inner.saveProviderKey(
    providerId,
    key,
    acknowledgeWarning: acknowledgeWarning,
  );

  @override
  Future<void> deleteProviderKey(String providerId) =>
      inner.deleteProviderKey(providerId);

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) =>
      inner.loadAccount(accountKey);

  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) =>
      inner.saveAccount(accountKey, account);

  @override
  Future<List<String>> listAccountKeys() => inner.listAccountKeys();

  @override
  Future<void> deleteAccount(String accountKey) =>
      inner.deleteAccount(accountKey);

  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) =>
      inner.readHistoryKey(accountKey);

  @override
  Future<void> writeHistoryKey(String accountKey, Uint8List key) =>
      inner.writeHistoryKey(accountKey, key);

  @override
  Future<void> deleteHistoryKey(String accountKey) async {
    if (!deleteStarted.isCompleted) deleteStarted.complete();
    await releaseDelete.future;
    await inner.deleteHistoryKey(accountKey);
  }

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) =>
      inner.readTombstone(accountKey);

  @override
  Future<void> setTombstone(String accountKey) =>
      inner.setTombstone(accountKey);

  @override
  Future<List<String>> listTombstones() => inner.listTombstones();

  @override
  Future<void> clearTombstone(String accountKey) =>
      inner.clearTombstone(accountKey);
}
