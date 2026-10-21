import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/auth/login_screen.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace;
import 'support/shell_nav.dart';

Widget evidenceHost(Widget page, Brightness brightness) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: appTheme(brightness),
  locale: const Locale('zh', 'TW'), supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: page,
);

/// Linux CI default when [GITLAB_MOBILE_TEST_FONT] is unset. An explicit
/// absolute path lets a Mac host satisfy the same required CI glyph checks
/// without bundling a font or hard-coding a platform fallback.
File visualEvidenceCjkFont() {
  final override = Platform.environment['GITLAB_MOBILE_TEST_FONT'];
  if (override == null || override.isEmpty) {
    return File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
  }
  final font = File(override);
  if (!font.isAbsolute) {
    throw StateError('GITLAB_MOBILE_TEST_FONT must be an absolute path');
  }
  return font;
}

/// A release whose links cover each asset action the detail offers.
const _evidenceRelease = <String, dynamic>{
  'tag_name': 'v0.6.0', 'name': 'v0.6.0 預覽版', 'released_at': '2026-10-18T02:00:00Z',
  'description': '### 這一版有什麼\n\n- 首頁、收件匣、探索與我的\n- Release 附件可在 App 內下載',
  'commit': {'id': WorkspaceFixture.sha, 'title': 'feat(ui): GitHub Mobile-style redesign'},
  'assets': {
    'count': 4,
    'links': [
      {'id': 1, 'name': 'gitlab-mobile-debug.apk', 'link_type': 'package',
        'url': 'https://example.com/gitlab/api/v4/projects/42/packages/generic/mobile-preview/0.6.0/gitlab-mobile-debug.apk'},
      {'id': 2, 'name': '更新說明', 'link_type': 'other', 'url': 'https://docs.example.org/changelog'},
    ],
    'sources': [
      {'format': 'zip', 'url': 'https://example.com/gitlab/studio/mobile-workspace/-/archive/v0.6.0/mobile-workspace-v0.6.0.zip'},
      {'format': 'tar.gz', 'url': 'https://example.com/gitlab/studio/mobile-workspace/-/archive/v0.6.0/mobile-workspace-v0.6.0.tar.gz'},
    ],
  },
};

