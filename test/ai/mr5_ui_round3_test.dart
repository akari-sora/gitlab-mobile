import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_provider_editor.dart';
import 'package:gitlab_mobile/features/ai/ai_settings_page.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  group('a format switch keeps the key draft with its recipient', () {
    testWidgets('a saved custom provider with an api-key header', (
      tester,
    ) async {
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      await settings.saveProviderWithKey(
        const AiProviderConfig(
          id: 'custom-api-key',
          name: 'Synthetic custom',
          presetId: 'custom',
          baseUrl: 'https://provider.example/v1',
          format: AiFormat.chatCompletions,
          model: 'synthetic-model',
          authStyle: AiAuthStyle.apiKey,
          caps: AiCaps(tokenLimitField: AiTokenLimitField.maxTokens),
          allowLanCleartext: false,
          toolsEnabled: false,
          recipientRevision: 0,
        ),
        key: 'sk-synthetic-stored-for-api-key-1',
      );
      await tester.pumpWidget(
        _host(
          AiProviderEditor(
            settings: settings,
            provider: settings.providers.single,
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-api-key')),
        'sk-synthetic-typed-for-api-key-123456',
      );
      await tester.pump();

      // The custom URL stays the same; only the auth header changes.
      _format(tester).onChanged!(AiFormat.responses);
      await tester.pumpAndSettle();

      expect(_keyField(tester).controller!.text, isEmpty);
      expect(find.text(l10n.aiProviderKeyDraftCleared), findsOneWidget);
    });

    testWidgets('a format whose header matches keeps the draft', (
      tester,
    ) async {
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
      _preset(tester).onChanged!(AiPresets.custom);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        'https://provider.example/v1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-api-key')),
        'sk-synthetic-same-header-123456',
      );
      await tester.pump();

      _format(tester).onChanged!(AiFormat.responses);
      await tester.pumpAndSettle();

      expect(
        _keyField(tester).controller!.text,
        'sk-synthetic-same-header-123456',
      );
      expect(find.text(l10n.aiProviderKeyDraftCleared), findsNothing);
    });
  });

  group('the policy line follows the consent derivation', () {
    Future<void> openCodeGo(WidgetTester tester) async {
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
      _preset(tester).onChanged!(AiPresets.openCodeGo);
      await tester.pumpAndSettle();
      _format(tester).onChanged!(AiFormat.responses);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-model')),
        'gpt-6-luna',
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the preset endpoint shows the listed policy', (tester) async {
      await openCodeGo(tester);

      expect(find.text(l10n.aiPolicyNoTraining), findsOneWidget);
      expect(find.text(l10n.aiPolicyRetainedDays('30')), findsOneWidget);
    });

    testWidgets('another recipient shows the policy as unknown', (
      tester,
    ) async {
      await openCodeGo(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        'https://different-recipient.example/v1',
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.aiPolicyNoTraining), findsNothing);
      expect(find.text(l10n.aiPolicyRetainedDays('30')), findsNothing);
      expect(find.text(l10n.aiProviderModelPolicyUnknown), findsOneWidget);
    });

    testWidgets('a format the policy does not list shows it as unknown', (
      tester,
    ) async {
      await openCodeGo(tester);
      _format(tester).onChanged!(AiFormat.chatCompletions);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-model')),
        'gpt-6-luna',
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.aiPolicyNoTraining), findsNothing);
      expect(find.text(l10n.aiProviderModelPolicyUnknown), findsOneWidget);
    });
  });

  group('the model list URL follows the base URL until edited', () {
    const elsewhere = 'https://different-recipient.example/v1';

    Future<void> openCodeGo(WidgetTester tester) async {
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
      _preset(tester).onChanged!(AiPresets.openCodeGo);
      await tester.pumpAndSettle();
      await _expandAdvanced(tester);
    }

    testWidgets('another server clears it and the preset server restores it', (
      tester,
    ) async {
      await openCodeGo(tester);
      expect(_modelsUrlText(tester), AiPresets.openCodeGo.modelsUrl);

      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        elsewhere,
      );
      await tester.pumpAndSettle();
      expect(_modelsUrlText(tester), isEmpty);
      expect(find.text(l10n.aiProviderBaseUrlInvalid), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        AiPresets.openCodeGo.baseUrlFor(AiFormat.chatCompletions),
      );
      await tester.pumpAndSettle();
      expect(_modelsUrlText(tester), AiPresets.openCodeGo.modelsUrl);
      expect(find.text(l10n.aiProviderBaseUrlInvalid), findsNothing);
    });

    testWidgets('an edited list URL stays and carries its own error', (
      tester,
    ) async {
      await openCodeGo(tester);
      const edited = 'https://opencode.ai/inference/v1/models';
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-models-url')),
        edited,
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        elsewhere,
      );
      await tester.pumpAndSettle();

      expect(_modelsUrlText(tester), edited);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ai-provider-models-url')),
          matching: find.text(l10n.aiProviderBaseUrlInvalid),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ai-provider-base-url')),
          matching: find.text(l10n.aiProviderBaseUrlInvalid),
        ),
        findsNothing,
      );
    });

    testWidgets('its floating label is not cut by the advanced section', (
      tester,
    ) async {
      await openCodeGo(tester);
      final header = find.ancestor(
        of: find.text(l10n.aiProviderAdvancedTitle),
        matching: find.byType(ListTile),
      );
      final label = find.descendant(
        of: find.byKey(const ValueKey('ai-provider-models-url')),
        matching: find.text(l10n.aiProviderModelsUrlLabel),
      );
      expect(
        tester.getRect(label).top,
        greaterThanOrEqualTo(tester.getRect(header).bottom),
      );
    });

    testWidgets('a saved provider on another server opens without one', (
      tester,
    ) async {
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      await settings.saveProviderWithKey(
        AiProviderConfig(
          id: 'go-elsewhere',
          name: 'Synthetic Go elsewhere',
          presetId: AiPresets.openCodeGo.id,
          baseUrl: elsewhere,
          format: AiFormat.chatCompletions,
          model: 'synthetic-model',
          authStyle: AiAuthStyle.bearer,
          caps: AiPresets.openCodeGo.capsFor(AiFormat.chatCompletions),
          allowLanCleartext: false,
          toolsEnabled: false,
          recipientRevision: 0,
        ),
        key: 'sk-synthetic-stored-for-elsewhere-1',
      );
      await tester.pumpWidget(
        _host(
          AiProviderEditor(
            settings: settings,
            provider: settings.providers.single,
          ),
        ),
      );
      await _expandAdvanced(tester);
      expect(_modelsUrlText(tester), isEmpty);

      // Another path on the same server marks the endpoint as touched.
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        'https://different-recipient.example/v2',
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiProviderBaseUrlInvalid), findsNothing);
    });
  });

  testWidgets('preset descriptions are not cut at 320 dp and 2x text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_scaledHost(AiProviderEditor(settings: settings)));
    final button = tester.widget<DropdownButton<AiPreset>>(
      find.descendant(
        of: find.byKey(const ValueKey('ai-provider-preset')),
        matching: find.byType(DropdownButton<AiPreset>),
      ),
    );
    for (final item in button.items!) {
      final description = ((item.child as Padding).child! as Column).children
          .whereType<Text>()
          .last;
      expect(description.maxLines, isNull, reason: description.data);
      expect(description.overflow, isNull, reason: description.data);
    }

    await tester.tap(find.byKey(const ValueKey('ai-provider-preset')));
    await tester.pumpAndSettle();
    final shown = find.text(l10n.aiPresetAboutOpenAi).last;
    expect(
      tester.renderObject<RenderParagraph>(shown).didExceedMaxLines,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  group('the token cap error wraps at 320 dp and 2x text', () {
    for (final tag in ['zh-TW', 'en', 'ar']) {
      testWidgets(tag, (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 1400);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        useLanguage(languageForTag(tag)!);
        final store = MemoryAiStore();
        final settings = AiSettingsController(store);
        final history = AiHistoryCoordinator(store: store);
        addTearDown(settings.dispose);
        addTearDown(history.dispose);
        await settings.initialize();
        final account = _account();
        await tester.pumpWidget(
          _scaledHost(
            AiSettingsPage(
              settings: settings,
              accountKey: account.key,
              account: account,
              isAccountRetained: (key) => key == account.key,
              history: history,
            ),
            tag: tag,
          ),
        );
        await tester.pumpAndSettle();
        final cap = find.byKey(ValueKey('ai-token-cap-${account.key}'));
        await tester.scrollUntilVisible(
          cap,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(cap, '12');
        await tester.pumpAndSettle();

        final messages = find.text(l10n.aiConversationCapHelp);
        // The help line below the field and the field's own error.
        expect(messages, findsNWidgets(2));
        for (final element in messages.evaluate()) {
          final paragraph = element.renderObject! as RenderParagraph;
          expect(paragraph.didExceedMaxLines, isFalse);
        }
        expect(tester.takeException(), isNull);
      });
    }
  });
}

DropdownButtonFormField<AiPreset> _preset(WidgetTester tester) =>
    tester.widget<DropdownButtonFormField<AiPreset>>(
      find.byKey(const ValueKey('ai-provider-preset')),
    );

DropdownButtonFormField<AiFormat> _format(WidgetTester tester) =>
    tester.widget<DropdownButtonFormField<AiFormat>>(
      find.byKey(const ValueKey('ai-provider-format')),
    );

TextField _keyField(WidgetTester tester) => tester.widget<TextField>(
  find.descendant(
    of: find.byKey(const ValueKey('ai-provider-api-key')),
    matching: find.byType(TextField),
  ),
);

String _modelsUrlText(WidgetTester tester) => tester
    .widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('ai-provider-models-url')),
        matching: find.byType(TextField),
      ),
    )
    .controller!
    .text;

Future<void> _expandAdvanced(WidgetTester tester) async {
  final title = find.text(l10n.aiProviderAdvancedTitle);
  await tester.ensureVisible(title);
  await tester.pumpAndSettle();
  await tester.tap(title);
  await tester.pumpAndSettle();
}

Account _account() => Account(
  instance: GitLabInstance.parse('https://gitlab.example.test/team'),
  user: const GitLabUser(id: 42, username: 'river', name: 'River Lin'),
  token: 'synthetic-token',
);

Widget _host(Widget child) => MaterialApp(
  theme: appTheme(Brightness.light),
  locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: child,
);

Widget _scaledHost(Widget child, {String tag = 'zh-TW'}) {
  final locale = switch (tag) {
    'zh-TW' => const Locale('zh', 'TW'),
    'ar' => const Locale('ar'),
    _ => const Locale('en'),
  };
  return MaterialApp(
    theme: appTheme(Brightness.dark),
    locale: locale,
    supportedLocales: const [Locale('zh', 'TW'), Locale('ar'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(2)),
      child: child!,
    ),
    home: child,
  );
}
