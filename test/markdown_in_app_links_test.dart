import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

const _issueUrl =
    'https://example.com/gitlab/studio/mobile-workspace/-/issues/1';
const _branchBlobUrl =
    'https://example.com/gitlab/studio/mobile-workspace/-/blob/main/README.md';
const _otherHostUrl =
    'https://other.example/gitlab/studio/mobile-workspace/-/issues/1';

const _markdown =
    '[Issue one]($_issueUrl)\n\n'
    '[Branch file]($_branchBlobUrl)\n\n'
    '[Other host]($_otherHostUrl)\n';

class _FakeUrlLauncher extends UrlLauncherPlatform
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

Future<BuildInfo> _buildInfo() async =>
    const BuildInfo(version: '0.6.0', buildNumber: '6', commit: 'links');

void main() {
  late _FakeUrlLauncher launcher;
  late UrlLauncherPlatform originalLauncher;
  late AppearanceController appearance;
  late LauncherShortcuts shortcuts;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    launcher = _FakeUrlLauncher();
    originalLauncher = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    appearance = AppearanceController(MemoryAppearanceStore());
    shortcuts = LauncherShortcuts(
      FakeAppShortcutHost(),
      MemoryRecentProjectStore(),
    );
  });

  tearDown(() {
    UrlLauncherPlatform.instance = originalLauncher;
    appearance.dispose();
    shortcuts.dispose();
  });

  /// Signs in against the synthetic workspace, which also answers the
  /// project lookup by path that a pasted link needs.
  Future<(SessionController, List<String>)> pumpApp(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = WorkspaceFixture();
    fixture.issues[1] = fixture.issue(1, 'Linked issue');
    final pathLookups = <String>[];
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/projects/studio%2Fmobile-workspace')) {
        pathLookups.add(request.uri.path);
        return jsonResponse(fixture.projectRecord);
      }
      return fixture.respond(request);
    });
    final session = controllerFor(MemoryAccountStore(), adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
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
    return (session, pathLookups);
  }

  /// A pushed route, like every project, review and detail page.
  Future<void> pushMarkdown(WidgetTester tester) async {
    final navigator = Navigator.of(tester.element(find.byType(NavigationBar)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('說明')),
            body: const MarkdownView(_markdown),
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.text('Issue one'), findsOneWidget);
  }

  testWidgets(
    'a same-instance issue link in Markdown pushes the in-app issue page',
    (tester) async {
      final (_, pathLookups) = await pumpApp(tester);
      await pushMarkdown(tester);

      await tester.tap(find.text('Issue one'));
      await settleNetworkWidgets(tester);

      final page = tester.widget<WorkItemPage>(find.byType(WorkItemPage));
      expect(page.resource, 'issues');
      expect(page.iid, 1);
      expect(page.project.id, 42);
      expect(
        pathLookups,
        hasLength(1),
        reason: 'the project is resolved by its path once',
      );
      expect(launcher.launched, isEmpty, reason: 'the link stays in the app');
    },
  );

  testWidgets(
    'a branch blob link and an other-host link still open the browser',
    (tester) async {
      final (_, pathLookups) = await pumpApp(tester);
      await pushMarkdown(tester);

      await tester.tap(find.text('Branch file'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('Other host'));
      await settleNetworkWidgets(tester);

      expect(launcher.launched, [_branchBlobUrl, _otherHostUrl]);
      expect(find.byType(RepositoryFilePage), findsNothing);
      expect(find.byType(WorkItemPage), findsNothing);
      expect(
        pathLookups,
        isEmpty,
        reason: 'neither link is resolved through the API',
      );
    },
  );

  testWidgets(
    'a link tapped after the session moved on falls back to the browser',
    (tester) async {
      final (session, pathLookups) = await pumpApp(tester);
      await pushMarkdown(tester);
      final before = session.generation;

      // The account is activated again: a new client and generation replace the
      // ones this tree was built for, while the pushed page is still up.
      await tester.runAsync(
        () => session.connect(
          'https://example.com/gitlab',
          'synthetic-test-token',
        ),
      );
      await settleNetworkWidgets(tester);
      expect(session.generation, greaterThan(before));
      expect(find.text('Issue one'), findsOneWidget);

      await tester.tap(find.text('Issue one'));
      await settleNetworkWidgets(tester);

      expect(launcher.launched, [_issueUrl]);
      expect(find.byType(WorkItemPage), findsNothing);
      expect(pathLookups, isEmpty, reason: 'nothing is read for the new owner');
    },
  );
}
