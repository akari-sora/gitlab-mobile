import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_attribute_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import '../tool/emulator_ui.dart';

Future<WorkItemGraphDetail> _detail(EmulatorQaFixture fixture, bool group) =>
    group
    ? fixture.api.namespaceWorkItem(
        'qa/synthetic-group',
        41,
        expectedNamespaceId: 'gid://gitlab/Group/84',
      )
    : fixture.api.projectWorkItem(fixture.project, 31);

Future<WorkItemMilestoneAccess> _open(
  EmulatorQaFixture fixture,
  bool group,
) async => fixture.api.workItemMilestone(
  await _detail(fixture, group),
  expectedUserId: fixture.account.user.id,
);

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((value) => value.kind, 'kind', kind);

void main() {
  for (final group in [false, true]) {
    final scope = group ? 'group' : 'project';

    test('$scope fixture exposes closed expired current milestone', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);

      final detail = await _detail(fixture, group);
      expect(detail.widgetTypes, contains('MILESTONE'));
      final access = await fixture.api.workItemMilestone(
        detail,
        expectedUserId: fixture.account.user.id,
      );

      expect(access.canSetMilestone, isTrue);
      expect(access.snapshot.milestone!.state, 'CLOSED');
      expect(access.snapshot.milestone!.title, contains('expired'));
      expect(access.snapshot.milestoneExpired, isTrue);
      expect(
        access.snapshot.milestone!.webPath,
        group
            ? '/groups/qa/synthetic-group/-/milestones/15'
            : '/groups/studio/-/milestones/5',
      );
      expect(
        access.target!.currentSelection.milestone!.id,
        endsWith(group ? '/915' : '/905'),
      );
      expect(fixture.unhandled, isEmpty);
    });

    test('$scope fixture pages and searches active candidates', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final access = await _open(fixture, group);

      final first = await fixture.api.workItemMilestoneChoices(access.target!);
      expect(first.items, hasLength(50));
      expect(first.continuation, isNotNull);
      expect(
        first.items.every((choice) => choice.milestone.state == 'ACTIVE'),
        isTrue,
      );
      expect(first.items.any((choice) => choice.expired), isTrue);
      for (final choice in first.items) {
        final milestone = choice.milestone;
        final expectedPath = milestone.project == null
            ? '/groups/${milestone.group!.fullPath}/-/milestones/${milestone.iid}'
            : '/${milestone.project!.fullPath}/-/milestones/${milestone.iid}';
        expect(milestone.webPath, expectedPath);
      }
      if (group) {
        expect(
          first.items.any((choice) => choice.milestone.group?.fullPath == 'qa'),
          isTrue,
        );
      }
      final second = await fixture.api.workItemMilestoneChoices(
        access.target!,
        continuation: first.continuation,
      );
      expect(second.items, hasLength(15));
      expect(second.continuation, isNull);
      final ids = <String>{
        ...first.items.map((choice) => choice.milestone.id),
        ...second.items.map((choice) => choice.milestone.id),
      };
      expect(ids, hasLength(65));

      final searched = await fixture.api.workItemMilestoneChoices(
        access.target!,
        search: 'Release 02',
      );
      expect(searched.items, hasLength(1));
      expect(searched.items.single.milestone.title, contains('Release 02'));
      expect(fixture.workItemMilestonePickerReads, hasLength(3));
      expect(
        fixture.workItemMilestonePickerReads[1]['after'],
        'qa-milestones:50',
      );
      expect(fixture.workItemMilestonePickerReads[2]['search'], 'Release 02');
      expect(fixture.unhandled, isEmpty);
    });

    test(
      '$scope fixture assigns and clears with exact mutation input',
      () async {
        final fixture = EmulatorQaFixture();
        addTearDown(fixture.api.close);
        final detail = await _detail(fixture, group);
        final access = await fixture.api.workItemMilestone(
          detail,
          expectedUserId: fixture.account.user.id,
        );
        final page = await fixture.api.workItemMilestoneChoices(access.target!);
        final selected = page.items[1];

        final assigned = await fixture.api.updateWorkItemMilestone(
          access.target!,
          selection: selected.selection,
        );
        expect(assigned.snapshot.milestone!.id, selected.milestone.id);
        expect(fixture.workItemMilestoneEvents, hasLength(1));
        expect(fixture.workItemMilestoneEvents.single['input'], {
          'id': detail.summary.id,
          'milestoneWidget': {'milestoneId': selected.milestone.id},
        });
        final assignedAttribute = await fixture.api.workItemAttribute(
          detail.summary,
          WorkItemAttributeKind.milestone,
        );
        expect(
          (assignedAttribute.value! as WorkItemMilestoneAttribute)
              .milestone!
              .id,
          selected.milestone.id,
        );

        final clearAccess = await _open(fixture, group);
        final cleared = await fixture.api.updateWorkItemMilestone(
          clearAccess.target!,
          selection: clearAccess.target!.clearSelection,
        );
        expect(cleared.snapshot.milestone, isNull);
        expect(fixture.workItemMilestoneEvents, hasLength(2));
        expect(fixture.workItemMilestoneEvents.last['input'], {
          'id': detail.summary.id,
          'milestoneWidget': {'milestoneId': null},
        });
        final clearedAttribute = await fixture.api.workItemAttribute(
          detail.summary,
          WorkItemAttributeKind.milestone,
        );
        expect(
          (clearedAttribute.value! as WorkItemMilestoneAttribute).milestone,
          isNull,
        );
        expect(fixture.unhandled, isEmpty);
      },
    );

    test('$scope candidate failure still permits explicit clear', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final access = await _open(fixture, group);
      fixture.failNextWorkItemMilestoneCandidates = true;

      await expectLater(
        fixture.api.workItemMilestoneChoices(access.target!),
        throwsA(isA<ApiFailure>()),
      );
      final cleared = await fixture.api.updateWorkItemMilestone(
        access.target!,
        selection: access.target!.clearSelection,
      );
      expect(cleared.snapshot.milestone, isNull);
      expect(fixture.workItemMilestoneEvents, hasLength(1));
    });

    test('$scope revoked metadata permission blocks mutation', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final access = await _open(fixture, group);
      fixture.workItemMilestoneMetadataAllowed = false;

      await expectLater(
        fixture.api.updateWorkItemMilestone(
          access.target!,
          selection: access.target!.clearSelection,
        ),
        throwsA(_failure(FailureKind.forbidden)),
      );
      expect(fixture.workItemMilestoneEvents, isEmpty);
      expect((await _open(fixture, group)).target, isNull);
    });

    test('$scope changed revision blocks mutation', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final access = await _open(fixture, group);
      fixture.reviseWorkItemMilestone(group: group);

      await expectLater(
        fixture.api.updateWorkItemMilestone(
          access.target!,
          selection: access.target!.clearSelection,
        ),
        throwsA(_failure(FailureKind.conflict)),
      );
      expect(fixture.workItemMilestoneEvents, isEmpty);
    });

    test('$scope uncertain acknowledgement persists without replay', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final access = await _open(fixture, group);
      fixture.failNextWorkItemMilestoneAcknowledgement = true;

      await expectLater(
        fixture.api.updateWorkItemMilestone(
          access.target!,
          selection: access.target!.clearSelection,
        ),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      await expectLater(
        fixture.api.updateWorkItemMilestone(
          access.target!,
          selection: access.target!.clearSelection,
        ),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(fixture.workItemMilestoneEvents, hasLength(1));
      expect((await _open(fixture, group)).snapshot.milestone, isNull);
      expect(fixture.unhandled, isEmpty);
    });
  }
}
