import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
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
      final contract = _contract();

      await tester.pumpWidget(_host(settings, contract));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(l10n.aiConsentTitle), findsOneWidget);
      expect(find.text(l10n.aiConsentUnencrypted), findsOneWidget);
      await tester.dragUntilVisible(
        find.text(l10n.aiConsentNoTraining),
        find.byType(ListView),
        const Offset(0, -180),
      );
      expect(find.text(l10n.aiConsentNoTraining), findsOneWidget);
      expect(find.text('gpt-6-luna'), findsOneWidget);
      await tester.tap(find.text(l10n.cancelAction));
      await tester.pumpAndSettle();
      expect(settings.accountRecord('account'), isNull);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.aiConsentAgreeAndSend));
      await tester.pumpAndSettle();

      final consent = settings.accountRecord('account')!.consents['provider']!;
      expect(consent.hash, contract.hash);
      expect(consent.summary['providerName'], 'Synthetic provider');
      expect(consent.summary['origin'], 'http://127.0.0.1:11434/v1');
      expect(consent.summary['format'], 'responses');
      expect(consent.summary['model'], 'gpt-6-luna');
      expect(consent.summary['dataUse'], 'noTraining');
      expect(consent.summary['retentionDays'], 30);
      expect(consent.summary['dataCategories'], <Object?>[
        'comments',
        'diff',
        'job_log',
        'source',
        'tool_reads',
      ]);
      expect(settings.isValid('account', contract), isTrue);
    });

    testWidgets('training and unknown policies use warning wording', (
      tester,
    ) async {
      final settings = await _settings();
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        _host(settings, _contract(dataUse: AiDataUse.training)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text(l10n.aiConsentTrainingWarning),
        find.byType(ListView),
        const Offset(0, -180),
      );
      expect(find.text(l10n.aiConsentTrainingWarning), findsOneWidget);
      await tester.tap(find.text(l10n.cancelAction));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        _host(settings, _contract(dataUse: AiDataUse.unknown)),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text(l10n.aiConsentUnknownDataUseWarning),
        find.byType(ListView),
        const Offset(0, -180),
      );
      expect(find.text(l10n.aiConsentUnknownDataUseWarning), findsOneWidget);
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
      expect(find.textContaining('2026/10/20'), findsOneWidget);
      expect(find.text(l10n.aiConsentSavedSummaryNotice), findsOneWidget);
    });

    testWidgets('provider edits while open prevent granting stale consent', (
      tester,
    ) async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      await tester.pumpWidget(_host(settings, _contract()));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

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
        _ScopedHost(key: key, settings: settings, contract: _contract()),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      key.currentState!.switchAccount();
      await tester.pump();
      await tester.tap(find.text(l10n.aiConsentAgreeAndSend));
      await tester.pumpAndSettle();

      expect(settings.accountRecord('account'), isNull);
    });

    testWidgets('non-model-sensitive consent still displays provider model', (
      tester,
    ) async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      await tester.pumpWidget(_host(settings, _contract(model: null)));
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

      await tester.pumpWidget(
        _host(
          settings,
          _contract(dataUse: AiDataUse.training),
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
}) => MaterialApp(
  theme: appTheme(brightness),
  builder: (context, child) => Directionality(
    textDirection: textDirection,
    child: child ?? const SizedBox.shrink(),
  ),
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

AiProviderConfig _provider({String model = 'gpt-6-luna'}) => AiProviderConfig(
  id: 'provider',
  name: 'Synthetic provider',
  presetId: 'opencode-go',
  baseUrl: 'http://127.0.0.1:11434/v1',
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
}) => AiConsentContract(
  providerId: 'provider',
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
