import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';

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

Widget _page(_StarFixture fixture, {Future<void> Function()? onStarChanged}) =>
    workspaceHost(
      ProjectPage(
        key: const ValueKey('same-project-page'),
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        onStarChanged: onStarChanged,
      ),
    );

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
    expect(find.byTooltip('在 GitLab 開啟'), findsOneWidget);
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
      find.byTooltip('在 GitLab 開啟'),
    ]) {
      final rect = tester.getRect(target);
      expect(rect.left, greaterThanOrEqualTo(appBarRect.left));
      expect(rect.top, greaterThanOrEqualTo(appBarRect.top));
      expect(rect.right, lessThanOrEqualTo(appBarRect.right));
      expect(rect.bottom, lessThanOrEqualTo(appBarRect.bottom));
    }
    expect(tester.takeException(), isNull);
  });
}
