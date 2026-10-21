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
          matching: find.text(l10n.aiProviderModelsUrlInvalid),
        ),
        findsOneWidget,
      );
      // The base URL is valid; its line points at the field to fix.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ai-provider-base-url')),
          matching: find.text(l10n.aiProviderModelsUrlNeedsFix),
        ),
        findsOneWidget,
      );
      expect(find.text(l10n.aiProviderBaseUrlInvalid), findsNothing);
    });

    testWidgets('a tap into the list URL field is not an edit', (tester) async {
      await openCodeGo(tester);
      await tester.tap(find.byKey(const ValueKey('ai-provider-models-url')));
      await tester.pump();
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('ai-provider-models-url')),
          matching: find.byType(TextField),
        ),
      );
      field.controller!.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        elsewhere,
      );
      await tester.pumpAndSettle();
      expect(_modelsUrlText(tester), isEmpty);

      // Tapping the now empty field does not pin it empty either.
      await tester.tap(find.byKey(const ValueKey('ai-provider-models-url')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        AiPresets.openCodeGo.baseUrlFor(AiFormat.chatCompletions),
      );
      await tester.pumpAndSettle();
      expect(_modelsUrlText(tester), AiPresets.openCodeGo.modelsUrl);
    });

    testWidgets('a port too large for an int is an invalid draft', (
      tester,
    ) async {
      await openCodeGo(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        'https://opencode.ai:999999999999999999999999/v1',
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_modelsUrlText(tester), isEmpty);
      expect(find.text(l10n.aiProviderBaseUrlInvalid), findsOneWidget);
    });

    // 411 x 923 is a common phone: the closed form fits without scrolling,
    // so the scroll must wait for the opening section to grow.
    for (final size in const [Size(360, 640), Size(411, 923)]) {
      testWidgets('a blocked save scrolls to the list URL error at '
          '${size.width.toInt()} x ${size.height.toInt()}', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final settings = AiSettingsController(MemoryAiStore());
        await settings.initialize();
        await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
        _preset(tester).onChanged!(AiPresets.openCodeGo);
        await tester.pumpAndSettle();
        await _expandAdvanced(tester);
        await tester.enterText(
          find.byKey(const ValueKey('ai-provider-models-url')),
          'https://opencode.ai/inference/v1/models',
        );
        // Close the section again and go back to the top of the form.
        await _expandAdvanced(tester);
        expect(
          find.byKey(const ValueKey('ai-provider-models-url')),
          findsNothing,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('ai-provider-base-url')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('ai-provider-base-url')),
          elsewhere,
        );
        await tester.enterText(
          find.byKey(const ValueKey('ai-provider-api-key')),
          'sk-synthetic-blocked-save-123456',
        );
        await tester.enterText(
          find.byKey(const ValueKey('ai-provider-model')),
          'synthetic-model',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text(l10n.saveAction));
        // Frames 16 ms apart, as on a device: the first frames of the opening
        // animation do not grow the section yet.
        for (var frame = 0; frame < 40; frame += 1) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pumpAndSettle();

        expect(settings.providers, isEmpty);
        final error = find.descendant(
          of: find.byKey(const ValueKey('ai-provider-models-url')),
          matching: find.text(l10n.aiProviderModelsUrlInvalid),
        );
        expect(error, findsOneWidget);
        final rect = tester.getRect(error);
        expect(
          rect.top,
          greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom),
        );
        expect(rect.bottom, lessThanOrEqualTo(size.height));
      });
    }

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

  group('a blocked save reveals the field that failed', () {
    // Frames 16 ms apart, as on a device.
    Future<void> deviceFrames(WidgetTester tester) async {
      for (var frame = 0; frame < 40; frame += 1) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
    }

    Future<AiSettingsController> filledOpenAi(
      WidgetTester tester, {
      bool largeText = false,
    }) async {
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      final editor = AiProviderEditor(settings: settings);
      await tester.pumpWidget(largeText ? _scaledHost(editor) : _host(editor));
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-api-key')),
        'sk-synthetic-limit-check-123456',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-model')),
        'synthetic-model',
      );
      await tester.pumpAndSettle();
      return settings;
    }

    void expectOnScreen(WidgetTester tester, Finder finder, double bottom) {
      expect(finder, findsOneWidget);
      final rect = tester.getRect(finder);
      expect(
        rect.top,
        greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom),
      );
      expect(rect.bottom, lessThanOrEqualTo(bottom));
    }

    // 2x text with the keyboard open is where revealing the request field
    // instead of the output field hides the output error.
    for (final (label, keyboard, largeText) in const [
      ('412 x 915', 0.0, false),
      ('360 x 640 with the keyboard open', 280.0, false),
      ('360 x 640, 2x text and the keyboard open', 280.0, true),
    ]) {
      for (final output in const [false, true]) {
        testWidgets(
          'a ${output ? 'output' : 'request'} limit error at $label',
          (tester) async {
            final size = keyboard == 0
                ? const Size(412, 915)
                : const Size(360, 640);
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = size;
            tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetViewInsets);
            final settings = await filledOpenAi(tester, largeText: largeText);
            await _expandAdvanced(tester);
            await tester.enterText(
              find.byKey(
                ValueKey(
                  output
                      ? 'ai-provider-output-limit'
                      : 'ai-provider-request-limit',
                ),
              ),
              '1',
            );
            await _expandAdvanced(tester);
            await tester.ensureVisible(
              find.byKey(const ValueKey('ai-provider-base-url')),
            );
            await tester.pumpAndSettle();

            await tester.tap(find.text(l10n.saveAction));
            await deviceFrames(tester);

            expect(settings.providers, isEmpty);
            expectOnScreen(
              tester,
              find.text(
                output
                    ? l10n.aiProviderOutputTokensRange
                    : l10n.aiProviderRequestCharsRange,
              ),
              size.height - keyboard,
            );
          },
        );
      }
    }

    for (final fix in const ['typed value', 'preset switch']) {
      testWidgets('a limit fixed by a $fix while waiting stays put', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 640);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await filledOpenAi(tester);
        await _expandAdvanced(tester);
        await tester.enterText(
          find.byKey(const ValueKey('ai-provider-request-limit')),
          '1',
        );
        await tester.pumpAndSettle();
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        position.jumpTo(0);
        await tester.pump();

        await tester.tap(find.text(l10n.saveAction));
        await tester.pump(const Duration(milliseconds: 16));
        if (fix == 'typed value') {
          tester
                  .widget<TextField>(
                    find.descendant(
                      of: find.byKey(
                        const ValueKey('ai-provider-request-limit'),
                      ),
                      matching: find.byType(TextField),
                    ),
                  )
                  .controller!
                  .text =
              '32000';
        } else {
          _preset(tester).onChanged!(AiPresets.anthropic);
        }
        await deviceFrames(tester);

        expect(position.pixels, 0);
        if (fix == 'preset switch') {
          // The reset value is valid; the old error is not left behind.
          expect(find.text(l10n.aiProviderRequestCharsRange), findsNothing);
        }
      });
    }

    testWidgets('a missing key scrolls back up to the key field', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-model')),
        'synthetic-model',
      );
      await _expandAdvanced(tester);
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();

      await tester.tap(find.text(l10n.saveAction));
      await deviceFrames(tester);

      expect(settings.providers, isEmpty);
      expectOnScreen(tester, find.text(l10n.aiProviderKeyMinimum), 640);
    });

    testWidgets('an error fixed while waiting does not move the page', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
      _preset(tester).onChanged!(AiPresets.openCodeGo);
      await tester.pumpAndSettle();
      await _expandAdvanced(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-models-url')),
        'https://opencode.ai/inference/v1/models',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        'https://different-recipient.example/v1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-api-key')),
        'sk-synthetic-stale-reveal-123456',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-model')),
        'synthetic-model',
      );
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(0);
      await tester.pump();

      await tester.tap(find.text(l10n.saveAction));
      await tester.pump(const Duration(milliseconds: 16));
      // The user clears the list URL before the scroll starts.
      tester
              .widget<TextField>(
                find.descendant(
                  of: find.byKey(const ValueKey('ai-provider-models-url')),
                  matching: find.byType(TextField),
                ),
              )
              .controller!
              .text =
          '';
      await deviceFrames(tester);

      expect(find.text(l10n.aiProviderModelsUrlInvalid), findsNothing);
      expect(position.pixels, 0);
    });
  });

  testWidgets('the key status follows the draft as it is typed', (
    tester,
  ) async {
    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
    expect(find.text(l10n.aiProviderKeyNotSet), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-api-key')),
      'sk-synthetic-status-123456',
    );
    await tester.pump();
    expect(find.text(l10n.aiProviderKeySet), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('ai-provider-api-key')),
      '',
    );
    await tester.pump();
    expect(find.text(l10n.aiProviderKeyNotSet), findsOneWidget);
  });

  testWidgets('Arabic reads /models left to right inside its message', (
    tester,
  ) async {
    useLanguage(languageForTag('ar')!);
    final message = l10n.aiProviderModelsUrlInvalid;
    final painter = TextPainter(
      text: TextSpan(text: message),
      textDirection: TextDirection.rtl,
    )..layout();
    addTearDown(painter.dispose);
    final slash = message.indexOf('/models');
    double left(int index) => painter
        .getBoxesForSelection(
          TextSelection(baseOffset: index, extentOffset: index + 1),
        )
        .single
        .left;
    // The slash is drawn before (left of) the "m" and the "s" last.
    expect(left(slash), lessThan(left(slash + 1)));
    expect(left(slash + 1), lessThan(left(slash + 6)));
  });

  group('a port too large for an int with a key draft', () {
    const huge = 'https://opencode.ai:999999999999999999999999/v1';

    Future<void> openCodeGo(WidgetTester tester) async {
      final settings = AiSettingsController(MemoryAiStore());
      await settings.initialize();
      await tester.pumpWidget(_host(AiProviderEditor(settings: settings)));
      _preset(tester).onChanged!(AiPresets.openCodeGo);
      await tester.pumpAndSettle();
    }

    testWidgets('typed after the key', (tester) async {
      await openCodeGo(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-api-key')),
        'sk-synthetic-huge-port-123456',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        huge,
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(l10n.aiProviderBaseUrlInvalid), findsOneWidget);
    });

    testWidgets('typed before the key still binds the draft', (tester) async {
      await openCodeGo(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        huge,
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-api-key')),
        'sk-synthetic-huge-port-123456',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.enterText(
        find.byKey(const ValueKey('ai-provider-base-url')),
        'https://different-recipient.example/v1',
      );
      await tester.pumpAndSettle();

      expect(_keyField(tester).controller!.text, isEmpty);
      expect(find.text(l10n.aiProviderKeyDraftCleared), findsOneWidget);
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
