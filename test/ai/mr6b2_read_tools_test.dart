import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/field_provenance.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/instance.dart';

import '../support/fake_adapter.dart';

const _root = 'https://example.com:8443/gitlab';
const _secret = '0123456789abcdef0123456789abcdef';
const _target = '/uploads/$_secret/shot.png';
const _description = 'Before\n![shot]($_target "screen")\nComplete tail';

void main() {
  test('production catalogue adds exactly three closed GET tool schemas', () {
    final h = _Harness();
    expect(h.catalogue.specs.map((spec) => spec.name), [
      'read_file',
      'list_directory',
      'get_issue',
      'get_merge_request',
      'get_merge_request_diff',
      'get_pipeline_jobs',
      'get_job_log',
      'get_commit',
      'get_commit_diff',
      'search_project',
      'get_release',
      'get_milestone',
      'get_snippet',
    ]);
    for (final spec in h.catalogue.specs) {
      expect(spec.parameters['additionalProperties'], isFalse);
    }
    final specs = {for (final spec in h.catalogue.specs) spec.name: spec};
    expect(specs['get_release']!.parameters['required'], ['tag_name']);
    expect(specs['get_milestone']!.parameters['required'], ['milestone_id']);
    expect(specs['get_snippet']!.parameters['required'], ['snippet_id']);
  });

  for (final name in _tools) {
    test(
      '$name complete description restores byte-for-byte only in place',
      () async {
        final h = _Harness();
        final execution = await h.read(name);
        expect(execution.result.isError, isFalse);
        expect(execution.provenance.freshness, AiProvenanceFreshness.live);
        expect(execution.result.content, contains('Complete tail'));
        expect(execution.result.uploadPlaceholders, isTrue);
        final token = _token(execution);
        final field = _field(name);
        expect(h.table.seenOnlyCut(field), isFalse);
        final restored = h.table.restoreIntoSameField(
          'After\n![shot]($token "screen")\nComplete tail',
          field,
        );
        expect(restored.policyBlocked, isFalse);
        expect(
          restored.finalText,
          'After\n![shot]($_target "screen")\nComplete tail',
        );
        expect(
          h.table
              .restoreIntoSameField('![shot]($token)', _field(name, id: 8))
              .blockedReasonCode,
          AiTextBlockCode.rereadField,
        );
        expect(
          h.table
              .restoreIntoSameField(
                '![shot]($token)',
                _field(name, project: 10),
              )
              .blockedReasonCode,
          AiTextBlockCode.rereadField,
        );
        final foreign = _field(
          name == 'get_release' ? 'get_snippet' : 'get_release',
        );
        expect(
          h.table
              .restoreIntoSameField('![shot]($token)', foreign)
              .blockedReasonCode,
          AiTextBlockCode.rereadField,
        );
        _expectNoSecrets(execution.result.content);
        expect(execution.result.content, isNot(contains('hidden_metadata')));
      },
    );

    test('$name is safe through all three provider wire encoders', () async {
      final h = _Harness();
      h.description =
          '$_description\n'
          '![foreign](https://other.example/uploads/$_secret/x.png)\n'
          'Literal [[upload:u-99]] and glpat-ABCDEFGHIJKLMNOPQRST';
      final result = (await h.read(name)).result;
      expect(result.isError, isFalse);
      const caps = AiCaps(tokenLimitField: AiTokenLimitField.maxTokens);
      final entry = AppToolResultsEntry([result]);
      for (final wire in [
        const ChatCompletionsFormat(),
        const ResponsesFormat(),
        const AnthropicMessagesFormat(),
      ]) {
        final outgoing = jsonEncode(wire.encodeEntry(entry, caps));
        _expectNoSecrets(outgoing);
        expect(outgoing, isNot(contains('[[upload:u-99]]')));
        expect(outgoing, contains('[[upload:u-1]]'));
        expect(outgoing, isNot(contains('example.com')));
      }
      expect(
        h.table.length,
        1,
        reason: 'Only the own description link is restorable',
      );
    });

    test(
      '$name output clipping blocks a whole-field write until reread',
      () async {
        final h = _Harness()..description = 'Long description. ' * 200;
        final cut = await h.read(
          name,
          budget: AiToolBudget(maxSingleOutputChars: 400),
        );
        expect(cut.result.isError, isFalse);
        expect(cut.truncated, isTrue);
        final field = _field(name);
        expect(h.table.seenOnlyCut(field), isTrue);
        final blocked = _prepare(h.table, field);
        expect(blocked.blockedReasonCode, AiTextBlockCode.fieldTooLong);
        final whole = await h.read(name);
        expect(whole.truncated, isFalse);
        expect(h.table.seenOnlyCut(field), isFalse);
        expect(_prepare(h.table, field).policyBlocked, isFalse);
      },
    );

    test(
      '$name without a placeholder table uses irreversible redaction',
      () async {
        final h = _Harness(placeholders: false);
        final result = (await h.read(name)).result;
        expect(result.isError, isFalse);
        expect(result.uploadPlaceholders, isFalse);
        expect(result.content, isNot(contains('[[upload:')));
        _expectNoSecrets(result.content);
      },
    );

    test('$name reserves OAuth replay worst case before any GET', () async {
      final h = _Harness();
      // A snippet can reread metadata internally and the catalogue can repeat
      // the whole composite once if secret refresh ages it before delivery.
      final cost = name == 'get_snippet' ? 12 : 2;
      final denied = await h.read(
        name,
        budget: AiToolBudget(maxGitLabRequests: cost - 1),
      );
      expect(denied.result.isError, isTrue);
      expect(h.adapter.requests, isEmpty);
      final budget = AiToolBudget(maxGitLabRequests: cost);
      final read = await h.read(name, budget: budget);
      final expectedRequests = name == 'get_snippet' ? 2 : 1;
      expect(read.result.isError, isFalse);
      expect(read.gitLabRequests, expectedRequests);
      expect(budget.gitLabRequests, expectedRequests);
      expect(h.adapter.requests, hasLength(expectedRequests));
      expect(budget.gitLabRequests, h.adapter.requests.length);
      for (final request in h.adapter.requests) {
        expect(request.method, 'GET');
        expect(request.uri.origin, 'https://example.com:8443');
        expect(request.uri.pathSegments.take(5), [
          'gitlab',
          'api',
          'v4',
          'projects',
          '9',
        ]);
      }
    });

    test('$name rejects schema expansion before HTTP', () async {
      final h = _Harness();
      for (final extra in [
        {'project_id': 10},
        {'url': 'https://other.example'},
        {'method': 'DELETE'},
        {'path': 'other'},
      ]) {
        final read = await h.read(name, arguments: {..._args(name), ...extra});
        expect(read.result.isError, isTrue);
      }
      expect(h.adapter.requests, isEmpty);
    });

    test('$name rejects mismatched response identity', () async {
      final h = _Harness()..wrongIdentity = true;
      expect((await h.read(name)).result.isError, isTrue);
      expect(h.table.length, 0);
      expect(h.adapter.requests, hasLength(1));
    });
  }

  test('provenance uses exact tag, numeric milestone ID and snippet ID', () {
    final release = _field('get_release');
    final milestone = _field('get_milestone');
    final snippet = _field('get_snippet');
    expect(release.fieldName, AiWritableField.releaseDescription);
    expect(milestone.fieldName, AiWritableField.milestoneDescription);
    expect(snippet.fieldName, AiWritableField.snippetDescription);
    expect(release.resourceKey.canonical, 'project:9/release:v1');
    expect(milestone.resourceKey.canonical, 'project:9/milestone:7');
    expect(snippet.resourceKey.canonical, 'project:9/snippet:7');
    expect(
      release.resourceWeb.toString(),
      '$_root/group/project/-/releases/v1',
    );
    expect(
      milestone.resourceWeb.toString(),
      '$_root/group/project/-/milestones/2',
    );
    expect(snippet.resourceWeb.toString(), '$_root/group/project/-/snippets/7');
  });

  test(
    'tag and file/ref slashes are encoded as single REST path segments',
    () async {
      final h = _Harness()..tagName = 'release/v1+#?';
      final release = await h.read(
        'get_release',
        arguments: {'tag_name': h.tagName},
      );
      expect(release.result.isError, isFalse);
      expect(h.adapter.requests.single.uri.pathSegments.last, h.tagName);
      final provenance = AiProjectFieldProvenance.releaseDescription(
        instance: GitLabInstance.parse(_root),
        projectId: 9,
        projectPath: 'group/project',
        tagName: h.tagName,
      );
      expect(provenance.resourceWeb!.pathSegments.last, h.tagName);
      expect(provenance.resourceWeb!.hasQuery, isFalse);
      expect(provenance.resourceWeb!.hasFragment, isFalse);
      final snippet = await h.read(
        'get_snippet',
        arguments: {
          'snippet_id': 7,
          'file_path': 'nested/b.txt',
          'ref': 'branch/topic',
        },
      );
      expect(snippet.result.isError, isFalse);
      expect(h.adapter.requests.last.uri.pathSegments.skip(5), [
        'snippets',
        '7',
        'files',
        'branch/topic',
        'nested/b.txt',
        'raw',
      ]);
      expect(snippet.result.content, contains('selected file text'));
      expect(snippet.result.content, isNot(contains('raw_url')));
    },
  );

  test(
    'snippet returns metadata, complete path list and only one source file',
    () async {
      final h = _Harness();
      final read = await h.read('get_snippet');
      expect(read.result.isError, isFalse);
      expect(read.result.content, contains('nested/b.txt'));
      expect(read.result.content, contains('a.txt'));
      expect(read.result.content, contains('selected file text'));
      expect(read.result.content, isNot(contains('raw_url')));
      expect(h.adapter.requests, hasLength(2));
      expect(h.adapter.requests.last.uri.pathSegments.skip(5), [
        'snippets',
        '7',
        'files',
        'HEAD',
        'a.txt',
        'raw',
      ]);
      expect(
        h.table.length,
        1,
        reason: 'File content and title cannot issue placeholders',
      );
      _expectNoSecrets(read.result.content);
    },
  );

  for (final files in <Object?>[null, <Object?>[]]) {
    test(
      'snippet with $files file list keeps metadata without guessing raw content',
      () async {
        final h = _Harness()..files = files;
        final budget = AiToolBudget();
        final read = await h.read('get_snippet', budget: budget);
        expect(read.result.isError, isFalse);
        expect(read.result.content, contains('snippetFileListUnknown'));
        expect(read.result.content, contains('[[upload:u-1]]'));
        expect(h.adapter.requests, hasLength(1));
        expect(read.gitLabRequests, 1);
        expect(budget.gitLabRequests, 1);
        expect(budget.gitLabRequests, h.adapter.requests.length);
      },
    );
  }

  test(
    'snippet missing selected file keeps metadata and never reads a different file',
    () async {
      final h = _Harness();
      final read = await h.read(
        'get_snippet',
        arguments: {'snippet_id': 7, 'file_path': 'missing.txt'},
      );
      expect(read.result.content, contains('snippetFileNotFound'));
      expect(h.adapter.requests, hasLength(1));
    },
  );

  test('snippet sensitive file has no source GET', () async {
    final h = _Harness()
      ..files = [
        {'path': '.env'},
      ];
    final read = await h.read('get_snippet');
    expect(read.result.content, contains('sensitivePath'));
    expect(h.adapter.requests, hasLength(1));
  });

  for (final visibility in ['private', 'internal', 'public', null]) {
    test(
      'snippet $visibility visibility keeps restricted-source read flags',
      () async {
        final h = _Harness()..visibility = visibility;
        final result = (await h.read('get_snippet')).result;
        expect(result.isError, isFalse);
        expect(
          result.readConfidential,
          visibility == 'private' || visibility == null,
        );
        expect(result.readInternal, visibility == 'internal');
      },
    );
  }

  for (final files in <Object?>[
    'invalid',
    [null],
    [
      {'raw_url': 'https://other.example'},
    ],
    [
      {'path': '../outside'},
    ],
    [
      {'path': 'dir/'},
    ],
    [
      {'path': 'dir//a.txt'},
    ],
    [
      {'path': 'dir/./a.txt'},
    ],
    [
      {'path': ' a.txt'},
    ],
    [
      {'path': 'a.txt'},
      {'path': 'a.txt'},
    ],
  ]) {
    test(
      'snippet rejects malformed file list $files before content GET',
      () async {
        final h = _Harness()..files = files;
        expect((await h.read('get_snippet')).result.isError, isTrue);
        expect(h.adapter.requests, hasLength(1));
        expect(h.table.length, 0);
      },
    );
  }

  test('resource identifiers are validated before HTTP', () async {
    final h = _Harness();
    for (final args in [
      {'tag_name': ''},
      {'tag_name': '..'},
      {'tag_name': 'v1\n'},
      {'tag_name': 7},
    ]) {
      expect(
        (await h.read('get_release', arguments: args)).result.isError,
        isTrue,
      );
    }
    for (final value in [null, '7', 0, -1, 1.5]) {
      expect(
        (await h.read(
          'get_milestone',
          arguments: {'milestone_id': value},
        )).result.isError,
        isTrue,
      );
      expect(
        (await h.read(
          'get_snippet',
          arguments: {'snippet_id': value},
        )).result.isError,
        isTrue,
      );
    }
    for (final extra in [
      {'file_path': ''},
      {'file_path': '../outside'},
      {'file_path': 'dir/'},
      {'file_path': 'dir//a.txt'},
      {'file_path': 'dir/./a.txt'},
      {'ref': '..'},
      {'ref': null},
      {'file_path': null},
    ]) {
      expect(
        (await h.read(
          'get_snippet',
          arguments: {'snippet_id': 7, ...extra},
        )).result.isError,
        isTrue,
      );
    }
    expect(h.adapter.requests, isEmpty);
  });

  test(
    'relative and absolute own upload targets round trip in each description',
    () async {
      for (final name in _tools) {
        final h = _Harness()
          ..description =
              '[absolute]($_root/group/project/uploads/$_secret/shot.png) '
              '[relative](../../uploads/$_secret/shot.png)';
        final read = await h.read(name);
        expect(read.result.isError, isFalse);
        _expectNoSecrets(read.result.content);
        final tokens = RegExp(r'\[\[upload:u-\d+\]\]')
            .allMatches(read.result.plainData.plainText)
            .map((match) => match.group(0)!)
            .toList();
        expect(tokens, hasLength(2));
        final restored = h.table.restoreIntoSameField(
          '[absolute](${tokens[0]}) [relative](${tokens[1]})',
          _field(name),
        );
        expect(restored.finalText, h.description);
      }
    },
  );
}

