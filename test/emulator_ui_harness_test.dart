import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';
import 'package:gitlab_mobile/core/work_item_health_edit_models.dart';
import 'package:gitlab_mobile/core/work_item_state_models.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/project_extras.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/shared/resource_share.dart';
import 'package:gitlab_mobile/shared/scroll_performance.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import '../tool/emulator_ui.dart';
import 'support/widget_settle.dart';
import 'support/work_item_health_parent_fixture.dart';

void main() {
  test(
    'activity fixture covers both scopes and all six server streams',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final project = await fixture.api.projectWorkItem(fixture.project, 31);
      final group = await fixture.api.namespaceWorkItem(
        'qa/synthetic-group',
        41,
        expectedNamespaceId: 'gid://gitlab/Group/84',
      );
      for (final detail in [project, group]) {
        for (final filter in WorkItemActivityFilter.values) {
          for (final order in WorkItemActivityOrder.values) {
            var page = await fixture.api.workItemActivity(
              detail.summary,
              filter: filter,
              order: order,
            );
            final discussions = [...page.snapshot.discussions.items];
            expect(discussions, hasLength(20));
            while (page.nextDiscussions != null) {
              page = await fixture.api.workItemActivityNext(
                page.nextDiscussions!,
              );
              expect(page.filter, filter);
              expect(page.order, order);
              discussions.addAll(page.snapshot.discussions.items);
            }
            expect(
              discussions,
              hasLength(filter == WorkItemActivityFilter.all ? 48 : 24),
            );
            expect(
              discussions.map((entry) => entry.id).toSet(),
              hasLength(discussions.length),
            );
            final timestamps = discussions
                .map((entry) => entry.createdAt)
                .toList();
            for (var i = 1; i < timestamps.length; i++) {
              expect(
                order == WorkItemActivityOrder.oldestFirst
                    ? timestamps[i].isAfter(timestamps[i - 1])
                    : timestamps[i].isBefore(timestamps[i - 1]),
                isTrue,
              );
            }
            final notes = discussions.expand((entry) => entry.notes.items);
            if (filter != WorkItemActivityFilter.all) {
              expect(
                notes.every(
                  (note) =>
                      note.system == (filter == WorkItemActivityFilter.history),
                ),
                isTrue,
              );
            }
          }
        }
      }
      expect(fixture.workItemStateEvents, isEmpty);
      expect(fixture.unhandled, isEmpty);
      expect(
        fixture.adapter.requests.every(
          (request) =>
              request.uri.host == 'qa.invalid' &&
              !((request.data as Map)['query'] as String).trimLeft().startsWith(
                'mutation',
              ),
        ),
        isTrue,
      );
    },
  );

  for (final group in [false, true]) {
    testWidgets(
      '320dp scaled ${group ? 'group' : 'project'} activity controls reach fresh pages',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 1100);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
        await tester.pumpAndSettle();
        final destination = find.text(group ? '群組 Work Item' : '專案 Work Item');
        await tester.scrollUntilVisible(destination, 200);
        await tester.pumpAndSettle();
        await tester.tap(destination);
        await settleNetworkWidgets(tester);
        await tester.scrollUntilVisible(find.text('活動'), 200);
        await tester.pumpAndSettle();
        await tester.tap(find.text('活動'));
        await settleNetworkWidgets(tester);
        for (final choice in [
          ('work-item-activity-order', '最新優先'),
          ('work-item-activity-filter', '只看留言'),
        ]) {
          final control = find.byKey(ValueKey(choice.$1));
          await tester.ensureVisible(control);
          await tester.pumpAndSettle();
          await tester.tap(control);
          await tester.pumpAndSettle();
          await tester.tap(find.text(choice.$2).last);
          await settleNetworkWidgets(tester);
        }
        expect(find.text('Synthetic comment 47'), findsOneWidget);
        expect(find.textContaining('Synthetic history 48'), findsNothing);
        await tester.ensureVisible(find.text('載入下一頁').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('載入下一頁').first);
        await settleNetworkWidgets(tester);
        expect(find.text('Synthetic comment 7'), findsOneWidget);
        expect(find.text('第 2 / 2 頁'), findsWidgets);
        await tester.ensureVisible(
          find.byKey(const ValueKey('work-item-activity-filter')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('work-item-activity-filter')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('只看歷史').last);
        await settleNetworkWidgets(tester);
        expect(find.textContaining('Synthetic history 48'), findsOneWidget);
        expect(find.text('Synthetic comment 7'), findsNothing);
        expect(find.text('第 1 / 1 頁'), findsWidgets);
        await tester.tap(find.text('結束 Session'));
        await settleNetworkWidgets(tester);
        expect(
          find.byKey(const ValueKey('work-item-activity-filter')),
          findsNothing,
        );
        expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('QA target refuses to build without the explicit dart define', () {
    expect(
      () => buildEmulatorQaApp(qaEnabled: false),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'performance fixture defaults off and preserves regular QA data',
    () async {
      expect(emulatorPerfQaEnabled, isFalse);
      final fixture = EmulatorQaFixture(performanceQa: false);
      addTearDown(fixture.api.close);

      expect(fixture.performanceQaEnabled, isFalse);
      expect(fixture.todoRows, hasLength(30));

      final projects = await fixture.api.projects(scope: ProjectScope.member);
      expect(projects.items, hasLength(1));
      expect(projects.items.single.id, 42);
      expect(projects.next, isNull);

      final version = await fixture.api.record([
        'projects',
        '42',
        'merge_requests',
        '12',
        'versions',
        '1',
      ]);
      final diffs = (version['diffs'] as List).cast<Json>();
      expect(diffs, hasLength(1));
      expect(diffs.single['new_path'], 'lib/session.dart');
      expect(utf8.encode(diffs.single['diff'] as String), hasLength(22));

      final sha = await fixture.api.defaultBranchSha(fixture.project);
      final root = await fixture.api.tree(42, sha);
      expect(root.items.map((entry) => entry.path), ['lib', 'README.md']);
      final readmeMetadata = await fixture.api.fileMetadata(
        42,
        'README.md',
        sha,
      );
      expect(readmeMetadata['size'], 80);
      final readme = await fixture.api.textFile(42, sha, 'README.md');
      expect(utf8.encode(readme), hasLength(65));
    },
  );

  test(
    'performance fixture exposes bounded current-schema MR changes',
    () async {
      final fixture = EmulatorQaFixture(performanceQa: true);
      addTearDown(fixture.api.close);

      expect(fixture.performanceQaEnabled, isTrue);
      final versions = await fixture.api.records([
        'projects',
        '42',
        'merge_requests',
        '12',
        'versions',
      ]);
      expect(versions.items, hasLength(1));
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
      expect(diffs.first['new_path'], 'lib/session.dart');
      expect(
        diffs.map((diff) => diff['new_path']).toSet(),
        hasLength(emulatorPerfQaChangedFileCount),
      );
      for (final diff in diffs) {
        expect(
          diff.keys,
          containsAll(const [
            'old_path',
            'new_path',
            'a_mode',
            'b_mode',
            'new_file',
            'renamed_file',
            'deleted_file',
            'generated_file',
            'too_large',
            'collapsed',
            'diff',
          ]),
        );
        expect(diff['old_path'], diff['new_path']);
        expect(diff['a_mode'], '100644');
        expect(diff['b_mode'], '100644');
        expect(diff['new_file'], isFalse);
        expect(diff['renamed_file'], isFalse);
        expect(diff['deleted_file'], isFalse);
        expect(diff['generated_file'], isFalse);
        expect(diff['too_large'], isFalse);
        expect(diff['collapsed'], isFalse);
      }

      final byteLengths = [
        for (final diff in diffs) utf8.encode(diff['diff'] as String).length,
      ];
      expect(byteLengths.where((bytes) => bytes > 64 * 1024), hasLength(1));
      expect(byteLengths.first, 156021);
      expect(byteLengths.first, lessThan(2 * 1024 * 1024));
      expect(
        const LineSplitter().convert(diffs.first['diff'] as String),
        hasLength(emulatorPerfQaLargeDiffLineCount),
      );
      final tinyByteLengths = byteLengths.skip(1).toList();
      expect(tinyByteLengths, hasLength(119));
      expect(tinyByteLengths.reduce(math.min), 25);
      expect(tinyByteLengths.reduce(math.max), 29);
      expect(byteLengths.reduce((left, right) => left + right), 159256);
    },
  );

  test(
    'performance repository tree serves an exact 20000-line UTF-8 file',
    () async {
      final fixture = EmulatorQaFixture(performanceQa: true);
      addTearDown(fixture.api.close);

      final sha = await fixture.api.defaultBranchSha(fixture.project);
      final root = await fixture.api.tree(42, sha);
      expect(
        root.items.where((entry) => entry.path == 'lib').single.isDirectory,
        isTrue,
      );
      final lib = await fixture.api.tree(42, sha, path: 'lib');
      final largeFile = lib.items.singleWhere(
        (entry) => entry.path == emulatorPerfQaLargeFilePath,
      );
      expect(largeFile.name, 'large_code.dart');
      expect(largeFile.isTextCandidate, isTrue);

      final metadata = await fixture.api.fileMetadata(
        42,
        emulatorPerfQaLargeFilePath,
        sha,
      );
      final source = await fixture.api.textFile(
        42,
        sha,
        emulatorPerfQaLargeFilePath,
      );
      final lines = const LineSplitter().convert(source);
      expect(lines, hasLength(emulatorPerfQaLargeFileLineCount));
      expect(utf8.encode(source), hasLength(748919));
      expect(metadata['size'], 748919);
      expect(lines[500], contains(emulatorPerfQaSearchTokenAlpha));
      expect(lines[15000], contains(emulatorPerfQaSearchTokenBeta));
      expect(lines[19000], contains(emulatorPerfQaDistantAnchor));
      expect(
        lines.where((line) => line.contains(emulatorPerfQaSearchTokenAlpha)),
        hasLength(1),
      );
      expect(
        lines.where((line) => line.contains(emulatorPerfQaSearchTokenBeta)),
        hasLength(1),
      );
      expect(
        lines.where((line) => line.contains(emulatorPerfQaDistantAnchor)),
        hasLength(1),
      );
    },
  );

  test('performance projects honor paging scopes and search', () async {
    final fixture = EmulatorQaFixture(performanceQa: true);
    addTearDown(fixture.api.close);

    final ids = <int>[];
    var page = await fixture.api.projects(scope: ProjectScope.member);
    expect(page.items, hasLength(30));
    expect(page.items.first.id, 42);
    while (true) {
      ids.addAll(page.items.map((project) => project.id));
      final next = page.next;
      if (next == null) break;
      expect(next.queryParameters['per_page'], '30');
      expect(next.queryParameters['membership'], 'true');
      page = await fixture.api.projects(scope: ProjectScope.member, next: next);
    }
    expect(ids, hasLength(emulatorPerfQaProjectCount));
    expect(ids.toSet(), hasLength(emulatorPerfQaProjectCount));
    expect(
      fixture.adapter.requests
          .where((request) => request.uri.path.endsWith('/api/v4/projects'))
          .map((request) => request.uri.queryParameters['page'] ?? '1'),
      ['1', '2', '3', '4'],
    );

    final starred = await fixture.api.projects(scope: ProjectScope.starred);
    expect(starred.items, hasLength(12));
    expect(starred.items.every((project) => project.id != 42), isTrue);
    expect(starred.next, isNull);

    final starResult = await fixture.api.setStar(42, true);
    expect(starResult?['star_count'], 13);
    final starredAfter = await fixture.api.projects(
      scope: ProjectScope.starred,
    );
    expect(starredAfter.items, hasLength(13));
    expect(starredAfter.items.first.id, 42);
    expect(starredAfter.next, isNull);

    final unstarResult = await fixture.api.setStar(42, false);
    expect(unstarResult?['star_count'], 12);
    final starredAfterUnstar = await fixture.api.projects(
      scope: ProjectScope.starred,
    );
    expect(starredAfterUnstar.items, hasLength(12));
    expect(
      starredAfterUnstar.items.every((project) => project.id != 42),
      isTrue,
    );
    expect(starredAfterUnstar.next, isNull);

    final search = await fixture.api.projects(
      scope: ProjectScope.accessibleSearch,
      search: 'performance project 119',
    );
    expect(search.items, hasLength(1));
    expect(search.items.single.name, 'Performance project 119');
    expect(search.next, isNull);
  });

  test(
    'performance projects star roundtrip updates live list, preserves historical snapshot and filters correctly',
    () async {
      final fixture = EmulatorQaFixture(performanceQa: true);
      addTearDown(fixture.api.close);

      // 1. Prime performance projects while unstarred.
      final primedRecords = await fixture.api.records(['projects']);
      expect(primedRecords.items, hasLength(30));
      final initialProjectSnapshot = primedRecords.items.first;
      expect(initialProjectSnapshot['id'], 42);
      expect(initialProjectSnapshot['star_count'], 12);
      expect(await fixture.api.hasStarred(42, 'developer'), isFalse);

      // Starred filter initially excludes 42, retains the 12 multiple-of-10 synthetic projects.
      final initialStarred = await fixture.api.projects(
        scope: ProjectScope.starred,
      );
      expect(initialStarred.items, hasLength(12));
      expect(initialStarred.items.any((project) => project.id == 42), isFalse);
      expect(
        initialStarred.items.map((project) => project.id).toList(),
        [for (var n = 10; n <= emulatorPerfQaProjectCount; n += 10) 1000 + n],
      );

      // 2. Star project 42 via actual POST API.
      final starResponse = await fixture.api.setStar(42, true);
      expect(starResponse?['id'], 42);
      expect(starResponse?['star_count'], 13);
      expect(await fixture.api.hasStarred(42, 'developer'), isTrue);

      // Fresh GET projects list reflects latest star_count 13 despite previous list reads.
      final listAfterStar = await fixture.api.records(['projects']);
      expect(listAfterStar.items.first['id'], 42);
      expect(listAfterStar.items.first['star_count'], 13);

      // Starred filter now includes project 42 once at index 0 (total 13 items).
      final starredAfter = await fixture.api.projects(
        scope: ProjectScope.starred,
      );
      expect(starredAfter.items, hasLength(13));
      expect(starredAfter.items.first.id, 42);
      expect(
        starredAfter.items.skip(1).map((project) => project.id).toList(),
        [for (var n = 10; n <= emulatorPerfQaProjectCount; n += 10) 1000 + n],
      );

      // 3. Repeated star preserves 13 (not 14).
      final repeatedStarResponse = await fixture.api.setStar(42, true);
      expect(repeatedStarResponse?['id'], 42);
      expect(repeatedStarResponse?['star_count'], 13);
      final listAfterRepeatedStar = await fixture.api.records(['projects']);
      expect(listAfterRepeatedStar.items.first['star_count'], 13);
      final starredAfterRepeated = await fixture.api.projects(
        scope: ProjectScope.starred,
      );
      expect(starredAfterRepeated.items, hasLength(13));
      expect(
        starredAfterRepeated.items.where((project) => project.id == 42),
        hasLength(1),
      );

      // 4. Unstar project 42 back to 12.
      final unstarResponse = await fixture.api.setStar(42, false);
      expect(unstarResponse?['id'], 42);
      expect(unstarResponse?['star_count'], 12);
      expect(await fixture.api.hasStarred(42, 'developer'), isFalse);

      // Fresh GET projects list reflects unstarred count 12.
      final listAfterUnstar = await fixture.api.records(['projects']);
      expect(listAfterUnstar.items.first['id'], 42);
      expect(listAfterUnstar.items.first['star_count'], 12);

      // Starred filter removes 42 while retaining the 12 multiple-of-10 rows.
      final starredAfterUnstar = await fixture.api.projects(
        scope: ProjectScope.starred,
      );
      expect(starredAfterUnstar.items, hasLength(12));
      expect(
        starredAfterUnstar.items.any((project) => project.id == 42),
        isFalse,
      );
      expect(
        starredAfterUnstar.items.map((project) => project.id).toList(),
        [for (var n = 10; n <= emulatorPerfQaProjectCount; n += 10) 1000 + n],
      );

      // Repeated unstar preserves 12.
      final repeatedUnstarResponse = await fixture.api.setStar(42, false);
      expect(repeatedUnstarResponse?['id'], 42);
      expect(repeatedUnstarResponse?['star_count'], 12);
      final listAfterRepeatedUnstar = await fixture.api.records(['projects']);
      expect(listAfterRepeatedUnstar.items.first['star_count'], 12);

      // 5. Response historical snapshot remains 12 after live 13 and live unstar.
      expect(initialProjectSnapshot['star_count'], 12);
      expect(listAfterStar.items.first['star_count'], 13);
      expect(listAfterUnstar.items.first['star_count'], 12);

      // 6. Paging and search match actual data.
      final searchWorkspace = await fixture.api.projects(
        scope: ProjectScope.accessibleSearch,
        search: 'mobile-workspace',
      );
      expect(searchWorkspace.items, hasLength(1));
      expect(searchWorkspace.items.single.id, 42);

      final searchTenthProject = await fixture.api.projects(
        scope: ProjectScope.starred,
        search: 'performance project 050',
      );
      expect(searchTenthProject.items, hasLength(1));
      expect(searchTenthProject.items.single.id, 1050);
    },
  );

  test(
    'regular QA projects star roundtrip honors starred filter, updates star counter and protects historical snapshot',
    () async {
      final fixture = EmulatorQaFixture(performanceQa: false);
      addTearDown(fixture.api.close);

      // Initial regular QA state
      final initialRecords = await fixture.api.records(['projects']);
      expect(initialRecords.items, hasLength(1));
      final initialSnapshot = initialRecords.items.single;
      expect(initialSnapshot['id'], 42);
      expect(initialSnapshot['star_count'], 12);

      final initialProjects = await fixture.api.projects(
        scope: ProjectScope.member,
      );
      expect(initialProjects.items, hasLength(1));
      expect(initialProjects.items.single.id, 42);

      // Starred filter initially excludes unstarred project 42
      final initialStarred = await fixture.api.projects(
        scope: ProjectScope.starred,
      );
      expect(initialStarred.items, isEmpty);
      expect(initialStarred.next, isNull);

      // Star project 42
      final starResult = await fixture.api.setStar(42, true);
      expect(starResult?['id'], 42);
      expect(starResult?['star_count'], 13);
      expect(await fixture.api.hasStarred(42, 'developer'), isTrue);

      // Starred filter now includes project 42
      final starredAfter = await fixture.api.projects(
        scope: ProjectScope.starred,
      );
      expect(starredAfter.items, hasLength(1));
      expect(starredAfter.items.single.id, 42);

      // Member list reflects 13
      final memberAfter = await fixture.api.records(['projects']);
      expect(memberAfter.items.single['star_count'], 13);

      // Repeated star stays 13 (not 14)
      final repeatedStar = await fixture.api.setStar(42, true);
      expect(repeatedStar?['id'], 42);
      expect(repeatedStar?['star_count'], 13);

      // Historical snapshot remains 12
      expect(initialSnapshot['star_count'], 12);

      // Unstar project 42
      final unstarResult = await fixture.api.setStar(42, false);
      expect(unstarResult?['id'], 42);
      expect(unstarResult?['star_count'], 12);
      expect(await fixture.api.hasStarred(42, 'developer'), isFalse);

      // Starred filter removes project 42
      final starredAfterUnstar = await fixture.api.projects(
        scope: ProjectScope.starred,
      );
      expect(starredAfterUnstar.items, isEmpty);

      // Member list reflects 12
      final memberAfterUnstar = await fixture.api.records(['projects']);
      expect(memberAfterUnstar.items.single['star_count'], 12);

      // Repeated unstar stays 12
      final repeatedUnstar = await fixture.api.setStar(42, false);
      expect(repeatedUnstar?['id'], 42);
      expect(repeatedUnstar?['star_count'], 12);

      // Historical snapshot remains 12
      expect(initialSnapshot['star_count'], 12);
    },
  );

  test(
    'performance endpoints support production paths and stay fail closed',
    () async {
      final fixture = EmulatorQaFixture(performanceQa: true);

      await fixture.api.record(['projects', '42']);
      await fixture.api.records(['projects', '42', 'merge_requests']);
      await fixture.api.record(['projects', '42', 'merge_requests', '12']);
      await fixture.api.records([
        'projects',
        '42',
        'merge_requests',
        '12',
        'versions',
      ]);
      await fixture.api.record([
        'projects',
        '42',
        'merge_requests',
        '12',
        'versions',
        '1',
      ]);
      final sha = await fixture.api.defaultBranchSha(fixture.project);
      await fixture.api.tree(42, sha);
      await fixture.api.tree(42, sha, path: 'lib');
      await fixture.api.fileMetadata(42, emulatorPerfQaLargeFilePath, sha);
      await fixture.api.textFile(42, sha, emulatorPerfQaLargeFilePath);

      final requested = fixture.adapter.requests
          .map(
            (request) =>
                '${request.method} ${request.uri.pathSegments.join('/')}',
          )
          .toList();
      expect(
        requested,
        containsAll(const [
          'GET gitlab/api/v4/projects/42',
          'GET gitlab/api/v4/projects/42/merge_requests',
          'GET gitlab/api/v4/projects/42/merge_requests/12',
          'GET gitlab/api/v4/projects/42/merge_requests/12/versions',
          'GET gitlab/api/v4/projects/42/merge_requests/12/versions/1',
          'GET gitlab/api/v4/projects/42/repository/branches/main',
          'GET gitlab/api/v4/projects/42/repository/tree',
          'HEAD gitlab/api/v4/projects/42/repository/files/lib/large_code.dart',
          'GET gitlab/api/v4/projects/42/repository/files/lib/large_code.dart/raw',
        ]),
      );
      expect(
        requested.where(
          (route) =>
              route ==
              'GET gitlab/api/v4/projects/42/merge_requests/12/versions/1',
        ),
        hasLength(1),
      );
      expect(
        requested.where(
          (route) => route == 'GET gitlab/api/v4/projects/42/repository/tree',
        ),
        hasLength(2),
      );
      expect(
        requested.where(
          (route) =>
              route ==
              'HEAD gitlab/api/v4/projects/42/repository/files/lib/large_code.dart',
        ),
        hasLength(2),
      );
      expect(
        requested.where(
          (route) =>
              route ==
              'GET gitlab/api/v4/projects/42/repository/files/lib/large_code.dart/raw',
        ),
        hasLength(1),
      );
      expect(
        fixture.adapter.requests.every(
          (request) =>
              request.uri.host == 'qa.invalid' &&
              request.uri.port == 8443 &&
              request.uri.path.startsWith('/gitlab/api/v4/'),
        ),
        isTrue,
      );

      await expectLater(
        fixture.api.record(['projects', '1002']),
        throwsA(
          isA<ApiFailure>().having((failure) => failure.status, 'status', 404),
        ),
      );
      await expectLater(
        fixture.api.record(['qa-performance-unknown']),
        throwsA(
          isA<ApiFailure>().having((failure) => failure.status, 'status', 404),
        ),
      );
      expect(fixture.unhandled, contains('GET projects/1002'));
      expect(fixture.unhandled, contains('GET qa-performance-unknown'));

      fixture.api.close();
      await expectLater(
        fixture.api.record(['projects', '42']),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
    },
  );

  test(
    'fixture is synthetic, deterministic, and closed to unknown endpoints',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);

      expect(fixture.api.instance.base.scheme, 'https');
      expect(fixture.api.instance.base.host, 'qa.invalid');
      expect(fixture.api.instance.base.port, 8443);
      expect(fixture.api.instance.base.path, '/gitlab');
      expect(fixture.account.user.id, 7);
      expect(fixture.project.id, 42);
      expect(fixture.todoRows, hasLength(30));
      expect(
        fixture.todoRows.first['target'],
        containsPair('title', 'Synthetic mobile QA todo 01'),
      );
      expect(fixture.environmentRows, hasLength(120));
      expect(fixture.environmentRows.first['id'], 17);
      expect(fixture.environmentRows.first['name'], 'staging/mobile');
      expect(fixture.deploymentRows, hasLength(120));

      final deploymentJob = await fixture.api.record([
        'projects',
        '42',
        'jobs',
        '5120',
      ]);
      expect(deploymentJob['id'], 5120);
      expect(
        await fixture.api.jobTrace(42, 5001),
        contains('[synthetic qa] deployment job 5001'),
      );
      await expectLater(
        fixture.api.record(['projects', '42', 'jobs', '5121']),
        throwsA(
          isA<ApiFailure>().having((failure) => failure.status, 'status', 404),
        ),
      );

      expect(await fixture.api.hasStarred(42, 'developer'), isFalse);
      final starred = await fixture.api.setStar(42, true);
      expect(starred?['star_count'], 13);
      expect(await fixture.api.hasStarred(42, 'developer'), isTrue);
      await fixture.api.playPipelineSchedule(42, 3);
      expect(fixture.playedSchedules, [3]);

      await expectLater(
        fixture.api.record(['qa-unknown-endpoint']),
        throwsA(
          isA<ApiFailure>().having((failure) => failure.status, 'status', 404),
        ),
      );
      expect(fixture.unhandled, contains('GET qa-unknown-endpoint'));
      expect(
        fixture.adapter.requests.every(
          (request) =>
              request.uri.host == 'qa.invalid' &&
              request.uri.port == 8443 &&
              request.uri.path.startsWith('/gitlab/api/v4/'),
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'QA project navigation reaches repository and MR changes directly',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1200);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('專案頁面'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('專案頁面'));
      await settleNetworkWidgets(tester);

      expect(find.text('Emulator UI QA'), findsNothing);
      expect(find.text('檔案'), findsOneWidget);
      expect(find.byType(RepositoryTab), findsOneWidget);
      expect(find.text('README.md'), findsWidgets);

      await tester.tap(find.text('MR'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('Improve private-project navigation'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('變更'));
      await settleNetworkWidgets(tester);

      expect(find.text('lib/session.dart'), findsOneWidget);
      expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('banner and QA controls persist across production routes', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var semanticsDisposed = false;
    void disposeSemantics() {
      if (semanticsDisposed) return;
      semanticsDisposed = true;
      semantics.dispose();
    }

    addTearDown(disposeSemantics);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    try {
      await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
      await tester.pumpAndSettle();

      expect(find.byType(ScrollPerformance), findsOneWidget);
      expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
      expect(find.text('重設 Session'), findsOneWidget);
      expect(find.text('結束 Session'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(find.text('環境與部署'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('環境與部署'));
      await settleNetworkWidgets(tester);

      expect(find.byType(EnvironmentsPage), findsOneWidget);
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(EnvironmentsPage)),
        ).scale(14),
        28,
      );
      expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
      expect(find.text('staging/mobile'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('合成資料 QA.*來源 $emulatorUiQaCommit')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('重設 Session'), findsOneWidget);
      expect(find.bySemanticsLabel('結束 Session'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('staging/mobile'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('#120'));
      await settleNetworkWidgets(tester);

      expect(find.byType(JobLogPage), findsOneWidget);
      expect(find.textContaining('deployment job 5120'), findsOneWidget);
      expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      disposeSemantics();
    }
  });

  test(
    'project and group QA state changes stay in memory and read back independently',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final project = await fixture.api.projectWorkItem(fixture.project, 31);
      final group = await fixture.api.namespaceWorkItem(
        'qa/synthetic-group',
        41,
        expectedNamespaceId: 'gid://gitlab/Group/84',
      );
      for (final item in [project, group]) {
        final before = await fixture.api.workItemState(item.summary);
        expect(before.state, WorkItemState.open);
        expect(before.canUpdate, isTrue);
        final changed = await fixture.api.updateWorkItemState(
          item.summary,
          WorkItemStateEvent.close,
          expectedUpdatedAt: before.updatedAt,
        );
        final readback = await fixture.api.workItemState(item.summary);
        expect(changed.state, WorkItemState.closed);
        expect(readback.state, WorkItemState.closed);
        expect(readback.updatedAt, changed.updatedAt);
      }
      expect(fixture.workItemStateEvents, ['CLOSE', 'CLOSE']);
      expect(fixture.unhandled, isEmpty);
      expect(
        fixture.adapter.requests.every(
          (request) =>
              request.uri.host == 'qa.invalid' &&
              request.uri.port == 8443 &&
              request.uri.path == '/gitlab/api/graphql',
        ),
        isTrue,
      );
    },
  );

  for (final group in [false, true]) {
    testWidgets(
      'scaled ${group ? 'group' : 'project'} Work Item can cancel, close, reopen and invalidate its dialog',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 1100);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
        await tester.pumpAndSettle();
        final destination = find.text(group ? '群組 Work Item' : '專案 Work Item');
        await tester.scrollUntilVisible(destination, 200);
        await tester.pumpAndSettle();
        await tester.tap(destination);
        await settleNetworkWidgets(tester);
        expect(
          find.text(
            group ? 'Synthetic group Work Item' : 'Synthetic project Work Item',
          ),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('work-item-state-control')),
          200,
        );
        await settleNetworkWidgets(tester);
        final close = find.text('關閉工作項目');
        await tester.ensureVisible(close);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.text('關閉工作項目？'), findsOneWidget);
        expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.text('目前為開啟'), findsOneWidget);
        await tester.tap(close);
        await tester.pumpAndSettle();
        await tester.tap(find.text('確認關閉'));
        await settleNetworkWidgets(tester);
        expect(find.text('目前為已關閉'), findsOneWidget);
        final reopen = find.text('重新開啟');
        await tester.ensureVisible(reopen);
        await tester.tap(reopen);
        await tester.pumpAndSettle();
        await tester.tap(find.text('確認重開'));
        await settleNetworkWidgets(tester);
        expect(find.text('目前為開啟'), findsOneWidget);
        await tester.ensureVisible(close);
        await tester.tap(close);
        await tester.pumpAndSettle();
        await tester.tap(find.text('結束 Session'));
        await settleNetworkWidgets(tester);
        expect(find.text('關閉工作項目？'), findsNothing);
        expect(find.text('確認關閉'), findsNothing);
        expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('compact scaled schedule confirmation keeps the QA chrome', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Pipeline 排程'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pipeline 排程'));
    await settleNetworkWidgets(tester);

    expect(
      MediaQuery.textScalerOf(
        tester.element(find.byType(PipelineSchedulesPage)),
      ).scale(14),
      28,
    );
    await tester.tap(find.byTooltip('立即執行').first);
    await tester.pumpAndSettle();

    expect(find.text('立即執行排程？'), findsOneWidget);
    expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('立即執行排程？'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'authenticated shell restores system insets and fits every tab at 320 dp with scaled text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 1100);
      tester.view.padding = const FakeViewPadding(top: 36, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 36, bottom: 24);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('主畫面與底部導航'));
      await settleNetworkWidgets(tester);

      final viewport = tester.element(
        find.byKey(const ValueKey('emulator-qa-shell-viewport')),
      );
      final media = MediaQuery.of(viewport);
      expect(media.padding.top, 36);
      expect(media.padding.bottom, 24);
      expect(media.textScaler.scale(14), 28);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '專案');

      for (final destination in ['收件匣', 'CI', '我的', '專案']) {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(destination),
          ),
        );
        await settleNetworkWidgets(tester);
        if (destination == '收件匣') {
          expect(find.text('Synthetic mobile QA todo 01'), findsOneWidget);
        }
        expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: destination);
      }
    },
  );

  testWidgets('end and reset discard the old authenticated QA shell', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('主畫面與底部導航'));
    await settleNetworkWidgets(tester);
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.tap(find.text('結束 Session'));
    await settleNetworkWidgets(tester);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);

    await tester.tap(find.text('重設 Session'));
    await tester.pumpAndSettle();
    expect(find.text('Emulator UI QA'), findsOneWidget);
    expect(find.text('主畫面與底部導航'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.tap(find.text('主畫面與底部導航'));
    await settleNetworkWidgets(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('end and reset controls invalidate and restore the QA session', (
    tester,
  ) async {
    await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Pipeline 排程'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pipeline 排程'));
    await settleNetworkWidgets(tester);
    expect(find.byType(PipelineSchedulesPage), findsOneWidget);
    expect(find.text('Nightly synthetic build'), findsOneWidget);

    await tester.tap(find.text('結束 Session'));
    await settleNetworkWidgets(tester);
    expect(find.text('Nightly synthetic build'), findsNothing);
    expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);

    await tester.tap(find.text('重設 Session'));
    await tester.pumpAndSettle();
    expect(find.text('Emulator UI QA'), findsOneWidget);
    expect(find.text('專案頁面'), findsOneWidget);
    expect(find.text('Pipeline 排程'), findsOneWidget);
    expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
  });

  testWidgets(
    'Dates QA destination mounts GraphWorkItemDetailPage with Dates section and chips across project and group scopes',
    (tester) async {
      await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Work Item 日期 (Dates Parent QA)'),
        200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work Item 日期 (Dates Parent QA)'));
      await settleNetworkWidgets(tester);

      expect(find.byType(DatesParentQaScreen), findsOneWidget);
      expect(find.byType(GraphWorkItemDetailPage), findsOneWidget);
      final projectScrollable = find.descendant(
        of: find.byType(GraphWorkItemDetailPage),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('work-item-dates-section')),
        200,
        scrollable: projectScrollable,
      );
      expect(
        find.byKey(const ValueKey('work-item-dates-section')),
        findsOneWidget,
      );
      expect(find.text('開始 2026/10/10'), findsOneWidget);
      expect(find.text('到期 2026/10/20'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work-item-dates-edit')),
        findsOneWidget,
      );

      await tester.tap(find.text('群組'));
      await settleNetworkWidgets(tester);

      expect(find.byType(GraphWorkItemDetailPage), findsOneWidget);
      final groupScrollable = find.descendant(
        of: find.byType(GraphWorkItemDetailPage),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('work-item-dates-section')),
        200,
        scrollable: groupScrollable,
      );
      expect(
        find.byKey(const ValueKey('work-item-dates-section')),
        findsOneWidget,
      );
      expect(find.text('開始 2026/11/01'), findsOneWidget);
      expect(find.text('到期 2026/11/30'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Dates QA save flow mutates server state and updates parent chips and ledger',
    (tester) async {
      await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Work Item 日期 (Dates Parent QA)'),
        200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work Item 日期 (Dates Parent QA)'));
      await settleNetworkWidgets(tester);

      final datesScrollable = find.descendant(
        of: find.byType(GraphWorkItemDetailPage),
        matching: find.byType(Scrollable),
      );
      final editButton = find.byKey(const ValueKey('work-item-dates-edit'));
      await tester.scrollUntilVisible(
        editButton,
        200,
        scrollable: datesScrollable,
      );
      await tester.ensureVisible(editButton);
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () {
          final matches = editButton.evaluate();
          if (matches.isEmpty) return false;
          final renderBox = matches.first.findRenderObject() as RenderBox?;
          return renderBox != null &&
              renderBox.hasSize &&
              !renderBox.size.isEmpty &&
              editButton.hitTestable().evaluate().isNotEmpty;
        },
        description: 'waiting for editButton layout and hit test readiness',
      );

      await tester.tap(editButton);
      await settleNetworkWidgets(tester);

      expect(find.text('編輯日期'), findsOneWidget);
      final editorScrollable = find.descendant(
        of: find.byKey(const ValueKey('work-item-dates-scroll')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              (widget.axisDirection == AxisDirection.down ||
                  widget.axisDirection == AxisDirection.up),
        ),
      );
      expect(editorScrollable, findsOneWidget);
      final dueInput = find.descendant(
        of: find.byKey(const ValueKey('work-item-dates-scroll')),
        matching: find.byKey(const ValueKey('work-item-dates-due-input')),
      );
      await tester.scrollUntilVisible(
        dueInput,
        150,
        scrollable: editorScrollable,
      );
      await tester.ensureVisible(dueInput);
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () {
          final matches = dueInput.evaluate();
          if (matches.isEmpty) return false;
          final widget = matches.first.widget;
          if (widget is! TextField || widget.enabled != true) return false;
          final editable = find
              .descendant(of: dueInput, matching: find.byType(EditableText))
              .evaluate();
          if (editable.isEmpty) return false;
          final renderBox = matches.first.findRenderObject() as RenderBox?;
          return renderBox != null &&
              renderBox.hasSize &&
              !renderBox.size.isEmpty &&
              dueInput.hitTestable().evaluate().isNotEmpty;
        },
        description: 'waiting for due-input TextField layout and editability',
      );
      await tester.enterText(dueInput, '2026-10-25');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
      await settleNetworkWidgets(tester);

      expect(find.text('編輯日期'), findsNothing);
      expect(find.text('到期 2026/10/25'), findsOneWidget);

      final ledgerButton = find.byKey(const ValueKey('dates-qa-view-ledger'));
      final footerScrollable = find.ancestor(
        of: ledgerButton,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              (widget.axisDirection == AxisDirection.right ||
                  widget.axisDirection == AxisDirection.left),
        ),
      );
      expect(footerScrollable, findsOneWidget);
      await tester.scrollUntilVisible(
        ledgerButton,
        150,
        scrollable: footerScrollable,
      );
      await tester.ensureVisible(ledgerButton);
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () {
          final matches = ledgerButton.evaluate();
          if (matches.isEmpty) return false;
          final renderBox = matches.first.findRenderObject() as RenderBox?;
          return renderBox != null &&
              renderBox.hasSize &&
              !renderBox.size.isEmpty &&
              ledgerButton.hitTestable().evaluate().isNotEmpty;
        },
        description: 'waiting for ledgerButton layout and hit test readiness',
      );

      await tester.tap(ledgerButton);
      await tester.pumpAndSettle();

      expect(find.text('網路紀錄與計數（開啟時快照）'), findsOneWidget);

      final eeOperation = find.textContaining('MobileSetWorkItemDatesEe');
      final sheetScrollable = find.descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              (widget.axisDirection == AxisDirection.down ||
                  widget.axisDirection == AxisDirection.up),
        ),
      );
      if (sheetScrollable.evaluate().isNotEmpty &&
          (eeOperation.evaluate().isEmpty ||
              eeOperation.hitTestable().evaluate().isEmpty)) {
        await tester.scrollUntilVisible(
          eeOperation,
          100,
          scrollable: sheetScrollable,
        );
      }
      await tester.ensureVisible(eeOperation);
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () {
          final matches = eeOperation.evaluate();
          if (matches.isEmpty) return false;
          final renderBox = matches.first.findRenderObject() as RenderBox?;
          return renderBox != null &&
              renderBox.hasSize &&
              !renderBox.size.isEmpty &&
              eeOperation.hitTestable().evaluate().isNotEmpty;
        },
        description: 'waiting for eeOperation layout and hit test readiness',
      );
      expect(eeOperation, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Dates QA held write disables observer B and competing actions then settles',
    (tester) async {
      await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Work Item 日期 (Dates Parent QA)'),
        200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work Item 日期 (Dates Parent QA)'));
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('A/B'));
      await settleNetworkWidgets(tester);

      expect(find.byType(GraphWorkItemDetailPage), findsNWidgets(2));

      await tester.tap(
        find.byKey(const ValueKey('dates-qa-hold-apply')),
      );
      await tester.pumpAndSettle();

      final paneAScrollable = find.descendant(
        of: find.byKey(const ValueKey('dates-qa-split-pane-a')),
        matching: find.byType(Scrollable),
      );
      final paneBScrollable = find.descendant(
        of: find.byKey(const ValueKey('dates-qa-split-pane-b')),
        matching: find.byType(Scrollable),
      );
      final editA = find.descendant(
        of: find.byKey(const ValueKey('dates-qa-split-pane-a')),
        matching: find.byKey(const ValueKey('work-item-dates-edit')),
      );
      final editB = find.descendant(
        of: find.byKey(const ValueKey('dates-qa-split-pane-b')),
        matching: find.byKey(const ValueKey('work-item-dates-edit')),
      );

      await tester.scrollUntilVisible(editA, 200, scrollable: paneAScrollable);
      await tester.ensureVisible(editA);
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(editB, 200, scrollable: paneBScrollable);
      await tester.ensureVisible(editB);
      await tester.pumpAndSettle();

      await pumpUntil(
        tester,
        () {
          final matches = editA.evaluate();
          if (matches.isEmpty) return false;
          final renderBox = matches.first.findRenderObject() as RenderBox?;
          return renderBox != null &&
              renderBox.hasSize &&
              !renderBox.size.isEmpty &&
              editA.hitTestable().evaluate().isNotEmpty;
        },
        description: 'waiting for editA layout and hit test readiness',
      );

      await tester.tap(editA);
      await settleNetworkWidgets(tester);

      final editorScrollableA = find.descendant(
        of: find.byKey(const ValueKey('dates-qa-split-pane-a')),
        matching: find.descendant(
          of: find.byKey(const ValueKey('work-item-dates-scroll')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                (widget.axisDirection == AxisDirection.down ||
                    widget.axisDirection == AxisDirection.up),
          ),
        ),
      );
      expect(editorScrollableA, findsOneWidget);
      final dueInputA = find.descendant(
        of: find.byKey(const ValueKey('dates-qa-split-pane-a')),
        matching: find.byKey(const ValueKey('work-item-dates-due-input')),
      );
      await tester.scrollUntilVisible(
        dueInputA,
        150,
        scrollable: editorScrollableA,
      );
      await tester.ensureVisible(dueInputA);
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () {
          final matches = dueInputA.evaluate();
          if (matches.isEmpty) return false;
          final widget = matches.first.widget;
          if (widget is! TextField || widget.enabled != true) return false;
          final editable = find
              .descendant(of: dueInputA, matching: find.byType(EditableText))
              .evaluate();
          if (editable.isEmpty) return false;
          final renderBox = matches.first.findRenderObject() as RenderBox?;
          return renderBox != null &&
              renderBox.hasSize &&
              !renderBox.size.isEmpty &&
              dueInputA.hitTestable().evaluate().isNotEmpty;
        },
        description:
            'waiting for pane A due-input TextField layout and editability',
      );
      await tester.enterText(dueInputA, '2026-10-28');
      await tester.pumpAndSettle();

      final saveA = find.descendant(
        of: find.byKey(const ValueKey('dates-qa-split-pane-a')),
        matching: find.byKey(const ValueKey('work-item-dates-save')),
      );
      await tester.tap(saveA);
      await pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('work-item-dates-hold'), skipOffstage: false)
            .evaluate()
            .isNotEmpty,
        description: 'Dates write START held at fixture',
      );

      expect(find.byKey(const ValueKey('work-item-dates-hold')), findsWidgets);
      expect(
        tester.widget<TextButton>(
          find.byKey(const ValueKey('work-item-dates-edit')).last,
        ).onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('dates-qa-release-holds')));
      await settleNetworkWidgets(tester);

      expect(find.text('到期 2026/10/28'), findsWidgets);
      expect(find.byKey(const ValueKey('work-item-dates-hold')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Dates QA owner loss during held write blocks late paint',
    (tester) async {
      await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Work Item 日期 (Dates Parent QA)'),
        200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work Item 日期 (Dates Parent QA)'));
      await settleNetworkWidgets(tester);

      await tester.tap(
        find.byKey(const ValueKey('dates-qa-hold-apply')),
      );
      await tester.pumpAndSettle();

      final datesScrollable = find.descendant(
        of: find.byType(GraphWorkItemDetailPage),
        matching: find.byType(Scrollable),
      );
      final editButton = find.byKey(const ValueKey('work-item-dates-edit'));
      await tester.scrollUntilVisible(
        editButton,
        200,
        scrollable: datesScrollable,
      );
      await tester.ensureVisible(editButton);
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () {
          final matches = editButton.evaluate();
          if (matches.isEmpty) return false;
          final renderBox = matches.first.findRenderObject() as RenderBox?;
          return renderBox != null &&
              renderBox.hasSize &&
              !renderBox.size.isEmpty &&
              editButton.hitTestable().evaluate().isNotEmpty;
        },
        description: 'waiting for editButton layout and hit test readiness',
      );

      await tester.tap(editButton);
      await settleNetworkWidgets(tester);

      expect(find.text('編輯日期'), findsOneWidget);
      final editorScrollable = find.descendant(
        of: find.byKey(const ValueKey('work-item-dates-scroll')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              (widget.axisDirection == AxisDirection.down ||
                  widget.axisDirection == AxisDirection.up),
        ),
      );
      expect(editorScrollable, findsOneWidget);
      final dueInput = find.descendant(
        of: find.byKey(const ValueKey('work-item-dates-scroll')),
        matching: find.byKey(const ValueKey('work-item-dates-due-input')),
      );
      await tester.scrollUntilVisible(
        dueInput,
        150,
        scrollable: editorScrollable,
      );
      await tester.ensureVisible(dueInput);
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () {
          final matches = dueInput.evaluate();
          if (matches.isEmpty) return false;
          final widget = matches.first.widget;
          if (widget is! TextField || widget.enabled != true) return false;
          final editable = find
              .descendant(of: dueInput, matching: find.byType(EditableText))
              .evaluate();
          if (editable.isEmpty) return false;
          final renderBox = matches.first.findRenderObject() as RenderBox?;
          return renderBox != null &&
              renderBox.hasSize &&
              !renderBox.size.isEmpty &&
              dueInput.hitTestable().evaluate().isNotEmpty;
        },
        description: 'waiting for due-input TextField layout and editability',
      );

      await tester.enterText(dueInput, '2026-10-29');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
      await pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('work-item-dates-hold'), skipOffstage: false)
            .evaluate()
            .isNotEmpty,
        description: 'Dates write START held at fixture',
      );

      expect(find.text('正在儲存…'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('dates-qa-toggle-session')));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('dates-qa-release-holds')));
      await settleNetworkWidgets(tester);

      expect(find.text('帳號已切換，工作項目頁面已關閉。'), findsOneWidget);
      expect(find.text('到期 2026/10/29'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Health QA destination mounts GraphWorkItemDetailPage with Health section and chips across project and group scopes',
    (tester) async {
      _useSurface(tester, const Size(1080, 2400));
      final fixture = WorkItemHealthParentFixture();
      addTearDown(fixture.closeAll);
      await tester.pumpWidget(
        MaterialApp(
          home: HealthParentQaScreen(fixture: fixture),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(find.byType(HealthParentQaScreen), findsOneWidget);
      expect(find.byType(GraphWorkItemDetailPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('health-qa-witness-strip')),
        findsOneWidget,
      );

      final healthSection =
          find.byKey(const ValueKey('work-item-health-section'));
      await tester.scrollUntilVisible(
        healthSection,
        200,
        scrollable: _detailScrollable(null),
      );
      expect(healthSection, findsOneWidget);
      await _expandAttributes(tester);
      await pumpUntil(
        tester,
        () => _shows(find.text('目前：正常')),
        description: 'project attributes read item X Health',
      );
      expect(find.text('目前：正常'), findsOneWidget);
      expect(find.text('彙整：正常 1'), findsOneWidget);
      expect(
        fixture.detailReads(item: WorkItemHealthParentFixture.itemX),
        1,
      );

      await _tapHealthSegment(tester, '群組');

      expect(find.byType(GraphWorkItemDetailPage), findsOneWidget);
      await tester.scrollUntilVisible(
        healthSection,
        200,
        scrollable: _detailScrollable(null),
      );
      expect(healthSection, findsOneWidget);
      await _expandAttributes(tester);
      await pumpUntil(
        tester,
        () => _shows(find.text('目前：需關注')),
        description: 'group attributes read item Y Health',
      );
      expect(find.text('目前：需關注'), findsOneWidget);
      expect(find.text('彙整：沒有資料'), findsOneWidget);
      expect(find.text('目前：正常'), findsNothing);
      expect(
        fixture.detailReads(item: WorkItemHealthParentFixture.itemY),
        1,
      );
      expect(fixture.unhandled, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Health QA held write and ledger controls reflect stage counts and settle correctly',
    (tester) async {
      _useSurface(tester, const Size(1080, 2400));
      final fixture = WorkItemHealthParentFixture();
      addTearDown(fixture.closeAll);
      await tester.pumpWidget(
        MaterialApp(
          home: HealthParentQaScreen(fixture: fixture),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(
        find.byKey(const ValueKey('health-qa-witness-strip')),
        findsOneWidget,
      );
      expect(find.textContaining('寫入 0 · 套用 0'), findsOneWidget);

      await _expandAttributes(tester);
      await pumpUntil(
        tester,
        () => _shows(find.text('目前：正常')),
        description: 'attributes read the server Health before the write',
      );

      await _tapQaControl(tester, 'health-qa-hold-apply');
      await _expectLedger(tester, ['寫入請求: 0', '已套用: 0', '等待Apply: 0']);

      await _openHealthEditor(tester);
      await _chooseHealth(tester, 'needsAttention');
      final editsBeforeSave =
          fixture.editReads(item: WorkItemHealthParentFixture.itemX);
      final detailsBeforeSave =
          fixture.detailReads(item: WorkItemHealthParentFixture.itemX);
      await tester.tap(_healthSave());
      await pumpUntil(
        tester,
        () => fixture.awaitingApply,
        description: 'mutation parked before apply',
      );

      expect(fixture.healthMutationRequests, 1);
      expect(fixture.healthApplied, 0);
      expect(
        fixture.editReads(item: WorkItemHealthParentFixture.itemX),
        editsBeforeSave + 1,
        reason: 'save preflight read only; no readback while held',
      );
      await _tapQaControl(tester, 'health-qa-refresh-witness');
      expect(find.textContaining('寫入 1 · 套用 0'), findsOneWidget);
      await _expectLedger(tester, ['寫入請求: 1', '已套用: 0', '等待Apply: 1']);

      await _tapQaControl(tester, 'health-qa-release-holds');
      await pumpUntil(
        tester,
        () => fixture.healthApplied == 1,
        description: 'held mutation applied after release',
      );
      await pumpUntil(
        tester,
        () => _shows(find.text('目前：需關注')),
        description: 'expanded attributes re-read the applied value',
      );

      expect(
        fixture.health[WorkItemHealthParentFixture.itemX]?.value,
        WorkItemHealthEditValue.needsAttention,
      );
      expect(find.text('目前：需關注'), findsOneWidget);
      expect(find.text('目前：正常'), findsNothing);
      expect(_healthSave(), findsNothing, reason: 'bumped reload dismisses the editor');
      expect(
        find.byKey(const ValueKey('work-item-health-stale')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('work-item-health-unconfirmed')),
        findsNothing,
      );
      expect(
        fixture.editReads(item: WorkItemHealthParentFixture.itemX),
        editsBeforeSave + 2,
        reason: 'preflight plus one readback',
      );
      expect(
        fixture.detailReads(item: WorkItemHealthParentFixture.itemX),
        detailsBeforeSave + 1,
        reason: 'one detail reload after the settled write',
      );

      await _tapQaControl(tester, 'health-qa-refresh-witness');
      expect(find.textContaining('寫入 1 · 套用 1'), findsOneWidget);
      await _expectLedger(tester, ['寫入請求: 1', '已套用: 1', '等待Apply: 0']);

      expect(fixture.unhandled, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Health QA owner loss during held write blocks late paint',
    (tester) async {
      _useSurface(tester, const Size(1080, 2400));
      final fixture = WorkItemHealthParentFixture();
      addTearDown(fixture.closeAll);
      await tester.pumpWidget(
        MaterialApp(
          home: HealthParentQaScreen(fixture: fixture),
        ),
      );
      await settleNetworkWidgets(tester);

      await _expandAttributes(tester);
      await pumpUntil(
        tester,
        () => _shows(find.text('目前：正常')),
        description: 'attributes read before the write',
      );

      await _tapQaControl(tester, 'health-qa-hold-apply');
      await _openHealthEditor(tester);
      await _chooseHealth(tester, 'atRisk');
      await tester.tap(_healthSave());
      await pumpUntil(
        tester,
        () => fixture.awaitingApply,
        description: 'mutation parked before apply',
      );

      expect(fixture.healthMutationRequests, 1);
      expect(fixture.healthApplied, 0);
      final detailsHeld = fixture.detailReads();
      final editsHeld = fixture.editReads();
      final attributesHeld = fixture.attributeReads();

      await _tapQaControl(tester, 'health-qa-toggle-session');
      await _tapQaControl(tester, 'health-qa-release-holds');
      await pumpUntil(
        tester,
        () => fixture.healthApplied == 1,
        description: 'server applies the already-sent mutation',
      );
      await settleNetworkWidgets(tester);

      expect(find.text('帳號已切換，工作項目頁面已關閉。'), findsOneWidget);
      expect(fixture.detailReads(), detailsHeld);
      expect(fixture.editReads(), editsHeld);
      expect(fixture.attributeReads(), attributesHeld);
      expect(find.text('目前：有風險'), findsNothing);
      expect(_healthSave(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Display QA destination mounts and double-tapped display options sheet deduplicates route with 12 tier switches',
    (tester) async {
      _useSurface(tester, const Size(1080, 2400));
      await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('工作項目顯示 (Display QA)'),
        200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('工作項目顯示 (Display QA)'));
      await settleNetworkWidgets(tester);

      expect(find.byType(WorkItemsDisplayQaScreen), findsOneWidget);
      await pumpUntil(
        tester,
        () => _shows(_displayRow()),
        description: 'group rows loaded',
      );
      final optionsButton =
          find.byKey(const Key('graph-work-items-display-options-button'));
      expect(optionsButton, findsOneWidget);

      final center = tester.getCenter(optionsButton);
      await tester.tap(optionsButton);
      await tester.tapAt(center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('顯示設定'), findsOneWidget);
      for (final title in [
        ..._supportedDisplayTiles,
        ..._unsupportedDisplayTiles,
      ]) {
        await _revealDisplayTile(tester, title);
        expect(_displayTile(title), findsOneWidget);
      }

      // Group preference change must not leak into the project variant.
      final labels = await _revealDisplayTile(tester, '標籤');
      expect(labels.value, isTrue);
      await tester.tap(_displayTile('標籤'));
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(_displayTile('標籤')).value,
        isFalse,
      );
      await _closeDisplaySheet(tester);
      expect(
        find.descendant(of: _displayRow(), matching: find.text('qa-label')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('display-qa-variant-project')));
      await settleNetworkWidgets(tester);
      await pumpUntil(
        tester,
        () => _shows(_displayRow()),
        description: 'project rows loaded',
      );
      expect(find.byType(FailureNotice), findsNothing);
      expect(
        find.descendant(of: _displayRow(), matching: find.text('qa-label')),
        findsOneWidget,
      );
      await _openDisplaySheet(tester);
      for (final title in _supportedDisplayTiles) {
        expect((await _revealDisplayTile(tester, title)).value, isTrue);
      }
      await _closeDisplaySheet(tester);
      await _openDisplaySheet(tester);
      await _revealDisplayTile(tester, '標籤');
      await tester.tap(_displayTile('標籤'));
      await tester.pump();
      await _closeDisplaySheet(tester);
      expect(
        find.descendant(of: _displayRow(), matching: find.text('qa-label')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('display-qa-variant-group')));
      await settleNetworkWidgets(tester);
      await pumpUntil(
        tester,
        () => _shows(_displayRow()),
        description: 'group rows reloaded',
      );
      expect(
        find.descendant(of: _displayRow(), matching: find.text('qa-label')),
        findsOneWidget,
      );
      await _openDisplaySheet(tester);
      for (final title in _supportedDisplayTiles) {
        expect((await _revealDisplayTile(tester, title)).value, isTrue);
      }
      await _closeDisplaySheet(tester);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Display QA loaded rows expose partial connection accessible label and support project and group route variants',
    (tester) async {
      _useSurface(tester, const Size(1080, 2400));
      final fixture = EmulatorQaFixture();
      final session = _qaSession(fixture);
      addTearDown(session.dispose);
      await tester.pumpWidget(_displayApp(fixture, session));
      await settleNetworkWidgets(tester);

      expect(find.byType(WorkItemsDisplayQaScreen), findsOneWidget);
      expect(find.byType(GraphWorkItemsPage), findsOneWidget);
      await pumpUntil(
        tester,
        () => _shows(_displayRow()),
        description: 'group rows loaded',
      );
      expect(find.byType(FailureNotice), findsNothing);
      expect(find.bySemanticsLabel('還有更多，未載入'), findsWidgets);
      await _verifyDisplayToggles(tester, hierarchyMarker: false);

      await tester.tap(find.byKey(const ValueKey('display-qa-variant-project')));
      await settleNetworkWidgets(tester);
      await pumpUntil(
        tester,
        () => _shows(_displayRow()),
        description: 'project rows loaded',
      );

      expect(find.byType(GraphWorkItemsPage), findsOneWidget);
      expect(find.byType(FailureNotice), findsNothing);
      _expectUniqueRowIids(tester);
      expect(find.bySemanticsLabel('還有更多，未載入'), findsWidgets);
      await _verifyDisplayToggles(tester, hierarchyMarker: true);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Project QA direct actions verify star count 12, share action and synthetic clipboard copy ID 42',
    (tester) async {
      _useSurface(tester, const Size(1080, 2400));
      final clipboardWrites = _mockClipboard(tester);
      final shared = _mockShare(tester);
      final fixture = EmulatorQaFixture();
      final session = _qaSession(fixture);
      addTearDown(session.dispose);
      await tester.pumpWidget(_projectApp(fixture, session));
      await settleNetworkWidgets(tester);

      expect(find.byType(ProjectPage), findsOneWidget);

      final starFinder = find.byKey(const ValueKey('project-header-star'));
      final shareFinder = find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(ResourceShareButton),
      );
      final overflowFinder =
          find.byKey(const ValueKey('project-header-actions'));
      expect(starFinder, findsOneWidget);
      expect(shareFinder, findsOneWidget);
      expect(overflowFinder, findsOneWidget);

      IconButton starButton() => tester.widget<IconButton>(starFinder);
      IconData? starIcon() => tester
          .widget<Icon>(
            find.descendant(of: starFinder, matching: find.byType(Icon)),
          )
          .icon;
      final starStat = find
          .ancestor(of: find.text('星標'), matching: find.byType(Column))
          .first;

      await pumpUntil(
        tester,
        () => starButton().tooltip == '加入星標',
        description: 'header star state checked',
      );
      expect(starIcon(), Icons.star_border);
      expect(fixture.starCount, 12);

      await tester.tap(find.widgetWithText(Tab, '更多'));
      await settleNetworkWidgets(tester);
      await pumpUntil(
        tester,
        () => _shows(find.text('星標')),
        description: 'More tab overview loaded',
      );
      expect(
        find.descendant(of: starStat, matching: find.text('12')),
        findsOneWidget,
      );

      await tester.tap(starFinder);
      await pumpUntil(
        tester,
        () => fixture.starCount == 13 && starButton().tooltip == '移除星標',
        description: 'star 12 -> 13',
      );
      expect(starIcon(), Icons.star);
      await pumpUntil(
        tester,
        () => _shows(find.descendant(of: starStat, matching: find.text('13'))),
        description: 'More tab star stat shows 13',
      );
      await _waitSnackBarsGone(tester);

      await tester.tap(starFinder);
      await pumpUntil(
        tester,
        () => fixture.starCount == 12 && starButton().tooltip == '加入星標',
        description: 'star 13 -> 12',
      );
      expect(starIcon(), Icons.star_border);
      await pumpUntil(
        tester,
        () => _shows(find.descendant(of: starStat, matching: find.text('12'))),
        description: 'More tab star stat shows 12',
      );
      await _waitSnackBarsGone(tester);

      final shareWidget = tester.widget<ResourceShareButton>(shareFinder);
      expect(
        shareWidget.uri,
        fixture.account.instance.projectWeb(fixture.project.path),
      );
      expect(
        shareWidget.uri.toString(),
        'https://qa.invalid:8443/gitlab/studio/mobile-workspace',
      );
      expect(shareWidget.uri.hasQuery, isFalse);
      await tester.tap(shareFinder);
      await pumpUntil(
        tester,
        () => shared.isNotEmpty,
        description: 'native share invoked',
      );
      expect(shared, ['https://qa.invalid:8443/gitlab/studio/mobile-workspace']);
      expect(find.text('無法分享連結。'), findsNothing);

      await tester.tap(overflowFinder);
      await pumpUntil(
        tester,
        () => _shows(
          find.byKey(const ValueKey('project-header-action-copy-id')),
        ),
        description: 'overflow menu opened',
      );
      await settleNetworkWidgets(tester);
      expect(find.text('複製專案 ID：42'), findsOneWidget);
      expect(find.text('在 GitLab 開啟'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('project-header-action-copy-id')),
      );
      await pumpUntil(
        tester,
        () => clipboardWrites.isNotEmpty,
        description: 'project id copied',
      );
      expect(clipboardWrites, ['42']);
      await pumpUntil(
        tester,
        () => _shows(find.text('已複製專案 ID：42')),
        description: 'copy confirmation shown',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Health QA A/B split mode settles shared health status across competing panes',
    (tester) async {
      _useSurface(tester, const Size(2000, 2400));
      final fixture = WorkItemHealthParentFixture();
      addTearDown(fixture.closeAll);
      await tester.pumpWidget(
        MaterialApp(
          home: HealthParentQaScreen(fixture: fixture),
        ),
      );
      await settleNetworkWidgets(tester);

      await _tapHealthSegment(tester, 'A/B');
      const paneA = 'health-qa-split-pane-a';
      const paneB = 'health-qa-split-pane-b';
      expect(find.byKey(const ValueKey(paneA)), findsOneWidget);
      expect(find.byKey(const ValueKey(paneB)), findsOneWidget);
      for (final pane in [paneA, paneB]) {
        await _expandAttributes(tester, pane: pane);
        await pumpUntil(
          tester,
          () => _shows(_inPane(pane, find.text('目前：正常'))),
          description: '$pane attributes read before the write',
        );
      }

      await _tapQaControl(tester, 'health-qa-hold-apply');
      await _openHealthEditor(tester, pane: paneA);
      await _chooseHealth(tester, 'atRisk', pane: paneA);
      final detailsBeforeSave =
          fixture.detailReads(item: WorkItemHealthParentFixture.itemX);
      final editsBeforeSave =
          fixture.editReads(item: WorkItemHealthParentFixture.itemX);
      await tester.tap(_healthSave(pane: paneA));
      await pumpUntil(
        tester,
        () => fixture.awaitingApply,
        description: 'writer A mutation parked before apply',
      );
      expect(fixture.healthMutationRequests, 1);

      final editB = _inPane(
        paneB,
        find.byKey(const ValueKey('work-item-health-edit')),
      );
      await tester.scrollUntilVisible(
        editB,
        200,
        scrollable: _detailScrollable(paneB),
      );
      expect(editB, findsOneWidget);
      expect(tester.widget<TextButton>(editB).onPressed, isNull);
      expect(
        _inPane(paneB, find.byKey(const ValueKey('work-item-health-hold'))),
        findsOneWidget,
      );
      expect(_inPane(paneB, find.text('目前：有風險')), findsNothing);

      await _tapQaControl(tester, 'health-qa-release-holds');
      await pumpUntil(
        tester,
        () => fixture.healthApplied == 1,
        description: 'writer A mutation applied',
      );
      for (final pane in [paneA, paneB]) {
        await pumpUntil(
          tester,
          () => _shows(_inPane(pane, find.text('目前：有風險'))),
          description: '$pane attributes re-read the applied value',
        );
        expect(_inPane(pane, find.text('目前：有風險')), findsOneWidget);
        expect(_inPane(pane, find.text('目前：正常')), findsNothing);
      }
      await settleNetworkWidgets(tester);

      expect(
        fixture.health[WorkItemHealthParentFixture.itemX]?.value,
        WorkItemHealthEditValue.atRisk,
      );
      expect(fixture.healthMutationRequests, 1);
      expect(
        fixture.detailReads(item: WorkItemHealthParentFixture.itemX),
        detailsBeforeSave + 2,
        reason: 'one settle reload per pane',
      );
      expect(
        fixture.editReads(item: WorkItemHealthParentFixture.itemX),
        editsBeforeSave + 2,
        reason: 'writer preflight plus one readback',
      );
      expect(
        tester.widget<TextButton>(editB).onPressed,
        isNotNull,
        reason: 'observer B is editable again after settle',
      );
      expect(fixture.unhandled, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Health QA denial, read failure, final fence and lost ACK exercise defensive paths',
    (tester) async {
      _useSurface(tester, const Size(1080, 2400));
      final fixture = WorkItemHealthParentFixture();
      addTearDown(fixture.closeAll);
      await tester.pumpWidget(
        MaterialApp(
          home: HealthParentQaScreen(fixture: fixture),
        ),
      );
      await settleNetworkWidgets(tester);

      final edit = find.byKey(const ValueKey('work-item-health-edit'));
      final stale = find.byKey(const ValueKey('work-item-health-stale'));
      final unconfirmed =
          find.byKey(const ValueKey('work-item-health-unconfirmed'));
      final confirmed =
          find.byKey(const ValueKey('work-item-health-confirmed'));
      final refresh = find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('重新整理'),
      );

      // 1. Denial: adminWorkItem=false keeps the editor read-only.
      await _tapQaControl(tester, 'health-qa-deny-admin');
      await _openHealthEditor(tester);
      expect(
        find.byKey(const ValueKey('work-item-health-read-only')),
        findsOneWidget,
      );
      expect(
        find.text('目前帳號沒有管理這個工作項目健康狀態的權限，僅供檢視。'),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(_healthSave()).onPressed, isNull);
      for (final choice in ['clear', 'onTrack', 'needsAttention', 'atRisk']) {
        expect(
          find.byKey(ValueKey('work-item-health-choice-$choice')),
          findsNothing,
        );
      }
      expect(fixture.healthMutationRequests, 0);
      await _closeHealthEditor(tester);
      await _tapQaControl(tester, 'health-qa-reset-health');

      // 2. Read failure: readWorkItem=false with the widget still present.
      await _tapQaControl(tester, 'health-qa-fail-read');
      await tester.scrollUntilVisible(
        edit,
        200,
        scrollable: _detailScrollable(null),
      );
      await tester.ensureVisible(edit);
      await tester.pump();
      final editsBeforeFailure =
          fixture.editReads(item: WorkItemHealthParentFixture.itemX);
      await tester.tap(edit);
      await pumpUntil(
        tester,
        () => _shows(
          find.text('無法讀取工作項目健康狀態。目前帳號沒有讀取這個工作項目的權限。'),
        ),
        description: 'read failure reported',
      );
      expect(
        fixture.editReads(item: WorkItemHealthParentFixture.itemX),
        editsBeforeFailure + 1,
      );
      expect(_healthSave(), findsNothing);
      expect(find.textContaining('讀取時：'), findsNothing);
      expect(tester.widget<TextButton>(edit).onPressed, isNotNull);
      await _waitSnackBarsGone(tester);
      await _tapQaControl(tester, 'health-qa-reset-health');

      // 3. Final fence parks the editor's preflight read.
      await _tapQaControl(tester, 'health-qa-arm-fence');
      expect(fixture.armFinalFence, isTrue);
      await tester.scrollUntilVisible(
        edit,
        200,
        scrollable: _detailScrollable(null),
      );
      await tester.ensureVisible(edit);
      await tester.pump();
      await tester.tap(edit);
      await pumpUntil(
        tester,
        () => fixture.awaitingFinalFenceReads == 1,
        description: 'editor read parked at the fence',
      );
      await tester.pump();
      expect(
        find.descendant(of: edit, matching: find.text('讀取健康狀態…')),
        findsOneWidget,
      );
      expect(tester.widget<TextButton>(edit).onPressed, isNull);
      expect(_healthSave(), findsNothing);
      await _tapQaControl(tester, 'health-qa-release-holds');
      await pumpUntil(
        tester,
        () => _shows(_healthSave()),
        description: 'editor opens after the fence releases',
      );
      expect(fixture.awaitingFinalFenceReads, 0);
      expect(fixture.armFinalFence, isFalse);
      await settleNetworkWidgets(tester);
      await _closeHealthEditor(tester);

      // 4. Lagged detail after a confirmed write: stale notice, then recovery.
      await _tapQaControl(tester, 'health-qa-lag-detail');
      expect(fixture.lagNextDetail, isTrue);
      await _openHealthEditor(tester);
      await _chooseHealth(tester, 'needsAttention');
      await tester.tap(_healthSave());
      await pumpUntil(
        tester,
        () => _shows(confirmed),
        description: 'readback confirmed while the editor stays bound',
      );
      expect(find.text('GitLab 已確認健康狀態為「需關注」。'), findsOneWidget);
      expect(
        find.descendant(of: confirmed, matching: find.text('伺服器回讀：需關注')),
        findsOneWidget,
      );
      await pumpUntil(
        tester,
        () => !fixture.lagNextDetail,
        description: 'page reload consumed the lagged detail',
      );
      expect(fixture.healthApplied, 1);
      await _closeHealthEditor(tester);
      await pumpUntil(
        tester,
        () => _shows(stale),
        description: 'stale notice after the lagged detail',
      );
      expect(
        find.descendant(
          of: stale,
          matching: find.text('尚未確認最新健康狀態。請重新整理後再查看。'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
      final detailsBeforeRefresh =
          fixture.detailReads(item: WorkItemHealthParentFixture.itemX);
      expect(refresh, findsOneWidget);
      await tester.tap(refresh);
      await pumpUntil(
        tester,
        () => stale.evaluate().isEmpty,
        description: 'refresh recovers from the stale notice',
      );
      expect(
        fixture.detailReads(item: WorkItemHealthParentFixture.itemX),
        detailsBeforeRefresh + 1,
      );

      // 5. Lost ACK: applied server-side, outcome unknown to the client.
      await _tapQaControl(tester, 'health-qa-lose-ack');
      expect(fixture.loseNextAck, isTrue);
      await _openHealthEditor(tester);
      await _chooseHealth(tester, 'atRisk');
      await tester.tap(_healthSave());
      await pumpUntil(
        tester,
        () => fixture.healthApplied == 2,
        description: 'lost-ACK mutation applied',
      );
      await pumpUntil(
        tester,
        () => _shows(unconfirmed),
        description: 'unconfirmed notice after the lost acknowledgement',
      );
      expect(
        find.descendant(
          of: unconfirmed,
          matching: find.text('尚未確認健康狀態是否已更新。請重新整理後再查看。'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
      expect(_healthSave(), findsNothing);
      expect(confirmed, findsNothing);
      await settleNetworkWidgets(tester);
      expect(fixture.healthMutationRequests, 2);
      expect(fixture.loseNextAck, isFalse);
      await tester.tap(refresh);
      await pumpUntil(
        tester,
        () => unconfirmed.evaluate().isEmpty,
        description: 'refresh acknowledges the unconfirmed outcome',
      );

      expect(fixture.unhandled, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final isGroup in [false, true]) {
    testWidgets(
      '320dp scaled 2.0x reaches all Health, Display and Project controls (${isGroup ? "group" : "project"}) without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(320 * 2.0, 800 * 2.0);
        tester.view.devicePixelRatio = 2.0;
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        final fixture = WorkItemHealthParentFixture();
        addTearDown(fixture.closeAll);
        await tester.pumpWidget(
          MaterialApp(
            home: HealthParentQaScreen(
              fixture: fixture,
              initialMode: isGroup
                  ? HealthQaViewMode.group
                  : HealthQaViewMode.project,
            ),
          ),
        );
        await settleNetworkWidgets(tester);
        _expectScaledViewport(tester, find.byType(HealthParentQaScreen));
        expect(tester.takeException(), isNull);

        for (final control in [
          'health-qa-reset-health',
          'health-qa-hold-apply',
          'health-qa-hold-ack',
          'health-qa-arm-fence',
          'health-qa-release-holds',
          'health-qa-deny-admin',
          'health-qa-fail-read',
          'health-qa-lose-ack',
          'health-qa-lag-detail',
          'health-qa-reset-health',
          'health-qa-toggle-session',
          'health-qa-toggle-session',
          'health-qa-refresh-witness',
        ]) {
          await _tapQaControl(tester, control);
          expect(tester.takeException(), isNull, reason: control);
        }
        await _expectLedger(tester, ['寫入請求: 0', '已套用: 0']);
        expect(tester.takeException(), isNull);
        for (final segment in ['專案', '群組', 'A/B', '啟動器']) {
          await _tapHealthSegment(tester, segment);
          expect(tester.takeException(), isNull, reason: segment);
        }
        fixture.releaseHolds();

        final displayFixture = EmulatorQaFixture();
        final displaySession = _qaSession(displayFixture);
        addTearDown(displaySession.dispose);
        await tester.pumpWidget(
          _displayApp(
            displayFixture,
            displaySession,
            variant: isGroup
                ? DisplayQaRouteVariant.group
                : DisplayQaRouteVariant.project,
          ),
        );
        await settleNetworkWidgets(tester);
        _expectScaledViewport(tester, find.byType(WorkItemsDisplayQaScreen));
        await pumpUntil(
          tester,
          () => _shows(_displayRow()),
          description: 'display rows loaded at 320dp',
        );
        expect(tester.takeException(), isNull);
        await _openDisplaySheet(tester);
        expect(tester.takeException(), isNull);
        for (final title in _supportedDisplayTiles) {
          final tile = await _revealDisplayTile(tester, title);
          expect(tile.onChanged, isNotNull, reason: title);
          expect(_displayTile(title).hitTestable(), findsOneWidget);
          await tester.tap(_displayTile(title));
          await tester.pump();
          expect(
            tester.widget<SwitchListTile>(_displayTile(title)).value,
            !tile.value,
            reason: title,
          );
          expect(tester.takeException(), isNull, reason: title);
        }
        for (final title in _unsupportedDisplayTiles) {
          final tile = await _revealDisplayTile(tester, title);
          expect(tile.onChanged, isNull, reason: title);
          expect(_displayTile(title).hitTestable(), findsOneWidget);
          expect(
            find.descendant(
              of: _displayTile(title),
              matching: find.text('尚未支援'),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull, reason: title);
        }
        await _closeDisplaySheet(tester);
        expect(tester.takeException(), isNull);

        final clipboardWrites = _mockClipboard(tester);
        final shared = _mockShare(tester);
        final projectFixture = EmulatorQaFixture();
        final projectSession = _qaSession(projectFixture);
        addTearDown(projectSession.dispose);
        await tester.pumpWidget(_projectApp(projectFixture, projectSession));
        await settleNetworkWidgets(tester);
        _expectScaledViewport(tester, find.byType(ProjectPage));
        expect(tester.takeException(), isNull);

        final star = find.byKey(const ValueKey('project-header-star'));
        await pumpUntil(
          tester,
          () => tester.widget<IconButton>(star).tooltip == '加入星標',
          description: 'header star state checked at 320dp',
        );
        expect(star.hitTestable(), findsOneWidget);
        await tester.tap(star);
        await pumpUntil(
          tester,
          () =>
              projectFixture.starCount == 13 &&
              tester.widget<IconButton>(star).tooltip == '移除星標',
          description: 'star toggled at 320dp',
        );
        expect(tester.takeException(), isNull);
        await _waitSnackBarsGone(tester);

        final share = find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(ResourceShareButton),
        );
        expect(share.hitTestable(), findsOneWidget);
        await tester.tap(share);
        await pumpUntil(
          tester,
          () => shared.isNotEmpty,
          description: 'share invoked at 320dp',
        );
        expect(shared, ['https://qa.invalid:8443/gitlab/studio/mobile-workspace']);
        expect(tester.takeException(), isNull);

        final overflow = find.byKey(const ValueKey('project-header-actions'));
        expect(overflow.hitTestable(), findsOneWidget);
        await tester.tap(overflow);
        final copyId =
            find.byKey(const ValueKey('project-header-action-copy-id'));
        await pumpUntil(
          tester,
          () => _shows(copyId),
          description: 'overflow menu opened at 320dp',
        );
        await settleNetworkWidgets(tester);
        expect(copyId.hitTestable(), findsOneWidget);
        await tester.tap(copyId);
        await pumpUntil(
          tester,
          () => clipboardWrites.isNotEmpty,
          description: 'project id copied at 320dp',
        );
        expect(clipboardWrites, ['42']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

const _supportedDisplayTiles = [
  '標籤',
  '指派對象',
  '里程碑',
  '起訖日期',
  '階層關係',
  '工作流程狀態',
];

const _unsupportedDisplayTiles = [
  '阻礙項目',
  '留言數',
  '健康狀態',
  '疊代',
  '熱門度',
  '權重',
];

const _displayMarkers = {
  '標籤': 'qa-label',
  '指派對象': 'QA Tester',
  '里程碑': '17.5',
  '起訖日期': '2026/10/01 - 2026/10/31',
  '階層關係': '上層不可見',
  '工作流程狀態': 'In progress',
};

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

bool _shows(Finder finder) => finder.evaluate().isNotEmpty;

void _expectScaledViewport(WidgetTester tester, Finder target) {
  final context = tester.element(target);
  expect(MediaQuery.sizeOf(context).width, 320);
  expect(MediaQuery.textScalerOf(context).scale(14), 28);
}

Future<void> _waitSnackBarsGone(WidgetTester tester) => pumpUntil(
  tester,
  () => find.byType(SnackBar).evaluate().isEmpty,
  maxCycles: 200,
  description: 'snack bars dismissed',
);

Finder _inPane(String? pane, Finder matching) => pane == null
    ? matching
    : find.descendant(of: find.byKey(ValueKey(pane)), matching: matching);

Finder _detailScrollable(String? pane) => find
    .descendant(
      of: _inPane(pane, find.byType(GraphWorkItemDetailPage)),
      matching: find.byType(Scrollable),
    )
    .first;

Finder _healthSave({String? pane}) =>
    _inPane(pane, find.byKey(const ValueKey('work-item-health-save')));

Future<void> _tapQaControl(WidgetTester tester, String key) async {
  final control = find.byKey(ValueKey(key));
  await tester.ensureVisible(control);
  await tester.pump();
  expect(control.hitTestable(), findsOneWidget, reason: key);
  await tester.tap(control);
  await settleNetworkWidgets(tester);
  await _waitSnackBarsGone(tester);
}

Future<void> _tapHealthSegment(WidgetTester tester, String label) async {
  final segment = find.descendant(
    of: find.byType(SegmentedButton<HealthQaViewMode>),
    matching: find.text(label),
  );
  await tester.ensureVisible(segment);
  await tester.pump();
  expect(segment.hitTestable(), findsOneWidget, reason: label);
  await tester.tap(segment);
  await settleNetworkWidgets(tester);
}

Future<void> _expectLedger(WidgetTester tester, List<String> chips) async {
  const title = '網路紀錄與計數（開啟時快照）';
  await _tapQaControl(tester, 'health-qa-view-ledger');
  expect(find.text(title), findsOneWidget);
  for (final chip in chips) {
    expect(find.text(chip), findsOneWidget, reason: chip);
  }
  await tester.binding.handlePopRoute();
  await pumpUntil(
    tester,
    () => find.text(title).evaluate().isEmpty,
    description: 'ledger sheet closed',
  );
}

Future<void> _expandAttributes(WidgetTester tester, {String? pane}) async {
  final card = _inPane(
    pane,
    find.byKey(const ValueKey('work-item-attributes')),
  );
  await tester.scrollUntilVisible(
    card,
    200,
    scrollable: _detailScrollable(pane),
  );
  final title = find.descendant(of: card, matching: find.text('屬性'));
  await tester.ensureVisible(title);
  await tester.pump();
  await tester.tap(title);
  await settleNetworkWidgets(tester);
}

Future<void> _openHealthEditor(WidgetTester tester, {String? pane}) async {
  final edit = _inPane(
    pane,
    find.byKey(const ValueKey('work-item-health-edit')),
  );
  await tester.scrollUntilVisible(
    edit,
    200,
    scrollable: _detailScrollable(pane),
  );
  await tester.ensureVisible(edit);
  await tester.pump();
  await tester.tap(edit);
  await pumpUntil(
    tester,
    () => _shows(_healthSave(pane: pane)),
    description: 'health editor opened',
  );
  await settleNetworkWidgets(tester);
}

Future<void> _chooseHealth(
  WidgetTester tester,
  String choice, {
  String? pane,
}) async {
  final tile = _inPane(
    pane,
    find.byKey(ValueKey('work-item-health-choice-$choice')),
  );
  expect(tile, findsOneWidget, reason: choice);
  await tester.ensureVisible(tile);
  await tester.pump();
  await tester.tap(tile);
  await tester.pump();
}

Future<void> _closeHealthEditor(WidgetTester tester, {String? pane}) async {
  final cancel = _inPane(
    pane,
    find.byKey(const ValueKey('work-item-health-cancel')),
  );
  await tester.tap(cancel);
  await pumpUntil(
    tester,
    () => _healthSave(pane: pane).evaluate().isEmpty,
    description: 'health editor closed',
  );
  await settleNetworkWidgets(tester);
}

SessionController _qaSession(EmulatorQaFixture fixture) {
  final store = EmulatorQaMemoryAccountStore()
    ..accounts = [fixture.account]
    ..lastActive = fixture.account.key;
  return SessionController(
    store,
    createApi: (instance, credential, oauth, onOAuthRotated) => fixture.api,
  )
    ..active = fixture.account
    ..api = fixture.api
    ..initializing = false;
}

Widget _displayApp(
  EmulatorQaFixture fixture,
  SessionController session, {
  DisplayQaRouteVariant variant = DisplayQaRouteVariant.group,
}) => ProviderScope(
  overrides: [sessionProvider.overrideWithValue(session)],
  child: MaterialApp(
    home: WorkItemsDisplayQaScreen(
      fixture: fixture,
      session: session,
      initialVariant: variant,
    ),
  ),
);

Widget _projectApp(EmulatorQaFixture fixture, SessionController session) =>
    ProviderScope(
      overrides: [sessionProvider.overrideWithValue(session)],
      child: MaterialApp(
        home: ProjectPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
        ),
      ),
    );

List<String> _mockClipboard(WidgetTester tester) {
  final writes = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      writes.add((call.arguments as Map<Object?, Object?>)['text']! as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return writes;
}

List<String> _mockShare(WidgetTester tester) {
  const channel = MethodChannel('dev.fluttercommunity.plus/share');
  final shared = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'share') {
      shared.add((call.arguments as Map<Object?, Object?>)['text']! as String);
    }
    return 'dev.fluttercommunity.plus/share/success';
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return shared;
}

Finder _displayTile(String title) =>
    find.widgetWithText(SwitchListTile, title);

Finder _displayRow() => find
    .ancestor(
      of: find.textContaining(RegExp(r'^Synthetic \w+ item \d+$')).first,
      matching: find.byType(EntityCard),
    )
    .first;

Future<void> _openDisplaySheet(WidgetTester tester) async {
  final button =
      find.byKey(const Key('graph-work-items-display-options-button'));
  await tester.ensureVisible(button);
  await tester.pump();
  expect(button.hitTestable(), findsOneWidget);
  await tester.tap(button);
  await pumpUntil(
    tester,
    () => _shows(find.byType(BottomSheet)),
    description: 'display sheet opened',
  );
  await settleNetworkWidgets(tester);
}

Future<void> _closeDisplaySheet(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await pumpUntil(
    tester,
    () => find.byType(BottomSheet).evaluate().isEmpty,
    description: 'display sheet closed',
  );
  await settleNetworkWidgets(tester);
}

Future<SwitchListTile> _revealDisplayTile(
  WidgetTester tester,
  String title,
) async {
  final tile = _displayTile(title);
  await tester.scrollUntilVisible(
    tile,
    80,
    scrollable: find
        .descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pump();
  return tester.widget<SwitchListTile>(tile);
}

void _expectUniqueRowIids(WidgetTester tester) {
  final iids = [
    for (final text in tester.widgetList<Text>(
      find.descendant(
        of: find.byType(EntityCard),
        matching: find.byType(Text),
      ),
    ))
      if (RegExp(r'#(\d+)$').firstMatch(text.data ?? '') case final match?)
        match.group(1)!,
  ];
  expect(iids, isNotEmpty);
  expect(iids.toSet(), hasLength(iids.length));
}

Future<void> _verifyDisplayToggles(
  WidgetTester tester, {
  required bool hierarchyMarker,
}) async {
  for (final MapEntry(key: title, value: marker) in _displayMarkers.entries) {
    final rendered = title != '階層關係' || hierarchyMarker;
    final markerInRow = find.descendant(
      of: _displayRow(),
      matching: find.text(marker),
    );
    expect(markerInRow, rendered ? findsOneWidget : findsNothing, reason: title);

    await _openDisplaySheet(tester);
    final before = await _revealDisplayTile(tester, title);
    expect(before.onChanged, isNotNull, reason: title);
    expect(before.value, isTrue, reason: title);
    await tester.tap(_displayTile(title));
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(_displayTile(title)).value,
      isFalse,
      reason: title,
    );
    await _closeDisplaySheet(tester);
    expect(markerInRow, findsNothing, reason: '$title hidden');

    await _openDisplaySheet(tester);
    final retained = await _revealDisplayTile(tester, title);
    expect(retained.value, isFalse, reason: '$title retained');
    await tester.tap(_displayTile(title));
    await tester.pump();
    await _closeDisplaySheet(tester);
    expect(
      markerInRow,
      rendered ? findsOneWidget : findsNothing,
      reason: '$title restored',
    );
  }

  await _openDisplaySheet(tester);
  for (final title in _unsupportedDisplayTiles) {
    final tile = await _revealDisplayTile(tester, title);
    expect(tile.onChanged, isNull, reason: title);
    expect(tile.value, isFalse, reason: title);
    expect(
      find.descendant(of: _displayTile(title), matching: find.text('尚未支援')),
      findsOneWidget,
      reason: title,
    );
  }
  await _closeDisplaySheet(tester);
}
