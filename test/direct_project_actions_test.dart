import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'session_test.dart' show MemoryAccountStore;
import 'workspace_widget_test.dart' show workspaceHost;

String _apiPath(RequestOptions request) {
  final parts = request.uri.pathSegments;
  return parts.skip(parts.indexOf('v4') + 1).join('/');
}

final class _StarFixture extends WorkspaceFixture {
  _StarFixture({
    this.starred = false,
    this.failReads = false,
    this.respond304 = false,
  });

  bool starred;
  bool failReads;
  bool respond304;
  int? starWriteFailure;
  int starReads = 0, starWrites = 0;
  Completer<void>? readGate, writeGate;

  @override
  Future<ResponseBody> respond(RequestOptions request) async {
    final path = _apiPath(request);
    if (path == 'projects/42/starrers') {
      starReads++;
      await readGate?.future;
      if (failReads) {
        return jsonResponse({'message': 'unavailable'}, status: 503);
      }
      return jsonResponse(
        starred
            ? [
                {
                  'user': {'id': 7, 'username': 'developer'},
                },
              ]
            : <Object>[],
      );
    }
    if (path == 'projects/42' && request.method == 'GET') {
      return jsonResponse({...projectRecord, 'star_count': starred ? 1 : 0});
    }
    if ((path == 'projects/42/star' || path == 'projects/42/unstar') &&
        request.method == 'POST') {
      starWrites++;
      await writeGate?.future;
      if (starWriteFailure case final status?) {
        return jsonResponse({
          'message': 'synthetic star failure',
        }, status: status);
      }
      starred = path.endsWith('/star');
      if (respond304) return ResponseBody.fromString('', 304);
      return jsonResponse({...projectRecord, 'star_count': starred ? 1 : 0});
    }
    return await Future<ResponseBody>.value(super.respond(request));
  }
}

Widget _page(
  _StarFixture fixture, {
  Project? project,
  Future<void> Function()? onStarChanged,
}) =>
    workspaceHost(
      ProjectPage(
        key: const ValueKey('same-project-page'),
        account: fixture.account,
        api: fixture.api,
        project: project ?? fixture.project,
        onStarChanged: onStarChanged,
      ),
    );

final class _FakeUrlLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

