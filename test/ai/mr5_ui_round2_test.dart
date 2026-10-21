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
import 'package:gitlab_mobile/shared/workspace_ui.dart';

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  group('system back with unsaved edits', () {
    final edits = <String, Future<void> Function(WidgetTester)>{
      'name': (tester) => tester.enterText(
        find.byKey(const ValueKey('ai-provider-name')),
        'Renamed provider',
      ),
      'key': (tester) => tester.enterText(
        find.byKey(const ValueKey('ai-provider-api-key')),
        'sk-synthetic-replacement-123456',
      ),
      'request limit': (tester) async {
        await _tapVisible(
          tester,
          find.byKey(const ValueKey('ai-provider-advanced')),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('ai-provider-request-limit')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(
          find.byKey(const ValueKey('ai-provider-request-limit')),
          '9000',
        );
      },
    };
    for (final edit in edits.entries) {
      testWidgets('asks before discarding a changed ${edit.key}', (
        tester,
      ) async {
        final settings = await _settingsWithProvider();
        await tester.pumpWidget(_navigationHost(settings));
        await tester.tap(find.text('open-editor'));
        await tester.pumpAndSettle();
        await edit.value(tester);
        await tester.pump();

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        expect(find.text(l10n.aiProviderDiscardTitle), findsOneWidget);
        expect(find.byType(AiProviderEditor), findsOneWidget);
      });
    }

    testWidgets('leaves at once when nothing changed', (tester) async {
      final settings = await _settingsWithProvider();
      await tester.pumpWidget(_navigationHost(settings));
      await tester.tap(find.text('open-editor'));
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text(l10n.aiProviderDiscardTitle), findsNothing);
      expect(find.byType(AiProviderEditor), findsNothing);
    });
  });

  group('field messages wrap at 320 dp and 2x text', () {
    for (final tag in ['zh-TW', 'en', 'ar']) {
      testWidgets(tag, (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        useLanguage(languageForTag(tag)!);
        final settings = AiSettingsController(MemoryAiStore());
        await settings.initialize();
        await tester.pumpWidget(
          _scaledHost(AiProviderEditor(settings: settings), tag),
        );
        final field = tester.widget<DropdownButtonFormField<AiPreset>>(
          find.byKey(const ValueKey('ai-provider-preset')),
        );
        field.onChanged!(AiPresets.all.firstWhere((p) => p.id == 'ollama'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('ai-provider-base-url')),
          'http://100.64.0.1:11434/v1',
        );
        await tester.pumpAndSettle();
        _expectWhole(tester, l10n.aiProviderLocalCleartextHelp);

        await tester.enterText(
          find.byKey(const ValueKey('ai-provider-base-url')),
          'not a url',
        );
        await tester.pumpAndSettle();
        _expectWhole(tester, l10n.aiProviderBaseUrlInvalid);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('a typed key stays with the recipient it was typed for', () {
    testWidgets('editing the base URL clears the draft and explains why', (
      tester,
    ) async {
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-api-key')),
        'sk-synthetic-draft-123456',
      );
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        'https://different.example/v1',
      );
      await tester.pumpAndSettle();

      expect(_keyField(tester).controller!.text, isEmpty);
      expect(
        find.byKey(const ValueKey('ai-provider-key-draft-cleared')),
        findsOneWidget,
      );
      expect(find.text(l10n.aiProviderKeyDraftCleared), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-api-key')),
        'sk-synthetic-new-recipient-1234',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('ai-provider-key-draft-cleared')),
        findsNothing,
      );
    });

    testWidgets('a key typed after the URL survives later key edits', (
      tester,
    ) async {
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        'https://api.openai.com/v1/',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-api-key')),
        'sk-synthetic-stays-123456',
      );
      await tester.pump();
      // The same origin written differently is the same recipient.
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        'https://API.openai.com:443/v1',
      );
      await tester.pumpAndSettle();

      expect(_keyField(tester).controller!.text, 'sk-synthetic-stays-123456');
      expect(
        find.byKey(const ValueKey('ai-provider-key-draft-cleared')),
        findsNothing,
      );
    });

    testWidgets('changing the authentication header clears the draft', (
      tester,
    ) async {
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
      final preset = tester.widget<DropdownButtonFormField<AiPreset>>(
        find.byKey(const ValueKey('ai-provider-preset')),
      );
      preset.onChanged!(AiPresets.custom);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        'https://provider.example/v1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-api-key')),
        'sk-synthetic-header-123456',
      );
      await tester.pump();

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('ai-provider-advanced')),
      );
      await tester.pumpAndSettle();
      final auth = tester.widget<DropdownButtonFormField<AiAuthStyle>>(
        find.byKey(const ValueKey('ai-provider-auth-style')),
      );
      auth.onChanged!(AiAuthStyle.apiKey);
      await tester.pumpAndSettle();

      expect(_keyField(tester).controller!.text, isEmpty);
      expect(find.text(l10n.aiProviderKeyDraftCleared), findsOneWidget);
    });
  });

  testWidgets('preset menu lists likely services first, each described', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
    final button = tester.widget<DropdownButton<AiPreset>>(
      find.descendant(
        of: find.byKey(const ValueKey('ai-provider-preset')),
        matching: find.byType(DropdownButton<AiPreset>),
      ),
    );
    final ids = [for (final item in button.items!) item.value!.id];
    expect(ids.take(3), ['openai', 'anthropic', 'gemini']);
    expect(ids.last, 'custom');
    expect(ids.toSet(), {for (final preset in AiPresets.all) preset.id});

    // The open menu builds only the rows on screen, so read each item.
    final shown = [
      for (final item in button.items!)
        ...((item.child as Padding).child! as Column).children
            .whereType<Text>()
            .skip(1)
            .map((text) => text.data),
    ];
    final descriptions = [
      l10n.aiPresetAboutOpenAi,
      l10n.aiPresetAboutAnthropic,
      l10n.aiPresetAboutGemini,
      l10n.aiPresetAboutOpenRouter,
      l10n.aiPresetAboutOpenCodeGo,
      l10n.aiPresetAboutDeepSeek,
      l10n.aiPresetAboutXai,
      l10n.aiPresetAboutAzure,
      l10n.aiPresetAboutOpenCodeZen,
      l10n.aiPresetAboutOllama,
      l10n.aiPresetAboutLmStudio,
      l10n.aiProviderPresetDescriptionCustom,
    ];
    expect(shown, descriptions);
    expect(descriptions.toSet(), hasLength(descriptions.length));
  });

  group('settings page', () {
    testWidgets('keyless providers show no key status; account monogram', (
      tester,
    ) async {
      final store = MemoryAiStore();
      final settings = AiSettingsController(store);
      final history = AiHistoryCoordinator(store: store);
      addTearDown(settings.dispose);
      addTearDown(history.dispose);
      await settings.saveProvider(_keylessProvider('local'));
      final account = _account();
      await tester.pumpWidget(
        MaterialApp(
          home: AiSettingsPage(
            settings: settings,
            accountKey: account.key,
            account: account,
            isAccountRetained: (key) => key == account.key,
            history: history,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.aiProviderKeyNotSet), findsNothing);
      expect(find.text(l10n.aiProviderKeySet), findsNothing);
      expect(find.byType(Monogram), findsOneWidget);
      expect(find.text(account.key), findsNothing);
    });
  });
}

