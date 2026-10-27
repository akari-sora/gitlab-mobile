import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 20);

final class _Secrets implements KnownSecretsSource {
  const _Secrets();

  @override
  Iterable<String> get current => const [];
}

void main() {
  for (final resource in ['issues', 'merge_requests']) {
    for (final scenario in const [
      (failReread: false, deliveryDelay: false),
      (failReread: true, deliveryDelay: false),
      (failReread: false, deliveryDelay: true),
    ]) {
      test(
        'provider $resource payload ${scenario.failReread ? 'fails closed' : 'uses the reread'} when ${scenario.deliveryDelay ? 'delivery' : 'notes'} crosses 60 seconds',
        () async {
          var now = DateTime.utc(2026, 10, 23, 12);
          var metadataReads = 0;
          final adapter = FakeAdapter((request) {
            if (request.uri.path.endsWith('/notes')) {
              if (!scenario.deliveryDelay) {
                now = now.add(const Duration(seconds: 2));
              }
              return jsonResponse(<Object?>[]);
            }
            metadataReads++;
            if (scenario.failReread && metadataReads > 1) {
              throw DioException(
                requestOptions: request,
                type: DioExceptionType.connectionError,
              );
            }
            return jsonResponse({
              'iid': 4,
              'title': metadataReads == 1
                  ? 'stale provider title'
                  : 'fresh title',
            });
          });
          final api = GitLabApi(
            instance: GitLabInstance.parse('https://example.com/gitlab'),
            token: 'synthetic-test-token',
            dio: Dio()..httpClientAdapter = adapter,
            readCacheClock: () => now,
          );
          api.bindReadCache('${api.instance.key}#7', 1);
          addTearDown(api.close);
          await api
              .cachedRecord(['projects', '9', resource, '4'])
              .timeout(_deadline);
          now = now.add(const Duration(seconds: 59));

          final catalogue = AiToolCatalogue(
            // Keep provider delivery checks on the synthetic cache timeline.
            port: GitLabAiReadPort(api, 9, now: () => now),
            scope: const AiResourceScope(
              accountKey: 'https://example.com/gitlab#7',
              instanceKey: 'https://example.com/gitlab',
              projectId: 9,
              projectPath: 'group/project',
              current: AiResourceRef(kind: AiResourceKind.issue, id: 3),
            ),
            redactor: Redactor(secrets: const _Secrets()),
            now: () => now,
            refreshSecrets: scenario.deliveryDelay
                ? () async {
                    now = now.add(const Duration(seconds: 2));
                  }
                : null,
          );
          const caps = AiCaps(
            tokenLimitField: AiTokenLimitField.maxTokens,
            toolChoice: true,
          );
          const config = AiProviderConfig(
            id: 'provider',
            name: 'Synthetic',
            presetId: 'custom',
            baseUrl: 'https://provider.example/v1',
            format: AiFormat.chatCompletions,
            model: 'synthetic',
            authStyle: AiAuthStyle.bearer,
            caps: caps,
            allowLanCleartext: false,
            toolsEnabled: true,
            recipientRevision: 1,
          );
          const wire = ChatCompletionsFormat();
          final payloads = <String>[];
          var modelCalls = 0;
          final owner = Object();
          final budget = AiToolBudget();
          final runner = AiRunner(
            appInForeground: () => true,
            config: config,
            wire: wire,
            complete: (plan, {void Function(AiEvent)? onEvent}) async {
              payloads.add(wire.encodeJson(plan, caps));
              modelCalls++;
              final calls = modelCalls == 1
                  ? [
                      AiToolCall(
                        id: 'call-1',
                        name: resource == 'issues'
                            ? 'get_issue'
                            : 'get_merge_request',
                        arguments: {'iid': 4},
                      ),
                    ]
                  : const <AiToolCall>[];
              return AiDecodedTurn(
                ProviderOutputEntry(AiFormat.chatCompletions, <String, Object?>{
                  'role': 'assistant',
                  'content': calls.isEmpty ? 'done' : '',
                  if (calls.isNotEmpty)
                    'tool_calls': [
                      for (final call in calls)
                        {
                          'id': call.id,
                          'type': 'function',
                          'function': {
                            'name': call.name,
                            'arguments': jsonEncode(call.arguments),
                          },
                        },
                    ],
                }, toolCalls: calls),
                AiStopReason.endTurn,
                null,
              );
            },
            secrets: const _Secrets(),
            refreshSecrets: () async {},
            guard: AiRunGuard(
              expectedGeneration: 1,
              ownerApi: owner,
              generation: () => 1,
              api: () => owner,
              recipientRevision: () => 1,
              consentValid: () => true,
            ),
            system: 'Synthetic system prompt.',
            close: () {},
            cancelActive: () {},
            tools: catalogue.specs,
            executeTool: (call) =>
                catalogue.executeResult(call, budget: budget),
          );
          final result = await runner
              .run('Read resource four')
              .timeout(_deadline);

          expect(result.reason, AiRunEnd.done);
          expect(payloads, hasLength(2));
          expect(payloads.last, isNot(contains('stale provider title')));
          if (scenario.failReread) {
            expect(payloads.last, contains('read failed'));
          } else {
            expect(payloads.last, contains('fresh title'));
          }
          expect(metadataReads, 2);
        },
      );
    }
  }
}
