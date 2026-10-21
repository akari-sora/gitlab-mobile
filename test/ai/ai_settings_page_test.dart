import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_settings_page.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

AiProviderConfig provider(String id, {int output = 4096}) => AiProviderConfig(
  id: id,
  name: 'Synthetic $id',
  presetId: 'openai',
  baseUrl: 'https://example.test/v1',
  format: AiFormat.responses,
  model: 'synthetic-model',
  authStyle: AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    maxOutputTokens: output,
  ),
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default survives editing, deletion and a store reload', () async {
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    await settings.saveProvider(provider('first'));
    await settings.saveProvider(provider('second'));
    await settings.setDefaultProvider('second');
    await settings.saveProvider(provider('second', output: 512));
    expect(settings.providers.first.id, 'second');
    await settings.initialize();
    expect(settings.providers.first.id, 'second');
    expect(settings.providers.first.caps.maxOutputTokens, 512);
    await settings.deleteProvider('second');
    expect(settings.providers.single.id, 'first');
    settings.dispose();
  });

  test(
    'history toggles, retention, token cap and clear preserve consents',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ai-mr5-history-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = MemoryAiStore();
      final settings = AiSettingsController(store);
      final history = AiHistoryCoordinator(
        store: store,
        files: AiHistoryFileStore(root: () async => directory),
      );
      addTearDown(settings.dispose);
      addTearDown(history.dispose);
      await store.saveAccount(
        'account',
        AiAccountRecord(
          consents: {
            'provider': AiConsentRecord(
              hash: 'synthetic-hash',
              summary: const {},
              grantedAt: DateTime.utc(2026),
            ),
          },
        ),
      );
      await history.enable('account');
      expect(history.state('account'), AiHistoryState.ready);
      await history.setRetention('account', 7);
      await settings.setConversationTokenCap('account', 50000);
      await history.disable('account');
      expect(
        (await store.loadAccount('account')).value!.historyEnabled,
        isFalse,
      );
      expect((await store.readHistoryKey('account')).isFound, isTrue);
      await history.enable('account');
      await history.clearHistory('account');
      final record = (await store.loadAccount('account')).value!;
      expect(record.consents.keys, ['provider']);
      expect(record.retentionDays, 7);
      expect(record.conversationTokenCap, 50000);
      expect(record.historyEnabled, isFalse);
      expect((await store.readHistoryKey('account')).isFound, isFalse);
      expect(history.state('account'), AiHistoryState.disabled);
      await history.enable('account');
      expect(history.state('account'), AiHistoryState.ready);
    },
  );

  testWidgets('delete requires confirmation and removes key and all consents', (
    tester,
  ) async {
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(store: store);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);
    await settings.saveProvider(provider('first'));
    await settings.saveProviderKey('first', 'synthetic-key-12345');
    for (final account in ['a', 'b']) {
      await store.saveAccount(
        account,
        AiAccountRecord(
          consents: {
            'first': AiConsentRecord(
              hash: 'hash',
              summary: const {},
              grantedAt: DateTime.utc(2026),
            ),
          },
        ),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: AiSettingsPage(
          settings: settings,
          history: history,
          accountKey: 'a',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.aiDeleteProvider));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiDeleteProviderDetail), findsOneWidget);
    await tester.tap(find.text(l10n.cancelAction));
    await tester.pumpAndSettle();
    expect(settings.providers, hasLength(1));
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.aiDeleteProvider));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.confirmAction));
    await tester.pumpAndSettle();
    expect(settings.providers, isEmpty);
    expect((await store.readProviderKey('first')).isFound, isFalse);
    for (final account in ['a', 'b']) {
      expect((await store.loadAccount(account)).value!.consents, isEmpty);
    }
  });

  testWidgets(
    'token cap saves by button and focus loss without keyboard submit',
    (tester) async {
      final store = MemoryAiStore();
      final settings = AiSettingsController(store);
      final history = AiHistoryCoordinator(store: store);
      addTearDown(settings.dispose);
      addTearDown(history.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AiSettingsPage(
            settings: settings,
            history: history,
            accountKey: 'account',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byType(TextFormField);
      await tester.ensureVisible(field);
      await tester.enterText(field, '75000');
      await tester.tap(find.byTooltip(l10n.saveAction));
      await tester.pumpAndSettle();
      expect(
        (await store.loadAccount('account')).value!.conversationTokenCap,
        75000,
      );
      await tester.enterText(field, '90000');
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pumpAndSettle();
      expect(
        (await store.loadAccount('account')).value!.conversationTokenCap,
        90000,
      );
      await tester.enterText(field, '1');
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pumpAndSettle();
      expect(
        (await store.loadAccount('account')).value!.conversationTokenCap,
        90000,
      );
    },
  );

  for (final language in [
    sourceLanguage,
    appLanguages.firstWhere((l) => l.tag == 'ar'),
  ]) {
    testWidgets('settings narrow large text dark ${language.tag}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      useLanguage(language);
      final store = MemoryAiStore();
      final settings = AiSettingsController(store);
      final history = AiHistoryCoordinator(store: store);
      addTearDown(settings.dispose);
      addTearDown(history.dispose);
      await settings.saveProvider(provider('a-long-synthetic-name'));
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: Directionality(
              textDirection: language.rtl
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              child: child!,
            ),
          ),
          home: AiSettingsPage(
            settings: settings,
            history: history,
            accountKey: 'synthetic-account',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = find.byType(Scrollable).first;
      for (var i = 0; i < 12; i++) {
        await tester.drag(scrollable, const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}
