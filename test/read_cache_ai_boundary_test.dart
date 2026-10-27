import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/core/read_cache_projection.dart';
import 'package:gitlab_mobile/core/request_meter.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_context.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_backend.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 20);
const _head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _base = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final _now = DateTime.utc(2026, 10, 27, 12);
final _instance = GitLabInstance.parse('https://cache.example/subpath');
final _account = '${_instance.key}#7';
const _project = Project(
  id: 9,
  name: 'Example',
  path: 'team/example',
  defaultBranch: 'main',
);
const _versionPath = ['projects', '9', 'merge_requests', '3', 'versions', '5'];

final class _Secrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => const [];
}

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

/// Holds the actual encrypted-file lookup after it has returned its entry.
final class _HoldLookup implements ReadCacheDiskBackend {
  _HoldLookup(this.delegate, this.target);
  final ReadCacheDiskBackend delegate;
  final String target;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool hold = true;

  @override
  Future<ProjectedDiskEntry?> lookup(DiskLookup request) async {
    final value = await delegate.lookup(request);
    if (hold && request.canonicalKey.contains(target) && value != null) {
      hold = false;
      entered.complete();
      await release.future.timeout(_deadline);
    }
    return value;
  }

  @override
  void accept(DiskWriteCandidate candidate, ProjectedDiskEntry entry) =>
      delegate.accept(candidate, entry);
  @override
  DiskInvalidationFence invalidate(DiskInvalidation invalidation) =>
      delegate.invalidate(invalidation);
  @override
  void revoke(DiskBinding binding) => delegate.revoke(binding);
  @override
  Future<DiskClearResult> clear(
    DiskBinding binding,
    ReadCacheCleanupOperation operation,
  ) => delegate.clear(binding, operation);
  @override
  void reportCleanup(ReadCacheCleanupState state) =>
      delegate.reportCleanup(state);
}

final class _Harness {
  _Harness() {
    root = Directory.systemTemp.createTempSync('c2d3-ai-');
    keys = ReadCacheKeyStore(storage);
    files = ReadCacheFileStore(root: () async => root, clock: () => _now);
    coordinator = ReadCacheDiskCoordinator(
      keys: keys,
      files: files,
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
      controlsInstalled: true,
      clock: () => _now,
    );
  }
  final storage = _Storage();
  late final Directory root;
  late final ReadCacheKeyStore keys;
  late final ReadCacheFileStore files;
  late final ReadCacheDiskCoordinator coordinator;
  final clients = <GitLabApi>[];

  Future<void> recover() async {
    expect(
      await coordinator.recover(
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
      ),
      isTrue,
    );
  }

  Future<GitLabApi> client(
    int generation,
    FakeAdapter adapter, {
    void Function(_HoldLookup)? onBackend,
    String holdTarget = '/versions/5',
  }) async {
    final binding = DiskBinding(accountKey: _account, generation: generation);
    expect(await coordinator.activate(binding), isTrue);
    final api = GitLabApi(
      instance: _instance,
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = adapter,
      readCacheClock: () => _now,
    );
    expect((await api.currentUser()).id, 7);
    api.bindReadCache(_account, generation);
    final backend = CoordinatedReadCacheDiskBackend(
      coordinator: coordinator,
      binding: binding,
    );
    if (onBackend == null) {
      api.attachReadCacheDiskBackend(backend);
    } else {
      final held = _HoldLookup(backend, holdTarget);
      onBackend(held);
      api.attachReadCacheDiskBackend(held);
    }
    clients.add(api);
    return api;
  }

  Future<ProjectedDiskEntry?> entry(Uri uri, String accept) async {
    final key = await keys.readKey(_account);
    expect(key.isFound, isTrue);
    final actual = readCacheDurableKey(
      binding: DiskBinding(accountKey: _account, generation: 1),
      instance: _instance,
      uri: uri,
      logicalAccept: accept,
    );
    expect(actual, isNotNull);
    return files.readEntry(_account, key.value, actual!);
  }

