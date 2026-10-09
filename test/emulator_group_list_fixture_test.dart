import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_state_models.dart';

import '../tool/emulator_ui.dart';

void main() {
  test(
    'group fixture exercises descendants, filters and bounded pages',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      const path = 'qa/synthetic-group';
      const filter = GroupWorkItemListFilter(includeDescendants: true);
      final first = await fixture.api.groupWorkItems(path, filter: filter);
      expect(first.items, hasLength(20));
      expect(first.items.any((item) => item.project != null), isTrue);
      final next = await fixture.api.groupWorkItems(
        path,
        filter: first.filter,
        previousFilter: first.filter,
        expectedGroupId: first.group.id,
        after: first.nextCursor,
      );
      final rows = [...first.items, ...next.items];
      expect(rows, hasLength(30));
      expect(rows.map((item) => item.id).toSet(), hasLength(30));
      expect(rows.map((item) => item.iid).toSet().length, lessThan(30));

      final root = await fixture.api.groupWorkItems(path);
      expect(root.items, hasLength(5));
      expect(
        root.items.every((item) => item.namespace!.fullPath == path),
        isTrue,
      );
      final filtered = await fixture.api.groupWorkItems(
        path,
        filter: const GroupWorkItemListFilter(
          includeDescendants: true,
          state: GroupWorkItemState.closed,
          search: 'project',
          sort: GroupWorkItemSort.createdAsc,
          typeId: 'gid://gitlab/WorkItems::Type/qa-project',
          typeNamespace: GraphResourceRef(
            id: 'gid://gitlab/Group/84',
            fullPath: path,
          ),
        ),
      );
      expect(filtered.items, hasLength(10));
      expect(filtered.items.every((item) => item.state == 'CLOSED'), isTrue);
      expect(
        filtered.items.first.createdAt.isBefore(filtered.items.last.createdAt),
        isTrue,
      );
      final detail = await fixture.api.namespaceWorkItem(
        filtered.items.first.namespace!.fullPath,
        filtered.items.first.iid,
        expectedNamespaceId: filtered.items.first.namespace!.id,
      );
      expect(detail.summary.id, filtered.items.first.id);
      expect(fixture.unhandled, isEmpty);
      expect(fixture.workItemStateEvents, isEmpty);
      expect(
        fixture.adapter.requests.every(
          (request) => request.uri.host == 'qa.invalid',
        ),
        isTrue,
      );
    },
  );

  test(
    'generic root and descendant rows resolve matching read-only state',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      const path = 'qa/synthetic-group';
      final first = await fixture.api.groupWorkItems(
        path,
        filter: const GroupWorkItemListFilter(includeDescendants: true),
      );
      final second = await fixture.api.groupWorkItems(
        path,
        filter: first.filter,
        previousFilter: first.filter,
        expectedGroupId: first.group.id,
        after: first.nextCursor,
      );
      final rows = [...first.items, ...second.items];
      final genericRoot = rows.firstWhere(
        (item) =>
            item.namespace!.fullPath == path &&
            item.id != 'gid://gitlab/WorkItem/1041',
      );
      final descendantGroup = rows.firstWhere(
        (item) => item.namespace!.fullPath == 'qa/synthetic-group/child-group',
      );
      final descendantProject = rows.firstWhere((item) => item.project != null);

      for (final summary in [genericRoot, descendantGroup, descendantProject]) {
        final detail = await fixture.api.namespaceWorkItem(
          summary.namespace!.fullPath,
          summary.iid,
          expectedNamespaceId: summary.namespace!.id,
        );
        final state = await fixture.api.workItemState(summary);
        expect(detail.summary.id, summary.id);
        expect(state.id, summary.id);
        expect(
          state.state,
          summary.state == 'OPEN' ? WorkItemState.open : WorkItemState.closed,
        );
        expect(state.canUpdate, isFalse);
      }

      await expectLater(
        fixture.api.updateWorkItemState(
          genericRoot,
          WorkItemStateEvent.close,
          expectedUpdatedAt: genericRoot.updatedAt,
        ),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.forbidden,
          ),
        ),
      );
      expect(fixture.workItemStateEvents, isEmpty);
      expect(
        fixture.adapter.requests.where((request) {
          final data = request.data;
          return data is Map &&
              data['query'] is String &&
              (data['query'] as String).startsWith(
                'mutation MobileUpdateWorkItemState',
              );
        }),
        isEmpty,
      );
      expect(fixture.unhandled, isEmpty);
    },
  );

  test('unknown synthetic Work Item state remains a 404', () async {
    final fixture = EmulatorQaFixture();
    addTearDown(fixture.api.close);
    final page = await fixture.api.groupWorkItems(
      'qa/synthetic-group',
      filter: const GroupWorkItemListFilter(includeDescendants: true),
    );
    final known = page.items.first;
    final unknown = WorkItemGraphSummary(
      id: 'gid://gitlab/WorkItem/qa-list-unknown',
      iid: known.iid,
      title: known.title,
      state: known.state,
      createdAt: known.createdAt,
      updatedAt: known.updatedAt,
      project: known.project,
      namespace: known.namespace,
      type: known.type,
    );

    await expectLater(
      fixture.api.workItemState(unknown),
      throwsA(
        isA<ApiFailure>().having(
          (failure) => failure.kind,
          'kind',
          FailureKind.invisible,
        ),
      ),
    );
    expect(fixture.unhandled, ['POST MobileWorkItemState']);
  });
}
