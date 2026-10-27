import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/core/read_cache_projection.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_backend.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/cache_freshness.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

// P-C2e typed UI adoption (§6e): real screens over the real coordinator, an
// encrypted temporary root and synthetic GitLab responses.
final _instance = GitLabInstance.parse('https://cache.example/subpath');
final _account = '${_instance.key}#7';
const _sha = '0123456789abcdef0123456789abcdef01234567';
final _project = Project.fromJson({
  'id': 1,
  'name': 'Synthetic',
  'path_with_namespace': 'team/synthetic',
});
final _user = Account(
  instance: _instance,
  user: const GitLabUser(id: 7, username: 'synthetic', name: 'Synthetic'),
  token: 'synthetic-test-token',
);

final class _Storage implements ReadCacheSecureStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
}

final class _Harness {
  _Harness() {
    root = Directory.systemTemp.createTempSync('c2e-pinned-ui-');
    files = ReadCacheFileStore(root: () async => root);
    keys = ReadCacheKeyStore(storage);
    coordinator = ReadCacheDiskCoordinator(
      keys: keys,
      files: files,
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
      controlsInstalled: true,
      schedule: (_, _) => () {},
    );
  }

  final storage = _Storage();
  late final Directory root;
  late final ReadCacheFileStore files;
  late final ReadCacheKeyStore keys;
  late final ReadCacheDiskCoordinator coordinator;
  DateTime now = DateTime.now().toUtc();
  final clients = <GitLabApi>[];

  Future<bool> recover() => coordinator.recover(
    ReadCacheStartupDecision(
      operationTicket: 1,
      accountListRevision: 1,
      accountsReadable: true,
      signOutMarkerReadable: true,
      lastActiveReadable: true,
      signOutPending: false,
      resumeAccountKey: _account,
    ),
    accountKeys: {_account},
  );

  /// A verified client of a new generation, as SessionController._activate
  /// binds it.
  Future<GitLabApi> client(FakeAdapter adapter) async {
    final generation = clients.length + 1;
    final binding = DiskBinding(accountKey: _account, generation: generation);
    final api = GitLabApi(
      instance: _instance,
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = adapter,
      readCacheClock: () => now,
    );
    api.bindReadCache(_account, generation);
    // No expect() here: this runs while the widget clock is being pumped.
    if (!await coordinator.activate(binding)) throw StateError('cache not ready');
    api.attachReadCacheDiskBackend(
      CoordinatedReadCacheDiskBackend(coordinator: coordinator, binding: binding),
    );
    clients.add(api);
    return api;
  }

  Future<void> flush() async {
    await coordinator.flush(
      DiskBinding(accountKey: _account, generation: clients.length),
    );
    await coordinator.quiesced;
  }

  Future<ProjectedDiskEntry?> entry(List<String> path, String accept) async {
    final key = await keys.readKey(_account);
    if (!key.isFound) return null;
    final durable = readCacheDurableKey(
      binding: DiskBinding(accountKey: _account, generation: 999),
      instance: _instance,
      uri: _instance.api(path),
      logicalAccept: accept,
    );
    return files.readEntry(_account, key.value, durable!);
  }

