import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/anonymous_api.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/instance_ca.dart';
import 'package:gitlab_mobile/features/auth/instance_trust.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import 'session_test.dart' show MemoryAccountStore;

// A real dart:io TLS handshake against a loopback HttpServer. The CA under
// test/fixtures/tls is committed (test-only key); the server certificate is
// issued from it on every run, because a committed leaf would expire and
// Apple's verifier refuses leaves valid for more than 825 days.
const _serverConfig = '[req]\ndistinguished_name = dn\n[dn]\n'
    '[v3_server]\nbasicConstraints = CA:FALSE\n'
    'keyUsage = critical,digitalSignature,keyEncipherment\n'
    'extendedKeyUsage = serverAuth\n'
    'subjectAltName = DNS:localhost,IP:127.0.0.1\n';

/// A leaf whose validity ended in 2020, issued by the same committed CA
/// (`openssl ca` takes explicit dates on every OpenSSL version CI may have).
Future<String> _issueExpiredCertificate(Directory dir) async {
  final fixtures = Directory('test/fixtures/tls').absolute.path;
  File('${dir.path}/index.txt').writeAsStringSync('');
  File('${dir.path}/serial').writeAsStringSync('1000\n');
  File('${dir.path}/ca.cnf').writeAsStringSync(
    '[ca]\ndefault_ca = test_ca\n'
    '[test_ca]\ndatabase = index.txt\nnew_certs_dir = .\nserial = serial\n'
    'default_md = sha256\npolicy = any\nunique_subject = no\n'
    '[any]\ncommonName = supplied\n',
  );
  final result = await Process.run('openssl', [
    'ca', '-batch', '-notext', '-config', 'ca.cnf',
    '-cert', '$fixtures/ca.pem', '-keyfile', '$fixtures/ca.key',
    '-in', 'server.csr', '-out', 'expired.pem',
    '-startdate', '20200101000000Z', '-enddate', '20200102000000Z',
    '-extfile', 'server.cnf', '-extensions', 'v3_server',
  ], workingDirectory: dir.path);
  if (result.exitCode != 0) {
    throw StateError('openssl ca failed: ${result.stderr}');
  }
  return File('${dir.path}/expired.pem').readAsStringSync();
}

Future<({String certificate, String key})> _issueServerCertificate(
  Directory dir,
) async {
  final fixtures = Directory('test/fixtures/tls').absolute.path;
  Future<void> openssl(List<String> args) async {
    final result = await Process.run('openssl', args, workingDirectory: dir.path);
    if (result.exitCode != 0) {
      throw StateError('openssl ${args.first} failed: ${result.stderr}');
    }
  }

  File('${dir.path}/server.cnf').writeAsStringSync(_serverConfig);
  await openssl([
    'req', '-new', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', 'server.key', '-out', 'server.csr',
    '-subj', '/CN=localhost', '-config', 'server.cnf',
  ]);
  await openssl([
    'x509', '-req', '-in', 'server.csr',
    '-CA', '$fixtures/ca.pem', '-CAkey', '$fixtures/ca.key',
    '-set_serial', '${DateTime.now().microsecondsSinceEpoch}',
    '-out', 'server.pem', '-days', '2', '-sha256',
    '-extfile', 'server.cnf', '-extensions', 'v3_server',
  ]);
  return (
    certificate: File('${dir.path}/server.pem').readAsStringSync(),
    key: File('${dir.path}/server.key').readAsStringSync(),
  );
}

/// The second-host tests reach the loopback server as `localhost`; skip them
/// where that name does not resolve to 127.0.0.1.
Future<bool> _localhostIsIpv4Loopback() async {
  try {
    final addresses = await InternetAddress.lookup('localhost');
    return addresses.any((address) => address.address == '127.0.0.1');
  } on SocketException {
    return false;
  }
}

const _noLocalhost = 'localhost does not resolve to 127.0.0.1 on this host';

TypeMatcher<ApiFailure> _failure(FailureKind kind) =>
    isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind);

