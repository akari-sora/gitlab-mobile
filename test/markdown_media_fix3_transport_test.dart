import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/shared/markdown_media_source.dart';

// The loopback TLS material is generated for each run with the openssl
// command (CI images have it through ca-certificates): no private key is kept
// in the repository, and the server certificate stays within the 398-day limit
// that Apple's TLS verification enforces without ever expiring in the tree.
typedef _TlsMaterial = ({String ca, String certificate, String key});

Future<_TlsMaterial> _generateTlsMaterial(Directory dir) async {
  Future<void> openssl(List<String> args) async {
    final result = await Process.run(
      'openssl',
      args,
      workingDirectory: dir.path,
    );
    if (result.exitCode != 0) {
      throw StateError('openssl ${args.first} failed: ${result.stderr}');
    }
  }

  File('${dir.path}/tls.cnf').writeAsStringSync(
    '[req]\ndistinguished_name = dn\n[dn]\n'
    '[v3_ca]\nbasicConstraints = critical,CA:TRUE\n'
    'keyUsage = critical,keyCertSign,cRLSign\n'
    'subjectKeyIdentifier = hash\n'
    '[v3_server]\nbasicConstraints = CA:FALSE\n'
    'keyUsage = critical,digitalSignature,keyEncipherment\n'
    'extendedKeyUsage = serverAuth\n'
    'subjectAltName = DNS:media.example.com,DNS:redirect.example.com\n',
  );
  await openssl([
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-keyout',
    'ca.key',
    '-out',
    'ca.pem',
    '-days',
    '2',
    '-subj',
    '/CN=Mergeline Test CA',
    '-config',
    'tls.cnf',
    '-extensions',
    'v3_ca',
  ]);
  await openssl([
    'req',
    '-new',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-keyout',
    'server.key',
    '-out',
    'server.csr',
    '-subj',
    '/CN=media.example.com',
    '-config',
    'tls.cnf',
  ]);
  await openssl([
    'x509',
    '-req',
    '-in',
    'server.csr',
    '-CA',
    'ca.pem',
    '-CAkey',
    'ca.key',
    '-CAcreateserial',
    '-out',
    'server.pem',
    '-days',
    '2',
    '-extfile',
    'tls.cnf',
    '-extensions',
    'v3_server',
  ]);
  String read(String name) => File('${dir.path}/$name').readAsStringSync();
  return (
    ca: read('ca.pem'),
    certificate: read('server.pem'),
    key: read('server.key'),
  );
}

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((value) => value.kind, 'kind', kind);

void main() {
  late HttpServer server;
  late SecurityContext trustedContext;
  late Directory tlsDir;
  late _TlsMaterial tls;
  var requests = 0;

  setUpAll(() async {
    tlsDir = Directory.systemTemp.createTempSync('mergeline-tls-');
    tls = await _generateTlsMaterial(tlsDir);
  });

  tearDownAll(() => tlsDir.deleteSync(recursive: true));

  setUp(() async {
    requests = 0;
    final serverContext = SecurityContext()
      ..useCertificateChainBytes(utf8.encode('${tls.certificate}\n${tls.ca}'))
      ..usePrivateKeyBytes(utf8.encode(tls.key));
    trustedContext = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(tls.ca));
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    server.listen((request) async {
      requests++;
      if (request.uri.path == '/redirect-private') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'https://private.example.com:${server.port}/image.png',
          );
      } else if (request.uri.path == '/redirect-rebind') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/image.png');
      } else if (request.uri.path == '/redirect-safe') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'https://redirect.example.com:${server.port}/image.png',
          );
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('image', 'png')
          ..add(<int>[1, 2, 3]);
      }
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  MarkdownMediaSource source(String host, String path) => MarkdownMediaSource(
    kind: MarkdownMediaSourceKind.external,
    uri: Uri.parse('https://$host:${server.port}$path'),
  );

  test(
    'pins the checked address while TLS verifies the original host',
    () async {
      final loader = MarkdownMediaLoader(
        externalResolver: (_) async => <InternetAddress>[
          InternetAddress.loopbackIPv4,
        ],
        allowLoopbackAddressesForTesting: true,
        externalSecurityContextForTesting: trustedContext,
      );
      addTearDown(loader.close);

      expect(
        await loader.load(source('media.example.com', '/image.png')),
        <int>[1, 2, 3],
      );
      await expectLater(
        loader.load(source('wrong.test', '/image.png')),
        throwsA(_failure(FailureKind.network)),
      );
      expect(requests, 1);
    },
  );

  test('fails closed if any DNS result is private before connecting', () async {
    final loader = MarkdownMediaLoader(
      externalResolver: (_) async => <InternetAddress>[
        InternetAddress('8.8.8.8'),
        InternetAddress.loopbackIPv4,
      ],
      externalSecurityContextForTesting: trustedContext,
    );
    addTearDown(loader.close);

    await expectLater(
      loader.load(source('mixed.test', '/image.png')),
      throwsA(_failure(FailureKind.unsupported)),
    );
    expect(requests, 0);
  });

  test('resolves and checks every redirect hop', () async {
    final resolved = <String>[];
    final loader = MarkdownMediaLoader(
      externalResolver: (host) async {
        resolved.add(host);
        if (host == 'private.example.com') {
          return <InternetAddress>[InternetAddress('10.0.0.1')];
        }
        return <InternetAddress>[InternetAddress.loopbackIPv4];
      },
      allowLoopbackAddressesForTesting: true,
      externalSecurityContextForTesting: trustedContext,
    );
    addTearDown(loader.close);

    expect(
      await loader.load(source('media.example.com', '/redirect-safe')),
      <int>[1, 2, 3],
    );
    await expectLater(
      loader.load(source('media.example.com', '/redirect-private')),
      throwsA(_failure(FailureKind.redirectBlocked)),
    );
    expect(
      resolved,
      containsAll(<String>[
        'media.example.com',
        'redirect.example.com',
        'private.example.com',
      ]),
    );
    expect(requests, 3);
  });

  test('same-host redirects cannot reuse a socket across DNS checks', () async {
    var lookups = 0;
    final loader = MarkdownMediaLoader(
      externalResolver: (_) async {
        lookups++;
        return <InternetAddress>[
          lookups == 1
              ? InternetAddress.loopbackIPv4
              : InternetAddress('10.0.0.1'),
        ];
      },
      allowLoopbackAddressesForTesting: true,
      externalSecurityContextForTesting: trustedContext,
    );
    addTearDown(loader.close);

    await expectLater(
      loader.load(source('media.example.com', '/redirect-rebind')),
      throwsA(_failure(FailureKind.redirectBlocked)),
    );
    expect(lookups, 2);
    expect(requests, 1);
  });
}
