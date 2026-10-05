import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';
import 'package:gitlab_mobile/core/work_item_state_models.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/project_extras.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/shared/scroll_performance.dart';

import '../tool/emulator_ui.dart';
import 'support/widget_settle.dart';

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
}

