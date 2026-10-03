import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';

import '../tool/emulator_ui.dart';

Future<WorkItemGraphSummary> _summary(
  EmulatorQaFixture fixture,
  bool group,
) async =>
    (group
            ? await fixture.api.namespaceWorkItem(
                'qa/synthetic-group',
                41,
                expectedNamespaceId: 'gid://gitlab/Group/84',
              )
            : await fixture.api.projectWorkItem(fixture.project, 31))
        .summary;

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind);

void main() {
  for (final group in [false, true]) {
    final scope = group ? 'group' : 'project';
    test('$scope subscription fixture uses explicit desired states', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final summary = await _summary(fixture, group);
      expect(fixture.workItemNotificationReads, isEmpty);
      var access = await fixture.api.workItemNotifications(
        summary,
        expectedUserId: fixture.account.user.id,
      );
      expect(access.subscribed, isFalse);
      expect(access.canAttemptSubscription, isTrue);
      access = await fixture.api.setWorkItemNotifications(
        access.target!,
        subscribed: true,
      );
      expect(access.subscribed, isTrue);
      access = await fixture.api.setWorkItemNotifications(
        access.target!,
        subscribed: false,
      );
      expect(access.subscribed, isFalse);
      expect(fixture.workItemNotificationEvents, hasLength(2));
      expect(
        fixture.workItemNotificationEvents.every(
          (event) => event['group'] == group && event['accepted'] == true,
        ),
        isTrue,
      );
      await fixture.api.setWorkItemNotifications(
        access.target!,
        subscribed: false,
      );
      expect(fixture.workItemNotificationEvents, hasLength(2));
      expect(fixture.unhandled, isEmpty);
      expect(
        fixture.adapter.requests.every(
          (request) => request.uri.host == 'qa.invalid',
        ),
        isTrue,
      );
    });

    test(
      '$scope uncertain fixture persists state and prevents replay',
      () async {
        final fixture = EmulatorQaFixture();
        addTearDown(fixture.api.close);
        final summary = await _summary(fixture, group);
        final access = await fixture.api.workItemNotifications(summary);
        fixture.failNextWorkItemNotificationAcknowledgement = true;
        await expectLater(
          fixture.api.setWorkItemNotifications(
            access.target!,
            subscribed: true,
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(fixture.workItemNotificationSubscribed[group], isTrue);
        await expectLater(
          fixture.api.setWorkItemNotifications(
            access.target!,
            subscribed: true,
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(fixture.workItemNotificationEvents, hasLength(1));
        final refreshed = await fixture.api.workItemNotifications(summary);
        expect(refreshed.subscribed, isTrue);
        expect(fixture.unhandled, isEmpty);
      },
    );

    test('$scope anonymous preflight cannot send a mutation', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final summary = await _summary(fixture, group);
      final access = await fixture.api.workItemNotifications(summary);
      fixture.workItemNotificationAuthenticated = false;
      await expectLater(
        fixture.api.setWorkItemNotifications(access.target!, subscribed: true),
        throwsA(isA<ApiFailure>()),
      );
      expect(fixture.workItemNotificationEvents, isEmpty);
      final anonymous = await fixture.api.workItemNotifications(summary);
      expect(anonymous.canAttemptSubscription, isFalse);
      expect(anonymous.target, isNull);
      expect(fixture.unhandled, isEmpty);
    });

    test('$scope denied mutation is rejected without changing state', () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final summary = await _summary(fixture, group);
      final access = await fixture.api.workItemNotifications(summary);
      fixture.workItemNotificationWritesAllowed = false;
      await expectLater(
        fixture.api.setWorkItemNotifications(access.target!, subscribed: true),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(fixture.workItemNotificationSubscribed[group], isFalse);
      expect(fixture.workItemNotificationEvents, hasLength(1));
      expect(fixture.workItemNotificationEvents.single['accepted'], isFalse);
      expect(fixture.unhandled, isEmpty);
    });
  }
}
