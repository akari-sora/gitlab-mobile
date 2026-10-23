import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'fx_coord_support.dart';

const _scope = AiWriteScope(
  accountKey: 'https://example.com/gitlab#7',
  grants: [AiScopeGrant(kind: AiScopeKind.project, projectId: 42, projectPath: 'studio/mobile-workspace')],
);

AiWriteRequest _request(String operation, Map<String, Object?> arguments) => AiWriteRequest(
  operationId: operation,
  executionId: 'mr6b3-freshness-$operation',
  scope: _scope,
  arguments: arguments,
);

void main() {
  test('all thirteen project graph operations retain exactly one project freshness read', () async {
    final harness = await StackHarness.create();
    addTearDown(harness.dispose);
    for (final operation in [
      'updateWorkItemState', 'updateWorkItemStatus', 'updateWorkItemDates',
      'updateWorkItemHealthStatus', 'updateWorkItemAssignees',
      'updateWorkItemMilestone', 'updateWorkItemWeight',
      'createWorkItemActivityComment', 'createWorkItemActivityReply',
      'deleteWorkItemActivityNote', 'setWorkItemActivityNoteReaction',
      'setWorkItemNotifications', 'setIncidentStatus',
    ]) {
      final before = harness.server.adapter.requests.length;
      final freshness = await harness.controller.readWriteFreshnessForTesting(
        _request(operation, {'projectId': 42, 'iid': 5}),
      );
      final reads = harness.server.adapter.requests.skip(before).toList();
      expect(reads, hasLength(1), reason: operation);
      expect(reads.single.method, 'GET', reason: operation);
      expect(reads.single.uri.path, '/gitlab/api/v4/projects/42', reason: operation);
      expect(freshness.visibilityUnreadable, isFalse, reason: operation);
      expect(freshness.currentFields, isEmpty, reason: operation);
      expect(freshness.provenance, isEmpty, reason: operation);
      expect(freshness.updatedAt, isNull, reason: operation);
    }
    expect(harness.provider.adapter.requests, isEmpty);
    expect(harness.server.mutations, isEmpty);
  });

  test('both account-todo operations retain zero freshness HTTP requests', () async {
    final harness = await StackHarness.create(origin: const AiGeneralOrigin());
    addTearDown(harness.dispose);
    for (final operation in ['snoozeTodo', 'unsnoozeTodo']) {
      final before = harness.server.adapter.requests.length;
      final freshness = await harness.controller.readWriteFreshnessForTesting(
        _request(operation, {'todoId': 7, if (operation == 'snoozeTodo') 'until': '2030-01-01T00:00:00Z'}),
      );
      expect(harness.server.adapter.requests, hasLength(before));
      expect(freshness.currentFields, isEmpty);
      expect(freshness.provenance, isEmpty);
    }
    expect(harness.provider.adapter.requests, isEmpty);
    expect(harness.server.mutations, isEmpty);
  });

  test('invalid project coordinates fail before freshness I/O', () async {
    final harness = await StackHarness.create(origin: const AiGeneralOrigin());
    addTearDown(harness.dispose);
    final before = harness.server.adapter.requests.length;
    await expectLater(
      harness.controller.readWriteFreshnessForTesting(_request('updateWorkItemState', {'projectId': 0, 'iid': 5})),
      throwsA(isA<AiJournalException>().having((error) => error.reason, 'reason', 'invalidArguments')),
    );
    expect(harness.server.adapter.requests, hasLength(before));
  });
}