const _tools = ['get_release', 'get_milestone', 'get_snippet'];

Map<String, Object?> _args(String name) => switch (name) {
  'get_release' => {'tag_name': 'v1'},
  'get_milestone' => {'milestone_id': 7},
  _ => {'snippet_id': 7},
};

AiFieldProvenance _field(String name, {int id = 7, int project = 9}) {
  final instance = GitLabInstance.parse(_root);
  return switch (name) {
    'get_release' => AiProjectFieldProvenance.releaseDescription(
      instance: instance,
      projectId: project,
      projectPath: 'group/project',
      tagName: id == 7 ? 'v1' : 'v$id',
    ),
    'get_milestone' => AiProjectFieldProvenance.milestoneDescription(
      instance: instance,
      projectId: project,
      projectPath: 'group/project',
      milestoneId: id,
      milestoneIid: 2,
    ),
    _ => AiProjectFieldProvenance.snippetDescription(
      instance: instance,
      projectId: project,
      projectPath: 'group/project',
      snippetId: id,
    ),
  };
}

AiTextOutcome _prepare(UploadPlaceholderTable table, AiFieldProvenance field) =>
    prepareWriteText(
      textClass: AiTextClass.plainContent,
      modelText: 'Updated description',
      field: field,
      placeholders: table,
      knownSecrets: const {},
      aiAttribution: false,
      visibility: const AiVisibilityContext(targetProjectPath: 'group/project'),
    );

