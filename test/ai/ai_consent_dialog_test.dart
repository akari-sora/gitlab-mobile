import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart'
    show AiScopeClass, productionAiLedger;
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart'
    show aiProductionWritePolicy;
import 'package:gitlab_mobile/features/ai/ai_consent_dialog.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_scope.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

void main() {
  group('AI consent dialog', () {
    testWidgets('cancel does not grant and agree stores hash and summary', (
      tester,
    ) async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      await settings.saveProvider(
        _provider(baseUrl: 'http://127.0.0.1:11434/v1'),
      );
      final contract = aiCurrentConsentContractFor(settings.providers.single);
      final results = <bool>[];

      await tester.pumpWidget(_host(settings, contract, onResult: results.add));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(l10n.aiConsentTitle), findsOneWidget);
      expect(find.text(l10n.aiConsentUnencrypted), findsOneWidget);
      await tester.dragUntilVisible(
        find.text(l10n.aiConsentUnknownDataUseWarning),
        find.byType(ListView),
        const Offset(0, -180),
      );
      expect(find.text(l10n.aiConsentUnknownDataUseWarning), findsOneWidget);
      expect(find.text('gpt-6-luna'), findsOneWidget);
      await tester.tap(find.text(l10n.cancelAction));
      await tester.pumpAndSettle();
      expect(settings.accountRecord('account'), isNull);
      expect(results, [false]);

      await settings.saveProvider(_provider());
      final derivedContract = aiCurrentConsentContractFor(
        settings.providers.single,
      );
      await tester.pumpWidget(
        _host(settings, derivedContract, onResult: results.add),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text(l10n.aiConsentNoTraining),
        find.byType(ListView),
        const Offset(0, -180),
      );
      expect(find.text(l10n.aiConsentNoTraining), findsOneWidget);
      await tester.tap(find.text(l10n.aiConsentAgreeAndSend));
      await tester.pumpAndSettle();

      final consent = settings.accountRecord('account')!.consents['provider']!;
      expect(results, [false, true]);
      expect(consent.hash, derivedContract.hash);
      expect(consent.summary['providerName'], 'Synthetic provider');
      expect(consent.summary['origin'], _provider().baseUrl);
      expect(consent.summary['format'], 'responses');
      expect(consent.summary['model'], 'gpt-6-luna');
      expect(consent.summary['dataUse'], 'noTraining');
      expect(consent.summary['retentionDays'], 30);
      expect(consent.summary['toolCatalogueVersion'], aiToolCatalogueVersion);
      expect(consent.summary['disclosureVersion'], aiDisclosureVersion);
      expect(consent.summary['dataCategories'], <Object?>[
        'attachment_metadata',
        'comments',
        'diff',
        'issue_text',
        'job_log',
        'source',
        'tool_reads',
        'write_results',
      ]);
      expect(settings.isValid('account', derivedContract), isTrue);
    });

    testWidgets('write results and attachment names have their own labels', (
      tester,
    ) async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      await settings.saveProvider(_provider());
      final contract = aiCurrentConsentContractFor(settings.providers.single);
      expect(
        contract.dataCategories,
        containsAll(<String>['write_results', 'attachment_metadata']),
      );
      await tester.pumpWidget(_host(settings, contract, onResult: (_) {}));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      for (final label in [
        l10n.aiConsentCategoryWriteResults,
        l10n.aiConsentCategoryAttachmentMetadata,
      ]) {
        await tester.dragUntilVisible(
          find.text(label),
          find.byType(ListView),
          const Offset(0, -120),
        );
        expect(find.text(label), findsOneWidget);
      }
      // Every category the contract lists has a name of its own.
      expect(find.text(l10n.aiConsentCategoryOther), findsNothing);
    });

    testWidgets('with nothing to send the button only agrees', (tester) async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      final contract = aiCurrentConsentContractFor(settings.providers.single);
      final results = <bool>[];

      await tester.pumpWidget(
        _host(
          settings,
          contract,
          onResult: results.add,
          agreeLabel: l10n.aiConsentAgree,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(l10n.aiConsentAgreeAndSend), findsNothing);
      await tester.tap(find.text(l10n.aiConsentAgree));
      await tester.pumpAndSettle();
      expect(results, [true]);
      expect(settings.isValid('account', contract), isTrue);
    });

    testWidgets('training and unknown policies use warning wording', (
      tester,
    ) async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      await settings.saveProvider(
        _provider(model: 'muse-spark-1.3-contributor'),
      );

      await tester.pumpWidget(
        _host(settings, aiCurrentConsentContractFor(settings.providers.single)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text(l10n.aiConsentTrainingWarning),
        find.byType(ListView),
        const Offset(0, -180),
      );
      expect(find.text(l10n.aiConsentTrainingWarning), findsOneWidget);
      expect(find.text(l10n.aiConsentRetentionNotStated), findsOneWidget);
      await tester.tap(find.text(l10n.cancelAction));
      await tester.pumpAndSettle();

      await settings.saveProvider(_provider(model: 'unlisted-model'));
      await tester.pumpWidget(
        _host(settings, aiCurrentConsentContractFor(settings.providers.single)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text(l10n.aiConsentUnknownDataUseWarning),
        find.byType(ListView),
        const Offset(0, -180),
      );
      expect(find.text(l10n.aiConsentUnknownDataUseWarning), findsOneWidget);
      expect(find.text(l10n.aiConsentRetentionNotStated), findsOneWidget);
    });

    testWidgets('saved record renders the original readable summary', (
      tester,
    ) async {
      final record = AiConsentRecord(
        hash: 'saved-hash',
        summary: aiConsentSummary(
          _contract(),
          providerName: 'Original provider name',
        ),
        grantedAt: DateTime.utc(2026, 10, 20, 1, 2),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          locale: const Locale('zh', 'TW'),
          supportedLocales: const [Locale('zh', 'TW')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAiConsentRecordDialog(context, record),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(l10n.aiConsentDetailsTitle), findsOneWidget);
      expect(find.text('Original provider name'), findsOneWidget);
      final dialogContext = tester.element(find.byType(Dialog));
      final localizedDate = MaterialLocalizations.of(
        dialogContext,
      ).formatMediumDate(record.grantedAt.toLocal());
      expect(find.textContaining(localizedDate), findsOneWidget);
      expect(find.text(l10n.aiConsentSavedSummaryNotice), findsOneWidget);
    });

    testWidgets('provider edits while open prevent granting stale consent', (
      tester,
    ) async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        _host(settings, aiCurrentConsentContractFor(settings.providers.single)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiConsentTitle), findsOneWidget);

      await settings.saveProvider(_provider(model: 'changed-model'));
      await tester.tap(find.text(l10n.aiConsentAgreeAndSend));
      await tester.pumpAndSettle();

      expect(find.text(l10n.aiConsentTitle), findsNothing);
      expect(settings.accountRecord('account'), isNull);
    });

    testWidgets('account switch while open prevents granting consent', (
      tester,
    ) async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      final key = GlobalKey<_ScopedHostState>();
      await tester.pumpWidget(
        _ScopedHost(
          key: key,
          settings: settings,
          contract: aiCurrentConsentContractFor(settings.providers.single),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiConsentTitle), findsOneWidget);

      key.currentState!.switchAccount();
      await tester.pump();
      await tester.tap(find.text(l10n.aiConsentAgreeAndSend));
      await tester.pumpAndSettle();

      expect(settings.accountRecord('account'), isNull);
      expect(settings.accountRecord('other-account'), isNull);
      expect(find.text(l10n.aiConsentTitle), findsNothing);
    });

    testWidgets('non-model-sensitive consent still displays provider model', (
      tester,
    ) async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      await settings.saveProvider(_provider(preset: AiPresets.openAi));
      final contract = aiCurrentConsentContractFor(settings.providers.single);
      expect(contract.routedModel, isNull);
      await tester.pumpWidget(_host(settings, contract));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('gpt-6-luna'), findsOneWidget);
    });

    testWidgets('full-screen content scrolls at 320dp, 2x text, RTL and dark', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final settings = await _settings();
      addTearDown(settings.dispose);
      await settings.saveProvider(
        _provider(model: 'muse-spark-1.3-contributor'),
      );

      await tester.pumpWidget(
        _host(
          settings,
          aiCurrentConsentContractFor(settings.providers.single),
          brightness: Brightness.dark,
          textDirection: TextDirection.rtl,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.dragUntilVisible(
        find.text(l10n.aiConsentIrreversible),
        find.byType(ListView),
        const Offset(0, -180),
      );
      expect(find.text(l10n.aiConsentIrreversible), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // MR6b-3g full UI: the writes section names the group scope exactly
    // when the agreed policy lists a write to a group's own work item.
    group('group work-item scope', () {
      AiWritePolicy policy(Set<String> operationIds) => AiWritePolicy(
        policyVersion: 9,
        agreedCeiling: AiAutonomyLevel.confirmEach,
        catalogueVersion: 9,
        operationIds: operationIds,
        hardLineOperationIds: const {},
        fixedConfirmOperationIds: const {},
        resetConfirmWindow: const Duration(minutes: 10),
      );

      Future<void> openRecord(
        WidgetTester tester,
        AiWritePolicy? writePolicy, {
        String tag = 'zh-TW',
      }) async {
        // The app's strings and the Material locale switch together, so an
        // Arabic run lays out the real Arabic sentences right to left.
        useLanguage(languageForTag(tag)!);
        addTearDown(() => useLanguage(languageForTag('zh-TW')!));
        final locale = tag == 'ar'
            ? const Locale('ar')
            : const Locale('zh', 'TW');
        final record = AiConsentRecord(
          hash: 'saved-hash',
          summary: aiConsentSummary(_contract(writePolicy: writePolicy)),
          grantedAt: DateTime.utc(2026, 10, 28, 1, 2),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            locale: locale,
            supportedLocales: const [Locale('zh', 'TW'), Locale('ar')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showAiConsentRecordDialog(context, record),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }

      Finder groupScope() => find.text(l10n.aiConsentWritesGroupScope);

      Future<void> showWrites(WidgetTester tester) => tester.dragUntilVisible(
        find.byKey(const ValueKey('ai-consent-writes')),
        find.byType(ListView),
        const Offset(0, -180),
      );

      testWidgets('a policy with a group alias names the group scope', (
        tester,
      ) async {
        await openRecord(
          tester,
          policy({'createNote', 'updateGroupWorkItemState'}),
        );
        await showWrites(tester);
        await tester.dragUntilVisible(
          groupScope(),
          find.byType(ListView),
          const Offset(0, -120),
        );
        expect(groupScope(), findsOneWidget);
      });

      testWidgets('a project-only policy does not', (tester) async {
        await openRecord(tester, policy({'createNote', 'snoozeTodo'}));
        await showWrites(tester);
        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(groupScope(), findsNothing);
      });

      testWidgets('a read-only consent has no writes section at all', (
        tester,
      ) async {
        await openRecord(tester, null);
        expect(find.byKey(const ValueKey('ai-consent-writes')), findsNothing);
        expect(groupScope(), findsNothing);
      });

      testWidgets('the production policy names it exactly when it offers a '
          'group write', (tester) async {
        final production = aiProductionWritePolicy(AiAutonomyLevel.confirmEach);
        // Today the group rows stay hidden until G14 opens them; the
        // sentence follows the policy, not a flag of its own.
        final offersGroup = production.operationIds.any(
          (id) =>
              productionAiLedger.find(id)?.scopeClass ==
              AiScopeClass.groupWorkItem,
        );
        await openRecord(tester, production);
        await showWrites(tester);
        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(groupScope(), offersGroup ? findsOneWidget : findsNothing);
      });

      test('the sentence is read from the agreed policy, so a consent '
          'without group writes never covers them', () {
        final project = _contract(writePolicy: policy({'createNote'}));
        final group = _contract(
          writePolicy: policy({'createNote', 'updateGroupWorkItemState'}),
        );
        // Adding a group write changes the hash: the user agrees again and
        // sees the sentence then. The sentence itself adds nothing to the
        // saved summary.
        expect(group.hash, isNot(project.hash));
        expect(
          aiConsentSummary(group).keys,
          unorderedEquals(aiConsentSummary(project).keys),
        );
      });

      testWidgets('it fits 320dp and 2x text in Arabic', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 640);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await openRecord(
          tester,
          policy({'updateGroupWorkItemState'}),
          tag: 'ar',
        );
        // groupScope() reads the Arabic sentence now that Arabic is in use.
        expect(l10n.aiConsentWritesGroupScope, contains('عناصر العمل'));
        await tester.dragUntilVisible(
          groupScope(),
          find.byType(ListView),
          const Offset(0, -120),
        );
        expect(groupScope(), findsOneWidget);
        expect(
          Directionality.of(tester.element(groupScope())),
          TextDirection.rtl,
        );
        expect(tester.takeException(), isNull);
      });
    });

    test('model-sensitive fields and data use invalidate the hash', () {
      final original = _contract();
      expect(
        _contract(model: 'muse-spark-1.3-contributor').hash,
        isNot(original.hash),
      );
      expect(_contract(dataUse: AiDataUse.training).hash, isNot(original.hash));
      expect(
        _contract(categories: const <String>{'diff', 'source'}).hash,
        isNot(original.hash),
      );
      expect(_contract(toolsEnabled: false).hash, isNot(original.hash));
    });
  });
}

Future<AiSettingsController> _settings() async {
  final settings = AiSettingsController(MemoryAiStore());
  await settings.saveProvider(_provider());
  return settings;
}

Widget _host(
  AiSettingsController settings,
  AiConsentContract contract, {
  Brightness brightness = Brightness.light,
  TextDirection textDirection = TextDirection.ltr,
  ValueChanged<bool>? onResult,
  String? agreeLabel,
}) => MaterialApp(
  theme: appTheme(brightness),
  builder: (context, child) => Directionality(
    textDirection: textDirection,
    child: child ?? const SizedBox.shrink(),
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () async {
          final granted = await showAiConsentDialog(
            context,
            settings,
            'account',
            contract,
            agreeLabel: agreeLabel,
          );
          onResult?.call(granted);
        },
        child: const Text('open'),
      ),
    ),
  ),
);

