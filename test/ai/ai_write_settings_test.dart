import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_settings_page.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_log_page.dart';
import 'package:gitlab_mobile/features/ai/ai_write_settings.dart';
import 'package:gitlab_mobile/features/security/app_lock.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import '../support/workspace_fixture.dart';

final class _Fence implements AiJournalAccountFence {
  @override
  bool isCleaning(String accountKey) => false;
  @override
  Future<T> run<T>(String accountKey, Future<T> Function() action) => action();
}

final class _DeviceCheck implements AppLockAuthenticator {
  _DeviceCheck({this.isAvailable = true, this.passes = true});

  final bool isAvailable;
  final bool passes;
  final reasons = <String>[];

  @override
  Future<bool> available() async => isAvailable;

  @override
  Future<bool> authenticate(String reason) async {
    reasons.add(reason);
    return passes;
  }
}

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  Future<({AiSettingsController settings, WorkspaceFixture fixture})> open(
    WidgetTester tester, {
    _DeviceCheck? device,
    AiAccountRecord? record,
    String tag = 'zh-TW',
    double scale = 1,
    AiWriteJournal? journal,
  }) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final store = MemoryAiStore();
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(store: store);
    addTearDown(settings.dispose);
    addTearDown(history.dispose);
    if (record != null) await store.saveAccount(fixture.account.key, record);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        locale: switch (tag) {
          'ar' => const Locale('ar'),
          'en' => const Locale('en'),
          _ => const Locale('zh', 'TW'),
        },
        supportedLocales: const [
          Locale('zh', 'TW'),
          Locale('ar'),
          Locale('en'),
        ],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: AiSettingsPage(
          settings: settings,
          history: history,
          accountKey: fixture.account.key,
          account: fixture.account,
          deviceCheck: device ?? _DeviceCheck(),
          writeJournal: journal,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (settings: settings, fixture: fixture);
  }

  // The settings list builds lazily; scroll the page to the row first. Rows
  // inside a sheet or a pushed page are already built.
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(finder);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await reveal(tester, finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  AiAccountRecord? recordOf(
    ({AiSettingsController settings, WorkspaceFixture fixture}) opened,
  ) => opened.settings.accountRecord(opened.fixture.account.key);

  testWidgets('defaults to low-risk automatic for both values', (tester) async {
    await open(tester);
    final ceiling = find.byKey(const ValueKey('ai-write-ceiling'));
    await reveal(tester, ceiling);
    expect(
      find.descendant(
        of: ceiling,
        matching: find.textContaining(l10n.aiLevelLowRiskAuto),
      ),
      findsOneWidget,
    );
    await reveal(tester, find.text(l10n.aiWritePromise));
    expect(find.text(l10n.aiWritePromise), findsOneWidget);
  });

  testWidgets('lowering the ceiling saves it and lowers the start', (
    tester,
  ) async {
    final opened = await open(tester);
    await tapKey(tester, 'ai-write-ceiling');
    await tapKey(tester, 'ai-level-confirmEach');
    expect(recordOf(opened)?.ceiling, AiAutonomyLevel.confirmEach);
    expect(recordOf(opened)?.startingLevel.index, lessThanOrEqualTo(1));
  });

  testWidgets('the start offers only levels under the ceiling', (tester) async {
    await open(tester);
    await tapKey(tester, 'ai-write-starting');
    expect(find.byKey(const ValueKey('ai-level-readOnly')), findsOne);
    expect(find.byKey(const ValueKey('ai-level-lowRiskAuto')), findsOne);
    // A conversation grant is made in a conversation, and the start may not
    // pass the ceiling.
    expect(
      find.byKey(const ValueKey('ai-level-conversationGrant')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('ai-level-bypass')), findsNothing);
  });

  testWidgets('allowing everything needs the username and the device', (
    tester,
  ) async {
    final device = _DeviceCheck();
    final opened = await open(tester, device: device);
    await tapKey(tester, 'ai-write-ceiling');
    await tapKey(tester, 'ai-level-bypass');
    expect(find.text(l10n.aiBypassTitle), findsWidgets);
    // The exact account is shown: instance, name, username and numeric ID.
    expect(
      find.text(opened.fixture.account.instance.base.toString()),
      findsOneWidget,
    );
    expect(find.textContaining(l10n.aiBypassUserId('7')), findsOneWidget);
    final confirm = find.byKey(const ValueKey('ai-bypass-confirm'));
    expect(tester.widget<ButtonStyleButton>(confirm).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('ai-bypass-username')),
      '@someone-else',
    );
    await tester.pump();
    expect(tester.widget<ButtonStyleButton>(confirm).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('ai-bypass-username')),
      '@developer',
    );
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(device.reasons, [l10n.aiBypassReason]);
    expect(recordOf(opened)?.ceiling, AiAutonomyLevel.bypass);
  });

  testWidgets('a failed device check turns nothing on', (tester) async {
    final opened = await open(tester, device: _DeviceCheck(passes: false));
    await tapKey(tester, 'ai-write-ceiling');
    await tapKey(tester, 'ai-level-bypass');
    await tester.enterText(
      find.byKey(const ValueKey('ai-bypass-username')),
      'developer',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-bypass-confirm')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiBypassCheckFailed), findsOneWidget);
    // Leave with the close button of the full-screen page.
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(
      recordOf(opened)?.ceiling ?? AiAutonomyLevel.lowRiskAuto,
      AiAutonomyLevel.lowRiskAuto,
    );
  });

  testWidgets('without a screen lock it cannot be turned on', (tester) async {
    await open(tester, device: _DeviceCheck(isAvailable: false));
    await tapKey(tester, 'ai-write-ceiling');
    await tapKey(tester, 'ai-level-bypass');
    expect(find.byKey(const ValueKey('ai-bypass-unavailable')), findsOne);
    final confirm = find.byKey(const ValueKey('ai-bypass-confirm'));
    expect(tester.widget<ButtonStyleButton>(confirm).onPressed, isNull);
  });

  testWidgets('the change log opens from the AI writes section', (
    tester,
  ) async {
    final root = Directory(
      Directory.systemTemp.resolveSymbolicLinksSync(),
    ).createTempSync('ai-settings-log-');
    addTearDown(() => root.deleteSync(recursive: true));
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      fence: _Fence(),
    );
    await open(tester, journal: journal);
    await tapKey(tester, 'ai-write-log');
    expect(find.byType(AiWriteLogPage), findsOneWidget);
    expect(find.text(l10n.aiWriteLogTitle), findsWidgets);
  });

  testWidgets('a log that start-up could not read is flagged', (tester) async {
    final root = Directory(
      Directory.systemTemp.resolveSymbolicLinksSync(),
    ).createTempSync('ai-settings-log-');
    addTearDown(() => root.deleteSync(recursive: true));
    final account = WorkspaceFixture().account.key;
    // The log file exists, but its key is gone (a restored device).
    late AiWriteJournal journal;
    await tester.runAsync(() async {
      final first = AiWriteJournal(
        keys: MemoryAiJournalKeyStore(),
        applicationSupport: root,
        fence: _Fence(),
      );
      await first.recoverAfterAccountsLoaded([account]);
      await first.ensureInitialized(account);
      journal = AiWriteJournal(
        keys: MemoryAiJournalKeyStore(),
        applicationSupport: root,
        fence: _Fence(),
      );
      await journal.recoverAfterAccountsLoaded([account]);
    });
    expect(journal.recoveryStatus(account), AiJournalKeyStatus.keyMissing);
    await open(tester, journal: journal);
    await reveal(tester, find.byKey(const ValueKey('ai-write-log')));
    expect(find.text(l10n.aiWriteLogUnreadableShort), findsOneWidget);
  });

  testWidgets('the attribution footer is a saved switch', (tester) async {
    final opened = await open(tester);
    await tapKey(tester, 'ai-write-attribution');
    expect(recordOf(opened)?.aiAttribution, isTrue);
  });

  for (final (tag, size) in [
    ('zh-TW', const Size(320, 640)),
    ('ar', const Size(320, 640)),
    ('en', const Size(640, 360)),
  ]) {
    testWidgets('fits $tag at 2x on ${size.width}x${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size * tester.view.devicePixelRatio;
      addTearDown(tester.view.reset);
      if (tag != 'zh-TW') useLanguage(languageForTag(tag)!);
      addTearDown(() => useLanguage(languageForTag('zh-TW')!));
      await open(tester, tag: tag, scale: 2);
      await tapKey(tester, 'ai-write-ceiling');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'ai-level-bypass');
      expect(tester.takeException(), isNull);
    });
  }

  test('every level has a name and a description', () {
    for (final level in AiAutonomyLevel.values) {
      expect(aiLevelLabel(level), isNotEmpty);
      expect(aiLevelHint(level), isNotEmpty);
    }
  });
}
