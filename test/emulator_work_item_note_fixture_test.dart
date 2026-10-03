import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';

import '../tool/emulator_ui.dart';

void main() {
  for (final group in [false, true]) {
    test(
      'fixture replies to an existing ${group ? 'group' : 'project'} thread',
      () async {
        final fixture = EmulatorQaFixture();
        addTearDown(fixture.api.close);
        final detail = group
            ? await fixture.api.namespaceWorkItem(
                'qa/synthetic-group',
                41,
                expectedNamespaceId: 'gid://gitlab/Group/84',
              )
            : await fixture.api.projectWorkItem(fixture.project, 31);
        final page = await fixture.api.workItemActivity(
          detail.summary,
          filter: WorkItemActivityFilter.comments,
        );
        final discussion = page.snapshot.discussions.items.first;
        final target = page.replyTargetsByDiscussion[discussion.id];
        expect(target, isNotNull);
        final created = await fixture.api.createWorkItemActivityReply(
          target!,
          'Synthetic existing thread reply',
        );
        expect(created.discussionId, discussion.id);
        expect(created.note.body, 'Synthetic existing thread reply');
        expect(fixture.workItemNoteEvents.single['reply'], isTrue);
        expect(fixture.unhandled, isEmpty);
      },
    );
    test(
      '${group ? 'group' : 'project'} fixture creates and reads exact comments and replies',
      () async {
        final fixture = EmulatorQaFixture();
        addTearDown(fixture.api.close);
        final detail = group
            ? await fixture.api.namespaceWorkItem(
                'qa/synthetic-group',
                41,
                expectedNamespaceId: 'gid://gitlab/Group/84',
              )
            : await fixture.api.projectWorkItem(fixture.project, 31);
        final access = await fixture.api.workItemActivityWriteAccess(
          detail.summary,
        );
        expect(access.canCreateNote, isTrue);
        final comment = await fixture.api.createWorkItemActivityComment(
          access.commentTarget!,
          '**Synthetic ${group ? 'group' : 'project'} saved comment**',
        );
        var page = await fixture.api.workItemActivity(
          detail.summary,
          filter: WorkItemActivityFilter.comments,
          order: WorkItemActivityOrder.newestFirst,
        );
        expect(
          page.snapshot.discussions.items.first.notes.items.single.id,
          comment.note.id,
        );
        final reply = await fixture.api.createWorkItemActivityReply(
          page.replyTargetsByDiscussion[comment.discussionId]!,
          'Synthetic saved reply',
        );
        page = await fixture.api.workItemActivity(
          detail.summary,
          filter: WorkItemActivityFilter.comments,
          order: WorkItemActivityOrder.newestFirst,
        );
        final notes = page.snapshot.discussions.items.first.notes.items;
        expect(notes.map((note) => note.id), [comment.note.id, reply.note.id]);
        expect(notes.last.body, 'Synthetic saved reply');
        expect(fixture.workItemNoteEvents, hasLength(2));
        expect(
          fixture.workItemNoteEvents.map((event) => event['scope']).toSet(),
          {group ? 'group' : 'project'},
        );
        final before = fixture.adapter.requests.length;
        await expectLater(
          fixture.api.createWorkItemActivityComment(
            access.commentTarget!,
            'Duplicate',
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(fixture.adapter.requests, hasLength(before));
        expect(fixture.workItemNoteEvents, hasLength(2));
        expect(fixture.unhandled, isEmpty);
        expect(
          fixture.adapter.requests.every(
            (request) => request.uri.host == 'qa.invalid',
          ),
          isTrue,
        );
      },
    );
  }

  test(
    'fixture rejects unknown and cross-scope discussion targets without writing',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      for (final input in [
        {'noteableId': 'gid://gitlab/WorkItem/9999', 'body': 'Unknown item'},
        {
          'noteableId': 'gid://gitlab/WorkItem/1041',
          'body': 'Wrong scope',
          'discussionId': 'gid://gitlab/Discussion/qa-project-reply-1',
        },
      ]) {
        await fixture.respond(
          RequestOptions(
            path: 'https://qa.invalid:8443/gitlab/api/graphql',
            method: 'POST',
            data: {
              'query':
                  'mutation MobileCreateWorkItemActivityNote(\$input: CreateNoteInput!) { createNote(input: \$input) { errors } }',
              'variables': {'input': input},
            },
          ),
        );
      }
      expect(fixture.workItemNoteEvents, isEmpty);
    },
  );
}
