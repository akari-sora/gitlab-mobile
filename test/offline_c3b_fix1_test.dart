// C3b FIX1 regressions (review fu-c3b-r1): Explore's switch-account entry,
// pausing a save that has no record yet, re-saving a damaged same-SHA copy,
// a save sheet that follows the API budgets, and the §6.4 states derived
// from real queue jobs (not hand-built statuses).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/offline/snapshot_save.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';
import 'package:gitlab_mobile/core/repository_ref.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/offline/offline_projects_page.dart';
import 'package:gitlab_mobile/features/offline/offline_repositories.dart';
import 'package:gitlab_mobile/features/offline/offline_status.dart';
import 'package:gitlab_mobile/features/offline/save_sheet.dart';
import 'package:gitlab_mobile/features/offline/snapshot_browser_page.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';
import 'package:gitlab_mobile/shared/network_boundary.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'offline/coordinator_regression_test.dart' as fixture;
import 'offline/snapshot_save_test.dart' as save;
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

final _account = Account(
  instance: GitLabInstance.parse('https://example.test'),
  user: const GitLabUser(id: 1, username: 'coder', name: 'Coder'),
  token: 'synthetic-test-token',
);

/// Polls on the real event loop (jobs started there keep running there).
Future<void> _realUntil(bool Function() condition, {String? what}) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      throw StateError('timed out waiting for ${what ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

ResponseBody _branch(save.SaveHarness h) => jsonResponse({
  'commit': {
    'id': h.sha,
    'title': 'fixture',
    'committed_date': h.now.toIso8601String(),
  },
});

/// GET projects fails, so Explore shows its failure card.
final class _FailingProjects extends WorkspaceFixture {
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final path = segments.skip(segments.indexOf('v4') + 1).join('/');
    if (request.method == 'GET' && path == 'projects') {
      return jsonResponse({'message': 'unavailable'}, status: 503);
    }
    return super.respond(request);
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  // P1-1: the Explore list's own switch-account callback.
  testWidgets('Explore\'s 切換帳號 goes through the leave confirmations', (
    tester,
  ) async {
    final workspace = _FailingProjects();
    late SessionController session;
    session = controllerFor(MemoryAccountStore(), workspace.adapter);
    addTearDown(session.dispose);
    addTearDown(workspace.api.close);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-token');
    });
    final intents = <LeaveKind>[];
    await tester.pumpWidget(
      SessionLeaveScope(
        leave: (intent, action) async => intents.add(intent.kind),
        child: MaterialApp(home: ProjectsPage(session: session)),
      ),
    );
    await settleNetworkWidgets(tester);
    await pumpUntil(
      tester,
      () => find.text('切換帳號').evaluate().isNotEmpty,
      description: 'Explore failure card',
    );
    await tester.tap(find.text('切換帳號').first);
    await tester.pump();
    expect(intents, [LeaveKind.signOut], reason: 'the scope decides');
    expect(session.active, isNotNull, reason: 'nothing ended before confirming');
  });

  group('real queue jobs', () {
    late save.SaveHarness h;
    late OfflineRepositories repositories;

    setUp(() async {
      h = save.SaveHarness();
      repositories = OfflineRepositories(
        binding: fixture.binding,
        coordinator: h.coordinator,
        api: h.api,
      );
      await repositories.refresh();
    });

    tearDown(() {
      repositories.dispose();
      h.dispose();
    });

    test('saving and queued, then saved', () async {
      h.refGate = Completer<ResponseBody>();
      final first = repositories.save(h.request(projectId: 1));
      final second = repositories.save(h.request(projectId: 2));
      await _realUntil(
        () => first.phase == SnapshotJobPhase.resolving,
        what: 'first job resolving',
      );
      final saving = jobStatus(first);
      expect(saving.kind, SnapshotStatusKind.saving);
      expect(snapshotStatusLabel(saving).$2, '保存中 0%');
      expect(snapshotPhaseText(saving), '正在確認版本');
      expect(second.phase, SnapshotJobPhase.queued);
      expect(snapshotStatusLabel(jobStatus(second)).$2, '排隊中');
      expect(offlineProjectsAtRisk(repositories), 2);

      await repositories.cancel(second);
      expect(second.phase, SnapshotJobPhase.cancelled);
      final gate = h.refGate!;
      h.refGate = null;
      gate.complete(_branch(h));
      final record = await h.run(first);
      expect(record, isNotNull);
      await _realUntil(
        () => repositories.snapshots.any((s) => s.id == first.id),
        what: 'saved record listed',
      );
      final stored = repositories.snapshots.singleWhere((s) => s.id == first.id);
      expect(snapshotStatusLabel(recordStatus(stored, null)).$2, '已保存');
    });

    test('waiting for the rate limit and for the request budget', () async {
      final seen = <SnapshotStatusKind>[];
      final sub = h.queue.changes.listen((job) => seen.add(jobStatus(job).kind));
      addTearDown(sub.cancel);
      h.rateFailures = 1;
      final limited = repositories.save(h.request(projectId: 3));
      expect(await h.run(limited), isNotNull);
      expect(seen, contains(SnapshotStatusKind.waitingRateLimit));
      expect(
        snapshotStatusLabel(
          const SnapshotRowStatus(SnapshotStatusKind.waitingRateLimit),
        ).$2,
        '等待限流解除',
      );

      // Every run lease is taken (AI, say): the save waits for budget.
      final leases = [for (var i = 0; i < 3; i++) h.api.runBudget.acquire(1)!];
      h.budgetDelay = Completer<void>();
      final waiting = repositories.save(h.request(projectId: 4));
      await _realUntil(
        () => waiting.phase == SnapshotJobPhase.waitingBudget,
        what: 'waiting for budget',
      );
      expect(snapshotStatusLabel(jobStatus(waiting)).$2, '等待額度');
      for (final lease in leases) {
        lease.release();
      }
      h.budgetDelay!.complete();
      expect(await h.run(waiting), isNotNull);
    });

    test('pause keeps a resumable record; resume completes it', () async {
      h.stream = StreamController<Uint8List>();
      final job = repositories.save(h.request(projectId: 5));
      await _realUntil(
        () => job.phase == SnapshotJobPhase.downloading,
        what: 'downloading',
      );
      expect(jobStatus(job).kind, SnapshotStatusKind.saving);
      expect(snapshotPhaseText(jobStatus(job)), startsWith('正在下載與驗證'));
      // Past resolving the save has written its record, so pausing it keeps
      // something to resume.
      await repositories.refresh();
      expect(repositories.snapshots.where((s) => s.id == job.id), hasLength(1));
      repositories.pause(job);
      await h.run(job);
      expect(job.phase, SnapshotJobPhase.paused);
      // The adapter reloads on its own after the job ends; wait for it.
      await _realUntil(
        () => repositories.snapshots.any(
          (s) => s.id == job.id && s.status == SnapshotStatus.paused,
        ),
        what: 'paused record listed',
      );
      final paused = repositories.snapshots.singleWhere((s) => s.id == job.id);
      expect(snapshotStatusLabel(recordStatus(paused, null)).$2, '已暫停');

      // Closing the held archive stream can wait on the cancelled request's
      // pipe; the resumed save reads a fresh archive instead.
      h.stream = null;
      final resumed = repositories.save(h.request(projectId: 5), resume: paused);
      expect(await h.run(resumed), isNotNull);
      await _realUntil(
        () => repositories.snapshots.any(
          (s) => s.id == job.id && s.status == SnapshotStatus.complete,
        ),
        what: 'resumed record listed',
      );
      final done = repositories.snapshots.singleWhere((s) => s.id == job.id);
      expect(snapshotStatusLabel(recordStatus(done, null)).$2, '已保存');
    });

    test('a failed save says why', () async {
      h.corrupt = true;
      final job = repositories.save(h.request(projectId: 6));
      expect(await h.run(job), isNull);
      expect(job.phase, SnapshotJobPhase.failed);
      final status = jobStatus(job);
      expect(status.kind, SnapshotStatusKind.failed);
      expect(snapshotStatusLabel(status).$2, '失敗：下載的封存檔已損壞。');
    });
  });

  // P2-3: a queued save without a record cannot be paused into nothing.
  testWidgets('a queued save without a record offers cancel, not pause', (
    tester,
  ) async {
    late save.SaveHarness h;
    late OfflineRepositories repositories;
    late SnapshotSaveJob first, second;
    await tester.runAsync(() async {
      h = save.SaveHarness();
      repositories = OfflineRepositories(
        binding: fixture.binding,
        coordinator: h.coordinator,
        api: h.api,
      );
      await repositories.refresh();
      h.refGate = Completer<ResponseBody>();
      first = repositories.save(h.request(projectId: 1));
      second = repositories.save(h.request(projectId: 2));
      await _realUntil(() => first.phase == SnapshotJobPhase.resolving);
    });
    addTearDown(() async {
      repositories.dispose();
      h.dispose();
    });
    // Offline boundary: the list's opening probe would hold the maintenance
    // lock on the widget clock while the jobs run on the real loop.
    await tester.pumpWidget(
      NetworkBoundary(
        mode: NetworkBoundaryMode.offlineSnapshot,
        child: OfflineScope(
          repositories: repositories,
          account: _account,
          child: MaterialApp(
            home: OfflineProjectsPage(
              repositories: repositories,
              account: _account,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('排隊中'), findsOneWidget);
    // The resolving row shows an indeterminate bar: pump, never settle.
    Future<void> frames() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.byKey(ValueKey('offline-row-menu-${second.id}')));
    await frames();
    expect(find.text('暫停'), findsNothing, reason: 'it would vanish with no 繼續');
    expect(find.text('取消保存'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await frames();
    await tester.tap(find.byKey(ValueKey('offline-row-menu-${first.id}')));
    await frames();
    expect(find.text('暫停'), findsNothing, reason: 'no record written yet');
    await tester.tapAt(Offset.zero);
    await frames();
    await tester.runAsync(() async {
      await repositories.cancel(second);
      final gate = h.refGate!;
      h.refGate = null;
      gate.complete(_branch(h));
      await h.run(first);
    });
  });

  // P2-4: 重新保存 from a damaged same-SHA copy reaches the core repair.
  testWidgets('re-saving a damaged copy at the same commit is not "up to date"', (
    tester,
  ) async {
    late save.SaveHarness h;
    late OfflineRepositories repositories;
    late SnapshotRecord record;
    await tester.runAsync(() async {
      h = save.SaveHarness();
      repositories = OfflineRepositories(
        binding: fixture.binding,
        coordinator: h.coordinator,
        api: h.api,
      );
      await repositories.refresh();
      record = (await h.run(repositories.save(h.request(projectId: 7))))!;
      // The day's first 2xx starts the coordinator's recovery, which would
      // drop a complete copy with no tree; let it finish before the damage.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await h.coordinator.snapshots(fixture.binding);
      await repositories.refresh();
      // Damage the stored content of the complete copy. (A copy whose tree
      // is unreadable is removed by the next recovery instead; a damaged
      // blob is what the browser reports as 離線內容已損壞.)
      final store = SnapshotStore(
        supportRoot: h.root,
        accountKey: fixture.binding.accountKey,
        rootKey: Uint8List(32),
      );
      for (final blob in Directory('${store.accountDirectory}/b').listSync()) {
        if (blob is! File) continue;
        final bytes = blob.readAsBytesSync();
        bytes[bytes.length ~/ 2] ^= 0xff;
        blob.writeAsBytesSync(bytes, flush: true);
      }
      await expectLater(
        h.reader(record).text('docs/hello.txt'),
        throwsA(anything),
        reason: 'the copy is damaged',
      );
    });
    addTearDown(() async {
      repositories.dispose();
      h.dispose();
    });
    final project = Project(
      id: 7,
      name: 'project',
      path: 'group/project',
      defaultBranch: 'main',
    );
    final reference = RepositoryRef(
      kind: RepositoryRefKind.branch,
      name: 'main',
      sha: record.sha,
      protected: false,
    );
    Future<void> open({required bool repair}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openOfflineSaveSheet(
                  context,
                  repositories: repositories,
                  account: _account,
                  project: project,
                  ref: reference,
                  repair: repair,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    // The ordinary sheet for the same commit has nothing to save.
    await open(repair: false);
    expect(find.byKey(const ValueKey('offline-save-current')), findsOneWidget);
    expect(find.byKey(const ValueKey('offline-save-start')), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await open(repair: true);
    expect(find.byKey(const ValueKey('offline-save-current')), findsNothing);
    expect(find.text('重新保存'), findsOneWidget);
    // Fail fast: this tap only shows what is queued; the repair itself runs
    // below on the real event loop with the same request.
    h.responseOverride = (_) => jsonResponse({}, status: 503);
    await tester.tap(find.byKey(const ValueKey('offline-save-start')));
    await tester.pump();
    final job = repositories.activeJob ?? repositories.queuedJobs.single;
    expect(job.request.replaces, record.id);
    expect(job.request.subPath, record.subPath);
    var ended = false;
    unawaited(job.completion.whenComplete(() => ended = true));
    await pumpUntil(
      tester,
      () => ended && repositories.activeJob == null,
      description: 'fast-failing job left the queue',
    );
    expect(job.phase, SnapshotJobPhase.failed);
    h.responseOverride = null;
    await tester.runAsync(() async {
      final repair = repositories.save(job.request);
      final repaired = await h.run(repair);
      expect(
        repaired,
        isNotNull,
        reason: 'the core rebuilds the unreadable copy '
            '(${repair.phase} ${repair.failure})',
      );
      final text = await h.reader(repaired!).text('docs/hello.txt');
      expect(text, isNotEmpty);
    });
  });

  // P2-5: blockers follow the budgets while the sheet stays open.
  testWidgets('an open sheet follows the rate limit and the request budget', (
    tester,
  ) async {
    late save.SaveHarness h;
    late OfflineRepositories repositories;
    await tester.runAsync(() async {
      h = save.SaveHarness();
      repositories = OfflineRepositories(
        binding: fixture.binding,
        coordinator: h.coordinator,
        api: h.api,
      );
      await repositories.refresh();
      await repositories.probe();
    });
    addTearDown(() async {
      repositories.dispose();
      h.dispose();
    });
    expect(repositories.canSave, isTrue);
    final project = Project(
      id: 9,
      name: 'project',
      path: 'group/project',
      defaultBranch: 'main',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OfflineSaveSheet(
            repositories: repositories,
            account: _account,
            project: project,
            reference: RepositoryRef(
              kind: RepositoryRefKind.branch,
              name: 'main',
              sha: 'c' * 40,
              protected: false,
            ),
            consentAt: h.now,
          ),
        ),
      ),
    );
    await tester.pump();
    ButtonStyleButton start() => tester.widget<ButtonStyleButton>(
      find.byKey(const ValueKey('offline-save-start')),
    );
    expect(start().onPressed, isNotNull);

    // A cooldown arrives while the sheet is open…
    h.api.rateBudget.noteResponse(
      headers: {
        'retry-after': ['60'],
      },
      statusCode: 429,
      requestClass: RateRequestClass.global,
      sequence: h.api.rateBudget.nextSequence(),
      trusted: true,
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('GitLab 正在限制請求'), findsOneWidget);
    expect(start().onPressed, isNull);
    // …and lapses: the sheet opens up again without being reopened.
    h.now = h.now.add(const Duration(seconds: 61));
    await tester.pump(const Duration(seconds: 61));
    await tester.pump();
    expect(find.textContaining('GitLab 正在限制請求'), findsNothing);
    expect(start().onPressed, isNotNull);

    // The request budget: every lease taken, then one returned.
    final leases = [for (var i = 0; i < 3; i++) h.api.runBudget.acquire(1)!];
    await tester.pump();
    await tester.pump();
    expect(find.text('等待額度'), findsOneWidget);
    expect(start().onPressed, isNull);
    leases.first.release();
    await tester.pump();
    await tester.pump();
    expect(find.text('等待額度'), findsNothing);
    expect(start().onPressed, isNotNull);
    for (final lease in leases.skip(1)) {
      lease.release();
    }
    await tester.pump();
  });

  /// A saved synthetic snapshot through the real queue, opened for reading.
  Future<(save.SaveHarness, OfflineRepositories, SnapshotRecord)> saved(
    WidgetTester tester,
  ) async {
    late save.SaveHarness h;
    late OfflineRepositories repositories;
    late SnapshotRecord record;
    await tester.runAsync(() async {
      h = save.SaveHarness();
      repositories = OfflineRepositories(
        binding: fixture.binding,
        coordinator: h.coordinator,
        api: h.api,
      );
      await repositories.refresh();
      await h.run(repositories.save(h.request(projectId: 11)));
      await repositories.refresh();
      record = repositories.snapshots.single;
    });
    addTearDown(() {
      repositories.dispose();
      h.dispose();
    });
    return (h, repositories, record);
  }

  Widget host(Widget home, OfflineRepositories repositories,
          {NetworkBoundaryMode mode = NetworkBoundaryMode.offlineSnapshot}) =>
      NetworkBoundary(
        mode: mode,
        child: OfflineScope(
          repositories: repositories,
          account: _account,
          child: MaterialApp(home: home),
        ),
      );

  // GLM #1: a fence drops content that is already on screen.
  testWidgets('an access fence clears an open file page', (
    tester,
  ) async {
    final (h, repositories, record) = await saved(tester);
    final reader = repositories.reader(record);
    late List<SnapshotTreeEntry> entries;
    await tester.runAsync(() async {
      entries = await loadSnapshotEntries(h.coordinator, reader);
    });
    final file = entries.singleWhere((e) => e.path == 'docs/hello.txt');
    await tester.pumpWidget(
      host(
        SnapshotFilePage(
          repositories: repositories,
          record: record,
          reader: reader,
          account: _account,
          entry: file,
        ),
        repositories,
      ),
    );
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey('snapshot-file-line-1')).evaluate().isNotEmpty,
      description: 'file shown',
    );
    // GitLab refused the project elsewhere in the app.
    h.coordinator.accessLost(
      const OfflineAccessLoss(
        binding: fixture.binding,
        projectId: 11,
        scope: OfflineAccessScope.project,
        status: 403,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('snapshot-file-line-1')), findsNothing);
    expect(find.byKey(const ValueKey('snapshot-code')), findsNothing);
    expect(find.text('目前帳號無法讀取這個專案。'), findsOneWidget);
  });

  testWidgets('an access fence clears the open folder list and README', (
    tester,
  ) async {
    final (h, repositories, record) = await saved(tester);
    await tester.pumpWidget(
      host(
        SnapshotBrowserPage(
          repositories: repositories,
          record: record,
          reader: repositories.reader(record),
          account: _account,
        ),
        repositories,
      ),
    );
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey('snapshot-row-docs')).evaluate().isNotEmpty,
      description: 'rows shown',
    );
    h.coordinator.accessLost(
      const OfflineAccessLoss(
        binding: fixture.binding,
        projectId: 11,
        scope: OfflineAccessScope.repository,
        status: 403,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('snapshot-row-docs')), findsNothing);
    expect(find.byKey(const ValueKey('snapshot-browser-error')), findsOneWidget);
    expect(find.text('目前帳號無法讀取這個專案。'), findsOneWidget);
  });

  // #56 part 2: a folder or file's first read shows its skeleton (the real
  // header, filter and search stay), never a bar over an empty page. A retry
  // calls the same read, which clears the page first; a fenced reader fails
  // before the next frame, so that path cannot be held here.
  testWidgets('snapshot folder and file first reads show skeletons', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final (h, repositories, record) = await saved(tester);
    final reader = repositories.reader(record);
    await tester.pumpWidget(
      host(
        SnapshotBrowserPage(
          repositories: repositories,
          record: record,
          reader: reader,
          account: _account,
        ),
        repositories,
      ),
    );
    // The read runs on real file I/O, so the first frames hold it.
    expect(find.byType(RowsSkeleton), findsOneWidget);
    expect(find.byKey(const ValueKey('snapshot-filter')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.bySemanticsLabel('正在載入'), findsOneWidget);
    await pumpUntil(
      tester,
      () =>
          find.byKey(const ValueKey('snapshot-row-docs')).evaluate().isNotEmpty,
      description: 'rows shown',
    );
    expect(find.byType(RowsSkeleton), findsNothing);

    late List<SnapshotTreeEntry> entries;
    await tester.runAsync(() async {
      entries = await loadSnapshotEntries(h.coordinator, reader);
    });
    final file = entries.singleWhere((e) => e.path == 'docs/hello.txt');
    await tester.pumpWidget(
      host(
        SnapshotFilePage(
          repositories: repositories,
          record: record,
          reader: reader,
          account: _account,
          entry: file,
        ),
        repositories,
      ),
    );
    expect(find.byType(CodeSkeleton), findsOneWidget);
    expect(find.byKey(const ValueKey('snapshot-file-search')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.bySemanticsLabel('正在載入'), findsOneWidget);
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('snapshot-file-line-1'))
          .evaluate()
          .isNotEmpty,
      description: 'file shown',
    );
    expect(find.byType(CodeSkeleton), findsNothing);

    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  // GLM #6: an update started from the list that fails later is reported.
  testWidgets('a list update that fails after it started says why', (
    tester,
  ) async {
    final (h, repositories, record) = await saved(tester);
    await tester.pumpWidget(
      host(
        OfflineProjectsPage(repositories: repositories, account: _account),
        repositories,
        mode: NetworkBoundaryMode.online,
      ),
    );
    await tester.pump();
    h.responseOverride = (request) => request.uri.path.contains('/branches/')
        ? jsonResponse({'message': 'unavailable'}, status: 503)
        : null;
    await tester.tap(find.byKey(ValueKey('offline-row-menu-${record.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新'));
    await tester.pump();
    final job = repositories.activeJob ?? repositories.queuedJobs.single;
    expect(job.request.replaces, record.id);
    await pumpUntil(
      tester,
      () => job.phase == SnapshotJobPhase.failed,
      description: 'update failed',
    );
    await pumpUntil(
      tester,
      () => find.textContaining('無法離線保存: ').evaluate().isNotEmpty,
      description: 'failure snack',
    );
    expect(repositories.snapshots.where((s) => s.id == record.id), isNotEmpty,
        reason: 'the old copy stays');
  });

  // GLM #7: opening a snapshot online checks its project.
  testWidgets('opening a snapshot online probes its project', (tester) async {
    final (h, repositories, record) = await saved(tester);
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => openSnapshot(
                context,
                repositories: repositories,
                record: record,
                account: _account,
              ),
              child: const Text('open'),
            ),
          ),
        ),
        repositories,
        mode: NetworkBoundaryMode.online,
      ),
    );
    final before = h.adapter.requests
        .where((r) => r.uri.path.contains('/branches/'))
        .length;
    await tester.tap(find.text('open'));
    await pumpUntil(
      tester,
      () =>
          h.adapter.requests
              .where((r) => r.uri.path.contains('/branches/'))
              .length >
          before,
      description: 'project probe',
    );
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey('snapshot-row-docs')).evaluate().isNotEmpty,
      description: 'browser open',
    );
  });

  // GLM #8: in-page anchors scroll to their heading.
  testWidgets('an in-page anchor in snapshot Markdown scrolls to its heading', (
    tester,
  ) async {
    final (_, repositories, record) = await saved(tester);
    final text = StringBuffer('[jump](#install-guide)\n\n');
    for (var i = 0; i < 60; i++) {
      text.write('Paragraph $i.\n\n');
    }
    text.write('## Install Guide\n\nDone.\n');
    await tester.pumpWidget(
      host(
        Scaffold(
          body: SingleChildScrollView(
            child: MarkdownView(
              text.toString(),
              account: _account,
              base: _account.instance.projectWeb(
                'group/project/-/blob/${record.sha}/README.md',
              ),
              projectId: record.projectId,
              projectWeb: _account.instance.projectWeb('group/project'),
              snapshot: SnapshotMarkdownContext(
                reader: repositories.reader(record),
                projectPath: 'group/project',
                refName: 'main',
              ),
            ),
          ),
        ),
        repositories,
      ),
    );
    await tester.pump();
    final heading = find.text('Install Guide', findRichText: true);
    expect(tester.getTopLeft(heading).dy, greaterThan(600));
    await tester.tap(find.text('jump', findRichText: true));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(heading).dy, inInclusiveRange(0, 600));
    expect(find.byKey(const ValueKey('snapshot-link-sheet')), findsNothing);
    expect(markdownHeadingSlug('Hello, World!  2.0'), 'hello-world-20');
  });
}
