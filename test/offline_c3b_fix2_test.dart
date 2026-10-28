// C3b FIX2 regressions (review fu-c3b-r2): Pause only where the paused
// record survives recovery (a new save has no tree while listing), and
// in-page anchors bound to the rendered heading and its occurrence.
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
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_save.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';
import 'package:gitlab_mobile/features/offline/offline_projects_page.dart';
import 'package:gitlab_mobile/features/offline/offline_repositories.dart';
import 'package:gitlab_mobile/features/offline/offline_status.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/network_boundary.dart';

import 'offline/coordinator_regression_test.dart' as fixture;
import 'offline/snapshot_save_test.dart' as save;
import 'support/fake_adapter.dart';

final _account = Account(
  instance: GitLabInstance.parse('https://example.test'),
  user: const GitLabUser(id: 1, username: 'coder', name: 'Coder'),
  token: 'synthetic-test-token',
);

Future<void> _realUntil(bool Function() condition, {String? what}) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      throw StateError('timed out waiting for ${what ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// The save fixture of C3a, with every tree page held at [treeGate] while it
/// is set. Its own client, coordinator and queue, so the gate is in front of
/// every request the save makes.
final class _GatedSave {
  _GatedSave() {
    final scratch = Directory('.dart_tool/c3b/fix2')..createSync(recursive: true);
    root = scratch.createTempSync('case.');
    adapter = FakeAdapter((request) async {
      final gate = treeGate;
      if (request.uri.path.endsWith('/repository/tree') && gate != null) {
        await gate.future;
      }
      return fixtureResponses.adapter.respond(request);
    });
    api = GitLabApi(
      instance: GitLabInstance.parse('https://example.test'),
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = adapter,
      cdnAdapter: adapter,
      rateBudget: GitLabRateBudget(now: () => fixtureResponses.now),
    )..bindReadCache(fixture.binding.accountKey, fixture.binding.generation);
    // Recovery ages records on the fixture clock, like the queue does.
    coordinator = OfflineRepositoryCoordinator(clock: () => fixtureResponses.now)
      ..configure(
        keys: fixture.MemoryKeys(),
        supportRoot: () async => root,
        deleteDirectory: (_) async {
          final namespace = Directory('${root.path}/offline_repo');
          if (namespace.existsSync()) namespace.deleteSync(recursive: true);
        },
      )
      ..bindApi(api, fixture.binding)
      ..open(fixture.binding);
    // The queue is shared per coordinator and binding: create it with the
    // fixture clock before the adapter asks for it.
    SnapshotSaveQueue(
      api: api,
      coordinator: coordinator,
      binding: fixture.binding,
      clock: () => fixtureResponses.now,
      delay: (duration) async {
        fixtureResponses.now = fixtureResponses.now.add(duration);
      },
    );
    repositories = OfflineRepositories(
      binding: fixture.binding,
      coordinator: coordinator,
      api: api,
    );
  }

  final fixtureResponses = save.SaveHarness();
  late final Directory root;
  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final OfflineRepositoryCoordinator coordinator;
  late final OfflineRepositories repositories;
  Completer<void>? treeGate;

  void dispose() {
    final gate = treeGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    repositories.dispose();
    api.close();
    fixtureResponses.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Widget _host(Widget home, OfflineRepositories repositories) => NetworkBoundary(
  // Offline: the list's opening probe would otherwise hold the maintenance
  // lock on the widget clock while the save runs on the real loop.
  mode: NetworkBoundaryMode.offlineSnapshot,
  child: OfflineScope(
    repositories: repositories,
    account: _account,
    child: MaterialApp(home: home),
  ),
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Rendered headings with [text], in document order: no link, heading size.
List<Element> _headings(String text) => [
  for (final element in find.byType(RichText).evaluate())
    if (_isHeading((element.widget as RichText).text, text)) element,
];

bool _isHeading(InlineSpan span, String text) {
  if (span.toPlainText().trim() != text) return false;
  var link = false;
  double? size;
  span.visitChildren((child) {
    if (child is TextSpan) {
      if (child.recognizer != null) link = true;
      if (size == null && (child.text ?? '').isNotEmpty) {
        size = child.style?.fontSize;
      }
    }
    return true;
  });
  return !link && (size ?? 0) > 16;
}

double _top(WidgetTester tester, Element element) =>
    tester.getTopLeft(find.byWidget(element.widget)).dy;

const _hashTable = '# | Package | Version\n--- | --- | ---\n1 | example | 1.0\n';

/// [_hashTable] rendered as a table with three columns, not as a heading.
void _expectHashTable(WidgetTester tester) {
  final table = tester.widget<Table>(find.byType(Table));
  expect(table.children, hasLength(2));
  expect(table.children.first.children, hasLength(3));
  expect(find.text('Package', findRichText: true), findsOneWidget);
  expect(find.text('example', findRichText: true), findsOneWidget);
  expect(find.textContaining('| Package', findRichText: true), findsNothing);
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('online, the same table is a table (unchanged)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MarkdownView(_hashTable, account: _account)),
      ),
    );
    await tester.pump();
    _expectHashTable(tester);
  });

  // FIX2 #1: no Pause while listing; the Pause that is offered really keeps a
  // row that resumes.
  testWidgets('pause appears only once the tree exists, and its row resumes', (
    tester,
  ) async {
    late _GatedSave g;
    late SnapshotSaveJob job;
    await tester.runAsync(() async {
      g = _GatedSave();
      // Completers made on the real loop resolve there.
      g.treeGate = Completer<void>();
      g.fixtureResponses.stream = StreamController<Uint8List>();
      await g.repositories.refresh();
      job = g.repositories.save(g.fixtureResponses.request(projectId: 21));
      await _realUntil(
        () => job.phase == SnapshotJobPhase.listing,
        what: 'listing',
      );
      // The index already has the saving record (no tree yet); a reload,
      // such as another save ending, lists it.
      await g.repositories.refresh();
      expect(g.repositories.snapshots.where((s) => s.id == job.id), hasLength(1));
    });
    addTearDown(() => g.dispose());
    await tester.pumpWidget(
      _host(
        OfflineProjectsPage(repositories: g.repositories, account: _account),
        g.repositories,
      ),
    );
    await _frames(tester);
    final menu = find.byKey(ValueKey('offline-row-menu-${job.id}'));
    await tester.tap(menu);
    await _frames(tester);
    expect(find.text('暫停'), findsNothing, reason: 'no tree yet: it would vanish');
    expect(find.text('取消保存'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await _frames(tester);

    // The last tree page arrives; the tree is written before downloading.
    await tester.runAsync(() async {
      g.treeGate!.complete();
      await _realUntil(
        () => job.phase == SnapshotJobPhase.downloading,
        what: 'downloading',
      );
    });
    await _frames(tester);
    await tester.tap(menu);
    await _frames(tester);
    expect(find.text('暫停'), findsOneWidget);
    await tester.tap(find.text('暫停'));
    await _frames(tester);
    await tester.runAsync(() async {
      await job.completion.timeout(const Duration(seconds: 10));
      // The job's final recovery keeps a paused record with a tree.
      await _realUntil(
        () => g.repositories.snapshots.any(
          (s) => s.id == job.id && s.status == SnapshotStatus.paused,
        ),
        what: 'paused row kept',
      );
    });
    await _frames(tester);
    expect(find.text('已暫停'), findsOneWidget);

    await tester.runAsync(() async {
      // The held archive stream belonged to the cancelled request; the
      // resumed save reads a fresh archive.
      g.fixtureResponses.stream = null;
      final paused = g.repositories.snapshots.singleWhere((s) => s.id == job.id);
      final resumed = g.repositories.save(
        g.fixtureResponses.request(projectId: 21),
        resume: paused,
      );
      expect(await resumed.completion.timeout(const Duration(seconds: 10)), isNotNull);
      await _realUntil(
        () => g.repositories.snapshots.any(
          (s) => s.id == job.id && s.status == SnapshotStatus.complete,
        ),
        what: 'resumed row complete',
      );
    });
    await _frames(tester);
    expect(find.text('已保存'), findsOneWidget);
  });

  // FIX3 #1: a paused record older than 24 hours whose branch has moved
  // resumes as a fresh save; until its new tree exists Pause would lose it.
  const moved = 'cccccccccccccccccccccccccccccccccccccccc';

  /// Saves, pauses during download, waits 25 hours, moves the branch and
  /// resumes; the resumed save is held at its first tree page.
  Future<(_GatedSave, SnapshotRecord, SnapshotSaveJob)> expiredResume(
    WidgetTester tester,
  ) async {
    late _GatedSave g;
    late SnapshotRecord paused;
    late SnapshotSaveJob resumed;
    await tester.runAsync(() async {
      g = _GatedSave();
      final h = g.fixtureResponses;
      h.stream = StreamController<Uint8List>();
      await g.repositories.refresh();
      final first = g.repositories.save(h.request(projectId: 41));
      await _realUntil(
        () => first.phase == SnapshotJobPhase.downloading,
        what: 'first save downloading',
      );
      expect(first.treePersisted, isTrue);
      g.repositories.pause(first);
      await first.completion.timeout(const Duration(seconds: 10));
      await _realUntil(
        () => g.repositories.snapshots.any(
          (s) => s.id == first.id && s.status == SnapshotStatus.paused,
        ),
        what: 'first save paused',
      );
      paused = g.repositories.snapshots.singleWhere((s) => s.id == first.id);
      h.now = h.now.add(const Duration(hours: 25));
      h.sha = moved;
      h.stream = StreamController<Uint8List>();
      g.treeGate = Completer<void>();
      resumed = g.repositories.save(h.request(projectId: 41), resume: paused);
      await _realUntil(
        () => resumed.phase == SnapshotJobPhase.listing,
        what: 'resume listing',
      );
      // The old tree is not reused: the record now names the moved commit
      // and has no tree for it yet.
      expect(resumed.resumeRecord, isNotNull);
      expect(resumed.treePersisted, isFalse);
      await g.repositories.refresh();
      expect(
        g.repositories.snapshots.singleWhere((s) => s.id == paused.id).sha,
        moved,
      );
    });
    addTearDown(() => g.dispose());
    return (g, paused, resumed);
  }

  testWidgets('an expired resume at a moved branch offers Pause only after its new tree', (
    tester,
  ) async {
    final (g, paused, resumed) = await expiredResume(tester);
    await tester.pumpWidget(
      _host(
        OfflineProjectsPage(repositories: g.repositories, account: _account),
        g.repositories,
      ),
    );
    await _frames(tester);
    final menu = find.byKey(ValueKey('offline-row-menu-${paused.id}'));
    await tester.tap(menu);
    await _frames(tester);
    expect(find.text('暫停'), findsNothing, reason: 'the resume has no tree for this SHA');
    expect(find.text('取消保存'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await _frames(tester);

    await tester.runAsync(() async {
      g.treeGate!.complete();
      await _realUntil(() => resumed.treePersisted, what: 'new tree written');
    });
    await _frames(tester);
    await tester.tap(menu);
    await _frames(tester);
    expect(find.text('暫停'), findsOneWidget);
    await tester.tap(find.text('暫停'));
    await _frames(tester);
    late SnapshotRecord kept;
    await tester.runAsync(() async {
      await resumed.completion.timeout(const Duration(seconds: 10));
      // An explicit recovery, the step that drops tree-less records.
      await g.coordinator.recover(fixture.binding);
      await g.repositories.refresh();
      kept = g.repositories.snapshots.singleWhere((s) => s.id == paused.id);
      expect(kept.status, SnapshotStatus.paused);
      expect(kept.sha, moved);
    });
    await _frames(tester);
    expect(find.text('已暫停'), findsOneWidget);

    await tester.runAsync(() async {
      g.fixtureResponses.stream = null;
      final again = g.repositories.save(
        g.fixtureResponses.request(projectId: 41),
        resume: kept,
      );
      expect(await again.completion.timeout(const Duration(seconds: 10)), isNotNull);
      await _realUntil(
        () => g.repositories.snapshots.any(
          (s) => s.id == paused.id && s.status == SnapshotStatus.complete,
        ),
        what: 'resumed to complete',
      );
    });
    await _frames(tester);
    expect(find.text('已保存'), findsOneWidget);
  });

  // The premise of the rule above: pausing that same listing state does lose
  // the record once recovery runs, so not offering it is required.
  testWidgets('pausing an expired resume before its tree loses the record', (
    tester,
  ) async {
    final (g, paused, resumed) = await expiredResume(tester);
    await tester.runAsync(() async {
      g.repositories.pause(resumed);
      await resumed.completion.timeout(const Duration(seconds: 10));
      await g.coordinator.recover(fixture.binding);
      await g.repositories.refresh();
      expect(g.repositories.snapshots.where((s) => s.id == paused.id), isEmpty);
    });
  });

  group('anchors bind to the rendered heading', () {
    late save.SaveHarness h;
    late OfflineRepositories repositories;
    late SnapshotRecord record;

    Future<void> pumpMarkdown(WidgetTester tester, String text) async {
      await tester.runAsync(() async {
        h = save.SaveHarness();
        repositories = OfflineRepositories(
          binding: fixture.binding,
          coordinator: h.coordinator,
          api: h.api,
        );
        await repositories.refresh();
        await h.run(repositories.save(h.request(projectId: 31)));
        await _realUntil(() => repositories.snapshots.isNotEmpty);
        record = repositories.snapshots.single;
      });
      addTearDown(() {
        repositories.dispose();
        h.dispose();
      });
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: SingleChildScrollView(
              child: MarkdownView(
                text,
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
    }

    String paragraphs(int count, String tag) => [
      for (var i = 0; i < count; i++) 'Paragraph $tag $i.\n',
    ].join('\n');

    testWidgets('a TOC link labelled like its heading scrolls to the heading', (
      tester,
    ) async {
      await pumpMarkdown(
        tester,
        '[Install Guide](#install-guide)\n\n'
        '${paragraphs(60, 'a')}\n## Install Guide\n\nDone.\n',
      );
      final heading = _headings('Install Guide').single;
      expect(_top(tester, heading), greaterThan(600));
      // The link is the first text with these words; it must not be the
      // target.
      await tester.tap(find.text('Install Guide', findRichText: true).first);
      await tester.pumpAndSettle();
      expect(_top(tester, heading), inInclusiveRange(0, 600));
      expect(find.byKey(const ValueKey('snapshot-link-sheet')), findsNothing);
    });

    testWidgets('a linked heading is a target', (tester) async {
      await pumpMarkdown(
        tester,
        '[go](#project)\n\n'
        '${paragraphs(60, 'a')}\n# [Project](https://example.test/group/project)\n\nDone.\n',
      );
      final heading = find.text('Project', findRichText: true);
      expect(_top(tester, heading.evaluate().single), greaterThan(600));
      await tester.tap(find.text('go', findRichText: true));
      await tester.pumpAndSettle();
      expect(_top(tester, heading.evaluate().single), inInclusiveRange(0, 600));
    });

    testWidgets('a plain heading after a linked heading is reached', (
      tester,
    ) async {
      await pumpMarkdown(
        tester,
        '# [Project](https://example.test/group/project)\n\n'
        '[jump](#install-guide)\n\n'
        '${paragraphs(60, 'a')}\n## Install Guide\n\nEnd.\n',
      );
      final heading = _headings('Install Guide').single;
      expect(_top(tester, heading), greaterThan(600));
      await tester.tap(find.text('jump', findRichText: true));
      await tester.pumpAndSettle();
      expect(_top(tester, heading), inInclusiveRange(0, 600));
    });

    // FIX4: marking headings keeps GFM table precedence. A table whose first
    // header cell starts with `#` stays a three-column table, online and in
    // a snapshot, and anchors after it still land.
    testWidgets('a table with a leading # header cell stays a table, and anchors after it land', (
      tester,
    ) async {
      await pumpMarkdown(
        tester,
        '[jump](#install-guide)\n\n$_hashTable\n'
        '${paragraphs(60, 'a')}\n## Install Guide\n\nEnd.\n',
      );
      _expectHashTable(tester);
      final heading = _headings('Install Guide').single;
      expect(_top(tester, heading), greaterThan(600));
      await tester.tap(find.text('jump', findRichText: true));
      await tester.pumpAndSettle();
      expect(_top(tester, heading), inInclusiveRange(0, 600));
    });

    testWidgets('a repeated heading is reached by its -1 anchor', (
      tester,
    ) async {
      await pumpMarkdown(
        tester,
        '[second](#install-guide-1)\n\n'
        '${paragraphs(30, 'a')}\n## Install Guide\n\n'
        '${paragraphs(60, 'b')}\n## Install Guide\n\nEnd.\n',
      );
      final both = _headings('Install Guide');
      expect(both, hasLength(2));
      await tester.tap(find.text('second', findRichText: true));
      await tester.pumpAndSettle();
      expect(_top(tester, both[1]), inInclusiveRange(0, 600));
      expect(_top(tester, both[0]), lessThan(0), reason: 'not the first one');
    });
  });
}
