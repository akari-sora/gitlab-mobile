import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/features/workspace/project_overview.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/shell_nav.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;

/// Where the project is open: pushed as its own route (Home, links, recent
/// projects) or as the detail of the 探索 list-detail inside the shell.
enum _Host { pushed, shell }

Future<BuildInfo> _buildInfo() async => const BuildInfo(
  version: '0.6.0',
  buildNumber: '6',
  commit: 'overview_back_test',
);

void _viewport(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<SessionController?> _openProject(
  WidgetTester tester,
  _Host host,
  WorkspaceFixture fixture, {
  int? initialTab,
}) async {
  addTearDown(fixture.api.close);
  if (host == _Host.pushed) {
    await tester.pumpWidget(workspaceHost(const Scaffold(body: Text('below'))));
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(
            MaterialPageRoute<void>(
              builder: (_) => ProjectPage(
                account: fixture.account,
                api: fixture.api,
                project: fixture.project,
                initialTab: initialTab,
              ),
            ),
          ),
    );
    await settleNetworkWidgets(tester);
    return null;
  }
  assert(initialTab == null, '探索 always lands on the overview');
  FlutterSecureStorage.setMockInitialValues({});
  final appearance = AppearanceController(MemoryAppearanceStore());
  final shortcuts = LauncherShortcuts(
    FakeAppShortcutHost(),
    MemoryRecentProjectStore(),
  );
  final session = controllerFor(MemoryAccountStore(), fixture.adapter);
  addTearDown(appearance.dispose);
  addTearDown(shortcuts.dispose);
  addTearDown(session.dispose);
  await tester.runAsync(() async {
    await session.initialize();
    await session.connect('https://example.com/gitlab', 'synthetic-test-token');
  });
  await tester.pumpWidget(
    AuthenticatedApp(
      session: session,
      appearance: appearance,
      shortcuts: shortcuts,
      buildInfoLoader: _buildInfo,
    ),
  );
  await settleNetworkWidgets(tester);
  await openExplore(tester);
  await tester.tap(find.text('Mobile Workspace'));
  await settleNetworkWidgets(tester);
  return session;
}

/// Settles the session-attached read-cache disk coordinator so its bounded
/// invalidation wait cancels its FakeAsync timer before teardown. The pushed
/// host never attaches a disk backend, so a null session is a no-op.
Future<void> _drainDiskCoordinator(
  WidgetTester tester,
  SessionController? session,
) async {
  if (session == null) return;
  await pumpUntilComplete(tester, session.readCache.quiesced);
}

/// The project's own tab bar, not the one inside an open issue.
Finder get _projectTabs => find.ancestor(
  of: find.widgetWithText(Tab, '檔案'),
  matching: find.byType(TabBar),
);

void _expectOverview() {
  expect(find.byType(ProjectPage), findsOneWidget);
  expect(find.byType(ProjectOverview), findsOneWidget);
  expect(_projectTabs, findsNothing);
}

void _expectSection(WidgetTester tester, int index) {
  expect(
    find.byType(ProjectOverview),
    findsNothing,
    reason: 'the overview must not open as well',
  );
  expect(_projectTabs, findsOneWidget);
  expect(tester.widget<TabBar>(_projectTabs).controller!.index, index);
}

/// What back from the overview did before sections went back to it.
void _expectLeft(WidgetTester tester, _Host host, double width) {
  expect(find.byType(ProjectPage), findsNothing);
  if (host == _Host.pushed) {
    expect(find.text('below'), findsOneWidget);
  } else if (width < 600) {
    expect(
      find.byKey(const Key('projectSearch')),
      findsOneWidget,
      reason: 'the compact project closes',
    );
  } else {
    // A two-pane project stays selected; back on 探索 goes to 首頁.
    expect(find.text('我的工作'), findsOneWidget);
  }
}

Future<void> _systemBack(WidgetTester tester) async {
  expect(await tester.binding.handlePopRoute(), isTrue);
  await settleNetworkWidgets(tester);
}

