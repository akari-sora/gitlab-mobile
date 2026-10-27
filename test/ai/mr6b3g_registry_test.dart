import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_work_item_write_registry.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as writes;
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_status_models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_status.dart';

import '../support/fake_adapter.dart';
import '../support/widget_settle.dart';
import '../support/work_item_health_parent_fixture.dart';
import '../support/work_item_status_fixture.dart';

const _gid = WorkItemStatusFixture.groupItemId;
const _projectGid = WorkItemStatusFixture.projectItemId;
const _otherGid = 'gid://gitlab/WorkItem/402';
const _group = GraphResourceRef(
  id: 'gid://gitlab/Group/84',
  fullPath: 'studio/group',
);
const _otherGroup = GraphResourceRef(
  id: 'gid://gitlab/Group/85',
  fullPath: 'studio/other',
);
const _projectNamespace = GraphResourceRef(
  id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
  fullPath: 'studio/mobile',
);

AiWorkItemWriteRegistry _registry(
  GitLabApi api,
  String accountKey, {
  bool Function()? current,
}) => createAiWorkspaceWorkItemWriteRegistry(
  api: api,
  accountKey: accountKey,
  instanceKey: api.instance.key,
  generation: 12,
  isCurrent: current ?? () => true,
);

Account _account(String host) => Account(
  instance: GitLabInstance.parse(host),
  user: const GitLabUser(id: 7, username: 'ada', name: 'Ada'),
  token: 'synthetic-test-token',
);

Map<String, Object?> _response(
  GraphResourceRef owner,
  String gid, {
  bool project = false,
}) => {
  'data': {
    'namespace': {
      'id': owner.id,
      'fullPath': owner.fullPath,
      'workItem': {
        'id': gid,
        'iid': '17',
        'title': 'Fresh title',
        'state': 'OPEN',
        'createdAt': '2026-10-01T00:00:00Z',
        'updatedAt': '2026-10-02T00:00:00Z',
        'project': project
            ? {'id': 'gid://gitlab/Project/42', 'fullPath': owner.fullPath}
            : null,
        'namespace': {'id': owner.id, 'fullPath': owner.fullPath},
        'workItemType': {
          'id': 'gid://gitlab/WorkItems::Type/1',
          'name': 'Task',
        },
        'description': '',
        'widgets': <Object?>[],
      },
    },
  },
};

