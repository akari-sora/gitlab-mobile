import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

void main() {
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
