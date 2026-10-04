import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_labels_models.dart';

import '../tool/emulator_ui.dart';

Future<WorkItemGraphDetail> _detail(EmulatorQaFixture fixture, bool group) =>
    group
    ? fixture.api.namespaceWorkItem(
        'qa/synthetic-group',
        41,
        expectedNamespaceId: 'gid://gitlab/Group/84',
      )
    : fixture.api.projectWorkItem(fixture.project, 31);

Future<WorkItemLabelAccess> _open(EmulatorQaFixture fixture, bool group) async {
  final detail = await _detail(fixture, group);
  return fixture.api.workItemLabels(
    detail,
    expectedUserId: fixture.account.user.id,
    generation: 0,
  );
}

Matcher failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

Matcher writeFailure(FailureKind kind, {required bool mutationSent}) =>
    isA<WorkItemLabelWriteFailure>()
        .having((error) => error.failure.kind, 'kind', kind)
        .having((error) => error.mutationSent, 'mutationSent', mutationSent);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'project and group detail preview 50 vs complete 120 across two pages',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      fixture.setWorkItemLabelCount(group: false, count: 120);
      fixture.setWorkItemLabelCount(group: true, count: 120);

      final projectDetail = await _detail(fixture, false);
      final groupDetail = await _detail(fixture, true);

      expect(projectDetail.labels!.labels!.items, hasLength(50));
      expect(projectDetail.labels!.labels!.isPartial, isTrue);
      expect(groupDetail.labels!.labels!.items, hasLength(50));
      expect(groupDetail.labels!.labels!.isPartial, isTrue);

      final project = await fixture.api.workItemLabels(
        projectDetail,
        expectedUserId: fixture.account.user.id,
        generation: 0,
      );
      final group = await fixture.api.workItemLabels(
        groupDetail,
        expectedUserId: fixture.account.user.id,
        generation: 0,
      );

      expect(project.snapshot.labels, hasLength(120));
      expect(group.snapshot.labels, hasLength(120));
      expect(project.snapshot.labels.map((l) => l.id).toSet(), hasLength(120));
      expect(group.snapshot.labels.map((l) => l.id).toSet(), hasLength(120));
      expect(
        fixture.workItemLabelReads.where((event) => event['after'] != null),
        hasLength(2),
      );
      expect(fixture.workItemLabelEvents, isEmpty);
      expect(fixture.unhandled, isEmpty);
    },
  );

  test(
    'performance mode keeps public project and stateful labels routes together',
    () async {
      final fixture = EmulatorQaFixture(performanceQa: true);
      addTearDown(fixture.api.close);
      fixture.setWorkItemLabelCount(group: false, count: 120);
      fixture.setWorkItemLabelCount(group: true, count: 120);

      final projects = await fixture.api.projects(scope: ProjectScope.member);
      expect(projects.items, hasLength(30));
      expect(projects.next, isNotNull);

      final version = await fixture.api.record([
        'projects',
        '42',
        'merge_requests',
        '12',
        'versions',
        '1',
      ]);
      final diffs = (version['diffs'] as List).cast<Json>();
      expect(diffs, hasLength(emulatorPerfQaChangedFileCount));
      expect(
        diffs
            .map((diff) => utf8.encode(diff['diff'] as String).length)
            .where((bytes) => bytes > 64 * 1024),
        hasLength(1),
      );

      final sha = await fixture.api.defaultBranchSha(fixture.project);
      final source = await fixture.api.textFile(
        42,
        sha,
        emulatorPerfQaLargeFilePath,
      );
      expect(
        const LineSplitter().convert(source),
        hasLength(emulatorPerfQaLargeFileLineCount),
      );

      for (final group in [false, true]) {
        final access = await _open(fixture, group);
        expect(access.snapshot.labels, hasLength(120));
        final candidates = await fixture.api.searchWorkItemLabelCandidates(
          access.target!,
          searchTerm: 'priority',
          pageIndex: 0,
        );
        final addedId = candidates.labels
            .firstWhere((label) => !access.snapshot.labelIds.contains(label.id))
            .id;
        final saved = await fixture.api.updateWorkItemLabels(
          access.target!,
          desiredLabelIds: [...access.snapshot.labelIds, addedId],
        );
        final readback = await _open(fixture, group);

        expect(saved.status, WorkItemLabelSaveStatus.success);
        expect(saved.mutationSent, isTrue);
        expect(readback.snapshot.labelIds, contains(addedId));
      }
      expect(fixture.workItemLabelEvents, hasLength(2));
      expect(fixture.unhandled, isEmpty);
    },
  );

  test(
    'candidate search is bounded 20x5 with exact project ancestor and group only shape',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);

      final project = await _open(fixture, false);
      final projectPage0 = await fixture.api.searchWorkItemLabelCandidates(
        project.target!,
        searchTerm: 'workflow',
        pageIndex: 0,
      );
      expect(projectPage0.labels, isNotEmpty);
      expect(
        projectPage0.labels.any((l) => l.id.contains('GroupLabel')),
        isTrue,
      );
      expect(
        projectPage0.labels.any((l) => l.id.contains('ProjectLabel')),
        isTrue,
      );

      final group = await _open(fixture, true);
      final groupPage0 = await fixture.api.searchWorkItemLabelCandidates(
        group.target!,
        searchTerm: 'workflow',
        pageIndex: 0,
      );
      expect(groupPage0.labels, isNotEmpty);
      expect(
        groupPage0.labels.every((l) => l.id.contains('GroupLabel')),
        isTrue,
      );
      expect(
        groupPage0.labels.any((l) => l.id.contains('ProjectLabel')),
        isFalse,
      );

      final p0 = await fixture.api.searchWorkItemLabelCandidates(
        project.target!,
        searchTerm: '候選',
        pageIndex: 0,
      );
      expect(p0.labels, hasLength(20));
      expect(p0.hasNextPage, isTrue);
      expect(p0.endCursor, isNotNull);

      final p1 = await fixture.api.searchWorkItemLabelCandidates(
        project.target!,
        searchTerm: '候選',
        after: p0.endCursor,
        pageIndex: 1,
      );
      expect(p1.labels, hasLength(20));
      expect(p1.pageIndex, 1);

      final candidateRequests = fixture.adapter.requests.where((r) {
        final data = r.data;
        return data is Map && (data['query'] as String).contains('Candidate');
      });
      expect(candidateRequests, isNotEmpty);
      expect(fixture.workItemLabelEvents, isEmpty);
    },
  );

  test('candidate page failure and partial scenarios', () async {
    final fixture = EmulatorQaFixture();
    addTearDown(fixture.api.close);
    final project = await _open(fixture, false);

    fixture.failNextWorkItemLabelCandidates = true;
    await expectLater(
      fixture.api.searchWorkItemLabelCandidates(
        project.target!,
        searchTerm: 'workflow',
        pageIndex: 0,
      ),
      throwsA(failure(FailureKind.unsupported)),
    );

    final fresh = await _open(fixture, false);
    fixture.partialNextWorkItemLabelCandidates = true;
    final partialPage = await fixture.api.searchWorkItemLabelCandidates(
      fresh.target!,
      searchTerm: '候選',
      pageIndex: 0,
    );
    expect(partialPage.labels.length, lessThanOrEqualTo(5));
    expect(partialPage.hasNextPage, isFalse);
    expect(partialPage.endCursor, isNull);
  });

  test(
    'delta addition, removal, clear, noop and single-use target consumption',
    () async {
      final logs = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add('$message');
      addTearDown(() => debugPrint = previous);

      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);

      // 1. Noop: unchanged desired IDs sends nothing
      final current = await _open(fixture, false);
      final initialIds = current.snapshot.labelIds;
      final noopResult = await fixture.api.updateWorkItemLabels(
        current.target!,
        desiredLabelIds: initialIds,
      );
      expect(noopResult.status, WorkItemLabelSaveStatus.noop);
      expect(noopResult.mutationSent, isFalse);
      expect(noopResult.acknowledgedUpdatedAt, isNull);
      expect(fixture.workItemLabelEvents, isEmpty);

      // Target was consumed by noop: second call throws writeUncertain without sending mutation
      await expectLater(
        fixture.api.updateWorkItemLabels(
          current.target!,
          desiredLabelIds: initialIds,
        ),
        throwsA(writeFailure(FailureKind.writeUncertain, mutationSent: false)),
      );
      expect(fixture.workItemLabelEvents, isEmpty);

      // 2. Delta addition: add a candidate ID
      final openForAdd = await _open(fixture, false);
      final candidatePage = await fixture.api.searchWorkItemLabelCandidates(
        openForAdd.target!,
        searchTerm: 'priority',
        pageIndex: 0,
      );
      final addId = candidatePage.labels
          .firstWhere((l) => !openForAdd.snapshot.labelIds.contains(l.id))
          .id;
      final desiredWithAdd = [...openForAdd.snapshot.labelIds, addId];
      final addResult = await fixture.api.updateWorkItemLabels(
        openForAdd.target!,
        desiredLabelIds: desiredWithAdd,
      );
      expect(addResult.status, WorkItemLabelSaveStatus.success);
      expect(addResult.mutationSent, isTrue);
      expect(addResult.snapshot.labelIds, contains(addId));
      expect(fixture.workItemLabelEvents, hasLength(1));
      final addInput =
          fixture.workItemLabelEvents.single['input'] as Map<String, Object?>;
      final addWidget = addInput['labelsWidget'] as Map;
      expect(addWidget['addLabelIds'], [addId]);
      expect(addWidget.containsKey('removeLabelIds'), isFalse);

      // 3. Delta removal: remove a label while preserving unmentioned labels
      final openForRemove = await _open(fixture, false);
      final removedId = openForRemove.snapshot.labelIds.first;
      final desiredWithRemove = openForRemove.snapshot.labelIds
          .where((id) => id != removedId)
          .toList();
      final removeResult = await fixture.api.updateWorkItemLabels(
        openForRemove.target!,
        desiredLabelIds: desiredWithRemove,
      );
      expect(removeResult.status, WorkItemLabelSaveStatus.success);
      expect(removeResult.snapshot.labelIds, isNot(contains(removedId)));
      expect(fixture.workItemLabelEvents, hasLength(2));
      final removeInput =
          fixture.workItemLabelEvents.last['input'] as Map<String, Object?>;
      final removeWidget = removeInput['labelsWidget'] as Map;
      expect(removeWidget['removeLabelIds'], [removedId]);
      expect(removeWidget.containsKey('addLabelIds'), isFalse);

      // 4. Clear: desiredLabelIds is empty
      final openForClear = await _open(fixture, false);
      final currentIdsToClear = openForClear.snapshot.labelIds;
      final clearResult = await fixture.api.updateWorkItemLabels(
        openForClear.target!,
        desiredLabelIds: const [],
      );
      expect(clearResult.status, WorkItemLabelSaveStatus.success);
      expect(clearResult.snapshot.labels, isEmpty);
      expect(fixture.workItemLabelEvents, hasLength(3));
      final clearInput =
          fixture.workItemLabelEvents.last['input'] as Map<String, Object?>;
      final clearWidget = clearInput['labelsWidget'] as Map;
      expect(clearWidget['removeLabelIds'], currentIdsToClear);
      expect(clearWidget.containsKey('addLabelIds'), isFalse);

      // 5. Group work item delta mutation
      final groupOpen = await _open(fixture, true);
      final groupCandidates = await fixture.api.searchWorkItemLabelCandidates(
        groupOpen.target!,
        searchTerm: 'workflow',
        pageIndex: 0,
      );
      final groupAddId = groupCandidates.labels
          .firstWhere((l) => !groupOpen.snapshot.labelIds.contains(l.id))
          .id;
      final groupSave = await fixture.api.updateWorkItemLabels(
        groupOpen.target!,
        desiredLabelIds: [...groupOpen.snapshot.labelIds, groupAddId],
      );
      expect(groupSave.status, WorkItemLabelSaveStatus.success);
      expect(groupSave.snapshot.labelIds, contains(groupAddId));
      expect(groupAddId, startsWith('gid://gitlab/GroupLabel/90'));
      expect(fixture.workItemLabelEvents, hasLength(4));

      // Verify event marker format
      final projectMarker = logs.firstWhere(
        (entry) =>
            entry.startsWith('[work_item_labels_qa]') &&
            entry.contains('scope=project'),
      );
      expect(projectMarker, contains('accepted=true'));
      expect(projectMarker, contains('sequence='));
      expect(projectMarker, isNot(contains('PRIVATE-TOKEN')));

      final groupMarker = logs.firstWhere(
        (entry) =>
            entry.startsWith('[work_item_labels_qa]') &&
            entry.contains('scope=group'),
      );
      expect(groupMarker, contains('accepted=true'));
      expect(groupMarker, contains('sequence=4'));
    },
  );

  test(
    'silent denial returns notApplied and readback mismatch throws writeUncertain',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);

      // 1. Silent denial: server acknowledges mutation but doesn't apply labels
      final open1 = await _open(fixture, false);
      final cPage = await fixture.api.searchWorkItemLabelCandidates(
        open1.target!,
        searchTerm: 'workflow',
        pageIndex: 0,
      );
      final newLabelId = cPage.labels.first.id;
      fixture.silentDenyNextWorkItemLabelMutation = true;
      final silentResult = await fixture.api.updateWorkItemLabels(
        open1.target!,
        desiredLabelIds: [...open1.snapshot.labelIds, newLabelId],
      );
      expect(silentResult.status, WorkItemLabelSaveStatus.notApplied);
      expect(silentResult.mutationSent, isTrue);
      expect(silentResult.acknowledgedUpdatedAt, isNotNull);
      expect(fixture.silentDenyNextWorkItemLabelMutation, isFalse);

      // 2. Readback mismatch: ack succeeds but readback revision doesn't match
      final open2 = await _open(fixture, false);
      final cPage2 = await fixture.api.searchWorkItemLabelCandidates(
        open2.target!,
        searchTerm: 'workflow',
        pageIndex: 0,
      );
      final mismatchLabelId = cPage2.labels.first.id;
      fixture.mismatchNextWorkItemLabelReadback = true;
      await expectLater(
        fixture.api.updateWorkItemLabels(
          open2.target!,
          desiredLabelIds: [...open2.snapshot.labelIds, mismatchLabelId],
        ),
        throwsA(writeFailure(FailureKind.writeUncertain, mutationSent: true)),
      );
      expect(fixture.mismatchNextWorkItemLabelReadback, isFalse);
    },
  );

  test(
    'metadata permission false, widget absent and read forbidden prevent writes',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);

      // Metadata permission false: canWrite is false, target is null
      fixture.workItemLabelMetadataAllowed = false;
      final denied = await _open(fixture, false);
      expect(denied.canWrite, isFalse);
      expect(denied.target, isNull);
      expect(denied.snapshot.setWorkItemMetadata, isFalse);

      // Widget absent: canWrite is false, target is null
      fixture.workItemLabelMetadataAllowed = true;
      fixture.workItemLabelWidgetPresent = false;
      final absent = await _open(fixture, false);
      expect(absent.canWrite, isFalse);
      expect(absent.target, isNull);
      expect(absent.snapshot.labelsWidgetPresent, isFalse);

      // Read forbidden: throws forbidden
      fixture.workItemLabelWidgetPresent = true;
      fixture.workItemLabelReadWorkItemAllowed = false;
      await expectLater(
        _open(fixture, false),
        throwsA(failure(FailureKind.forbidden)),
      );
      expect(fixture.workItemLabelEvents, isEmpty);
    },
  );

  test(
    'revision drift throws conflict and lost ack throws writeUncertain',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);

      // Revision conflict: work item updated before mutation
      final current = await _open(fixture, false);
      final cPage = await fixture.api.searchWorkItemLabelCandidates(
        current.target!,
        searchTerm: 'priority',
        pageIndex: 0,
      );
      final addId = cPage.labels.first.id;
      fixture.reviseWorkItemLabel(group: false);
      await expectLater(
        fixture.api.updateWorkItemLabels(
          current.target!,
          desiredLabelIds: [...current.snapshot.labelIds, addId],
        ),
        throwsA(writeFailure(FailureKind.conflict, mutationSent: false)),
      );
      expect(fixture.workItemLabelEvents, isEmpty);

      // Lost acknowledgement: server 503 during mutation ack
      final fresh = await _open(fixture, false);
      final freshCandidates = await fixture.api.searchWorkItemLabelCandidates(
        fresh.target!,
        searchTerm: 'priority',
        pageIndex: 0,
      );
      final freshAddId = freshCandidates.labels.first.id;
      fixture.failNextWorkItemLabelAcknowledgement = true;
      await expectLater(
        fixture.api.updateWorkItemLabels(
          fresh.target!,
          desiredLabelIds: [...fresh.snapshot.labelIds, freshAddId],
        ),
        throwsA(writeFailure(FailureKind.writeUncertain, mutationSent: true)),
      );
      expect(fixture.workItemLabelEvents, hasLength(1));

      // Fresh read confirms server applied the change
      final verified = await _open(fixture, false);
      expect(verified.snapshot.labelIds, contains(freshAddId));
    },
  );

  test(
    'allowsScopedLabels allowed/disabled/unknown does not falsely gate; scope keys and contrast',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);

      // Test allowed
      fixture.workItemLabelAllowsScoped = WorkItemLabelAllowsScoped.allowed;
      final allowedAccess = await _open(fixture, false);
      expect(
        allowedAccess.snapshot.allowsScopedLabels,
        WorkItemLabelAllowsScoped.allowed,
      );
      expect(allowedAccess.canWrite, isTrue);

      // Test disabled
      fixture.workItemLabelAllowsScoped = WorkItemLabelAllowsScoped.disabled;
      final disabledAccess = await _open(fixture, false);
      expect(
        disabledAccess.snapshot.allowsScopedLabels,
        WorkItemLabelAllowsScoped.disabled,
      );
      expect(disabledAccess.canWrite, isTrue);

      // Test unknown: does not falsely gate write
      fixture.workItemLabelAllowsScoped = WorkItemLabelAllowsScoped.unknown;
      final unknownAccess = await _open(fixture, false);
      expect(
        unknownAccess.snapshot.allowsScopedLabels,
        WorkItemLabelAllowsScoped.unknown,
      );
      expect(unknownAccess.canWrite, isTrue);

      // Verify scope key parsing on fixture labels
      fixture.setWorkItemLabelCount(group: false, count: 10);
      final labeled = await _open(fixture, false);
      final labelsByTitle = {
        for (final l in labeled.snapshot.labels) l.title: l,
      };

      expect(
        workItemLabelScopeKey('workflow::backend::review'),
        'workflow::backend',
      );
      expect(workItemLabelScopeKey('priority::high'), 'priority');
      expect(workItemLabelScopeKey('::value'), '');
      expect(workItemLabelScopeKey('a::'), 'a');
      expect(workItemLabelScopeKey('a:::b'), 'a:');
      expect(workItemLabelScopeKey('a::b::'), 'a::b');
      expect(workItemLabelScopeKey('a::b::c'), 'a::b');
      expect(workItemLabelScopeKey('範疇::前端::審查'), '範疇::前端');
      expect(workItemLabelScopeKey('plain'), isNull);

      // Verify contrast checking
      final contrastBad = labelsByTitle['contrast::bad']!;
      expect(
        workItemLabelContrastAccepted(
          contrastBad.color!,
          contrastBad.textColor!,
        ),
        isFalse,
      );
      final reviewLabel = labelsByTitle['workflow::backend::review']!;
      expect(
        workItemLabelContrastAccepted(
          reviewLabel.color!,
          reviewLabel.textColor!,
        ),
        isTrue,
      );
    },
  );

  test(
    'malformed read, revision drift during pagination and 2000 page cap',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);

      fixture.malformNextLabelRead = true;
      await expectLater(
        _open(fixture, false),
        throwsA(failure(FailureKind.unsupported)),
      );

      fixture.setWorkItemLabelCount(group: false, count: 120);
      fixture.workItemLabelRevisionDuringPagination = true;
      await expectLater(
        _open(fixture, false),
        throwsA(failure(FailureKind.unsupported)),
      );

      fixture.workItemLabelReads.clear();
      fixture.setWorkItemLabelCount(group: false, count: 2000);
      final complete2000 = await _open(fixture, false);
      expect(complete2000.snapshot.labels, hasLength(2000));
      expect(fixture.workItemLabelReads, hasLength(20));

      fixture.setWorkItemLabelCount(group: false, count: 2001);
      await expectLater(
        _open(fixture, false),
        throwsA(failure(FailureKind.unsupported)),
      );
    },
  );

  testWidgets('phone QA menu scrolls to the labels controls', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('emulator-qa-note-edit-controls'));
    await tester.tap(menu);
    await tester.pumpAndSettle();
    final option = find.text('允許標籤設定');
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(
        of: option,
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      ),
    );
    await tester.pump();
    expect(find.text('標籤設定：允許'), findsOneWidget);
    expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
  });
}
