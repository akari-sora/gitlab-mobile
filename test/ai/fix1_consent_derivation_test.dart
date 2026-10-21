import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_consent_dialog.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

AiProviderConfig provider({
  AiPreset? preset,
  String model = 'gpt-6-luna',
  AiFormat format = AiFormat.responses,
  bool tools = true,
}) {
  final selected = preset ?? AiPresets.openCodeGo;
  return AiProviderConfig(
    id: 'synthetic',
    name: 'Synthetic provider',
    presetId: selected.id,
    baseUrl: selected.baseUrlFor(format),
    format: format,
    model: model,
    authStyle: selected.authStyle,
    caps: selected.capsFor(format),
    allowLanCleartext: false,
    toolsEnabled: tools,
    recipientRevision: 1,
  );
}

void main() {
  tearDown(() => useLanguage(sourceLanguage));

  test('production OpenCode Go same-origin model swaps change consent', () {
    final original = aiConsentContractFor(provider());
    final training = aiConsentContractFor(
      provider(model: 'muse-spark-1.3-contributor'),
    );
    expect(training.origin, original.origin);
    expect(training.hash, isNot(original.hash));
    expect(training.dataUse, AiDataUse.training);
    expect(training.retentionDays, isNull);
    expect(original.retentionDays, 30);
    expect(original.policyUrl, AiPresets.openCodePolicySource);
    expect(original.policyCheckedOn, AiPresets.policyCheckedOn);
    final zero = aiConsentContractFor(
      provider(model: 'qwen3.8-flash', format: AiFormat.anthropicMessages),
    );
    final thirty = aiConsentContractFor(
      provider(model: 'claude-haiku-5-5', format: AiFormat.anthropicMessages),
    );
    expect(zero.origin, thirty.origin);
    expect(zero.hash, isNot(thirty.hash));
    expect(zero.retentionDays, 0);
    expect(thirty.retentionDays, 30);
  });

  test('non-model-sensitive model swaps keep consent stable', () {
    final first = aiConsentContractFor(provider(preset: AiPresets.openAi));
    final second = aiConsentContractFor(
      provider(preset: AiPresets.openAi, model: 'synthetic-other-model'),
    );
    expect(first.routedModel, isNull);
    expect(first.hash, second.hash);
  });

  test('custom policy identity is explicit and model-sensitive', () {
    AiProviderConfig custom(String model) => AiProviderConfig(
      id: 'custom',
      name: 'Custom synthetic',
      presetId: 'custom',
      baseUrl: 'https://synthetic.example:443/v1/',
      format: AiFormat.chatCompletions,
      model: model,
      authStyle: AiAuthStyle.bearer,
      caps: AiPresets.custom.capsFor(AiFormat.chatCompletions),
      allowLanCleartext: false,
      toolsEnabled: false,
      recipientRevision: 1,
    );
    final first = aiConsentContractFor(custom('first-model'));
    final second = aiConsentContractFor(custom('second-model'));
    expect(first.policyIdentity, 'custom');
    expect(first.origin, 'https://synthetic.example/v1');
    expect(first.dataUse, AiDataUse.unknown);
    expect(first.hash, isNot(second.hash));
  });

  test('off-table and wrong-format policies stay unknown', () {
    expect(
      aiConsentContractFor(provider(model: 'unlisted')).dataUse,
      AiDataUse.unknown,
    );
    final wrong = aiConsentContractFor(
      provider(model: 'claude-haiku-5-5', format: AiFormat.responses),
    );
    expect(wrong.dataUse, AiDataUse.unknown);
    expect(wrong.retentionDays, isNull);
    expect(wrong.policyUrl, isNull);
  });

  test(
    'tools and category catalogue and disclosure revisions change consent',
    () {
      final initial = aiConsentContractFor(provider());
      final off = aiConsentContractFor(provider(tools: false));
      expect(off.dataCategories, isNot(contains('tool_reads')));
      expect(initial.dataCategories, contains('tool_reads'));
      expect(initial.hash, isNot(off.hash));
      expect(
        aiConsentContractFor(provider(), toolCatalogueVersion: 2).hash,
        isNot(initial.hash),
      );
      expect(
        aiConsentContractFor(provider(), disclosureVersion: 2).hash,
        isNot(initial.hash),
      );
      expect(
        aiConsentContractFor(provider(), dataCategories: {'source'}).hash,
        isNot(initial.hash),
      );
    },
  );

  test('summary uses structured policy fields and never parses identity', () {
    final contract = AiConsentContract(
      providerId: 'synthetic',
      origin: 'https://example.com/v1',
      format: AiFormat.responses,
      cleartext: false,
      toolsEnabled: false,
      toolCatalogueVersion: 1,
      dataCategories: {'source'},
      policyIdentity: 'unstructured|training|999|https://wrong.example',
      dataUse: AiDataUse.training,
      disclosureVersion: 1,
      policyUrl: 'https://policy.example/privacy',
      retentionDays: 7,
      policyCheckedOn: '2026-10-20',
    );
    final summary = aiConsentSummary(contract);
    expect(summary['policyUrl'], 'https://policy.example/privacy');
    expect(summary['retentionDays'], 7);
    expect(summary['policyCheckedOn'], '2026-10-20');
  });

  testWidgets('dialog derives from recipient and ignores forged policy', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    addTearDown(settings.dispose);
    await settings.saveProvider(provider(model: 'muse-spark-1.3-contributor'));
    await tester.pumpWidget(host(settings, aiConsentContractFor(provider())));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(l10n.aiConsentTrainingWarning),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(l10n.aiConsentTrainingWarning), findsOneWidget);
    expect(find.text(l10n.aiConsentRetentionNotStated), findsOneWidget);
    await tester.tap(find.text(l10n.aiConsentAgreeAndSend));
    await tester.pumpAndSettle();
    final saved = settings.accountRecord('account')!.consents['synthetic']!;
    expect(saved.hash, aiConsentContractFor(settings.providers.single).hash);
    expect(saved.summary['dataUse'], 'training');
  });

  for (final days in <int?>[null, 7]) {
    testWidgets('training record discloses retention $days', (tester) async {
      final summary = aiConsentSummary(
        aiConsentContractFor(provider(model: 'muse-spark-1.3-contributor')),
      );
      if (days != null) summary['retentionDays'] = days;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () => showAiConsentRecordDialog(
                  context,
                  AiConsentRecord(
                    hash: 'synthetic',
                    summary: summary,
                    grantedAt: DateTime.utc(2026, 10, 20),
                  ),
                ),
                child: const Text('open'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(l10n.aiConsentTrainingWarning),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(l10n.aiConsentTrainingWarning), findsOneWidget);
      expect(
        find.text(
          days == null
              ? l10n.aiConsentRetentionNotStated
              : l10n.aiConsentRetentionDays,
        ),
        findsOneWidget,
      );
    });
  }

  testWidgets('Arabic RTL dark dialog scrolls at 320dp and 2x text', (
    tester,
  ) async {
    useLanguage(languageForTag('ar')!);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final settings = AiSettingsController(MemoryAiStore());
    addTearDown(settings.dispose);
    await settings.saveProvider(provider(model: 'muse-spark-1.3-contributor'));
    await tester.pumpWidget(
      host(
        settings,
        aiConsentContractFor(settings.providers.single),
        arabic: true,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      Directionality.of(tester.element(find.byType(ListView))),
      TextDirection.rtl,
    );
    await tester.scrollUntilVisible(
      find.text(l10n.aiConsentIrreversible),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    expect(find.text(l10n.aiConsentIrreversible), findsOneWidget);
  });

  testWidgets('saved disclosure date follows Arabic locale', (tester) async {
    useLanguage(languageForTag('ar')!);
    final record = AiConsentRecord(
      hash: 'synthetic',
      summary: aiConsentSummary(aiConsentContractFor(provider())),
      grantedAt: DateTime.utc(2026, 10, 20),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAiConsentRecordDialog(context, record),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('أكتوبر'), findsOneWidget);
    expect(find.textContaining('2026/10/20'), findsNothing);
  });

  testWidgets('typed secure-store failure stays on the AI failure surface', (
    tester,
  ) async {
    final store = PausedStore();
    final settings = AiSettingsController(store);
    addTearDown(settings.dispose);
    await settings.saveProvider(provider());
    await tester.pumpWidget(
      host(settings, aiConsentContractFor(settings.providers.single)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    store.failAccount = true;
    await tester.tap(find.text(l10n.aiConsentAgreeAndSend));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiConsentTitle), findsOneWidget);
    expect(find.textContaining(l10n.aiHistoryCleaning), findsOneWidget);
    expect(settings.accountRecord('account')?.consents ?? {}, isEmpty);
  });

  testWidgets('back cannot dismiss consent while secure write is pending', (
    tester,
  ) async {
    final store = PausedStore();
    final settings = AiSettingsController(store);
    addTearDown(settings.dispose);
    await settings.saveProvider(provider());
    await tester.pumpWidget(
      host(settings, aiConsentContractFor(settings.providers.single)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    store.pause = Completer<void>();
    await tester.tap(find.text(l10n.aiConsentAgreeAndSend));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text(l10n.aiConsentTitle), findsOneWidget);
    store.pause!.complete();
    await tester.pumpAndSettle();
    expect(settings.accountRecord('account')!.consents, contains('synthetic'));
  });
}

Widget host(
  AiSettingsController settings,
  AiConsentContract contract, {
  bool arabic = false,
}) => MaterialApp(
  theme: appTheme(arabic ? Brightness.dark : Brightness.light),
  locale: arabic ? const Locale('ar') : const Locale('en'),
  supportedLocales: const [Locale('en'), Locale('ar')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () =>
            showAiConsentDialog(context, settings, 'account', contract),
        child: const Text('open'),
      ),
    ),
  ),
);

