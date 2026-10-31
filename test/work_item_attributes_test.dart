import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_attribute_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/workspace/work_item_attributes.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';

import 'support/fake_adapter.dart';

const _projectRef = GraphResourceRef(
  id: 'gid://gitlab/Project/42',
  fullPath: 'team/example',
);

WorkItemGraphSummary _summary() => WorkItemGraphSummary(
  id: 'gid://gitlab/WorkItem/7',
  iid: 7,
  title: 'Customer follow-up',
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 9, 1),
  updatedAt: DateTime.utc(2026, 9, 2),
  project: _projectRef,
  namespace: const GraphResourceRef(
    id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
    fullPath: 'team/example',
  ),
  type: const WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/99',
    name: 'Custom type',
  ),
);

WorkItemGraphDetail _detail(Set<String> widgetTypes) => WorkItemGraphDetail(
  summary: _summary(),
  description: null,
  widgetsAvailable: true,
  widgetTypes: widgetTypes,
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

WorkItemAttributeSnapshot _snapshot(
  WorkItemAttributeKind kind,
  WorkItemAttributeValue value,
) => WorkItemAttributeSnapshot(
  workItemId: 'gid://gitlab/WorkItem/7',
  iid: 7,
  project: _projectRef,
  namespace: null,
  kind: kind,
  availability: WorkItemAttributeAvailability.present,
  value: value,
);

Account _account(GitLabApi api, {int user = 7}) => Account(
  instance: api.instance,
  user: GitLabUser(id: user, username: 'user$user', name: 'User $user'),
  token: 'synthetic-token',
);

Widget _host({
  required Account account,
  required GitLabApi api,
  required WorkItemGraphDetail detail,
  required WorkItemAttributeLoader loader,
  bool Function()? isCurrent,
  Listenable? ownerChanges,
  double scale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: WorkItemAttributesPanel(
        account: account,
        api: api,
        detail: detail,
        loadAttribute: loader,
        isCurrent: isCurrent,
        ownerChanges: ownerChanges,
      ),
    ),
  ),
);

final class _OwnerMarker extends ChangeNotifier {
  int generation = 1;
  void changed() => notifyListeners();
}

