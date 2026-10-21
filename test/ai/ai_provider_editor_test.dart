import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/features/ai/ai_provider_editor.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import '../support/fake_adapter.dart';

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  testWidgets('preset limits formats and keyless presets hide the key field', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));

    await _selectPreset(tester, 'Gemini');
    await tester.tap(find.byKey(const ValueKey('ai-provider-format')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiProviderFormatChat), findsWidgets);
    expect(find.text(l10n.aiProviderFormatResponses), findsNothing);
    await tester.tap(find.text(l10n.aiProviderFormatChat).last);
    await tester.pumpAndSettle();

    await _selectPreset(tester, 'Ollama');
    expect(find.byKey(const ValueKey('ai-provider-api-key')), findsNothing);
    await _selectPreset(tester, 'LM Studio');
    expect(find.byKey(const ValueKey('ai-provider-api-key')), findsNothing);
    await _selectPreset(tester, l10n.aiCustomProvider);
    expect(find.byKey(const ValueKey('ai-provider-no-key')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-provider-api-key')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-provider-no-key')));
    await tester.pump();
    expect(find.byKey(const ValueKey('ai-provider-api-key')), findsNothing);
  });

  testWidgets('URL validation requires cleartext opt-in including CGNAT', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));

    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-base-url')),
      'http://100.64.0.1:11434/v1',
    );
    await tester.pump();
    expect(find.text(l10n.aiProviderLocalCleartextHelp), findsOneWidget);
    expect(find.text(l10n.aiProviderBaseUrlInvalid), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ai-provider-cleartext')));
    await tester.pump();
    expect(find.text(l10n.aiProviderLocalCleartextHelp), findsNothing);
    expect(find.text(l10n.aiProviderBaseUrlInvalid), findsNothing);
    expect(find.text(l10n.aiProviderCleartextWarning), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-base-url')),
      'http://100.128.0.1/v1',
    );
    await tester.pump();
    expect(find.text(l10n.aiProviderBaseUrlInvalid), findsOneWidget);
  });

  testWidgets('trims the key and rejects embedded whitespace before saving', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
    await _fillRequired(tester, key: '  sk-synthetic-123456  ');
    await tester.tap(find.text(l10n.saveAction));
    await tester.pumpAndSettle();

    expect(settings.providers, hasLength(1));
    expect(
      settings.knownProviderKeys[settings.providers.single.id],
      'sk-synthetic-123456',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    final second = AiSettingsController(MemoryAiStore());
    await second.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: second)));
    await _fillRequired(tester, key: 'sk-synthetic 123456');
    await tester.tap(find.text(l10n.saveAction));
    await tester.pump();
    expect(find.text(l10n.aiProviderKeyWhitespace), findsOneWidget);
    expect(second.providers, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-api-key')),
      'sk-synthetic\u0085123456',
    );
    await tester.tap(find.text(l10n.saveAction));
    await tester.pump();
    expect(find.text(l10n.aiProviderKeyWhitespace), findsOneWidget);
    expect(second.providers, isEmpty);
  });

  testWidgets('rejects short keys and confirms short or word-like keys', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
    await _fillRequired(tester, key: 'abc');
    await tester.tap(find.text(l10n.saveAction));
    await tester.pump();
    expect(find.text(l10n.aiProviderKeyMinimum), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-api-key')),
      'ordinaryword',
    );
    await tester.tap(find.text(l10n.saveAction));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiProviderKeyWarningTitle), findsOneWidget);
    expect(find.text(l10n.aiProviderKeyWarningDetail), findsOneWidget);
    await tester.tap(find.text(l10n.cancelAction));
    await tester.pumpAndSettle();
    expect(settings.providers, isEmpty);

    await tester.tap(find.text(l10n.saveAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.confirmAction));
    await tester.pumpAndSettle();
    expect(settings.providers, hasLength(1));
  });

  testWidgets('model list uses injected client and filters OpenCode routes', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromString(
        jsonEncode({
          'data': [
            {'id': 'glm-5.3-flash'},
            {'id': 'gpt-6-luna'},
            {'id': 'unroutable-model'},
          ],
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
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
    await _selectPreset(tester, 'OpenCode Go');
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-api-key')),
      'oc_sk_synthetic_123456',
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-read-models')),
    );
    await tester.pumpAndSettle();

    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.path, contains('/go/v1/models'));
    // Reading the list opens the picker.
    expect(_option('glm-5.3-flash'), findsOneWidget);
    expect(find.text('gpt-6-luna'), findsNothing);
    expect(find.text('unroutable-model'), findsNothing);
    expect(find.text(l10n.aiProviderModelsReadSuccess), findsOneWidget);
    expect(find.text(l10n.aiProviderUnverifiedLabel), findsNothing);

    await tester.tap(_option('glm-5.3-flash'));
    await tester.pumpAndSettle();
    expect(_option('glm-5.3-flash'), findsNothing);
    expect(_modelText(tester), 'glm-5.3-flash');
    expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
    // Label and explanation are shown as two lines, not joined in code.
    expect(find.text(l10n.aiProviderUnverifiedLabel), findsOneWidget);
    expect(find.text(l10n.aiProviderVerificationExplanation), findsOneWidget);
  });

  testWidgets('a tap into the base URL keeps the loaded model list', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'data': [
          {'id': 'glm-5.3-flash'},
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
    await _selectPreset(tester, 'OpenCode Go');
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-api-key')),
      'oc_sk_synthetic_123456',
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-read-models')),
    );
    await tester.pumpAndSettle();
    expect(_option('glm-5.3-flash'), findsOneWidget);
    await _closePicker(tester);

    // Focus and selection changes are not edits of the URL or the key.
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-base-url')),
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-api-key')),
    );
    await tester.pumpAndSettle();

    // The list is still loaded: the field's button opens it without a read.
    await _tapVisible(tester, find.byKey(const ValueKey('ai-provider-pick-model')));
    await tester.pumpAndSettle();
    expect(_option('glm-5.3-flash'), findsOneWidget);
    expect(adapter.requests, hasLength(1));
  });

  testWidgets('the read button reads the catalogue again', (tester) async {
    var round = 0;
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'data': [
          {'id': 'synthetic-round-${++round}'},
        ],
      }),
    );
    await _pumpCustomEditor(tester, adapter);
    await _tapVisible(tester, find.byKey(const ValueKey('ai-provider-read-models')));
    await tester.pumpAndSettle();
    expect(_option('synthetic-round-1'), findsOneWidget);
    await _closePicker(tester);

    // The field's button reuses the list; the read button fetches it again.
    await _tapVisible(tester, find.byKey(const ValueKey('ai-provider-pick-model')));
    await tester.pumpAndSettle();
    expect(adapter.requests, hasLength(1));
    await _closePicker(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('ai-provider-read-models')));
    await tester.pumpAndSettle();
    expect(adapter.requests, hasLength(2));
    expect(_option('synthetic-round-2'), findsOneWidget);
  });

  testWidgets('an empty catalogue opens the picker once and says so', (
    tester,
  ) async {
    final adapter = FakeAdapter((_) => jsonResponse({'data': <Object?>[]}));
    await _pumpCustomEditor(tester, adapter);
    await _tapVisible(tester, find.byKey(const ValueKey('ai-provider-pick-model')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiProviderModelPickerTitle), findsOneWidget);
    expect(find.text(l10n.aiProviderModelPickerEmpty), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await _tapVisible(tester, find.byKey(const ValueKey('ai-provider-pick-model')));
    await tester.pumpAndSettle();
    expect(adapter.requests, hasLength(1));
    expect(find.text(l10n.aiProviderModelPickerEmpty), findsOneWidget);
  });

  testWidgets('with the keyboard up, results stay visible on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'data': [
          for (var i = 0; i < 40; i++) {'id': 'synthetic-model-$i'},
        ],
      }),
    );
    await _pumpCustomEditor(tester, adapter, scale: 1.3);
    await _tapVisible(tester, find.byKey(const ValueKey('ai-provider-pick-model')));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-model-search')),
      'model-1',
    );
    await tester.pumpAndSettle();

    const keyboardTop = 640.0 - 280;
    final visible = find.byType(ListTile).evaluate().where((element) {
      final box = element.renderObject! as RenderBox;
      final top = box.localToGlobal(Offset.zero).dy;
      return top >= 0 && top + box.size.height <= keyboardTop;
    });
    expect(visible.length, greaterThanOrEqualTo(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the model field button reads the list and fills the field', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'data': [
          {'id': 'synthetic-alpha'},
          {'id': 'synthetic-beta'},
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
    await _selectPreset(tester, l10n.aiCustomProvider);
    await _fillRequired(tester, key: 'sk-synthetic-123456');
    await _tapVisible(tester, find.byKey(const ValueKey('ai-provider-pick-model')));
    await tester.pumpAndSettle();

    expect(adapter.requests, hasLength(1));
    // A short list needs no search field.
    expect(find.byKey(const ValueKey('ai-provider-model-search')), findsNothing);
    expect(find.text(l10n.aiProviderModelPickerHint), findsOneWidget);
    await tester.tap(_option('synthetic-beta'));
    await tester.pumpAndSettle();
    expect(_modelText(tester), 'synthetic-beta');

    // Reopened, the picker marks the current model and lists it first.
    await _tapVisible(tester, find.byKey(const ValueKey('ai-provider-pick-model')));
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(_option('synthetic-beta')).selected, isTrue);
    expect(tester.widget<ListTile>(_option('synthetic-alpha')).selected, isFalse);
    expect(
      tester.getTopLeft(_option('synthetic-beta')).dy,
      lessThan(tester.getTopLeft(_option('synthetic-alpha')).dy),
    );
    await _closePicker(tester);

    // Typing a model ID still works.
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-model')),
      'synthetic-typed-model',
    );
    expect(_modelText(tester), 'synthetic-typed-model');
    expect(adapter.requests, hasLength(1));
  });

  testWidgets('OpenRouter key verification uses the dedicated key endpoint', (
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
    await _selectPreset(tester, 'OpenRouter');
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-api-key')),
      'sk-or-synthetic-123456',
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-verify-key')),
    );
    await tester.pumpAndSettle();

    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.path, endsWith('/api/v1/key'));
    expect(find.text(l10n.aiProviderKeyVerified), findsOneWidget);

    // A tap into the model field is not an edit of the model.
    await _tapVisible(tester, find.byKey(const ValueKey('ai-provider-model')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiProviderKeyVerified), findsOneWidget);
  });

  testWidgets('OpenRouter model catalog is public and sends no auth header', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'data': [
          {'id': 'synthetic/openrouter-model'},
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
    await _selectPreset(tester, 'OpenRouter');
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-read-models')),
    );
    await tester.pumpAndSettle();

    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.path, endsWith('/api/v1/models'));
    expect(
      adapter.requests.single.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('authorization')),
    );
    expect(
      adapter.requests.single.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('api-key')),
    );
    expect(
      adapter.requests.single.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('x-api-key')),
    );
    expect(_option('synthetic/openrouter-model'), findsOneWidget);
  });

  testWidgets('model list failure is explicit and preserves free entry', (
    tester,
  ) async {
    final adapter = FakeAdapter((_) => throw StateError('synthetic failure'));
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
    await _fillRequired(tester, key: 'sk-synthetic-123456');
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-read-models')),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.aiProviderModelsReadFailure), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('ai-provider-model')),
          )
          .controller!
          .text,
      'synthetic-model',
    );
  });

  testWidgets('changed network inputs discard an in-flight model result', (
    tester,
  ) async {
    final response = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => response.future);
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
    await _selectPreset(tester, l10n.aiCustomProvider);
    await _fillRequired(tester, key: 'sk-synthetic-123456');
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-read-models')),
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(adapter.requests, hasLength(1));

    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-api-key')),
      'sk-synthetic-changed-123456',
    );
    response.complete(
      jsonResponse({
        'data': [
          {'id': 'stale-model'},
        ],
      }),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.aiProviderModelsReadSuccess), findsNothing);
    expect(_option('stale-model'), findsNothing);
    expect(find.byKey(const ValueKey('ai-provider-model-picker')), findsNothing);
    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('ai-provider-read-models')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('advanced authentication and output limit are persisted', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
    await _fillRequired(tester, key: 'sk-synthetic-123456');
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-advanced')),
    );
    await tester.pumpAndSettle();
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('ai-provider-auth-style')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.aiProviderAuthApiKey).last);
    await tester.pumpAndSettle();
    // A key typed for another authentication header is cleared.
    expect(find.text(l10n.aiProviderKeyDraftCleared), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-api-key')),
      'sk-synthetic-123456',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-output-limit')),
      '8192',
    );
    await tester.tap(find.text(l10n.saveAction));
    await tester.pumpAndSettle();

    expect(settings.providers.single.authStyle, AiAuthStyle.apiKey);
    expect(settings.providers.single.caps.maxOutputTokens, 8192);
  });

  testWidgets('editor has no overflow at 320 dp, 2x text, RTL and dark mode', (
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
      _host(
        AiProviderEditor(settings: settings),
        brightness: Brightness.dark,
        scale: 2,
        direction: TextDirection.rtl,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(AiProviderEditor), findsOneWidget);
  });
}

