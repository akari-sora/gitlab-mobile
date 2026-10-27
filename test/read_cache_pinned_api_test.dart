import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/read_cache_cipher.dart';
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

final class _Lease implements DiskCommitLease {
  @override
  bool isCurrent = true;
  @override
  void revoke() => isCurrent = false;
}

final class _HeldFence implements DiskInvalidationFence {
  _HeldFence(this.delegate, Future<void> release)
    : barrier = delegate.barrier.then((result) async {
        await release;
        return result;
      });
  final DiskInvalidationFence delegate;
  @override
  final Future<DiskClearResult> barrier;
  @override
  bool get isCurrent => delegate.isCurrent;
  @override
  Future<void> get quiesced => delegate.quiesced;
  @override
  void revoke() => delegate.revoke();
}

/// Retains an already decrypted entry across a same-client erase observation.
final class _TraceBackend implements ReadCacheDiskBackend {
  _TraceBackend(this.delegate);
  final ReadCacheDiskBackend delegate;
  final entered = Completer<void>();
  final release = Completer<void>();
  final invalidating = Completer<void>();
  bool holdLookup = false;
  bool failDeletion = false;
  bool holdDeletion = false;
  final deletionEntered = Completer<void>();
  final deletionRelease = Completer<void>();
  final accountRevoked = Completer<void>();
  final projectRevoked = Completer<void>();
  void Function()? onTraceInvalidation;
  DiskCommitLease? writer;
  final notices = <ReadCacheCleanupState>[];

  @override
  Future<ProjectedDiskEntry?> lookup(DiskLookup request) async {
    final entry = await delegate.lookup(request);
    if (holdLookup &&
        request.bodyKind == ReadCacheBodyKind.terminalLog &&
        entry != null) {
      holdLookup = false;
      entered.complete();
      await release.future.timeout(_deadline);
    }
    return entry;
  }

  @override
  void accept(DiskWriteCandidate candidate, ProjectedDiskEntry entry) {
    if (candidate.bodyKind == ReadCacheBodyKind.terminalLog) {
      writer = candidate.lease;
    }
    delegate.accept(candidate, entry);
  }

  @override
  DiskInvalidationFence invalidate(DiskInvalidation invalidation) {
    if (failDeletion && invalidation.canonicalKey?.contains('/trace') == true) {
      throw const ReadCacheFileException(ReadCacheFileFailure.io);
    }
    final fence = delegate.invalidate(invalidation);
    if (invalidation.canonicalKey?.contains('/trace') == true) {
      onTraceInvalidation?.call();
    }
    if (invalidation.kind == DiskInvalidationKind.account &&
        !accountRevoked.isCompleted) {
      accountRevoked.complete();
    }
    if (invalidation.kind == DiskInvalidationKind.permission &&
        invalidation.path?.path == _instance.api(['projects', '1']).path &&
        !projectRevoked.isCompleted) {
      projectRevoked.complete();
    }
    if (invalidation.canonicalKey?.contains('/trace') == true &&
        !invalidating.isCompleted) {
      invalidating.complete();
    }
    if (holdDeletion && invalidation.canonicalKey?.contains('/trace') == true) {
      if (!deletionEntered.isCompleted) deletionEntered.complete();
      return _HeldFence(fence, deletionRelease.future);
    }
    return fence;
  }

  @override
  void revoke(DiskBinding binding) => delegate.revoke(binding);
  @override
  Future<DiskClearResult> clear(
    DiskBinding binding,
    ReadCacheCleanupOperation operation,
  ) => delegate.clear(binding, operation);
  @override
  void reportCleanup(ReadCacheCleanupState state) {
    notices.add(state);
    delegate.reportCleanup(state);
  }
}

