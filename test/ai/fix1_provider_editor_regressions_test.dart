import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart' show ResponseBody;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/features/ai/ai_provider_editor.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import '../support/fake_adapter.dart';

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  testWidgets('starts with a described cloud preset and no early errors', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));

    final preset = tester.widget<DropdownButtonFormField<AiPreset>>(
      find.byKey(const ValueKey('ai-provider-preset')),
    );
    expect(preset.initialValue, same(AiPresets.openAi));
    final presetButton = tester.widget<DropdownButton<AiPreset>>(
      find.descendant(
        of: find.byKey(const ValueKey('ai-provider-preset')),
        matching: find.byType(DropdownButton<AiPreset>),
      ),
    );
    expect(presetButton.items!.last.value, same(AiPresets.custom));
    expect(find.text(l10n.aiProviderBaseUrlInvalid), findsNothing);
    expect(find.text(l10n.aiProviderModelPolicyUnknown), findsNothing);
    expect(find.text(l10n.aiProviderUnverifiedLabel), findsNothing);
    expect(find.byKey(const ValueKey('ai-provider-cleartext')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ai-provider-preset')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiPresetAboutOpenAi), findsWidgets);
  });

  testWidgets('custom format changes preserve the typed URL', (tester) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
    await _selectPreset(tester, AiPresets.custom);
    const url = 'https://custom.example/v1';
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-base-url')),
      url,
    );

    final format = tester.widget<DropdownButtonFormField<AiFormat>>(
      find.byKey(const ValueKey('ai-provider-format')),
    );
    format.onChanged!(AiFormat.responses);
    await tester.pump();

    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('ai-provider-base-url')),
          )
          .controller!
          .text,
      url,
    );
  });

  testWidgets('switching preset clears a key entered for another recipient', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-api-key')),
      'sk-synthetic-first-123456',
    );

    await _selectPreset(tester, AiPresets.openRouter);

    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('ai-provider-api-key')),
          )
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('save retry keeps one stable provider ID', (tester) async {
    final store = _FailOnceKeyStore();
    final settings = AiSettingsController(store);
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
    await _fillRequired(tester);

    await tester.tap(find.text(l10n.saveAction));
    await tester.pumpAndSettle();
    expect(settings.providers, isEmpty);
    expect(store.keyWriteIds, hasLength(1));

    await tester.tap(find.text(l10n.saveAction));
    await tester.pumpAndSettle();
    expect(settings.providers, hasLength(1));
    expect(store.keyWriteIds, hasLength(2));
    expect(store.keyWriteIds.toSet(), hasLength(1));
    expect(settings.providers.single.id, store.keyWriteIds.first);
  });

  testWidgets('key input is private and model URL stays in Advanced', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));

    final keyField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('ai-provider-api-key')),
        matching: find.byType(EditableText),
      ),
    );
    expect(keyField.obscureText, isTrue);
    expect(keyField.enableSuggestions, isFalse);
    expect(keyField.autocorrect, isFalse);
    expect(keyField.enableIMEPersonalizedLearning, isFalse);
    expect(keyField.keyboardType, TextInputType.visiblePassword);
    expect(find.byKey(const ValueKey('ai-provider-models-url')), findsNothing);

    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-advanced')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('ai-provider-models-url')),
      findsOneWidget,
    );
  });

  testWidgets('completed model results clear when endpoint input changes', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'data': [
          {'id': 'model-from-first-recipient'},
        ],
      }),
    );
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(
      _host(
        AiProviderEditor(
          settings: settings,
          clientFactory: (config, key) => _client(config, key, adapter),
        ),
      ),
    );
    await _selectPreset(tester, AiPresets.custom);
    await _fillRequired(tester);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-read-models')),
    );
    await tester.pumpAndSettle();
    expect(find.text('model-from-first-recipient'), findsOneWidget);
    expect(find.text(l10n.aiProviderModelsReadSuccess), findsOneWidget);
    // Dismiss the picker by tapping the barrier above it.
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-base-url')),
      'https://second.example/v1',
    );
    await tester.pump();
    expect(find.text(l10n.aiProviderModelsReadSuccess), findsNothing);
    // The list belonged to the first recipient: the picker never offers it.
    // (The URL change also dropped the typed key, so nothing is read again.)
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-pick-model')),
    );
    await tester.pumpAndSettle();
    expect(find.text('model-from-first-recipient'), findsNothing);
    expect(adapter.requests, hasLength(1));
  });

  testWidgets('invalid collapsed caps expand Advanced and cannot persist', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
    await _fillRequired(tester);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-advanced')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-request-limit')),
      '7999',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-output-limit')),
      '511',
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-advanced')),
    );

    await tester.tap(find.text(l10n.saveAction));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiProviderRequestCharsRange), findsOneWidget);
    expect(find.text(l10n.aiProviderOutputTokensRange), findsOneWidget);
    expect(settings.providers, isEmpty);
  });

  testWidgets('Chat token field override reaches the encoded request', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
    await _selectPreset(tester, AiPresets.custom);
    await _fillRequired(tester);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-advanced')),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<DropdownButtonFormField<AiTokenLimitField>>(
      find.byKey(const ValueKey('ai-provider-token-limit-field')),
    );
    field.onChanged!(AiTokenLimitField.maxCompletionTokens);
    await tester.pump();
    await tester.tap(find.text(l10n.saveAction));
    await tester.pumpAndSettle();

    final provider = settings.providers.single;
    final segment = AiSegment(
      providerId: provider.id,
      recipientRevision: provider.recipientRevision,
      format: AiFormat.chatCompletions,
      model: provider.model,
      secretSetAtStart: SecretSetId.fromSecrets(const []),
    )..setTail(AppUserEntry(text: 'synthetic'));
    final body = const ChatCompletionsFormat().encode(
      AiRequestPlan(
        model: provider.model,
        system: 'synthetic',
        segment: segment,
      ),
      provider.caps,
    );
    expect(body['max_completion_tokens'], 4096);
    expect(body, isNot(contains('max_tokens')));
  });

  testWidgets('changed recipient cannot reuse a stored key for model reads', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    final saved = await settings.saveProviderWithKey(
      _provider('saved-provider'),
      key: 'sk-synthetic-original-123456',
      acknowledgeWarning: true,
    );
    var factoryCalls = 0;
    await tester.pumpWidget(
      _host(
        AiProviderEditor(
          settings: settings,
          provider: saved,
          clientFactory: (config, key) {
            factoryCalls += 1;
            return _client(config, key, FakeAdapter((_) => jsonResponse({})));
          },
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-base-url')),
      'https://different.example/v1',
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-read-models')),
    );
    await tester.pump();

    expect(factoryCalls, 0);
    expect(find.text(l10n.aiProviderKeyMinimum), findsOneWidget);
    expect(find.text(l10n.aiProviderKeyNotSet), findsOneWidget);
  });

  testWidgets('invalid edited recipient safely drops stored-key status', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    final saved = await settings.saveProviderWithKey(
      _provider('invalid-recipient-edit'),
      key: 'sk-synthetic-original-123456',
      acknowledgeWarning: true,
    );
    await tester.pumpWidget(
      _host(AiProviderEditor(settings: settings, provider: saved)),
    );
    expect(find.text(l10n.aiProviderKeySet), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-base-url')),
      'https://',
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text(l10n.aiProviderBaseUrlInvalid), findsOneWidget);
    expect(find.text(l10n.aiProviderKeyNotSet), findsOneWidget);
  });

  testWidgets('keyed provider can switch to a local preset without crashing', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    final saved = await settings.saveProviderWithKey(
      _provider('local-preset-edit'),
      key: 'sk-synthetic-original-123456',
      acknowledgeWarning: true,
    );
    await tester.pumpWidget(
      _host(AiProviderEditor(settings: settings, provider: saved)),
    );

    await _selectPreset(tester, AiPresets.ollama);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('ai-provider-cleartext')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-provider-api-key')), findsNothing);
  });

  testWidgets('OpenRouter model catalogue can be searched', (tester) async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'data': [
          {'id': 'vendor/alpha'},
          {'id': 'vendor/beta'},
          {'id': 'other/gamma'},
          {'id': 'other/delta'},
          {'id': 'vendor/epsilon'},
          {'id': 'vendor/zeta'},
          {'id': 'other/eta'},
        ],
      }),
    );
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(
      _host(
        AiProviderEditor(
          settings: settings,
          clientFactory: (config, key) => _client(config, key, adapter),
        ),
      ),
    );
    await _selectPreset(tester, AiPresets.openRouter);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-read-models')),
    );
    await tester.pumpAndSettle();
    // The picker is open; a longer list gets a search field.
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-model-search')),
      'beta',
    );
    await tester.pump();

    expect(find.text('vendor/beta'), findsOneWidget);
    expect(find.text('vendor/alpha'), findsNothing);
    expect(find.text('other/gamma'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-model-search')),
      'no-such-model',
    );
    await tester.pump();
    expect(find.text(l10n.aiProviderModelPickerEmpty), findsOneWidget);
  });

  testWidgets('model and auth edits clear key verification success', (
    tester,
  ) async {
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(
      _host(
        AiProviderEditor(
          settings: settings,
          clientFactory: (config, key) => _client(config, key, adapter),
        ),
      ),
    );
    await _selectPreset(tester, AiPresets.openRouter);
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-api-key')),
      'sk-or-synthetic-123456',
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-verify-key')),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiProviderKeyVerified), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-model')),
      'changed-model',
    );
    await tester.pump();
    expect(find.text(l10n.aiProviderKeyVerified), findsNothing);

    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-verify-key')),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiProviderKeyVerified), findsOneWidget);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-advanced')),
    );
    final auth = tester.widget<DropdownButtonFormField<AiAuthStyle>>(
      find.byKey(const ValueKey('ai-provider-auth-style')),
    );
    auth.onChanged!(AiAuthStyle.apiKey);
    await tester.pump();
    expect(find.text(l10n.aiProviderKeyVerified), findsNothing);
  });

  testWidgets('a model read that ends while leaving opens no picker', (
    tester,
  ) async {
    final response = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => response.future);
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(
      _navigationHost(
        settings,
        clientFactory: (config, key) => _client(config, key, adapter),
      ),
    );
    await tester.tap(find.text('open-editor'));
    await tester.pumpAndSettle();
    await _selectPreset(tester, AiPresets.openRouter);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-pick-model')),
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(adapter.requests, hasLength(1));

    await tester.tap(find.byTooltip(l10n.cancelAction));
    await tester.pump(const Duration(milliseconds: 400));
    if (find.text(l10n.aiProviderDiscardTitle).evaluate().isNotEmpty) {
      await tester.tap(find.text(l10n.confirmAction));
    }
    // The editor starts leaving; the catalogue answers during the exit.
    await tester.pump();
    response.complete(
      jsonResponse({
        'data': [
          {'id': 'synthetic/late-model'},
        ],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AiProviderEditor), findsNothing);
    expect(find.text('synthetic/late-model'), findsNothing);
  });

  testWidgets('a model read that ends while saving opens no picker', (
    tester,
  ) async {
    final response = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => response.future);
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final storage = _GatedStorage();
    final settings = AiSettingsController(SecureAiStore(storage));
    await settings.initialize();
    await tester.pumpWidget(
      _navigationHost(
        settings,
        clientFactory: (config, key) => _client(config, key, adapter),
      ),
    );
    await tester.tap(find.text('open-editor'));
    await tester.pumpAndSettle();
    await _selectPreset(tester, AiPresets.custom);
    await _fillRequired(tester);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-pick-model')),
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(adapter.requests, hasLength(1));

    // Saving waits on storage; the catalogue answers meanwhile.
    storage.gate = Completer<void>();
    await tester.tap(find.text(l10n.saveAction));
    await tester.pump();
    // Saving stopped the read at once, before its answer arrived.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-provider-pick-model')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    response.complete(
      jsonResponse({
        'data': [
          {'id': 'synthetic-late-model'},
        ],
      }),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('synthetic-late-model'), findsNothing);
    // While it saves, both list buttons are off and the read has stopped.
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('ai-provider-pick-model')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('ai-provider-read-models')),
          )
          .onPressed,
      isNull,
    );
    storage.gate!.complete();
    await tester.pumpAndSettle();

    expect(find.byType(AiProviderEditor), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(settings.providers, hasLength(1));
  });

  testWidgets('a model read that ends under the discard dialog opens no picker', (
    tester,
  ) async {
    final response = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => response.future);
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(
      _navigationHost(
        settings,
        clientFactory: (config, key) => _client(config, key, adapter),
      ),
    );
    await tester.tap(find.text('open-editor'));
    await tester.pumpAndSettle();
    await _selectPreset(tester, AiPresets.custom);
    await _fillRequired(tester);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-pick-model')),
    );
    await tester.pump(const Duration(milliseconds: 10));
    await tester.tap(find.byTooltip(l10n.cancelAction));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(l10n.aiProviderDiscardTitle), findsOneWidget);

    response.complete(
      jsonResponse({
        'data': [
          {'id': 'synthetic-covered-model'},
        ],
      }),
    );
    await tester.pump(const Duration(milliseconds: 400));
    // No picker opened over the dialog.
    expect(find.text('synthetic-covered-model'), findsNothing);
    expect(find.text(l10n.aiProviderDiscardTitle), findsOneWidget);
    // Keep editing.
    await tester.tap(find.text(l10n.cancelAction).last);
    await tester.pumpAndSettle();
    expect(find.byType(AiProviderEditor), findsOneWidget);
    expect(find.text('synthetic-covered-model'), findsNothing);
  });

  testWidgets('Cancel asks before discarding edited settings', (tester) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_navigationHost(settings));
    await tester.tap(find.text('open-editor'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-model')),
      'changed-model',
    );
    await tester.tap(find.byTooltip(l10n.cancelAction));
    await tester.pumpAndSettle();

    expect(find.text(l10n.aiProviderDiscardTitle), findsOneWidget);
    expect(find.byType(AiProviderEditor), findsOneWidget);
    await tester.tap(find.text(l10n.cancelAction));
    await tester.pumpAndSettle();
    expect(find.byType(AiProviderEditor), findsOneWidget);
    await tester.tap(find.byTooltip(l10n.cancelAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.confirmAction));
    await tester.pumpAndSettle();
    expect(find.byType(AiProviderEditor), findsNothing);
  });

  testWidgets('system back asks before discarding edited settings', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_navigationHost(settings));
    await tester.tap(find.text('open-editor'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-model')),
      'changed-model',
    );
    await tester.pump();

    final popScope = tester.widget<PopScope<Object?>>(
      find.byKey(const ValueKey('ai-provider-pop-scope')),
    );
    expect(popScope.canPop, isFalse);
    popScope.onPopInvokedWithResult!(false, null);
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiProviderDiscardTitle), findsOneWidget);
    expect(find.byType(AiProviderEditor), findsOneWidget);
  });

  testWidgets('Advanced remains scrollable at 320 dp, 2x text and RTL', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    useLanguage(languageForTag('ar')!);
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(
      _scaledRtlHost(AiProviderEditor(settings: settings)),
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-advanced')),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ai-provider-output-limit')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('ai-provider-output-limit')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _host(Widget child) => MaterialApp(
  theme: appTheme(Brightness.light),
  locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: child,
);

Widget _navigationHost(
  AiSettingsController settings, {
  AiProviderClientFactory? clientFactory,
}) => MaterialApp(
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
              clientFactory: clientFactory,
            ),
          ),
        ),
        child: const Text('open-editor'),
      ),
    ),
  ),
);

