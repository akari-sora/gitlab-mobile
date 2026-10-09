import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/project_locator.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/groups_page.dart';
import 'package:gitlab_mobile/features/workspace/navigation.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/widget_settle.dart';
import 'support/work_item_status_fixture.dart';

// Route families reach GraphWorkItemDetailPage only through production
// openers, built with constructor arguments that existed at 61cf7f0. The
// opener's isCurrent checks account and client identity only, so the
// SessionController.generation check under test is the page's own.
//
// Limitation: a generation advance that keeps the same Account and the same
// GitLabApi instance cannot be produced through a public SessionController
// method (every _activate creates a new client). Those cases assign the
// public `generation` field directly and say so; one case per file uses the
// real endSession/select activation path instead.

const _project = Project(id: 42, name: 'mobile', path: 'studio/mobile');
const _edit = ValueKey('work-item-status-edit');
const _save = ValueKey('work-item-status-save');
const _statusOp = 'MobileWorkItemStatus';
const _childId = 'gid://gitlab/WorkItem/302';

void main() {
  testWidgets('project list -> detail carries the captured generation', (
    tester,
  ) async {
    final h = await _session(tester);
    await _pump(tester, h, (account, api, isCurrent) {
      return GraphWorkItemsPage(
        account: account,
        api: api,
        project: _project,
        isCurrent: isCurrent,
        ownerChanges: h.session,
      );
    });
    await tester.tap(find.text('專案狀態項目'));
    await settleNetworkWidgets(tester);
    expect(find.text('工作項目 #17'), findsOneWidget);
    await _expectWriterOpens(tester, h.fixture);

    h.session.generation++; // same Account, identical GitLabApi (see header)
    await _expectWriterClosed(tester, h.fixture);
    await tester.pageBack();
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('專案狀態項目'));
    await settleNetworkWidgets(tester);
    await _expectWriterClosed(tester, h.fixture, reason: 'old list route');
    expect(h.fixture.mutations, 0);
  });

  testWidgets('group list -> namespace detail carries the generation', (
    tester,
  ) async {
    final h = await _session(tester);
    await _pump(tester, h, (account, api, isCurrent) {
      return Scaffold(
        body: GraphWorkItemsPage.group(
          account: account,
          api: api,
          namespacePath: WorkItemStatusFixture.groupRef.fullPath,
          isCurrent: isCurrent,
          ownerChanges: h.session,
        ),
      );
    });
    await tester.tap(find.text('群組狀態項目'));
    await settleNetworkWidgets(tester);
    expect(h.fixture.count('MobileNamespaceWorkItem'), 1);
    await _expectWriterOpens(tester, h.fixture);
    expect(
      h.fixture.requests.last.workItemId,
      WorkItemStatusFixture.groupItemId,
    );

    h.session.generation++; // field assignment, see header
    await _expectWriterClosed(tester, h.fixture);
  });

  testWidgets(
    'GroupPage work-items tab (groupByPath, list, detail) carries the '
    'generation it captured from sessionProvider',
    (tester) async {
      final h = await _session(tester);
      final group = (await tester.runAsync(
        () =>
            h.session.api!.groupByPath(WorkItemStatusFixture.groupRef.fullPath),
      ))!;
      expect(h.fixture.count('GET groups/studio/group'), 1);
      expect(group['id'], 84);
      await _pump(
        tester,
        h,
        (account, api, isCurrent) =>
            GroupPage(account: account, api: api, group: group, initialTab: 4),
      );
      expect(h.fixture.count('MobileGroupWorkItems'), greaterThanOrEqualTo(1));
      await tester.tap(find.text('群組狀態項目'));
      await settleNetworkWidgets(tester);
      expect(h.fixture.count('MobileNamespaceWorkItem'), 1);
      await _expectWriterOpens(tester, h.fixture);
      expect(
        h.fixture.requests.last.workItemId,
        WorkItemStatusFixture.groupItemId,
      );

      h.session.generation++; // field assignment, see header
      await _expectWriterClosed(tester, h.fixture);
      expect(h.fixture.mutations, 0);
      expect(h.fixture.unhandled, isEmpty);
    },
  );

  testWidgets('hierarchy child -> detail carries the generation', (
    tester,
  ) async {
    final h = await _session(tester, withChild: true);
    await _pump(tester, h, (_, _, _) => _detail(h));
    await tester.tap(find.text('子項目狀態'));
    await settleNetworkWidgets(tester);
    expect(find.text('工作項目 #18'), findsOneWidget);
    await _expectWriterOpens(tester, h.fixture);
    expect(h.fixture.requests.last.workItemId, _childId);

    h.session.generation++; // field assignment, see header
    await _expectWriterClosed(tester, h.fixture);
  });

  testWidgets(
    'hierarchy project resolve finishing after a generation advance opens a '
    'route whose writer stays closed',
    (tester) async {
      final h = await _session(tester, withChild: true, hideNamespace: true);
      await _pump(tester, h, (_, _, _) => _detail(h));
      h.fixture.holdNextProject = Completer<void>();
      await tester.tap(find.text('子項目狀態'));
      await _untilProjectHeld(tester, h.fixture);
      expect(h.fixture.count('GET projects/studio/mobile'), 1);
      expect(h.fixture.heldCount, 1, reason: 'the project resolve is held');
      h.session.generation++; // field assignment, see header
      h.fixture.releaseHolds();
      await settleNetworkWidgets(tester);
      expect(find.text('工作項目 #18'), findsOneWidget, reason: 'route opened');
      await _expectWriterClosed(tester, h.fixture);
      expect(h.fixture.count(_statusOp), 0);
    },
  );

  testWidgets('hierarchy resolve after the route is popped pushes nothing', (
    tester,
  ) async {
    final h = await _session(tester, withChild: true, hideNamespace: true);
    final navigator = GlobalKey<NavigatorState>();
    await _pump(
      tester,
      h,
      (account, api, isCurrent) => const SizedBox.shrink(),
      navigator: navigator,
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => _detail(h)),
      ),
    );
    await settleNetworkWidgets(tester);
    h.fixture.holdNextProject = Completer<void>();
    await tester.tap(find.text('子項目狀態'));
    await _untilProjectHeld(tester, h.fixture);
    expect(h.fixture.count('GET projects/studio/mobile'), 1);
    expect(h.fixture.heldCount, 1, reason: 'the project resolve is held');
    navigator.currentState!.pop();
    await settleNetworkWidgets(tester);
    h.fixture.releaseHolds();
    await settleNetworkWidgets(tester);
    expect(find.text('工作項目 #18'), findsNothing);
    expect(find.text('工作項目 #17'), findsNothing);
  });

  testWidgets('ResourceNavigator project deep link carries the generation', (
    tester,
  ) async {
    final h = await _session(tester);
    await _pump(
      tester,
      h,
      (account, api, isCurrent) => _linkButton(
        account,
        api,
        'https://example.com/gitlab/studio/mobile/-/work_items/17',
      ),
    );
    await tester.tap(find.text('open'));
    await settleNetworkWidgets(tester);
    expect(find.text('工作項目 #17'), findsOneWidget);
    await _expectWriterOpens(tester, h.fixture);
    h.session.generation++; // field assignment, see header
    await _expectWriterClosed(tester, h.fixture);
  });

  testWidgets('ResourceNavigator group deep link carries the generation', (
    tester,
  ) async {
    final h = await _session(tester);
    await _pump(
      tester,
      h,
      (account, api, isCurrent) => _linkButton(
        account,
        api,
        'https://example.com/gitlab/groups/studio/group/-/work_items/17',
      ),
    );
    await tester.tap(find.text('open'));
    await settleNetworkWidgets(tester);
    expect(h.fixture.count('MobileNamespaceWorkItem'), 1);
    await _expectWriterOpens(tester, h.fixture);
    h.session.generation++; // field assignment, see header
    await _expectWriterClosed(tester, h.fixture);
  });

  testWidgets('deep link resolve finishing after a generation advance '
      'pushes no late route', (tester) async {
    final h = await _session(tester);
    await _pump(
      tester,
      h,
      (account, api, isCurrent) => _linkButton(
        account,
        api,
        'https://example.com/gitlab/studio/mobile/-/work_items/17',
      ),
    );
    h.fixture.holdNextProject = Completer<void>();
    await tester.tap(find.text('open'));
    await _untilProjectHeld(tester, h.fixture);
    expect(h.fixture.count('GET projects/studio/mobile'), 1);
    expect(h.fixture.heldCount, 1, reason: 'the project resolve is held');
    h.session.generation++; // field assignment, see header
    h.fixture.releaseHolds();
    await settleNetworkWidgets(tester);
    expect(find.text('工作項目 #17'), findsNothing);
    expect(h.fixture.count('MobileProjectWorkItem'), 0);
  });

  testWidgets('real away-and-back activation keeps the old detail invalid', (
    tester,
  ) async {
    final h = await _session(tester);
    await _pump(tester, h, (account, api, isCurrent) {
      return GraphWorkItemsPage(
        account: account,
        api: api,
        project: _project,
        isCurrent: isCurrent,
        ownerChanges: h.session,
      );
    });
    await tester.tap(find.text('專案狀態項目'));
    await settleNetworkWidgets(tester);
    await _expectWriterOpens(tester, h.fixture);
    final generation = h.session.generation;
    final api = h.session.api;
    await tester.runAsync(() => h.session.endSession());
    await tester.runAsync(() => h.session.select(h.session.accounts.single));
    await settleNetworkWidgets(tester);
    expect(h.session.active?.key, h.fixture.account.key);
    expect(h.session.generation, generation + 3, reason: 'end + select');
    expect(identical(h.session.api, api), isFalse);
    final reads = h.fixture.count(_statusOp);
    expect(find.byKey(_edit), findsNothing, reason: 'old detail: no writer');
    expect(find.text('屬性'), findsNothing, reason: 'old detail withdrawn');
    await settleNetworkWidgets(tester);
    expect(h.fixture.count(_statusOp), reads);
    expect(find.byKey(_save), findsNothing);
  });
}