void main() {
  // #56 part 2: a field's first read is a one-line skeleton inside the loaded
  // page (no live region of its own); a failed read retried shows it again.
  testWidgets('a field first read is a line skeleton, not a bar', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);
    final pending =
        <WorkItemAttributeKind, Completer<WorkItemAttributeSnapshot>>{};
    Future<WorkItemAttributeSnapshot> load(
      WorkItemGraphSummary _,
      WorkItemAttributeKind kind, {
      bool Function()? isCurrent,
    }) => (pending[kind] = Completer()).future;

    await tester.pumpWidget(
      _host(
        account: _account(api),
        api: api,
        detail: _detail({'STATUS', 'WEIGHT'}),
        loader: load,
      ),
    );
    await tester.tap(find.text('屬性'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LineSkeleton), findsNWidgets(2));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.bySemanticsLabel('正在載入'), findsNothing);

    pending[WorkItemAttributeKind.weight]!.complete(
      _valueFor(WorkItemAttributeKind.weight),
    );
    pending[WorkItemAttributeKind.status]!.completeError(
      const ApiFailure(FailureKind.server),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(LineSkeleton), findsNothing);
    expect(find.text('權重：0'), findsOneWidget);
    expect(find.text('GitLab 暫時無法回應'), findsOneWidget);

    await tester.tap(find.text('重試'));
    await tester.pump();
    expect(find.byType(LineSkeleton), findsOneWidget);
    expect(find.text('權重：0'), findsOneWidget);
    pending[WorkItemAttributeKind.status]!.complete(
      _valueFor(WorkItemAttributeKind.status),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(LineSkeleton), findsNothing);
    semantics.dispose();
  });

  testWidgets('lazy expansion caps reads at two and caches loaded rows', (
    tester,
  ) async {
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);
    final calls = <WorkItemAttributeKind>[];
    final pending =
        <WorkItemAttributeKind, Completer<WorkItemAttributeSnapshot>>{};
    Future<WorkItemAttributeSnapshot> load(
      WorkItemGraphSummary _,
      WorkItemAttributeKind kind, {
      bool Function()? isCurrent,
    }) {
      calls.add(kind);
      return (pending[kind] = Completer()).future;
    }

    await tester.pumpWidget(
      _host(
        account: _account(api),
        api: api,
        detail: _detail({
          'STATUS',
          'MILESTONE',
          'WEIGHT',
          'ITERATION',
          'HEALTH_STATUS',
          'TIME_TRACKING',
          'DEVELOPMENT',
        }),
        loader: load,
      ),
    );
    expect(calls, isEmpty, reason: 'collapsed attributes do no network work');

    await tester.tap(find.text('屬性'));
    await tester.pump();
    expect(calls.length, 2);

    pending[calls.first]!.complete(
      _snapshot(calls.first, const WorkItemStatusAttribute(status: null)),
    );
    await tester.pump();
    expect(calls.length, 3, reason: 'one completion admits one queued read');

    while (pending.values.any((future) => !future.isCompleted)) {
      for (final entry in pending.entries.toList()) {
        if (!entry.value.isCompleted) {
          entry.value.complete(_valueFor(entry.key));
        }
      }
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(calls.length, 7);

    await tester.tap(find.text('屬性'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('屬性'));
    await tester.pumpAndSettle();
    expect(
      calls.length,
      7,
      reason: 'collapse and re-expand retain loaded rows',
    );
  });

  testWidgets('one field failure retries without hiding successful fields', (
    tester,
  ) async {
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);
    var statusAttempts = 0;
    Future<WorkItemAttributeSnapshot> load(
      WorkItemGraphSummary _,
      WorkItemAttributeKind kind, {
      bool Function()? isCurrent,
    }) async {
      if (kind == WorkItemAttributeKind.status && statusAttempts++ == 0) {
        throw const ApiFailure(FailureKind.server);
      }
      return _valueFor(kind);
    }

    await tester.pumpWidget(
      _host(
        account: _account(api),
        api: api,
        detail: _detail({'STATUS', 'WEIGHT'}),
        loader: load,
      ),
    );
    await tester.tap(find.text('屬性'));
    await tester.pumpAndSettle();

    expect(find.text('GitLab 暫時無法回應'), findsOneWidget);
    expect(find.text('權重：0'), findsOneWidget);
    await tester.tap(find.text('重試'));
    await tester.pumpAndSettle();
    expect(find.text('Ready for release'), findsOneWidget);
    expect(find.text('權重：0'), findsOneWidget);
  });

  testWidgets('generation replacement drops a late old attribute result', (
    tester,
  ) async {
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);
    final marker = _OwnerMarker();
    final old = Completer<WorkItemAttributeSnapshot>();
    final fresh = Completer<WorkItemAttributeSnapshot>();
    final firstGeneration = marker.generation;

    await tester.pumpWidget(
      _host(
        account: _account(api),
        api: api,
        detail: _detail({'STATUS'}),
        ownerChanges: marker,
        isCurrent: () => marker.generation == firstGeneration,
        loader: (_, _, {isCurrent}) => old.future,
      ),
    );
    await tester.tap(find.text('屬性'));
    await tester.pump();

    marker.generation++;
    marker.changed();
    final replacementGeneration = marker.generation;
    await tester.pumpWidget(
      _host(
        account: _account(api),
        api: api,
        detail: _detail({'STATUS'}),
        ownerChanges: marker,
        isCurrent: () => marker.generation == replacementGeneration,
        loader: (_, _, {isCurrent}) => fresh.future,
      ),
    );
    fresh.complete(_statusSnapshot('Fresh owner status'));
    old.complete(_statusSnapshot('Old owner status'));
    await tester.pumpAndSettle();

    expect(find.text('Fresh owner status'), findsOneWidget);
    expect(find.text('Old owner status'), findsNothing);
  });

  testWidgets('renders known zero, durations, group owner and large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 840);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      _host(
        account: _account(api),
        api: api,
        detail: _detail({
          'MILESTONE',
          'WEIGHT',
          'TIME_TRACKING',
          'DEVELOPMENT',
        }),
        scale: 2,
        loader: (_, kind, {isCurrent}) async => switch (kind) {
          WorkItemAttributeKind.milestone => _snapshot(
            kind,
            WorkItemMilestoneAttribute(
              milestone: WorkItemMilestoneValue(
                id: 'gid://gitlab/Milestone/5',
                iid: 5,
                title: 'A very long group-owned milestone title for mobile',
                state: 'active',
                webPath: '/groups/actual-owner/-/milestones/5',
                dueDate: DateTime.utc(2026, 1, 1),
                startDate: DateTime.utc(2025, 12, 1),
                project: null,
                group: const WorkItemAttributeOwnerRef(
                  id: 'gid://gitlab/Group/9',
                  fullPath: 'actual-owner/platform',
                ),
              ),
            ),
          ),
          _ => _valueFor(kind),
        },
      ),
    );
    await tester.tap(find.text('屬性'));
    await tester.pumpAndSettle();

    expect(find.text('權重：0'), findsOneWidget);
    expect(find.text('已完成彙整權重：未知'), findsOneWidget);
    expect(find.text('預估：0 秒'), findsOneWidget);
    expect(find.text('已花費：1 小時（3600 秒）'), findsOneWidget);
    expect(find.text('可關閉此項目的 Merge Request：2'), findsOneWidget);
    expect(find.text('所屬：actual-owner/platform'), findsOneWidget);
    expect(find.text('到期：2026/01/01'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

WorkItemAttributeSnapshot _statusSnapshot(String name) => _snapshot(
  WorkItemAttributeKind.status,
  WorkItemStatusAttribute(
    status: WorkItemStatusValue(
      id: 'gid://gitlab/WorkItems::Statuses::SystemDefined/1',
      name: name,
      iconName: null,
      color: null,
      category: 'in_progress',
    ),
  ),
);

WorkItemAttributeSnapshot _valueFor(WorkItemAttributeKind kind) =>
    switch (kind) {
      WorkItemAttributeKind.status => _statusSnapshot('Ready for release'),
      WorkItemAttributeKind.milestone => _snapshot(
        kind,
        const WorkItemMilestoneAttribute(milestone: null),
      ),
      WorkItemAttributeKind.weight => _snapshot(
        kind,
        const WorkItemWeightAttribute(
          weight: 0,
          rolledUpWeight: 5,
          rolledUpCompletedWeight: null,
        ),
      ),
      WorkItemAttributeKind.iteration => _snapshot(
        kind,
        const WorkItemIterationAttribute(iteration: null),
      ),
      WorkItemAttributeKind.health => _snapshot(
        kind,
        const WorkItemHealthAttribute(
          healthStatus: null,
          rolledUpHealthStatus: [],
        ),
      ),
      WorkItemAttributeKind.timeTracking => _snapshot(
        kind,
        const WorkItemTimeTrackingAttribute(
          timeEstimate: 0,
          totalTimeSpent: 3600,
          humanReadable: WorkItemHumanReadableTime(
            timeEstimate: null,
            totalTimeSpent: '1 小時',
          ),
        ),
      ),
      WorkItemAttributeKind.development => _snapshot(
        kind,
        const WorkItemDevelopmentAttribute(
          closingMergeRequestsCount: 2,
          willAutoCloseByMergeRequest: true,
        ),
      ),
    };
