import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/instance_ca.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/instance_trust.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';

final ca = parseCaCertificate(File('test/fixtures/tls/ca.pem').readAsBytesSync());
final otherCa =
    parseCaCertificate(File('test/fixtures/tls/other_ca.pem').readAsBytesSync());

/// What dart:io raises when the platform refuses the server's certificate;
/// Dio wraps it as `DioExceptionType.unknown`, as with a real handshake.
final class HandshakeRefusingAdapter implements HttpClientAdapter {
  int attempts = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    attempts++;
    throw const HandshakeException(
      'Handshake error in client',
      OSError('CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate'),
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A session whose clients fail the handshake for an instance until a CA is
/// stored for it, the way the production client does with its context.
SessionController trustingSession(
  MemoryAccountStore store,
  InstanceTrust trust, {
  FakeAdapter? adapter,
  HandshakeRefusingAdapter? refusing,
}) {
  final accepted =
      adapter ?? FakeAdapter((_) => jsonResponse({'id': 7, 'username': 'tester'}));
  final refused = refusing ?? HandshakeRefusingAdapter();
  return SessionController(
    store,
    readCache: store.readCache,
    trust: trust,
    createApi: (instance, credential, oauth, onOAuthRotated) => GitLabApi(
      instance: instance,
      credential: credential,
      dio: Dio()
        ..httpClientAdapter =
            trust.certificateFor(instance) == null ? refused : accepted,
      oauth: oauth,
      onOAuthRotated: onOAuthRotated,
    ),
  );
}

Account account(String instance, int id) => Account(
  instance: GitLabInstance.parse(instance),
  user: GitLabUser(id: id, username: 'user$id', name: 'User $id'),
  token: 'synthetic-test-token',
);

void main() {
  test('storage key is instance_ca.v1.<base64url(instance.key)>', () {
    expect(
      instanceCaStorageKey('https://gitlab.example.com/gitlab'),
      'instance_ca.v1.aHR0cHM6Ly9naXRsYWIuZXhhbXBsZS5jb20vZ2l0bGFi',
    );
    expect(
      instanceKeyOfStorageKey(
          'instance_ca.v1.aHR0cHM6Ly9naXRsYWIuZXhhbXBsZS5jb20vZ2l0bGFi'),
      'https://gitlab.example.com/gitlab',
    );
    expect(instanceKeyOfStorageKey('instance_ca.v1.%%%'), isNull);
  });

  test('a failed connect stores nothing; the CA is stored only on import',
      () async {
    final store = MemoryAccountStore();
    final backing = MemoryInstanceTrustStore();
    final trust = InstanceTrust.memory(backing);
    final refusing = HandshakeRefusingAdapter();
    final session = trustingSession(store, trust, refusing: refusing);
    addTearDown(session.dispose);
    await session.initialize();

    await session.connect('https://gitlab.example.com/gitlab', 'synthetic-test-token');
    expect(refusing.attempts, 1);
    expect(session.active, isNull);
    final untrusted = session.untrusted!;
    expect(untrusted.instance.key, 'https://gitlab.example.com/gitlab');
    expect(untrusted.retry, UntrustedRetry.connect);
    expect(session.message,
        contains(const ApiFailure(FailureKind.untrustedCertificate).title));
    expect(backing.values, isEmpty);
    expect(store.accounts, isEmpty);

    await session.importInstanceCa(untrusted.instance, ca);
    final key = instanceCaStorageKey('https://gitlab.example.com/gitlab');
    expect(backing.values.keys, [key]);
    expect(InstanceCaCertificate.decode(backing.values[key]), ca);

    await session.connect('https://gitlab.example.com/gitlab', 'synthetic-test-token');
    expect(session.active?.user.id, 7);
    expect(session.untrusted, isNull);
    expect(refusing.attempts, 1);
  });

  test('a failed write to secure storage stores nothing and says so', () async {
    final backing = _FailingTrustStore();
    final trust = InstanceTrust.memory(backing);
    await expectLater(
      trust.save(GitLabInstance.parse('https://gitlab.example.com'), ca),
      throwsA(isA<CaCertificateFailure>().having(
          (failure) => failure.problem, 'problem', CaCertificateProblem.saveFailed)),
    );
    expect(trust.certificateFor(GitLabInstance.parse('https://gitlab.example.com')),
        isNull);
  });

  test('select of a saved account offers the import for that account',
      () async {
    final store = MemoryAccountStore();
    final saved = account('https://gitlab.example.com', 7);
    store.accounts = [saved];
    final session = trustingSession(store, InstanceTrust.memory());
    addTearDown(session.dispose);
    await session.initialize();
    await session.select(saved);
    expect(session.active, isNull);
    expect(session.untrusted?.retry, UntrustedRetry.select);
    expect(session.untrusted?.saved?.key, saved.key);
    expect(store.accounts, [saved], reason: 'no identity verdict, nothing removed');
  });

  test('the CA stays while another account of the instance remains and goes '
      'with the last one', () async {
    final store = MemoryAccountStore();
    final first = account('https://gitlab.example.com', 7);
    final second = account('https://gitlab.example.com', 8);
    final elsewhere = account('https://code.example.org', 9);
    store.accounts = [first, second, elsewhere];
    final backing = MemoryInstanceTrustStore({
      instanceCaStorageKey(first.instance.key): ca.encode(),
      instanceCaStorageKey(elsewhere.instance.key): otherCa.encode(),
    });
    final trust = InstanceTrust(backing);
    final session = trustingSession(store, trust);
    addTearDown(session.dispose);
    await session.initialize();
    expect(trust.certificateFor(first.instance), ca);
    expect(trust.certificateFor(elsewhere.instance), otherCa);

    expect((await session.remove(first)).removed, isTrue);
    expect(trust.certificateFor(first.instance), ca);
    expect(backing.values, contains(instanceCaStorageKey(first.instance.key)));

    expect((await session.remove(second)).removed, isTrue);
    expect(store.accounts, [elsewhere]);
    expect(trust.certificateFor(first.instance), isNull);
    expect(backing.values.keys, [instanceCaStorageKey(elsewhere.instance.key)]);
  });

  test('a failed account removal keeps the CA', () async {
    final store = MemoryAccountStore();
    final only = account('https://gitlab.example.com', 7);
    store.accounts = [only];
    final backing = MemoryInstanceTrustStore({
      instanceCaStorageKey(only.instance.key): ca.encode(),
    });
    final trust = InstanceTrust(backing);
    final session = trustingSession(store, trust);
    addTearDown(session.dispose);
    await session.initialize();
    store.rejectWrite = true;
    expect((await session.remove(only)).removed, isFalse);
    expect(store.accounts, [only]);
    expect(trust.certificateFor(only.instance), ca);
    expect(backing.values, hasLength(1));
  });

  test('start-up sweeps entries whose instance has no saved account', () async {
    final store = MemoryAccountStore();
    final kept = account('https://gitlab.example.com', 7);
    store.accounts = [kept];
    final orphan = instanceCaStorageKey('https://gone.example.com');
    final backing = MemoryInstanceTrustStore({
      instanceCaStorageKey(kept.instance.key): ca.encode(),
      orphan: otherCa.encode(),
      'instance_ca.v1.%%%': 'undecodable name',
      'unrelated.key': 'kept',
    });
    final trust = InstanceTrust(backing);
    final session = trustingSession(store, trust);
    addTearDown(session.dispose);
    await session.initialize();
    await pumpEventQueue();
    expect(trust.certificateFor(kept.instance), ca);
    expect(backing.values.keys.toSet(), {
      instanceCaStorageKey(kept.instance.key),
      'unrelated.key',
    });
  });

  test('an unreadable store keeps every entry and uses the default roots',
      () async {
    final store = MemoryAccountStore();
    final trust = InstanceTrust(_FailingTrustStore());
    final session = trustingSession(store, trust);
    addTearDown(session.dispose);
    await session.initialize();
    expect(trust.loaded, isTrue);
    expect(trust.readable, isFalse);
    expect(session.accountsLoaded, isTrue);
  });

  test('a CA imported this run is not swept before its account exists',
      () async {
    final backing = MemoryInstanceTrustStore();
    final trust = InstanceTrust(backing);
    await trust.load();
    final instance = GitLabInstance.parse('https://gitlab.example.com');
    await trust.save(instance, ca);
    await trust.sweepOrphans(const {});
    expect(trust.certificateFor(instance), ca);
    expect(backing.values, hasLength(1));
  });

  test('remove deletes the entry; the next client gets the default roots',
      () async {
    final backing = MemoryInstanceTrustStore();
    final trust = InstanceTrust.memory(backing);
    final instance = GitLabInstance.parse('https://gitlab.example.com');
    await trust.save(instance, ca);
    expect(trust.securityContextFor(instance), isNotNull);
    await trust.remove(instance);
    expect(trust.securityContextFor(instance), isNull);
    expect(backing.values, isEmpty);
  });
}

final class _FailingTrustStore implements InstanceTrustStore {
  @override
  Future<Map<String, String>> readAll() async =>
      throw StateError('synthetic keychain failure');
  @override
  Future<String?> read(String storageKey) async => null;
  @override
  Future<void> write(String storageKey, String value) async =>
      throw StateError('synthetic keychain failure');
  @override
  Future<void> delete(String storageKey) async =>
      throw StateError('synthetic keychain failure');
}
