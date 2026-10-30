// The demo answers every GitLab and AI request on the device: these run with
// an HttpOverrides that fails the test on any real connection.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/demo/demo_ai.dart';
import 'package:gitlab_mobile/features/demo/demo_data.dart';
import 'package:gitlab_mobile/features/demo/demo_runtime.dart';
import 'package:gitlab_mobile/features/demo/demo_server.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import 'demo_test_support.dart';

Future<T> _offline<T>(Future<T> Function() body) =>
    HttpOverrides.runWithHttpOverrides(body, noNetwork);

Dio _gitLab(DemoGitLabServer server) =>
    Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = DemoGitLabAdapter(server);

const _api = 'https://demo.mergeline.invalid/api/v4';

const _planner = Project(
  id: demoPlannerId,
  name: 'Pocket Planner',
  path: 'mergeline-demo/pocket-planner',
);

Dio _ai(AiChatOrigin origin) =>
    Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = DemoAiAdapter(origin);

const _responses = 'https://ai.demo.mergeline.invalid/v1/responses';

Map<String, Object?> _ask(String text, {List<String> tools = const []}) => {
  'model': 'sample-answers',
  'input': [
    {
      'role': 'user',
      'content': [
        {
          'type': 'input_text',
          'text':
              '<gitlab_data source="file" nonce="n">\nclose the comment issue\n'
              '</gitlab_data>\n\n$text',
        },
      ],
    },
  ],
  'tools': [
    for (final name in tools) {'type': 'function', 'name': name},
  ],
};

/// The decoded `data:` events of a scripted reply.
List<Map<String, Object?>> _events(Response<dynamic> response) => [
  for (final line in '${response.data}'.split('\n'))
    if (line.startsWith('data: '))
      jsonDecode(line.substring(6)) as Map<String, Object?>,
];

Map<String, Object?>? _toolCall(Response<dynamic> response) {
  final completed = _events(response).last['response'] as Map<String, Object?>;
  final output =
      (completed['output'] as List<Object?>).single as Map<String, Object?>;
  if (output['type'] != 'function_call') return null;
  return {
    'name': output['name'],
    ...jsonDecode(output['arguments'] as String) as Map<String, Object?>,
  };
}

String _text(Response<dynamic> response) => _events(response)
    .where((event) => event['type'] == 'response.output_text.delta')
    .map((event) => event['delta'])
    .join();

