import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';

import '../tool/emulator_ui.dart';

void main() {
  for (final group in [false, true]) {
    for (final uncertain in [false, true]) {
      test(
        '${group ? 'group' : 'project'} delete fixture, uncertain=$uncertain',
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
          final access = await fixture.api.workItemActivityDeleteAccess(
            detail.summary,
            discussion,
            note,
          );
          fixture.failNextWorkItemNoteDeleteAcknowledgement = uncertain;
          final deletion = fixture.api.deleteWorkItemActivityNote(
            access.target!,
          );
          if (uncertain) {
            await expectLater(
              deletion,
              throwsA(
                isA<ApiFailure>().having(
                  (failure) => failure.kind,
                  'kind',
                  FailureKind.writeUncertain,
                ),
              ),
            );
          } else {
            await deletion;
          }
          expect(
            fixture.workItemActivityNoteRecord(note.id, group: group),
            isNull,
          );
          expect(fixture.workItemNoteDeleteEvents, hasLength(1));
          await expectLater(
            fixture.api.deleteWorkItemActivityNote(access.target!),
            throwsA(isA<ApiFailure>()),
          );
          expect(fixture.workItemNoteDeleteEvents, hasLength(1));
          expect(fixture.unhandled, isEmpty);
        },
      );
    }
    test(
      '${group ? 'group' : 'project'} fixture reacts independently of adminNote',
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
        fixture.workItemNoteEditAllowed[group] = false;
        var access = await fixture.api.workItemActivityReactionAccess(
          detail.summary,
          discussion,
          note,
        );
        expect(access.canAward, isTrue);
        access = await fixture.api.setWorkItemActivityNoteReaction(
          access.target!,
          'heart',
          awarded: true,
        );
        expect(
          access.reactions.where(
            (r) => r.name == 'heart' && r.actorId == access.actorId,
          ),
          hasLength(1),
        );
        final addedNote = access.target!.note;
        expect(addedNote.updatedAt.isAfter(note.updatedAt), isTrue);
        access = await fixture.api.setWorkItemActivityNoteReaction(
          access.target!,
          'heart',
          awarded: false,
        );
        expect(
          access.reactions.where(
            (r) => r.name == 'heart' && r.actorId == access.actorId,
          ),
          isEmpty,
        );
        expect(access.target!.note.updatedAt.isAfter(addedNote.updatedAt), isTrue);
        expect(fixture.workItemNoteReactionEvents, hasLength(2));
        fixture.workItemNoteReactionAllowed[group] = false;
        access = await fixture.api.workItemActivityReactionAccess(
          detail.summary,
          discussion,
          access.target!.note,
        );
        expect(access.canAward, isFalse);
        expect(access.target, isNull);
        expect(fixture.unhandled, isEmpty);
        expect(
          fixture.adapter.requests.every((r) => r.uri.host == 'qa.invalid'),
          isTrue,
        );
      },
    );
    test(
      '${group ? 'group' : 'project'} uncertain reaction sends once and persists',
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
        final access = await fixture.api.workItemActivityReactionAccess(
          detail.summary,
          discussion,
          note,
        );
        fixture.failNextWorkItemNoteReactionAcknowledgement = true;
        await expectLater(
          fixture.api.setWorkItemActivityNoteReaction(
            access.target!,
            'rocket',
            awarded: true,
          ),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.writeUncertain,
            ),
          ),
        );
        await expectLater(
          fixture.api.setWorkItemActivityNoteReaction(
            access.target!,
            'rocket',
            awarded: true,
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(fixture.workItemNoteReactionEvents, hasLength(1));
        final refreshedPage = await fixture.api.workItemActivity(
          detail.summary,
          filter: WorkItemActivityFilter.comments,
        );
        final refreshedDiscussion = refreshedPage.snapshot.discussions.items.first;
        final refreshed = await fixture.api.workItemActivityReactionAccess(
          detail.summary,
          refreshedDiscussion,
          refreshedDiscussion.notes.items.first,
        );
        expect(
          refreshed.reactions.where(
            (r) => r.name == 'rocket' && r.actorId == refreshed.actorId,
          ),
          hasLength(1),
        );
        expect(fixture.unhandled, isEmpty);
      },
    );
  }
}