  Future<void> dispose() async {
    for (final api in clients.reversed) {
      api.close();
    }
    await coordinator.quiesced;
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Map<String, Object?> _version(String text) => {
  'id': 5,
  'base_commit_sha': _base,
  'start_commit_sha': _base,
  'head_commit_sha': _head,
  'diffs': [
    {'old_path': 'a', 'new_path': 'a', 'diff': '+$text'},
  ],
};

FakeAdapter _adapter(String text) => FakeAdapter((request) {
  final path = request.uri.path;
  if (path.endsWith('/user')) {
    return jsonResponse({'id': 7, 'username': 'tester'});
  }
  if (path.endsWith('/projects/9/jobs/7')) {
    return jsonResponse({
      'id': 7,
      'name': 'synthetic job',
      'stage': 'test',
      'status': 'success',
      'finished_at': '2026-10-27T11:59:00.000Z',
      'erased_at': null,
      'pipeline': {'id': 70, 'project_id': 9, 'sha': _head},
    });
  }
  if (path.endsWith('/projects/9/jobs/7/trace')) {
    return ResponseBody.fromString(
      text,
      200,
      headers: {
        'content-type': ['text/plain'],
        'content-length': ['${utf8.encode(text).length}'],
        'x-gitlab-trace-eof': ['true'],
      },
    );
  }
  if (path.endsWith('/repository/branches/main')) {
    return jsonResponse({
      'commit': {'id': _head},
    });
  }
  if (path.contains('/repository/files/README.md')) {
    if (request.method == 'HEAD') {
      return ResponseBody.fromString(
        '',
        200,
        headers: {
          'x-gitlab-size': ['${text.length}'],
        },
      );
    }
    return ResponseBody.fromString(
      text,
      200,
      headers: {
        'content-type': ['text/plain'],
      },
    );
  }
  if (path.endsWith('/versions')) {
    return jsonResponse([
      {'id': 5, 'head_commit_sha': _head, 'base_commit_sha': _base},
    ]);
  }
  if (path.endsWith('/versions/5')) return jsonResponse(_version(text));
  if (path.endsWith('/merge_requests/3')) {
    return jsonResponse({
      'id': 33,
      'iid': 3,
      'project_id': 9,
      'title': 'Synthetic MR',
      'state': 'opened',
      'diff_refs': {'head_sha': _head, 'base_sha': _base},
    });
  }
  if (path.endsWith('/merge_requests/3/notes')) return jsonResponse([]);
  return jsonResponse({'message': 'not found'}, status: 404);
});

Future<void> _confirmSha(GitLabApi api) => api
    .cachedRecord(['projects', '9', 'repository', 'branches', 'main'])
    .then((_) {});

Future<void> _writeVersion(_Harness h) async {
  final first = await h.client(1, _adapter('disk'));
  expect(
    (await first.cachedMergeRequestVersion(9, 3, 5)).lineage,
    CacheLineage.network,
  );
  await h.coordinator.flush(DiskBinding(accountKey: _account, generation: 1));
  final entry = await h.entry(_instance.api(_versionPath), 'application/json');
  expect(entry?.bodyKind, ReadCacheBodyKind.json);
  expect(entry?.cacheClass, ReadCacheDiskClass.pinned);
  expect((entry!.body as Map<String, dynamic>)['diffs'], [
    {'old_path': 'a', 'new_path': 'a', 'diff': '+disk'},
  ]);
}

String _diff(Map<String, dynamic> result) =>
    ((result['changes'] as List<Object?>).single
            as Map<String, dynamic>)['diff']
        as String;

void main() {
  for (final hydrate in [false, true]) {
    for (final contextRead in [false, true]) {
      test(
        'real AI ${contextRead ? 'job context' : 'job log'} ignores ${hydrate ? 'hydrated memory' : 'disk-only'} terminal trace',
        () async {
          final h = _Harness();
          addTearDown(h.dispose);
          await h.recover();
          final first = await h.client(1, _adapter('disk-log'));
          final seedMeter = RequestMeter();
          final seeded = await seedMeter.runAsync(
            () => first.cachedTerminalJobTrace(9, 7),
          );
          expect(seeded.lineage, CacheLineage.network);
          expect(seedMeter.count, 3);
          await h.coordinator.flush(
            DiskBinding(accountKey: _account, generation: 1),
          );
          final entry = await h.entry(
            _instance.api(['projects', '9', 'jobs', '7', 'trace']),
            'text/plain',
          );
          expect(entry?.bodyKind, ReadCacheBodyKind.terminalLog);
          expect(entry?.cacheClass, ReadCacheDiskClass.pinned);
          expect(
            utf8.decode((entry!.body as ReadCacheTerminalLog).bytes),
            'disk-log',
          );

          final adapter = _adapter('network-log');
          final api = await h.client(2, adapter);
          if (hydrate) {
            final meter = RequestMeter();
            final disk = await meter.runAsync(
              () => api.cachedTerminalJobTrace(9, 7),
            );
            expect(disk.lineage, CacheLineage.disk);
            expect(utf8.decode(disk.value.bytes), 'disk-log');
            expect(
              meter.count,
              1,
              reason: 'terminal eligibility is checked over HTTP',
            );
          }
          final before = adapter.requests.length;
          final meter = RequestMeter();
          if (contextRead) {
            final context = await meter
                .runAsync(
                  () => loadAiChatContext(
                    origin: const AiJobOrigin(
                      project: _project,
                      jobId: 7,
                      jobName: 'fixture',
                    ),
                    api: api,
                    redactor: Redactor(secrets: _Secrets()),
                    accountKey: _account,
                    refreshSecrets: () async {},
                    isCurrent: () => true,
                    now: () => _now,
                  ),
                )
                .timeout(_deadline);
            expect(context.built.blocks.single.text, contains('network-log'));
            expect(
              context.built.blocks.single.text,
              isNot(contains('disk-log')),
            );
          } else {
            final result = await meter
                .runAsync(
                  () => GitLabAiReadPort(api, 9, now: () => _now).jobLog(7),
                )
                .timeout(_deadline);
            expect(result.value, 'network-log');
            expect(result.requestCount, 1);
          }
          final requests = adapter.requests.skip(before).toList();
          expect(meter.count, contextRead && !hydrate ? 2 : 1);
          expect(requests, hasLength(meter.count));
          expect(
            requests.where((r) => r.uri.path.endsWith('/jobs/7/trace')),
            hasLength(1),
          );
          expect(requests.every((r) => r.method == 'GET'), isTrue);
        },
      );
    }
  }
  for (final contextRead in [false, true]) {
    test(
      'real AI ${contextRead ? 'job context' : 'job log'} cannot join a pending terminal trace hydration',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final first = await h.client(1, _adapter('disk-log'));
        await first.cachedTerminalJobTrace(9, 7);
        await h.coordinator.flush(
          DiskBinding(accountKey: _account, generation: 1),
        );
        final entry = await h.entry(
          _instance.api(['projects', '9', 'jobs', '7', 'trace']),
          'text/plain',
        );
        expect(entry?.bodyKind, ReadCacheBodyKind.terminalLog);
        expect(
          utf8.decode((entry!.body as ReadCacheTerminalLog).bytes),
          'disk-log',
        );

        final adapter = _adapter('network-log');
        late _HoldLookup held;
        final api = await h.client(
          2,
          adapter,
          holdTarget: '/jobs/7/trace',
          onBackend: (backend) => held = backend,
        );
        addTearDown(() {
          if (!held.release.isCompleted) held.release.complete();
        });
        final uiMeter = RequestMeter();
        final uiRead = uiMeter.runAsync(() => api.cachedTerminalJobTrace(9, 7));
        await held.entered.future.timeout(_deadline);
        expect(uiMeter.count, 1, reason: 'terminal proof is a network read');
        final before = adapter.requests.length;
        final meter = RequestMeter();
        if (contextRead) {
          final context = await meter
              .runAsync(
                () => loadAiChatContext(
                  origin: const AiJobOrigin(
                    project: _project,
                    jobId: 7,
                    jobName: 'fixture',
                  ),
                  api: api,
                  redactor: Redactor(secrets: _Secrets()),
                  accountKey: _account,
                  refreshSecrets: () async {},
                  isCurrent: () => true,
                  now: () => _now,
                ),
              )
              .timeout(_deadline);
          expect(context.built.blocks.single.text, contains('network-log'));
          expect(context.built.blocks.single.text, isNot(contains('disk-log')));
        } else {
          final result = await meter
              .runAsync(
                () => GitLabAiReadPort(api, 9, now: () => _now).jobLog(7),
              )
              .timeout(_deadline);
          expect(result.value, 'network-log');
          expect(result.requestCount, 1);
        }
        expect(held.release.isCompleted, isFalse);
        expect(meter.count, 1);
        final requests = adapter.requests.skip(before).toList();
        expect(requests, hasLength(1));
        expect(requests.single.method, 'GET');
        expect(requests.single.uri.path, endsWith('/jobs/7/trace'));
        held.release.complete();
        final disk = await uiRead.timeout(_deadline);
        expect(disk.lineage, CacheLineage.disk);
        expect(utf8.decode(disk.value.bytes), 'disk-log');
        expect(uiMeter.count, 1);
      },
    );
  }
  for (final hydrate in [false, true]) {
    test(
      'real AI read port ignores ${hydrate ? 'hydrated memory' : 'disk-only'} pinned file',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final first = await h.client(1, _adapter('disk-file'));
        await _confirmSha(first);
        expect(await first.textFile(9, _head, 'README.md'), 'disk-file');
        await h.coordinator.flush(
          DiskBinding(accountKey: _account, generation: 1),
        );
        final uri = _instance.api(
          ['projects', '9', 'repository', 'files', 'README.md'],
          {'ref': _head},
        );
        expect((await h.entry(uri, 'text/plain'))?.body, 'disk-file');
        final adapter = _adapter('network-file');
        final api = await h.client(2, adapter);
        await _confirmSha(api);
        expect(
          adapter.requests,
          hasLength(2),
          reason: 'currentUser and SHA proof are network reads',
        );
        if (hydrate) {
          expect(await api.textFile(9, _head, 'README.md'), 'disk-file');
          expect(
            adapter.requests,
            hasLength(2),
            reason: 'qualified disk lookup is zero HTTP',
          );
        }
        final before = adapter.requests.length;
        final result = await GitLabAiReadPort(
          api,
          9,
          now: () => _now,
        ).readFile(_head, 'README.md').timeout(_deadline);
        expect(result.value, 'network-file');
        expect(
          result.requestCount,
          2,
          reason: 'HEAD and GET are physical requests',
        );
        expect(adapter.requests.length - before, 2);
      },
    );
  }