AiProviderConfig _provider({
  String model = 'gpt-6-luna',
  AiPreset? preset,
  String? baseUrl,
}) => AiProviderConfig(
  id: 'provider',
  name: 'Synthetic provider',
  presetId: (preset ?? AiPresets.openCodeGo).id,
  baseUrl:
      baseUrl ??
      (preset ?? AiPresets.openCodeGo).baseUrlFor(AiFormat.responses),
  format: AiFormat.responses,
  model: model,
  authStyle: AiAuthStyle.none,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    requiresKey: false,
  ),
  allowLanCleartext: true,
  toolsEnabled: true,
  recipientRevision: 1,
);

AiConsentContract _contract({
  String? model = 'gpt-6-luna',
  AiDataUse dataUse = AiDataUse.noTraining,
  Set<String> categories = const <String>{
    'job_log',
    'diff',
    'source',
    'comments',
    'tool_reads',
  },
  bool toolsEnabled = true,
  AiWritePolicy? writePolicy,
}) => AiConsentContract(
  providerId: 'provider',
  writePolicy: writePolicy,
  origin: 'http://127.0.0.1:11434/v1',
  format: AiFormat.responses,
  cleartext: true,
  toolsEnabled: toolsEnabled,
  toolCatalogueVersion: 1,
  dataCategories: categories,
  policyIdentity:
      'opencode-go|${model ?? 'stable-model'}|responses|${dataUse.name}|30|'
      'https://opencode.ai/docs/go/|2026-10-20',
  routedModel: model,
  dataUse: dataUse,
  disclosureVersion: 1,
);

class _ScopedHost extends StatefulWidget {
  const _ScopedHost({
    super.key,
    required this.settings,
    required this.contract,
  });

  final AiSettingsController settings;
  final AiConsentContract contract;

  @override
  State<_ScopedHost> createState() => _ScopedHostState();
}

class _ScopedHostState extends State<_ScopedHost> {
  var accountKey = 'account';

  void switchAccount() => setState(() => accountKey = 'other-account');

  @override
  Widget build(BuildContext context) => AiScope(
    controllers: AiControllers(
      settings: widget.settings,
      history: AiHistoryCoordinator.instance,
    ),
    accountKey: accountKey,
    child: _host(widget.settings, widget.contract),
  );
}
