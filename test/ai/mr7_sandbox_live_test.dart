import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../../tool/mr7/live_host.dart';
import '../../tool/mr7/live_provider.dart';
import '../../tool/mr7/live_run.dart';
import '../../tool/mr7/live_transport.dart';
import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart' as runner;
import 'mr7_live_provider_cases.dart' as provider_tests;

const _pat = 'fake-owner-pat-only-gitlab';
const _key = 'fake-provider-key-only-provider';
const _sha = '0123456789abcdef0123456789abcdef01234567';

final class _Secrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => [_pat, _key];
}

final class _GitLabFixture {
  final model = Mr7SyntheticGitLab();
  late final HttpServer http;
  final requests = <String>[];
  final authentication = <String>[];
  final clientPorts = <int>{};
  final errors = <Object>[];
  final setupBodies = <Map<String, dynamic>>[];
  bool incompleteStarrers = false;

  /// Paths answered like gitlab.com's burst limiter: 429, plain text, no Date.
  final rateLimitedPaths = <String>{};
  Future<void> Function(HttpRequest)? before;
  Uri get origin => Uri.parse('http://127.0.0.1:${http.port}');

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((request) async {
      try {
        requests.add('${request.method} ${request.uri.path}');
        authentication.add(request.headers.value('private-token') ?? '');
        authentication.add(request.headers.value('authorization') ?? '');
        clientPorts.add(request.connectionInfo!.remotePort);
        await before?.call(request);
        final body = await utf8.decoder.bind(request).join();
        if (rateLimitedPaths.contains(request.uri.path)) {
          request.response.statusCode = 429;
          for (final MapEntry(:key, :value) in _rateLimitHeaders.entries) {
            request.response.headers.set(key, value);
          }
          request.response.write('Retry later\n');
          await request.response.close();
          return;
        }
        if (request.method == 'POST' &&
            request.uri.path == '/api/v4/projects') {
          setupBodies.add(jsonDecode(body) as Map<String, dynamic>);
        }
        final personalList = request.uri.path == '/api/v4/users/7/projects';
        final starrers = request.uri.path == '/api/v4/projects/909/starrers';
        final rows = <Map<String, Object?>>[
          if (model.project?['starred'] == true)
            {
              'user': {'id': 7, 'username': 'synthetic-owner'},
            },
        ];
        final response = starrers
            ? mr7Json(
                rows,
                headers: {
                  'x-page': ['1'],
                  'x-per-page': ['100'],
                  'x-total': ['${rows.length}'],
                  'x-total-pages': ['1'],
                  'x-next-page': incompleteStarrers ? [] : [''],
                },
              )
            : await model.respond(
                // The model answers as gitlab.com, e.g. in a redirect target.
                RequestOptions(
                  baseUrl: 'https://gitlab.com',
                  path: personalList ? '/api/v4/projects' : request.uri.path,
                  method: request.method,
                  queryParameters: request.uri.queryParameters,
                  data: body.isEmpty ? null : jsonDecode(body),
                ),
              );
        request.response.statusCode = response.statusCode;
        response.headers.forEach(
          (key, value) => request.response.headers.set(key, value),
        );
        request.response.headers.set('date', HttpDate.format(model.serverTime));
        final value = jsonDecode(
          await utf8.decoder.bind(response.stream).join(),
        );
        // Match API response shape rather than the synthetic-only projections.
        if (request.uri.path == '/api/v4/namespaces' && value is List) {
          for (final row in value.whereType<Map<String, dynamic>>()) {
            if (row['owner_id'] == 7) row.remove('owner_id');
          }
        }
        if (value is Map && value.containsKey('path_with_namespace')) {
          value.remove('starred');
        }
        request.response.write(jsonEncode(value));
        await request.response.close();
      } catch (error) {
        errors.add(error);
        request.response.statusCode = 500;
        await request.response.close();
      }
    });
  }

  Mr7SandboxSession session({int cap = 200}) {
    final transport = Mr7LiveGitLab.forTesting(_pat, origin);
    final session = Mr7SandboxSession(
      server: Mr7SyntheticGitLab(),
      liveTransport: transport,
      instance: transport.instance,
      nonce: 'livefixture123',
      requestCap: cap,
    );
    session.writer.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) {
          errors.add(error.error ?? error.type);
          if (error.error is Error) {
            errors.add((error.error as Error).stackTrace!);
          }
          handler.next(error);
        },
      ),
    );
    return session;
  }

  Future<void> close() => http.close(force: true);
}