Widget _scaledRtlHost(Widget child) => MaterialApp(
  theme: appTheme(Brightness.dark),
  locale: const Locale('ar'),
  supportedLocales: const [Locale('ar'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(2)),
    child: Directionality(textDirection: TextDirection.rtl, child: child!),
  ),
  home: child,
);

Future<void> _selectPreset(WidgetTester tester, AiPreset preset) async {
  final field = tester.widget<DropdownButtonFormField<AiPreset>>(
    find.byKey(const ValueKey('ai-provider-preset')),
  );
  field.onChanged!(preset);
  await tester.pumpAndSettle();
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

Future<void> _fillRequired(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('ai-provider-name')),
    'Synthetic provider',
  );
  await tester.enterText(
    find.byKey(const ValueKey('ai-provider-base-url')),
    'https://provider.example/v1',
  );
  await tester.enterText(
    find.byKey(const ValueKey('ai-provider-model')),
    'synthetic-model',
  );
  await tester.enterText(
    find.byKey(const ValueKey('ai-provider-api-key')),
    'sk-synthetic-123456',
  );
  await tester.pump();
}

AiProviderConfig _provider(String id) => AiProviderConfig(
  id: id,
  name: 'Synthetic provider',
  presetId: 'custom',
  baseUrl: 'https://provider.example/v1',
  format: AiFormat.chatCompletions,
  model: 'synthetic-model',
  authStyle: AiAuthStyle.bearer,
  caps: const AiCaps(tokenLimitField: AiTokenLimitField.maxTokens),
  allowLanCleartext: false,
  toolsEnabled: false,
  recipientRevision: 0,
);