final class PausedStore implements AiStore {
  final MemoryAiStore _delegate = MemoryAiStore();
  Completer<void>? pause;
  bool failAccount = false;

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() =>
      _delegate.loadProviders();

  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) =>
      _delegate.saveProviders(providers);

  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) =>
      _delegate.readProviderKey(providerId);

  @override
  Future<Map<String, String>> readAllProviderKeys(
    Iterable<String> providerIds,
  ) => _delegate.readAllProviderKeys(providerIds);

  @override
  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  }) => _delegate.saveProviderKey(
    providerId,
    key,
    acknowledgeWarning: acknowledgeWarning,
  );

  @override
  Future<void> deleteProviderKey(String providerId) =>
      _delegate.deleteProviderKey(providerId);

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) =>
      _delegate.loadAccount(accountKey);

  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) async {
    await pause?.future;
    if (failAccount) {
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.cleaning, 'syntheticConsentSave'),
      );
    }
    await _delegate.saveAccount(accountKey, account);
  }

  @override
  Future<List<String>> listAccountKeys() => _delegate.listAccountKeys();

  @override
  Future<void> deleteAccount(String accountKey) =>
      _delegate.deleteAccount(accountKey);

  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) =>
      _delegate.readHistoryKey(accountKey);

  @override
  Future<void> writeHistoryKey(String accountKey, Uint8List key) =>
      _delegate.writeHistoryKey(accountKey, key);

  @override
  Future<void> deleteHistoryKey(String accountKey) =>
      _delegate.deleteHistoryKey(accountKey);

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) =>
      _delegate.readTombstone(accountKey);

  @override
  Future<void> setTombstone(String accountKey) =>
      _delegate.setTombstone(accountKey);

  @override
  Future<List<String>> listTombstones() => _delegate.listTombstones();

  @override
  Future<void> clearTombstone(String accountKey) =>
      _delegate.clearTombstone(accountKey);
}
