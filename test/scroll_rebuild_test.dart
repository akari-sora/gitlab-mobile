import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/shared/list_detail_scaffold.dart';
import 'package:gitlab_mobile/shared/scroll_chrome.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

/// Counts rebuilds of the elements [target] finds when [body] starts (rows
/// entering the viewport later are first builds and do not count). Uses the
/// framework's debug rebuild hook.
Future<int> _rebuildsOf(Finder target, Future<void> Function() body) async {
  final existing = target.evaluate().toSet();
  expect(existing, isNotEmpty);
  var count = 0;
  final previous = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    if (existing.contains(element)) count++;
  };
  try {
    await body();
  } finally {
    debugOnRebuildDirtyWidget = previous;
  }
  return count;
}

/// The avatar of every project row built so far (not the account avatar in
/// the app bar).
final _rowAvatars = find.descendant(
  of: find.byType(SliverList, skipOffstage: false),
  matching: find.byType(Monogram, skipOffstage: false),
);

void main() {
  testWidgets('hiding the navigation while scrolling 探索 rebuilds no project row', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    FlutterSecureStorage.setMockInitialValues({});
    final appearance = AppearanceController(MemoryAppearanceStore());
    addTearDown(appearance.dispose);
    final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
    addTearDown(shortcuts.dispose);

    final fixture = WorkspaceFixture();
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/api/v4/projects') && request.uri.queryParameters['membership'] == 'true') {
        return jsonResponse([
          for (var i = 1; i <= 40; i++) {
            ...projectJson(100 + i), 'last_activity_at': '2026-09-19T08:30:00Z', 'star_count': i % 3,
          },
        ]);
      }
      return fixture.respond(request);
    });
    final session = controllerFor(MemoryAccountStore(), adapter);
    addTearDown(session.dispose);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-test-token');
    });
    await tester.pumpWidget(AuthenticatedApp(session: session, appearance: appearance, shortcuts: shortcuts,
      buildInfoLoader: () async => const BuildInfo(version: '0.5.0', buildNumber: '5', commit: 'perf')));
    await settleNetworkWidgets(tester);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('探索')));
    await settleNetworkWidgets(tester);
    expect(find.text('Example 101'), findsOneWidget);

    final chrome = find.byType(CollapsingChrome);
    final fullHeight = tester.getSize(chrome).height;
    expect(fullHeight, greaterThan(0));

    final rebuilt = await _rebuildsOf(_rowAvatars, () async {
      final gesture = await tester.startGesture(tester.getCenter(find.text('Example 103')));
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(0, -12));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      // The navigation slides away over 220 ms; pump every frame of it.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    });
    expect(tester.getSize(chrome).height, 0, reason: 'the navigation hid');
    expect(rebuilt, 0, reason: 'only the viewport grew: rows already built must not rebuild per frame');

    final shown = await _rebuildsOf(_rowAvatars, () async {
      final gesture = await tester.startGesture(tester.getCenter(find.byType(CustomScrollView).first));
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(0, 12));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    });
    expect(tester.getSize(chrome).height, fullHeight, reason: 'the navigation came back');
    expect(shown, 0);
    await tester.pumpAndSettle();
  });

  group('ListDetailScaffold', () {
    testWidgets('a height-only change reuses the panes', (tester) async {
      final controller = ListDetailController<String>();
      addTearDown(controller.dispose);
      final height = ValueNotifier(600.0);
      addTearDown(height.dispose);
      var resized = 0;
      final scaffold = ListDetailScaffold<String>(
        controller: controller,
        listBuilder: (context, twoPane, selected) {
          resized++;
          return const Text('list');
        },
        detailBuilder: (context, item, twoPane, onBack) => Text('detail $item'),
        emptyBuilder: (context) => const SizedBox(),
      );
      await tester.pumpWidget(MaterialApp(home: ValueListenableBuilder<double>(valueListenable: height,
        builder: (context, value, child) => Align(alignment: Alignment.topCenter,
          child: SizedBox(width: 400, height: value, child: child)),
        child: scaffold)));
      expect(resized, 1);
      for (final value in [580.0, 540.0, 500.0, 460.0]) {
        height.value = value;
        await tester.pump();
      }
      expect(resized, 1, reason: 'the list builder did not run again for a height change');
      expect(tester.getSize(find.text('list')).height, greaterThan(0));

      controller.select('a');
      await tester.pump();
      expect(find.text('detail a'), findsOneWidget);
      expect(resized, 2, reason: 'a selection change rebuilds the list with the new selection');
      height.value = 600;
      await tester.pump();
      expect(resized, 2);
      controller.clear();
      await tester.pump();
      expect(resized, 3);
    });

    testWidgets('on a phone an opened item slides in and the list slides back', (tester) async {
      final controller = ListDetailController<String>();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(home: SizedBox(width: 400, height: 600, child: ListDetailScaffold<String>(
        controller: controller,
        listBuilder: (context, twoPane, selected) => const Text('list'),
        detailBuilder: (context, item, twoPane, onBack) => Text('detail $item'),
        emptyBuilder: (context) => const SizedBox(),
      ))));
      double dx(String text) => tester.widget<SlideTransition>(find.ancestor(
        of: find.text(text, skipOffstage: false), matching: find.byType(SlideTransition, skipOffstage: false)).first,
      ).position.value.dx;

      controller.select('a');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(dx('detail a'), greaterThan(0), reason: 'the detail enters from the trailing edge');
      await tester.pumpAndSettle();
      expect(dx('detail a'), 0);

      controller.clear();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(dx('list'), lessThan(0), reason: 'the list comes back from the leading edge');
      await tester.pumpAndSettle();
      expect(dx('list'), 0);
    });

    testWidgets('a width change across the breakpoint rebuilds both panes', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = ListDetailController<String>(initial: 'a');
      addTearDown(controller.dispose);
      final width = ValueNotifier(400.0);
      addTearDown(width.dispose);
      final modes = <bool>[];
      final scaffold = ListDetailScaffold<String>(
        controller: controller,
        listBuilder: (context, twoPane, selected) {
          modes.add(twoPane);
          return const Text('list');
        },
        detailBuilder: (context, item, twoPane, onBack) => Text('detail $item ${twoPane ? 'wide' : 'narrow'}'),
        emptyBuilder: (context) => const SizedBox(),
      );
      await tester.pumpWidget(MaterialApp(home: ValueListenableBuilder<double>(valueListenable: width,
        builder: (context, value, child) => Align(alignment: Alignment.topLeft,
          child: SizedBox(width: value, height: 600, child: child)),
        child: scaffold)));
      expect(find.text('detail a narrow'), findsOneWidget);
      width.value = 1200;
      await tester.pump();
      expect(find.text('detail a wide'), findsOneWidget);
      expect(modes.last, isTrue);
      width.value = 1100;
      await tester.pump();
      expect(modes.where((mode) => mode), hasLength(1), reason: 'same mode, only the size changed');
    });
  });
}