  void dispose() {
    for (final api in clients) {
      api.close();
    }
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Future<T> _run<T>(WidgetTester tester, Future<T> Function() work) async {
  late T value;
  await pumpUntilComplete(tester, work().then((result) => value = result));
  return value;
}

// Up to a minute of real time: a 2 MiB tail is decoded, parsed and encrypted.
Future<void> _until(WidgetTester tester, bool Function() condition, String what) =>
    pumpUntil(tester, condition, description: what, maxCycles: 2000, realDelay: const Duration(milliseconds: 30));

bool _shown(Finder finder) => finder.evaluate().isNotEmpty;

Json _version() => {
  'id': 9,
  'created_at': '2026-10-27T10:00:00Z',
  'base_commit_sha': _sha,
  'start_commit_sha': _sha,
  'head_commit_sha': _sha,
  'state': 'collected',
  'real_size': '1',
  'diffs': [
    {
      'old_path': 'readme.md',
      'new_path': 'readme.md',
      'a_mode': '100644',
      'b_mode': '100644',
      'new_file': false,
      'renamed_file': false,
      'deleted_file': false,
      'generated_file': false,
      'collapsed': false,
      'too_large': false,
      'diff': '@@ -1 +1 @@\n-old\n+synthetic-diff\n',
    },
  ],
};

FakeAdapter _diffAdapter() => FakeAdapter((request) {
  final path = request.uri.path;
  if (path.endsWith('/merge_requests/3/versions/9')) return jsonResponse(_version());
  if (path.endsWith('/merge_requests/3/versions')) {
    return jsonResponse([
      {
        'id': 9,
        'head_commit_sha': _sha,
        'base_commit_sha': _sha,
        'start_commit_sha': _sha,
        'state': 'collected',
      },
    ]);
  }
  if (path.endsWith('/merge_requests/3/discussions')) return jsonResponse([]);
  return jsonResponse({'message': 'not found'}, status: 404);
});

// Fixed-width lines: a 2 MiB suffix of 33,000 lines starts on line 232, and
// the screen shows the last 19,999 of them (its parser takes < 20,000 lines).
const _shownLines = 19999;
String _line(int index) => 'line ${index.toString().padLeft(7, '0')}'.padRight(63, '.');
List<int> _log(int lines) => utf8.encode(
  [for (var i = 0; i < lines; i++) '${_line(i)}\n'].join(),
);

// One fixed finish time: the tail is re-verified against fresh metadata.
final _finished = DateTime.now().toUtc().subtract(const Duration(hours: 1));

Json _job(int id, {String status = 'success', bool erasedKey = true}) => {
  'id': id,
  'name': 'synthetic-build',
  'status': status,
  'stage': 'test',
  'ref': 'main',
  if (status != 'running') 'finished_at': _finished.toIso8601String(),
  if (erasedKey) 'erased_at': null,
  'pipeline': {'id': 6, 'project_id': 1, 'sha': _sha},
};

ResponseBody _suffix(List<int> source) {
  final offset = source.length > readCacheTerminalLogLimit
      ? source.length - readCacheTerminalLogLimit
      : 0;
  final bytes = source.sublist(offset);
  return ResponseBody.fromBytes(bytes, 206, headers: {
    'content-range': ['bytes $offset-${source.length - 1}/${source.length}'],
    'content-length': ['${bytes.length}'],
    'x-gitlab-trace-eof': ['true'],
  });
}

bool _isTrace(RequestOptions request, int job) =>
    request.uri.path.endsWith('/jobs/$job/trace');
bool _isSuffix(RequestOptions request) =>
    request.headers['Range'] == 'bytes=-$readCacheTerminalLogLimit';

/// The number of rendered log rows: the tail is never joined with old bytes.
int _rows(WidgetTester tester) {
  final list = tester.widget<ListView>(find.descendant(
    of: find.byType(SelectionArea),
    matching: find.byType(ListView),
  ));
  return (list.childrenDelegate as SliverChildBuilderDelegate).childCount!;
}

void _scrollLogToTop(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byType(SelectionArea),
    matching: find.byType(Scrollable),
  ).first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
}

Widget _jobPage(GitLabApi api, {int id = 7, ValueNotifier<bool>? visible}) {
  final page = JobLogPage(account: _user, api: api, project: _project, id: id);
  return MaterialApp(home: visible == null
      ? page
      : ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, value, child) => TickerMode(enabled: value, child: child!),
          child: page,
        ));
}

