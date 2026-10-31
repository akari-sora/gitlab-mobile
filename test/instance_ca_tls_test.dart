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

TypeMatcher<ApiFailure> _failure(FailureKind kind) =>
    isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind);

void main() {
  late Directory dir;
  late ({String certificate, String key}) tls;
  late HttpServer server;
  late GitLabInstance instance;
  final ca = parseCaCertificate(File('test/fixtures/tls/ca.pem').readAsBytesSync());
  final caFromDer =
      parseCaCertificate(File('test/fixtures/tls/ca.der').readAsBytesSync());
  final otherCa =
      parseCaCertificate(File('test/fixtures/tls/other_ca.pem').readAsBytesSync());
  var requests = 0;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('mergeline-instance-ca-');
    tls = await _issueServerCertificate(dir);
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() async {
    requests = 0;
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(tls.certificate))
      ..usePrivateKeyBytes(utf8.encode(tls.key));
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    server.listen((request) async {
      requests++;
      if (request.uri.path.endsWith('/api/v4/user')) {
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

    await session.importInstanceCa(instance, ca);
    await session.connect(instance.key, 'synthetic-test-token');
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
}