void Function(ReadCacheFileCheckpoint) _holdWriter(
  ReadCacheFileCheckpoint boundary,
  SendPort entered,
  String release,
) => (step) {
  if (step != boundary) return;
  entered.send(step.name);
  final deadline = DateTime.now().add(_deadline);
  while (!File(release).existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('synthetic writer hold expired');
    }
    sleep(const Duration(milliseconds: 1));
  }
};

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
  Responder? metadataResponse;
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

  Future<GitLabApi> client({
    bool ready = true,
    ReadCacheDiskBackend Function(ReadCacheDiskBackend)? wrapBackend,
  }) async {
    await flush();
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/jobs/7/trace') && traceResponse != null) {
        return traceResponse!(request);
      }
      if (request.uri.path.endsWith('/jobs/7') && metadataResponse != null) {
        return metadataResponse!(request);
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
    final backend = CoordinatedReadCacheDiskBackend(
      coordinator: coordinator,
      binding: binding,
    );
    api.attachReadCacheDiskBackend(wrapBackend?.call(backend) ?? backend);
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

Future<void> _expectStored(
  _Harness h,
  List<String> path, {
  required bool present,
}) async {
  await h.flush();
  final key = (await h.keys.readKey(_account)).value!;
  final canonical = readCacheDurableKey(
    binding: DiskBinding(accountKey: _account, generation: 999),
    instance: _instance,
    uri: _instance.api(path),
    logicalAccept: 'text/plain',
  )!;
  final name = await const ReadCacheCipher().entryFileName(key, canonical);
  final file = File(
    '${h.root.path}/read_cache/'
    '${ReadCacheCipher.accountDirectoryName(_account)}/$name',
  );
  expect(file.existsSync(), present, reason: 'committed encrypted trace file');
  final index = await h.files.readIndex(_account, key);
  expect(
    index!.entries.any((entry) => entry.fileName == name),
    present,
    reason: 'encrypted trace index row',
  );
}

Future<void> _seedOtherTrace(_Harness h, GitLabApi api) async {
  h.extraResponse = (request) {
    if (request.uri.path.endsWith('/jobs/8/trace')) return _suffix(h.trace);
    if (request.uri.path.endsWith('/jobs/8')) {
      return jsonResponse({..._job(), 'id': 8});
    }
    return jsonResponse({}, status: 404);
  };
  await api.cachedTerminalJobTrace(1, 8);
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

  for (final postRange in [false, true]) {
    test(
      'erase retires committed trace at ${postRange ? 'post-Range' : 'initial'} check',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final api = await h.client();
        await api.cachedTerminalJobTrace(1, 7);
        await _seedOtherTrace(h, api);
        await _expectStored(h, _tracePath, present: true);
        final erasedAt = _initialNow.toIso8601String();
        if (postRange) {
          h.traceResponse = (_) {
            h.metadata['erased_at'] = erasedAt;
            return _suffix(h.trace);
          };
        } else {
          h.metadata['erased_at'] = erasedAt;
        }
        await expectLater(
          api.cachedTerminalJobTrace(1, 7, fresh: true),
          throwsA(_failure(FailureKind.unsupported)),
        );
        await _expectStored(h, _tracePath, present: false);
        await _expectStored(h, [
          'projects',
          '1',
          'jobs',
          '8',
          'trace',
        ], present: true);
        expect(
          (await api.cachedTerminalJobTrace(1, 8)).lineage,
          CacheLineage.memory,
        );

        // Fresh legal proof cannot make the retired in-memory bytes reusable.
        h.traceResponse = null;
        h.metadata = _job();
        h.trace = utf8.encode('new network trace after retirement\n');
        await api.cachedRecord(_jobPath, fresh: true, allowDisk: false);
        final read = await api.cachedTerminalJobTrace(1, 7);
        expect(read.lineage, CacheLineage.network);
        expect(read.value.bytes, h.trace);
      },
    );
  }

  for (final direct in [false, true]) {
    for (final noStore in [false, true]) {
      test(
        'erase fences held disk hydration direct=$direct no-store=$noStore',
        () async {
          final h = _Harness();
          addTearDown(h.dispose);
          await h.recover();
          final first = await h.client();
          await first.cachedTerminalJobTrace(1, 7);
          await _seedOtherTrace(h, first);
          await _expectStored(h, _tracePath, present: true);
          late _TraceBackend backend;
          final api = await h.client(
            wrapBackend: (delegate) =>
                backend = _TraceBackend(delegate)..holdLookup = true,
          );
          addTearDown(() {
            if (!backend.release.isCompleted) backend.release.complete();
          });
          final read = api.cachedTerminalJobTrace(1, 7);
          final rejected = expectLater(
            read,
            throwsA(_failure(FailureKind.unsupported)),
          );
          await backend.entered.future.timeout(_deadline);
          h.metadata['erased_at'] = _initialNow.toIso8601String();
          h.metadataNoStore = noStore;
          if (direct) {
            await api.record(_jobPath);
          } else {
            await api.cachedRecord(_jobPath, fresh: true, allowDisk: false);
          }
          backend.release.complete();
          await rejected;
          await _expectStored(h, _tracePath, present: false);
          await _expectStored(h, [
            'projects',
            '1',
            'jobs',
            '8',
            'trace',
          ], present: true);
          h.metadata = _job();
          h.metadataNoStore = false;
          h.trace = utf8.encode('network after cancelled hydration\n');
          await api.cachedRecord(_jobPath, fresh: true, allowDisk: false);
          final next = await api.cachedTerminalJobTrace(1, 7);
          expect(next.lineage, CacheLineage.network);
          expect(next.value.bytes, h.trace);
        },
      );
    }
  }

  test(
    'erased legacy job metadata on disk retires its committed trace',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final first = await h.client();
      await first.cachedTerminalJobTrace(1, 7);
      await _seedOtherTrace(h, first);
      await h.flush();
      final binding = DiskBinding(accountKey: _account, generation: 1);
      const versions = {'global': 0, 'project:1': 0};
      final candidate = DiskWriteCandidate(
        binding: binding,
        uri: _instance.api(_jobPath),
        logicalAccept: 'application/json',
        bodyKind: ReadCacheBodyKind.json,
        fetchedAt: h.now,
        responseBytes: 512,
        lease: _Lease(),
        cacheable: true,
        noStore: false,
        firstPage: true,
        scopeVersions: versions,
      );
      final legacy = projectReadCacheResponse(
        candidate,
        {..._job(), 'erased_at': _initialNow.toIso8601String()},
        ReadCacheProjectionContext(
          instance: _instance,
          binding: binding,
          now: h.now,
          scopeVersions: versions,
        ),
      );
      expect(legacy, isNotNull);
      h.coordinator.accept(candidate, legacy!);
      await h.flush();
      final api = await h.client();
      final meter = RequestMeter();
      final read = await meter.runAsync(() => api.cachedRecord(_jobPath));
      expect(read.lineage, CacheLineage.disk);
      expect(read.value['erased_at'], isNotNull);
      expect(meter.count, 0);
      await _expectStored(h, _tracePath, present: false);
      await _expectStored(h, [
        'projects',
        '1',
        'jobs',
        '8',
        'trace',
      ], present: true);
    },
  );

  test('erased query metadata in memory retires a later trace', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.recover();
    final api = await h.client();
    h.metadata['erased_at'] = _initialNow.toIso8601String();
    const query = {'include_retried': 'true'};
    await api.cachedRecord(_jobPath, query: query, allowDisk: false);
    h.metadata = _job();
    await api.cachedTerminalJobTrace(1, 7, fresh: true);
    await _expectStored(h, _tracePath, present: true);
    final meter = RequestMeter();
    final read = await meter.runAsync(
      () => api.cachedRecord(_jobPath, query: query, allowDisk: false),
    );
    expect(read.lineage, CacheLineage.memory);
    expect(read.value['erased_at'], isNotNull);
    expect(meter.count, 0);
    await _expectStored(h, _tracePath, present: false);
  });

  test(
    'cached erase cleanup cannot return metadata after account revocation',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      late _TraceBackend backend;
      final api = await h.client(
        wrapBackend: (delegate) => backend = _TraceBackend(delegate),
      );
      addTearDown(() {
        if (!backend.deletionRelease.isCompleted) {
          backend.deletionRelease.complete();
        }
      });
      const query = {'include_retried': 'true'};
      h.metadata['erased_at'] = _initialNow.toIso8601String();
      await api.cachedRecord(_jobPath, query: query, allowDisk: false);
      backend.holdDeletion = true;
      final read = api.cachedRecord(_jobPath, query: query, allowDisk: false);
      final rejected = expectLater(
        read,
        throwsA(_failure(FailureKind.cancelled)),
      );
      await backend.deletionEntered.future.timeout(_deadline);
      h.extraResponse = (_) => jsonResponse({}, status: 401);
      final revoked = expectLater(
        api.record(['projects', '1']),
        throwsA(_failure(FailureKind.unauthenticated, status: 401)),
      );
      await backend.accountRevoked.future.timeout(_deadline);
      backend.deletionRelease.complete();
      await rejected;
      await revoked;
    },
  );

  test(
    'FIX2 retirement survives a superseded initial metadata ticket',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      late _TraceBackend backend;
      final api = await h.client(
        wrapBackend: (delegate) => backend = _TraceBackend(delegate),
      );
      addTearDown(() {
        if (!backend.deletionRelease.isCompleted) {
          backend.deletionRelease.complete();
        }
      });
      await api.cachedTerminalJobTrace(1, 7);
      await _seedOtherTrace(h, api);
      await h.flush();
      h.trace = utf8.encode('queued trace must not outlive erase\n');
      await api.cachedTerminalJobTrace(1, 7, fresh: true);
      final writer = backend.writer!;
      expect(writer.isCurrent, isTrue);

      final otherResponse = h.extraResponse!;
      h.extraResponse = (request) => request.uri.path.endsWith('/jobs/9')
          ? jsonResponse({
              ..._job(),
              'id': 9,
              'erased_at': _initialNow.toIso8601String(),
            })
          : otherResponse(request);
      backend.holdDeletion = true;
      final unrelated = api.record(['projects', '1', 'jobs', '9']);
      await backend.deletionEntered.future.timeout(_deadline);

      final initialResponse = Completer<void>();
      h.metadataResponse = (_) {
        initialResponse.complete();
        return jsonResponse({
          ..._job(),
          'erased_at': _initialNow.toIso8601String(),
        });
      };
      final typed = api
          .cachedTerminalJobTrace(1, 7, fresh: true)
          .then<Object>((read) => read, onError: (Object error) => error);
      await initialResponse.future.timeout(_deadline);
      // Drain the fake transport's microtasks up to the held cleanup await.
      await Future<void>.delayed(Duration.zero);
      final newerResponse = Completer<void>();
      h.metadataResponse = (_) {
        newerResponse.complete();
        return jsonResponse(_job());
      };
      final newer = api.cachedRecord(_jobPath, fresh: true, allowDisk: false);
      await newerResponse.future.timeout(_deadline);
      await Future<void>.delayed(Duration.zero);
      backend.deletionRelease.complete();
      await unrelated;
      await newer;
      expect(await typed, _failure(FailureKind.unsupported));

      await _expectStored(h, _tracePath, present: false);
      expect(writer.isCurrent, isFalse, reason: 'late writer must be retired');
      await _expectStored(h, [
        'projects',
        '1',
        'jobs',
        '8',
        'trace',
      ], present: true);
      expect(
        (await api.cachedTerminalJobTrace(1, 8)).lineage,
        CacheLineage.memory,
      );
      h.metadataResponse = null;
      h.metadata = _job();
      h.trace = utf8.encode('network after superseded erase retirement\n');
      final next = await api.cachedTerminalJobTrace(1, 7);
      expect(next.lineage, CacheLineage.network);
      expect(next.value.bytes, h.trace);
    },
  );

  for (final global in [false, true]) {
    test(
      'FIX2 cached erase rechecks completed ${global ? 'global' : 'project'} write',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        late _TraceBackend backend;
        final api = await h.client(
          wrapBackend: (delegate) => backend = _TraceBackend(delegate),
        );
        addTearDown(() {
          if (!backend.deletionRelease.isCompleted) {
            backend.deletionRelease.complete();
          }
        });
        const query = {'include_retried': 'true'};
        h.metadata['erased_at'] = _initialNow.toIso8601String();
        h.metadata['name'] = 'before';
        await api.cachedRecord(_jobPath, query: query, allowDisk: false);
        backend.holdDeletion = true;
        final reading = api.cachedRecord(
          _jobPath,
          query: query,
          allowDisk: false,
        );
        await backend.deletionEntered.future.timeout(_deadline);
        h.extraResponse = (_) {
          h.metadata['name'] = 'after';
          return jsonResponse({});
        };
        await api.writeRecord(
          'PUT',
          global
              ? ['application', 'settings']
              : ['projects', '1', 'issues', '2'],
          {'title': 'synthetic FIX2 mutation'},
        );
        backend.deletionRelease.complete();
        final read = await reading;
        expect(read.lineage, CacheLineage.memory);
        expect(
          read.superseded || read.value['name'] == 'after',
          isTrue,
          reason: 'mutable cached value must revalidate after completed write',
        );
      },
    );
  }

  test('FIX2 cached erase rechecks a newer no-store publication', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.recover();
    late _TraceBackend backend;
    final api = await h.client(
      wrapBackend: (delegate) => backend = _TraceBackend(delegate),
    );
    addTearDown(() {
      if (!backend.deletionRelease.isCompleted) {
        backend.deletionRelease.complete();
      }
    });
    const query = {'include_retried': 'true'};
    h.metadata['erased_at'] = _initialNow.toIso8601String();
    h.metadata['name'] = 'before';
    await api.cachedRecord(_jobPath, query: query, allowDisk: false);
    backend.holdDeletion = true;
    final reading = api.cachedRecord(_jobPath, query: query, allowDisk: false);
    await backend.deletionEntered.future.timeout(_deadline);
    final responded = Completer<void>();
    h.metadataResponse = (_) {
      responded.complete();
      return jsonResponse(
        {...h.metadata, 'name': 'after'},
        headers: {
          'cache-control': ['no-store'],
        },
      );
    };
    final newer = api.cachedRecord(
      _jobPath,
      query: query,
      fresh: true,
      allowDisk: false,
    );
    await responded.future.timeout(_deadline);
    await Future<void>.delayed(Duration.zero);
    backend.deletionRelease.complete();
    expect((await newer).value['name'], 'after');
    expect((await reading).superseded, isTrue);
  });

  for (final delivery in [
    'generic network',
    'uncached network',
    'direct record',
  ]) {
    for (final status in [403, 404]) {
      test('FIX2 $delivery erase cancels after project $status', () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        late _TraceBackend backend;
        final api = await h.client(
          wrapBackend: (delegate) => backend = _TraceBackend(delegate),
        );
        addTearDown(() {
          if (!backend.deletionRelease.isCompleted) {
            backend.deletionRelease.complete();
          }
        });
        h.metadata['erased_at'] = _initialNow.toIso8601String();
        backend.holdDeletion = true;
        final Future<Object> reading =
            (delivery == 'direct record'
                    ? api.record(_jobPath)
                    : api.cachedRecord(
                        _jobPath,
                        query: delivery == 'uncached network'
                            ? {'page': '1'}
                            : const {},
                        fresh: true,
                        allowDisk: false,
                      ))
                .then<Object>(
                  (value) => value,
                  onError: (Object error) => error,
                );
        await backend.deletionEntered.future.timeout(_deadline);
        // Finish the fake response and suspend delivery on the cleanup barrier.
        await Future<void>.delayed(Duration.zero);
        expect(backend.projectRevoked.isCompleted, isFalse);
        h.extraResponse = (_) => jsonResponse({}, status: status);
        final denied = api
            .record(['projects', '1'])
            .then<Object>((value) => value, onError: (Object error) => error);
        await backend.projectRevoked.future.timeout(_deadline);
        backend.deletionRelease.complete();
        expect(
          await denied,
          _failure(
            status == 403 ? FailureKind.forbidden : FailureKind.invisible,
            status: status,
          ),
        );
        expect(
          await reading,
          _failure(FailureKind.cancelled),
          reason: 'revoked project must not deliver metadata after cleanup',
        );
      });
    }
  }

  for (final delivery in [
    'cached record',
    'uncached network',
    'direct record',
  ]) {
    for (final status in [403, 404]) {
      test('FIX3 alias $delivery erase cancels after project $status', () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        late _TraceBackend backend;
        final api = await h.client(
          wrapBackend: (delegate) => backend = _TraceBackend(delegate),
        );
        addTearDown(() {
          if (!backend.deletionRelease.isCompleted) {
            backend.deletionRelease.complete();
          }
        });
        await api.cachedTerminalJobTrace(1, 7);
        await h.flush();
        h.extraResponse = (_) =>
            jsonResponse({'id': 1, 'path_with_namespace': 'group/project'});
        expect((await api.record(['projects', 'group/project']))['id'], 1);
        expect(api.readCacheMetadataCounts['aliases'], greaterThan(0));
        const aliasJobPath = ['projects', 'group/project', 'jobs', '7'];
        h.metadata['erased_at'] = _initialNow.toIso8601String();
        backend.holdDeletion = true;
        final reading =
            (delivery == 'direct record'
                    ? api.record(aliasJobPath)
                    : api.cachedRecord(
                        aliasJobPath,
                        query: delivery == 'uncached network'
                            ? {'page': '1'}
                            : const {},
                        fresh: true,
                        allowDisk: false,
                      ))
                .then<Object>(
                  (value) => value,
                  onError: (Object error) => error,
                );
        await backend.deletionEntered.future.timeout(_deadline);
        // Suspend metadata delivery before the numeric denial removes aliases.
        await Future<void>.delayed(Duration.zero);
        expect(backend.projectRevoked.isCompleted, isFalse);
        h.extraResponse = (_) => jsonResponse({}, status: status);
        final denied = api
            .record(['projects', '1'])
            .then<Object>((value) => value, onError: (Object error) => error);
        await backend.projectRevoked.future.timeout(_deadline);
        await Future<void>.delayed(Duration.zero);
        expect(api.readCacheMetadataCounts['aliases'], 0);
        backend.deletionRelease.complete();
        expect(
          await denied,
          _failure(
            status == 403 ? FailureKind.forbidden : FailureKind.invisible,
            status: status,
          ),
        );
        expect(
          await reading,
          _failure(FailureKind.cancelled),
          reason:
              'numeric project denial must cancel delivery after alias removal',
        );
      });
    }
  }

  for (final status in [403, 404]) {
    test('FIX3 alias generic network cancels after project $status', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      late _TraceBackend backend;
      final api = await h.client(
        wrapBackend: (delegate) => backend = _TraceBackend(delegate),
      );
      addTearDown(() {
        if (!backend.deletionRelease.isCompleted) {
          backend.deletionRelease.complete();
        }
      });
      await api.cachedTerminalJobTrace(1, 7);
      await h.flush();
      h.extraResponse = (_) =>
          jsonResponse({'id': 1, 'path_with_namespace': 'group/project'});
      await api.record(['projects', 'group/project']);
      expect(api.readCacheMetadataCounts['aliases'], greaterThan(0));
      h.metadata['erased_at'] = _initialNow.toIso8601String();
      backend.holdDeletion = true;
      final erasing = api
          .record(_jobPath)
          .then<Object>((value) => value, onError: (Object error) => error);
      await backend.deletionEntered.future.timeout(_deadline);
      final responded = Completer<void>();
      h.extraResponse = (_) {
        responded.complete();
        // Project detail is cacheable; full-path job requests are not. The
        // generic JSON need not repeat the numeric ID from the learned alias.
        return jsonResponse({'path_with_namespace': 'group/project'});
      };
      final reading = api
          .cachedRecord(
            ['projects', 'group/project'],
            fresh: true,
            allowDisk: false,
          )
          .then<Object>((value) => value, onError: (Object error) => error);
      await responded.future.timeout(_deadline);
      await Future<void>.delayed(Duration.zero);
      expect(backend.projectRevoked.isCompleted, isFalse);
      h.extraResponse = (_) => jsonResponse({}, status: status);
      final denied = api
          .record(['projects', '1'])
          .then<Object>((value) => value, onError: (Object error) => error);
      await backend.projectRevoked.future.timeout(_deadline);
      await Future<void>.delayed(Duration.zero);
      expect(api.readCacheMetadataCounts['aliases'], 0);
      backend.deletionRelease.complete();
      expect(
        await denied,
        _failure(
          status == 403 ? FailureKind.forbidden : FailureKind.invisible,
          status: status,
        ),
      );
      expect(await erasing, _failure(FailureKind.cancelled));
      expect(
        await reading,
        _failure(FailureKind.cancelled),
        reason:
            'numeric project denial must cancel delivery after alias removal',
      );
    });
  }

  test(
    'FIX2 uncached erase keeps generation across load observation',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      late _TraceBackend backend;
      final api = await h.client(
        wrapBackend: (delegate) => backend = _TraceBackend(delegate),
      );
      var cleared = false;
      backend.onTraceInvalidation = () {
        cleared = true;
        api.clearReadCache();
      };
      h.metadata['erased_at'] = _initialNow.toIso8601String();
      await expectLater(
        api.cachedRecord(
          _jobPath,
          query: const {'page': '1'},
          allowDisk: false,
        ),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(cleared, isTrue);
    },
  );

  for (final topLevel in [false, true]) {
    test(
      'conflicting project identity cannot erase a trace top-level=$topLevel',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final api = await h.client();
        await api.cachedTerminalJobTrace(1, 7);
        await h.flush();
        h.metadata['erased_at'] = _initialNow.toIso8601String();
        if (topLevel) {
          h.metadata['project_id'] = 2;
        } else {
          h.metadata['pipeline'] = {'id': 6, 'project_id': 2, 'sha': _sha};
        }
        await api.record(_jobPath);
        await _expectStored(h, _tracePath, present: true);
        expect(
          (await api.cachedTerminalJobTrace(1, 7)).lineage,
          CacheLineage.memory,
        );
      },
    );
  }

  for (final boundary in [
    null,
    ReadCacheFileCheckpoint.beforeEntryRename,
    ReadCacheFileCheckpoint.beforeIndexRename,
  ]) {
    test(
      'erase revokes late writer at ${boundary?.name ?? 'queued'}',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        late _TraceBackend backend;
        final api = await h.client(
          wrapBackend: (delegate) => backend = _TraceBackend(delegate),
        );
        await api.cachedTerminalJobTrace(1, 7);
        await _seedOtherTrace(h, api);
        await _expectStored(h, _tracePath, present: true);

        final events = ReceivePort();
        addTearDown(events.close);
        final messages = StreamIterator<Object?>(events);
        final release = File('${h.root.path}/release-writer');
        addTearDown(() => release.createSync());
        if (boundary != null) {
          h.coordinator.configure(
            keys: h.keys,
            settings: ReadCacheSettingsStore(h.storage),
            files: ReadCacheFileStore(
              root: () async => h.root,
              clock: () => h.now,
              checkpoint: _holdWriter(boundary, events.sendPort, release.path),
            ),
          );
        }
        h.trace = utf8.encode('writer must not resurrect erased trace\n');
        await api.cachedTerminalJobTrace(1, 7, fresh: true);
        final lease = backend.writer!;
        expect(lease.isCurrent, isTrue);
        final writing = boundary == null ? null : h.flush();
        if (boundary != null) {
          expect(await messages.moveNext().timeout(_deadline), isTrue);
          expect(messages.current, boundary.name);
        }
        h.metadata['erased_at'] = _initialNow.toIso8601String();
        final observing = api.record(_jobPath);
        try {
          await Future.any([
            backend.invalidating.future,
            observing.then((_) {}),
          ]).timeout(_deadline);
          expect(
            lease.isCurrent,
            isFalse,
            reason: 'erase must revoke writer lease',
          );
        } finally {
          release.createSync();
          await observing;
          if (writing != null) await writing;
          await messages.cancel();
        }
        await _expectStored(h, _tracePath, present: false);
        await _expectStored(h, [
          'projects',
          '1',
          'jobs',
          '8',
          'trace',
        ], present: true);
      },
    );
  }

  test(
    'erase deletion failure reports cleanup without restoring trace memory',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      late _TraceBackend backend;
      final api = await h.client(
        wrapBackend: (delegate) => backend = _TraceBackend(delegate),
      );
      await api.cachedTerminalJobTrace(1, 7);
      await h.flush();
      backend.failDeletion = true;
      h.metadata['erased_at'] = _initialNow.toIso8601String();
      expect((await api.record(_jobPath))['erased_at'], isNotNull);
      expect(backend.notices, hasLength(1));
      expect(backend.notices.single.code, ReadCacheCleanupCode.cleanupFailed);
      expect(backend.notices.single.clearResult.complete, isFalse);
      expect(backend.writer!.isCurrent, isFalse);
      await expectLater(
        api.cachedTerminalJobTrace(1, 7),
        throwsA(_failure(FailureKind.unsupported)),
      );
      // Even if a later legal proof appears, failed deletion cannot resurrect
      // the retained ciphertext. The source fence forces a new network tail.
      h.metadata = _job();
      h.trace = utf8.encode('network after failed retirement\n');
      await api.cachedRecord(_jobPath, fresh: true, allowDisk: false);
      final next = await api.cachedTerminalJobTrace(1, 7);
      expect(next.lineage, CacheLineage.network);
      expect(next.value.bytes, h.trace);
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
