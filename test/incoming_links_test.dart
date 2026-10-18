import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/incoming_links.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;

final class _Source implements IncomingLinkSource {
  final controller = StreamController<Uri>.broadcast();
  @override
  Stream<Uri> get links => controller.stream;
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'keeps the newest https link once and ignores everything else',
    () async {
      final source = _Source();
      final links = IncomingLinks(source);
      var changes = 0;
      links.addListener(() => changes++);
      links.start();
      links.start();

      for (final ignored in [
        'io.gitlabmobile.app://oauth/callback?code=x',
        'http://gitlab.com/group/project',
        'https://user:secret@gitlab.com/group/project',
        'https://gitlab.com/${'a' * incomingLinkMaxLength}',
      ]) {
        source.controller.add(Uri.parse(ignored));
      }
      source.controller.add(Uri.parse('https://gitlab.com/group/first'));
      source.controller.add(
        Uri.parse('https://gitlab.com/group/project/-/issues/3'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(changes, 2);
      expect(
        links.take(),
        Uri.parse('https://gitlab.com/group/project/-/issues/3'),
      );
      expect(links.take(), isNull);

      links.dispose();
      source.controller.add(Uri.parse('https://gitlab.com/group/late'));
      await Future<void>.delayed(Duration.zero);
      expect(links.pending, isNull);
      await source.controller.close();
    },
  );

  test(
    'without a platform way in nothing arrives and settings stay hidden',
    () async {
      final links = IncomingLinks(null)..start();
      addTearDown(links.dispose);
      expect(links.canOpenSettings, isFalse);
      expect(await links.openSettings(), isFalse);
      final failing = IncomingLinks(
        null,
        openSettings: () async => throw StateError('no activity'),
      );
      addTearDown(failing.dispose);
      expect(failing.canOpenSettings, isTrue);
      expect(await failing.openSettings(), isFalse);
    },
  );

  testWidgets(
    'Explore resolves each handed-over link once through the locator',
    (tester) async {
      final adapter = FakeAdapter((_) => jsonResponse([]));
      final api = testApi(adapter);
      final session = SessionController(MemoryAccountStore())
        ..active = Account(
          instance: api.instance,
          user: const GitLabUser(id: 7, username: 'first', name: 'First'),
          token: 'synthetic-first',
        )
        ..api = api;
      addTearDown(api.close);
      addTearDown(session.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryRecentProjectStore();
      int lookups() => adapter.requests
          .where((r) => r.uri.pathSegments.last == 'team/client')
          .length;
      Widget page((int, String)? link) => workspaceHost(
        ProjectsPage(session: session, recentStore: store, openLink: link),
      );

      await tester.pumpWidget(
        page((1, 'https://example.com/gitlab/team/client')),
      );
      await pumpUntil(
        tester,
        () => lookups() == 1,
        description: 'first link looked up',
      );
      await settleNetworkWidgets(tester);

      await tester.pumpWidget(
        page((1, 'https://example.com/gitlab/team/client')),
      );
      await settleNetworkWidgets(tester);
      expect(lookups(), 1, reason: 'the same link number is not opened twice');

      ScaffoldMessenger.of(
        tester.element(find.byType(ProjectsPage)),
      ).clearSnackBars();
      await tester.pumpWidget(page((2, 'https://other.example/team/client')));
      await settleNetworkWidgets(tester);
      expect(lookups(), 1);
      expect(
        find.text('這個連結屬於 other.example，目前的帳號在 example.com。'),
        findsOneWidget,
      );

      await tester.pumpWidget(
        page((3, 'https://example.com/gitlab/team/client')),
      );
      await pumpUntil(
        tester,
        () => lookups() == 2,
        description: 'next link looked up',
      );
      await settleNetworkWidgets(tester);
    },
  );

  testWidgets(
    'a link that arrived before sign-in opens in Explore once the shell is up',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = WorkspaceFixture();
      final session = controllerFor(MemoryAccountStore(), fixture.adapter);
      await tester.runAsync(() async {
        await session.initialize();
        await session.connect(
          'https://example.com/gitlab',
          'synthetic-test-token',
        );
      });
      final shortcuts = LauncherShortcuts(
        FakeAppShortcutHost(),
        MemoryRecentProjectStore(),
      );
      final appearance = AppearanceController(MemoryAppearanceStore());
      var settingsOpened = 0;
      final incoming = IncomingLinks(
        null,
        openSettings: () async {
          settingsOpened++;
          return true;
        },
      );
      addTearDown(() {
        incoming.dispose();
        appearance.dispose();
        shortcuts.dispose();
        session.dispose();
        fixture.api.close();
      });
      incoming.offer(
        Uri.parse(
          'https://example.com/gitlab/studio/mobile-workspace/-/issues/1',
        ),
      );
      int lookups() => fixture.adapter.requests
          .where((r) => r.uri.pathSegments.contains('studio/mobile-workspace'))
          .length;

      await tester.pumpWidget(
        AuthenticatedApp(
          session: session,
          appearance: appearance,
          shortcuts: shortcuts,
          incoming: incoming,
        ),
      );
      await pumpUntil(
        tester,
        () => lookups() > 0,
        description: 'linked project looked up',
      );
      await settleNetworkWidgets(tester);
      expect(incoming.pending, isNull);
      final explore = tester.widget<NavigationBar>(
        find.byType(NavigationBar, skipOffstage: false),
      );
      expect(explore.selectedIndex, 2, reason: 'the link opens from 探索');

      // A link that arrives while the shell is up opens the same way.
      final before = lookups();
      incoming.offer(
        Uri.parse('https://example.com/gitlab/studio/mobile-workspace'),
      );
      await pumpUntil(
        tester,
        () => lookups() > before,
        description: 'second link looked up',
      );
      await settleNetworkWidgets(tester);
      expect(incoming.pending, isNull);

      final navigator = Navigator.of(
        tester.element(find.byType(NavigationBar, skipOffstage: false)),
      );
      while (navigator.canPop()) {
        navigator.pop();
        await settleNetworkWidgets(tester);
      }
      ScaffoldMessenger.of(
        tester.element(find.byType(NavigationBar)),
      ).clearSnackBars();
      await tester.tap(find.text('我的'));
      await settleNetworkWidgets(tester);
      await tester.scrollUntilVisible(find.text('用 App 開啟 GitLab.com 連結'), 200);
      await tester.tap(find.text('用 App 開啟 GitLab.com 連結'));
      await settleNetworkWidgets(tester);
      expect(settingsOpened, 1);
    },
  );
}