String _token(AiToolExecution execution) => RegExp(
  r'\[\[upload:u-\d+\]\]',
).firstMatch(execution.result.plainData.plainText)!.group(0)!;

void _expectNoSecrets(String outgoing) {
  expect(outgoing, isNot(contains(_secret)));
  expect(outgoing, isNot(contains('glpat-ABCDEFGHIJKLMNOPQRST')));
}

final class _Secrets implements KnownSecretsSource {
  const _Secrets();
  @override
  Iterable<String> get current => const [];
}

final class _Harness {
  _Harness({bool placeholders = true}) {
    final api = testApi(adapter, host: _root);
    addTearDown(api.close);
    catalogue = AiToolCatalogue(
      port: GitLabAiReadPort(api, 9),
      scope: const AiResourceScope(
        accountKey: '$_root#7',
        instanceKey: _root,
        projectId: 9,
        projectPath: 'group/project',
        current: AiResourceRef(kind: AiResourceKind.issue, id: 3),
      ),
      redactor: Redactor(secrets: const _Secrets()),
      placeholders: placeholders ? table : null,
    );
  }

  String description = _description;
  String tagName = 'v1';
  String? visibility = 'private';
  bool wrongIdentity = false;
  Object? files = [
    {'path': 'a.txt', 'raw_url': 'https://other.example/never-fetch'},
    {'path': 'nested/b.txt'},
  ];
  final table = UploadPlaceholderTable(instance: GitLabInstance.parse(_root));
  late final adapter = FakeAdapter(_respond);
  late final AiToolCatalogue catalogue;

