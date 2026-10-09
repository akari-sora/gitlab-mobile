import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';

void main() {
  test('activity controls expose fixed GraphQL enum values', () {
    expect(WorkItemActivityFilter.values.map((value) => value.graphValue), [
      'ALL_NOTES',
      'ONLY_COMMENTS',
      'ONLY_ACTIVITY',
    ]);
    expect(WorkItemActivityOrder.values.map((value) => value.graphValue), [
      'CREATED_ASC',
      'CREATED_DESC',
    ]);
  });

  test('activity connection preserves unavailable and present-empty', () {
    final unavailable = WorkItemActivityConnection<WorkItemActivityNote>(
      availability: WorkItemActivityConnectionAvailability.unavailable,
      items: const [],
    );
    final empty = WorkItemActivityConnection<WorkItemActivityNote>(
      availability: WorkItemActivityConnectionAvailability.present,
      items: const [],
    );

    expect(
      unavailable.availability,
      WorkItemActivityConnectionAvailability.unavailable,
    );
    expect(empty.availability, WorkItemActivityConnectionAvailability.present);
    expect(unavailable.items, isEmpty);
    expect(empty.items, isEmpty);
  });

  test('activity collections are immutable', () {
    final source = <WorkItemActivityNote>[];
    final connection = WorkItemActivityConnection<WorkItemActivityNote>(
      availability: WorkItemActivityConnectionAvailability.present,
      items: source,
    );
    source.add(
      WorkItemActivityNote(
        id: 'gid://gitlab/Note/1',
        system: false,
        systemNoteIconName: null,
        body: 'Synthetic',
        createdAt: DateTime.utc(2026, 10, 1),
        updatedAt: DateTime.utc(2026, 10, 1),
        author: null,
      ),
    );

    expect(connection.items, isEmpty);
    expect(() => connection.items.add(source.single), throwsUnsupportedError);
  });
}
