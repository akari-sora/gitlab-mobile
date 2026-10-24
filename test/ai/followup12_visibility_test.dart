import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';

import '../support/fake_adapter.dart';
import 'fx_coord_support.dart';

Project _project(String visibility) => Project.fromJson({
  'id': 42,
  'name': 'Synthetic',
  'path_with_namespace': 'studio/mobile-workspace',
  'visibility': visibility,
  'default_branch': 'main',
});

port.AiWriteRequest _request(
  StackHarness h, {
  int project = 42,
  int iid = 6,
  String operation = 'updateIssue',
  Map<String, Object?>? fields,
}) => port.AiWriteRequest(
  operationId: operation,
  executionId: 'visibility-check',
  scope: AiWriteScope(
    accountKey: h.account,
    grants: [AiScopeGrant(kind: AiScopeKind.project, projectId: project)],
  ),
  arguments: {
    'projectId': project,
    'iid': iid,
    'fields': fields ?? {'title': 'Updated synthetic title'},
  },
);

void main() {
  test(
    'visibility pollution compares source and target restrictions',
    () async {
      final h = await StackHarness.create(
        origin: AiWorkItemOrigin(
          project: _project('internal'),
          kind: AiWorkItemKind.issue,
          iid: 5,
          title: 'Source',
        ),
      );
      addTearDown(h.dispose);
      for (final (visibility, polluted) in [
        ('private', false),
        ('internal', false),
        ('public', true),
      ]) {
        h.server.overrides['GET projects/43'] = (_) => jsonResponse({
          'id': 43,
          'path_with_namespace': 'studio/target',
          'visibility': visibility,
        });
        h.server.overrides['GET projects/43/issues/6'] = (_) => jsonResponse({
          'id': 106,
          'iid': 6,
          'project_id': 43,
          'confidential': false,
        });
        final fresh = await h.controller.readWriteFreshnessForTesting(
          _request(h, project: 43),
        );
        expect(fresh.visibilityUnreadable, isFalse, reason: visibility);
        expect(fresh.polluted, polluted, reason: visibility);
      }
      expect(h.server.mutations, isEmpty);
    },
  );

  test(
    'initial confidential issue requires confirmation before any read tool',
    () async {
      final h = await StackHarness.create(
        origin: AiWorkItemOrigin(
          project: _project('private'),
          kind: AiWorkItemKind.issue,
          iid: 5,
          title: 'Confidential source',
        ),
        level: AiAutonomyLevel.conversationGrant,
        writeScope: (server) => AiWriteScope(
          accountKey: server.workspace.account.key,
          grants: const [
            AiScopeGrant(kind: AiScopeKind.project, projectId: 42),
          ],
        ),
        configure: (server) {
          server.overrides['GET projects/42/issues/5'] = (_) => jsonResponse({
            ...server.workspace.issue(5, 'Confidential source'),
            'confidential': true,
          });
          server.overrides['GET projects/42/issues/6'] = (_) => jsonResponse({
            ...server.workspace.issue(6, 'Ordinary target'),
            'confidential': false,
          });
        },
      );
      addTearDown(h.dispose);
      h.provider.script.add(
        (_) => toolTurn('createNote', {
          'projectId': 42,
          'resource': 'issues',
          'iid': 6,
          'body': 'Synthetic summary',
          'reason': 'Requested',
        }),
      );
      final sending = h.controller.send('Add a note to #6');
      await waitFor(
        () =>
            h.controller.proposals.isNotEmpty ||
            h.controller.phase == AiChatPhase.idle,
      );
      expect(h.controller.proposals, hasLength(1));
      final proposal = h.controller.proposals.single;
      expect(proposal.tier.decision, AiGateDecision.requireApproval);
      expect(
        proposal.tier.reasons,
        contains(AiFixedConfirmReason.confidentialOrVisibilityMix),
      );
      expect(h.server.mutations, isEmpty);
      await h.controller.rejectWrite(proposal);
      await sending;
    },
  );

  test(
    'confidential source does not pollute an equally restricted issue',
    () async {
      final h = await StackHarness.create(
        origin: AiWorkItemOrigin(
          project: _project('private'),
          kind: AiWorkItemKind.issue,
          iid: 5,
          title: 'Source',
        ),
        configure: (server) {
          for (final iid in [5, 6]) {
            server.overrides['GET projects/42/issues/$iid'] = (_) =>
                jsonResponse({
                  ...server.workspace.issue(iid, 'Restricted issue'),
                  'confidential': true,
                });
          }
        },
      );
      addTearDown(h.dispose);
      h.provider.script.add((_) => toolTurn('get_issue', {'iid': 5}));
      await h.controller.send('Read issue #5');
      final read = h.controller.items.whereType<AiToolRunItem>().single;
      expect(read.name, 'get_issue');
      expect(read.status, AiToolRunStatus.completed);
      expect(read.confidential, isTrue);
      final fresh = await h.controller.readWriteFreshnessForTesting(
        _request(h),
      );
      expect(fresh.polluted, isFalse);
      final lowering = await h.controller.readWriteFreshnessForTesting(
        _request(h, fields: {'confidential': false}),
      );
      expect(lowering.polluted, isTrue);
      expect(lowering.facts.confidentialLowered, isTrue);
      expect(h.server.mutations, isEmpty);
    },
  );

  for (final source in ['private', 'internal']) {
    test('$source snippet pollution compares the target visibility', () async {
      final h = await StackHarness.create(
        origin: AiWorkItemOrigin(
          project: _project('public'),
          kind: AiWorkItemKind.issue,
          iid: 5,
          title: 'Source',
        ),
        configure: (server) {
          server.overrides['GET projects/42/snippets/7'] = (_) => jsonResponse({
            'id': 7,
            'project_id': 42,
            'title': 'Restricted snippet',
            'description': 'Synthetic context',
            'visibility': source,
            'files': <Map<String, Object?>>[],
          });
        },
      );
      addTearDown(h.dispose);
      h.provider.script.add((_) => toolTurn('get_snippet', {'snippet_id': 7}));
      await h.controller.send('Read snippet #7');
      expect(
        h.server.adapter.requests.any(
          (request) => request.uri.path.endsWith('/projects/42/snippets/7'),
        ),
        isTrue,
      );
      for (final target in ['private', 'internal', 'public']) {
        h.server.overrides['GET projects/43'] = (_) => jsonResponse({
          'id': 43,
          'path_with_namespace': 'studio/target',
          'visibility': target,
        });
        h.server.overrides['GET projects/43/issues/6'] = (_) => jsonResponse({
          'id': 106,
          'iid': 6,
          'project_id': 43,
          'confidential': false,
        });
        final fresh = await h.controller.readWriteFreshnessForTesting(
          _request(h, project: 43),
        );
        expect(fresh.visibilityUnreadable, isFalse, reason: target);
        expect(
          fresh.polluted,
          source == 'private' ? target != 'private' : target == 'public',
          reason: target,
        );
      }
      expect(h.server.mutations, isEmpty);
    });
  }

  test(
    'snippet targets use their requested visibility and private create default',
    () async {
      final h = await StackHarness.create(
        origin: AiWorkItemOrigin(
          project: _project('public'),
          kind: AiWorkItemKind.issue,
          iid: 5,
          title: 'Source',
        ),
        configure: (server) {
          server.overrides['GET projects/42'] = (_) => jsonResponse({
            ...server.workspace.projectRecord,
            'visibility': 'public',
          });
          for (final id in [7, 8]) {
            server.overrides['GET projects/42/snippets/$id'] = (_) =>
                jsonResponse({
                  'id': id,
                  'project_id': 42,
                  'title': 'Private snippet',
                  'description': 'Synthetic context',
                  'visibility': 'private',
                  'files': <Map<String, Object?>>[],
                });
          }
        },
      );
      addTearDown(h.dispose);
      h.provider.script.add((_) => toolTurn('get_snippet', {'snippet_id': 7}));
      await h.controller.send('Read snippet #7');
      for (final operation in ['createSnippet', 'updateSnippetMetadata']) {
        for (final visibility in [null, 'private', 'internal', 'public']) {
          final fresh = await h.controller.readWriteFreshnessForTesting(
            port.AiWriteRequest(
              operationId: operation,
              executionId: 'snippet-visibility',
              scope: AiWriteScope(
                accountKey: h.account,
                grants: const [
                  AiScopeGrant(kind: AiScopeKind.project, projectId: 42),
                ],
              ),
              arguments: {
                'projectId': 42,
                if (operation == 'createSnippet') ...{
                  'title': 'New snippet',
                  'path': 'example.txt',
                  'content': 'Synthetic',
                  'visibility': ?visibility,
                } else ...{
                  'snippetId': 8,
                  'fields': {
                    'title': 'Edited title',
                    'visibility': ?visibility,
                  },
                },
              },
            ),
          );
          expect(
            fresh.visibilityUnreadable,
            isFalse,
            reason: '$operation/$visibility',
          );
          expect(
            fresh.polluted,
            visibility != null && visibility != 'private',
            reason: '$operation/$visibility',
          );
        }
      }
      h.server.overrides['GET projects/42/snippets/8'] = (_) => jsonResponse({
        'id': 8,
        'project_id': 42,
        'title': 'Unknown visibility',
      });
      final unreadable = await h.controller.readWriteFreshnessForTesting(
        port.AiWriteRequest(
          operationId: 'updateSnippetMetadata',
          executionId: 'unknown-snippet',
          scope: AiWriteScope(accountKey: h.account, grants: const []),
          arguments: {
            'projectId': 42,
            'snippetId': 8,
            'fields': {'title': 'New title'},
          },
        ),
      );
      expect(unreadable.visibilityUnreadable, isTrue);
      expect(h.server.mutations, isEmpty);
    },
  );

  test(
    'unknown snippet source visibility cannot authorize an automatic write',
    () async {
      final h = await StackHarness.create(
        origin: AiWorkItemOrigin(
          project: _project('public'),
          kind: AiWorkItemKind.issue,
          iid: 5,
          title: 'Source',
        ),
        configure: (server) {
          server.overrides['GET projects/42/snippets/7'] = (_) => jsonResponse({
            'id': 7,
            'project_id': 42,
            'title': 'Unknown visibility',
            'files': <Map<String, Object?>>[],
          });
        },
      );
      addTearDown(h.dispose);
      h.provider.script.add((_) => toolTurn('get_snippet', {'snippet_id': 7}));
      await h.controller.send('Read snippet #7');
      final fresh = await h.controller.readWriteFreshnessForTesting(
        _request(h),
      );
      expect(fresh.visibilityUnreadable, isTrue);
      expect(h.server.mutations, isEmpty);
    },
  );

  test(
    'unknown target visibility cannot authorize an automatic write',
    () async {
      final h = await StackHarness.create(
        origin: AiWorkItemOrigin(
          project: _project('public'),
          kind: AiWorkItemKind.issue,
          iid: 5,
          title: 'Source',
        ),
      );
      addTearDown(h.dispose);
      h.server.overrides['GET projects/42'] = (_) => jsonResponse({
        ...h.server.workspace.projectRecord,
        'visibility': null,
      });
      final fresh = await h.controller.readWriteFreshnessForTesting(
        _request(h),
      );
      expect(fresh.visibilityUnreadable, isTrue);
      expect(h.server.mutations, isEmpty);
    },
  );
}