typedef _Harness = ({
  WorkItemStatusFixture fixture,
  SessionController session,
  bool Function() isCurrent,
});

typedef _Builder =
    Widget Function(Account account, GitLabApi api, bool Function() isCurrent);

Future<_Harness> _session(
  WidgetTester tester, {
  bool withChild = false,
  bool hideNamespace = false,
}) async {
  final fixture = WorkItemStatusFixture()..serveParent = true;
  if (withChild) {
    fixture.items[_childId] = StatusFixtureItem(
      id: _childId,
      iid: 18,
      title: '子項目狀態',
      project: WorkItemStatusFixture.projectRef,
      namespace: WorkItemStatusFixture.projectNamespaceRef,
      updatedAt: WorkItemStatusFixture.openedAt,
      assignment: WorkItemStatusFixture.defaultMembers.first,
      members: WorkItemStatusFixture.defaultMembers,
    )..hideNamespaceAsChild = hideNamespace;
    fixture.item(group: false).childIds.add(_childId);
  }
  final session = controllerFor(MemoryAccountStore(), fixture.adapter);
  // Tear-downs run last-in first-out: holds, then clients, then session.
  addTearDown(session.dispose);
  addTearDown(fixture.closeAll);
  addTearDown(fixture.releaseHolds);
  await tester.binding.setSurfaceSize(const Size(420, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(session.initialize);
  await tester.runAsync(
    () => session.connect('https://example.com/gitlab', 'synthetic-test-token'),
  );
  final account = session.active!;
  final api = session.api!;
  bool isCurrent() =>
      session.active?.key == account.key && identical(session.api, api);
  return (fixture: fixture, session: session, isCurrent: isCurrent);
}

Future<void> _pump(
  WidgetTester tester,
  _Harness h,
  _Builder build, {
  GlobalKey<NavigatorState>? navigator,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sessionProvider.overrideWithValue(h.session)],
      child: MaterialApp(
        navigatorKey: navigator,
        home: build(h.session.active!, h.session.api!, h.isCurrent),
      ),
    ),
  );
  await settleNetworkWidgets(tester);
}

