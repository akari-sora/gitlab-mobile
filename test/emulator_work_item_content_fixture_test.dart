import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
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

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((value) => value.kind, 'kind', kind);

Future<WorkItemContentAccess> _open(
  EmulatorQaFixture fixture,
  bool group,
) async => fixture.api.workItemContent(
  await _detail(fixture, group),
  expectedUserId: fixture.account.user.id,
);

void main() {
  for (final group in [false, true]) {
    final scope = group ? 'group' : 'project';
    test('$scope editor fixture saves exact title and Markdown', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final detail = await _detail(fixture, group);
      expect(fixture.workItemContentReads, isEmpty);
      final access = await fixture.api.workItemContent(
        detail,
        expectedUserId: fixture.account.user.id,
      );
      const markdown = '  # Synthetic updated\n\n* exact Markdown *  \n';
      final confirmed = await fixture.api.updateWorkItemContent(
        access.target!,
        title: 'Updated $scope item',
        description: markdown,
      );
      expect(confirmed.snapshot.summary.title, 'Updated $scope item');
      expect(confirmed.snapshot.rawDescription, markdown);
      expect(fixture.workItemContentEvents, hasLength(1));
      final event = fixture.workItemContentEvents.single;
      expect(event['group'], group);
      expect(event['accepted'], isTrue);
      expect(event['descriptionWidget'], {'description': markdown});
      expect(
        (await _detail(fixture, group)).descriptionWidget!.description,
        markdown,
      );
      expect(fixture.unhandled, isEmpty);
      expect(
        fixture.adapter.requests.every((r) => r.uri.host == 'qa.invalid'),
        isTrue,
      );
    });
    test('$scope content fixture no-op sends no mutation', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final access = await _open(fixture, group);
      await fixture.api.updateWorkItemContent(
        access.target!,
        title: access.snapshot.summary.title,
        description: access.snapshot.rawDescription,
      );
      expect(fixture.workItemContentEvents, isEmpty);
      await expectLater(
        fixture.api.updateWorkItemContent(
          access.target!,
          title: 'Cannot reuse',
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(fixture.workItemContentEvents, isEmpty);
    });
    test('$scope absent description fixture allows only title', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      fixture.workItemDescriptionPresent[group] = false;
      final access = await _open(fixture, group);
      expect(
        access.snapshot.descriptionAvailability,
        WorkItemDescriptionAvailability.absent,
      );
      final confirmed = await fixture.api.updateWorkItemContent(
        access.target!,
        title: 'Title-only $scope',
      );
      expect(confirmed.snapshot.summary.title, 'Title-only $scope');
      expect(fixture.workItemContentEvents.single['descriptionWidget'], isNull);
      expect(fixture.unhandled, isEmpty);
    });
    test('$scope uncertain content persists and prevents replay', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final access = await _open(fixture, group);
      fixture.failNextWorkItemContentAcknowledgement = true;
      await expectLater(
        fixture.api.updateWorkItemContent(
          access.target!,
          title: 'Applied but uncertain $scope',
        ),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      await expectLater(
        fixture.api.updateWorkItemContent(
          access.target!,
          title: 'Applied but uncertain $scope',
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(fixture.workItemContentEvents, hasLength(1));
      expect(
        (await _open(fixture, group)).snapshot.summary.title,
        'Applied but uncertain $scope',
      );
      expect(fixture.unhandled, isEmpty);
    });
    test('$scope changed server version blocks content mutation', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final access = await _open(fixture, group);
      fixture.reviseWorkItemContent(group: group);
      await expectLater(
        fixture.api.updateWorkItemContent(access.target!, title: 'Stale edit'),
        throwsA(_failure(FailureKind.conflict)),
      );
      expect(fixture.workItemContentEvents, isEmpty);
      expect(
        (await _open(fixture, group)).snapshot.summary.title,
        contains('concurrent'),
      );
    });
    test('$scope revoked edit permission blocks content mutation', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final access = await _open(fixture, group);
      fixture.workItemContentAllowed = false;
      await expectLater(
        fixture.api.updateWorkItemContent(access.target!, title: 'Denied edit'),
        throwsA(_failure(FailureKind.forbidden)),
      );
      expect(fixture.workItemContentEvents, isEmpty);
      expect((await _open(fixture, group)).target, isNull);
    });
    test('$scope anonymous content preflight sends no mutation', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final access = await _open(fixture, group);
      fixture.workItemContentAuthenticated = false;
      await expectLater(
        fixture.api.updateWorkItemContent(
          access.target!,
          title: 'Expired edit',
        ),
        throwsA(_failure(FailureKind.unauthenticated)),
      );
      expect(fixture.workItemContentEvents, isEmpty);
      await expectLater(
        _open(fixture, group),
        throwsA(_failure(FailureKind.unauthenticated)),
      );
    });
    test('$scope server denial does not mutate fixture content', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final access = await _open(fixture, group);
      fixture.workItemContentWritesAllowed = false;
      await expectLater(
        fixture.api.updateWorkItemContent(
          access.target!,
          title: 'Backend denied',
        ),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(fixture.workItemContentEvents, hasLength(1));
      expect(fixture.workItemContentEvents.single['accepted'], isFalse);
      expect(
        fixture.workItemContentTitles[group],
        access.snapshot.summary.title,
      );
      expect(fixture.unhandled, isEmpty);
    });
  }
}