// Only the fake HTTPS provider origin is mapped onto this loopback listener.
final class _ProviderWire implements HttpClientAdapter {
  _ProviderWire(this.port);
  final int port;
  final HttpClient client = HttpClient();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancellation,
  ) => runZoned(() async {
    final request = await client.openUrl(
      options.method,
      Uri.parse('http://127.0.0.1:$port${options.uri.path}'),
    );
    options.headers.forEach((key, value) {
      if (value != null) request.headers.set(key, value.toString());
    });
    if (stream != null) await request.addStream(stream);
    final response = await request.close();
    final headers = <String, List<String>>{};
    response.headers.forEach((key, value) => headers[key] = value);
    return ResponseBody(
      response.map(Uint8List.fromList),
      response.statusCode,
      headers: headers,
    );
  }, zoneValues: {#flutter.io.allow_http: true});
  @override
  void close({bool force = false}) => client.close(force: force);
}

Map<String, dynamic> _config(String format) => {
  'endpoint': 'https://provider.invalid/v1',
  'format': format,
  'model': 'fixture-model',
  'caps': {'tools': true, 'maxTokens': 2048},
  'maxCost': 1.0,
  'maxCalls': 4,
  'priceInputPerMTok': 1.0,
  'priceOutputPerMTok': 2.0,
};
String _data(Map<String, Object?> value) => 'data: ${jsonEncode(value)}\n\n';

const _rateLimitHeaders = {
  'RateLimit-Name': 'burst_traffic_per_user_free_plan',
  'RateLimit-Limit': '100',
  'RateLimit-Observed': '101',
  'RateLimit-Remaining': '0',
  'RateLimit-Reset': '1761740000',
  'RateLimit-ResetTime': 'Thu, 29 Oct 2026 12:13:20 GMT',
  'Retry-After': '60',
};

/// The sanitised real gitlab.com entity (after deletion scheduling), bound to
/// this fixture's nonce.
Map<String, Object?> _scheduledEntity() =>
    jsonDecode(
          File(
            'test/ai/fixtures/mr7/gitlab_com_project_scheduled_for_deletion.json',
          ).readAsStringSync().replaceAll('testnonce123', 'livefixture123'),
        )
        as Map<String, Object?>;

/// The same real entity before DELETE: original path, no deletion date.
Map<String, Object?> _liveEntity() {
  final row = _scheduledEntity()
    ..remove('marked_for_deletion_on')
    ..remove('marked_for_deletion_at');
  return {
    ...row,
    'name': 'mr7-livefixture123',
    'path': 'mr7-livefixture123',
    'path_with_namespace': 'synthetic-owner/mr7-livefixture123',
  };
}

const _originalPathKey = 'GET projects/synthetic-owner/mr7-livefixture123';

String _providerAnswer(String format, bool tool) {
  const arguments = {
    'projectId': 909,
    'starred': true,
    'reason': 'Synthetic sandbox star requested.',
  };
  if (format == 'chat_completions') {
    return '${_data({
      'choices': [
        {
          'index': 0,
          'delta': {
            'role': 'assistant',
            if (tool) 'tool_calls': [
                {
                  'index': 0,
                  'id': 'server-assigned-17',
                  'type': 'function',
                  'function': {'name': 'setStar', 'arguments': jsonEncode(arguments)},
                },
              ] else 'content': 'Synthetic fixture complete.',
          },
          'finish_reason': tool ? 'tool_calls' : 'stop',
        },
      ],
      'usage': null,
    })}${_data({
      'choices': [],
      'usage': {'prompt_tokens': 100, 'completion_tokens': 20},
    })}data: [DONE]\n\n';
  }
  return _data({
        'type': 'message_start',
        'message': {
          'id': 'message-17',
          'usage': {'input_tokens': 100, 'output_tokens': 1},
        },
      }) +
      _data({
        'type': 'content_block_start',
        'index': 0,
        'content_block': tool
            ? {
                'type': 'tool_use',
                'id': 'server-assigned-17',
                'name': 'setStar',
                'input': <String, Object?>{},
              }
            : {'type': 'text', 'text': ''},
      }) +
      _data({
        'type': 'content_block_delta',
        'index': 0,
        'delta': tool
            ? {
                'type': 'input_json_delta',
                'partial_json': jsonEncode(arguments),
              }
            : {'type': 'text_delta', 'text': 'Synthetic fixture complete.'},
      }) +
      _data({'type': 'content_block_stop', 'index': 0}) +
      _data({
        'type': 'message_delta',
        'delta': {'stop_reason': tool ? 'tool_use' : 'end_turn'},
        'usage': {'output_tokens': 20},
      }) +
      _data({'type': 'message_stop'});
}

