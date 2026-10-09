import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

void main() {
  test(
    'group list filters are immutable value objects with legacy defaults',
    () {
      const defaults = GroupWorkItemListFilter();
      const same = GroupWorkItemListFilter();
      const changed = GroupWorkItemListFilter(
        includeDescendants: true,
        state: GroupWorkItemState.opened,
        search: '  roadmap  ',
        sort: GroupWorkItemSort.updatedAsc,
        typeId: 'gid://gitlab/WorkItems::Type/server-type',
        typeNamespace: GraphResourceRef(
          id: 'gid://gitlab/Group/server-group',
          fullPath: 'gitlab-org',
        ),
      );
      const sameChanged = GroupWorkItemListFilter(
        includeDescendants: true,
        state: GroupWorkItemState.opened,
        search: '  roadmap  ',
        sort: GroupWorkItemSort.updatedAsc,
        typeId: 'gid://gitlab/WorkItems::Type/server-type',
        typeNamespace: GraphResourceRef(
          id: 'gid://gitlab/Group/server-group',
          fullPath: 'gitlab-org',
        ),
      );

      expect(defaults.includeDescendants, isFalse);
      expect(defaults.state, GroupWorkItemState.all);
      expect(defaults.search, isEmpty);
      expect(defaults.sort, GroupWorkItemSort.createdDesc);
      expect(defaults.typeId, isNull);
      expect(defaults.typeNamespace, isNull);
      expect(defaults, same);
      expect(defaults.hashCode, same.hashCode);
      expect(changed, isNot(defaults));
      expect(changed, sameChanged);
      expect(changed.hashCode, sameChanged.hashCode);
    },
  );

  test('bounded connection and pages expose partial state without totals', () {
    const connection = BoundedGraphConnection<int>(
      items: [1, 2],
      isPartial: true,
      nextCursor: 'opaque',
    );
    const page = WorkItemGraphPage(items: [], nextCursor: 'opaque');
    const complete = WorkItemGraphPage(items: [], nextCursor: null);

    expect(connection.items, [1, 2]);
    expect(connection.isPartial, isTrue);
    expect(page.isPartial, isTrue);
    expect(complete.isPartial, isFalse);
  });

  test('work item type remains separate opaque display metadata', () {
    const type = WorkItemGraphType(
      id: 'gid://gitlab/FutureType/server-owned',
      name: 'Future planning item',
    );
    const capability = WorkItemTypeCapability(
      type: type,
      enabled: true,
      isGroupWorkItemType: true,
      widgetTypes: {'FUTURE_WIDGET'},
    );

    expect(capability.type.name, 'Future planning item');
    expect(capability.widgetTypes, {'FUTURE_WIDGET'});
  });

  test('null widget connection is distinct from a loaded empty connection', () {
    const unavailable = WorkItemAssigneesWidget(assignees: null);
    const empty = WorkItemAssigneesWidget(
      assignees: BoundedGraphConnection(
        items: <WorkItemGraphAssignee>[],
        isPartial: false,
        nextCursor: null,
      ),
    );

    expect(unavailable.assignees, isNull);
    expect(empty.assignees, isNotNull);
    expect(empty.assignees!.items, isEmpty);
  });
}