void main() {
  var fontsAvailable = false;
  setUpAll(() async {
    final font = visualEvidenceCjkFont();
    if (!font.existsSync()) {
      if (Platform.environment['CI'] == 'true') { throw StateError('CJK font is required for CI visual evidence'); }
      return;
    }
    final bytes = ByteData.sublistView(await font.readAsBytes());
    // Flutter tests otherwise use Ahem squares for text without an explicit
    // family (such as AppBar's title style). This substitution is test-only.
    for (final family in ['Roboto', 'Ahem', 'sans-serif', 'monospace']) {
      await (FontLoader(family)..addFont(Future.value(bytes))).load();
    }
    // The bundled code font, so branch names and SHAs are not test squares.
    await (FontLoader('JetBrainsMono')
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-NoCalt-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-NoCalt-Medium.ttf'))).load();
    // Icon glyphs are a separate font; loading a text font does not load them.
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    fontsAvailable = true;
  });

  testWidgets('visual evidence has distinguishable Chinese and Material icon glyphs', (tester) async {
    if (!fontsAvailable) { return; }
    Future<Uint8List> raster(Widget child) async {
      final key = GlobalKey();
      await tester.pumpWidget(evidenceHost(Scaffold(body: Center(child: RepaintBoundary(key: key,
        child: SizedBox(width: 48, height: 48, child: Center(child: child))))), Brightness.light));
      await tester.pumpAndSettle();
      final render = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final data = await tester.runAsync(() async {
        final image = await render.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return png!.buffer.asUint8List();
      });
      return data!;
    }
    expect(await raster(const Icon(Icons.search, size: 24)),
      isNot(orderedEquals(await raster(const Icon(Icons.folder, size: 24)))));
    expect(await raster(const Text('專', style: TextStyle(fontSize: 24))),
      isNot(orderedEquals(await raster(const Text('案', style: TextStyle(fontSize: 24))))));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    for (final name in ['login', 'home', 'inbox', 'projects', 'me', 'repository', 'files', 'review', 'release']) {
      testWidgets('capture actual $name ${brightness.name} synthetic-data screen', (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final fixture = WorkspaceFixture();
        final session = controllerFor(MemoryAccountStore(), fixture.adapter);
        addTearDown(session.dispose); addTearDown(fixture.api.close);
        await tester.runAsync(() async {
          await session.initialize();
          if (name != 'login') { await session.connect('https://example.com/gitlab', 'synthetic-test-token'); }
        });
        tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(412, 892);
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final key = GlobalKey();
        if (name == 'release') fixture.releases = [_evidenceRelease];
        final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
        addTearDown(shortcuts.dispose);
        final Widget screen = switch (name) {
          'login' => evidenceHost(LoginScreen(session: session), brightness),
          // Capture actual production navigation, not just the project body.
          'home' || 'inbox' || 'projects' || 'me' => AuthenticatedApp(session: session,
            appearance: AppearanceController(MemoryAppearanceStore()), shortcuts: shortcuts),
          'repository' => evidenceHost(ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project), brightness),
          'files' => evidenceHost(ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project,
            initialTab: 0), brightness),
          'release' => evidenceHost(MetadataPage(account: fixture.account, api: fixture.api, project: fixture.project,
            kind: MetadataKind.releases), brightness),
          _ => evidenceHost(WorkItemPage(account: fixture.account, api: fixture.api, project: fixture.project,
            resource: 'merge_requests', iid: 12), brightness),
        };
        await tester.pumpWidget(RepaintBoundary(key: key, child: screen));
        await settleWorkspace(tester);
        expect(tester.takeException(), isNull);
        final destination = const {'inbox': '收件匣', 'projects': '探索', 'me': '我的'}[name];
        if (destination != null) {
          await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(destination)));
          await settleWorkspace(tester);
          expect(tester.takeException(), isNull);
        }
        if (const ['home', 'inbox', 'projects', 'me'].contains(name)) {
          expect(find.byType(NavigationBar), findsOneWidget);
        }
        if (name == 'release') {
          await tester.tap(find.text('v0.6.0 預覽版'));
          await settleWorkspace(tester);
          expect(find.text('附件'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final directory = Directory('ci-output/screenshots')..createSync(recursive: true);
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          if (bytes == null) { throw StateError('Screenshot encoder returned no data'); }
          await File('${directory.path}/$name-${brightness.name}.png').writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
          await File('${directory.path}/evidence.json').writeAsString(jsonEncode({
            'source_sha': Platform.environment['CI_COMMIT_SHA'],
            'rendering': 'actual Flutter host test; synthetic API data; not a device screenshot',
            'text_fonts': 'host Noto CJK aliases for deterministic text',
            'icon_fonts': 'bundled MaterialIcons',
            'dimensions': [412, 892],
            'screens': ['login', 'home, inbox, explore (projects) and me with production bottom navigation',
              'repository overview', 'repository files', 'review', 'release detail with assets'],
            'themes': ['light', 'dark'],
          }));
        });
        expect(fixture.unhandled, isEmpty);
      });
    }
  }

  group('Adaptive Shell visual evidence and pane geometry across breakpoints', () {
    for (final width in [412.0, 700.0, 840.0, 1200.0]) {
      testWidgets('render adaptive shell at ${width.toInt()} dp, capture PNG, and assert layout geometry', (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final fixture = WorkspaceFixture();
        fixture.issues[42] = fixture.issue(42, 'Adaptive Layout Issue 42');
        final session = controllerFor(MemoryAccountStore(), fixture.adapter);
        final appearance = AppearanceController(MemoryAppearanceStore());
        final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
        addTearDown(session.dispose);
        addTearDown(fixture.api.close);
        addTearDown(shortcuts.dispose);

        await tester.runAsync(() async {
          await session.initialize();
          await session.connect('https://example.com/gitlab', 'synthetic-test-token');
        });

        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: AuthenticatedApp(
              session: session,
              appearance: appearance,
              shortcuts: shortcuts,
            ),
          ),
        );
        await settleWorkspace(tester);
        await openExplore(tester);
        expect(tester.takeException(), isNull);

        if (width < 600) {
          // Compact: bottom NavigationBar
          expect(find.byType(NavigationBar), findsOneWidget);
          expect(find.byType(NavigationRail), findsNothing);
        } else {
          // Medium / Expanded / Large: side NavigationRail
          expect(find.byType(NavigationRail), findsOneWidget);
          expect(find.byType(NavigationBar), findsNothing);
        }

        if (width >= 840) {
          // Enter Project and navigate to Issues tab to verify two-pane layout
          await tester.tap(find.text('Mobile Workspace'));
          await settleWorkspace(tester);
          await tester.tap(find.text('議題'));
          await settleWorkspace(tester);
          await tester.tap(find.text('Adaptive Layout Issue 42'));
          await settleWorkspace(tester);

          // Both list-pane and detail-pane-expanded must be present
          final listPaneFinder = find.byKey(const ValueKey('list-pane'));
          final detailPaneFinder = find.byKey(const ValueKey('detail-pane-expanded'));
          expect(listPaneFinder, findsOneWidget);
          expect(detailPaneFinder, findsOneWidget);

          // Pane width assertions
          final listPaneSize = tester.getSize(listPaneFinder);
          final detailPaneSize = tester.getSize(detailPaneFinder);
          expect(listPaneSize.width, equals(380.0));

          if (width == 840) {
            // 840 - 81 (rail) - 380 (list) - 1 (divider) = 378.0
            expect(detailPaneSize.width, equals(378.0));
          } else if (width == 1200) {
            // 1200 - 81 (rail) - 380 (list) - 1 (divider) = 738.0
            expect(detailPaneSize.width, equals(738.0));
          }

          // Spatial non-overlapping geometry assertion
          final listCardFinder = find.descendant(
            of: find.byType(Card),
            matching: find.text('Adaptive Layout Issue 42'),
          ).first;
          final detailOverviewFinder = find.text('Overview');

          expect(listCardFinder, findsOneWidget);
          expect(detailOverviewFinder, findsOneWidget);

          final listCardBox = tester.getRect(listCardFinder);
          final detailOverviewBox = tester.getRect(detailOverviewFinder);
          expect(
            listCardBox.right,
            lessThan(detailOverviewBox.left),
            reason: 'List card must be strictly to the left of detail overview pane',
          );

          // Both panes are interactive and hit-testable
          expect(listCardFinder.hitTestable(), findsOneWidget);
          expect(detailOverviewFinder.hitTestable(), findsOneWidget);
        }

        // Capture screenshot artifact
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final directory = Directory('ci-output/screenshots')..createSync(recursive: true);
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          if (bytes == null) {
            throw StateError('Screenshot encoder returned no data');
          }
          await File('${directory.path}/adaptive-shell-${width.toInt()}.png')
              .writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });

        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }
  });
}