  test(
    'real AI read port cannot join a pending pinned file hydration',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final first = await h.client(1, _adapter('disk-file'));
      await _confirmSha(first);
      await first.textFile(9, _head, 'README.md');
      await h.coordinator.flush(
        DiskBinding(accountKey: _account, generation: 1),
      );
      final adapter = _adapter('network-file');
      late _HoldLookup held;
      final api = await h.client(
        2,
        adapter,
        holdTarget: 'README.md',
        onBackend: (backend) => held = backend,
      );
      await _confirmSha(api);
      final uiRead = api.textFile(9, _head, 'README.md');
      addTearDown(() {
        if (!held.release.isCompleted) held.release.complete();
      });
      await held.entered.future.timeout(_deadline);
      final result = await GitLabAiReadPort(
        api,
        9,
        now: () => _now,
      ).readFile(_head, 'README.md').timeout(_deadline);
      expect(result.value, 'network-file');
      expect(result.requestCount, 2);
      held.release.complete();
      await uiRead.timeout(_deadline);
    },
  );

  test(
    'real AI write preflight and readback stay on HTTP with hydrated entries',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      FakeAdapter issueAdapter(String title) => FakeAdapter((request) {
        if (request.uri.path.endsWith('/user')) {
          return jsonResponse({'id': 7, 'username': 'tester'});
        }
        if (request.uri.path.endsWith('/projects/9')) {
          return jsonResponse(projectJson(9));
        }
        if (request.uri.path.endsWith('/issues/3')) {
          return jsonResponse({
            'id': 33,
            'iid': 3,
            'project_id': 9,
            'title': title,
            'confidential': false,
          });
        }
        return jsonResponse({}, status: 404);
      });
      const projectPath = ['projects', '9'];
      const issuePath = ['projects', '9', 'issues', '3'];
      final first = await h.client(1, issueAdapter('disk-title'));
      await first.cachedRecord(projectPath, query: {'license': 'true'});
      await first.cachedRecord(issuePath);
      await h.coordinator.flush(
        DiskBinding(accountKey: _account, generation: 1),
      );
      expect(
        (await h.entry(_instance.api(issuePath), 'application/json'))?.body,
        isNotNull,
      );

      final adapter = issueAdapter('network-title');
      final api = await h.client(2, adapter);
      expect(
        (await api.cachedRecord(
          projectPath,
          query: {'license': 'true'},
        )).lineage,
        CacheLineage.disk,
      );
      expect((await api.cachedRecord(issuePath)).lineage, CacheLineage.disk);
      final port = GitLabAiWritePort(api, accountKey: _account);
      final meter = RequestMeter();
      final prepared = await meter.runAsync(
        () => port.prepare(
          AiWriteRequest(
            operationId: 'updateIssue',
            executionId: 'synthetic-ai-update',
            scope: AiWriteScope(
              accountKey: _account,
              grants: const [
                AiScopeGrant(
                  kind: AiScopeKind.project,
                  projectId: 9,
                  projectPath: 'team/example-9',
                ),
              ],
            ),
            arguments: const {
              'projectId': 9,
              'iid': 3,
              'fields': {'title': 'updated'},
            },
          ),
        ),
      );
      expect(
        meter.count,
        3,
        reason: 'currentUser, project and issue are fresh network preflight',
      );
      final before = adapter.requests.length;
      final outcome = await meter.runAsync(
        () => port.commit(prepared, mayStart: () => true),
      );
      expect(
        outcome,
        isA<AiWriteSettled>().having(
          (v) => v.readbackVerified,
          'readbackVerified',
          isTrue,
        ),
      );
      expect((outcome as AiWriteSettled).state, AiJournalState.succeeded);
      expect(
        meter.count,
        5,
        reason: 'PUT and independent readback GET are both metered',
      );
      expect(adapter.requests.skip(before).map((r) => r.method), [
        'PUT',
        'GET',
      ]);
    },
  );
  for (final hydrate in [false, true]) {
    test(
      'real AI MR diff refuses ${hydrate ? 'hydrated memory' : 'disk-only'} pinned version',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        await _writeVersion(h);
        final adapter = _adapter('network');
        final api = await h.client(2, adapter);
        expect(
          adapter.requests,
          hasLength(1),
          reason: 'new client verifies currentUser over HTTP',
        );
        if (hydrate) {
          final disk = await api.cachedMergeRequestVersion(9, 3, 5);
          expect(disk.lineage, CacheLineage.disk);
          expect(
            adapter.requests,
            hasLength(1),
            reason: 'only the disk lookup costs zero HTTP',
          );
        }
        final result = await GitLabAiReadPort(api, 9, now: () => _now)
            .mergeRequestDiff(3, headSha: _head, baseSha: _base)
            .timeout(_deadline);
        expect(_diff(result.value), '+network');
        expect(result.requestCount, 2);
        expect(
          adapter.requests.where((r) => r.uri.path.endsWith('/versions/5')),
          hasLength(1),
        );
      },
    );
    test(
      'real AI MR context refuses ${hydrate ? 'hydrated memory' : 'disk-only'} pinned version',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        await _writeVersion(h);
        final adapter = _adapter('network');
        final api = await h.client(2, adapter);
        if (hydrate) {
          expect(
            (await api.cachedMergeRequestVersion(9, 3, 5)).lineage,
            CacheLineage.disk,
          );
          expect(adapter.requests, hasLength(1));
        }
        final before = adapter.requests.length;
        final context = await loadAiChatContext(
          origin: const AiWorkItemOrigin(
            project: _project,
            kind: AiWorkItemKind.mergeRequest,
            iid: 3,
            title: 'Synthetic MR',
          ),
          api: api,
          redactor: Redactor(secrets: _Secrets()),
          accountKey: _account,
          refreshSecrets: () async {},
          isCurrent: () => true,
          now: () => _now,
        ).timeout(_deadline);
        expect(context.built.blocks.single.text, contains('+network'));
        expect(context.built.blocks.single.text, isNot(contains('+disk')));
        expect(
          adapter.requests.length - before,
          4,
          reason:
              'MR metadata, versions list, selected detail and notes use HTTP',
        );
        expect(
          adapter.requests.where((r) => r.uri.path.endsWith('/versions/5')),
          hasLength(1),
        );
      },
    );
  }

  test('real AI MR diff cannot join a pending disk hydration', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.recover();
    await _writeVersion(h);
    final adapter = _adapter('network');
    late _HoldLookup held;
    final api = await h.client(
      2,
      adapter,
      onBackend: (backend) => held = backend,
    );
    final uiRead = api.cachedMergeRequestVersion(9, 3, 5);
    addTearDown(() {
      if (!held.release.isCompleted) held.release.complete();
    });
    await held.entered.future.timeout(_deadline);
    final result = await GitLabAiReadPort(
      api,
      9,
      now: () => _now,
    ).mergeRequestDiff(3, headSha: _head, baseSha: _base).timeout(_deadline);
    expect(_diff(result.value), '+network');
    expect(result.requestCount, 2);
    expect(
      adapter.requests.where((r) => r.uri.path.endsWith('/versions/5')),
      hasLength(1),
    );
    held.release.complete();
    await uiRead.timeout(_deadline);
  });

  for (final hydrate in [false, true]) {
    test(
      'real AI file context ignores ${hydrate ? 'hydrated memory' : 'disk-only'} pinned file',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final first = await h.client(1, _adapter('disk-file'));
        await _confirmSha(first);
        expect(await first.textFile(9, _head, 'README.md'), 'disk-file');
        await h.coordinator.flush(
          DiskBinding(accountKey: _account, generation: 1),
        );
        final uri = _instance.api(
          ['projects', '9', 'repository', 'files', 'README.md'],
          {'ref': _head},
        );
        expect((await h.entry(uri, 'text/plain'))?.body, 'disk-file');
        final adapter = _adapter('network-file');
        final api = await h.client(2, adapter);
        await _confirmSha(api);
        expect(
          adapter.requests,
          hasLength(2),
          reason: 'currentUser and SHA proof are network reads',
        );
        if (hydrate) {
          expect(await api.textFile(9, _head, 'README.md'), 'disk-file');
          expect(
            adapter.requests,
            hasLength(2),
            reason: 'qualified disk lookup is zero HTTP',
          );
        }
        final before = adapter.requests.length;
        final context = await loadAiChatContext(
          origin: const AiFileOrigin(
            project: _project,
            path: 'README.md',
            sha: _head,
          ),
          api: api,
          redactor: Redactor(secrets: _Secrets()),
          accountKey: _account,
          refreshSecrets: () async {},
          isCurrent: () => true,
          now: () => _now,
        ).timeout(_deadline);
        expect(context.built.blocks.single.text, contains('network-file'));
        expect(context.built.blocks.single.text, isNot(contains('disk-file')));
        expect(
          adapter.requests.length - before,
          2,
          reason: 'HEAD and bounded GET remain network',
        );
      },
    );
  }
}
