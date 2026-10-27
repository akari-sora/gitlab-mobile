import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/read_cache_cipher.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_backend.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';

import 'support/fake_adapter.dart';

final _instance = GitLabInstance.parse('https://cache.example/subpath');
final _account = '${_instance.key}#7';
final _now = DateTime.utc(2026, 10, 27, 12);
final _cancelled = throwsA(
  isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.cancelled),
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
  final storage = _Storage();
  final root = Directory.systemTemp.createTempSync('c2d1-fix1-transport-');
  late final keys = ReadCacheKeyStore(storage);
  late final files = ReadCacheFileStore(
    root: () async => root,
    clock: () => _now,
  );
  late final coordinator = ReadCacheDiskCoordinator(
    keys: keys,
    files: files,
    settings: ReadCacheSettingsStore(storage),
    coordinationScope: Object(),
    controlsInstalled: true,
    clock: () => _now,
  );
  final binding = DiskBinding(accountKey: _account, generation: 1);
  GitLabApi? api;

  Future<GitLabApi> client(
    FakeAdapter adapter, {
    required FakeAdapter tokens,
    FakeAdapter? cdn,
    Future<void> Function(OAuthCredential)? rotated,
  }) async {
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
    expect(await coordinator.activate(binding), isTrue);
    return api =
        GitLabApi(
            instance: _instance,
            credential: const OAuthCredential(
              accessToken: 'synthetic-old',
              refreshToken: 'synthetic-refresh',
              clientId: 'synthetic-client',
            ),
            dio: Dio()..httpClientAdapter = adapter,
            cdnAdapter: cdn,
            oauth: OAuthTokenClient(
              instance: _instance,
              clientId: 'synthetic-client',
              dio: Dio()..httpClientAdapter = tokens,
            ),
            onOAuthRotated: rotated,
            readCacheClock: () => _now,
          )
          ..bindReadCache(_account, 1)
          ..attachReadCacheDiskBackend(
            CoordinatedReadCacheDiskBackend(
              coordinator: coordinator,
              binding: binding,
            ),
          );
  }

  Directory get accountDirectory => Directory(
    '${root.path}/read_cache/${ReadCacheCipher.accountDirectoryName(_account)}',
  );

  Future<void> seed(GitLabApi api) async {
    await api.cachedRecord(['projects', '1']);
    await coordinator.flush(binding);
    expect((await keys.readKey(_account)).isFound, isTrue);
    expect(accountDirectory.listSync().whereType<File>(), isNotEmpty);
  }

  Future<void> dispose() async {
    api?.close();
    await coordinator.quiesced;
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

const _cleared = DiskClearResult(
  keyGoneConfirmed: true,
  directoryGoneConfirmed: true,
  markerDurable: false,
  complete: true,
);

final class _Fence implements DiskInvalidationFence {
  _Fence(this.barrier);
  @override
  final Future<DiskClearResult> barrier;
  @override
  Future<void> get quiesced => barrier.then((_) {});
  @override
  bool isCurrent = true;
  @override
  void revoke() => isCurrent = false;
}

final class _PrivacyBarrier implements ReadCacheDiskBackend {
  final started = Completer<void>();
  final release = Completer<DiskClearResult>();
  @override
  DiskInvalidationFence invalidate(DiskInvalidation invalidation) {
    if (!started.isCompleted) started.complete();
    return _Fence(release.future);
  }

  @override
  Future<ProjectedDiskEntry?> lookup(DiskLookup lookup) async => null;
  @override
  void accept(DiskWriteCandidate candidate, ProjectedDiskEntry entry) {}
  @override
  void revoke(DiskBinding binding) {}
  @override
  Future<DiskClearResult> clear(
    DiskBinding binding,
    ReadCacheCleanupOperation operation,
  ) async => _cleared;
  @override
  void reportCleanup(ReadCacheCleanupState state) {}
}

void main() {
  for (final page in [false, true]) {
    test(
      'closed client cancels ${page ? '_page' : '_object'} privacy settle',
      () async {
        final backend = _PrivacyBarrier();
        final issue = <String, Object?>{
          'id': 103,
          'project_id': 9,
          'iid': 3,
          'confidential': true,
        };
        final adapter = FakeAdapter(
          (_) => jsonResponse(page ? [issue] : issue),
        );
        final api =
            GitLabApi(
                instance: _instance,
                token: 'synthetic-test-token',
                dio: Dio()..httpClientAdapter = adapter,
              )
              ..bindReadCache(_account, 1)
              ..attachReadCacheDiskBackend(backend);
        addTearDown(api.close);
        final operation = page
            ? api.records(['projects', '9', 'issues'])
            : api.record(['projects', '9', 'issues', '3']);
        await backend.started.future;
        api.close();
        backend.release.complete(_cleared);
        await expectLater(operation, _cancelled);
        expect(adapter.requests, hasLength(1));
      },
    );
  }

  for (final route in ['currentUser', 'raw', 'artifact', 'upload']) {
    for (final throwsOnPersist in [false, true]) {
      test(
        'OAuth ${throwsOnPersist ? 'refresh throws' : 'refresh rejected'} clears $route disk before return',
        () async {
          final h = _Harness();
          addTearDown(h.dispose);
          final adapter = FakeAdapter(
            (request) => jsonResponse(
              request.uri.path.endsWith('/projects/1') ? projectJson(1) : {},
              status: request.uri.path.endsWith('/projects/1') ? 200 : 401,
            ),
          );
          final tokens = FakeAdapter(
            (_) => throwsOnPersist
                ? jsonResponse({
                    'access_token': 'synthetic-new',
                    'refresh_token': 'synthetic-new-refresh',
                    'token_type': 'bearer',
                  })
                : jsonResponse({'error': 'invalid_grant'}, status: 400),
          );
          final persistError = StateError(
            'synthetic credential persistence failure',
          );
          final api = await h.client(
            adapter,
            tokens: tokens,
            rotated: throwsOnPersist ? (_) async => throw persistError : null,
          );
          await h.seed(api);
          final sink = route == 'artifact' || route == 'upload'
              ? File('${h.root.path}/download.tmp').openWrite()
              : null;
          try {
            final operation = switch (route) {
              'raw' => api.rawFileBytes('1', 'main', 'a.txt'),
              'artifact' => api.downloadJobArtifacts(1, 9, sink: sink!),
              'upload' => api.downloadProjectUpload(
                1,
                'a' * 32,
                'test.txt',
                sink: sink!,
              ),
              _ => api.currentUser(),
            };
            await expectLater(
              operation,
              throwsA(
                throwsOnPersist
                    ? same(persistError)
                    : isA<ApiFailure>().having(
                        (e) => e.kind,
                        'kind',
                        FailureKind.unauthenticated,
                      ),
              ),
            );
            expect(tokens.requests, hasLength(1));
            expect(
              adapter.requests,
              hasLength(2),
              reason: 'no failed write/read replay',
            );
            expect((await h.keys.readKey(_account)).isFound, isFalse);
            expect(h.accountDirectory.existsSync(), isFalse);
          } finally {
            await sink?.close();
          }
        },
      );
    }
  }

  test(
    'unauthenticated same-instance artifact 401 preserves OAuth disk snapshot',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final destination = _instance.api([
        'projects',
        '1',
        'jobs',
        '9',
        'artifacts',
      ]);
      final adapter = FakeAdapter(
        (request) => request.uri.path.endsWith('/projects/1')
            ? jsonResponse(projectJson(1))
            : jsonResponse(
                {},
                status: 302,
                headers: {
                  'location': ['$destination'],
                },
              ),
      );
      final cdn = FakeAdapter((request) {
        expect(request.uri, destination);
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains(anyOf('authorization', 'private-token', 'cookie'))),
        );
        return jsonResponse({}, status: 401);
      });
      final tokens = FakeAdapter(
        (_) => fail('unauthenticated hop cannot refresh account'),
      );
      final api = await h.client(adapter, tokens: tokens, cdn: cdn);
      await h.seed(api);
      final key = (await h.keys.readKey(_account)).value!;
      final before = {
        for (final file in h.accountDirectory.listSync().whereType<File>())
          file.path: file.readAsBytesSync(),
      };
      final sink = File('${h.root.path}/redirect.tmp').openWrite();
      try {
        await expectLater(
          api.downloadJobArtifacts(1, 9, sink: sink),
          throwsA(
            isA<ApiFailure>().having(
              (e) => e.kind,
              'kind',
              FailureKind.unauthenticated,
            ),
          ),
        );
        await h.coordinator.quiesced;
        expect(cdn.requests, hasLength(1));
        expect(tokens.requests, isEmpty);
        expect((await h.keys.readKey(_account)).value, key);
        expect(h.accountDirectory.existsSync(), isTrue);
        expect({
          for (final file in h.accountDirectory.listSync().whereType<File>())
            file.path: file.readAsBytesSync(),
        }, before);
      } finally {
        await sink.close();
      }
    },
  );
}
