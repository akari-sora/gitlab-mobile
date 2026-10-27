import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_run_notification_ui.dart';
import 'package:gitlab_mobile/features/ai/ai_run_notifications.dart';
import 'package:gitlab_mobile/features/security/app_lock.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import '../support/ai_run_notification_shell.dart';
import '../support/shell_nav.dart';
import '../support/widget_settle.dart';

final _android = TargetPlatformVariant.only(TargetPlatform.android);

void _background(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _resume(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.resumed) return;
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

final class _Store implements AppLockStore {
  _Store(this.value);
  bool value;
  @override
  Future<bool> read() async => value;
  @override
  Future<void> write(bool enabled) async => value = enabled;
}

final class _Auth implements AppLockAuthenticator {
  Completer<bool>? pending;
  @override
  Future<bool> available() async => true;
  @override
  Future<bool> authenticate(String reason) =>
      (pending = Completer<bool>()).future;
}

Finder get _card => find.byKey(const ValueKey('ai-proposal-card-exec-1'));

/// Every string the plugin was asked to show, at any depth.
Iterable<String> _strings(Object? value) sync* {
  switch (value) {
    case String():
      yield value;
    case Map():
      for (final entry in value.entries) {
        yield* _strings(entry.key);
        yield* _strings(entry.value);
      }
    case Iterable():
      for (final item in value) {
        yield* _strings(item);
      }
  }
}

void main() {
  late FakeNotificationPlatform platform;

  setUp(() => (platform = FakeNotificationPlatform()).install());
  tearDown(() => platform.uninstall());

  for (final withLock in [false, true]) {
    testWidgets('background tap waits without popping or pushing: '
        '${withLock ? "loaded disabled lock" : "no lock"}', (tester) async {
      final lock = withLock
          ? AppLockController(store: _Store(false), authenticator: _Auth())
          : null;
      if (lock != null) {
        addTearDown(lock.dispose);
        await tester.runAsync(lock.start);
        expect(lock.loaded, isTrue);
        expect(lock.enabled, isFalse);
      }
      final shell = await NotificationShell.start(
        tester,
        platform: platform,
        lock: lock,
      );
      final chat = shell.openChat(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('covered-page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _background(tester);
      addTearDown(() => _resume(tester));

      await platform.tap(notificationPayload(chat.id, shell.generation));
      await tester.pump();
      expect(shell.gate.waiting, isTrue);
      expect(shell.gate.take(), isNull);
      expect(find.text('covered-page'), findsOneWidget);
      expect(find.byType(AiChatPage), findsNothing);

      _resume(tester);
      await settleNetworkWidgets(tester);
      expect(shell.gate.waiting, isFalse);
      expect(find.text('covered-page'), findsNothing);
      expect(
        tester.widget<AiChatPage>(find.byType(AiChatPage)).session,
        same(chat),
      );
    }, variant: _android);
  }

  for (final change in [
    'background',
    'owner',
    'background with covered page',
  ]) {
    testWidgets('notification rechecks $change after awaited editor exit', (
      tester,
    ) async {
      final shell = await NotificationShell.start(tester, platform: platform);
      final chat = shell.openChat(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      MaterialPageRoute<void>? covered;
      if (change == 'background with covered page') {
        covered = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('covered-page')),
        );
        unawaited(navigator.push(covered));
        await tester.pumpAndSettle();
      }
      final exit = Completer<void>();
      var leaveAttempts = 0;
      final editor = MaterialPageRoute<void>(
        builder: (context) => PopScope<void>(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            leaveAttempts++;
            RouteExit.track(ModalRoute.of(context)!, exit.future);
          },
          child: const Scaffold(body: Text('async-editor')),
        ),
      );
      unawaited(navigator.push(editor));
      await tester.pumpAndSettle();

      await platform.tap(notificationPayload(chat.id, shell.generation));
      await tester.pump();
      expect(leaveAttempts, 1);
      expect(
        shell.gate.waiting,
        isFalse,
        reason: 'an editor exit attempt consumes this tap',
      );
      if (change.startsWith('background')) {
        _background(tester);
        addTearDown(() => _resume(tester));
      } else {
        final replacement = _OtherRegistry();
        addTearDown(replacement.dispose);
        shell.gate.bind(replacement);
      }
      // The editor finishes its own guarded exit; the notification must
      // neither pop another page nor push a chat after this await.
      navigator.removeRoute(editor);
      exit.complete();
      await tester.pump();
      expect(find.byType(AiChatPage), findsNothing);
      if (change == 'background with covered page') {
        expect(covered!.isActive, isTrue);
      }
      _resume(tester);
      await settleNetworkWidgets(tester);
      expect(
        find.byType(AiChatPage),
        findsNothing,
        reason:
            'a consumed tap is dropped when foreground or ownership changes',
      );
    }, variant: _android);
  }

  testWidgets(
    'cancelled unlock invalidates delayed cold tap, new warm tap works',
    (tester) async {
      final auth = _Auth();
      final lock = AppLockController(store: _Store(true), authenticator: auth);
      addTearDown(lock.dispose);
      await tester.runAsync(lock.start);
      final shell = await NotificationShell.start(
        tester,
        platform: platform,
        lock: lock,
        initializeBeforeShell: false,
      );
      final chat = shell.openChat(tester);
      platform.launchPayload = notificationPayload(chat.id, shell.generation);
      platform.launchRequested = Completer<void>();
      platform.launchBarrier = Completer<void>();
      final initializing = shell.notifications.initialize();
      await tester.pump();
      expect(platform.launchRequested!.isCompleted, isTrue);
      auth.pending!.complete(false);
      await tester.pump();
      expect(lock.refusedUnlocks, 1);
      platform.launchBarrier!.complete();
      await initializing;
      expect(shell.gate.waiting, isFalse);

      final unlocking = lock.unlock();
      auth.pending!.complete(true);
      await unlocking;
      await settleNetworkWidgets(tester);
      expect(find.byType(AiChatPage), findsNothing);
      await platform.tap(notificationPayload(chat.id, shell.generation));
      await settleNetworkWidgets(tester);
      expect(
        tester.widget<AiChatPage>(find.byType(AiChatPage)).session,
        same(chat),
      );
    },
    variant: _android,
  );

  testWidgets(
    'warm tap without a lock opens the conversation at its waiting card',
    (tester) async {
      final shell = await NotificationShell.start(tester, platform: platform);
      final chat = shell.openChat(tester);
      await tapDestination(tester, l10n.meTab);

      await platform.tap(notificationPayload(chat.id, shell.generation));
      await settleNetworkWidgets(tester);

      final page = tester.widget<AiChatPage>(find.byType(AiChatPage));
      expect(page.session, same(chat));
      expect(page.focusProposal, 'exec-1');
      expect(_card.hitTestable(), findsOneWidget);
      expect(shell.gate.waiting, isFalse);
      // Opening the card shows it; approving stays the user's tap.
      expect(chat.approved, isEmpty);

      // Leaving the page releases the visit; the waiting session stays.
      Navigator.of(tester.element(find.byType(AiChatPage))).pop();
      await settleNetworkWidgets(tester);
      expect(find.byType(AiChatPage), findsNothing);
      expect(
        shell
            .registry(tester)
            .sessionForConversation(chat.id, shell.generation),
        same(chat),
      );
    },
    variant: _android,
  );

  testWidgets('a conversation whose card is gone opens without a card', (
    tester,
  ) async {
    final shell = await NotificationShell.start(tester, platform: platform);
    final chat = shell.openChat(tester)..proposals = [];

    await platform.tap(notificationPayload(chat.id, shell.generation));
    await settleNetworkWidgets(tester);

    final page = tester.widget<AiChatPage>(find.byType(AiChatPage));
    expect(page.session, same(chat));
    expect(page.focusProposal, isNull);
    expect(_card, findsNothing);
  }, variant: _android);

  testWidgets(
    'a stale generation or unknown conversation goes to 首頁, opening nothing',
    (tester) async {
      final shell = await NotificationShell.start(tester, platform: platform);
      final chat = shell.openChat(tester);
      await tapDestination(tester, l10n.meTab);
      expect(selectedDestination(tester), 3);

      await platform.tap(notificationPayload(chat.id, shell.generation + 1));
      await settleNetworkWidgets(tester);
      expect(find.byType(AiChatPage), findsNothing);
      expect(selectedDestination(tester), 0);

      await tapDestination(tester, l10n.meTab);
      await platform.tap(notificationPayload('another', shell.generation));
      await settleNetworkWidgets(tester);
      expect(find.byType(AiChatPage), findsNothing);
      expect(selectedDestination(tester), 0);
      expect(shell.gate.waiting, isFalse);
    },
    variant: _android,
  );

  testWidgets(
    'cold start: the launch tap waits behind the lock, then goes to 首頁 '
    'because a new process holds no conversation',
    (tester) async {
      final auth = _Auth();
      final lock = AppLockController(store: _Store(true), authenticator: auth);
      addTearDown(lock.dispose);
      await tester.runAsync(lock.start);
      // The tap arrives before any shell or registry exists.
      platform.launchPayload = notificationPayload('conversation-1', 1);
      final shell = await NotificationShell.start(
        tester,
        platform: platform,
        lock: lock,
      );
      expect(lock.locked, isTrue);
      expect(lock.authenticating, isTrue, reason: 'the lock asked by itself');
      expect(shell.gate.waiting, isTrue);
      expect(find.byType(AiChatPage), findsNothing);

      auth.pending!.complete(true);
      await settleNetworkWidgets(tester);
      expect(lock.locked, isFalse);
      expect(shell.gate.waiting, isFalse);
      expect(find.byType(AiChatPage), findsNothing);
      expect(selectedDestination(tester), 0);
    },
    variant: _android,
  );

  testWidgets(
    'cold start uses the same gate: a launch tap for a held conversation '
    'opens its card only after unlock',
    (tester) async {
      final auth = _Auth();
      final lock = AppLockController(store: _Store(true), authenticator: auth);
      addTearDown(lock.dispose);
      await tester.runAsync(lock.start);
      final shell = await NotificationShell.start(
        tester,
        platform: platform,
        lock: lock,
        initializeBeforeShell: false,
      );
      final chat = shell.openChat(tester);
      platform.launchPayload = notificationPayload(chat.id, shell.generation);
      expect(await shell.notifications.initialize(), isTrue);
      await settleNetworkWidgets(tester);
      expect(shell.gate.waiting, isTrue);
      expect(find.byType(AiChatPage), findsNothing);

      auth.pending!.complete(true);
      await settleNetworkWidgets(tester);
      expect(
        tester.widget<AiChatPage>(find.byType(AiChatPage)).session,
        same(chat),
      );
      expect(_card.hitTestable(), findsOneWidget);
      expect(chat.approved, isEmpty);
    },
    variant: _android,
  );

  testWidgets(
    'a replaced shell never unbinds the registry the newer shell bound',
    (tester) async {
      final shell = await NotificationShell.start(tester, platform: platform);
      final first = shell.registry(tester);
      // Unbinding a registry that is not the bound one changes nothing.
      shell.gate.unbind(_OtherRegistry());
      await shell.replaceShell(tester, const ValueKey('next'));
      final second = shell.registry(tester);
      expect(second, isNot(same(first)));
      final chat = shell.openChat(tester);

      await platform.tap(notificationPayload(chat.id, shell.generation));
      await settleNetworkWidgets(tester);
      expect(
        tester.widget<AiChatPage>(find.byType(AiChatPage)).session,
        same(chat),
      );
      expect(_card.hitTestable(), findsOneWidget);
    },
    variant: _android,
  );

  group('notification text', () {
    testWidgets(
      'is read again for each notification, follows the language and holds '
      'nothing from the conversation',
      (tester) async {
        final shell = await NotificationShell.start(tester, platform: platform);
        final chat = shell.openChat(tester);
        chat.emit(AiRunNotificationKind.needsApproval, shell.generation);
        await tester.pump();
        useLanguage(languageForTag('en')!);
        chat.emit(AiRunNotificationKind.completed, shell.generation);
        await tester.pump();
        useLanguage(sourceLanguage);

        final shows = platform.shows;
        expect(shows, hasLength(2));
        final zh = AppStrings(sourceLanguage);
        final en = AppStrings(languageForTag('en')!);
        expect(shows[0]['title'], zh.aiRunNoticeTitle);
        expect(shows[0]['body'], zh.aiRunNoticeNeedsApproval);
        expect(_strings(shows[0]), contains(zh.aiRunNoticeApprovalChannel));
        expect(shows[1]['title'], en.aiRunNoticeTitle);
        expect(shows[1]['body'], en.aiRunNoticeCompleted);
        expect(_strings(shows[1]), contains(en.aiRunNoticeResultChannel));
        for (final show in shows) {
          for (final text in _strings(show)) {
            for (final sentinel in notificationSentinels) {
              expect(text, isNot(contains(sentinel)));
            }
          }
        }
      },
      variant: _android,
    );

    test('every language has short, generic text for the lock screen', () {
      for (final language in appLanguages) {
        useLanguage(language);
        final text = aiRunNotificationText();
        final bodies = [
          text.needsApproval,
          text.completed,
          text.failed,
          text.interrupted,
        ];
        final all = [
          text.approvalChannelName,
          text.resultChannelName,
          text.title,
          ...bodies,
        ];
        expect(all.every((value) => value.trim().isNotEmpty), isTrue);
        expect(bodies.toSet(), hasLength(4), reason: language.tag);
        expect(text.title.length, lessThanOrEqualTo(24), reason: language.tag);
        for (final value in all) {
          expect(value.length, lessThanOrEqualTo(48), reason: value);
          expect(value, isNot(contains('{')), reason: value);
        }
      }
      useLanguage(sourceLanguage);
    });
  });

  group('permission before the first run', () {
    late AiRunNotifications notifications;
    late AiRunNotificationGate gate;
    late NotificationChat chat;

    Future<void> pumpChat(WidgetTester tester) async {
      notifications = AiRunNotifications(text: aiRunNotificationText);
      gate = AiRunNotificationGate(notifications);
      chat = NotificationChat()..phase = AiChatPhase.idle;
      addTearDown(chat.dispose);
      addTearDown(notifications.dispose);
      addTearDown(gate.dispose);
      await tester.pumpWidget(
        AiRunNotificationScope(
          gate: gate,
          child: MaterialApp(home: AiChatPage(session: chat)),
        ),
      );
      await tester.pump();
    }

    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const ValueKey('ai-chat-input')), text);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
      await tester.pump();
      await tester.pump();
    }

    Finder disclosure() => find.text(l10n.aiRunNoticeDenied);

    testWidgets(
      'enabled notifications skip explanation and permission request',
      (tester) async {
        platform.notificationsEnabled = true;
        await pumpChat(tester);
        await send(tester, 'hello');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ai-run-notice-ask')), findsNothing);
        expect(platform.permissionRequests, 0);
        expect(chat.sent, ['hello']);
        expect(disclosure(), findsNothing);
      },
      variant: _android,
    );

    testWidgets('known disabled notifications disclose without asking again', (
      tester,
    ) async {
      platform.notificationsEnabled = false;
      await pumpChat(tester);
      await send(tester, 'hello');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-run-notice-ask')), findsNothing);
      expect(platform.permissionRequests, 0);
      expect(chat.sent, ['hello']);
      expect(disclosure(), findsOneWidget);
    }, variant: _android);

    testWidgets(
      'blocked approval channel discloses without a permission request',
      (tester) async {
        platform.notificationsEnabled = true;
        platform.channels = [
          notificationChannel('ai_run_approvals_v1', importance: 0),
        ];
        await pumpChat(tester);
        await send(tester, 'hello');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ai-run-notice-ask')), findsNothing);
        expect(platform.permissionRequests, 0);
        expect(chat.sent, ['hello']);
        expect(disclosure(), findsOneWidget);
      },
      variant: _android,
    );

    testWidgets('not now rechecks permission before disclosing off', (
      tester,
    ) async {
      await pumpChat(tester);
      await send(tester, 'hello');
      expect(find.byKey(const ValueKey('ai-run-notice-ask')), findsOneWidget);
      platform.notificationsEnabled = true;
      await tester.tap(find.byKey(const ValueKey('ai-run-notice-skip')));
      await tester.pumpAndSettle();
      expect(platform.permissionRequests, 0);
      expect(chat.sent, ['hello']);
      expect(disclosure(), findsNothing);
    }, variant: _android);

    for (final appEnabled in [false, true]) {
      testWidgets(
        'unknown notification state never discloses off: '
        '${appEnabled ? "enabled app with unreadable channels" : "unreadable app permission"}',
        (tester) async {
          if (appEnabled) {
            platform.notificationsEnabled = true;
            platform.channels = null;
          }
          await pumpChat(tester);
          await send(tester, 'hello');
          expect(
            find.byKey(const ValueKey('ai-run-notice-ask')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('ai-run-notice-skip')));
          await tester.pumpAndSettle();
          expect(platform.permissionRequests, 0);
          expect(chat.sent, ['hello']);
          expect(disclosure(), findsNothing);
        },
        variant: _android,
      );
    }

    testWidgets(
      'a refusal still sends, and says once that no reminder will come and '
      'proposals expire after 30 minutes',
      (tester) async {
        platform.permission = false;
        await pumpChat(tester);
        await send(tester, 'first');
        expect(find.byKey(const ValueKey('ai-run-notice-ask')), findsOneWidget);
        expect(chat.sent, isEmpty, reason: 'nothing is sent behind the dialog');
        expect(platform.permissionRequests, 0, reason: 'explained first');

        await tester.tap(find.byKey(const ValueKey('ai-run-notice-continue')));
        await tester.pumpAndSettle();
        expect(platform.permissionRequests, 1);
        expect(chat.sent, ['first']);
        expect(disclosure(), findsOneWidget);
        expect(l10n.aiRunNoticeDenied, contains('30'));
        expect(find.byKey(const ValueKey('ai-chat-input')), findsOneWidget);

        await tester.pump(const Duration(seconds: 11));
        await tester.pumpAndSettle();
        expect(disclosure(), findsNothing);
        chat.phase = AiChatPhase.idle;
        await send(tester, 'second');
        await tester.pumpAndSettle();
        expect(chat.sent, ['first', 'second']);
        expect(find.byKey(const ValueKey('ai-run-notice-ask')), findsNothing);
        expect(platform.permissionRequests, 1, reason: 'once per process');
        expect(disclosure(), findsNothing, reason: 'disclosed once');
      },
      variant: _android,
    );

    testWidgets('a grant sends without a disclosure', (tester) async {
      await pumpChat(tester);
      await send(tester, 'hello');
      await tester.tap(find.byKey(const ValueKey('ai-run-notice-continue')));
      await tester.pumpAndSettle();
      expect(platform.permissionRequests, 1);
      expect(chat.sent, ['hello']);
      expect(disclosure(), findsNothing);
    }, variant: _android);

    testWidgets(
      'not now skips the system request, discloses, and still sends',
      (tester) async {
        await pumpChat(tester);
        await send(tester, 'hello');
        platform.notificationsEnabled = false;
        await tester.tap(find.byKey(const ValueKey('ai-run-notice-skip')));
        await tester.pumpAndSettle();
        expect(platform.permissionRequests, 0);
        expect(chat.sent, ['hello']);
        expect(disclosure(), findsOneWidget);
      },
      variant: _android,
    );

    testWidgets('an unavailable request leaves state unknown and still sends', (
      tester,
    ) async {
      platform.permission = null;
      await pumpChat(tester);
      await send(tester, 'hello');
      await tester.tap(find.byKey(const ValueKey('ai-run-notice-continue')));
      await tester.pumpAndSettle();
      expect(chat.sent, ['hello']);
      expect(disclosure(), findsNothing);
    }, variant: _android);

    testWidgets('where notifications are not supported nothing is asked', (
      tester,
    ) async {
      await pumpChat(tester);
      await send(tester, 'hello');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-run-notice-ask')), findsNothing);
      expect(platform.calls, isEmpty);
      expect(chat.sent, ['hello']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}

/// A registry this shell never bound.
final class _OtherRegistry extends ChangeNotifier implements AiRunRegistry {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected registry access: ${invocation.memberName}');
}
