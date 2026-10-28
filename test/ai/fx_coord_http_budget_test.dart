// C4 (§4.4): each write reserves its own counted worst case of GitLab
// requests, not nearly the whole 40-request budget of a send.

import 'release_policy_support.dart';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';

import '../support/fake_adapter.dart';
import 'fx_coord_support.dart';

/// Counted from the code, independently of the table under test: GETs per
/// pass by the freshness reader (`_freshWrite`: the project, then the
/// target record when there is one) and by the write port's `prepare`
/// (the current user, the project, the parent issue or merge request, then
/// the operation's own records at their worst case), and readback GETs.
const _counted = <String, (int fresh, int prepare, int readback)>{
  'setStar': (1, 2, 0), // project | user, project
  'setSubscribed': (2, 3, 0), // + issue | + issue
  'markTodoDone': (0, 5, 0), // none | user, 4 todo pages
  'addAwardEmoji': (2, 4, 0), // project, issue | user, project, issue, note
  'removeAwardEmoji': (2, 5, 0), // ... | ..., note, award
  'createNote': (2, 3, 1), // project, issue | user, project, issue | note
  'updateNote': (2, 4, 1), // project, note | user, project, issue, note
  'createIssue': (1, 2, 1), // project | user, project | issue
  'updateIssue': (2, 3, 1),
  'createMergeRequest': (1, 2, 1),
  'updateMergeRequest': (2, 3, 1),
  'unapproveMergeRequest': (2, 3, 0),
  'createTodo': (2, 3, 0),
  'createDiscussion': (2, 4, 0), // ... | ..., MR changes for a position
  'createDiscussionNote': (2, 4, 1), // ... | ..., discussion | discussion
  'updateDiscussionNote': (2, 4, 1),
  'setDiscussionResolved': (2, 4, 1),
  'createDraftNote': (2, 4, 0), // ... | ..., MR changes for a position
  'updateDraftNote': (2, 4, 1), // project, draft | user, project, MR, draft
  'createLabel': (1, 2, 0),
  'updateLabel': (2, 3, 1), // project, label | user, project, label
  'createMilestone': (1, 2, 0),
  'updateMilestone': (2, 3, 1),
  'setMilestoneState': (2, 3, 1),
  'createBoard': (1, 2, 0),
  'renameBoard': (2, 3, 0), // project, board | user, project, board
  'setBoardSystemListHidden': (2, 3, 0),
  'createBoardList': (1, 4, 0), // project | user, project, board, label
  'moveBoardList': (2, 4, 0), // project, list | user, project, board, list
  'moveBoardCard': (2, 3, 1),
  'upload_attachment': (1, 2, 0),
};

// MR6b-2 caps independently counted in the family port tests. These include
// both preparation passes, freshness, readback and OAuth replay. Cancel
// auto-merge also reserves its fallback mutation; batch suggestions reserve
// all twenty distinct discussions and can exceed a single send's budget.
const _mr6b2CountedCaps = <String, int>{
  'edit_file': 35,
  'createFile': 27,
  'deleteFile': 29,
  'applySuggestion': 27,
  'createBranch': 19,
  'deleteBranch': 17,
  'createTag': 19,
  'deleteTag': 17,
  'createRelease': 19,
  'updateRelease': 19,
  'deleteRelease': 17,
  'mergeRequest': 37,
  'approveMergeRequest': 23,
  'rebaseMergeRequest': 19,
  'cancelAutoMerge': 20,
  'publishDraftNotes': 23,
  'deleteDraftNote': 23,
  'createPipeline': 19,
  'pipelineAction': 15,
  'jobAction': 15,
  'playPipelineSchedule': 23,
  'deletePipeline': 15,
  'createSnippet': 19,
  'updateSnippetMetadata': 19,
  'updateSnippet': 31,
  'updateSnippetFiles': 37,
  'deleteSnippetFile': 27,
  'deleteSnippet': 37,
  'deleteNote': 21,
  'deleteDiscussionNote': 21,
  'deleteIssue': 17,
  'deleteMergeRequest': 17,
  'deleteLabel': 17,
  'deleteMilestone': 17,
  'deleteBoard': 17,
  'deleteBoardList': 21,
  'markAllTodosDone': 9,
  'deletePackage': 19,
  'deletePackageFile': 35,
  'deleteContainerRepository': 23,
  'deleteContainerTag': 27,
  'createProject': 7,
  'editProject': 15,
  'deleteProject': 15,
  'forkProject': 15,
};

