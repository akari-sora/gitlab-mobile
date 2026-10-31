import 'dart:async';
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
  bool Function(GitLabInstance instance)? accepts,
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
            (accepts?.call(instance) ?? trust.certificateFor(instance) != null)
            ? accepted
            : refused,
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
  _securityReviewTests();
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

    final kept = await session.importInstanceCa(
      untrusted.instance,
      ca,
      retry: () =>
          session.connect('https://gitlab.example.com/gitlab', 'synthetic-test-token'),
    );
    expect(kept, isTrue);
    final key = instanceCaStorageKey('https://gitlab.example.com/gitlab');
    expect(backing.values.keys, [key]);
    expect(InstanceCaCertificate.decode(backing.values[key]), ca);
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

const _gitLabComWarning = 'GitLab.com 的憑證不受信任';
const _didNotHelp = '匯入這張 CA 憑證後，站台的憑證仍不受信任';

void _securityReviewTests() {
  test('isGitLabCom covers gitlab.com and its subdomains only', () {
    bool gitLabCom(String url) => GitLabInstance.parse(url).isGitLabCom;
    expect(gitLabCom('https://gitlab.com'), isTrue);
    expect(gitLabCom('https://GitLab.com/'), isTrue);
    expect(gitLabCom('https://gitlab.com.'), isTrue);
    expect(gitLabCom('https://next.gitlab.com'), isTrue);
    expect(gitLabCom('https://a.b.gitlab.com:8443/x'), isTrue);
    expect(gitLabCom('https://gitlab.com.evil.example'), isFalse);
    expect(gitLabCom('https://notgitlab.com'), isFalse);
    expect(gitLabCom('https://gitlab.example.com'), isFalse);
  });

  test('M1: GitLab.com never offers an import and refuses to store one',
      () async {
    final store = MemoryAccountStore();
    final backing = MemoryInstanceTrustStore();
    final trust = InstanceTrust.memory(backing);
    final session = trustingSession(store, trust);
    addTearDown(session.dispose);
    await session.initialize();
    await session.connect('https://gitlab.com', 'synthetic-test-token');
    expect(session.active, isNull);
    expect(session.untrusted, isNull);
    expect(session.message, contains(_gitLabComWarning));

    final gitLabCom = GitLabInstance.parse('https://gitlab.com');
    Matcher refused() => throwsA(isA<CaCertificateFailure>().having(
        (failure) => failure.problem, 'problem', CaCertificateProblem.gitLabCom));
    await expectLater(trust.save(gitLabCom, ca), refused());
    await expectLater(
      trust.save(GitLabInstance.parse('https://next.gitlab.com'), ca),
      refused(),
    );
    var retried = false;
    await expectLater(
      session.importInstanceCa(gitLabCom, ca, retry: () async => retried = true),
      refused(),
    );
    expect(retried, isFalse);
    expect(backing.values, isEmpty);
  });

  test('L2: validity dates decide whether a CA can help', () {
    final now = DateTime.utc(2026, 10, 31);
    RefusedCertificate dates(DateTime? start, DateTime? end) => RefusedCertificate(
        subject: '/CN=x', issuer: '/CN=y', startValidity: start, endValidity: end);
    expect(dates(DateTime.utc(2026), DateTime.utc(2027)).validAt(now), isTrue);
    expect(dates(DateTime.utc(2025), DateTime.utc(2026)).validAt(now), isFalse);
    expect(dates(DateTime.utc(2027), DateTime.utc(2028)).validAt(now), isFalse);
    expect(dates(null, null).validAt(now), isTrue);
  });

  test('L3: a retry that still fails at the certificate removes the new CA',
      () async {
    final store = MemoryAccountStore();
    final backing = MemoryInstanceTrustStore();
    final trust = InstanceTrust.memory(backing);
    final refusing = HandshakeRefusingAdapter();
    final session =
        trustingSession(store, trust, refusing: refusing, accepts: (_) => false);
    addTearDown(session.dispose);
    await session.initialize();
    const url = 'https://gitlab.example.com';
    await session.connect(url, 'synthetic-test-token');
    final kept = await session.importInstanceCa(
      session.untrusted!.instance,
      ca,
      retry: () => session.connect(url, 'synthetic-test-token'),
    );
    expect(kept, isFalse);
    expect(refusing.attempts, 2);
    expect(trust.certificateFor(GitLabInstance.parse(url)), isNull);
    expect(backing.values, isEmpty);
    expect(session.untrusted, isNull);
    expect(session.message, contains(_didNotHelp));
  });

  test('L3: a retry that still fails restores the previous CA', () async {
    final store = MemoryAccountStore();
    const url = 'https://gitlab.example.com';
    final instance = GitLabInstance.parse(url);
    final backing = MemoryInstanceTrustStore({
      instanceCaStorageKey(instance.key): otherCa.encode(),
    });
    final trust = InstanceTrust.memory(backing);
    final session = trustingSession(store, trust, accepts: (_) => false);
    addTearDown(session.dispose);
    await session.initialize();
    await trust.save(instance, otherCa);
    await session.connect(url, 'synthetic-test-token');
    expect(
      await session.importInstanceCa(instance, ca,
          retry: () => session.connect(url, 'synthetic-test-token')),
      isFalse,
    );
    expect(trust.certificateFor(instance), otherCa);
    expect(InstanceCaCertificate.decode(backing.values[instanceCaStorageKey(url)]),
        otherCa);
  });

  test('L3: a retry that fails for another reason keeps the CA', () async {
    final store = MemoryAccountStore();
    final trust = InstanceTrust.memory();
    final session = trustingSession(store, trust,
        adapter: FakeAdapter((_) => jsonResponse({'message': '401'}, status: 401)));
    addTearDown(session.dispose);
    await session.initialize();
    const url = 'https://gitlab.example.com';
    await session.connect(url, 'synthetic-test-token');
    expect(
      await session.importInstanceCa(session.untrusted!.instance, ca,
          retry: () => session.connect(url, 'synthetic-test-token')),
      isTrue,
    );
    expect(trust.certificateFor(GitLabInstance.parse(url)), ca);
    expect(session.active, isNull);
  });

  test('L6: a failed delete stops trusting the CA for the rest of the run',
      () async {
    final store = MemoryAccountStore();
    final instance = GitLabInstance.parse('https://gitlab.example.com');
    final backing = _StuckTrustStore({
      instanceCaStorageKey(instance.key): ca.encode(),
    });
    final trust = InstanceTrust(backing);
    final refusing = HandshakeRefusingAdapter();
    final session = trustingSession(store, trust, refusing: refusing);
    addTearDown(session.dispose);
    await session.initialize();
    expect(trust.certificateFor(instance), ca);

    await expectLater(
      trust.remove(instance),
      throwsA(isA<CaCertificateFailure>().having(
          (failure) => failure.problem, 'problem', CaCertificateProblem.removeFailed)),
    );
    expect(backing.values, hasLength(1), reason: 'storage still holds it');
    expect(trust.certificateFor(instance), isNull);
    expect(trust.instanceKeys, isEmpty);
    expect(trust.securityContextFor(instance), isNull);
    // A later sign-in builds its client without it.
    await session.connect(instance.key, 'synthetic-test-token');
    expect(refusing.attempts, 1);
    expect(session.active, isNull);
    expect(session.untrusted?.instance.key, instance.key);
  });

  test('L7: a hung CA delete cannot hold the account removal', () async {
    final store = MemoryAccountStore();
    final only = account('https://gitlab.example.com', 7);
    store.accounts = [only];
    final backing = _StuckTrustStore({
      instanceCaStorageKey(only.instance.key): ca.encode(),
    }, hang: true);
    final trust = InstanceTrust(backing);
    final session = trustingSession(store, trust);
    addTearDown(session.dispose);
    await session.initialize();
    final watch = Stopwatch()..start();
    expect((await session.remove(only)).removed, isTrue);
    expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
    expect(store.accounts, isEmpty);
    expect(trust.certificateFor(only.instance), isNull);
  });
}

/// A keychain whose delete fails ([hang] false) or never answers.
final class _StuckTrustStore implements InstanceTrustStore {
  _StuckTrustStore(this.values, {this.hang = false});
  final Map<String, String> values;
  final bool hang;
  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
  @override
  Future<String?> read(String storageKey) async => values[storageKey];
  @override
  Future<void> write(String storageKey, String value) async =>
      values[storageKey] = value;
  @override
  Future<void> delete(String storageKey) => hang
      ? Completer<void>().future
      : Future.error(StateError('synthetic keychain failure'));
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
