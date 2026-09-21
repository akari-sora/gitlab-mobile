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
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace;

Widget evidenceHost(Widget page, Brightness brightness) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: appTheme(brightness),
  locale: const Locale('zh', 'TW'), supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: page,
);

void main() {
  var fontsAvailable = false;
  setUpAll(() async {
    final font = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
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
    for (final name in ['login', 'projects', 'repository', 'review']) {
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
        final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
        addTearDown(shortcuts.dispose);
        final Widget screen = switch (name) {
          'login' => evidenceHost(LoginScreen(session: session), brightness),
          // Capture actual production navigation, not just the project body.
          'projects' => AuthenticatedApp(session: session,
            appearance: AppearanceController(MemoryAppearanceStore()), shortcuts: shortcuts),
          'repository' => evidenceHost(ProjectPage(account: fixture.account, api: fixture.api, project: fixture.project), brightness),
          _ => evidenceHost(WorkItemPage(account: fixture.account, api: fixture.api, project: fixture.project,
            resource: 'merge_requests', iid: 12), brightness),
        };
        await tester.pumpWidget(RepaintBoundary(key: key, child: screen));
        await settleWorkspace(tester);
        expect(tester.takeException(), isNull);
        if (name == 'projects') { expect(find.byType(NavigationBar), findsOneWidget); }
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
            'screens': ['login', 'projects with production bottom navigation', 'repository', 'review'],
            'themes': ['light', 'dark'],
          }));
        });
        expect(fixture.unhandled, isEmpty);
        await tester.pumpWidget(const SizedBox()); await tester.pump();
      });
    }
  }
}