void main() {
  test(
    'fresh entry resolves exact group and project owners, not list data',
    () async {
      var owner = _group;
      var itemGid = _gid;
      var project = false;
      final adapter = FakeAdapter((request) {
        if (request.method == 'GET') {
          if (request.uri.pathSegments.contains('groups')) {
            return jsonResponse({
              'id': int.parse(owner.id.split('/').last),
              'full_path': owner.fullPath,
            });
          }
          return jsonResponse({
            ...projectJson(42),
            'path_with_namespace': 'studio/mobile',
          });
        }
        return jsonResponse(_response(owner, itemGid, project: project));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final account = _account('https://example.com/gitlab');
      Future<AiChatOrigin> read() => freshGroupPageAiOrigin(
        api: api,
        account: account,
        generation: 12,
        isCurrent: () => true,
        viewGroup: _group,
        itemNamespace: owner,
        iid: 17,
      );
      final first = await read();
      expect(first, isA<AiGroupWorkItemOrigin>());
      expect(first.key, 'group-item:84:17');
      expect((first as AiGroupWorkItemOrigin).title, 'Fresh title');
      owner = _otherGroup;
      itemGid = _otherGid;
      final second = await read();
      expect(second.key, 'group-item:85:17');
      owner = _projectNamespace;
      project = true;
      final descendant = await read();
      expect(descendant, isA<AiProjectWorkItemFromGroupPageOrigin>());
      expect(descendant.key, 'group-page:84:project:42:workItem:17');
      expect(adapter.requests.where((r) => r.method == 'POST'), hasLength(3));
      owner = const GraphResourceRef(
        id: 'gid://gitlab/Group/84',
        fullPath: 'renamed/group',
      );
      itemGid = _gid;
      project = false;
      final renamed = await freshGroupPageAiOrigin(
        api: api,
        account: account,
        generation: 12,
        isCurrent: () => true,
        viewGroup: _group,
        itemNamespace: _group,
        iid: 17,
      );
      expect(
        (renamed as AiGroupWorkItemOrigin).group.fullPath,
        'renamed/group',
      );
    },
  );

  test(
    'fresh entry rejects unverified owner and cancelled generation',
    () async {
      final pending = Completer<void>();
      var current = true;
      final api = testApi(
        FakeAdapter((_) async {
          await pending.future;
          return jsonResponse(_response(_group, _gid));
        }),
      );
      addTearDown(api.close);
      final account = _account('https://example.com/gitlab');
      final read = freshGroupPageAiOrigin(
        api: api,
        account: account,
        generation: 12,
        isCurrent: () => current,
        viewGroup: _group,
        itemNamespace: _group,
        iid: 17,
      );
      current = false;
      pending.complete();
      await expectLater(read, throwsA(isA<ApiFailure>()));
      await expectLater(
        freshGroupPageAiOrigin(
          api: api,
          account: account,
          generation: 12,
          isCurrent: () => true,
          viewGroup: const GraphResourceRef(
            id: 'gid://gitlab/Project/84',
            fullPath: 'studio/group',
          ),
          itemNamespace: _group,
          iid: 17,
        ),
        throwsA(isA<ApiFailure>()),
      );
    },
  );

  test(
    'reopened adapter shares the old page lock but replacement owners isolate it',
    () {
      final firstApi = testApi(FakeAdapter((_) => jsonResponse({})));
      final replacement = testApi(FakeAdapter((_) => jsonResponse({})));
      final otherInstance = testApi(
        FakeAdapter((_) => jsonResponse({})),
        host: 'https://other.example/gitlab',
      );
      addTearDown(firstApi.close);
      addTearDown(replacement.close);
      addTearDown(otherInstance.close);
      var current = true;
      final first = _registry(
        firstApi,
        _account('https://example.com/gitlab').key,
        current: () => current,
      );
      final reopened = _registry(
        firstApi,
        _account('https://example.com/gitlab').key,
      );
      final newApi = _registry(
        replacement,
        _account('https://example.com/gitlab').key,
      );
      final foreign = _registry(
        otherInstance,
        _account('https://other.example/gitlab').key,
      );
      final lease = first.tryStart(_gid, AiWorkItemWriteKind.health)!;
      expect(reopened.isActive(_gid), isTrue);
      expect(reopened.tryStart(_gid, AiWorkItemWriteKind.status), isNull);
      expect(reopened.isActive(_otherGid), isFalse);
      final anotherItem = reopened.tryStart(
        _otherGid,
        AiWorkItemWriteKind.status,
      )!;
      final newClient = newApi.tryStart(_gid, AiWorkItemWriteKind.status)!;
      final otherHost = foreign.tryStart(_gid, AiWorkItemWriteKind.status)!;
      current = false;
      expect(first.tryStart(_otherGid, AiWorkItemWriteKind.health), isNull);
      first.settle(lease, AiWorkItemWriteResult.notSent, null);
      reopened.settle(anotherItem, AiWorkItemWriteResult.notSent, null);
      newApi.settle(newClient, AiWorkItemWriteResult.notSent, null);
      foreign.settle(otherHost, AiWorkItemWriteResult.notSent, null);
      expect(reopened.isActive(_gid), isFalse);
    },
  );

  test(
    'UI status reservation excludes every AI kind, with separate group GIDs',
    () {
      final fixture = WorkItemStatusFixture();
      addTearDown(fixture.closeAll);
      final registry = _registry(fixture.api, fixture.account.key);
      final uiToken = Object();
      final status = WorkItemStatusWriteRegistry.instance;
      expect(status.tryStartExternal(fixture.api, _gid, uiToken), isTrue);
      for (final kind in AiWorkItemWriteKind.values) {
        expect(registry.isActive(_gid), isTrue);
        expect(registry.tryStart(_gid, kind), isNull);
      }
      final other = registry.tryStart(_otherGid, AiWorkItemWriteKind.status)!;
      registry.settle(other, AiWorkItemWriteResult.notSent, null);
      status.settleExternal(
        fixture.api,
        _gid,
        token: uiToken,
        mutationSent: false,
      );
    },
  );

  for (final cancel in [false, true]) {
    testWidgets(
      'real group STATUS write excludes AI and settles after ${cancel ? 'cancel' : 'failure'}',
      (tester) async {
        final fixture = WorkItemStatusFixture();
        addTearDown(fixture.closeAll);
        addTearDown(fixture.releaseHolds);
        final phases = <WorkItemStatusWritePhase>[];
        final registry = _registry(fixture.api, fixture.account.key);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WorkItemStatusControl(
                account: fixture.account,
                api: fixture.api,
                detail: fixture.detail(group: true),
                sessionGeneration: 12,
                onSaved: (_) {},
                onStatusWrite:
                    (phase, token, account, api, detail, generation) =>
                        phases.add(phase),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('work-item-status-edit')));
        await settleNetworkWidgets(tester);
        final choice = find.byKey(
          const ValueKey(
            'work-item-status-choice-${WorkItemStatusFixture.statusDoing}',
          ),
        );
        await tester.scrollUntilVisible(
          choice,
          120,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(choice);
        await tester.pump();
        final held = Completer<void>();
        fixture.holdBeforeApply = held;
        await tester.tap(find.byKey(const ValueKey('work-item-status-save')));
        await pumpUntil(
          tester,
          () => phases.contains(WorkItemStatusWritePhase.start),
        );
        for (final kind in AiWorkItemWriteKind.values) {
          expect(registry.tryStart(_gid, kind), isNull);
        }
        if (cancel) {
          fixture.api.close();
          held.complete();
        } else {
          held.completeError(StateError('synthetic write failure'));
        }
        await pumpUntil(
          tester,
          () => phases.contains(WorkItemStatusWritePhase.settle),
        );
        expect(phases, [
          WorkItemStatusWritePhase.start,
          WorkItemStatusWritePhase.settle,
        ]);
        expect(
          WorkItemStatusWriteRegistry.instance.isActive(fixture.api, _gid),
          isFalse,
        );
        expect(
          aiWorkspaceWriteFreshnessForTesting(
            fixture.api,
            _gid,
            AiWorkItemWriteKind.status,
          )?.confirmed,
          isFalse,
        );
      },
    );
  }

  testWidgets(
    'AI leases exclude peers and are visible to a group STATUS control',
    (tester) async {
      final fixture = WorkItemStatusFixture();
      addTearDown(fixture.closeAll);
      final registry = _registry(fixture.api, fixture.account.key);
      final peer = _registry(fixture.api, fixture.account.key);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkItemStatusControl(
              account: fixture.account,
              api: fixture.api,
              detail: fixture.detail(group: true),
              sessionGeneration: 12,
              onSaved: (_) {},
            ),
          ),
        ),
      );
      for (final kind in AiWorkItemWriteKind.values) {
        final lease = registry.tryStart(_gid, kind)!;
        for (final otherKind in AiWorkItemWriteKind.values) {
          expect(peer.tryStart(_gid, otherKind), isNull);
        }
        if (kind != AiWorkItemWriteKind.health) {
          await tester.pump();
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('work-item-status-edit')),
                )
                .onPressed,
            isNull,
          );
        }
        registry.settle(lease, AiWorkItemWriteResult.notSent, null);
        await tester.pump();
        expect(peer.isActive(_gid), isFalse);
      }
    },
  );

  testWidgets('group detail shows Dates and Health AI leases as in flight', (
    tester,
  ) async {
    final fixture = WorkItemHealthParentFixture();
    final api = fixture.primaryApi();
    addTearDown(fixture.closeAll);
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Widget page() => ProviderScope(
      child: MaterialApp(
        home: GraphWorkItemDetailPage.namespace(
          account: fixture.account,
          api: api,
          namespacePath: _group.fullPath,
          expectedNamespaceId: _group.id,
          iid: 17,
          sessionGeneration: 12,
          isCurrent: () => true,
        ),
      ),
    );
    await tester.pumpWidget(page());
    await settleNetworkWidgets(tester);
    final registry = _registry(api, fixture.account.key);
    for (final (kind, key) in [
      (AiWorkItemWriteKind.dates, 'work-item-dates-hold'),
      (AiWorkItemWriteKind.health, 'work-item-health-hold'),
    ]) {
      final lease = registry.tryStart(_gid, kind)!;
      await tester.pump();
      expect(find.byKey(ValueKey(key)), findsOneWidget);
      if (kind == AiWorkItemWriteKind.health) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(page());
        await settleNetworkWidgets(tester);
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      registry.settle(lease, AiWorkItemWriteResult.notSent, null);
      await settleNetworkWidgets(tester);
      expect(find.byKey(ValueKey(key)), findsNothing);
    }
  });

  for (final kind in [AiWorkItemWriteKind.dates, AiWorkItemWriteKind.health]) {
    testWidgets('real group ${kind.name} write excludes every AI lease', (
      tester,
    ) async {
      final fixture = WorkItemHealthParentFixture();
      final api = fixture.primaryApi();
      addTearDown(fixture.closeAll);
      addTearDown(fixture.releaseHolds);
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: GraphWorkItemDetailPage.namespace(
              account: fixture.account,
              api: api,
              namespacePath: _group.fullPath,
              expectedNamespaceId: _group.id,
              iid: 17,
              sessionGeneration: 12,
              isCurrent: () => true,
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      final edit = find.byKey(ValueKey('work-item-${kind.name}-edit'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await settleNetworkWidgets(tester);
      if (kind == AiWorkItemWriteKind.dates) {
        await tester.enterText(
          find.byKey(const ValueKey('work-item-dates-start-input')),
          '2026-11-02',
        );
        await tester.enterText(
          find.byKey(const ValueKey('work-item-dates-due-input')),
          '2026-11-29',
        );
      } else {
        final choice = find.byKey(
          const ValueKey('work-item-health-choice-onTrack'),
        );
        await tester.scrollUntilVisible(
          choice,
          120,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('work-item-health-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.tap(choice);
      }
      await tester.pump();
      final held = Completer<void>();
      if (kind == AiWorkItemWriteKind.dates) {
        fixture.dates.holdBeforeApply = held;
      } else {
        fixture.holdBeforeApply = held;
      }
      await tester.tap(find.byKey(ValueKey('work-item-${kind.name}-save')));
      await pumpUntil(
        tester,
        () => kind == AiWorkItemWriteKind.dates
            ? fixture.dates.awaitingApply
            : fixture.awaitingApply,
      );
      final registry = _registry(api, fixture.account.key);
      for (final other in AiWorkItemWriteKind.values) {
        expect(registry.tryStart(_gid, other), isNull);
      }
      held.complete();
      await pumpUntil(tester, () => !registry.isActive(_gid));
      await settleNetworkWidgets(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleNetworkWidgets(tester);
    });
  }

  test(
    'group prepare families remain unavailable before lock checking',
    () async {
      expect(aiGroupWorkItemWritesEnabled, isFalse);
      final adapter = FakeAdapter((_) => jsonResponse({}));
      final api = testApi(adapter);
      addTearDown(api.close);
      final account = _account('https://example.com/gitlab');
      final registry = _registry(api, account.key);
      final lease = registry.tryStart(_gid, AiWorkItemWriteKind.health)!;
      addTearDown(
        () => registry.settle(lease, AiWorkItemWriteResult.notSent, null),
      );
      final port = writes.GitLabAiWritePort(
        api,
        accountKey: account.key,
        workItemWriteRegistry: registry,
      );
      for (final op in [
        'updateGroupWorkItemStatus',
        'updateGroupWorkItemDates',
        'updateGroupWorkItemHealthStatus',
      ]) {
        final request = writes.AiWriteRequest(
          operationId: op,
          executionId: op,
          scope: AiWriteScope(
            accountKey: account.key,
            grants: const [
              AiScopeGrant(
                kind: AiScopeKind.groupWorkItem,
                groupId: 84,
                groupFullPath: 'studio/group',
                iid: 17,
              ),
            ],
          ),
          arguments: const {'groupId': 84, 'iid': 17},
        );
        await expectLater(
          port.prepare(request),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.unsupported,
            ),
          ),
        );
      }
      expect(adapter.requests, isEmpty);
    },
  );

  for (final kind in AiWorkItemWriteKind.values) {
    testWidgets('production ${kind.name} prepare refuses a real UI write', (
      tester,
    ) async {
      final fixture = WorkItemHealthParentFixture();
      final api = fixture.primaryApi();
      addTearDown(fixture.closeAll);
      addTearDown(fixture.releaseHolds);
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: GraphWorkItemDetailPage.project(
              account: fixture.account,
              api: api,
              project: const Project(
                id: 42,
                name: 'mobile',
                path: 'studio/mobile',
              ),
              iid: 17,
              sessionGeneration: 12,
              isCurrent: () => true,
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      if (kind == AiWorkItemWriteKind.status) {
        final attributes = find.text('屬性');
        await tester.ensureVisible(attributes);
        await tester.tap(attributes);
        await settleNetworkWidgets(tester);
      }
      final edit = find.byKey(ValueKey('work-item-${kind.name}-edit'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await settleNetworkWidgets(tester);
      if (kind == AiWorkItemWriteKind.dates) {
        await tester.enterText(
          find.byKey(const ValueKey('work-item-dates-start-input')),
          '2026-11-02',
        );
        await tester.enterText(
          find.byKey(const ValueKey('work-item-dates-due-input')),
          '2026-11-09',
        );
      } else {
        final choice = kind == AiWorkItemWriteKind.status
            ? find.byKey(
                const ValueKey(
                  'work-item-status-choice-${WorkItemStatusFixture.statusDoing}',
                ),
              )
            : find.byKey(
                const ValueKey('work-item-health-choice-needsAttention'),
              );
        final scrollable = kind == AiWorkItemWriteKind.status
            ? find.byType(Scrollable).last
            : find.descendant(
                of: find.byKey(const ValueKey('work-item-health-scroll')),
                matching: find.byType(Scrollable),
              );
        await tester.scrollUntilVisible(choice, 120, scrollable: scrollable);
        await tester.tap(choice);
      }
      await tester.pump();
      final held = Completer<void>();
      switch (kind) {
        case AiWorkItemWriteKind.status:
          fixture.status.holdBeforeApply = held;
        case AiWorkItemWriteKind.dates:
          fixture.dates.holdBeforeApply = held;
        case AiWorkItemWriteKind.health:
          fixture.holdBeforeApply = held;
      }
      await tester.tap(find.byKey(ValueKey('work-item-${kind.name}-save')));
      final registry = _registry(api, fixture.account.key);
      await pumpUntil(tester, () => registry.isActive(_projectGid));
      await pumpUntil(
        tester,
        () => switch (kind) {
          AiWorkItemWriteKind.status => fixture.status.awaitingApply,
          AiWorkItemWriteKind.dates => fixture.dates.awaitingApply,
          AiWorkItemWriteKind.health => fixture.awaitingApply,
        },
      );
      final counts = (
        fixture.status.mutationInputs.length,
        fixture.dates.datesMutationRequests,
        fixture.healthMutationRequests,
      );
      final operation = switch (kind) {
        AiWorkItemWriteKind.status => 'updateWorkItemStatus',
        AiWorkItemWriteKind.dates => 'updateWorkItemDates',
        AiWorkItemWriteKind.health => 'updateWorkItemHealthStatus',
      };
      final expectedReason = switch (kind) {
        AiWorkItemWriteKind.status => 'statusNotStarted',
        AiWorkItemWriteKind.dates => 'datesConflict',
        AiWorkItemWriteKind.health => 'healthConflict',
      };
      final request = writes.AiWriteRequest(
        operationId: operation,
        executionId: 'ui-${kind.name}',
        scope: AiWriteScope(
          accountKey: fixture.account.key,
          grants: const [
            AiScopeGrant(
              kind: AiScopeKind.workItem,
              projectId: 42,
              projectPath: 'studio/mobile',
              iid: 17,
            ),
          ],
        ),
        arguments: {
          'projectId': 42,
          'iid': 17,
          if (kind == AiWorkItemWriteKind.status)
            'candidateId': WorkItemStatusFixture.statusDoing,
          if (kind == AiWorkItemWriteKind.dates) ...{
            'mode': 'manual',
            'startDate': '2026-11-03',
          },
          if (kind == AiWorkItemWriteKind.health) 'healthStatus': 'atRisk',
        },
      );
      final port = writes.GitLabAiWritePort(
        api,
        accountKey: fixture.account.key,
        workItemWriteRegistry: registry,
      );
      await tester.runAsync(() async {
        await expectLater(
          port.prepare(request),
          throwsA(
            isA<writes.AiWriteRefused>().having(
              (failure) => failure.reason,
              'reason',
              expectedReason,
            ),
          ),
        );
      });
      expect((
        fixture.status.mutationInputs.length,
        fixture.dates.datesMutationRequests,
        fixture.healthMutationRequests,
      ), counts);
      held.complete();
      await pumpUntil(tester, () => !registry.isActive(_projectGid));
      await settleNetworkWidgets(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleNetworkWidgets(tester);
    });
  }

  test(
    'each kind settles once and uncertain preserves confirmed revision floor',
    () {
      final fixture = WorkItemStatusFixture();
      addTearDown(fixture.closeAll);
      final registry = _registry(fixture.api, fixture.account.key);
      final floor = DateTime.utc(2026, 10, 22);
      final misleading = DateTime.utc(2026, 10, 25);
      for (final kind in AiWorkItemWriteKind.values) {
        final first = registry.tryStart(_gid, kind)!;
        registry.settle(first, AiWorkItemWriteResult.confirmed, floor);
        final later = registry.tryStart(_gid, kind)!;
        registry.settle(first, AiWorkItemWriteResult.uncertain, null);
        expect(registry.isActive(_gid), isTrue);
        registry.settle(later, AiWorkItemWriteResult.uncertain, misleading);
        expect(aiWorkspaceWriteFreshnessForTesting(fixture.api, _gid, kind), (
          revision: floor,
          confirmed: false,
          knownNotApplied: false,
        ));
        registry.settle(later, AiWorkItemWriteResult.confirmed, misleading);
        expect(aiWorkspaceWriteFreshnessForTesting(fixture.api, _gid, kind), (
          revision: floor,
          confirmed: false,
          knownNotApplied: false,
        ));
        final cancel = registry.tryStart(_gid, kind)!;
        registry.settle(cancel, AiWorkItemWriteResult.notSent, null);
        registry.settle(cancel, AiWorkItemWriteResult.confirmed, misleading);
        expect(
          aiWorkspaceWriteFreshnessForTesting(
            fixture.api,
            _gid,
            kind,
          )?.revision,
          floor,
        );
        expect(registry.isActive(_gid), isFalse);
      }
    },
  );
}
