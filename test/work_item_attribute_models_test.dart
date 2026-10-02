import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/work_item_attribute_models.dart';

void main() {
  test('attribute models preserve unavailable and zero as distinct values', () {
    const unavailable = WorkItemWeightAttribute(
      weight: null,
      rolledUpWeight: null,
      rolledUpCompletedWeight: null,
    );
    const zero = WorkItemWeightAttribute(
      weight: 0,
      rolledUpWeight: 0,
      rolledUpCompletedWeight: 0,
    );
    const time = WorkItemTimeTrackingAttribute(
      timeEstimate: null,
      totalTimeSpent: 0,
      humanReadable: WorkItemHumanReadableTime(
        timeEstimate: null,
        totalTimeSpent: '0m',
      ),
    );

    expect(unavailable.weight, isNull);
    expect(zero.weight, 0);
    expect(time.timeEstimate, isNull);
    expect(time.totalTimeSpent, 0);
    expect(time.humanReadable!.totalTimeSpent, '0m');
  });

  test('calendar dates remain UTC values for display without toLocal', () {
    final date = DateTime.utc(2026, 9, 3);
    final milestone = WorkItemMilestoneValue(
      id: 'gid://gitlab/Milestone/server-owned',
      iid: 4,
      title: 'Synthetic milestone',
      state: 'active',
      webPath: '/team/example/-/milestones/4',
      dueDate: date,
      startDate: null,
      project: null,
      group: const WorkItemAttributeOwnerRef(id: null, fullPath: 'team'),
    );

    expect(milestone.dueDate!.isUtc, isTrue);
    expect(milestone.dueDate!.toIso8601String(), '2026-09-03T00:00:00.000Z');
    expect(milestone.group!.id, isNull);
  });
}