void main() {
  testWidgets('a late More star retry failure stays with its original owner', (tester) async {
    final old = _StarFixture(failReads: true);
    final replacement = _StarFixture(starred: true);
    addTearDown(old.api.close);
    addTearDown(replacement.api.close);
    await tester.pumpWidget(_page(old));
    await settleNetworkWidgets(tester);
    await tester.tap(find.widgetWithText(Tab, '更多'));
    await settleNetworkWidgets(tester);
    old.readGate = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('project-star-toggle')));
    await tester.pump();
    await tester.pumpWidget(_page(replacement));
    await settleNetworkWidgets(tester);
    old.readGate!.complete();
    await settleNetworkWidgets(tester);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('移除星標'), findsOneWidget);
    expect(old.starWrites, 0);
  });

  testWidgets('closed API disables direct project actions', (tester) async {
    final fixture = _StarFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(_page(fixture));
    await settleNetworkWidgets(tester);
    fixture.api.close();
    await tester.pumpWidget(_page(fixture));
    await settleNetworkWidgets(tester);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('project-header-star'))).onPressed, isNull);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.share_outlined)).onPressed, isNull);
    expect(fixture.starWrites, 0);
  });

  testWidgets('header and More share one star state and one write', (
    tester,
  ) async {
    final fixture = _StarFixture();
    addTearDown(fixture.api.close);
    var reconciled = 0;
    await tester.pumpWidget(
      _page(fixture, onStarChanged: () async => reconciled++),
    );
    await settleNetworkWidgets(tester);

    expect(fixture.starReads, 1);
    await tester.tap(find.byTooltip('加入星標'));
    await settleNetworkWidgets(tester);
    expect(fixture.starWrites, 1);
    expect(reconciled, 1);
    expect(find.byTooltip('移除星標'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, '更多'));
    await settleNetworkWidgets(tester);
    expect(find.text('移除星標'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ProjectMoreTab),
        matching: find.text('1'),
      ),
      findsOneWidget,
      reason: 'the header response star_count is shared with More',
    );
    expect(fixture.starReads, 1, reason: 'More must reuse the header state');
  });

  testWidgets('unknown star state retries without guessing a write direction', (
    tester,
  ) async {
    final fixture = _StarFixture(failReads: true);
    addTearDown(fixture.api.close);
    await tester.pumpWidget(_page(fixture));
    await settleNetworkWidgets(tester);
    expect(find.byTooltip('重新確認星標'), findsOneWidget);
    expect(fixture.starWrites, 0);

    fixture
      ..failReads = false
      ..starred = true;
    await tester.tap(find.byTooltip('重新確認星標'));
    await settleNetworkWidgets(tester);
    expect(find.byTooltip('移除星標'), findsOneWidget);
    expect(fixture.starWrites, 0);
  });

  testWidgets(
    '304 still refreshes More count without a second star-state read',
    (tester) async {
      final fixture = _StarFixture(respond304: true);
      addTearDown(fixture.api.close);
      await tester.pumpWidget(_page(fixture));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byTooltip('加入星標'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.widgetWithText(Tab, '更多'));
      await settleNetworkWidgets(tester);
      expect(find.text('移除星標'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ProjectMoreTab),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      expect(fixture.starReads, 1);
      expect(fixture.starWrites, 1);
    },
  );

  testWidgets(
    'late old API read cannot replace the current project star state',
    (tester) async {
      final old = _StarFixture(starred: true)..readGate = Completer<void>();
      final current = _StarFixture(starred: false);
      addTearDown(old.api.close);
      addTearDown(current.api.close);
      await tester.pumpWidget(_page(old));
      await tester.pump();
      await tester.pumpWidget(_page(current));
      await settleNetworkWidgets(tester);
      expect(find.byTooltip('加入星標'), findsOneWidget);
      old.readGate!.complete();
      await settleNetworkWidgets(tester);
      expect(find.byTooltip('加入星標'), findsOneWidget);
      expect(find.byTooltip('移除星標'), findsNothing);
    },
  );

  testWidgets(
    'late old API write cannot update or announce the replacement project',
    (tester) async {
      final old = _StarFixture()
        ..writeGate = Completer<void>()
        ..starWriteFailure = 503;
      final current = _StarFixture();
      addTearDown(old.api.close);
      addTearDown(current.api.close);
      var oldRefreshes = 0;
      await tester.pumpWidget(
        _page(old, onStarChanged: () async => oldRefreshes++),
      );
      await settleNetworkWidgets(tester);
      await tester.tap(find.byTooltip('加入星標'));
      await pumpUntil(
        tester,
        () => old.starWrites == 1,
        description: 'old star write starts',
      );

      await tester.pumpWidget(_page(current));
      await settleNetworkWidgets(tester);
      old.writeGate!.complete();
      await settleNetworkWidgets(tester);
      expect(oldRefreshes, 0);
      expect(find.byTooltip('加入星標'), findsOneWidget);
      expect(find.text('已加入星標'), findsNothing);
    },
  );

  testWidgets('session generation invalidation fences a pending star read', (
    tester,
  ) async {
    final fixture = _StarFixture()..readGate = Completer<void>();
    final session = SessionController(MemoryAccountStore())
      ..active = fixture.account
      ..api = fixture.api
      ..generation = 1;
    addTearDown(session.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _page(fixture),
      ),
    );
    await pumpUntil(
      tester,
      () => fixture.starReads == 1,
      description: 'pending session-owned star read',
    );
    await session.endSession();
    await tester.pump();
    fixture.readGate!.complete();
    await tester.pumpAndSettle();
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('project-header-star')),
    );
    expect(button.onPressed, isNull);
    expect(find.byTooltip('加入星標'), findsNothing);
    expect(find.byTooltip('移除星標'), findsNothing);
  });

  testWidgets('project header actions fit a 320dp phone at double text', (
    tester,
  ) async {
    final fixture = _StarFixture();
    addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      workspaceHost(
        ProjectPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
        ),
        scale: 2,
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.byKey(const ValueKey('project-header-star')), findsOneWidget);
    expect(find.byTooltip('分享連結'), findsOneWidget);
    expect(find.byTooltip('更多動作'), findsOneWidget);
    final appBar = find.byType(AppBar);
    final title = find.descendant(
      of: appBar,
      matching: find.text(fixture.project.name),
    );
    final path = find.descendant(
      of: appBar,
      matching: find.text(fixture.project.path),
    );
    expect(title, findsOneWidget);
    expect(path, findsOneWidget);
    final appBarRect = tester.getRect(appBar);
    for (final target in [
      title,
      path,
      find.byKey(const ValueKey('project-header-star')),
      find.byTooltip('分享連結'),
      find.byTooltip('更多動作'),
    ]) {
      final rect = tester.getRect(target);
      expect(rect.left, greaterThanOrEqualTo(appBarRect.left));
      expect(rect.top, greaterThanOrEqualTo(appBarRect.top));
      expect(rect.right, lessThanOrEqualTo(appBarRect.right));
      expect(rect.bottom, lessThanOrEqualTo(appBarRect.bottom));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'copy project ID writes literal decimal ID to platform clipboard and shows feedback',
    (tester) async {
      final fixture = _StarFixture();
      addTearDown(fixture.api.close);
      final clipboardWrites = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            final args = methodCall.arguments as Map<dynamic, dynamic>;
            clipboardWrites.add(args['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(_page(fixture));
      await settleNetworkWidgets(tester);

      // Tap overflow menu
      await tester.tap(find.byTooltip('更多動作'));
      await tester.pumpAndSettle();

      // Check available menu action
      final copyAction = find.text('複製專案 ID：${fixture.project.id}');
      final openWebAction = find.byKey(
        const ValueKey('project-header-action-open-web'),
      );
      expect(copyAction, findsOneWidget);
      expect(openWebAction, findsOneWidget);

      // Tap copy action
      await tester.tap(copyAction);
      await tester.pumpAndSettle();

      // Verify literal decimal ID only
      expect(clipboardWrites, ['${fixture.project.id}']);
      expect(clipboardWrites.single, '42');
      expect(find.text('已複製專案 ID：42'), findsOneWidget);
    },
  );

  testWidgets(
    'closed API or session switch prevents copy action and makes zero clipboard writes',
    (tester) async {
      final fixture = _StarFixture();
      addTearDown(fixture.api.close);
      var clipboardWrites = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            clipboardWrites++;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      // Case 1: Closed API disables the menu action
      fixture.api.close();
      await tester.pumpWidget(_page(fixture));
      await settleNetworkWidgets(tester);

      final menuButton = tester.widget<PopupMenuButton<dynamic>>(
        find.byKey(const ValueKey('project-header-actions')),
      );
      expect(menuButton.enabled, isFalse);
      expect(clipboardWrites, 0);

      // Case 2: Project rebind while menu is open produces zero writes and zero launches
      final rebindFixture = _StarFixture();
      addTearDown(rebindFixture.api.close);
      await tester.pumpWidget(_page(rebindFixture));
      await settleNetworkWidgets(tester);

      final fakeLauncher = _FakeUrlLauncher();
      final originalLauncher = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = fakeLauncher;
      addTearDown(() => UrlLauncherPlatform.instance = originalLauncher);

      await tester.tap(find.byTooltip('更多動作'));
      await tester.pumpAndSettle();
      expect(find.text('複製專案 ID：42'), findsOneWidget);

      const replacementProject = Project(
        id: 99,
        name: 'Replacement',
        path: 'group/replacement',
      );
      await tester.pumpWidget(_page(rebindFixture, project: replacementProject));
      await settleNetworkWidgets(tester);

      // Tap the stale copy item: zero writes, no snackbar, never copies fresh owner 99
      await tester.tap(find.text('複製專案 ID：42'));
      await tester.pumpAndSettle();

      expect(clipboardWrites, 0);
      expect(find.text('已複製專案 ID：42'), findsNothing);
      expect(find.text('已複製專案 ID：99'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);

      // Reopen menu for 42, rebind to 99, tap open-web: zero launches
      await tester.pumpWidget(_page(rebindFixture));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byTooltip('更多動作'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_page(rebindFixture, project: replacementProject));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('在 GitLab 開啟'));
      await tester.pumpAndSettle();

      expect(fakeLauncher.launched, isEmpty);

      // Case 3: Session switch before copy invocation produces zero clipboard writes
      final activeFixture = _StarFixture();
      addTearDown(activeFixture.api.close);
      final session = SessionController(MemoryAccountStore())
        ..active = activeFixture.account
        ..api = activeFixture.api
        ..generation = 1;
      addTearDown(session.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: _page(activeFixture),
        ),
      );
      await settleNetworkWidgets(tester);

      await tester.tap(find.byTooltip('更多動作'));
      await tester.pumpAndSettle();
      expect(find.text('複製專案 ID：42'), findsOneWidget);

      // Session switch happens while menu is open
      await session.endSession();
      await tester.pump();

      // Tap copy item after session ended
      await tester.tap(find.text('複製專案 ID：42'));
      await tester.pumpAndSettle();

      expect(clipboardWrites, 0);
      expect(find.text('已複製專案 ID：42'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'held clipboard completion across account, project or generation change discards feedback',
    (tester) async {
      final oldFixture = _StarFixture();
      addTearDown(oldFixture.api.close);

      var clipboardGate = Completer<void>();
      var clipboardWrites = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            clipboardWrites++;
            await clipboardGate.future;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      // Round 1: Project change while clipboard write is held in flight
      await tester.pumpWidget(_page(oldFixture));
      await settleNetworkWidgets(tester);

      await tester.tap(find.byTooltip('更多動作'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('複製專案 ID：42'));
      await tester.pump();
      expect(clipboardWrites, 1);

      // While clipboard write is held in flight, owner changes to new project
      const newProject = Project(
        id: 99,
        name: 'Replacement',
        path: 'group/replacement',
      );
      await tester.pumpWidget(_page(oldFixture, project: newProject));
      await settleNetworkWidgets(tester);

      // Complete the held platform write
      clipboardGate.complete();
      await tester.pumpAndSettle();

      // Must not display feedback on the new owner
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('已複製專案 ID：42'), findsNothing);
      expect(find.text('已複製專案 ID：99'), findsNothing);

      // Round 2: Session generation invalidation and endSession while held
      final sessionFixture = _StarFixture();
      addTearDown(sessionFixture.api.close);
      final session = SessionController(MemoryAccountStore())
        ..active = sessionFixture.account
        ..api = sessionFixture.api
        ..generation = 1;
      addTearDown(session.dispose);

      clipboardGate = Completer<void>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: _page(sessionFixture),
        ),
      );
      await settleNetworkWidgets(tester);

      await tester.tap(find.byTooltip('更多動作'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('複製專案 ID：42'));
      await tester.pump();
      expect(clipboardWrites, 2);

      // While clipboard write is held, session ends (generation invalidation & session reset)
      await session.endSession();
      await tester.pump();

      // Complete the held platform write
      clipboardGate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('已複製專案 ID：42'), findsNothing);

      // Round 3: Replacement account and API while held
      final accountFixture = _StarFixture();
      final replacementFixture = _StarFixture();
      addTearDown(accountFixture.api.close);
      addTearDown(replacementFixture.api.close);
      session
        ..active = accountFixture.account
        ..api = accountFixture.api
        ..generation = 2;

      clipboardGate = Completer<void>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: _page(accountFixture),
        ),
      );
      await settleNetworkWidgets(tester);

      await tester.tap(find.byTooltip('更多動作'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('複製專案 ID：42'));
      await tester.pump();
      expect(clipboardWrites, 3);

      // Switch to replacement account and API while held
      session
        ..active = replacementFixture.account
        ..api = replacementFixture.api
        ..generation = 3;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: _page(replacementFixture),
        ),
      );
      await settleNetworkWidgets(tester);

      clipboardGate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('已複製專案 ID：42'), findsNothing);
    },
  );

  testWidgets(
    'real clipboard failure gives helpful retry feedback for current owner but stays silent if stale',
    (tester) async {
      final fixture = _StarFixture();
      addTearDown(fixture.api.close);

      var failImmediately = true;
      var errorGate = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            if (failImmediately) {
              throw PlatformException(code: 'FAILED', message: 'clipboard busy');
            }
            await errorGate.future;
            throw PlatformException(code: 'FAILED', message: 'late clipboard failure');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      // Part 1: Current owner failure shows helpful retry feedback
      await tester.pumpWidget(_page(fixture));
      await settleNetworkWidgets(tester);

      await tester.tap(find.byTooltip('更多動作'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('複製專案 ID：42'));
      await tester.pumpAndSettle();

      expect(find.text('無法複製專案 ID，請重試。'), findsOneWidget);

      // Dismiss current snackbar before part 2 via proper existing disposal
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // Part 2: Late error after project change stays completely silent
      failImmediately = false;

      await tester.pumpWidget(_page(fixture));
      await settleNetworkWidgets(tester);

      await tester.tap(find.byTooltip('更多動作'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('複製專案 ID：42'));
      await tester.pump();

      // Switch owner while error is pending
      const replacementProject = Project(
        id: 99,
        name: 'Replacement',
        path: 'group/replacement',
      );
      await tester.pumpWidget(_page(fixture, project: replacementProject));
      await settleNetworkWidgets(tester);

      // Complete the held error
      errorGate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('無法複製專案 ID，請重試。'), findsNothing);
      expect(tester.takeException(), isNull);

      // Part 3: Late error after session end stays completely silent
      final sessionFixture = _StarFixture();
      addTearDown(sessionFixture.api.close);
      final session = SessionController(MemoryAccountStore())
        ..active = sessionFixture.account
        ..api = sessionFixture.api
        ..generation = 1;
      addTearDown(session.dispose);

      errorGate = Completer<void>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(session)],
          child: _page(sessionFixture),
        ),
      );
      await settleNetworkWidgets(tester);

      await tester.tap(find.byTooltip('更多動作'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('複製專案 ID：42'));
      await tester.pump();

      // End session while error is in flight
      await session.endSession();
      await tester.pump();

      errorGate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('無法複製專案 ID，請重試。'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'project header actions at 320dp double text retain star and share with open and copy reachable',
    (tester) async {
      final fixture = _StarFixture();
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final clipboardWrites = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            final args = methodCall.arguments as Map<dynamic, dynamic>;
            clipboardWrites.add(args['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final fakeLauncher = _FakeUrlLauncher();
      final originalLauncher = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = fakeLauncher;
      addTearDown(() => UrlLauncherPlatform.instance = originalLauncher);

      await tester.pumpWidget(
        workspaceHost(
          ProjectPage(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
          ),
          scale: 2,
        ),
      );
      await settleNetworkWidgets(tester);

      // Direct star and share retained
      final starFinder = find.byKey(const ValueKey('project-header-star'));
      final shareFinder = find.byTooltip('分享連結');
      final overflowFinder = find.byKey(const ValueKey('project-header-actions'));

      expect(starFinder, findsOneWidget);
      expect(shareFinder, findsOneWidget);
      expect(overflowFinder, findsOneWidget);
      expect(find.byTooltip('更多動作'), findsOneWidget);

      // Measure each overflow/star/share button min 48dp and inbounds [0, 320]
      for (final btn in [starFinder, shareFinder, overflowFinder]) {
        expect(
          tester.getSize(btn).shortestSide,
          greaterThanOrEqualTo(kMinInteractiveDimension),
        );
        final rect = tester.getRect(btn);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
      }

      // Open menu at 320dp 2x
      await tester.tap(overflowFinder);
      await tester.pumpAndSettle();

      // Menu items hitTestable, min 48dp height, inbounds [0, 320]
      for (final k in [
        'project-header-action-copy-id',
        'project-header-action-open-web',
      ]) {
        final f = find.byKey(ValueKey(k));
        expect(f.hitTestable(), findsOneWidget);
        final r = tester.getRect(f);
        expect(r.height, greaterThanOrEqualTo(kMinInteractiveDimension));
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(320));
      }
      expect(find.text('複製專案 ID：42'), findsOneWidget);
      expect(find.text('在 GitLab 開啟'), findsOneWidget);

      // Actually tap copy action via meaningful pointer tap
      await tester.tap(
        find.byKey(const ValueKey('project-header-action-copy-id')),
      );
      await tester.pumpAndSettle();

      expect(clipboardWrites, ['42']);
      expect(find.text('已複製專案 ID：42'), findsOneWidget);

      // Reopen menu and actually tap open web action
      await tester.tap(overflowFinder);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('project-header-action-open-web')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('project-header-action-open-web')),
      );
      await tester.pumpAndSettle();

      final canonicalUrl =
          fixture.account.instance.projectWeb(fixture.project.path).toString();
      expect(fakeLauncher.launched, [canonicalUrl]);
      expect(tester.takeException(), isNull);
    },
  );
}