void main() {
  group('diff version detail', () {
    testWidgets('restores the selected version from the encrypted disk for real', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await _run(tester, h.recover), isTrue);
      final firstAdapter = _diffAdapter();
      final first = await _run(tester, () => h.client(firstAdapter));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ReviewDiffPage(
        account: _user, api: first, project: _project, iid: 3, expectedSha: _sha))));
      await _until(tester, () => _shown(find.text('readme.md')), 'network diff');
      expect(firstAdapter.requests.where((r) => r.uri.path.endsWith('/versions/9')), hasLength(1));
      await _run(tester, h.flush);
      final stored = await _run(tester, () => h.entry(
        ['projects', '1', 'merge_requests', '3', 'versions', '9'], 'application/json'));
      expect(stored, isNotNull, reason: 'the version detail is on disk, encrypted');
      expect((stored!.body as Map)['id'], 9);
      expect(stored.cacheClass, ReadCacheDiskClass.pinned);

      // A new verified client: discovery is network, the detail comes from disk.
      await tester.pumpWidget(const SizedBox());
      final secondAdapter = _diffAdapter();
      final second = await _run(tester, () => h.client(secondAdapter));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ReviewDiffPage(
        account: _user, api: second, project: _project, iid: 3, expectedSha: _sha))));
      await _until(tester, () => _shown(find.text('readme.md')), 'disk diff');
      expect(secondAdapter.requests.where((r) => r.uri.path.endsWith('/versions')), hasLength(1),
        reason: 'version discovery stays on the network');
      expect(secondAdapter.requests.where((r) => r.uri.path.endsWith('/versions/9')), isEmpty,
        reason: 'the selected version detail came from disk');
      expect(tester.takeException(), isNull);
    });
  });

  group('finished job log tail', () {
    testWidgets('a truncated tail keeps its absolute start, says so, and restores from disk', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await _run(tester, h.recover), isTrue);
      final log = _log(33000);
      FakeAdapter adapter() => FakeAdapter((request) {
        if (_isTrace(request, 7)) return _isSuffix(request) ? _suffix(log) : jsonResponse({}, status: 500);
        if (request.uri.path.endsWith('/jobs/7')) return jsonResponse(_job(7));
        return jsonResponse({}, status: 404);
      });
      final firstAdapter = adapter();
      final first = await _run(tester, () => h.client(firstAdapter));
      await tester.pumpWidget(_jobPage(first));
      await _until(tester, () => _shown(find.byKey(const ValueKey('job-log-truncated'))), 'tail shown');
      expect(find.text('Log 太長，前段已截掉，只顯示最後一部分。'), findsOneWidget);
      // The 2 MiB tail (lines 232 to 32999) is shown as its last lines within
      // the screen's 20,000-line limit: the log's own end, never its start.
      expect(_rows(tester), _shownLines + 1); // and the empty row after the last newline
      _scrollLogToTop(tester);
      await tester.pump();
      expect(find.text(_line(33000 - _shownLines)), findsOneWidget);
      expect(find.text(_line(33000 - _shownLines - 1)), findsNothing);
      expect(find.text(_line(0)), findsNothing);
      expect(firstAdapter.requests.where((r) => _isTrace(r, 7)).every(_isSuffix), isTrue,
        reason: 'no unbounded or offset chunk read');
      await _run(tester, h.flush);
      // The stored tail also fits its metadata inside 2 MiB, so it can start a
      // little later; it is still one contiguous, absolute tail.
      final stored = await _run(tester, () => h.entry(
        ['projects', '1', 'jobs', '7', 'trace'], 'text/plain'));
      final storedLog = stored!.body as ReadCacheTerminalLog;
      expect(storedLog.truncated, isTrue);
      expect(storedLog.nextOffset, log.length);
      expect(storedLog.startOffset, log.length - storedLog.bytes.length);
      expect('\n'.allMatches(utf8.decode(storedLog.bytes)).length, greaterThan(_shownLines));

      // The language of the hint follows the interface.
      useLanguage(languageForTag('en')!);
      await tester.pumpWidget(const SizedBox());
      final secondAdapter = adapter();
      final second = await _run(tester, () => h.client(secondAdapter));
      await tester.pumpWidget(_jobPage(second));
      await _until(tester, () => _shown(find.byKey(const ValueKey('job-log-truncated'))), 'disk tail');
      expect(find.text('This log is too long. The beginning was cut off; only the last part is shown.'), findsOneWidget);
      expect(_rows(tester), _shownLines + 1); // and the empty row after the last newline
      _scrollLogToTop(tester);
      await tester.pump();
      expect(find.text(_line(33000 - _shownLines)), findsOneWidget);
      expect(secondAdapter.requests.where((r) => _isTrace(r, 7)), isEmpty,
        reason: 'the finished log came from the encrypted disk');
      expect(secondAdapter.requests.where((r) => r.uri.path.endsWith('/jobs/7')), isNotEmpty,
        reason: 'terminal eligibility is always fresh network metadata');
    });

    testWidgets('reloading a finished tail replaces it and never joins the bytes shown', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await _run(tester, h.recover), isTrue);
      final log = _log(30);
      final adapter = FakeAdapter((request) {
        if (_isTrace(request, 7)) return _isSuffix(request) ? _suffix(log) : jsonResponse({}, status: 500);
        if (request.uri.path.endsWith('/jobs/7')) return jsonResponse(_job(7));
        return jsonResponse({}, status: 404);
      });
      final api = await _run(tester, () => h.client(adapter));
      await tester.pumpWidget(_jobPage(api));
      await _until(tester, () => _shown(find.text(_line(29))), 'whole short tail');
      expect(_rows(tester), 31, reason: '30 lines and the empty row after the last newline');
      expect(find.byKey(const ValueKey('job-log-truncated')), findsNothing,
        reason: 'a complete log is not marked as cut');
      for (var reload = 0; reload < 2; reload++) {
        final before = adapter.requests.length;
        await tester.tap(find.byTooltip('重新讀取 Log'));
        await tester.pump();
        await _until(tester, () => adapter.requests.length > before &&
            !_shown(find.byType(LinearProgressIndicator)), 'reload');
        expect(_rows(tester), 31, reason: 'replaced, not appended');
      }
      expect(adapter.requests.where((r) => _isTrace(r, 7) && !_isSuffix(r)), isEmpty);
    });

    testWidgets('a retried attempt starts from byte 0 of its own log, never the old tail', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await _run(tester, h.recover), isTrue);
      final old = utf8.encode('attempt seven output\n');
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/jobs/7/retry')) return jsonResponse(_job(8, status: 'pending'));
        if (_isTrace(request, 7)) return _suffix(old);
        if (_isTrace(request, 8)) {
          return ResponseBody.fromString('attempt eight output\n', 200,
            headers: {'x-gitlab-trace-eof': ['false']});
        }
        if (path.endsWith('/jobs/7')) return jsonResponse(_job(7));
        if (path.endsWith('/jobs/8')) return jsonResponse(_job(8, status: 'pending'));
        return jsonResponse({}, status: 404);
      });
      final api = await _run(tester, () => h.client(adapter));
      await tester.pumpWidget(_jobPage(api));
      await _until(tester, () => _shown(find.text('attempt seven output')), 'old attempt');
      await tester.tap(find.byTooltip('工作操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重試工作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('確認'));
      await _until(tester, () => _shown(find.text('attempt eight output')), 'new attempt');
      expect(find.text('attempt seven output'), findsNothing);
      expect(_rows(tester), 2);
      final attempt8 = adapter.requests.where((r) => _isTrace(r, 8)).toList();
      expect(attempt8, isNotEmpty);
      expect(attempt8.first.headers['Range'], isNull, reason: 'byte 0 of the new attempt');
      expect(attempt8.first.uri.queryParameters['offset'], isNull);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsNothing);
      await tester.pump(const Duration(milliseconds: 500)); // confirm dialog cleanup
    });

    testWidgets('only unsupported falls back to the original bounded chunk read', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await _run(tester, h.recover), isTrue);
      final adapter = FakeAdapter((request) {
        if (_isTrace(request, 7)) {
          // A 200 without a length cannot prove EOF: unsupported for the tail.
          return ResponseBody.fromString('plain chunk output\n', 200);
        }
        if (request.uri.path.endsWith('/jobs/7')) return jsonResponse(_job(7));
        return jsonResponse({}, status: 404);
      });
      final api = await _run(tester, () => h.client(adapter));
      await tester.pumpWidget(_jobPage(api));
      await _until(tester, () => _shown(find.text('plain chunk output')), 'fallback');
      final traces = adapter.requests.where((r) => _isTrace(r, 7)).toList();
      expect(traces.map(_isSuffix), [true, false], reason: 'tail tried once, then the original read');
      expect(traces.last.uri.queryParameters['offset'], isNull);
      expect(_rows(tester), 2, reason: 'shown once, not joined to anything');
      expect(find.byKey(const ValueKey('job-log-truncated')), findsNothing);
    });

    testWidgets('a job without terminal proof (no erased_at) uses the original read', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await _run(tester, h.recover), isTrue);
      final adapter = FakeAdapter((request) {
        if (_isTrace(request, 7)) return ResponseBody.fromString('legacy output\n', 200);
        if (request.uri.path.endsWith('/jobs/7')) return jsonResponse(_job(7, erasedKey: false));
        return jsonResponse({}, status: 404);
      });
      final api = await _run(tester, () => h.client(adapter));
      await tester.pumpWidget(_jobPage(api));
      await _until(tester, () => _shown(find.text('legacy output')), 'legacy');
      final traces = adapter.requests.where((r) => _isTrace(r, 7)).toList();
      expect(traces, hasLength(1));
      expect(_isSuffix(traces.single), isFalse);
    });

    testWidgets('any other tail failure is the page failure, with no fallback read', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await _run(tester, h.recover), isTrue);
      final adapter = FakeAdapter((request) {
        if (_isTrace(request, 7)) return jsonResponse({'message': 'forbidden'}, status: 403);
        if (request.uri.path.endsWith('/jobs/7')) return jsonResponse(_job(7));
        return jsonResponse({}, status: 404);
      });
      final api = await _run(tester, () => h.client(adapter));
      await tester.pumpWidget(_jobPage(api));
      await _until(tester, () => _shown(find.text('沒有操作權限')), 'forbidden notice');
      expect(adapter.requests.where((r) => _isTrace(r, 7)).map(_isSuffix), [true]);
    });

    testWidgets('a running job keeps polling the offset chunks; hidden it does not', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await _run(tester, h.recover), isTrue);
      final first = utf8.encode('running line one\n');
      final adapter = FakeAdapter((request) {
        if (_isTrace(request, 7)) {
          if (request.headers['Range'] == 'bytes=${first.length}-') {
            return ResponseBody.fromString('running line two\n', 206, headers: {
              'content-range': ['bytes ${first.length}-${first.length + 16}/*'],
            });
          }
          return ResponseBody.fromBytes(first, 200);
        }
        if (request.uri.path.endsWith('/jobs/7')) return jsonResponse(_job(7, status: 'running'));
        return jsonResponse({}, status: 404);
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final api = await _run(tester, () => h.client(adapter));
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await tester.pumpWidget(_jobPage(api, visible: visible));
      await _until(tester, () => _shown(find.text('running line one')), 'first chunk');
      expect(adapter.requests.where(_isSuffix), isEmpty, reason: 'a running job never asks for a tail');
      await tester.tap(find.text('10 秒更新'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      await _until(tester, () => _shown(find.text('running line two')), 'polled chunk');
      final polled = adapter.requests.where((r) => _isTrace(r, 7)).last;
      expect(polled.uri.queryParameters['offset'], '${first.length}');

      // Hidden: the timer stops and nothing more is read or shown.
      final before = adapter.requests.length;
      visible.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 35));
      await settleNetworkWidgets(tester);
      expect(adapter.requests.length, before);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a page disposed while its tail is read publishes nothing afterwards', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await _run(tester, h.recover), isTrue);
      final hold = Completer<void>();
      final adapter = FakeAdapter((request) async {
        if (_isTrace(request, 7)) {
          await hold.future;
          return _suffix(utf8.encode('late output\n'));
        }
        if (request.uri.path.endsWith('/jobs/7')) return jsonResponse(_job(7));
        return jsonResponse({}, status: 404);
      });
      final api = await _run(tester, () => h.client(adapter));
      await tester.pumpWidget(_jobPage(api));
      await _until(tester, () => adapter.requests.any((r) => _isTrace(r, 7)), 'tail requested');
      await tester.pumpWidget(const SizedBox());
      hold.complete();
      await settleNetworkWidgets(tester);
      expect(tester.takeException(), isNull);
      expect(adapter.requests.where((r) => _isTrace(r, 7)), hasLength(1),
        reason: 'no fallback or follow-up read after dispose');
      expect(find.text('late output'), findsNothing);
    });
  });

  group('records feed over disk lineage', () {
    Future<(_Harness, DateTime)> seeded(WidgetTester tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await _run(tester, h.recover), isTrue);
      final adapter = FakeAdapter((_) => jsonResponse([projectJson(1)]));
      final api = await _run(tester, () => h.client(adapter));
      final fetched = h.now;
      final read = await _run(tester, () => api.cachedRecords(['projects']));
      expect(read.lineage, CacheLineage.network);
      await _run(tester, h.flush);
      expect(h.coordinator.stats.retainedEntries, 1, reason: 'the first page is on disk');
      return (h, fetched);
    }

    Widget feed(GitLabApi api) => MaterialApp(home: Scaffold(body: RecordsFeed(
      identity: 'projects',
      load: (next) => api.records(['projects'], next: next),
      cached: ({required bool fresh, required bool background}) =>
          api.cachedRecords(['projects'], fresh: fresh, background: background),
      itemBuilder: (context, item) => Text(item['name'] as String),
    )));

    CacheFreshnessBar bar(WidgetTester tester) =>
        tester.widget<CacheFreshnessBar>(find.byType(CacheFreshnessBar));

    testWidgets('a 10-second-old disk list keeps its fetchedAt, is stale and refreshes in the background', (tester) async {
      final (h, fetched) = await seeded(tester);
      h.now = fetched.add(const Duration(seconds: 10));
      final release = Completer<void>();
      final adapter = FakeAdapter((_) async {
        await release.future;
        return jsonResponse([{...projectJson(1), 'name': 'Example 1 refreshed'}]);
      });
      final api = await _run(tester, () => h.client(adapter));
      await tester.pumpWidget(feed(api));
      await _until(tester, () => _shown(find.text('Example 1')), 'disk rows');
      await _until(tester, () => _shown(find.byType(CacheFreshnessBar)), 'freshness strip');
      expect(bar(tester).fetchedAt, fetched, reason: 'the original network time, not the read time');
      expect(bar(tester).refreshing, isTrue);
      expect(find.text('正在更新'), findsOneWidget);
      expect(adapter.requests, hasLength(1), reason: 'one background network refresh');
      release.complete();
      await _until(tester, () => _shown(find.text('Example 1 refreshed')), 'network rows');
      expect(find.byType(CacheFreshnessBar), findsNothing);
    });

    testWidgets('offline keeps the disk rows with their time and recovers on refresh', (tester) async {
      final (h, fetched) = await seeded(tester);
      h.now = fetched.add(const Duration(seconds: 10));
      var online = false;
      final adapter = FakeAdapter((request) {
        if (!online) {
          throw DioException(requestOptions: request, type: DioExceptionType.connectionError);
        }
        return jsonResponse([{...projectJson(1), 'name': 'Example 1 back online'}]);
      });
      final api = await _run(tester, () => h.client(adapter));
      await tester.pumpWidget(feed(api));
      await _until(tester, () => _shown(find.text('無法連線')), 'offline strip');
      expect(find.text('Example 1'), findsOneWidget, reason: 'disk rows are kept');
      expect(bar(tester).fetchedAt, fetched);
      online = true;
      await tester.tap(find.descendant(of: find.byType(CacheFreshnessBar), matching: find.text('重新整理')));
      await _until(tester, () => _shown(find.text('Example 1 back online')), 'recovered');
      expect(find.byType(CacheFreshnessBar), findsNothing);
    });
  });
}