void _expectWhole(WidgetTester tester, String text) {
  final finder = find.text(text);
  expect(finder, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  expect(paragraph.didExceedMaxLines, isFalse, reason: text);
}

TextField _keyField(WidgetTester tester) => tester.widget<TextField>(
  find.descendant(
    of: find.byKey(const ValueKey('ai-provider-api-key')),
    matching: find.byType(TextField),
  ),
);

Future<AiSettingsController> _settingsWithProvider() async {
  final store = MemoryAiStore();
  final settings = AiSettingsController(store);
  await settings.initialize();
  await settings.saveProviderWithKey(
    const AiProviderConfig(
      id: 'existing',
      name: 'Synthetic provider',
      presetId: 'custom',
      baseUrl: 'https://provider.example/v1',
      format: AiFormat.chatCompletions,
      model: 'synthetic-model',
      authStyle: AiAuthStyle.bearer,
      caps: AiCaps(tokenLimitField: AiTokenLimitField.maxTokens),
      allowLanCleartext: false,
      toolsEnabled: false,
      recipientRevision: 0,
    ),
    key: 'sk-synthetic-existing-123456',
  );
  return settings;
}

AiProviderConfig _keylessProvider(String id) => AiProviderConfig(
  id: id,
  name: 'Local models',
  presetId: 'ollama',
  baseUrl: 'http://127.0.0.1:11434/v1',
  format: AiFormat.chatCompletions,
  model: 'synthetic-local',
  authStyle: AiAuthStyle.none,
  caps: const AiCaps(
    tokenLimitField: AiTokenLimitField.maxTokens,
    requiresKey: false,
  ),
  allowLanCleartext: true,
  toolsEnabled: false,
  recipientRevision: 0,
);

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

Widget _navigationHost(AiSettingsController settings) => MaterialApp(
  theme: appTheme(Brightness.light),
  locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => AiProviderEditor(
              settings: settings,
              provider: settings.providers.single,
            ),
          ),
        ),
        child: const Text('open-editor'),
      ),
    ),
  ),
);

Widget _scaledHost(Widget child, String tag) {
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

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
}
