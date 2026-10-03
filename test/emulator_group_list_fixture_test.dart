import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

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
}