Widget _detail(_Harness h) => GraphWorkItemDetailPage.project(
  account: h.session.active!,
  api: h.session.api!,
  project: _project,
  iid: WorkItemStatusFixture.sharedIid,
  isCurrent: h.isCurrent,
  ownerChanges: h.session,
);

Widget _linkButton(Account account, GitLabApi api, String url) => Scaffold(
  body: Builder(
    builder: (context) => TextButton(
      onPressed: () => unawaited(
        ResourceNavigator(
          account,
          api,
        ).link(context, GitLabLink.parse(url, account.instance)),
      ),
      child: const Text('open'),
    ),
  ),
);

Future<void> _expectWriterOpens(
  WidgetTester tester,
  WorkItemStatusFixture fixture,
) async {
  await tester.tap(find.text('屬性'));
  await settleNetworkWidgets(tester);
  final before = fixture.count(_statusOp);
  await tester.tap(find.byKey(_edit));
  await settleNetworkWidgets(tester);
  expect(fixture.count(_statusOp), before + 1);
  expect(find.byKey(_save), findsOneWidget);
  await tester.pageBack();
  await settleNetworkWidgets(tester);
}

Future<void> _expectWriterClosed(
  WidgetTester tester,
  WorkItemStatusFixture fixture, {
  String? reason,
}) async {
  if (find.byKey(_edit).evaluate().isEmpty &&
      find.text('屬性').evaluate().isNotEmpty) {
    await tester.tap(find.text('屬性'));
    await settleNetworkWidgets(tester);
  }
  final reads = fixture.count(_statusOp);
  final mutations = fixture.mutations;
  expect(find.byKey(_edit), findsOneWidget, reason: 'STATUS row is shown');
  await tester.tap(find.byKey(_edit), warnIfMissed: false);
  await settleNetworkWidgets(tester);
  expect(fixture.count(_statusOp), reads, reason: reason);
  expect(fixture.mutations, mutations, reason: reason);
  expect(find.byKey(_save), findsNothing, reason: reason);
}

/// Pumps, bounded, until the held project resolve has reached the fixture.
Future<void> _untilProjectHeld(
  WidgetTester tester,
  WorkItemStatusFixture fixture,
) => pumpUntil(
  tester,
  () => fixture.count('GET projects/studio/mobile') == 1,
  step: const Duration(milliseconds: 1),
  realDelay: const Duration(milliseconds: 1),
  description: 'held project resolve',
);