Widget _host(
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  theme: appTheme(brightness),
  locale: Locale(direction == TextDirection.rtl ? 'ar' : 'zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en'), Locale('ar')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: Directionality(textDirection: direction, child: child!),
  ),
  home: child,
);

Future<void> _selectPreset(WidgetTester tester, String name) async {
  final field = tester.widget<DropdownButtonFormField<AiPreset>>(
    find.byKey(const ValueKey('ai-provider-preset')),
  );
  final preset = AiPresets.all.singleWhere(
    (candidate) => candidate.name == name,
  );
  field.onChanged!(preset);
  await tester.pumpAndSettle();
}

Finder _option(String id) => find.byKey(ValueKey('ai-provider-model-option-$id'));

Future<void> _pumpCustomEditor(
  WidgetTester tester,
  FakeAdapter adapter, {
  double scale = 1,
}) async {
  final settings = AiSettingsController(MemoryAiStore());
  await settings.initialize();
  await tester.pumpWidget(
    _host(
      AiProviderEditor(
        settings: settings,
        clientFactory: (config, key) => _client(config, key, adapter),
      ),
      scale: scale,
    ),
  );
  await _selectPreset(tester, l10n.aiCustomProvider);
  await _fillRequired(tester, key: 'sk-synthetic-123456');
}

String _modelText(WidgetTester tester) => tester
    .widget<TextFormField>(find.byKey(const ValueKey('ai-provider-model')))
    .controller!
    .text;

/// Dismisses the model picker by tapping the barrier above it.
Future<void> _closePicker(WidgetTester tester) async {
  await tester.tapAt(const Offset(8, 8));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('ai-provider-model-picker')), findsNothing);
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _fillRequired(WidgetTester tester, {required String key}) async {
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
    key,
  );
  await tester.pump();
}

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
    conversationId: 'editor-test',
    appVersion: 'test',
  );
}
