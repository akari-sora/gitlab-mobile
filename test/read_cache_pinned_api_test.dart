import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/core/read_cache_projection.dart';
import 'package:gitlab_mobile/core/request_meter.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_backend.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';

import 'support/fake_adapter.dart';

final _instance = GitLabInstance.parse('https://cache.example/subpath');
final _account = '${_instance.key}#7';
final _initialNow = DateTime.utc(2026, 10, 27, 12);
final _finished = DateTime.utc(2026, 10, 27, 11);
const _sha = '0123456789abcdef0123456789abcdef01234567';
const _versionPath = ['projects', '1', 'merge_requests', '3', 'versions', '9'];
const _jobPath = ['projects', '1', 'jobs', '7'];
const _tracePath = [..._jobPath, 'trace'];
const _deadline = Duration(seconds: 15);

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
      'token': 'discard-diff-secret',
    },
  ],
  'private_token': 'discard-version-secret',
};

Json _job() => {
  'id': 7,
  'name': 'synthetic-build',
  'status': 'success',
  'finished_at': _finished.toIso8601String(),
  'erased_at': null,
  'pipeline': {'id': 6, 'project_id': 1, 'sha': _sha},
};

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
  _Harness({this.controls = true}) {
    root = Directory.systemTemp.createTempSync('c2d3-pinned-');
    files = ReadCacheFileStore(root: () async => root, clock: () => now);
    keys = ReadCacheKeyStore(storage);
    coordinator = ReadCacheDiskCoordinator(
      keys: keys,
      files: files,
      settings: ReadCacheSettingsStore(storage),
      controlsInstalled: controls,
      coordinationScope: Object(),
      clock: () => now,
    );
  }
  final bool controls;
  final storage = _Storage();
  late final Directory root;
  late final ReadCacheFileStore files;
  late final ReadCacheKeyStore keys;
  late final ReadCacheDiskCoordinator coordinator;
  DateTime now = _initialNow;
  Json metadata = _job();
  Json version = _version();
  List<int> trace = utf8.encode('synthetic raw log 文\n');
  Responder? traceResponse;
  Responder? extraResponse;
  bool noStore = false;
  bool metadataNoStore = false;
  final clients = <GitLabApi>[];
  final adapters = <FakeAdapter>[];

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

  ResponseBody respond(RequestOptions request) {
    if (request.uri.path.endsWith('/user')) {
      return jsonResponse({'id': 7, 'username': 'synthetic'});
    }
    if (request.uri.path.endsWith('/jobs/7/trace')) {
      return ResponseBody.fromBytes(
        trace,
        200,
        headers: {
          'content-length': ['${trace.length}'],
          'x-gitlab-trace-eof': ['true'],
          if (noStore) 'cache-control': ['no-store'],
        },
      );
    }
    if (request.uri.path.endsWith('/jobs/7')) {
      return jsonResponse(
        metadata,
        headers: {
          if (metadataNoStore) 'cache-control': ['no-store'],
        },
      );
    }
    if (request.uri.path.endsWith('/versions/9')) {
      return jsonResponse(
        version,
        headers: {
          if (noStore) 'cache-control': ['no-store'],
        },
      );
    }
    return jsonResponse({}, status: 404);
  }

  Future<GitLabApi> client({bool ready = true}) async {
    await flush();
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/jobs/7/trace') && traceResponse != null) {
        return traceResponse!(request);
      }
      if (extraResponse != null &&
          !request.uri.path.endsWith('/user') &&
          !request.uri.path.endsWith('/jobs/7') &&
          !request.uri.path.endsWith('/versions/9') &&
          !request.uri.path.endsWith('/jobs/7/trace')) {
        return extraResponse!(request);
      }
      return respond(request);
    });
    final api = GitLabApi(
      instance: _instance,
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = adapter,
      readCacheClock: () => now,
    );
    // This is a physical network verification, included in RequestMeter.
    expect((await api.currentUser()).id, 7);
    final binding = DiskBinding(
      accountKey: _account,
      generation: clients.length + 1,
    );
    api.bindReadCache(_account, binding.generation);
    expect(await coordinator.activate(binding), ready);
    api.attachReadCacheDiskBackend(
      CoordinatedReadCacheDiskBackend(
        coordinator: coordinator,
        binding: binding,
      ),
    );
    clients.add(api);
    adapters.add(adapter);
    return api;
  }

  Future<ProjectedDiskEntry?> entry(List<String> path, String accept) async {
    await flush();
    final key = await keys.readKey(_account);
    if (!key.isFound) return null;
    // Use the real account in the durable identity, independent of generation.
    final accountDurable = readCacheDurableKey(
      binding: DiskBinding(accountKey: _account, generation: 999),
      instance: _instance,
      uri: _instance.api(path),
      logicalAccept: accept,
    );
    return files.readEntry(_account, key.value, accountDurable!);
  }

  Future<void> flush() async {
    if (clients.isNotEmpty) {
      final api = clients.last;
      await coordinator.flush(
        DiskBinding(accountKey: _account, generation: api.readCacheGeneration!),
      );
    }
    await coordinator.quiesced;
  }

  Future<void> dispose() async {
    for (final api in clients.reversed) {
      api.close();
    }
    await coordinator.quiesced;
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Matcher _failure(FailureKind kind, {int? status}) => isA<ApiFailure>()
    .having((error) => error.kind, 'kind', kind)
    .having((error) => error.status, 'status', status);

ResponseBody _suffix(
  List<int> source, {
  int? start,
  int? end,
  int? total,
  bool? eof,
  int? length,
  String? contentRange,
}) {
  final offset = source.length > readCacheTerminalLogLimit
      ? source.length - readCacheTerminalLogLimit
      : 0;
  final bytes = source.sublist(offset);
  return ResponseBody.fromBytes(
    bytes,
    206,
    headers: {
      'content-range': [
        contentRange ??
            'bytes ${start ?? offset}-${end ?? source.length - 1}/${total ?? source.length}',
      ],
      'content-length': ['${length ?? bytes.length}'],
      if (eof != null) 'x-gitlab-trace-eof': ['$eof'],
    },
  );
}

void main() {
  test(
    'E18 network encrypted file fresh verified client field-by-field round trip',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final meter = RequestMeter();
      final first = await meter.runAsync(h.client);
      expect(meter.count, 1);
      final read = await meter.runAsync(
        () => first.cachedMergeRequestVersion(1, 3, 9),
      );
      expect(read.lineage, CacheLineage.network);
      expect(meter.count, 2);
      final entry = (await h.entry(_versionPath, 'application/json'))!;
      final expected = _version()..remove('private_token');
      (expected['diffs'] as List<Json>).single.remove('token');
      expect(entry.body, expected);
      expect(entry.bodyKind, ReadCacheBodyKind.json);
      expect(entry.cacheClass, ReadCacheDiskClass.pinned);
      expect(entry.fetchedAt, h.now);
      expect(entry.issueIdentities, isEmpty);
      expect(entry.scopeTags, isEmpty);
      expect(entry.scopeVersions, isEmpty);
      expect(entry.serializedLength, lessThanOrEqualTo(readCacheEntryLimit));
      final second = await meter.runAsync(h.client);
      expect(meter.count, 3); // A fresh client is not a zero-HTTP cold start.
      final before = meter.count;
      final disk = await meter.runAsync(
        () => second.cachedMergeRequestVersion(1, 3, 9),
      );
      expect(disk.lineage, CacheLineage.disk);
      expect(disk.value, expected);
      expect(disk.fetchedAt, read.fetchedAt);
      expect(disk.stale, isFalse);
      expect(meter.count - before, 0);
      final memory = await second.cachedMergeRequestVersion(1, 3, 9);
      expect(memory.lineage, CacheLineage.disk);
      expect(
        await second
            .records(['projects', '1', 'merge_requests', '3', 'versions'])
            .then((_) => false)
            .catchError((Object _) => true),
        isTrue,
      );
    },
  );

  for (final invalid in <String, void Function(Json)>{
    'version identity': (value) => value['id'] = 10,
    'diff SHA': (value) => value['head_commit_sha'] = 'main',
    'diff collection': (value) => value['diffs'] = 'not a diff list',
  }.entries) {
    test('E18 rejects invalid ${invalid.key} without persisting', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      invalid.value(h.version);
      final api = await h.client();
      await expectLater(
        api.cachedMergeRequestVersion(1, 3, 9),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      expect(await h.entry(_versionPath, 'application/json'), isNull);
    });
  }

  test(
    'E19 fresh terminal proof encrypted tail and verified-client meter round trip',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final meter = RequestMeter();
      final first = await meter.runAsync(h.client);
      final read = await meter.runAsync(
        () => first.cachedTerminalJobTrace(1, 7),
      );
      expect(
        meter.count,
        4,
      ); // currentUser + metadata + trace + attempt recheck.
      expect(read.lineage, CacheLineage.network);
      final entry = (await h.entry(_tracePath, 'text/plain'))!;
      final log = entry.body as ReadCacheTerminalLog;
      expect(log.metadata, {
        'projectId': 1,
        'jobId': 7,
        'finishedAt': _finished.toIso8601String(),
        'startOffset': 0,
        'nextOffset': h.trace.length,
        'totalBytes': h.trace.length,
        'isEof': true,
        'truncated': false,
      });
      expect(log.bytes, h.trace);
      expect(utf8.decode(log.bytes), 'synthetic raw log 文\n');
      expect(entry.metadata.keys.toSet(), {
        'schema',
        'accountKey',
        'canonicalKey',
        'cacheClass',
        'bodyKind',
        'fetchedAt',
        'privacyEpoch',
        'scopeTags',
        'scopeVersions',
        'issueIdentities',
        'terminalLog',
      });
      expect(entry.metadata['bodyKind'], 'terminalLog');
      expect(entry.metadata['cacheClass'], 'pinned');
      expect(entry.metadata['accountKey'], _account);
      expect(entry.issueIdentities, isEmpty);
      expect(entry.scopeTags, isEmpty);
      expect(entry.scopeVersions, isEmpty);
      final ciphertext = h.root.listSync(recursive: true).whereType<File>();
      for (final file in ciphertext) {
        expect(
          latin1.decode(file.readAsBytesSync()),
          isNot(contains('synthetic raw log')),
        );
      }
      final second = await meter.runAsync(h.client);
      expect(meter.count, 5);
      final proof = await meter.runAsync(
        () => second.cachedRecord(_jobPath, allowDisk: false),
      );
      expect(proof.lineage, CacheLineage.network);
      expect(meter.count, 6);
      final before = meter.count;
      final disk = await meter.runAsync(
        () => second.cachedTerminalJobTrace(1, 7),
      );
      expect(disk.lineage, CacheLineage.disk);
      expect(disk.value.metadata, log.metadata);
      expect(disk.value.bytes, log.bytes);
      expect(disk.fetchedAt, read.fetchedAt);
      expect(meter.count - before, 0);
      expect(second.readCacheMetadataCounts['publications'], 0);
    },
  );

  for (final status in [
    'running',
    'pending',
    'manual',
    'created',
    'scheduled',
    'preparing',
  ]) {
    test(
      'running/nonterminal $status trace is refused before disk or Range',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        h.metadata['status'] = status;
        final api = await h.client();
        ApiFailure? failure;
        try {
          await api.cachedTerminalJobTrace(1, 7);
        } on ApiFailure catch (error) {
          failure = error;
        }
        expect(await h.entry(_tracePath, 'text/plain'), isNull);
        expect(
          h.adapters.single.requests.where(
            (r) => r.uri.path.endsWith('/trace'),
          ),
          isEmpty,
        );
        expect(failure, _failure(FailureKind.unsupported));
      },
    );
  }

  final badProofs = <String, void Function(Json)>{
    'foreign job': (job) => job['id'] = 8,
    'foreign project': (job) => (job['pipeline'] as Json)['project_id'] = 2,
    'foreign top-level project': (job) => job['project_id'] = 2,
    'erased': (job) => job['erased_at'] = _finished.toIso8601String(),
    'unknown erased state': (job) => job.remove('erased_at'),
    'missing finish': (job) => job['finished_at'] = null,
    'invalid finish': (job) => job['finished_at'] = 'invalid',
    'future finish': (job) => job['finished_at'] = _initialNow
        .add(const Duration(seconds: 1))
        .toIso8601String(),
  };
  for (final bad in badProofs.entries) {
    test('terminal proof rejects ${bad.key}', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      bad.value(h.metadata);
      final api = await h.client();
      await expectLater(
        api.cachedTerminalJobTrace(1, 7),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(await h.entry(_tracePath, 'text/plain'), isNull);
    });
  }

  test(
    '2 MiB includes metadata and UTF-8 with absolute offsets and no localized prefix',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      h.trace = utf8.encode('文🌟' * ((readCacheTerminalLogLimit ~/ 7) + 301));
      h.traceResponse = (request) {
        expect(request.headers['Range'], 'bytes=-$readCacheTerminalLogLimit');
        expect(request.headers['Accept'], 'text/plain');
        expect(request.uri.query, isEmpty);
        return _suffix(h.trace, eof: true);
      };
      final api = await h.client();
      final read = await api.cachedTerminalJobTrace(1, 7);
      final entry = (await h.entry(_tracePath, 'text/plain'))!;
      final log = read.value;
      final envelope = ProjectedDiskEntry(
        accountKey: entry.accountKey,
        canonicalKey: entry.canonicalKey,
        cacheClass: entry.cacheClass,
        bodyKind: entry.bodyKind,
        fetchedAt: entry.fetchedAt,
        body: log,
        privacyEpoch: entry.privacyEpoch,
        issueIdentities: entry.issueIdentities,
      );
      expect(
        envelope.serializedLength,
        lessThanOrEqualTo(readCacheTerminalLogLimit),
      );
      expect(
        entry.serializedLength,
        lessThanOrEqualTo(readCacheTerminalLogLimit),
      );
      expect(
        entry.serializedLength,
        greaterThan(readCacheTerminalLogLimit - 7),
      );
      expect(log.bytes, h.trace.sublist(log.startOffset));
      expect(
        log.startOffset,
        greaterThan(h.trace.length - readCacheTerminalLogLimit),
      );
      expect(log.nextOffset, h.trace.length);
      expect(log.totalBytes, h.trace.length);
      expect(log.truncated, isTrue);
      expect(log.isEof, isTrue);
      expect(
        utf8.decode(log.bytes, allowMalformed: false),
        isNot(contains('\uFFFD')),
      );
      expect((entry.body as ReadCacheTerminalLog).metadata, log.metadata);
      expect((entry.body as ReadCacheTerminalLog).bytes, log.bytes);
    },
  );

  final invalidRanges = <String, ResponseBody Function(List<int>)>{
    'mismatched requested suffix': (bytes) =>
        _suffix(bytes, start: 1, end: bytes.length, total: bytes.length + 1),
    'end before EOF': (bytes) => _suffix(bytes, end: bytes.length - 2),
    'unknown total': (bytes) => _suffix(bytes, contentRange: 'bytes 0-2/*'),
    'Content-Range not anchored': (bytes) =>
        _suffix(bytes, contentRange: 'prefix bytes 0-2/3 suffix'),
    'negative EOF': (bytes) => _suffix(bytes, eof: false),
    'wrong content length': (bytes) => _suffix(bytes, length: bytes.length + 1),
    'missing Content-Range': (bytes) => ResponseBody.fromBytes(bytes, 206),
    'ignored Range unknown length': (bytes) =>
        ResponseBody.fromBytes(bytes, 200),
    'ignored Range incomplete body': (bytes) => ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        'content-length': ['${bytes.length + 1}'],
      },
    ),
    'Range unsatisfiable': (bytes) => ResponseBody.fromBytes([], 416),
    'invalid UTF-8': (bytes) => ResponseBody.fromBytes(
      [0xff],
      200,
      headers: {
        'content-length': ['1'],
      },
    ),
  };
  for (final invalid in invalidRanges.entries) {
    test(
      'unsupported ${invalid.key} is not stored and falls back only by exact kind',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        h.traceResponse = (_) => invalid.value(h.trace);
        final api = await h.client();
        final meter = RequestMeter();
        await expectLater(
          meter.runAsync(() => api.cachedTerminalJobTrace(1, 7)),
          throwsA(_failure(FailureKind.unsupported)),
        );
        expect(meter.count, 2);
        expect(await h.entry(_tracePath, 'text/plain'), isNull);
        h.traceResponse = null;
        // This is the existing bounded fallback selected by e on exact unsupported.
        final fallback = await meter.runAsync(
          () => api.jobTraceChunk(1, 7, maxBytes: 128),
        );
        expect(fallback.bytes, h.trace);
        expect(meter.count, 3);
      },
    );
  }

  test(
    'ignored oversized Range is cancelled with a bounded body budget',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      var chunks = 0;
      var cancelled = false;
      h.traceResponse = (_) => ResponseBody(
        Stream<Uint8List>.multi((sink) {
          sink.onCancel = () {
            cancelled = true;
          };
          Future<void> emit() async {
            while (!cancelled && chunks < 10000) {
              chunks++;
              sink.add(Uint8List(64 * 1024));
              await Future<void>.delayed(Duration.zero);
            }
            unawaited(sink.close());
          }

          unawaited(emit());
        }),
        200,
      );
      final api = await h.client();
      await expectLater(
        api.cachedTerminalJobTrace(1, 7),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(chunks, lessThanOrEqualTo(34));
      expect(cancelled, isTrue);
      expect(await h.entry(_tracePath, 'text/plain'), isNull);
    },
  );

  for (final status in [401, 403, 404, 429, 500]) {
    test('terminal Range preserves HTTP $status failure', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      h.traceResponse = (_) => jsonResponse({}, status: status);
      final api = await h.client();
      await expectLater(
        api.cachedTerminalJobTrace(1, 7),
        throwsA(
          isA<ApiFailure>()
              .having((f) => f.status, 'status', status)
              .having((f) => f.kind, 'kind', isNot(FailureKind.unsupported)),
        ),
      );
      expect(await h.entry(_tracePath, 'text/plain'), isNull);
    });
  }

  test('network failure is not converted to unsupported', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.recover();
    h.traceResponse = (request) => throw DioException(
      requestOptions: request,
      type: DioExceptionType.connectionError,
    );
    final api = await h.client();
    await expectLater(
      api.cachedTerminalJobTrace(1, 7),
      throwsA(_failure(FailureKind.network)),
    );
  });

  test(
    'terminal proof expires during Range and prevents disk commit',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final entered = Completer<void>();
      final release = Completer<void>();
      h.traceResponse = (_) async {
        entered.complete();
        await release.future;
        return _suffix(h.trace);
      };
      final api = await h.client();
      final read = api.cachedTerminalJobTrace(1, 7);
      await entered.future.timeout(_deadline);
      h.now = h.now.add(const Duration(seconds: 30));
      release.complete();
      await expectLater(read, throwsA(_failure(FailureKind.unsupported)));
      expect(await h.entry(_tracePath, 'text/plain'), isNull);
    },
  );

  test(
    'new attempt while Range is pending cannot commit the old terminal proof',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final entered = Completer<void>();
      final release = Completer<void>();
      h.traceResponse = (_) async {
        entered.complete();
        await release.future;
        return _suffix(h.trace);
      };
      final api = await h.client();
      final read = api.cachedTerminalJobTrace(1, 7);
      await entered.future.timeout(_deadline);
      h.metadata['finished_at'] = _finished
          .add(const Duration(minutes: 1))
          .toIso8601String();
      await api.cachedRecord(_jobPath, fresh: true, allowDisk: false);
      release.complete();
      await expectLater(read, throwsA(_failure(FailureKind.unsupported)));
      expect(await h.entry(_tracePath, 'text/plain'), isNull);
    },
  );

  test(
    'disk-lineage job metadata never serves as terminal eligibility',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final first = await h.client();
      await first.cachedRecord(_jobPath);
      await h.coordinator.quiesced;
      final second = await h.client();
      expect((await second.cachedRecord(_jobPath)).lineage, CacheLineage.disk);
      final meter = RequestMeter();
      await meter.runAsync(() => second.cachedTerminalJobTrace(1, 7));
      expect(meter.count, 3);
      expect(
        h.adapters.last.requests.where((r) => r.uri.path.endsWith('/jobs/7')),
        hasLength(2),
      );
    },
  );

  test(
    'ordinary and global mutations preserve pinned disk and do not wait for active scopes',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final api = await h.client();
      await api.cachedMergeRequestVersion(1, 3, 9);
      await api.cachedTerminalJobTrace(1, 7);
      await h.coordinator.quiesced;
      for (final global in [false, true]) {
        final entered = Completer<void>();
        final release = Completer<void>();
        h.extraResponse = (request) async {
          if (request.method == 'PUT') {
            entered.complete();
            await release.future;
            return jsonResponse({'id': 2});
          }
          return jsonResponse({}, status: 404);
        };
        final write = api.writeRecord(
          'PUT',
          ['projects', '1', 'issues', '2'],
          {'description': global ? '/close' : 'ordinary'},
        );
        await entered.future.timeout(_deadline);
        // Force actual pinned network loads while the mutation is still held.
        expect(
          (await api
                  .cachedMergeRequestVersion(1, 3, 9, fresh: true)
                  .timeout(_deadline))
              .superseded,
          isFalse,
        );
        expect(
          (await api
                  .cachedTerminalJobTrace(1, 7, fresh: true)
                  .timeout(_deadline))
              .superseded,
          isFalse,
        );
        release.complete();
        await write;
        expect(
          await h.entry(_versionPath, 'application/json'),
          isNotNull,
          reason: 'ordinary/global mutations must preserve pinned entries',
        );
        expect(await h.entry(_tracePath, 'text/plain'), isNotNull);
      }
      final second = await h.client();
      expect(
        (await second.cachedMergeRequestVersion(1, 3, 9)).lineage,
        CacheLineage.disk,
      );
      expect(
        (await second.cachedTerminalJobTrace(1, 7)).lineage,
        CacheLineage.disk,
      );
    },
  );

  for (final status in [403, 404]) {
    test(
      'REST $status permission revokes terminal and MR pinned disk',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final api = await h.client();
        await api.cachedMergeRequestVersion(1, 3, 9);
        await api.cachedTerminalJobTrace(1, 7);
        await h.coordinator.quiesced;
        h.extraResponse = (_) => jsonResponse({}, status: status);
        await expectLater(
          api.record(['projects', '1']),
          throwsA(isA<ApiFailure>().having((f) => f.status, 'status', status)),
        );
        await h.coordinator.quiesced;
        expect(await h.entry(_versionPath, 'application/json'), isNull);
        expect(await h.entry(_tracePath, 'text/plain'), isNull);
      },
    );
  }

  test(
    'account clear deletes both pinned entries and old client cannot repopulate',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final api = await h.client();
      await api.cachedMergeRequestVersion(1, 3, 9);
      await api.cachedTerminalJobTrace(1, 7);
      await h.coordinator.quiesced;
      await h.coordinator.clearReadCacheDisk(_account);
      expect(await h.entry(_versionPath, 'application/json'), isNull);
      expect(await h.entry(_tracePath, 'text/plain'), isNull);
      await api.cachedMergeRequestVersion(1, 3, 9, fresh: true);
      await h.coordinator.quiesced;
      expect(await h.entry(_versionPath, 'application/json'), isNull);
    },
  );

  test('seven-day expiry and memory LRU still apply to typed pins', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.recover();
    final api = await h.client();
    await api.cachedMergeRequestVersion(1, 3, 9);
    await h.coordinator.quiesced;
    h.now = h.now.add(
      const Duration(days: 7) - const Duration(microseconds: 1),
    );
    expect(
      (await api.cachedMergeRequestVersion(1, 3, 9)).lineage,
      CacheLineage.memory,
    );
    h.now = h.now.add(const Duration(microseconds: 1));
    expect(
      (await api.cachedMergeRequestVersion(1, 3, 9)).lineage,
      CacheLineage.network,
    );
    h.extraResponse = (request) => jsonResponse({
      'id': int.parse(request.uri.pathSegments.last),
      'name': 'synthetic',
      'path_with_namespace': 'team/synthetic',
    });
    for (var id = 10; id < 10 + GitLabApi.maxCachedReads; id++) {
      await api.cachedRecord(['projects', '$id']);
    }
    final before = h.adapters.single.requests.length;
    // Disk-forbidden lookup exposes memory eviction without hiding it behind disk.
    expect(
      (await api.cachedMergeRequestVersion(1, 3, 9, allowDisk: false)).lineage,
      CacheLineage.network,
    );
    expect(h.adapters.single.requests.length - before, 1);
  });

  test('no-store refresh removes older pinned memory and disk', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.recover();
    final api = await h.client();
    await api.cachedMergeRequestVersion(1, 3, 9);
    await api.cachedTerminalJobTrace(1, 7);
    await h.coordinator.quiesced;
    h.noStore = true;
    await api.cachedMergeRequestVersion(1, 3, 9, fresh: true);
    await api.cachedTerminalJobTrace(1, 7, fresh: true);
    expect(await h.entry(_versionPath, 'application/json'), isNull);
    expect(await h.entry(_tracePath, 'text/plain'), isNull);
    final before = h.adapters.single.requests.length;
    await api.cachedMergeRequestVersion(1, 3, 9);
    expect(h.adapters.single.requests.length - before, 1);
  });

  test(
    'controls remain uninstalled and pinned API does not create a key',
    () async {
      final h = _Harness(controls: false);
      addTearDown(h.dispose);
      await h.recover();
      final api = await h.client(ready: false);
      expect(h.coordinator.controlsInstalled, isFalse);
      await api.cachedMergeRequestVersion(1, 3, 9);
      await api.cachedTerminalJobTrace(1, 7);
      await h.coordinator.quiesced;
      expect(
        h.storage.values.keys.where(
          (key) => key.startsWith(ReadCacheKeyStore.keyPrefix),
        ),
        isEmpty,
      );
      expect(h.root.listSync(recursive: true).whereType<File>(), isEmpty);
    },
  );

  test(
    'generic version reads and poll chunks do not persist typed pinned data',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final api = await h.client();
      await api.cachedRecord(_versionPath);
      await api.jobTraceChunk(1, 7);
      expect(await h.entry(_versionPath, 'application/json'), isNull);
      expect(await h.entry(_tracePath, 'text/plain'), isNull);
    },
  );

  test(
    'terminal metadata and Range honor a blocked caller send fence',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final api = await h.client();
      final meter = RequestMeter();
      final read = await meter.runAsync(
        () => CachedRead.run(
          () => api.cachedTerminalJobTrace(1, 7),
          mayStart: () => false,
        ),
      );
      expect(read.dropped, isTrue);
      expect(meter.count, 0);
      expect(await h.entry(_tracePath, 'text/plain'), isNull);
    },
  );

  for (final direct in [false, true]) {
    test(
      'post-Range proof rejects newer no-store erased job direct=$direct',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final entered = Completer<void>();
        final release = Completer<void>();
        h.traceResponse = (_) async {
          entered.complete();
          await release.future;
          return _suffix(h.trace);
        };
        final api = await h.client();
        final read = api.cachedTerminalJobTrace(1, 7);
        await entered.future.timeout(_deadline);
        h.metadataNoStore = true;
        h.metadata['erased_at'] = _initialNow.toIso8601String();
        if (direct) {
          await api.record(_jobPath);
        } else {
          await api.cachedRecord(_jobPath, fresh: true, allowDisk: false);
        }
        release.complete();
        await expectLater(read, throwsA(_failure(FailureKind.unsupported)));
        expect(await h.entry(_tracePath, 'text/plain'), isNull);
      },
    );
  }

  test(
    'a generic malformed version cannot bypass typed memory validation',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final api = await h.client();
      h.version['id'] = 8;
      await api.cachedRecord(_versionPath);
      h.version = _version();
      final before = h.adapters.single.requests.length;
      final read = await api.cachedMergeRequestVersion(1, 3, 9);
      expect(read.lineage, CacheLineage.network);
      expect(read.value['id'], 9);
      expect(h.adapters.single.requests.length - before, 1);
    },
  );

  test(
    'MR pinned memory cannot revive old nested issue after privacy transition',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final api = await h.client();
      h.version['issue'] = {
        'id': 22,
        'iid': 2,
        'project_id': 2,
        'title': 'old nested issue',
        'confidential': false,
      };
      await api.cachedMergeRequestVersion(1, 3, 9);
      await h.flush();
      h.now = h.now.add(const Duration(seconds: 1));
      h.extraResponse = (_) => jsonResponse({
        'id': 22,
        'iid': 2,
        'project_id': 2,
        'title': 'now private',
        'confidential': true,
      });
      await api.record(['projects', '2', 'issues', '2']);
      h.now = h.now.add(const Duration(seconds: 1));
      h.extraResponse = (_) => jsonResponse({
        'id': 22,
        'iid': 2,
        'project_id': 2,
        'title': 'public again',
        'confidential': false,
      });
      await api.record(['projects', '2', 'issues', '2']);
      h.version = _version();
      final before = h.adapters.single.requests.length;
      final read = await api.cachedMergeRequestVersion(1, 3, 9);
      expect(read.lineage, CacheLineage.network);
      expect(read.value.containsKey('issue'), isFalse);
      expect(h.adapters.single.requests.length - before, 1);
    },
  );

  test(
    'MR typed pending network requests coalesce with physical meter counts',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final api = await h.client();
      final one = RequestMeter();
      final two = RequestMeter();
      final reads = await Future.wait([
        one.runAsync(() => api.cachedMergeRequestVersion(1, 3, 9)),
        two.runAsync(() => api.cachedMergeRequestVersion(1, 3, 9)),
      ]);
      expect(reads.map((read) => read.value['id']), [9, 9]);
      expect(one.count + two.count, 1);
      expect(await h.entry(_versionPath, 'application/json'), isNotNull);
    },
  );

  for (final status in ['success', 'failed', 'canceled', 'skipped']) {
    test('terminal status $status has the exact terminal tail', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      h.metadata['status'] = status;
      final api = await h.client();
      final read = await api.cachedTerminalJobTrace(1, 7);
      expect(read.value.bytes, h.trace);
      expect(await h.entry(_tracePath, 'text/plain'), isNotNull);
    });
  }

  test(
    'terminal eligibility expires at thirty seconds and all rereads are counted',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final api = await h.client();
      final meter = RequestMeter();
      await meter.runAsync(() => api.cachedTerminalJobTrace(1, 7));
      expect(meter.count, 3);
      h.now = h.now.add(const Duration(seconds: 29));
      expect(
        (await meter.runAsync(() => api.cachedTerminalJobTrace(1, 7))).lineage,
        CacheLineage.memory,
      );
      expect(meter.count, 3);
      h.now = h.now.add(const Duration(seconds: 1));
      expect(
        (await meter.runAsync(() => api.cachedTerminalJobTrace(1, 7))).lineage,
        CacheLineage.memory,
      );
      expect(meter.count, 4);
    },
  );

  test('ordinary mutation cannot revoke either pinned memory entry', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.recover();
    final api = await h.client();
    await api.cachedMergeRequestVersion(1, 3, 9);
    await api.cachedTerminalJobTrace(1, 7);
    await h.flush();
    h.extraResponse = (_) => jsonResponse({'id': 2});
    await api.writeRecord(
      'PUT',
      ['projects', '1', 'issues', '2'],
      {'title': 'ordinary'},
    );
    expect(
      (await api.cachedMergeRequestVersion(1, 3, 9)).lineage,
      CacheLineage.memory,
    );
    expect(
      (await api.cachedTerminalJobTrace(1, 7)).lineage,
      CacheLineage.memory,
    );
    expect(await h.entry(_versionPath, 'application/json'), isNotNull);
    expect(await h.entry(_tracePath, 'text/plain'), isNotNull);
  });
}
