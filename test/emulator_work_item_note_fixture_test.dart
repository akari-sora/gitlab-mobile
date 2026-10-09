import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';

import '../tool/emulator_ui.dart';

void main() {
  testWidgets('compact QA menu exposes deterministic note edit controls', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
    await tester.pumpAndSettle();

    final menu = find.byKey(const ValueKey('emulator-qa-note-edit-controls'));
    expect(menu, findsOneWidget);
    expect(find.bySemanticsLabel('留言編輯 QA'), findsOneWidget);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('emulator-qa-controls')))
          .contains(tester.getCenter(menu)),
      isTrue,
      reason: 'QA overflow control must stay out of production route content',
    );
    for (final control in [
      ('拒絕留言編輯', '留言編輯權限：拒絕'),
      ('允許留言編輯', '留言編輯權限：允許'),
      ('更新既有留言版本', '留言版本已更新：2 則'),
      ('下次編輯確認失敗', '下一次編輯確認將失敗'),
    ]) {
      await tester.tap(menu);
      await tester.pumpAndSettle();
      final option = find.text(control.$1);
      await tester.ensureVisible(option);
      await tester.pumpAndSettle();
      final row = find.ancestor(
        of: option,
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      );
      await tester.tap(row);
      await tester.pump();
      expect(find.text(control.$2), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1500));
    }
    expect(tester.takeException(), isNull);
  });

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
    test(
      '${group ? 'group' : 'project'} fixture edits and reads back the exact note body',
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
        final note = discussion.notes.items.first;
        final access = await fixture.api.workItemActivityEditAccess(
          detail.summary,
          discussion,
          note,
        );

        expect(access.canEditNote, isTrue);
        expect(access.target, isNotNull);
        final edited = await fixture.api.editWorkItemActivityNote(
          access.target!,
          '  **Synthetic ${group ? 'group' : 'project'} edited note**  ',
        );

        expect(
          edited.body,
          '  **Synthetic ${group ? 'group' : 'project'} edited note**  ',
        );
        final refreshed = await fixture.api.workItemActivity(
          detail.summary,
          filter: WorkItemActivityFilter.comments,
        );
        expect(
          refreshed.snapshot.discussions.items.first.notes.items.first.body,
          edited.body,
        );
        expect(fixture.workItemNoteEditEvents.single, {
          'scope': group ? 'group' : 'project',
          'noteId': note.id,
          'body': edited.body,
        });
        expect(fixture.unhandled, isEmpty);
      },
    );
  }

  test('fixture denies an edit when adminNote is false or revoked', () async {
    final fixture = EmulatorQaFixture();
    addTearDown(fixture.api.close);
    final detail = await fixture.api.projectWorkItem(fixture.project, 31);
    final page = await fixture.api.workItemActivity(
      detail.summary,
      filter: WorkItemActivityFilter.comments,
    );
    final discussion = page.snapshot.discussions.items.first;
    final note = discussion.notes.items.first;
    fixture.workItemNoteEditAllowed[false] = false;
    final denied = await fixture.api.workItemActivityEditAccess(
      detail.summary,
      discussion,
      note,
    );
    expect(denied.canEditNote, isFalse);
    expect(denied.target, isNull);

    fixture.workItemNoteEditAllowed[false] = true;
    final granted = await fixture.api.workItemActivityEditAccess(
      detail.summary,
      discussion,
      note,
    );
    fixture.workItemNoteEditAllowed[false] = false;
    await expectLater(
      fixture.api.editWorkItemActivityNote(granted.target!, 'Denied edit'),
      throwsA(
        isA<ApiFailure>().having(
          (failure) => failure.kind,
          'kind',
          FailureKind.forbidden,
        ),
      ),
    );
    expect(fixture.workItemNoteEditEvents, isEmpty);
    expect(fixture.unhandled, isEmpty);
  });

  test('fixture exposes a concurrent note revision before mutation', () async {
    final fixture = EmulatorQaFixture();
    addTearDown(fixture.api.close);
    final detail = await fixture.api.projectWorkItem(fixture.project, 31);
    final page = await fixture.api.workItemActivity(
      detail.summary,
      filter: WorkItemActivityFilter.comments,
    );
    final discussion = page.snapshot.discussions.items.first;
    final note = discussion.notes.items.first;
    final access = await fixture.api.workItemActivityEditAccess(
      detail.summary,
      discussion,
      note,
    );
    expect(fixture.reviseWorkItemActivityNote(note.id), isTrue);

    await expectLater(
      fixture.api.editWorkItemActivityNote(access.target!, 'Stale edit'),
      throwsA(
        isA<ApiFailure>().having(
          (failure) => failure.kind,
          'kind',
          FailureKind.conflict,
        ),
      ),
    );
    expect(fixture.workItemNoteEditEvents, isEmpty);
    expect(fixture.unhandled, isEmpty);
  });

  test(
    'fixture applies one edit when its acknowledgement is uncertain',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final detail = await fixture.api.projectWorkItem(fixture.project, 31);
      final page = await fixture.api.workItemActivity(
        detail.summary,
        filter: WorkItemActivityFilter.comments,
      );
      final discussion = page.snapshot.discussions.items.first;
      final note = discussion.notes.items.first;
      final access = await fixture.api.workItemActivityEditAccess(
        detail.summary,
        discussion,
        note,
      );
      fixture.failNextWorkItemNoteUpdateAcknowledgement = true;

      await expectLater(
        fixture.api.editWorkItemActivityNote(
          access.target!,
          'Server applied uncertain edit',
        ),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.writeUncertain,
          ),
        ),
      );
      expect(fixture.workItemNoteEditEvents, hasLength(1));
      expect(
        fixture.workItemActivityNoteRecord(note.id, group: false)?['body'],
        'Server applied uncertain edit',
      );
      await expectLater(
        fixture.api.editWorkItemActivityNote(access.target!, 'Unsafe retry'),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.writeUncertain,
          ),
        ),
      );
      expect(fixture.workItemNoteEditEvents, hasLength(1));
      expect(fixture.unhandled, isEmpty);
    },
  );

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