void main() {
  for (final host in _Host.values) {
    for (final width in const [412.0, 1200.0]) {
      final label = '${host.name} ${width.toInt()} dp';

      testWidgets(
        '$label: system back from a section returns to the overview, then leaves',
        (tester) async {
          _viewport(tester, width);
          final fixture = WorkspaceFixture();
          final session = await _openProject(tester, host, fixture);
          _expectOverview();

          await openProjectTab(tester, '議題');
          _expectSection(tester, 1);
          await _systemBack(tester);
          _expectOverview();

          await openProjectTab(tester, 'CI');
          _expectSection(tester, 3);
          await _systemBack(tester);
          _expectOverview();

          await _systemBack(tester);
          _expectLeft(tester, host, width);
          expect(tester.takeException(), isNull);
          expect(fixture.unhandled, isEmpty);
          await _drainDiskCoordinator(tester, session);
        },
      );

      testWidgets('$label: the section app bar back returns to the overview', (
        tester,
      ) async {
        _viewport(tester, width);
        final fixture = WorkspaceFixture();
        final session = await _openProject(tester, host, fixture);

        await openProjectTab(tester, '議題');
        _expectSection(tester, 1);
        final back = find.descendant(
          of: find.byType(ProjectPage),
          matching: find.byType(BackButton),
        );
        expect(back, findsOneWidget);
        await tester.tap(back);
        await settleNetworkWidgets(tester);
        _expectOverview();

        await _systemBack(tester);
        _expectLeft(tester, host, width);
        expect(tester.takeException(), isNull);
        await _drainDiskCoordinator(tester, session);
      });

      testWidgets(
        '$label: a folder goes up before the files section returns to the overview',
        (tester) async {
          _viewport(tester, width);
          final fixture = WorkspaceFixture();
          final session = await _openProject(tester, host, fixture);

          await openProjectTab(tester, '檔案');
          _expectSection(tester, 0);
          expect(find.byType(RepositoryTab), findsOneWidget);
          await tester.tap(find.text('lib'));
          await settleNetworkWidgets(tester);
          expect(
            find.text('根目錄'),
            findsOneWidget,
            reason: 'inside the lib folder',
          );

          await _systemBack(tester);
          expect(
            find.text('根目錄'),
            findsNothing,
            reason: 'back went one folder up',
          );
          expect(
            find.text('lib'),
            findsOneWidget,
            reason: 'the root lists lib without a breadcrumb',
          );
          expect(
            find.byType(ProjectPage),
            findsOneWidget,
            reason: 'the project stays open',
          );
          _expectSection(tester, 0);

          await _systemBack(tester);
          _expectOverview();
          expect(tester.takeException(), isNull);
          expect(fixture.unhandled, isEmpty);
          await _drainDiskCoordinator(tester, session);
        },
      );

      testWidgets(
        '$label: an open issue closes before the issues section returns to the overview',
        (tester) async {
          _viewport(tester, width);
          final fixture = WorkspaceFixture();
          fixture.issues[7] = fixture.issue(7, 'Back chain issue');
          final session = await _openProject(tester, host, fixture);

          await openProjectTab(tester, '議題');
          await tester.tap(find.text('Back chain issue'));
          await settleNetworkWidgets(tester);
          expect(find.byType(WorkItemPage), findsOneWidget);
          if (width < 600) {
            expect(
              _projectTabs,
              findsNothing,
              reason: 'the compact issue owns the screen',
            );
          }

          await _systemBack(tester);
          expect(
            find.byType(WorkItemPage),
            findsNothing,
            reason: 'back closed the issue',
          );
          expect(
            find.text('Back chain issue'),
            findsOneWidget,
            reason: 'the issue list is back',
          );
          if (width >= 600) expect(find.text('請選擇議題'), findsOneWidget);
          _expectSection(tester, 1);

          await _systemBack(tester);
          _expectOverview();
          expect(tester.takeException(), isNull);
          expect(fixture.unhandled, isEmpty);
          await _drainDiskCoordinator(tester, session);
        },
      );
    }
  }

  for (final width in const [412.0, 1200.0]) {
    testWidgets(
      'pushed ${width.toInt()} dp: a section opened directly leaves on back',
      (tester) async {
        _viewport(tester, width);
        final fixture = WorkspaceFixture();
        await _openProject(tester, _Host.pushed, fixture, initialTab: 1);
        _expectSection(tester, 1);
        await _systemBack(tester);
        _expectLeft(tester, _Host.pushed, width);

        await _openProject(
          tester,
          _Host.pushed,
          WorkspaceFixture(),
          initialTab: 0,
        );
        _expectSection(tester, 0);
        await tester.tap(
          find.descendant(
            of: find.byType(ProjectPage),
            matching: find.byType(BackButton),
          ),
        );
        await settleNetworkWidgets(tester);
        _expectLeft(tester, _Host.pushed, width);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