// MR6b-3 graph caps independently counted in the family port tests. The
// caps are the ledger's own numbers (OAuth 2L+1, PAT L+1); each graph write
// reserves exactly one mutation.
const _mr6b3CountedCaps = <String, int>{
  // 3t: content P=user+WI+content=3; edit P=user+WI+locator(2)+access=5;
  // labels P=user+WI+opening+complete candidates=4. F=1, Mpre=Mrb=1.
  'updateWorkItemContent': 21,
  'editWorkItemActivityNote': 29,
  'updateWorkItemLabels': 25,
  'createWorkItemActivityComment': 21,
  'createWorkItemActivityReply': 29,
  'deleteWorkItemActivityNote': 29,
  'updateWorkItemDates': 29,
  'updateWorkItemAssignees': 37,
  'updateWorkItemHealthStatus': 21,
  'setWorkItemNotifications': 21,
  'setIncidentStatus': 21,
  'updateWorkItemMilestone': 25,
  'setWorkItemActivityNoteReaction': 37,
  'updateWorkItemStatus': 21,
  'snoozeTodo': 21,
  'unsnoozeTodo': 21,
  'updateWorkItemState': 21,
  'updateWorkItemWeight': 21,
};

// Group call paths independently counted in the MR6b-3g §4 table and the
// group family tests. F is the group freshness GET; P includes current user,
// strict namespace identity and the family's opening/candidate/locator reads.
// Snooze is account-global: no group freshness or separate namespace read,
// just user plus up to four ownership pages per pass, with no readback.
const _groupCounted =
    <String, (int fresh, int prepare, int preflight, int readback)>{
      'updateGroupWorkItemState': (1, 3, 1, 1),
      'updateGroupWorkItemStatus': (1, 3, 1, 1),
      'updateGroupWorkItemDates': (1, 4, 2, 2),
      'updateGroupWorkItemHealthStatus': (1, 3, 1, 1),
      'updateGroupWorkItemAssignees': (1, 7, 1, 1),
      'updateGroupWorkItemMilestone': (1, 4, 1, 1),
      'updateGroupWorkItemWeight': (1, 3, 1, 1),
      'createGroupWorkItemActivityComment': (1, 3, 1, 1),
      'createGroupWorkItemActivityReply': (1, 5, 1, 1),
      'deleteGroupWorkItemActivityNote': (1, 5, 1, 1),
      'setGroupWorkItemActivityNoteReaction': (1, 6, 2, 2),
      'setGroupWorkItemNotifications': (1, 3, 1, 1),
      'updateGroupWorkItemContent': (1, 3, 1, 1),
      'editGroupWorkItemActivityNote': (1, 5, 1, 1),
      'updateGroupWorkItemLabels': (1, 4, 1, 1),
      'snoozeTodo': (0, 5, 0, 0),
      'unsnoozeTodo': (0, 5, 0, 0),
    };

int _worstReads(String operation) {
  final (fresh, prepare, readback) = _counted[operation]!;
  return 2 * (fresh + prepare) + readback;
}

/// How far a reservation may exceed the counted worst case.
const _margin = 1;

final _project = Project.fromJson({
  'id': 42,
  'name': 'Mobile Workspace',
  'path_with_namespace': 'studio/mobile-workspace',
  'visibility': 'private',
  'default_branch': 'main',
  'archived': false,
  'last_activity_at': '2026-09-19T08:30:00Z',
});

final _issueOrigin = AiWorkItemOrigin(
  project: _project,
  kind: AiWorkItemKind.issue,
  iid: 5,
  title: 'Synthetic five',
);

