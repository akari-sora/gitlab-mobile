import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/core/read_cache_cipher.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';
import 'package:gitlab_mobile/core/request_meter.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';
import 'package:gitlab_mobile/features/offline/offline_gate.dart';
import 'package:gitlab_mobile/features/security/app_lock.dart';

import 'offline/coordinator_regression_test.dart' show completeRecord, jobId;
import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';

final class _Storage implements ReadCacheSecureStorage {
  final values = <String, String>{};
  bool failRefusalRead = false,
      failRefusalDelete = false,
      failRefusalWrite = false,
      failOfflineKeyRead = false;
  int refusalDeletes = 0;
  Completer<void>? holdRefusalDelete, refusalDeleteStarted;
  @override
  Future<String?> read(String key) async {
    if (failRefusalRead &&
            key.startsWith(ReadCacheKeyStore.offlineRefusalPrefix) ||
        failOfflineKeyRead &&
            key.startsWith(ReadCacheKeyStore.offlineKeyPrefix)) {
      throw StateError('synthetic unavailable');
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failRefusalWrite &&
        key.startsWith(ReadCacheKeyStore.offlineRefusalPrefix)) {
      throw StateError('synthetic refusal write failure');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (key.startsWith(ReadCacheKeyStore.offlineRefusalPrefix)) {
      refusalDeletes++;
      final hold = holdRefusalDelete;
      if (hold != null) {
        holdRefusalDelete = null;
        refusalDeleteStarted?.complete();
        await hold.future;
      }
      if (failRefusalDelete) {
        throw StateError('synthetic refusal delete failure');
      }
    }
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
}

final class _LockStore implements AppLockStore {
  bool fail = false;
  Completer<bool>? pending;
  @override
  Future<bool> read() async {
    if (fail) throw StateError('synthetic lock read failure');
    return await pending?.future ?? false;
  }

  @override
  Future<void> write(bool enabled) async {}
}

final class _Auth implements AppLockAuthenticator {
  @override
  Future<bool> authenticate(String reason) async => false;
  @override
  Future<bool> available() async => true;
}

final class _Harness {
  _Harness(
    this.responder, {
    AccountCredential? credential,
    this.oauthResponder,
  }) {
    keys = ReadCacheKeyStore(storage);
    files = ReadCacheFileStore(root: () async => root);
    cache = ReadCacheDiskCoordinator(
      keys: keys,
      files: files,
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
      controlsInstalled: true,
      clock: () => now,
    );
    lock = AppLockController(store: lockStore, authenticator: _Auth());
    account = Account(
      instance: GitLabInstance.parse('https://example.test'),
      user: const GitLabUser(id: 7, username: 'test', name: 'Test'),
      credential: credential ?? const PatCredential('synthetic'),
    );
    store.accounts = [account];
    store.lastActive = account.key;
  }
  final root = Directory.systemTemp.createTempSync('offline-session-');
  final storage = _Storage();
  final lockStore = _LockStore();
  final store = MemoryAccountStore();
  Responder responder;
  final Responder? oauthResponder;
  void Function(SessionController)? onIdentityClient;
  late final ReadCacheKeyStore keys;
  late final ReadCacheFileStore files;
  late final ReadCacheDiskCoordinator cache;
  late final AppLockController lock;
  late final Account account;
  final sessions = <SessionController>[];
  DateTime now = DateTime.utc(2026, 10, 28);

  Future<void> seed({
    DateTime? validatedAt,
    bool complete = true,
    bool tree = true,
  }) async {
    await keys.writeOfflineKey(account.key, Uint8List(32));
    final snapshotStore = SnapshotStore(
      supportRoot: root,
      accountKey: account.key,
      rootKey: Uint8List(32),
    );
    final record = completeRecord(1, jobId, now);
    if (complete) {
      await snapshotStore.writeTree(
        SnapshotTree(
          snapshotId: record.id,
          sha: record.sha,
          subPath: '',
          entries: [],
        ),
        format: record.objectFormat,
        complete: true,
        mayCommit: () => true,
      );
    }
    await snapshotStore.writeIndex(
      SnapshotIndex(
        accountKey: account.key,
        lastValidatedAt: validatedAt ?? now,
        consentAt: now,
        snapshots: complete ? [record] : [],
      ),
      expectedRevision: snapshotStore.revision,
      mayCommit: () => true,
    );
    if (complete && !tree) {
      snapshotStore.deleteTree(record.id, mayCommit: () => true);
    }
  }

  SessionController makeSession() {
    final adapter = FakeAdapter((request) => responder(request));
    late final SessionController session;
    session = SessionController(
      store,
      readCache: cache,
      appLock: lock,
      clock: () => now,
      createOAuth: (instance, clientId) => OAuthTokenClient(
        instance: instance,
        clientId: clientId,
        dio: Dio()
          ..httpClientAdapter = FakeAdapter(oauthResponder ?? responder),
      ),
      createApi: (instance, credential, oauth, onRotated) => GitLabApi(
        instance: instance,
        credential: credential,
        dio: Dio()..httpClientAdapter = adapter,
        oauth: oauth,
        onOAuthRotated: onRotated,
      ),
      createIdentityApi: (instance, credential, oauth, onRotated, budget) {
        onIdentityClient?.call(session);
        return GitLabApi(
          instance: instance,
          credential: credential,
          dio: Dio()..httpClientAdapter = adapter,
          oauth: oauth,
          onOAuthRotated: onRotated,
          rateBudget: budget,
        );
      },
    );
    final decisions = <Object>{};
    session.addListener(() {
      final decision = session.readCacheStartupDecision;
      if (decision != null && decisions.add(decision)) {
        unawaited(
          cache.recover(
            decision,
            accountKeys: session.accounts.map((a) => a.key).toSet(),
            sessionOwner: session,
          ),
        );
      }
    });
    sessions.add(session);
    return session;
  }

  Future<void> dispose() async {
    for (final session in sessions) {
      if (!session.isDisposed) session.dispose();
    }
    lock.dispose();
    await cache.quiesced;
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

ResponseBody _network(RequestOptions request) => throw DioException(
  requestOptions: request,
  type: DioExceptionType.connectionError,
);

Future<void> _eventually(bool Function() condition) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: 'condition did not become true');
}

Map<String, List<int>> _fileContents(Directory root) => {
  for (final entry in root.listSync(recursive: true, followLinks: false))
    if (entry is File) entry.path: entry.readAsBytesSync(),
};

Future<void> _seedReadCache(_Harness h) async {
  await h.keys.writeKey(h.account.key, Uint8List(32));
  await h.files.writeIndex(
    h.account.key,
    Uint8List(32),
    ReadCacheIndex(entries: []),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    offlineModeShellReadyForTesting = true;
    addTearDown(() {
      offlineModeShellReadyForTesting = null;
    });
  });

  test(
    'production shell flag blocks entry even with a readable snapshot',
    () async {
      final h = _Harness(_network);
      addTearDown(h.dispose);
      await h.seed();
      await h.lock.start();
      offlineModeShellReadyForTesting = null;
      final session = h.makeSession();
      await session.initialize();
      expect(session.offline, isNull);
    },
  );

  for (final kind in ['HTML 401', 'unrelated JSON 401']) {
    test(
      'production OAuth $kind preserves last-active, keys and files',
      () async {
        offlineModeShellReadyForTesting = null;
        expect(offlineModeShellReady, isFalse);
        expect(offlineModeEnabled, isFalse);
        var tokenRequests = 0;
        final h = _Harness(
          (_) => jsonResponse({'message': 'expired'}, status: 401),
          credential: const OAuthCredential(
            accessToken: 'old',
            refreshToken: 'old-refresh',
            clientId: 'id',
          ),
          oauthResponder: (request) {
            tokenRequests++;
            expect(request.uri.path, '/oauth/token');
            return kind == 'HTML 401'
                ? ResponseBody.fromString(
                    '<html>proxy</html>',
                    401,
                    headers: {
                      'content-type': ['text/html'],
                    },
                  )
                : jsonResponse({'error': 'invalid_client'}, status: 401);
          },
        );
        addTearDown(h.dispose);
        await h.seed();
        await _seedReadCache(h);
        final stored = Map.of(h.storage.values);
        final files = _fileContents(h.root);
        final session = h.makeSession();

        await session.initialize();
        await _eventually(() => h.cache.startupRecovered);
        await h.cache.quiesced;

        expect(tokenRequests, 1);
        expect(session.active, isNull);
        expect(session.offline, isNull);
        expect(h.store.lastActive, h.account.key);
        expect(h.storage.values, stored);
        expect(_fileContents(h.root), files);
        expect(h.cache.state(h.account.key), ReadCacheDiskState.closed);
        expect(await h.cache.readOfflineRefused(h.account.key), isFalse);
      },
    );
  }

  for (final markerPresent in [true, false]) {
    for (final failure in ['delete', 'readback']) {
      test(
        'production online resume survives refusal $failure failure; marker=$markerPresent',
        () async {
          offlineModeShellReadyForTesting = null;
          expect(offlineModeShellReady, isFalse);
          expect(offlineModeEnabled, isFalse);
          final h = _Harness(
            (_) => jsonResponse({'id': 7, 'username': 'test', 'name': 'Test'}),
          );
          addTearDown(h.dispose);
          await h.seed();
          await _seedReadCache(h);
          if (markerPresent) {
            await h.cache.writeOfflineRefused(h.account.key, h.now);
          }
          final files = _fileContents(h.root);
          final stored = Map.of(h.storage.values);
          h.storage.failRefusalDelete = failure == 'delete';
          h.storage.failRefusalRead = failure == 'readback';
          final session = h.makeSession();

          await session.initialize();
          await _eventually(() => h.cache.startupRecovered);
          await h.cache.quiesced;

          expect(session.active?.key, h.account.key);
          expect(session.api, isNotNull);
          expect(session.offline, isNull);
          expect(h.store.lastActive, h.account.key);
          expect(h.storage.refusalDeletes, 1);
          if (failure == 'readback') {
            stored.remove(ReadCacheKeyStore.offlineRefusalName(h.account.key));
          }
          expect(h.storage.values, stored);
          expect(_fileContents(h.root), files);

          // Even a recovered store reporting absence cannot reopen disk after
          // an unconfirmed delete; fresh online identity is already active.
          h.storage.failRefusalRead = false;
          h.storage.failRefusalDelete = false;
          expect(await h.cache.readOfflineRefused(h.account.key), isTrue);
          expect(h.cache.state(h.account.key), ReadCacheDiskState.unavailable);
          expect(
            (await h.cache.readOfflineEligibilityKey(h.account.key)).isFound,
            isFalse,
          );
          expect(
            await h.cache.activate(
              DiskBinding(
                accountKey: h.account.key,
                generation: session.generation,
              ),
            ),
            isFalse,
          );
          expect(_fileContents(h.root), files);

          await h.cache.deleteOfflineRefused(h.account.key);
          expect(await h.cache.readOfflineRefused(h.account.key), isFalse);
        },
      );
    }
  }

  test(
    'overlapping refusal deletes stay blocked through a failed readback',
    () async {
      final h = _Harness(_network);
      addTearDown(h.dispose);
      await h.seed();
      await h.lock.start();
      offlineModeShellReadyForTesting = null;
      final session = h.makeSession();
      await session.initialize();
      await _eventually(() => h.cache.startupRecovered);
      final files = _fileContents(h.root);

      final held = Completer<void>();
      final started = Completer<void>();
      h.storage.holdRefusalDelete = held;
      h.storage.refusalDeleteStarted = started;
      final pending = h.cache.deleteOfflineRefused(h.account.key);
      final failed = expectLater(
        pending,
        throwsA(isA<ReadCacheStoreException>()),
      );
      await started.future;

      // A second operation confirms absence while the first is still in flight.
      await h.cache.deleteOfflineRefused(h.account.key);
      expect(await h.cache.readOfflineRefused(h.account.key), isTrue);
      expect(
        (await h.cache.readOfflineEligibilityKey(h.account.key)).isFound,
        isFalse,
      );

      h.storage.failRefusalRead = true;
      held.complete();
      await failed;
      h.storage.failRefusalRead = false;
      expect(await h.cache.readOfflineRefused(h.account.key), isTrue);
      expect(
        (await h.cache.readOfflineEligibilityKey(h.account.key)).isFound,
        isFalse,
      );
      expect(_fileContents(h.root), files);

      await h.cache.deleteOfflineRefused(h.account.key);
      expect(await h.cache.readOfflineRefused(h.account.key), isFalse);
      expect(
        (await h.cache.readOfflineEligibilityKey(h.account.key)).isFound,
        isTrue,
      );
    },
  );

  for (final kind in [
    'network',
    'server',
    'rate',
    'redirect',
    'invalid',
    'cancelled',
    'validation',
    'non-api',
    'html401',
    'html403',
    'json401',
    'json403',
    'mismatch',
  ]) {
    test('identity matrix: $kind', () async {
      final h = _Harness(
        (request) => switch (kind) {
          'network' => _network(request),
          'server' => jsonResponse({'message': 'server'}, status: 503),
          'rate' => jsonResponse({'message': 'rate'}, status: 429),
          'redirect' => ResponseBody.fromString('', 302),
          'invalid' => ResponseBody.fromString(
            '<html>login</html>',
            200,
            headers: {
              'content-type': ['text/html'],
            },
          ),
          'cancelled' => throw DioException(
            requestOptions: request,
            type: DioExceptionType.cancel,
          ),
          'validation' => jsonResponse({'message': 'bad'}, status: 400),
          'non-api' => throw StateError('synthetic non-ApiFailure'),
          'html401' => ResponseBody.fromString(
            '<html>proxy</html>',
            401,
            headers: {
              'content-type': ['text/html'],
            },
          ),
          'html403' => ResponseBody.fromString(
            '<html>proxy</html>',
            403,
            headers: {
              'content-type': ['text/html'],
            },
          ),
          'json401' => jsonResponse({'message': 'denied'}, status: 401),
          'json403' => jsonResponse({'message': 'denied'}, status: 403),
          _ => jsonResponse({'id': 8, 'username': 'other'}),
        },
      );
      addTearDown(h.dispose);
      await h.seed();
      await h.lock.start();
      final session = h.makeSession();
      await session.initialize();
      expect(
        session.offline != null,
        ['network', 'server', 'rate', 'redirect', 'invalid'].contains(kind),
      );
      if (kind == 'json401' || kind == 'mismatch') {
        expect(h.store.lastActive, isNull);
      }
      if (kind == 'json403') {
        expect(await h.cache.readOfflineRefused(h.account.key), isTrue);
      }
      if (kind == 'html401' || kind == 'html403') {
        await h.cache.quiesced;
        expect(h.store.lastActive, h.account.key);
        expect(await h.cache.readOfflineRefused(h.account.key), isFalse);
        expect((await h.keys.readOfflineKey(h.account.key)).isFound, isTrue);
        final disk = SnapshotStore(
          supportRoot: h.root,
          accountKey: h.account.key,
          rootKey: Uint8List(32),
        );
        expect(await disk.readIndex(), isNotNull);
      }
    });
  }

  for (final condition in [
    'refusal',
    'unreadable-refusal',
    'no-snapshot',
    'missing-tree',
    'key-unavailable',
    'expired',
    'future',
    'lock-failed',
  ]) {
    test('eligibility matrix: $condition', () async {
      final h = _Harness(_network);
      addTearDown(h.dispose);
      await h.seed(
        complete: condition != 'no-snapshot',
        tree: condition != 'missing-tree',
        validatedAt: condition == 'expired'
            ? h.now.subtract(const Duration(days: 31))
            : condition == 'future'
            ? h.now.add(const Duration(minutes: 6))
            : h.now,
      );
      if (condition == 'refusal') {
        await h.cache.writeOfflineRefused(h.account.key, h.now);
      }
      h.storage.failRefusalRead = condition == 'unreadable-refusal';
      h.storage.failOfflineKeyRead = condition == 'key-unavailable';
      h.lockStore.fail = condition == 'lock-failed';
      await h.lock.start();
      final session = h.makeSession();
      await session.initialize();
      expect(session.offline, isNull);
      if (condition == 'lock-failed') expect(h.lock.offlineCovering, isTrue);
    });
  }

  test('unsupported identity admission does not enter offline', () async {
    final h = _Harness(_network);
    addTearDown(h.dispose);
    await h.seed();
    await h.lock.start();
    final session = h.makeSession();
    await RequestMeter(
      beforeRequest: () async {
        throw const ApiFailure(FailureKind.unsupported);
      },
    ).runAsync(session.initialize);
    expect(session.offline, isNull);
  });

  // Full cross product: identity outcomes must not bypass eligibility.
  for (final kind in [
    'network',
    'server',
    'rate',
    'redirect',
    'invalid',
    'unsupported',
    'cancelled',
    'validation',
    'non-api',
    'html401',
    'html403',
    'json401',
    'json403',
    'mismatch',
  ]) {
    for (final condition in [
      'eligible',
      'refusal',
      'unreadable-refusal',
      'no-snapshot',
      'missing-tree',
      'key-unavailable',
      'expired',
      'future',
      'lock-failed',
      'tampered-index',
      'newer-index',
    ]) {
      test('entry cross product: $kind / $condition', () async {
        final h = _Harness(
          (request) => switch (kind) {
            'network' => _network(request),
            'server' => jsonResponse({'message': 'server'}, status: 503),
            'rate' => jsonResponse({'message': 'rate'}, status: 429),
            'redirect' => ResponseBody.fromString('', 302),
            'invalid' => ResponseBody.fromString(
              '<html>login</html>',
              200,
              headers: {
                'content-type': ['text/html'],
              },
            ),
            'unsupported' => throw const ApiFailure(FailureKind.unsupported),
            'cancelled' => throw DioException(
              requestOptions: request,
              type: DioExceptionType.cancel,
            ),
            'validation' => jsonResponse({'message': 'bad'}, status: 400),
            'non-api' => throw StateError('synthetic unknown'),
            'html401' => ResponseBody.fromString(
              '<html>proxy</html>',
              401,
              headers: {
                'content-type': ['text/html'],
              },
            ),
            'html403' => ResponseBody.fromString(
              '<html>proxy</html>',
              403,
              headers: {
                'content-type': ['text/html'],
              },
            ),
            'json401' => jsonResponse({'message': 'denied'}, status: 401),
            'json403' => jsonResponse({'message': 'denied'}, status: 403),
            _ => jsonResponse({'id': 8, 'username': 'other'}),
          },
        );
        addTearDown(h.dispose);
        await h.seed(
          complete: condition != 'no-snapshot',
          tree: condition != 'missing-tree',
          validatedAt: condition == 'expired'
              ? h.now.subtract(const Duration(days: 31))
              : condition == 'future'
              ? h.now.add(const Duration(minutes: 6))
              : h.now,
        );
        if (condition == 'refusal') {
          await h.cache.writeOfflineRefused(h.account.key, h.now);
        }
        h.storage.failRefusalRead = condition == 'unreadable-refusal';
        h.storage.failOfflineKeyRead = condition == 'key-unavailable';
        h.lockStore.fail = condition == 'lock-failed';
        if (condition == 'tampered-index' || condition == 'newer-index') {
          final disk = SnapshotStore(
            supportRoot: h.root,
            accountKey: h.account.key,
            rootKey: Uint8List(32),
          );
          final file = File('${disk.accountDirectory}/index.v1.bin');
          final bytes = file.readAsBytesSync();
          if (condition == 'newer-index') {
            bytes[0] = 2;
          } else {
            bytes[bytes.length - 1] ^= 1;
          }
          file.writeAsBytesSync(bytes);
        }
        await h.lock.start();
        final session = h.makeSession();
        await session.initialize();
        final noVerdict = [
          'network',
          'server',
          'rate',
          'redirect',
          'invalid',
        ].contains(kind);
        expect(session.offline != null, noVerdict && condition == 'eligible');
      });
    }
  }

  test('entering offline advances generation', () async {
    final h = _Harness(_network);
    addTearDown(h.dispose);
    await h.seed();
    await h.lock.start();
    final session = h.makeSession();
    final before = session.generation;
    await session.initialize();
    expect(session.offline, isNotNull);
    expect(session.generation, greaterThan(before));
    expect(session.offline!.generation, session.generation);
    expect(session.api, isNull);
    expect(session.diskRetainedAccountKey, h.account.key);
  });

  for (final refusal in ['present', 'unreadable']) {
    test('offline admission rechecks a $refusal refusal marker', () async {
      final response = Completer<ResponseBody>();
      final h = _Harness((_) => response.future);
      addTearDown(h.dispose);
      await h.seed();
      await h.lock.start();
      final session = h.makeSession();
      final initialize = session.initialize();
      await _eventually(() => session.canEnterOffline);
      final generation = session.generation;
      if (refusal == 'present') {
        await h.cache.writeOfflineRefused(h.account.key, h.now);
      } else {
        h.storage.failRefusalRead = true;
      }
      expect(await session.enterOffline(), isFalse);
      expect(session.generation, generation);
      response.complete(jsonResponse({'message': 'down'}, status: 503));
      await initialize;
      expect(session.offline, isNull);
      expect((await h.keys.readOfflineKey(h.account.key)).isFound, isTrue);
      expect(h.store.lastActive, h.account.key);
    });
  }

  test(
    '403 persists across restart and same-account retry until matching ok',
    () async {
      final h = _Harness(
        (_) => jsonResponse({'message': 'denied'}, status: 403),
      );
      addTearDown(h.dispose);
      await h.seed();
      await h.lock.start();
      final first = h.makeSession();
      await first.initialize();
      expect(await h.cache.readOfflineRefused(h.account.key), isTrue);
      first.dispose();
      h.responder = _network;
      final second = h.makeSession();
      await second.initialize();
      expect(second.offline, isNull);
      h.responder = (_) => jsonResponse({'message': 'denied'}, status: 403);
      await second.select(h.account);
      expect(await h.cache.readOfflineRefused(h.account.key), isTrue);
      h.responder = (_) => jsonResponse({'id': 7, 'username': 'test'});
      await second.select(h.account);
      expect(second.active?.key, h.account.key);
      expect(await h.cache.readOfflineRefused(h.account.key), isFalse);
    },
  );

  test('403 marker write failure clears account data', () async {
    final h = _Harness((_) => jsonResponse({'message': 'denied'}, status: 403));
    addTearDown(h.dispose);
    await h.seed();
    await h.lock.start();
    h.storage.failRefusalWrite = true;
    final session = h.makeSession();
    await session.initialize();
    await h.cache.quiesced;
    expect((await h.keys.readOfflineKey(h.account.key)).isFound, isFalse);
    expect(h.store.lastActive, isNull);
  });

  for (final result in ['ok', '401', '403']) {
    test('early entry handles background $result', () async {
      final response = Completer<ResponseBody>();
      final h = _Harness((_) => response.future);
      addTearDown(h.dispose);
      await h.seed();
      await h.lock.start();
      final session = h.makeSession();
      final initialize = session.initialize();
      await _eventually(() => session.canEnterOffline);
      expect(await session.enterOffline(), isTrue);
      expect(session.offline, isNotNull);
      response.complete(
        result == 'ok'
            ? jsonResponse({'id': 7, 'username': 'test'})
            : jsonResponse({'message': 'denied'}, status: int.parse(result)),
      );
      await initialize;
      if (result == 'ok') {
        expect(session.offline?.connectionRestored, isTrue);
        expect(session.api, isNull);
      } else {
        expect(session.offline, isNull);
        if (result == '403') {
          expect(await h.cache.readOfflineRefused(h.account.key), isTrue);
        }
        if (result == '401') {
          await h.cache.quiesced;
          expect((await h.keys.readOfflineKey(h.account.key)).isFound, isFalse);
        }
      }
    });
  }

  for (final result in ['ok', '401', '403', 'mismatch', 'unknown']) {
    test('late early-entry A $result is dropped after switching to B', () async {
      final response = Completer<IdentityVerdict>();
      final h = _Harness(_network);
      addTearDown(h.dispose);
      await h.seed();
      await h.lock.start();
      // Join a held verdict so transport cancellation cannot hide a stale reply.
      h.onIdentityClient = (session) {
        unawaited(session.offlineGate.probe(() => response.future));
      };
      final session = h.makeSession();
      final initialize = session.initialize();
      await _eventually(() => session.canEnterOffline);
      expect(await session.enterOffline(), isTrue);
      await session.endSession();
      h.responder = (_) => jsonResponse({'id': 8, 'username': 'other'});
      await session.connect('https://example.test', 'new');
      expect(session.active?.user.id, 8);
      await h.cache.quiesced;
      final marker = ReadCacheKeyStore.offlineRefusalName(h.account.key);
      await h.cache.writeOfflineRefused(h.account.key, h.now);
      final retainedMarker = h.storage.values[marker];
      final generation = session.generation;
      final api = session.api;
      final message = session.message;
      response.complete(switch (result) {
        'ok' => IdentityOk(h.account.user),
        '401' => const IdentityRefused401(),
        '403' => const IdentityRefused403(),
        'mismatch' => const IdentityOk(
          GitLabUser(id: 9, username: 'wrong', name: 'Wrong'),
        ),
        _ => const IdentityUnknown(ApiFailure(FailureKind.cancelled)),
      });
      await initialize;
      expect(session.active?.user.id, 8);
      expect(session.api, same(api));
      expect(session.generation, generation);
      expect(session.message, message);
      expect(h.store.lastActive, session.active!.key);
      expect(h.storage.values[marker], retainedMarker);
    });
  }

  test('late offline probe is dropped after switching to B', () async {
    final h = _Harness(_network);
    addTearDown(h.dispose);
    await h.seed();
    await h.lock.start();
    final session = h.makeSession();
    await session.initialize();
    expect(session.offline, isNotNull);
    final started = Completer<void>();
    final release = Completer<void>();
    final probe = RequestMeter(
      beforeRequest: () async {
        started.complete();
        await release.future;
      },
    ).runAsync(() => session.probeOffline(manual: false));
    await started.future;
    await session.endSession();
    h.responder = (_) => jsonResponse({'id': 8, 'username': 'other'});
    await session.connect('https://example.test', 'new');
    expect(session.active?.user.id, 8);
    await h.cache.quiesced;
    await h.cache.writeOfflineRefused(h.account.key, h.now);
    final generation = session.generation;
    final api = session.api;
    final message = session.message;
    release.complete();
    await probe;
    expect(session.active?.user.id, 8);
    expect(session.api, same(api));
    expect(session.generation, generation);
    expect(session.message, message);
    expect(h.store.lastActive, session.active!.key);
    expect(await h.cache.readOfflineRefused(h.account.key), isTrue);
  });

  test('lock setting loading prevents entry until it resolves', () async {
    final h = _Harness(_network);
    addTearDown(h.dispose);
    await h.seed();
    h.lockStore.pending = Completer<bool>();
    final loading = h.lock.start();
    final session = h.makeSession();
    final initialize = session.initialize();
    await _eventually(() => session.resuming);
    expect(session.canEnterOffline, isFalse);
    h.lockStore.pending!.complete(false);
    await loading;
    await initialize;
    expect(session.offline, isNotNull);
  });

  test('lock setting load timeout rejects offline entry', () async {
    final h = _Harness(_network);
    addTearDown(h.dispose);
    await h.seed();
    h.lockStore.pending = Completer<bool>();
    final loading = h.lock.start();
    final session = h.makeSession();
    await session.initialize();
    expect(session.offline, isNull);
    h.lockStore.pending!.complete(false);
    await loading;
  });

  test(
    'online switch joins a probe then freshly validates and advances generation',
    () async {
      final h = _Harness(_network);
      addTearDown(h.dispose);
      await h.seed();
      await h.lock.start();
      final session = h.makeSession();
      await session.initialize();
      final priorGeneration = session.generation;
      final held = Completer<ResponseBody>();
      var requests = 0;
      h.responder = (_) {
        requests++;
        return requests == 1
            ? held.future
            : jsonResponse({'id': 7, 'username': 'test'});
      };
      final background = session.probeOffline(manual: false);
      await _eventually(() => requests == 1);
      final online = session.probeOffline(switchOnline: true, projectId: 17);
      held.complete(jsonResponse({'id': 7, 'username': 'test'}));
      await background;
      await online;
      expect(requests, 2);
      expect(session.active?.key, h.account.key);
      expect(session.offline, isNull);
      expect(session.generation, greaterThan(priorGeneration));
      expect(session.pendingResumeTarget?.projectId, 17);
      expect(session.pendingResumeTarget?.resource, 'repository');
    },
  );

  test(
    'offline guards prevent session changes; endSession clears departing account',
    () async {
      final h = _Harness(_network);
      addTearDown(h.dispose);
      await h.seed();
      await h.lock.start();
      final session = h.makeSession();
      await session.initialize();
      final before = session.generation;
      await session.connect('https://example.test', 'new');
      await session.select(h.account);
      final removed = await session.remove(h.account);
      expect(removed.removed, isFalse);
      expect(session.offline, isNotNull);
      await session.endSession();
      await h.cache.quiesced;
      expect(session.generation, greaterThan(before));
      expect(session.offline, isNull);
      expect((await h.keys.readOfflineKey(h.account.key)).isFound, isFalse);
    },
  );

  test(
    'same-account network retry retains snapshot through cold start',
    () async {
      final h = _Harness(_network);
      addTearDown(h.dispose);
      await h.seed();
      await h.lock.start();
      offlineModeShellReadyForTesting = false;
      final first = h.makeSession();
      await first.initialize();
      await _eventually(() => h.cache.startupRecovered);
      await first.select(h.account);
      await _eventually(() => h.cache.startupRecovered);
      await h.cache.quiesced;
      expect((await h.keys.readOfflineKey(h.account.key)).isFound, isTrue);
      first.dispose();
      offlineModeShellReadyForTesting = true;
      final second = h.makeSession();
      await second.initialize();
      expect(second.offline?.account.key, h.account.key);
    },
  );

  test('connecting a different account clears retained account data', () async {
    final h = _Harness(_network);
    addTearDown(h.dispose);
    await h.seed();
    await h.lock.start();
    offlineModeShellReadyForTesting = false;
    final session = h.makeSession();
    await session.initialize();
    h.responder = (_) => jsonResponse({'id': 8, 'username': 'other'});
    await session.connect('https://example.test', 'new');
    await h.cache.quiesced;
    expect(session.active?.user.id, 8);
    expect((await h.keys.readOfflineKey(h.account.key)).isFound, isFalse);
  });

  test('lock reload failure covers already admitted offline content', () async {
    final h = _Harness(_network);
    addTearDown(h.dispose);
    await h.seed();
    await h.lock.start();
    final session = h.makeSession();
    await session.initialize();
    expect(session.offline, isNotNull);
    h.lockStore.fail = true;
    await h.lock.reload();
    expect(h.lock.loadFailed, isTrue);
    expect(h.lock.offlineCovering, isTrue);
  });

  test('retry scheduling, foreground age and single flight', () async {
    final h = _Harness(_network);
    addTearDown(h.dispose);
    await h.seed();
    await h.lock.start();
    final session = h.makeSession();
    await session.initialize();
    expect(session.offline, isNotNull);
    expect(
      session.offlineGate.nextRetryAt,
      h.now.add(const Duration(seconds: 15)),
    );
    session.offlineGate.scheduleRetry();
    expect(
      session.offlineGate.nextRetryAt,
      h.now.add(const Duration(seconds: 30)),
    );
    for (final seconds in [60, 120, 300, 300]) {
      session.offlineGate.scheduleRetry();
      expect(
        session.offlineGate.nextRetryAt,
        h.now.add(Duration(seconds: seconds)),
      );
    }
    final completer = Completer<IdentityVerdict>();
    var calls = 0;
    Future<IdentityVerdict> action() {
      calls++;
      return completer.future;
    }

    final one = session.offlineGate.probe(action);
    final two = session.offlineGate.probe(action);
    expect(calls, 1);
    completer.complete(
      const IdentityNoVerdict(ApiFailure(FailureKind.network)),
    );
    expect(await one, same(await two));
    h.now = h.now.add(const Duration(days: 31));
    session.offlineGate.setForeground(true);
    expect(session.offline, isNull);
  });

  test('rate budget blocks probe until retryAt', () async {
    final h = _Harness(_network);
    addTearDown(h.dispose);
    await h.lock.start();
    final session = h.makeSession();
    session.offlineGate.rateBudget.noteResponse(
      headers: {
        'retry-after': ['60'],
      },
      statusCode: 429,
      requestClass: RateRequestClass.global,
      sequence: session.offlineGate.rateBudget.nextSequence(),
      trusted: true,
    );
    var calls = 0;
    final result = await session.offlineGate.probe(() async {
      calls++;
      return const IdentityNoVerdict(ApiFailure(FailureKind.network));
    });
    expect((result as IdentityNoVerdict).kind, FailureKind.rateLimited);
    expect(calls, 0);
  });
}
