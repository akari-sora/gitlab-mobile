import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/mr6c_qa_protocol.dart';
import '../../tool/mr6c_socket_transport.dart';

Future<(File, File)> _certificate(Directory directory, String san) async {
  await directory.create();
  final certificate = File('${directory.path}/certificate.pem');
  final key = File('${directory.path}/key.pem');
  final result = await Process.run('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-days',
    '1',
    '-subj',
    '/CN=mr6c-synthetic',
    '-addext',
    'subjectAltName=$san',
    '-addext',
    'basicConstraints=critical,CA:TRUE',
    '-addext',
    'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign',
    '-addext',
    'extendedKeyUsage=serverAuth',
    '-keyout',
    key.path,
    '-out',
    certificate.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('test certificate generation failed');
  }
  return (certificate, key);
}

Mr6cFixtureEndpoint _endpoint(
  String pem,
  int port, {
  String host = 'localhost',
}) => Mr6cFixtureEndpoint.parse({
  'host': host,
  'port': port,
  'certificate_pem': pem,
  'network_conclusion': 'NOT_VERIFIED',
}, hostTest: true);

Future<void> main() async {
  late Directory scratch;
  late (File, File) trusted;
  late (File, File) other;
  late (File, File) wrongHost;
  setUpAll(() async {
    scratch = await Directory.systemTemp.createTemp('mr6c-dart-tls-');
    trusted = await _certificate(
      Directory('${scratch.path}/trusted'),
      'DNS:localhost,IP:127.0.0.1,IP:10.0.2.2',
    );
    other = await _certificate(
      Directory('${scratch.path}/other'),
      'DNS:localhost',
    );
    wrongHost = await _certificate(
      Directory('${scratch.path}/wrong-host'),
      'DNS:other.invalid',
    );
  });
  tearDownAll(() => scratch.delete(recursive: true));

  Future<HttpServer> server(
    (File, File) pair,
    Future<void> Function(HttpRequest) handler,
  ) async {
    final context = SecurityContext()
      ..useCertificateChain(pair.$1.path)
      ..usePrivateKey(pair.$2.path);
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen(
      (request) => unawaited(handler(request)),
      onError: (Object _) {},
    );
    addTearDown(() => server.close(force: true));
    return server;
  }

  Dio client(Mr6cFixtureEndpoint endpoint, Mr6cSocketMetrics metrics) {
    final dio = Dio()..httpClientAdapter = Mr6cSocketAdapter(endpoint, metrics);
    addTearDown(() => dio.close(force: true));
    return dio;
  }

  test(
    'endpoint accepts only the emulator alias without explicit host-test mode',
    () async {
      final value = <String, Object>{
        'host': '10.0.2.2',
        'port': 1234,
        'certificate_pem': await trusted.$1.readAsString(),
        'network_conclusion': 'NOT_VERIFIED',
      };
      expect(Mr6cFixtureEndpoint.parse(value).host, '10.0.2.2');
      for (final bad in <Map<String, Object>>[
        {...value, 'host': 'localhost'},
        {...value, 'host': 'example.com'},
        {...value, 'port': 1.0},
        {...value, 'port': 0},
        {...value, 'network_conclusion': 'PASS'},
        {...value, 'token': 'secret'},
        {...value, 'certificate_pem': '-----BEGIN PRIVATE KEY-----'},
      ]) {
        expect(
          () => Mr6cFixtureEndpoint.parse(bad),
          throwsA(isA<QaProtocolException>()),
        );
      }
    },
  );

  test(
    'real TLS socket receives GitLab bytes and split SSE heartbeat without content evidence',
    () async {
      final host = await server(trusted, (request) async {
        if (request.uri.path == '/v1/chat/completions') {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.write(': heart');
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
          request.response.write('beat\n\ndata: synthetic-only\n\n');
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"id":1}');
        }
        await request.response.close();
      });
      final endpoint = _endpoint(await trusted.$1.readAsString(), host.port);
      final metrics = Mr6cSocketMetrics();
      final dio = client(endpoint, metrics);
      expect(
        (await dio.getUri<Object?>(endpoint.uri('/api/v4/user'))).statusCode,
        200,
      );
      await dio.postUri<String>(
        endpoint.uri('/v1/chat/completions'),
        data: '{}',
        options: Options(responseType: ResponseType.plain),
      );
      final snapshot = metrics.snapshot();
      final events = snapshot['events']! as List<Map<String, Object>>;
      final kinds = events.map((value) => value['kind']).toList();
      expect(kinds, contains('gitlab_readback_received'));
      expect(kinds.where((kind) => kind == 'sse_heartbeat_received').length, 1);
      expect(jsonEncode(snapshot), isNot(contains('synthetic-only')));
      expect(snapshot['network_conclusion'], 'NOT_VERIFIED');
    },
  );

  test(
    'unknown certificate and wrong hostname fail ordinary TLS verification',
    () async {
      for (final pair in [other, wrongHost]) {
        final host = await server(
          pair,
          (request) async => request.response.close(),
        );
        final pem = await (pair == wrongHost ? wrongHost.$1 : trusted.$1)
            .readAsString();
        final endpoint = _endpoint(pem, host.port);
        await expectLater(
          client(
            endpoint,
            Mr6cSocketMetrics(),
          ).getUri<Object?>(endpoint.uri('/api/v4/user')),
          throwsA(isA<DioException>()),
        );
      }
    },
  );

  test('alternate origins and real credentials never reach a socket', () async {
    var requests = 0;
    final host = await server(trusted, (request) async {
      requests++;
      await request.response.close();
    });
    final endpoint = _endpoint(await trusted.$1.readAsString(), host.port);
    final dio = client(endpoint, Mr6cSocketMetrics());
    for (final headers in [
      {'Authorization': 'Bearer owner-secret'},
      {'PRIVATE-TOKEN': 'owner-secret'},
      {'Cookie': 'owner-secret'},
    ]) {
      await expectLater(
        dio.getUri<Object?>(
          endpoint.uri('/api/v4/user'),
          options: Options(headers: headers),
        ),
        throwsA(isA<DioException>()),
      );
    }
    for (final uri in [
      endpoint.uri('/api/v4/user').replace(scheme: 'http'),
      endpoint.uri('/api/v4/user').replace(host: '127.0.0.1'),
      endpoint.uri('/api/v4/user').replace(port: host.port + 1),
      endpoint.uri('/api/v4/user').replace(userInfo: 'owner'),
      endpoint.uri('/api/v4/private'),
    ]) {
      await expectLater(dio.getUri<Object?>(uri), throwsA(isA<DioException>()));
    }
    expect(requests, 0);
  });

  test('redirect never follows to another origin', () async {
    var requests = 0;
    final host = await server(trusted, (request) async {
      requests++;
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        'location',
        'https://example.invalid/private',
      );
      await request.response.close();
    });
    final endpoint = _endpoint(await trusted.$1.readAsString(), host.port);
    await expectLater(
      client(
        endpoint,
        Mr6cSocketMetrics(),
      ).getUri<Object?>(endpoint.uri('/api/v4/user')),
      throwsA(isA<DioException>()),
    );
    expect(requests, 1);
  });

  QaCommand command(String phase) => QaCommand.parse({
    'schema': 1,
    'session': 'test',
    'case': 'V9',
    'variant': 'task_manager_stop',
    'phase': phase,
    'sequence': phase == 'prepare' ? 1 : 2,
  });

  test(
    'journal barrier needs typed preconditions, safe digests and correct phase',
    () {
      QaJournalBarrier evidence({bool active = true, String? digest}) =>
          QaJournalBarrier(
            executionDigest: digest ?? 'a' * 64,
            fileDigest: 'b' * 64,
            dispatchAccepted: true,
            journalFlushed: true,
            nativeServiceActive: active,
            modelCalls: 1,
            mutationCalls: 1,
          );
      expect(
        QaEvent(
          command('prepare'),
          QaEventKind.barrier,
          QaOutcome.running,
          evidence: evidence(),
        ).toJson()['outcome'],
        'RUNNING',
      );
      for (final bad in [
        evidence(active: false),
        evidence(digest: 'owner-content'),
      ]) {
        expect(
          () => QaEvent(
            command('prepare'),
            QaEventKind.barrier,
            QaOutcome.running,
            evidence: bad,
          ),
          throwsA(isA<QaProtocolException>()),
        );
      }
      expect(
        () => QaEvent(
          command('recover'),
          QaEventKind.barrier,
          QaOutcome.running,
          evidence: evidence(),
        ),
        throwsA(isA<QaProtocolException>()),
      );
    },
  );

  test('recovery preflight failure cannot be downgraded to NOT_RUN', () {
    const error = QaSandboxUnavailable();
    expect(
      qaPreflightRejected(command('prepare'), error).toJson()['outcome'],
      'NOT_RUN',
    );
    final result = qaPreflightRejected(command('recover'), error).toJson();
    expect(result['event'], 'error');
    expect(result['outcome'], 'FAIL');
    expect(result['evidence'], {'reason': 'unexpected_error'});
  });

  test(
    'journal PASS requires recovery flags and zero model and mutation resends',
    () {
      QaJournalRecovered evidence({int model = 0, bool isolated = true}) =>
          QaJournalRecovered(
            executionDigest: 'a' * 64,
            fileDigest: 'c' * 64,
            uncertain: true,
            isolated: isolated,
            permitAbsent: true,
            persistentAccountsVerified: true,
            modelCalls: model,
            mutationCalls: 0,
          );
      expect(
        QaEvent(
          command('recover'),
          QaEventKind.done,
          QaOutcome.pass,
          evidence: evidence(),
        ).toJson()['outcome'],
        'PASS',
      );
      for (final bad in [evidence(model: 1), evidence(isolated: false)]) {
        expect(
          () => QaEvent(
            command('recover'),
            QaEventKind.done,
            QaOutcome.pass,
            evidence: bad,
          ),
          throwsA(isA<QaProtocolException>()),
        );
      }
      expect(
        () => QaEvent(
          command('prepare'),
          QaEventKind.done,
          QaOutcome.pass,
          evidence: evidence(),
        ),
        throwsA(isA<QaProtocolException>()),
      );
    },
  );
}
