// Fake-only host entry for the FIX1 process regressions. This is intentionally
// not a *_test.dart: the Python tests launch it as an explicit Flutter CLI.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';

import '../../tool/mr7/live_host.dart';
import '../../tool/mr7/live_run.dart';
import '../../tool/mr7/live_state.dart';
import '../../tool/mr7/live_transport.dart';
import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart' as runner;

const pat = 'synthetic-pat-for-local-gitlab';
const key = 'synthetic-key-for-local-provider';

final class FixtureSecrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => [pat, key];
}

final class ProviderAdapter implements HttpClientAdapter {
  ProviderAdapter(this.port);
  final int port;
  final client = HttpClient();
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
    options.headers.forEach((name, value) {
      if (value != null) request.headers.set(name, value.toString());
    });
    if (stream != null) await request.addStream(stream);
    final response = await request.close();
    final headers = <String, List<String>>{};
    response.headers.forEach((name, value) => headers[name] = value);
    return ResponseBody(
      response.map(Uint8List.fromList),
      response.statusCode,
      headers: headers,
    );
  }, zoneValues: {#flutter.io.allow_http: true});
  @override
  void close({bool force = false}) => client.close(force: force);
}

String answer(bool tool) {
  final delta = <String, Object?>{'role': 'assistant'};
  if (tool) {
    delta['tool_calls'] = [
      {
        'index': 0,
        'id': 'server-assigned-17',
        'type': 'function',
        'function': {
          'name': 'setStar',
          'arguments': jsonEncode({
            'projectId': 909,
            'starred': true,
            'reason': 'Synthetic sandbox star requested.',
          }),
        },
      },
    ];
  } else {
    delta['content'] = 'Synthetic fixture complete.';
  }
  return 'data: ${jsonEncode({
    'choices': [
      {'index': 0, 'delta': delta, 'finish_reason': tool ? 'tool_calls' : 'stop'},
    ],
    'usage': {'prompt_tokens': 100, 'completion_tokens': 20},
  })}\n\ndata: [DONE]\n\n';
}

void main() {
  final config =
      jsonDecode(
            File(
              Platform.environment['MR7_SANDBOX_CONFIG_FILE']!,
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final marker = File(Platform.environment['MR7_FIXTURE_MARKER']!);
  final mode = Platform.environment['MR7_FIXTURE_MODE']!;
  final model = Mr7SyntheticGitLab();
  late HttpServer gitlab;
  late HttpServer provider;
  late ProviderAdapter adapter;
  var providerCalls = 0;
  setUpAll(() async {
    gitlab = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    adapter = ProviderAdapter(provider.port);
    provider.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(answer(++providerCalls == 1));
      await request.response.close();
    });
    gitlab.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final isCreate =
          request.method == 'POST' && request.uri.path == '/api/v4/projects';
      if (isCreate) {
        final saved =
            jsonDecode(
                  File(
                    '${config['stateDirectory']}/run.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        final creation = jsonDecode(body) as Map<String, dynamic>;
        if (saved['projectPath'] !=
                '${saved['namespace']}/${creation['path']}' ||
            saved['nonce'] != config['nonce']) {
          throw StateError('creation was dispatched before durable intent');
        }
      }
      final isStar =
          request.method == 'POST' &&
          request.uri.path == '/api/v4/projects/909/star';
      if (isStar && mode == 'pause-write') {
        await marker.writeAsString('write-dispatched', flush: true);
        await Completer<void>().future;
      }
      final personalList = request.uri.path == '/api/v4/users/7/projects';
      final starrers = request.uri.path == '/api/v4/projects/909/starrers';
      final rows = <Map<String, Object?>>[
        if (model.project?['starred'] == true)
          {
            'user': {'id': 7, 'username': 'synthetic-owner'},
          },
      ];
      final result = starrers
          ? mr7Json(
              rows,
              headers: {
                'x-page': ['1'],
                'x-per-page': ['100'],
                'x-total': ['${rows.length}'],
                'x-total-pages': ['1'],
                'x-next-page': [''],
              },
            )
          : await model.respond(
              RequestOptions(
                path: personalList ? '/api/v4/projects' : request.uri.path,
                method: request.method,
                queryParameters: request.uri.queryParameters,
                data: body.isEmpty ? null : jsonDecode(body),
              ),
            );
      if (isCreate && mode == 'lost-create') {
        await marker.writeAsString(jsonEncode(model.project), flush: true);
        final socket = await request.response.detachSocket();
        socket.destroy();
        return;
      }
      request.response.statusCode = result.statusCode;
      result.headers.forEach(
        (name, value) => request.response.headers.set(name, value),
      );
      request.response.headers.set('date', HttpDate.format(model.serverTime));
      final value = jsonDecode(await utf8.decoder.bind(result.stream).join());
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
    });
  });
  tearDownAll(() async {
    adapter.close(force: true);
    await gitlab.close(force: true);
    await provider.close(force: true);
  });

  runner.registerMr7SandboxHost(
    selectLive: (config) {
      final origin = Uri.parse('http://127.0.0.1:${gitlab.port}');
      final transport = Mr7LiveGitLab.forTesting(pat, origin);
      final host = Mr7LiveHost.fromWrapper(Platform.environment);
      final session = Mr7SandboxSession(
        server: Mr7SyntheticGitLab(),
        liveTransport: transport,
        instance: transport.instance,
        expectedUserId: config['expectedUserId'] as int,
        namespace: config['namespace'] as String,
        nonce: config['nonce'] as String,
      );
      return Mr7LiveRun(
        session: session,
        provider: host.createProvider(
          config['provider'] as Map<String, dynamic>,
          adapter: adapter,
        ),
        secrets: FixtureSecrets(),
        scratchRoot: Directory(config['stateDirectory'] as String),
        state: Mr7LiveState(Directory(config['stateDirectory'] as String)),
        deadlineAt: DateTime.parse(config['deadlineAt'] as String),
        only: {'b0-star'},
        host: host,
      );
    },
  );
}