void main() {
  group('C4 the per-operation reservation table', () {
    test('covers every write the model can call', () {
      expect(
        {
          for (final capability in fixtureAiLedger.modelVisible)
            capability.operationId,
        },
        {
          ..._counted.keys,
          ..._mr6b2CountedCaps.keys,
          ..._mr6b3CountedCaps.keys,
          ..._groupCounted.keys,
        },
      );
      expect(aiWriteRequestCounts.keys.toSet(), _counted.keys.toSet());
    });

    for (final operation in _counted.keys) {
      test('$operation reserves its counted worst case', () {
        final reads = _worstReads(operation);
        final pat = aiWriteRequestAllowance(operation, oauthReplay: false);
        final oauth = aiWriteRequestAllowance(operation);
        // One mutation, never replayed.
        expect(pat, greaterThanOrEqualTo(reads + 1));
        expect(pat, lessThanOrEqualTo(reads + 1 + _margin));
        // An OAuth 401 may replay each GET once.
        expect(oauth, greaterThanOrEqualTo(2 * reads + 1));
        expect(oauth, lessThanOrEqualTo(2 * reads + 1 + _margin));
        expect(oauth, lessThan(40), reason: 'never nearly the whole send');
      });
    }

    for (final entry in _mr6b2CountedCaps.entries) {
      test('${entry.key} reserves its counted worst case', () {
        expect(aiWriteRequestAllowance(entry.key), entry.value);
        final mutations = entry.key == 'cancelAutoMerge' ? 2 : 1;
        expect(
          aiWriteRequestAllowance(entry.key, oauthReplay: false),
          (entry.value - mutations) ~/ 2 + mutations,
        );
      });
    }

    for (final entry in _mr6b3CountedCaps.entries) {
      test('${entry.key} reserves its counted worst case', () {
        expect(aiWriteRequestAllowance(entry.key), entry.value);
        expect(
          aiWriteRequestAllowance(entry.key, oauthReplay: false),
          (entry.value - 1) ~/ 2 + 1,
        );
      });
    }

    for (final entry in _groupCounted.entries) {
      test('${entry.key} reserves independently counted group reads', () {
        final (fresh, prepare, preflight, readback) = entry.value;
        final logicalReads = 2 * (fresh + prepare) + preflight + readback;
        final row = productionAiLedger.find(entry.key);
        expect(row, isNotNull);
        expect(row!.modelVisible, isTrue);
        // One unreplayed mutation; OAuth may replay each resource read once.
        expect(row.httpCap, 2 * logicalReads + 1);
        expect(aiWriteRequestAllowance(entry.key), 2 * logicalReads + 1);
        expect(
          aiWriteRequestAllowance(entry.key, oauthReplay: false),
          logicalReads + 1,
        );
        expect(row.httpCap, lessThanOrEqualTo(40));
      });
    }

    test('an unknown operation reserves the largest row', () {
      final largest = [
        for (final operation in _counted.keys) 2 * _worstReads(operation) + 1,
        ..._mr6b2CountedCaps.values,
        ..._mr6b3CountedCaps.values,
        for (final (fresh, prepare, preflight, readback)
            in _groupCounted.values)
          2 * (2 * (fresh + prepare) + preflight + readback) + 1,
      ].reduce((a, b) => a > b ? a : b);
      expect(aiWriteRequestAllowance('notAnOperation'), largest);
      expect(
        aiWriteRequestAllowance('notAnOperation', oauthReplay: false),
        (largest - 1) ~/ 2 + 1,
      );
    });
  });

  group('C4 measured GitLab GETs stay within the reservation', () {
    Future<int> measure(
      StackHarness h,
      String operation,
      Map<String, Object?> arguments,
      String message,
    ) async {
      h.provider.script.add((_) => toolTurn(operation, arguments));
      final before = h.server.gets;
      final mutationsBefore = h.server.mutations.length;
      await h.sendAndApprove(message);
      expect(
        h.server.mutations.length - mutationsBefore,
        1,
        reason: '$operation ran once: ${h.provider.bodies.last}',
      );
      return h.server.gets - before;
    }

    void expectWithin(String operation, int gets, {bool worstCase = true}) {
      final reserved = aiWriteRequestAllowance(operation, oauthReplay: false);
      // The reservation covers every GET plus the one mutation...
      expect(gets + 1, lessThanOrEqualTo(reserved), reason: operation);
      // ...and, on the path that makes every counted GET, not much more.
      if (worstCase) {
        expect(gets, _worstReads(operation), reason: operation);
        expect(reserved - (gets + 1), lessThanOrEqualTo(_margin));
      }
    }

    test('project writes', () async {
      final h = await StackHarness.create(
        level: AiAutonomyLevel.bypass,
        picks: [
          PickedAttachment(
            filename: 'shot.png',
            bytes: Uint8List.fromList([1, 2, 3, 4]),
            contentType: 'image/png',
          ),
        ],
      );
      addTearDown(h.dispose);
      expectWithin(
        'setStar',
        await measure(h, 'setStar', {
          'projectId': 42,
          'starred': true,
          'reason': 'Asked.',
        }, 'Star this project'),
      );
      expectWithin(
        'createIssue',
        await measure(h, 'createIssue', {
          'projectId': 42,
          'fields': {'title': 'Synthetic bug'},
          'reason': 'Asked.',
        }, 'Create an issue'),
      );
      expect(
        (await h.controller.attach(AiAttachmentPick.image)).status,
        AiAttachStatus.stored,
      );
      expectWithin(
        'upload_attachment',
        await measure(h, 'upload_attachment', {
          'projectId': 42,
          'attachmentId': 'att-1',
          'reason': 'Asked.',
        }, 'Upload my file'),
      );
    });

    test('issue writes', () async {
      final h = await StackHarness.create(
        level: AiAutonomyLevel.bypass,
        origin: _issueOrigin,
        configure: (server) {
          server.workspace.notes[77] = {
            'id': 77,
            'body': 'Earlier synthetic note',
            'author': {'id': 7, 'username': 'developer'},
            'system': false,
          };
        },
      );
      addTearDown(h.dispose);
      expectWithin(
        'createNote',
        await measure(h, 'createNote', {
          'projectId': 42,
          'resource': 'issues',
          'iid': 5,
          'body': 'Synthetic note',
          'reason': 'Asked.',
        }, 'Comment on this issue'),
      );
      expectWithin(
        'updateNote',
        await measure(h, 'updateNote', {
          'projectId': 42,
          'resource': 'issues',
          'iid': 5,
          'noteId': 77,
          'body': 'Edited synthetic note',
          'reason': 'Asked.',
        }, 'Edit my comment on this issue'),
      );
      expectWithin(
        'addAwardEmoji',
        await measure(h, 'addAwardEmoji', {
          'projectId': 42,
          'resource': 'issues',
          'iid': 5,
          'noteId': 77,
          'name': 'thumbsup',
          'reason': 'Asked.',
        }, 'Add a thumbs up to that comment on this issue'),
      );
      expectWithin(
        'updateIssue',
        await measure(h, 'updateIssue', {
          'projectId': 42,
          'iid': 5,
          'fields': {'title': 'Renamed'},
          'reason': 'Asked.',
        }, 'Rename this issue'),
      );
    });

    test('markTodoDone reading all four todo pages', () async {
      final h = await StackHarness.create(
        level: AiAutonomyLevel.bypass,
        origin: _issueOrigin,
        configure: (server) {
          server.overrides['GET todos'] = (request) {
            final page = int.parse(request.uri.queryParameters['page'] ?? '1');
            return jsonResponse(
              [
                if (page == 4)
                  {
                    'id': 900,
                    'target_type': 'Issue',
                    'project': {'id': 42},
                    'target': {'iid': 5},
                  },
              ],
              headers: {
                if (page < 4) 'x-next-page': ['${page + 1}'],
              },
            );
          };
          server.overrides['POST todos/900/mark_as_done'] = (_) =>
              jsonResponse({'id': 900, 'state': 'done'}, status: 201);
        },
      );
      addTearDown(h.dispose);
      expectWithin(
        'markTodoDone',
        await measure(h, 'markTodoDone', {
          'todoId': 900,
          'reason': 'Asked.',
        }, 'Mark this todo done'),
      );
    });
  });

  test(
    'C4 a read, then addAwardEmoji, then createNote fit in one send',
    () async {
      final h = await StackHarness.create(
        level: AiAutonomyLevel.bypass,
        origin: _issueOrigin,
      );
      addTearDown(h.dispose);
      h.provider.script
        ..add((_) => toolTurn('get_issue', {'iid': 5}))
        ..add(
          (_) => toolTurn('addAwardEmoji', {
            'projectId': 42,
            'resource': 'issues',
            'iid': 5,
            'name': 'thumbsup',
            'reason': 'Asked.',
          }),
        )
        ..add(
          (_) => toolTurn('createNote', {
            'projectId': 42,
            'resource': 'issues',
            'iid': 5,
            'body': 'Synthetic note',
            'reason': 'Asked.',
          }),
        );

      await h.controller.send('Read this issue, thumbs it up and comment');

      expect(
        [for (final request in h.server.mutations) request.uri.path],
        [
          endsWith('/projects/42/issues/5/award_emoji'),
          endsWith('/projects/42/issues/5/notes'),
        ],
      );
      for (final body in h.provider.bodies) {
        expect(body, isNot(contains('httpBudgetExceeded')));
      }
      expect(h.provider.bodies, hasLength(4));
    },
  );

  test('C4 a second write after a read is no longer refused for budget '
      '(coordinator, default OAuth-safe reservation)', () async {
    final h = await CoordHarness.create();
    addTearDown(h.dispose);
    h.level = AiAutonomyLevel.bypass;
    h.newRun('Star team/example-9 and comment on team/example-9#3');
    // A read already used part of this send's budget.
    expect(h.budget.reserve(requests: 4, search: false), isNull);
    final star = await h.coordinator.execute(starCall('star'));
    expect(star.reasonCode, isNot('httpBudgetExceeded'));
    final note = await h.coordinator.execute(coordNoteCall('note'));
    expect(note.reasonCode, isNot('httpBudgetExceeded'));
    expect(h.budget.gitLabRequests, lessThanOrEqualTo(40));
  });
}
