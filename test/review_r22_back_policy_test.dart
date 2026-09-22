// Review probes for GitLab Mobile MR !17.
// Reviewed source: 8ae63487a088283d47ab9f42c0bf185385f998e6.
// NOT_RUN by the reviewer: the review environment has no Flutter SDK.
// Copy to test/review_r22_back_policy_test.dart in the repository, then run:
//   fvm flutter test --no-pub test/review_r22_back_policy_test.dart
// These tests assert desired behavior. They are not records of an executed test.

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/shared/list_detail_scaffold.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

const _rootPopKey = ValueKey<String>('review-root-pop-scope');

void _setViewport(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
}

// The dispatcher is intentionally owned by the parent, like the real Shell.
// The pane is a stable child: resize must invalidate back policy without relying
// on unrelated network completions, tab changes, or controller.select() calls.
Widget _probeHost(
  ListDetailController<int> controller,
  DetailBackDispatcher dispatcher, {
  ValueNotifier<bool>? active,
}) {
  final pane = ListDetailScaffold<int>(
    controller: controller,
    listBuilder: (_, twoPane, selected) => const Center(child: Text('list')),
    detailBuilder: (_, item, twoPane, onBack) =>
        Center(child: Text('detail-$item')),
    emptyBuilder: (_) => const Center(child: Text('empty')),
  );
  final scopedPane = active == null
      ? pane
      : ValueListenableBuilder<bool>(
          valueListenable: active,
          child: pane,
          builder: (_, isActive, child) =>
              TabActiveScope(isActive: isActive, child: child!),
        );
  return MaterialApp(
    home: DetailBackScope(
      dispatcher: dispatcher,
      depth: 0,
      child: ListenableBuilder(
        listenable: dispatcher,
        child: scopedPane,
        builder: (_, child) => PopScope<Object?>(
          key: _rootPopKey,
          canPop: !dispatcher.canHandleBack,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) dispatcher.handleBack();
          },
          child: child!,
        ),
      ),
    ),
  );
}

bool _publishedCanPop(WidgetTester tester) =>
    tester.widget<PopScope<Object?>>(find.byKey(_rootPopKey)).canPop;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('review: external back policy updates expanded -> compact', (
    tester,
  ) async {
    final controller = ListDetailController<int>();
    final dispatcher = DetailBackDispatcher();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      dispatcher.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    _setViewport(tester, 1000);
    await tester.pumpWidget(_probeHost(controller, dispatcher));
    await tester.pumpAndSettle();
    controller.select(42);
    await tester.pumpAndSettle();
    expect(dispatcher.canHandleBack, isFalse);
    expect(_publishedCanPop(tester), isTrue);

    _setViewport(tester, 412);
    await tester.pumpAndSettle();
    expect(controller.selected, 42);
    expect(dispatcher.canHandleBack, isTrue);
    expect(
      _publishedCanPop(tester),
      isFalse,
      reason: 'Rendered compact detail must publish a matching back veto.',
    );
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(controller.selected, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('review: external back policy updates compact -> expanded', (
    tester,
  ) async {
    final controller = ListDetailController<int>();
    final dispatcher = DetailBackDispatcher();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      dispatcher.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    _setViewport(tester, 412);
    await tester.pumpWidget(_probeHost(controller, dispatcher));
    await tester.pumpAndSettle();
    controller.select(42);
    await tester.pumpAndSettle();
    expect(dispatcher.canHandleBack, isTrue);
    expect(_publishedCanPop(tester), isFalse);

    _setViewport(tester, 1000);
    await tester.pumpAndSettle();
    expect(controller.selected, 42);
    expect(dispatcher.canHandleBack, isFalse);
    expect(
      _publishedCanPop(tester),
      isTrue,
      reason: 'Back policy must not retain the previous compact-mode veto.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('review: inherited activity alone invalidates back policy', (
    tester,
  ) async {
    final controller = ListDetailController<int>();
    final dispatcher = DetailBackDispatcher();
    final active = ValueNotifier<bool>(true);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      dispatcher.dispose();
      active.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    _setViewport(tester, 412);
    await tester.pumpWidget(_probeHost(controller, dispatcher, active: active));
    await tester.pumpAndSettle();
    controller.select(42);
    await tester.pumpAndSettle();
    expect(dispatcher.canHandleBack, isTrue);
    expect(_publishedCanPop(tester), isFalse);

    active.value = false;
    await tester.pumpAndSettle();
    expect(controller.selected, 42);
    expect(dispatcher.canHandleBack, isFalse);
    expect(
      _publishedCanPop(tester),
      isTrue,
      reason: 'An inactive pane must also release the published route veto.',
    );

    active.value = true;
    await tester.pumpAndSettle();
    expect(dispatcher.canHandleBack, isTrue);
    expect(_publishedCanPop(tester), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('review: real Shell project-only shrink updates route policy', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    final appearance = AppearanceController(MemoryAppearanceStore());
    final shortcuts = LauncherShortcuts(
      FakeAppShortcutHost(),
      MemoryRecentProjectStore(),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      fixture.api.close();
      appearance.dispose();
      shortcuts.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect(
        'https://example.com/gitlab',
        'synthetic-test-token',
      );
    });

    _setViewport(tester, 1000);
    await tester.pumpWidget(
      AuthenticatedApp(
        session: session,
        appearance: appearance,
        shortcuts: shortcuts,
        buildInfoLoader: () async => const BuildInfo(
          version: 'review',
          buildNumber: '0',
          commit: '8ae63487-back-policy-probe',
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('Mobile Workspace'));
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectPage), findsOneWidget);
    // Do not select an issue: a nested compact detail could mask a stale root
    // policy by keeping dispatcher.canHandleBack true throughout the resize.
    expect(find.text('Overview'), findsNothing);

    _setViewport(tester, 412);
    await settleNetworkWidgets(tester);
    final route = ModalRoute.of(tester.element(find.byType(ProjectPage)));
    expect(route, isNotNull);
    expect(
      route!.popDisposition,
      RoutePopDisposition.doNotPop,
      reason: 'Project-only compact detail must intercept system back.',
    );
    expect(await tester.binding.handlePopRoute(), isTrue);
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectPage), findsNothing);
    expect(find.byKey(const Key('projectSearch')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