  ResponseBody _respond(RequestOptions request) {
    final path = request.uri.pathSegments.skip(5).toList();
    if (path.length == 2 && path[0] == 'releases') {
      return jsonResponse({
        'tag_name': wrongIdentity ? 'foreign' : tagName,
        'name': 'Release $_target',
        'description': description,
        'assets': {'secret': 'hidden_metadata'},
      });
    }
    if (path.length == 2 && path[0] == 'milestones') {
      return jsonResponse({
        'id': 7,
        'iid': 2,
        'project_id': wrongIdentity ? 10 : 9,
        'title': 'Milestone',
        'description': description,
        'secret': 'hidden_metadata',
      });
    }
    if (path.length == 2 && path[0] == 'snippets') {
      return jsonResponse({
        'id': wrongIdentity ? 8 : 7,
        'project_id': 9,
        'title': 'Snippet $_target',
        'description': description,
        'visibility': visibility,
        'file_name': 'a.txt',
        'files': files,
        'secret': 'hidden_metadata',
      });
    }
    if (path.length == 6 && path[0] == 'snippets' && path[2] == 'files') {
      return ResponseBody.fromString(
        'selected file text\n[upload]($_target)',
        200,
      );
    }
    throw StateError('Unexpected fake endpoint');
  }

  Future<AiToolExecution> read(
    String name, {
    Map<String, Object?>? arguments,
    AiToolBudget? budget,
  }) => catalogue.execute(
    AiToolCall(
      id: 'call-$name',
      name: name,
      arguments: arguments ?? _args(name),
    ),
    budget: budget ?? AiToolBudget(),
  );
}
