import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/security/app_lock.dart';

import '../support/ai_run_notification_shell.dart';
import '../support/shell_nav.dart';
import '../support/widget_settle.dart';

const _channel = MethodChannel('io.gitlabmobile/c6_root_back_test');

/// The native run channel as C-D10 describes it: a side-effect-free
/// sequence probe, and `moveTaskToBack` counted like the debug QA counter.
final class _Native {
  var moves = 0;
  Map<String, Object> reply = {'version': 1, 'status': 'moved'};
  Completer<void>? hold;
  Completer<void>? holdProbe;
  final methods = <String>[];

  void install() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        methods.add(call.method);
        switch (call.method) {
          case 'moveTaskToBack':
            moves++;
            await hold?.future;
            return reply;
          case 'updateProgress':
            await holdProbe?.future;
            return {
              'version': 1,
              'status': 'rejected',
              'reason': 'permit_inactive',
            };
          case 'releaseRuns':
            return {'version': 1, 'status': 'released', 'didRelease': false};
          case 'stopAll':
            return {'version': 1, 'status': 'stopped'};
        }
        return {'version': 1, 'status': 'rejected', 'reason': 'unavailable'};
      });

  void uninstall() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null);
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

void main() {
  late FakeNotificationPlatform platform;
  late _Native native;
  // What happens when the shell lets a root back through: the app finishes.
  late List<String> systemPops;

  setUp(() {
    (platform = FakeNotificationPlatform()).install();
    (native = _Native()).install();
    systemPops = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemNavigator.pop') systemPops.add(call.method);
          return null;
        });
  });
  tearDown(() {
    platform.uninstall();
    native.uninstall();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<NotificationShell> start(
    WidgetTester tester, {
    AppLockController? lock,
  }) => NotificationShell.start(
    tester,
    platform: platform,
    lock: lock,
    aiRunsChannel: _channel,
  );

  /// One system back, as Android sends it, then the bridge's replies.
  Future<bool> back(WidgetTester tester) async {
    final handled = await tester.binding.handlePopRoute();
    await settleNetworkWidgets(tester);
    return handled;
  }

  /// The chat waiting for an approval is protected work (D11).
  Future<NotificationChat> protect(
    NotificationShell shell,
    WidgetTester tester,
  ) async {
    // A real conversation opens idle and reports the change that makes it
    // protected; the registry notifies the shell on that change.
    shell.chat.phase = AiChatPhase.idle;
    final chat = shell.openChat(tester);
    chat
      ..phase = AiChatPhase.awaitingApproval
      ..notifyListeners();
    await tester.pump();
    expect(
      (shell.registry(tester) as AiExecutionRunRegistry).backProtectedCount,
      1,
    );
    return chat;
  }

  testWidgets('root back with protected work moves the task once and keeps '
      'the page', (tester) async {
    final shell = await start(tester);
    await protect(shell, tester);
    await tester.pump();
    expect(await back(tester), isTrue);
    expect(native.moves, 1);
    expect(systemPops, isEmpty);
    // The probe seeds the sequence before the one move.
    expect(native.methods.where((m) => m == 'moveTaskToBack'), hasLength(1));
    expect(selectedDestination(tester), 0);
    expect(selectedDestination(tester), 0);
  });

  testWidgets('paused and running work are protected as well', (tester) async {
    final shell = await start(tester);
    final chat = await protect(shell, tester);
    for (final phase in [AiChatPhase.running, AiChatPhase.stopping]) {
      chat
        ..phase = phase
        ..notifyListeners();
      await tester.pump();
      native.moves = 0;
      expect(await back(tester), isTrue);
      expect(native.moves, 1, reason: phase.name);
    }
    expect(systemPops, isEmpty);
  });

  testWidgets('without AI work root back behaves as before', (tester) async {
    await start(tester);
    expect(await back(tester), isFalse);
    expect(native.moves, 0);
    expect(systemPops, hasLength(1));
  });

  testWidgets('work that ends restores the normal root back', (tester) async {
    final shell = await start(tester);
    final chat = await protect(shell, tester);
    chat
      ..phase = AiChatPhase.idle
      ..notifyListeners();
    await tester.pump();
    expect(await back(tester), isFalse);
    expect(native.moves, 0);
    expect(systemPops, hasLength(1));
  });

  testWidgets('a pushed route and a dialog pop normally first', (tester) async {
    final shell = await start(tester);
    await protect(shell, tester);
    final context = tester.element(
      find.byWidgetPredicate((w) => w is NavigationBar || w is NavigationRail),
    );
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('pushed page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(await back(tester), isTrue);
    expect(find.text('pushed page'), findsNothing);
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('a dialog')),
      ),
    );
    await tester.pumpAndSettle();
    expect(await back(tester), isTrue);
    expect(find.text('a dialog'), findsNothing);
    expect(native.moves, 0);
    // Now on the root page: the next back moves the task.
    expect(await back(tester), isTrue);
    expect(native.moves, 1);
    expect(systemPops, isEmpty);
  });

  testWidgets('another tab returns to Home first', (tester) async {
    final shell = await start(tester);
    await protect(shell, tester);
    await openExplore(tester);
    expect(selectedDestination(tester), isNot(0));
    expect(await back(tester), isTrue);
    expect(selectedDestination(tester), 0);
    expect(native.moves, 0);
    expect(await back(tester), isTrue);
    expect(native.moves, 1);
  });

  testWidgets('an open keyboard closes first', (tester) async {
    final shell = await start(tester);
    await protect(shell, tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    expect(await back(tester), isTrue);
    expect(native.moves, 0);
    expect(systemPops, isEmpty);
    tester.view.resetViewInsets();
    await tester.pump();
    expect(await back(tester), isTrue);
    expect(native.moves, 1);
  });

  testWidgets('a locked app keeps back held and moves nothing', (tester) async {
    final lock = AppLockController(store: _Store(true), authenticator: _Auth());
    addTearDown(lock.dispose);
    await tester.runAsync(lock.start);
    final shell = await start(tester, lock: lock);
    await protect(shell, tester);
    await tester.pump();
    expect(lock.locked, isTrue);
    expect(await back(tester), isTrue);
    expect(native.moves, 0);
    expect(systemPops, isEmpty);
  });

  testWidgets('a back pressed while one is under way is not repeated', (
    tester,
  ) async {
    final shell = await start(tester);
    await protect(shell, tester);
    native.hold = Completer<void>();
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    native.hold!.complete();
    await settleNetworkWidgets(tester);
    expect(native.moves, 1);
    expect(systemPops, isEmpty);
  });

  testWidgets('a dialog opened before the native call cancels the move', (
    tester,
  ) async {
    final shell = await start(tester);
    await protect(shell, tester);
    native.holdProbe = Completer<void>();
    await tester.binding.handlePopRoute();
    await tester.pump();
    final context = tester.element(
      find.byWidgetPredicate((w) => w is NavigationBar || w is NavigationRail),
    );
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('a dialog')),
      ),
    );
    await tester.pump();
    native.holdProbe!.complete();
    await tester.pumpAndSettle();
    // The live check runs again after the wait: the dialog is on top.
    expect(native.moves, 0);
    expect(find.text('a dialog'), findsOneWidget);
    expect(systemPops, isEmpty);
  });

  for (final (status, reason) in [
    ('not_moved', null),
    ('rejected', 'move_failed'),
    ('rejected', 'foreground_required'),
  ]) {
    testWidgets('a $status ${reason ?? ""} result leaves the app open', (
      tester,
    ) async {
      final shell = await start(tester);
      await protect(shell, tester);
      native.reply = {'version': 1, 'status': status, 'reason': ?reason};
      expect(await back(tester), isTrue);
      expect(native.moves, 1);
      expect(systemPops, isEmpty);
      expect(selectedDestination(tester), 0);
    });
  }

  testWidgets('a wide window with the rail behaves the same', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = await start(tester);
    await protect(shell, tester);
    await tester.pump();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(await back(tester), isTrue);
    expect(native.moves, 1);
    expect(systemPops, isEmpty);
  });
}
