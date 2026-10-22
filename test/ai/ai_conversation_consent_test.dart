import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_consent_dialog.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_settings.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

const _account = 'https://gitlab.example.test/team#42';

AiProviderConfig _provider({bool tools = true}) => AiProviderConfig(
  id: 'synthetic',
  name: 'Synthetic',
  presetId: 'custom',
  baseUrl: 'https://synthetic.example.test/v1',
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

Future<AiSettingsController> _settings() async {
  final settings = AiSettingsController(MemoryAiStore());
  await settings.initialize();
  await settings.loadAccount(_account);
  return settings;
}

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  test(
    'without tools a conversation asks for the read-only disclosure',
    () async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      final provider = await settings.saveProvider(_provider(tools: false));
      final contract = aiConversationConsentContract(
        settings,
        _account,
        provider,
      );
      expect(contract.writePolicy, isNull);
    },
  );

  test('with tools it asks to write up to the account ceiling', () async {
    final settings = await _settings();
    addTearDown(settings.dispose);
    final provider = await settings.saveProvider(_provider());
    final contract = aiConversationConsentContract(
      settings,
      _account,
      provider,
    );
    expect(contract.writePolicy?.agreedCeiling, AiAutonomyLevel.lowRiskAuto);
  });

  test('raising the ceiling asks again; lowering it does not', () async {
    final settings = await _settings();
    addTearDown(settings.dispose);
    final provider = await settings.saveProvider(_provider());
    final first = aiConversationConsentContract(settings, _account, provider);
    await settings.grantConsent(_account, first, const {'synthetic': true});
    expect(settings.isValid(_account, first), isTrue);

    await settings.setAutonomySettings(
      _account,
      ceiling: AiAutonomyLevel.confirmEach,
    );
    final lower = aiConversationConsentContract(settings, _account, provider);
    expect(lower.writePolicy?.agreedCeiling, AiAutonomyLevel.lowRiskAuto);
    expect(settings.isValid(_account, lower), isTrue);

    await settings.setAutonomySettings(
      _account,
      ceiling: AiAutonomyLevel.conversationGrant,
    );
    final higher = aiConversationConsentContract(settings, _account, provider);
    expect(
      higher.writePolicy?.agreedCeiling,
      AiAutonomyLevel.conversationGrant,
    );
    expect(settings.isValid(_account, higher), isFalse);
  });

  test(
    'a read-only ceiling with no earlier write agreement stays read only',
    () async {
      final settings = await _settings();
      addTearDown(settings.dispose);
      final provider = await settings.saveProvider(_provider());
      await settings.setAutonomySettings(
        _account,
        ceiling: AiAutonomyLevel.readOnly,
      );
      final contract = aiConversationConsentContract(
        settings,
        _account,
        provider,
      );
      expect(contract.writePolicy, isNull);
    },
  );

  testWidgets('the disclosure names the write ceiling, and only for writes', (
    tester,
  ) async {
    final settings = await _settings();
    final provider = await settings.saveProvider(_provider());
    addTearDown(settings.dispose);
    final write = aiConversationConsentContract(settings, _account, provider);
    final readOnly = aiCurrentConsentContractFor(provider);
    for (final (contract, shown) in [(write, true), (readOnly, false)]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showAiConsentDialog(context, settings, _account, contract),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('ai-consent-writes'));
      if (shown) {
        await tester.dragUntilVisible(
          card,
          find.byType(ListView),
          const Offset(0, -160),
        );
        expect(
          find.text(
            l10n.aiConsentWritesUpTo(aiLevelLabel(AiAutonomyLevel.lowRiskAuto)),
          ),
          findsOneWidget,
        );
      } else {
        expect(card, findsNothing);
      }
      await tester.tap(find.text(l10n.cancelAction));
      await tester.pumpAndSettle();
    }
  });
}