AiWireClient _client(AiProviderConfig config, String key, FakeAdapter adapter) {
  final endpoint = AiEndpoint.parse(
    config.baseUrl,
    allowLanCleartext: config.allowLanCleartext,
    modelsUrlOverride: config.modelsUrl,
    allowKeyEndpoint: config.presetId == 'openrouter',
  );
  return AiWireClient(
    transport: AiTransport(
      endpoint: endpoint,
      apiKey: key,
      authStyle: config.authStyle,
      adapter: adapter,
    ),
    wire: const ChatCompletionsFormat(),
    config: config,
    conversationId: 'fix1-editor-test',
    appVersion: 'test',
  );
}

final class _FailOnceKeyStore implements AiStore {
  final MemoryAiStore _inner = MemoryAiStore();
  final List<String> keyWriteIds = <String>[];
  bool _fail = true;

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() =>
      _inner.loadProviders();

  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) =>
      _inner.saveProviders(providers);

  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) =>
      _inner.readProviderKey(providerId);

  @override
  Future<Map<String, String>> readAllProviderKeys(
    Iterable<String> providerIds,
  ) => _inner.readAllProviderKeys(providerIds);

  @override
  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  }) async {
    keyWriteIds.add(providerId);
    if (_fail) {
      _fail = false;
      throw const AiStoreException(
        AiStoreFailure(AiStoreFailureKind.unavailable, 'saveProviderKey'),
      );
    }
    await _inner.saveProviderKey(
      providerId,
      key,
      acknowledgeWarning: acknowledgeWarning,
    );
  }

  @override
  Future<void> deleteProviderKey(String providerId) =>
      _inner.deleteProviderKey(providerId);

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) =>
      _inner.loadAccount(accountKey);

  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) =>
      _inner.saveAccount(accountKey, account);

  @override
  Future<List<String>> listAccountKeys() => _inner.listAccountKeys();

  @override
  Future<void> deleteAccount(String accountKey) =>
      _inner.deleteAccount(accountKey);

  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) =>
      _inner.readHistoryKey(accountKey);

  @override
  Future<void> writeHistoryKey(String accountKey, Uint8List key) =>
      _inner.writeHistoryKey(accountKey, key);

  @override
  Future<void> deleteHistoryKey(String accountKey) =>
      _inner.deleteHistoryKey(accountKey);

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) =>
      _inner.readTombstone(accountKey);

  @override
  Future<void> setTombstone(String accountKey) =>
      _inner.setTombstone(accountKey);

  @override
  Future<List<String>> listTombstones() => _inner.listTombstones();

  @override
  Future<void> clearTombstone(String accountKey) =>
      _inner.clearTombstone(accountKey);
}

/// Secure storage whose writes wait for [gate] while it is set.
final class _GatedStorage extends FlutterSecureStorage {
  Completer<void>? gate;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await gate?.future;
    await super.write(key: key, value: value);
  }
}