void main() {
  for (final boundary in ['accepted', 'cancelled', 'expired']) {
    test('live host confirmation response is $boundary', () async {
      final scratch = await Directory(
        Directory.current.parent.path,
      ).createTemp('mr7-confirm-boundary-');
      addTearDown(() => scratch.delete(recursive: true));
      final patFile = File('${scratch.path}/pat')..writeAsStringSync(_pat);
      final keyFile = File('${scratch.path}/key')..writeAsStringSync(_key);
      expect(
        (await Process.run('chmod', [
          '600',
          patFile.path,
          keyFile.path,
        ])).exitCode,
        0,
      );
      final request = File('${scratch.path}/request');
      final response = File('${scratch.path}/response');
      final host = Mr7LiveHost.fromWrapper({
        'MR7_GITLAB_PAT_FILE': patFile.path,
        'MR7_PROVIDER_KEY_FILE': keyFile.path,
        'MR7_CONFIRM_REQUEST_FILE': request.path,
        'MR7_CONFIRM_RESPONSE_FILE': response.path,
      });
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      final confirmation = host.confirm({
        'operation': 'setStar',
        'tier': 'T1',
        'projectId': 9,
        'payloadDigest': 'a' * 64,
        'preview': 'Synthetic sandbox only.',
      }, deadlineAt: deadline);
      while (!request.existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (boundary == 'cancelled') host.cancel();
      if (boundary == 'expired') {
        // Hold the event loop until the deadline, then place the response before
        // the pending poll resumes: availability must not bypass its deadline.
        final remaining = deadline.difference(DateTime.now());
        if (!remaining.isNegative) {
          sleep(remaining + const Duration(milliseconds: 10));
        }
      }
      response.writeAsStringSync(jsonEncode({'approved': true}));
      if (boundary == 'accepted') {
        expect(await confirmation, isTrue);
      } else {
        await expectLater(
          confirmation,
          throwsA(
            isA<Mr7Refused>().having(
              (error) => error.code,
              'code',
              'confirmationTimeout',
            ),
          ),
        );
        expect(host.typedName, isNull);
      }
      expect(request.existsSync(), isFalse);
      expect(response.existsSync(), isFalse);
    });
  }
  test('live runner refuses a journal override before any request', () async {
    final fixture = _GitLabFixture();
    await fixture.start();
    addTearDown(fixture.close);
    final scratch = await Directory(
      Directory.current.parent.path,
    ).createTemp('mr7-journal-override-');
    addTearDown(() => scratch.delete(recursive: true));
    final session = fixture.session();
    addTearDown(() => session.liveTransport!.close());
    final provider = Mr7LiveProvider(_config('chat_completions'), _key);
    await expectLater(
      runner.runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        confirm: (_) async => false,
        journal: AiWriteJournal(
          keys: MemoryAiJournalKeyStore(),
          applicationSupport: scratch,
        ),
        live: Mr7LiveRun(
          session: session,
          provider: provider,
          secrets: _Secrets(),
          scratchRoot: scratch,
          only: {'b0-star'},
        ),
      ),
      throwsA(
        isA<Mr7Refused>().having(
          (error) => error.code,
          'code',
          'liveJournalOverride',
        ),
      ),
    );
    expect(fixture.requests, isEmpty);
    expect(provider.calls, 0);
    expect(scratch.listSync(), isEmpty);
  });
  provider_tests.liveProviderTests();
  for (final mismatch in ['user', 'namespace']) {
    test('live refuses $mismatch mismatch before any write', () async {
      final fixture = _GitLabFixture();
      await fixture.start();
      addTearDown(fixture.close);
      if (mismatch == 'user') {
        fixture.model.routes['GET user'] = (_) =>
            mr7Json({'id': 8, 'username': 'synthetic-owner'});
      } else {
        fixture.model.routes['GET namespaces'] = (_) => mr7Json([
          {
            'id': 70,
            'full_path': 'synthetic-owner',
            'kind': 'group',
            'owner_id': 7,
          },
        ]);
      }
      final session = fixture.session();
      await expectLater(session.initialize(), throwsA(anything));
      await session.finish();
      expect(session.quarantined, isTrue);
      expect(fixture.requests.where((r) => !r.startsWith('GET ')), isEmpty);
      expect(fixture.model.setupWrites, 0);
    });
  }
  test(
    'live creates private personal project and deletes only its own project',
    () async {
      final fixture = _GitLabFixture();
      await fixture.start();
      addTearDown(fixture.close);
      final session = fixture.session();
      await session.initialize();
      expect(fixture.model.project!['visibility'], 'private');
      expect((fixture.model.project!['namespace'] as Map)['kind'], 'user');
      expect(fixture.setupBodies.single, {
        'name': 'mr7-livefixture123',
        'path': 'mr7-livefixture123',
        'namespace_id': 70,
        'visibility': 'private',
      });
      final firstWrite = fixture.requests.indexOf('POST /api/v4/projects');
      expect(
        fixture.requests.take(firstWrite).where((r) => r.contains('/events')),
        hasLength(2),
      );
      final api = GitLabApi(
        instance: GitLabInstance.parse(session.instance.toString()),
        token: session.gitLabToken,
        dio: session.writer,
      );
      session.permit = Mr7MutationPermit(
        operation: 'setStar',
        paths: {'POST projects/909/star'},
        resourceProjectId: 909,
      )..confirmed = true;
      try {
        await api.setStar(909, true);
      } catch (_) {
        fail('fake wire failure: ${fixture.errors}');
      }
      session.permit = null;
      await session.finish();
      expect(session.cleanup['deletionVerified'], isTrue);
      expect(fixture.requests.where((r) => r.startsWith('DELETE ')), [
        'DELETE /api/v4/projects/909',
      ]);
      expect(fixture.clientPorts.length, greaterThanOrEqualTo(2));
      expect(fixture.requests, contains('GET /api/v4/users/7/projects'));
      expect(fixture.requests, contains('GET /api/v4/projects/909/starrers'));
      expect(fixture.authentication, isNot(contains(_key)));
      expect(fixture.authentication.where((s) => s.isNotEmpty).toSet(), {_pat});
      expect(fixture.errors, isEmpty);
    },
  );
  test(
    'live additional observer reads consume the shared request cap',
    () async {
      final fixture = _GitLabFixture();
      await fixture.start();
      addTearDown(fixture.close);
      final session = fixture.session(cap: 6);
      await expectLater(session.initialize(), throwsA(anything));
      await session.finish();
      expect(session.quarantined, isTrue);
      expect(session.stopReason, 'httpBudget');
      expect(fixture.requests, hasLength(6));
      expect(fixture.requests.where((r) => r.endsWith('/starrers')), isEmpty);
      expect(fixture.requests.where((r) => r.startsWith('DELETE ')), isEmpty);
    },
  );
  test(
    'live incomplete starrers pagination quarantines before mutation',
    () async {
      final fixture = _GitLabFixture()..incompleteStarrers = true;
      await fixture.start();
      addTearDown(fixture.close);
      final session = fixture.session();
      await expectLater(session.initialize(), throwsA(anything));
      await session.finish();
      expect(session.quarantined, isTrue);
      expect(fixture.model.scenarioWrites, 0);
      expect(fixture.requests.where((r) => r.startsWith('DELETE ')), isEmpty);
    },
  );
  test('live cleanup refuses an identity not created by this run', () async {
    final fixture = _GitLabFixture();
    await fixture.start();
    addTearDown(fixture.close);
    final session = fixture.session();
    await session.initialize();
    final owned = session.identity!;
    session.identity = Mr7Identity(
      projectId: 1000,
      path: owned.path,
      userId: owned.userId,
      namespaceId: owned.namespaceId,
      namespace: owned.namespace,
      nonce: owned.nonce,
    );
    await session.finish();
    expect(fixture.requests.where((r) => r.startsWith('DELETE ')), isEmpty);
    expect(session.cleanup['accepted'], isFalse);
  });
  test(
    'live interrupted in-flight mutation quarantines without cleanup',
    () async {
      final fixture = _GitLabFixture();
      await fixture.start();
      addTearDown(fixture.close);
      final session = fixture.session();
      await session.initialize();
      final received = Completer<void>();
      final release = Completer<void>();
      fixture.before = (request) async {
        if (request.uri.path.endsWith('/star')) {
          received.complete();
          await release.future;
        }
      };
      session.permit = Mr7MutationPermit(
        operation: 'setStar',
        paths: {'POST projects/909/star'},
        resourceProjectId: 909,
      )..confirmed = true;
      final pending = session.writer
          .post<Object?>('projects/909/star')
          .then<Object?>((r) => r, onError: (Object e) => e);
      await received.future.timeout(const Duration(seconds: 5));
      session.stop('interrupted');
      release.complete();
      await pending;
      await session.finish();
      expect(session.quarantined, isTrue);
      expect(session.cleanup['status'], 'NOT_RUN');
      expect(fixture.requests.where((r) => r.startsWith('DELETE ')), isEmpty);
    },
  );
  for (final format in ['chat_completions', 'anthropic_messages']) {
    for (final (pendingCleanup, scheduled) in [
      (false, false),
      (true, false),
      (false, true),
    ]) {
      test(
        'live $format full production runner keeps credentials isolated${pendingCleanup ? " with pending cleanup" : ""}${scheduled ? " with scheduled deletion" : ""}',
        () async {
          final fixture = _GitLabFixture();
          fixture.model.delayedDeletion = pendingCleanup;
          fixture.model.scheduledDeletion = scheduled;
          await fixture.start();
          addTearDown(fixture.close);
          final providerHttp = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          addTearDown(() => providerHttp.close(force: true));
          final requests = <String>[];
          providerHttp.listen((request) async {
            final body = await utf8.decoder.bind(request).join();
            final headers = request.headers.toString();
            requests.add('$headers\n$body');
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            request.response.write(
              _providerAnswer(format, requests.length == 1),
            );
            await request.response.close();
          });
          final adapter = _ProviderWire(providerHttp.port);
          addTearDown(() => adapter.close(force: true));
          final scratch = await Directory(
            Directory.current.parent.path,
          ).createTemp('mr7-live-test-');
          addTearDown(() async {
            if (scratch.existsSync()) await scratch.delete(recursive: true);
          });
          final patFile = File('${scratch.path}/pat');
          final keyFile = File('${scratch.path}/key');
          await patFile.writeAsString(_pat);
          await keyFile.writeAsString(_key);
          final chmod = await Process.run('chmod', [
            '600',
            patFile.path,
            keyFile.path,
          ]);
          expect(chmod.exitCode, 0);
          final host = Mr7LiveHost.fromWrapper({
            'MR7_GITLAB_PAT_FILE': patFile.path,
            'MR7_PROVIDER_KEY_FILE': keyFile.path,
            'MR7_CONFIRM_REQUEST_FILE': '${scratch.path}/request',
            'MR7_CONFIRM_RESPONSE_FILE': '${scratch.path}/response',
          });
          final provider = host.createProvider(
            _config(format),
            adapter: adapter,
          );
          final session = fixture.session();
          final receipt = await runner.runMr7Sandbox(
            policy: Mr7Policy.candidate,
            releaseSha: _sha,
            live: Mr7LiveRun(
              session: session,
              provider: provider,
              secrets: _Secrets(),
              only: {'b0-star'},
              scratchRoot: scratch,
            ),
            confirm: (_) async => true,
          );
          expect(
            receipt['status'],
            pendingCleanup ? 'FAIL' : 'PASS',
            reason: '${jsonEncode(receipt)} ${fixture.errors}',
          );
          expect(receipt['evidenceClass'], 'live-candidate');
          expect(receipt['finalEligible'], isFalse);
          expect(receipt['live'], pendingCleanup ? 'FAIL' : 'PASS');
          expect(receipt['quarantined'], pendingCleanup);
          expect(
            (receipt['cleanup'] as Map)['status'],
            pendingCleanup
                ? 'PENDING'
                : scheduled
                ? 'scheduledForDeletion'
                : 'PASS',
          );
          expect(
            (receipt['cleanup'] as Map)['deletionVerified'],
            !pendingCleanup && !scheduled,
          );
          expect(
            (receipt['cleanup'] as Map)['markedForDeletionOn'],
            scheduled ? '2026-10-29' : isNull,
          );
          expect(receipt['releaseSha'], _sha);
          final row = (receipt['scenarios'] as List).single as Map;
          expect(row['live'], 'PASS');
          expect(row['mutationCount'], 1);
          expect(row['readback'], 'PASS');
          expect(provider.calls, greaterThanOrEqualTo(2));
          for (final usage in provider.usage) {
            expect(usage['usageEstimated'], 0);
            expect(usage['inputTokens'], 100);
            expect(usage['outputTokens'], 20);
          }
          expect(requests.join(), isNot(contains(_pat)));
          expect(jsonEncode(receipt), isNot(contains(_pat)));
          expect(jsonEncode(receipt), isNot(contains(_key)));
          expect(fixture.authentication.join(), isNot(contains(_key)));
          expect(fixture.model.cleanupWrites, 1);
        },
      );
    }
  }
  for (final redirect in [true, false]) {
    test('live identity and scheduled cleanup accept the real gitlab.com shape'
        '${redirect ? '' : ' with a 404 original path'}', () async {
      final fixture = _GitLabFixture();
      fixture.model.scheduledDeletion = true;
      fixture.model.routes['GET projects/909'] = (_) => mr7Json(
        fixture.model.cleanupWrites == 0 ? _liveEntity() : _scheduledEntity(),
      );
      // gitlab.com answers the original path with a 301 to the numeric ID.
      fixture.model.routes[_originalPathKey] = (_) =>
          fixture.model.cleanupWrites == 0
          ? mr7Json(_liveEntity())
          : redirect
          ? mr7Json(
              {'message': 'This resource has been moved permanently'},
              status: 301,
              headers: {
                'location': ['https://gitlab.com/api/v4/projects/909'],
              },
            )
          : mr7Json({}, status: 404);
      await fixture.start();
      addTearDown(fixture.close);
      final session = fixture.session();
      await session.initialize();
      expect(session.stopReason, isNull, reason: '${fixture.errors}');
      await session.finish();
      expect(session.stopReason, isNull, reason: '${fixture.errors}');
      expect(session.quarantined, isFalse);
      expect(session.cleanup['status'], 'scheduledForDeletion');
      expect(session.cleanup['deletionVerified'], isFalse);
      expect(session.cleanup['markedForDeletionOn'], '2026-10-29');
      final deleteAt = fixture.requests.indexOf('DELETE /api/v4/projects/909');
      expect(deleteAt, greaterThan(0));
      expect(
        fixture.requests.skip(deleteAt),
        containsAll([
          'GET /api/v4/users/7/projects',
          'GET /api/v4/projects/909',
          'GET /api/v4/projects/synthetic-owner%2Fmr7-livefixture123',
        ]),
      );
      // The redirect is classified, never followed.
      expect(
        fixture.requests
            .skip(deleteAt)
            .where((r) => r == 'GET /api/v4/projects/909'),
        hasLength(1),
      );
      expect(
        fixture.requests.where((r) => r.startsWith('DELETE ')),
        hasLength(1),
      );
      expect(fixture.errors, isEmpty);
    });
  }
  test(
    'live cleanup refuses a redirect of the original path to another project',
    () async {
      for (final location in [
        'https://gitlab.com/api/v4/projects/910',
        'https://gitlab.example/api/v4/projects/909',
      ]) {
        final fixture = _GitLabFixture();
        fixture.model.scheduledDeletion = true;
        fixture.model.routes['GET projects/909'] = (_) => mr7Json(
          fixture.model.cleanupWrites == 0 ? _liveEntity() : _scheduledEntity(),
        );
        fixture.model.routes[_originalPathKey] = (_) =>
            fixture.model.cleanupWrites == 0
            ? mr7Json(_liveEntity())
            : mr7Json(
                {},
                status: 301,
                headers: {
                  'location': [location],
                },
              );
        await fixture.start();
        addTearDown(fixture.close);
        final session = fixture.session();
        await session.initialize();
        await session.finish();
        expect(session.cleanup['status'], 'PENDING', reason: location);
        expect(session.cleanup.containsKey('markedForDeletionOn'), isFalse);
        expect(session.quarantined, isTrue, reason: location);
        expect(fixture.errors, isEmpty, reason: location);
      }
    },
  );
  for (final path in [
    '/api/v4/projects/909',
    '/api/v4/projects/909/starrers',
  ]) {
    test('live 429 on $path stops as rateLimited without Date', () async {
      final fixture = _GitLabFixture()..rateLimitedPaths.add(path);
      await fixture.start();
      addTearDown(fixture.close);
      final session = fixture.session();
      await expectLater(session.initialize(), throwsA(anything));
      await session.finish();
      expect(session.stopReason, 'rateLimited');
      expect(session.quarantined, isTrue);
      expect(session.rateLimit, {
        'status': 429,
        'retryAfter': 60,
        'limit': 100,
        'observed': 101,
        'remaining': 0,
        'reset': 1761740000,
      });
      expect(
        fixture.requests.where((r) => r == 'POST /api/v4/projects'),
        hasLength(1),
      );
      expect(fixture.requests.where((r) => r.startsWith('DELETE ')), isEmpty);
      final receipt = session.receipt(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        scenarios: const [],
        releasePolicy: mr7SandboxPolicy(Mr7Policy.candidate),
      );
      expect(jsonEncode(receipt), isNot(contains('burst_traffic')));
      expect(jsonEncode(receipt), isNot(contains(_pat)));
    });
  }
}