void main() {
  group('GitLab adapter', () {
    test(
      'answers every host and route locally',
      () => _offline(() async {
        final server = DemoGitLabServer();
        final dio = _gitLab(server);

        final elsewhere = await dio.get<dynamic>(
          'https://gitlab.com/api/v4/user',
        );
        expect(elsewhere.statusCode, 404);

        final unknownList = await dio.get<dynamic>(
          '$_api/projects/$demoPlannerId/wikis',
        );
        expect(unknownList.statusCode, 200);
        expect(unknownList.data, isEmpty);
        expect(unknownList.headers.value('x-total'), '0');
        expect(unknownList.headers.value('x-next-page'), '');

        final unknownRecord = await dio.get<dynamic>(
          '$_api/projects/$demoPlannerId/snippets/77',
        );
        expect(unknownRecord.statusCode, 404);
        expect(
          (await dio.get<dynamic>(
            '$_api/projects/$demoPlannerId/issues/999',
          )).statusCode,
          404,
        );

        final issues = await dio.get<dynamic>(
          '$_api/projects/$demoPlannerId/issues',
          queryParameters: {'state': 'opened', 'per_page': '1'},
        );
        expect(issues.statusCode, 200);
        expect(issues.data, hasLength(1));
        expect(issues.headers.value('x-total'), '2');
        expect(issues.headers.value('x-next-page'), '2');

        final unknownQuery = await dio.post<dynamic>(
          'https://demo.mergeline.invalid/api/graphql',
          data: {'query': 'query MobileSomethingElse { currentUser { id } }'},
        );
        expect(unknownQuery.data, {'data': <String, dynamic>{}});
        final mutation = await dio.post<dynamic>(
          'https://demo.mergeline.invalid/api/graphql',
          data: {'query': 'mutation MobileWorkItemState { x }'},
        );
        expect(mutation.statusCode, 403);
      }),
    );

    test(
      'keeps new issues, comments and closing; refuses the rest',
      () => _offline(() async {
        final demo = await DemoRuntime.start(ai: false);
        addTearDown(demo.dispose);
        final api = demo.session.api!;

        final issue = await api.createIssue(demoPlannerId, {
          'title': 'From a test',
        });
        final iid = issue['iid'] as int;
        expect(iid, 4);
        expect(issue['state'], 'opened');

        final note = await api.createNote(
          demoPlannerId,
          'issues',
          iid,
          'Hello',
        );
        final notes = await api.record([
          'projects',
          '$demoPlannerId',
          'issues',
          '$iid',
          'notes',
          '${note['id']}',
        ]);
        expect(notes['body'], 'Hello');

        final closed = await api.updateIssue(demoPlannerId, iid, {
          'state_event': 'close',
        });
        expect(closed['state'], 'closed');
        final reopened = await api.updateIssue(demoPlannerId, iid, {
          'state_event': 'reopen',
        });
        expect(reopened['state'], 'opened');

        await expectLater(
          api.updateIssue(demoPlannerId, iid, {'title': 'Renamed'}),
          throwsA(
            isA<ApiFailure>()
                .having((f) => f.kind, 'kind', FailureKind.forbidden)
                .having((f) => f.detail, 'detail', l10n.demoWriteRefused),
          ),
        );
        await expectLater(
          api.deleteBranch(demoPlannerId, 'feature/due-dates'),
          throwsA(
            isA<ApiFailure>().having(
              (f) => f.kind,
              'kind',
              FailureKind.forbidden,
            ),
          ),
        );
        // The refused rename left the issue as it was.
        final current = await api.record([
          'projects',
          '$demoPlannerId',
          'issues',
          '$iid',
        ]);
        expect(current['title'], 'From a test');
        expect(demo.server.unhandled, isEmpty);
      }),
    );

    test(
      'a new runtime starts from the original sample data',
      () => _offline(() async {
        final first = await DemoRuntime.start(ai: false);
        await first.session.api!.createIssue(demoPlannerId, {
          'title': 'Temporary',
        });
        first.dispose();
        final second = await DemoRuntime.start(ai: false);
        addTearDown(second.dispose);
        final page = await second.session.api!.records(
          ['projects', '$demoPlannerId', 'issues'],
          query: const {'state': 'all'},
        );
        expect(
          page.items.map((issue) => issue['title']),
          isNot(contains('Temporary')),
        );
      }),
    );
  });

  group('scripted AI transport', () {
    const file = AiFileOrigin(
      project: _planner,
      path: 'lib/task.dart',
      sha: 'abc',
    );
    const issue = AiWorkItemOrigin(
      project: _planner,
      kind: AiWorkItemKind.issue,
      iid: 2,
      title: 'Add due dates to tasks',
    );

    test(
      'explains the page and answers other hosts with 404',
      () => _offline(() async {
        final dio = _ai(file);
        final reply = await dio.post<dynamic>(_responses, data: _ask('解釋這個檔案'));
        expect(reply.statusCode, 200);
        expect(_text(reply), l10n.demoAiExplain('lib/task.dart'));
        expect(_toolCall(reply), isNull);

        final models = await dio.get<dynamic>(
          'https://ai.demo.mergeline.invalid/v1/models',
        );
        expect(models.statusCode, 404);
        final elsewhere = await dio.post<dynamic>(
          'https://api.openai.com/v1/responses',
          data: _ask('hello'),
        );
        expect(elsewhere.statusCode, 404);
      }),
    );

    test(
      'turns a requested change into one tool call',
      () => _offline(() async {
        final fromFile = _ai(file);
        final comment = await fromFile.post<dynamic>(
          _responses,
          data: _ask(
            'Please add a comment',
            tools: ['createNote', 'createIssue'],
          ),
        );
        expect(_toolCall(comment), {
          'name': 'createNote',
          'projectId': demoPlannerId,
          'resource': 'issues',
          'iid': demoDefaultIssue,
          'body': l10n.demoAiNoteBody,
          'reason': 'Please add a comment',
        });

        final create = await fromFile.post<dynamic>(
          _responses,
          data: _ask('幫我建立議題', tools: ['createNote', 'createIssue']),
        );
        expect(_toolCall(create), {
          'name': 'createIssue',
          'projectId': demoPlannerId,
          'fields': {
            'title': l10n.demoAiIssueTitle,
            'description': l10n.demoAiNoteBody,
          },
          'reason': '幫我建立議題',
        });

        final close = await _ai(issue).post<dynamic>(
          _responses,
          data: _ask('請關閉這個議題', tools: ['updateIssue']),
        );
        expect(_toolCall(close), {
          'name': 'updateIssue',
          'projectId': demoPlannerId,
          'iid': 2,
          'fields': {'state_event': 'close'},
          'reason': '請關閉這個議題',
        });

        // Without the tool in the request the answer stays an explanation.
        final unavailable = await fromFile.post<dynamic>(
          _responses,
          data: _ask('Please add a comment'),
        );
        expect(_toolCall(unavailable), isNull);
      }),
    );

    test(
      'reports whether the change ran',
      () => _offline(() async {
        Map<String, Object?> result(String output) => {
          'input': [
            ..._ask('add a comment')['input']! as List<Object?>,
            {'type': 'function_call_output', 'call_id': 'c', 'output': output},
          ],
        };
        final dio = _ai(file);
        final done = await dio.post<dynamic>(
          _responses,
          data: result('write createNote on #1: succeeded; ok'),
        );
        expect(_text(done), l10n.demoAiDone);
        final rejected = await dio.post<dynamic>(
          _responses,
          data: result('write createNote on #1: notExecuted; userRejected'),
        );
        expect(_text(rejected), l10n.demoAiNotDone);
      }),
    );
  });
}