void main() {
  late Directory dir;
  late ({String certificate, String key}) tls;
  late String expiredCertificate;
  late HttpServer server;
  late GitLabInstance instance;
  final ca = parseCaCertificate(File('test/fixtures/tls/ca.pem').readAsBytesSync());
  final caFromDer =
      parseCaCertificate(File('test/fixtures/tls/ca.der').readAsBytesSync());
  final otherCa =
      parseCaCertificate(File('test/fixtures/tls/other_ca.pem').readAsBytesSync());
  var requests = 0;
  var hopHost = '127.0.0.1';

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('mergeline-instance-ca-');
    tls = await _issueServerCertificate(dir);
    expiredCertificate = await _issueExpiredCertificate(dir);
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() async {
    requests = 0;
    hopHost = '127.0.0.1';
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(tls.certificate))
      ..usePrivateKeyBytes(utf8.encode(tls.key));
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    server.listen((request) async {
      requests++;
      final redirect = RegExp(r'/api/v4/projects/1/jobs/2/artifacts$')
          .hasMatch(request.uri.path);
      if (redirect) {
        // Object storage on the same server, reached by the host the test
        // picks: the certificate is valid for both names.
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'https://$hopHost:${server.port}/objects/artifacts.zip',
          );
      } else if (request.uri.path == '/objects/artifacts.zip') {
        request.response
          ..headers.contentType = ContentType('application', 'zip')
          ..add(const [0x50, 0x4b, 0x05, 0x06]);
      } else if (request.uri.path.endsWith('/api/v4/user')) {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'id': 7, 'username': 'tester', 'name': 'Test'}));
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..headers.contentType = ContentType.json
          ..write('{"message":"404 Not Found"}');
      }
      await request.response.close();
    });
    instance = GitLabInstance.parse('https://127.0.0.1:${server.port}');
  });

  tearDown(() => server.close(force: true));

  GitLabApi client(SecurityContext? context, [GitLabInstance? target]) {
    final api = GitLabApi(
      instance: target ?? instance,
      token: 'synthetic-test-token',
      securityContext: context,
    );
    addTearDown(api.close);
    return api;
  }

  test('without the CA the handshake fails as untrustedCertificate', () async {
    final api = client(null);
    await expectLater(
      api.currentUser(),
      throwsA(_failure(FailureKind.untrustedCertificate).having(
        (failure) => failure.refusedCertificate,
        'refused certificate',
        isA<RefusedCertificate>()
            .having((value) => value.subject, 'subject', contains('CN=localhost'))
            .having((value) => value.issuer, 'issuer',
                contains('Mergeline Test Instance CA')),
      )),
    );
    final verdict = await api.identityCheck();
    expect(verdict, isA<IdentityNoVerdict>());
    expect(verdict.failure?.kind, FailureKind.untrustedCertificate);
    expect(requests, 0, reason: 'no HTTP request reaches the server');
  });

  test('a refused write stays writeUncertain and never reaches the server',
      () async {
    final api = client(null);
    await expectLater(
      api.writeRecord('POST', ['projects', '1', 'issues'], {'title': 't'}),
      throwsA(_failure(FailureKind.writeUncertain)),
    );
    expect(requests, 0);
  });

  test('with the imported CA, PEM or DER, the same request succeeds', () async {
    expect((await client(ca.securityContext()).currentUser()).id, 7);
    expect((await client(caFromDer.securityContext()).currentUser()).id, 7);
    expect(requests, 2);
  });

  test('a different CA still fails', () async {
    await expectLater(
      client(otherCa.securityContext()).currentUser(),
      throwsA(_failure(FailureKind.untrustedCertificate)),
    );
    expect(requests, 0);
  });

  test('the session trusts the CA for its instance only', () async {
    final store = MemoryAccountStore();
    final trust = InstanceTrust.memory();
    final session = SessionController(store, readCache: store.readCache, trust: trust);
    addTearDown(session.dispose);
    await session.initialize();

    await session.connect(instance.key, 'synthetic-test-token');
    expect(session.active, isNull);
    expect(session.untrusted?.instance.key, instance.key);
    expect(session.untrusted?.retry, UntrustedRetry.connect);
    expect(session.untrusted?.certificate?.subject, contains('CN=localhost'));
    expect(session.message, contains(const ApiFailure(FailureKind.untrustedCertificate).title));

    expect(
      await session.importInstanceCa(instance, ca,
          retry: () => session.connect(instance.key, 'synthetic-test-token')),
      isTrue,
    );
    expect(session.active?.user.id, 7);
    expect(session.untrusted, isNull);
    expect((await session.api!.currentUser()).id, 7);

    // Same host and port, another installation path: another instance.
    final other = GitLabInstance.parse('${instance.key}/other');
    await expectLater(
      client(trust.securityContextFor(other), other).currentUser(),
      throwsA(_failure(FailureKind.untrustedCertificate)),
    );
    // Clients that never ask the trust store keep the default roots.
    final anonymous = anonymousGitLabApi(instance);
    addTearDown(anonymous.close);
    await expectLater(
      anonymous.currentUser(),
      throwsA(_failure(FailureKind.untrustedCertificate)),
    );
  });

  test('a second host is not trusted through the session', () async {
    if (!await _localhostIsIpv4Loopback()) return markTestSkipped(_noLocalhost);
    final store = MemoryAccountStore();
    final trust = InstanceTrust.memory();
    final session = SessionController(store, readCache: store.readCache, trust: trust);
    addTearDown(session.dispose);
    await session.initialize();
    await trust.save(instance, ca);
    await session.connect(instance.key, 'synthetic-test-token');
    expect(session.active?.user.id, 7);

    // The server's certificate is valid for localhost too; only the CA is
    // missing for that host.
    final second = GitLabInstance.parse('https://localhost:${server.port}');
    await session.endSession();
    await session.connect(second.key, 'synthetic-test-token');
    expect(session.active, isNull);
    expect(session.untrusted?.instance.key, second.key);
    await expectLater(
      client(trust.securityContextFor(second), second).currentUser(),
      throwsA(_failure(FailureKind.untrustedCertificate)),
    );
  });

  test('L3: importing the wrong CA is rolled back after the retry', () async {
    final store = MemoryAccountStore();
    final trust = InstanceTrust.memory();
    final session = SessionController(store, readCache: store.readCache, trust: trust);
    addTearDown(session.dispose);
    await session.initialize();
    await session.connect(instance.key, 'synthetic-test-token');
    expect(
      await session.importInstanceCa(instance, otherCa,
          retry: () => session.connect(instance.key, 'synthetic-test-token')),
      isFalse,
    );
    expect(trust.certificateFor(instance), isNull);
    expect(session.active, isNull);
    expect(session.untrusted, isNull);
    expect(session.message, contains('CA 憑證無法解決'));
  });

  test('L4: the artifact hop trusts the CA on the instance host only',
      () async {
    if (!await _localhostIsIpv4Loopback()) return markTestSkipped(_noLocalhost);
    final api = client(ca.securityContext());
    var downloads = 0;
    Future<ArtifactDownload> download() async {
      final sink = File('${dir.path}/artifact-${downloads++}').openWrite();
      try {
        return await api.downloadJobArtifacts(1, 2, sink: sink);
      } finally {
        await sink.close();
      }
    }

    // Hop on the instance host: the instance CA applies.
    expect((await download()).bytesWritten, 4);
    // Hop to another host (same server, certificate valid for it): the
    // default roots, so the CA's promise "only connections to {host}" holds.
    hopHost = 'localhost';
    await expectLater(
      download(),
      throwsA(_failure(FailureKind.untrustedCertificate)),
    );
  });

  test('L2: an expired server certificate offers no import', () async {
    final expiredServer = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChainBytes(utf8.encode(expiredCertificate))
        ..usePrivateKeyBytes(utf8.encode(tls.key)),
    );
    addTearDown(() => expiredServer.close(force: true));
    expiredServer.listen((request) async {
      request.response.write('{}');
      await request.response.close();
    });
    final expired = GitLabInstance.parse('https://127.0.0.1:${expiredServer.port}');
    final store = MemoryAccountStore();
    final session = SessionController(store, readCache: store.readCache);
    addTearDown(session.dispose);
    await session.initialize();
    await session.connect(expired.key, 'synthetic-test-token');
    expect(session.active, isNull);
    expect(session.untrusted, isNull);
    expect(session.message, contains('伺服器的憑證已過期或尚未生效'));
    // The same holds with the right CA: only the dates are wrong.
    await expectLater(
      client(ca.securityContext(), expired).currentUser(),
      throwsA(_failure(FailureKind.untrustedCertificate).having(
        (failure) => failure.refusedCertificate?.endValidity?.toUtc(),
        'end of validity',
        DateTime.utc(2020, 1, 2),
      )),
    );
  });
}
