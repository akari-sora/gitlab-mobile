import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';
import 'package:gitlab_mobile/core/ai/prompts.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';

import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart';

const _sha = '0123456789abcdef0123456789abcdef01234567';
const _attachmentHostText = [
  'Synthetic system.',
  'Upload a synthetic file.',
  'Acknowledged.',
  'Uploaded.',
  'The user asked for an upload.',
];

Mr7SandboxSession _session(Mr7SyntheticGitLab server) => Mr7SandboxSession(
  server: server,
  nonce: 'wave2testnonce',
  requestCap: 300,
  eventDelay: () async {},
);

List<Map<String, Object?>> _rows(Map<String, Object?> receipt) =>
    (receipt['scenarios']! as List).cast<Map<String, Object?>>();

Map<String, Object?> _attachmentWireBody(
  WireFormatBase wire,
  String projection, {
  Object? arguments = const <String, Object?>{},
  String result = 'Uploaded.',
}) {
  final segment = AiSegment(
    providerId: 'synthetic',
    recipientRevision: 1,
    format: wire.format,
    model: 'synthetic-model',
    secretSetAtStart: SecretSetId.fromSecrets([]),
  )..setTail(AppUserEntry(text: projection));
  final caps = AiCaps(
    tokenLimitField: AiTokenLimitField.maxTokens,
    toolChoice: true,
  );
  final plan = AiRequestPlan(
    model: 'synthetic-model',
    system: 'Synthetic system.',
    segment: segment,
    tools: [
      AiToolSpec(
        name: 'upload_attachment',
        description: 'Upload a synthetic file.',
        parameters: {
          'type': 'object',
          'properties': {
            'role': {
              'type': 'string',
              'enum': ['user', 'assistant', 'input_text', 'upload_attachment'],
            },
          },
          'required': ['role'],
        },
      ),
    ],
  );
  wire.encode(plan, caps);
  final call = AiToolCall(
    id: 'assistant',
    name: 'upload_attachment',
    arguments: arguments,
  );
  final function = {'name': call.name, 'arguments': jsonEncode(arguments)};
  final raw = switch (wire.format) {
    AiFormat.responses => [
      {
        'type': 'function_call',
        'id': 'user',
        'call_id': call.id,
        ...function,
        'status': 'completed',
      },
    ],
    AiFormat.chatCompletions => {
      'role': 'assistant',
      'content': 'Acknowledged.',
      'tool_calls': [
        {'id': call.id, 'type': 'function', 'function': function},
      ],
    },
    AiFormat.anthropicMessages => [
      {
        'type': 'tool_use',
        'id': call.id,
        'name': call.name,
        'input': arguments,
      },
    ],
  };
  segment.freezeWith(
    ProviderOutputEntry(wire.format, raw, toolCalls: [call]),
    (entry) => wire.encodeEntry(entry, caps),
  );
  segment.setTail(
    AppToolResultsEntry([
      AiToolResult(callId: call.id, name: call.name, content: result),
    ]),
  );
  return wire.encode(plan, caps);
}

Mr7Scenario _star(
  String id, {
  Future<Mr7ScenarioFixtures> Function(Mr7SandboxSession, Mr7Identity)? fixture,
  List<Mr7SnapshotSpec> Function(Mr7Identity)? preRead,
}) => Mr7Scenario(
  id: id,
  suite: 'rest',
  operation: 'setStar',
  variant: id,
  tier: 'T1',
  fixture: fixture,
  preRead: preRead,
  utterance: (p) => 'Star the synthetic project ${p.path}.',
  call: (p) => AiToolCall(
    id: id,
    name: 'setStar',
    arguments: {
      'projectId': p.projectId,
      'starred': true,
      'reason': 'Synthetic sandbox star requested.',
    },
  ),
  paths: (p) => {'POST projects/${p.projectId}/star'},
  observe: (observer, p) async =>
      (await observer.read('projects/${p.projectId}'))['starred'] == true,
);

Mr7Scenario _deleteNote(String id, {Set<AiTargetKind>? targetKinds}) =>
    Mr7Scenario(
      id: id,
      suite: 'rest',
      operation: 'deleteNote',
      variant: id,
      tier: 'T4',
      targetKind: AiTargetKind.note,
      targetKinds: targetKinds,
      utterance: (p) => 'Delete #note_71 from issue #3 in ${p.path}.',
      resource: (_) => const AiResourceRef(kind: AiResourceKind.issue, id: 3),
      call: (p) => AiToolCall(
        id: id,
        name: 'deleteNote',
        arguments: {
          'projectId': p.projectId,
          'resource': 'issues',
          'iid': 3,
          'noteId': 71,
          'reason': 'The user explicitly requested deletion.',
        },
      ),
      paths: (p) => {'DELETE projects/${p.projectId}/issues/3/notes/71'},
      readbackPaths: (p, _) => {'projects/${p.projectId}/issues/3'},
      observe: (_, _) async => false,
    );

void _deleteFixtures(Mr7SyntheticGitLab server) {
  server.routes['GET projects/909/issues/3'] = (_) =>
      mr7Json({'id': 300, 'iid': 3, 'project_id': 909, 'confidential': false});
  server.routes['GET projects/909/issues/3/notes/71'] = (_) => mr7Json({
    'id': 71,
    'project_id': 909,
    'noteable_id': 300,
    'body': 'Synthetic fixture.',
    'author': {'id': 7, 'username': 'synthetic-owner'},
  });
  server.routes['DELETE projects/909/issues/3/notes/71'] = (_) {
    server.scenarioWrites++;
    server.addEvent(target: 909);
    return mr7Json({}, status: 204);
  };
}

Mr7Scenario _createNote(Mr7SyntheticGitLab server) {
  Map<String, Object?>? note;
  server.routes['GET projects/909/issues/3'] = (_) => mr7Json({
    'id': 300,
    'iid': 3,
    'project_id': 909,
    'title': 'Synthetic issue',
    'description': 'Synthetic issue description',
    'updated_at': '2026-10-29T00:00:00.000Z',
    'confidential': false,
    'state': 'opened',
  });
  server.routes['POST projects/909/issues/3/notes'] = (request) {
    final body = request.data as Map;
    note = {
      'id': 72,
      'project_id': 909,
      'body': body['body'],
      'author': {'id': 7},
    };
    server.scenarioWrites++;
    server.addEvent(target: 909);
    return mr7Json(note, status: 201);
  };
  server.routes['GET projects/909/issues/3/notes/72'] = (_) => mr7Json(note);
  return Mr7Scenario(
    id: 'edit-note',
    suite: 'rest',
    operation: 'createNote',
    variant: 'edited',
    tier: 'T2',
    targetKind: AiTargetKind.issue,
    resource: (_) => const AiResourceRef(kind: AiResourceKind.issue, id: 3),
    utterance: (p) => 'Write a synthetic note on issue #3 in ${p.path}.',
    call: (p) => AiToolCall(
      id: 'edit-note',
      name: 'createNote',
      arguments: {
        'projectId': p.projectId,
        'resource': 'issues',
        'iid': 3,
        'body': 'Original synthetic note.',
        'reason': 'User asked for a synthetic note.',
      },
    ),
    paths: (p) => {'POST projects/${p.projectId}/issues/3/notes'},
    readbackPaths: (p, _) => {'projects/${p.projectId}/issues/3/notes/72'},
    observe: (observer, p) async =>
        (await observer.read(
          'projects/${p.projectId}/issues/3/notes/72',
        ))['body'] ==
        'Edited synthetic note.',
  );
}

final class _CaptureWorkItemQuery implements HttpClientAdapter {
  Map<String, Object?>? request;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    request = Map<String, Object?>.from(options.data as Map);
    return mr7Json({'data': <String, Object?>{}});
  }

  @override
  void close({bool force = false}) {}
}

final class _MemoryPicker implements AttachmentPicker {
  const _MemoryPicker();
  @override
  Future<PickedAttachment?> pickFile() async => null;
  @override
  Future<PickedAttachment?> pickImage() async => null;
}

Future<void> _seedJournal(
  AiWriteJournal journal,
  String account,
  int index,
  String conversation,
) async {
  final draft = AiJournalDraft(
    executionId: 'seed-$index',
    accountKey: account,
    conversationId: conversation,
    runId: 'seed-run-$index',
    operationId: 'setStar',
    writeKeys: {
      AiConflictKey([account, 'project:909', 'seed:$index']),
    },
    payloadSha256: 'a' * 64,
    releaseName: 'synthetic',
    instance: 'https://gitlab.invalid/install',
    confirmed: true,
  );
  await journal.prepare(draft: draft);
  await journal.markDispatching(executionId: draft.executionId);
  await journal.finish(
    executionId: draft.executionId,
    terminal: AiJournalState.succeeded,
  );
}

void main() {
  test('runner admits the exact production project WorkItem query', () async {
    final server = Mr7SyntheticGitLab();
    server.routes['GET projects/909/issues/3'] = (_) =>
        mr7Json({'id': 300, 'iid': 3, 'project_id': 909});
    var graphReads = 0;
    server.routes['POST /install/api/graphql'] = (request) {
      graphReads++;
      final data = request.data as Map;
      final path = (data['variables'] as Map)['path'];
      final project = {'id': 'gid://gitlab/Project/909', 'fullPath': path};
      return mr7Json({
        'data': {
          'project': {
            ...project,
            'workItems': {
              'pageInfo': {'hasNextPage': false, 'endCursor': null},
              'nodes': [
                {
                  'id': 'gid://gitlab/WorkItem/300',
                  'iid': '3',
                  'title': 'Work item fixture',
                  'state': 'OPEN',
                  'createdAt': '2026-09-01T01:02:03Z',
                  'updatedAt': '2026-09-02T03:04:05Z',
                  'webUrl':
                      'https://gitlab.invalid/install/$path/-/work_items/3',
                  'project': project,
                  'namespace': {
                    'id': 'gid://gitlab/Namespaces::ProjectNamespace/909',
                    'fullPath': path,
                  },
                  'workItemType': {
                    'id': 'gid://gitlab/WorkItems::Type/99',
                    'name': 'Issue',
                  },
                  'description': 'Synthetic description',
                  'widgets': <Object?>[],
                },
              ],
            },
          },
        },
      });
    };
    final base = _star('real-work-item-query');
    var readerPassed = false;
    final scenario = Mr7Scenario(
      id: base.id,
      suite: base.suite,
      operation: base.operation,
      variant: base.variant,
      tier: base.tier,
      call: base.call,
      paths: base.paths,
      utterance: base.utterance,
      observe: base.observe,
      fixture: (session, identity) async {
        await session.bindWorkItemGraphResource(
          'gid://gitlab/WorkItem/300',
          path: 'projects/909/issues/3',
        );
        final adapter = _CaptureWorkItemQuery();
        final capture = GitLabApi(
          instance: GitLabInstance.parse(session.instance.toString()),
          token: 'synthetic-gitlab-pat',
          dio: Dio()..httpClientAdapter = adapter,
        );
        final project = Project(
          id: identity.projectId,
          name: 'Synthetic',
          path: identity.path,
        );
        try {
          await capture.projectWorkItem(project, 3);
        } catch (_) {
          /* Capture intentionally returns no work item. */
        }
        final request = adapter.request!;
        final query = request['query']! as String;
        expect(query, contains('query MobileProjectWorkItem('));
        expect(query, contains('... on'));
        expect(query, contains('namespace'));
        return Mr7ScenarioFixtures(
          graphReadDocuments: {
            query: {mr7Digest(request['variables'])},
          },
        );
      },
      freshness: (session, _) async {
        final identity = session.identity!;
        final api = GitLabApi(
          instance: GitLabInstance.parse(session.instance.toString()),
          token: 'synthetic-gitlab-pat',
          dio: session.writer,
          cdnAdapter: session.writerAdapter,
        );
        final detail = await api.projectWorkItem(
          Project(
            id: identity.projectId,
            name: 'Synthetic',
            path: identity.path,
          ),
          3,
        );
        expect(detail.summary.iid, 3);
        readerPassed = true;
        return const AiWriteFreshness(
          visibilityUnreadable: false,
          sourceVisibilityUnreadable: false,
          targetVisibility: 'private',
        );
      },
    );
    final receipt = await runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _sha,
      session: _session(server),
      scenarios: [scenario],
      confirm: (_) async => true,
    );
    expect(
      _rows(receipt).single['status'],
      'PASS',
      reason: jsonEncode(receipt),
    );
    expect(readerPassed, isTrue);
    expect(graphReads, greaterThan(0));
    expect(server.scenarioWrites, 1);
  });

  test(
    'uploaded attachment is substituted into a later note in one conversation',
    () async {
      const raw = 'upload-fixture-unique-73492';
      const markdown =
          '![fixture.txt](/uploads/0123456789abcdef0123456789abcdef/fixture.txt)';
      final original = Uint8List.fromList(utf8.encode(raw));
      final digest = sha256.convert(original).toString();
      final bodies = <String>[];
      final server = Mr7SyntheticGitLab();
      Map<String, Object?>? note;
      server.routes['GET projects/909/issues/3'] = (_) => mr7Json({
        'id': 300,
        'iid': 3,
        'project_id': 909,
        'title': 'Synthetic issue',
        'description': 'Synthetic issue description',
        'confidential': false,
        'state': 'opened',
        'updated_at': '2026-10-29T00:00:00.000Z',
      });
      server.routes['POST projects/909/uploads'] = (_) {
        server.scenarioWrites++;
        server.addEvent(target: 909);
        return mr7Json({
          'alt': 'fixture.txt',
          'url': '/uploads/0123456789abcdef0123456789abcdef/fixture.txt',
          'markdown': markdown,
        }, status: 201);
      };
      server.routes['POST projects/909/issues/3/notes'] = (request) {
        note = {
          'id': 72,
          'project_id': 909,
          'body': (request.data as Map)['body'],
          'author': {'id': 7},
        };
        server.scenarioWrites++;
        server.addEvent(target: 909);
        return mr7Json(note, status: 201);
      };
      server.routes['GET projects/909/issues/3/notes/72'] = (_) =>
          mr7Json(note);
      AiAttachmentSession? shared;
      Future<Mr7ScenarioFixtures> fixture(
        Mr7SandboxSession session,
        Mr7Identity _,
      ) async {
        if (shared == null) {
          shared = AiAttachmentSession(
            accountKey: '${session.instance}#${session.expectedUserId}',
            conversationId: 'shared-upload',
            fileCapBytes: 1024,
          );
          final stored = await shared!.reserveAndRead(
            picker: const _MemoryPicker(),
            uploadToolInSegment: true,
            intake: AiAttachmentIntake(
              filename: 'fixture.txt',
              length: original.length,
              mediaType: 'text/plain',
              open: () => Stream.value(Uint8List.fromList(original)),
            ),
          );
          expect(stored.status, AiAttachStatus.stored);
        } else {
          expect(shared!.uploadedProjects('att-1'), {909});
        }
        return Mr7ScenarioFixtures(
          attachments: shared,
          onProviderRequest: (body) => bodies.add(jsonEncode(body)),
        );
      }

      final upload = Mr7Scenario(
        id: 'upload-first',
        suite: 'rest',
        operation: 'upload_attachment',
        variant: 'upload',
        tier: 'T2',
        fixture: fixture,
        utterance: (p) => 'Upload the synthetic file to project ${p.path}.',
        call: (p) => AiToolCall(
          id: 'upload-first',
          name: 'upload_attachment',
          arguments: {
            'projectId': p.projectId,
            'attachmentId': 'att-1',
            'reason': 'User requested upload.',
          },
        ),
        paths: (p) => {'POST projects/${p.projectId}/uploads'},
        readbackPaths: (p, _) => {
          'projects/${p.projectId}/uploads/mr7-observation',
        },
        observe: (observer, _) => observer.observe(
          Mr7UploadObservation(byteCount: original.length, sha256: digest),
        ),
      );
      final write = Mr7Scenario(
        id: 'note-second',
        suite: 'rest',
        operation: 'createNote',
        variant: 'uploaded-reference',
        tier: 'T2',
        targetKind: AiTargetKind.issue,
        fixture: fixture,
        resource: (_) => const AiResourceRef(kind: AiResourceKind.issue, id: 3),
        utterance: (p) =>
            'Write a note on issue #3 in ${p.path} with the uploaded file.',
        call: (p) => AiToolCall(
          id: 'note-second',
          name: 'createNote',
          arguments: {
            'projectId': p.projectId,
            'resource': 'issues',
            'iid': 3,
            'body': 'File: [[attachment:att-1]]',
            'reason': 'User requested a note.',
          },
        ),
        paths: (p) => {'POST projects/${p.projectId}/issues/3/notes'},
        readbackPaths: (p, _) => {'projects/${p.projectId}/issues/3/notes/72'},
        observe: (observer, p) async =>
            (await observer.read(
              'projects/${p.projectId}/issues/3/notes/72',
            ))['body'] ==
            'File: $markdown',
      );
      final receipt = await runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(server),
        scenarios: [upload, write],
        conversationId: 'shared-upload',
        confirm: (_) async => true,
      );
      expect(_rows(receipt).map((r) => r['status']), [
        'PASS',
        'PASS',
      ], reason: jsonEncode(receipt));
      expect(server.scenarioWrites, 2);
      expect(note!['body'], 'File: $markdown');
      expect(bodies.length, greaterThanOrEqualTo(2));
      for (final body in bodies) {
        expect(body, isNot(contains(raw)));
        expect(body, isNot(contains(base64Encode(original))));
        expect(body, isNot(contains(jsonEncode(original))));
      }
      expect(shared!.lookup('att-1'), isNull);
    },
  );

  test('provider rejects base64, numeric and text short attachments', () async {
    for (var length = 1; length <= 5; length++) {
      for (final ascii in [false, true]) {
        final bytes = Uint8List.fromList(
          List.generate(length, (i) => (ascii ? 81 : 201) + i),
        );
        final session = AiAttachmentSession(
          accountKey: 'synthetic',
          conversationId: 'tiny',
          fileCapBytes: 1024,
        );
        final result = await session.reserveAndRead(
          picker: const _MemoryPicker(),
          uploadToolInSegment: true,
          intake: AiAttachmentIntake(
            filename: 'tiny.bin',
            length: length,
            mediaType: 'application/octet-stream',
            open: () => Stream.value(Uint8List.fromList(bytes)),
          ),
        );
        expect(result.status, AiAttachStatus.stored);
        for (final leak in [
          base64Encode(bytes),
          bytes.toList(),
          if (ascii) utf8.decode(bytes),
        ]) {
          final provider = Mr7SyntheticProvider(
            AiToolCall(id: 'tiny', name: 'get_issue', arguments: const {}),
            attachments: [session.lookup('att-1')!],
            allowedUserText: 'Upload.',
          );
          await expectLater(
            provider.fetch(
              RequestOptions(
                path: 'https://provider.invalid/v1/responses',
                method: 'POST',
                data: jsonEncode({
                  'input': [
                    {
                      'role': 'user',
                      'content': [
                        {'type': 'input_text', 'text': 'Upload.'},
                      ],
                    },
                  ],
                  'extension': leak,
                }),
              ),
              null,
              null,
            ),
            throwsA(isA<Mr7Refused>()),
            reason: 'length $length',
          );
          expect(
            provider.attachmentLeakDetected,
            isTrue,
            reason: 'length $length',
          );
          expect(provider.requests, 0);
        }
        session.discardAll();
      }
    }
  });

  test('a previous scenario GraphQL read seal is not inherited', () async {
    const document = r'query Lookup($id: ID!) { node(id: $id) { id } }';
    final vars = {'id': 'gid://gitlab/Project/909'};
    final server = Mr7SyntheticGitLab();
    var graphReads = 0;
    server.routes['POST /install/api/graphql'] = (_) {
      graphReads++;
      return mr7Json({
        'data': {
          'node': {'id': vars['id']},
        },
      });
    };
    final first = _star(
      'seal-owner',
      fixture: (_, _) async => Mr7ScenarioFixtures(
        graphReadDocuments: {
          document: {mr7Digest(vars)},
        },
      ),
    );
    final base = _star('seal-nonowner');
    final second = Mr7Scenario(
      id: base.id,
      suite: base.suite,
      operation: base.operation,
      variant: base.variant,
      tier: base.tier,
      call: base.call,
      paths: base.paths,
      utterance: base.utterance,
      observe: base.observe,
      freshness: (session, _) async {
        await session.writer.post<Object?>(
          '${session.instance}/api/graphql',
          data: {'query': document, 'variables': vars},
        );
        return const AiWriteFreshness(
          visibilityUnreadable: false,
          sourceVisibilityUnreadable: false,
          targetVisibility: 'private',
        );
      },
    );
    final receipt = await runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _sha,
      session: _session(server),
      scenarios: [first, second],
      confirm: (_) async => true,
    );
    expect(_rows(receipt).first['status'], 'PASS', reason: jsonEncode(receipt));
    expect(
      _rows(receipt).last['status'],
      isNot('PASS'),
      reason: jsonEncode(receipt),
    );
    expect(graphReads, 0);
    expect(server.scenarioWrites, 1);
  });

  test('runner snoozes bound project Todo with production GraphQL', () async {
    String document(String name) {
      final source = File('lib/core/todo_snooze_api.dart').readAsStringSync();
      final marker = "const $name = r'''";
      final start = source.indexOf(marker) + marker.length;
      if (start < marker.length) {
        throw StateError('Production Todo document missing');
      }
      return source
          .substring(start, source.indexOf("''';", start))
          .replaceFirst(RegExp(r'^\r?\n'), '');
    }

    const until = '2030-01-01T00:00:00.000Z';
    final server = Mr7SyntheticGitLab();
    server.routes['GET projects/909/issues/3'] = (_) => mr7Json({
      'id': 300,
      'iid': 3,
      'project_id': 909,
      'confidential': false,
    });
    final scenario = Mr7Scenario(
      id: 'todo-snooze',
      suite: 'graphql',
      operation: 'snoozeTodo',
      variant: 'bound-project-todo',
      tier: 'T1',
      projectTodo: true,
      targetKind: AiTargetKind.todo,
      utterance: (_) => 'Snooze todo #71 until 2030-01-01T00:00:00Z.',
      call: (_) => AiToolCall(
        id: 'snooze',
        name: 'snoozeTodo',
        arguments: {'todoId': 71, 'until': until},
      ),
      paths: (_) => {'POST graphql'},
      readbackPaths: (_, _) => {
        'projects/909/issues/3',
        'projects/909/todos/71/mr7-observation',
      },
      observe: (observer, _) => observer.observe(
        const Mr7TodoObservation(id: 71, snoozedUntil: until),
      ),
      fixture: (session, _) async {
        await session.bindProjectTodo(
          todoId: 71,
          parentPath: 'projects/909/issues/3',
          snoozedUntil: null,
        );
        expect(session.allowsTodoFixture('snoozeTodo'), isTrue);
        return Mr7ScenarioFixtures(
          graphReadDocuments: {
            document('_pendingTodosForSnoozeQuery'): {
              mr7Digest({'first': 100, 'after': null}),
            },
          },
          graphDocuments: {document('_todoSnoozeMutation')},
          graphVariablesDigests: {
            mr7Digest({'id': 'gid://gitlab/Todo/71', 'until': until}),
          },
        );
      },
    );
    final receipt = await runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _sha,
      session: _session(server),
      scenarios: [scenario],
      confirm: (_) async => true,
    );
    expect(
      _rows(receipt).single['status'],
      'PASS',
      reason: jsonEncode(receipt),
    );
    expect(server.scenarioWrites, 1);
  });

  test(
    'candidate target kinds never bleed between same-operation scenarios',
    () async {
      for (final explicit in [false, true]) {
        final server = Mr7SyntheticGitLab();
        _deleteFixtures(server);
        final deletion = _deleteNote(
          'delete-first',
          targetKinds: explicit
              ? {AiTargetKind.note, AiTargetKind.issue}
              : null,
        );
        final sentinel = Mr7Scenario(
          id: 'other-issue-kind',
          suite: 'rest',
          operation: 'deleteNote',
          variant: 'sentinel',
          tier: 'T4',
          targetKind: AiTargetKind.issue,
          call: (_) => throw const Mr7Refused('sentinelMustNotExecute'),
          paths: (_) => const {},
          observe: (_, _) async => false,
        );
        final receipt = await runMr7Sandbox(
          policy: Mr7Policy.candidate,
          releaseSha: _sha,
          session: _session(server),
          scenarios: [deletion, sentinel],
          confirm: (_) async => true,
          typedConfirm: (p) async => p.requiredTypedName,
        );
        expect(
          _rows(receipt).first['mutationCount'],
          explicit ? 1 : 0,
          reason: jsonEncode(receipt),
        );
        expect(server.scenarioWrites, explicit ? 1 : 0);
      }
    },
  );

  test(
    'fixture binds a fresh document before provider and seals its digests',
    () async {
      const document = r'query Lookup($id: ID!) { node(id: $id) { id } }';
      final server = Mr7SyntheticGitLab();
      final order = <String>[];
      final digests = <String>{};
      final vars = {'id': 'gid://gitlab/Project/909'};
      var graphReads = 0;
      server.routes['POST /install/api/graphql'] = (_) {
        graphReads++;
        return mr7Json({
          'data': {
            'node': {'id': vars['id']},
          },
        });
      };
      final base = _star(
        'fixture-star',
        fixture: (session, identity) async {
          order.add('fixture');
          expect(identity.projectId, 909);
          expect(session.identity, same(identity));
          expect(server.setupWrites, 1);
          expect(server.scenarioWrites, 0);
          digests.add(mr7Digest(vars));
          return Mr7ScenarioFixtures(
            graphReadDocuments: {document: digests},
            onProviderRequest: (_) {
              order.add('provider');
              digests.clear(); // The running seal must be a defensive copy.
            },
          );
        },
      );
      final scenario = Mr7Scenario(
        id: base.id,
        suite: base.suite,
        operation: base.operation,
        variant: base.variant,
        tier: base.tier,
        fixture: base.fixture,
        call: base.call,
        paths: base.paths,
        utterance: base.utterance,
        observe: base.observe,
        freshness: (session, _) async {
          await session.writer.post<Object?>(
            '${session.instance}/api/graphql',
            data: {'query': document, 'variables': vars},
          );
          return const AiWriteFreshness(
            visibilityUnreadable: false,
            sourceVisibilityUnreadable: false,
            targetVisibility: 'private',
          );
        },
      );
      final receipt = await runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(server),
        scenarios: [scenario],
        confirm: (_) async => true,
      );
      expect(order.first, 'fixture');
      expect(order.skip(1), contains('provider'));
      expect(graphReads, greaterThan(0), reason: jsonEncode(receipt));
      expect(
        _rows(receipt).single['status'],
        'PASS',
        reason: jsonEncode(receipt),
      );
    },
  );

  test(
    'runner verifies omitted fields against its pre-send snapshot',
    () async {
      for (final tamper in [false, true]) {
        final server = Mr7SyntheticGitLab();
        server.routes['POST projects/909/star'] = (_) {
          server.project!['starred'] = true;
          if (tamper) server.project!['description'] = 'unexpected change';
          server.scenarioWrites++;
          server.addEvent(target: 909);
          return mr7Json(server.project, status: 201);
        };
        final scenario = _star(
          'snapshot-star',
          fixture: (session, _) async {
            session.server.project!['description'] = 'original private text';
            return const Mr7ScenarioFixtures();
          },
          preRead: (p) => [
            Mr7SnapshotSpec(
              path: 'projects/${p.projectId}',
              fields: {'description'},
              unchangedFields: {'description'},
            ),
          ],
        );
        final receipt = await runMr7Sandbox(
          policy: Mr7Policy.candidate,
          releaseSha: _sha,
          session: _session(server),
          scenarios: [scenario],
          confirm: (_) async => true,
        );
        final row = _rows(receipt).single;
        expect(row['mutationCount'], 1, reason: jsonEncode(receipt));
        expect(
          row['status'],
          tamper ? 'NOT_VERIFIED' : 'PASS',
          reason: jsonEncode(receipt),
        );
        expect(
          jsonEncode(row['preread']),
          isNot(contains('original private text')),
        );
        expect(receipt['quarantined'], tamper);
      }
    },
  );

  test(
    'scripted read then write sends the read result before the write',
    () async {
      final server = Mr7SyntheticGitLab();
      server.routes['GET projects/909/issues/3'] = (_) => mr7Json({
        'id': 300,
        'iid': 3,
        'project_id': 909,
        'title': 'Scripted observation title',
        'description': 'Public synthetic data',
        'confidential': false,
        'state': 'opened',
      });
      server.routes['GET projects/909/issues/3/notes'] = (_) => mr7Json([]);
      final requests = <Map<String, Object?>>[];
      final base = _star('scripted-star');
      final scenario = Mr7Scenario(
        id: base.id,
        suite: base.suite,
        operation: base.operation,
        variant: base.variant,
        tier: base.tier,
        readNames: const {'get_issue'},
        resource: (_) => const AiResourceRef(kind: AiResourceKind.issue, id: 3),
        utterance: (p) => 'Read issue #3 then star project ${p.path}.',
        call: base.call,
        paths: base.paths,
        observe: base.observe,
        fixture: (_, identity) async => Mr7ScenarioFixtures(
          providerScript: [
            [
              AiToolCall(
                id: 'read-issue',
                name: 'get_issue',
                arguments: {'iid': 3},
              ),
            ],
            [base.call(identity)],
          ],
          onProviderRequest: requests.add,
        ),
      );
      final receipt = await runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(server),
        scenarios: [scenario],
        confirm: (_) async => true,
      );
      expect(
        _rows(receipt).single['status'],
        'PASS',
        reason: '${jsonEncode(receipt)} requests=${jsonEncode(requests)}',
      );
      expect(requests.length, greaterThanOrEqualTo(3));
      expect(jsonEncode(requests[1]), contains('Scripted observation title'));
      expect(server.scenarioWrites, 1);
    },
  );

  test(
    'delivered read placeholders survive an edited same-field write',
    () async {
      const secret = '0123456789abcdef0123456789abcdef';
      const original = 'Screenshot ![shot](/uploads/$secret/screen.png)';
      const edited = 'Edited ![shot]([[upload:u-1]])';
      var description = original;
      final server = Mr7SyntheticGitLab();
      Map<String, Object?> issue() => {
        'id': 300,
        'iid': 3,
        'project_id': 909,
        'title': 'Synthetic issue',
        'description': description,
        'confidential': false,
        'state': 'opened',
        'updated_at': '2026-10-29T00:00:00.000Z',
      };
      server.routes['GET projects/909/issues/3'] = (_) => mr7Json(issue());
      server.routes['GET projects/909/issues/3/notes'] = (_) => mr7Json([]);
      server.routes['PUT projects/909/issues/3'] = (request) {
        description = (request.data as Map)['description'] as String;
        server.scenarioWrites++;
        server.addEvent(target: 909);
        return mr7Json(issue());
      };
      final requests = <Map<String, Object?>>[];
      final confirmations = <Mr7HostProposal>[];
      final scenario = Mr7Scenario(
        id: 'read-edit',
        suite: 'rest',
        operation: 'updateIssue',
        variant: 'placeholder',
        tier: 'T2',
        targetKind: AiTargetKind.issue,
        readNames: const {'get_issue'},
        resource: (_) => const AiResourceRef(kind: AiResourceKind.issue, id: 3),
        utterance: (p) =>
            'Read issue #3 and update its description in ${p.path}.',
        call: (p) => AiToolCall(
          id: 'update',
          name: 'updateIssue',
          arguments: {
            'projectId': p.projectId,
            'iid': 3,
            'fields': {'description': 'Updated ![shot]([[upload:u-1]])'},
            'reason': 'User requested a description edit.',
          },
        ),
        paths: (p) => {'PUT projects/${p.projectId}/issues/3'},
        readbackPaths: (p, _) => {'projects/${p.projectId}/issues/3'},
        observe: (observer, p) async =>
            (await observer.read(
              'projects/${p.projectId}/issues/3',
            ))['description'] ==
            'Edited ![shot](/uploads/$secret/screen.png)',
        freshness: (session, _) async => AiWriteFreshness(
          visibilityUnreadable: false,
          sourceVisibilityUnreadable: false,
          targetVisibility: 'private',
          currentFields: {'description': original},
          provenance: {
            'description': text.AiFieldProvenance.gitLab(
              instance: GitLabInstance.parse(session.instance.toString()),
              projectId: session.identity!.projectId,
              projectPath: session.identity!.path,
              resource: 'issues',
              iid: 3,
            ),
          },
        ),
        fixture: (_, identity) async => Mr7ScenarioFixtures(
          providerScript: [
            [
              AiToolCall(id: 'read', name: 'get_issue', arguments: {'iid': 3}),
            ],
            [
              AiToolCall(
                id: 'update',
                name: 'updateIssue',
                arguments: {
                  'projectId': identity.projectId,
                  'iid': 3,
                  'fields': {'description': 'Updated ![shot]([[upload:u-1]])'},
                  'reason': 'User requested a description edit.',
                },
              ),
            ],
          ],
          onProviderRequest: requests.add,
        ),
      );
      final receipt = await runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(server),
        scenarios: [scenario],
        confirm: (proposal) async {
          confirmations.add(proposal);
          return true;
        },
        editConfirm: (_) async => edited,
      );
      expect(
        _rows(receipt).single['status'],
        'PASS',
        reason: '${jsonEncode(receipt)} requests=${jsonEncode(requests)}',
      );
      expect(requests.length, greaterThanOrEqualTo(3));
      expect(jsonEncode(requests[1]), contains('[[upload:u-1]]'));
      for (final request in requests) {
        expect(jsonEncode(request), isNot(contains(secret)));
      }
      expect(confirmations, hasLength(2));
      expect(
        confirmations.first.payloadDigest,
        isNot(confirmations.last.payloadDigest),
      );
      expect(description, 'Edited ![shot](/uploads/$secret/screen.png)');
      expect(server.scenarioWrites, 1);
    },
  );

  for (final sharedConversation in [false, true]) {
    test(
      sharedConversation
          ? 'upload placeholders restore across scenarios sharing a conversation'
          : 'upload placeholders cannot cross different scenario conversations',
      () async {
        const secret = '0123456789abcdef0123456789abcdef';
        const link = '![shot](/uploads/$secret/screen.png)';
        var description = 'Original $link';
        final server = Mr7SyntheticGitLab();
        Map<String, Object?> issue() => {
          'id': 300,
          'iid': 3,
          'project_id': 909,
          'title': 'Synthetic issue',
          'description': description,
          'confidential': false,
          'state': 'opened',
          'updated_at': '2026-10-29T00:00:00.000Z',
        };
        server.routes['GET projects/909/issues/3'] = (_) => mr7Json(issue());
        server.routes['GET projects/909/issues/3/notes'] = (_) => mr7Json([]);
        server.routes['PUT projects/909/issues/3'] = (request) {
          description = (request.data as Map)['description'] as String;
          server.scenarioWrites++;
          server.addEvent(target: 909);
          return mr7Json(issue());
        };
        final requests = <Map<String, Object?>>[];
        Mr7Scenario edit(String id, {required bool readFirst}) {
          AiToolCall call(Mr7Identity p) => AiToolCall(
            id: id,
            name: 'updateIssue',
            arguments: {
              'projectId': p.projectId,
              'iid': 3,
              'fields': {'description': '$id ![shot]([[upload:u-1]])'},
              'reason': 'User requested a description edit.',
            },
          );
          return Mr7Scenario(
            id: id,
            suite: 'rest',
            operation: 'updateIssue',
            variant: 'conversation-placeholder',
            tier: 'T2',
            targetKind: AiTargetKind.issue,
            readNames: readFirst ? const {'get_issue'} : const {},
            resource: (_) =>
                const AiResourceRef(kind: AiResourceKind.issue, id: 3),
            utterance: (p) => 'Update issue #3 description in ${p.path}.',
            call: call,
            paths: (p) => {'PUT projects/${p.projectId}/issues/3'},
            readbackPaths: (p, _) => {'projects/${p.projectId}/issues/3'},
            observe: (observer, p) async =>
                (await observer.read(
                  'projects/${p.projectId}/issues/3',
                ))['description'] ==
                '$id $link',
            freshness: (session, _) async => AiWriteFreshness(
              visibilityUnreadable: false,
              sourceVisibilityUnreadable: false,
              targetVisibility: 'private',
              currentFields: {'description': description},
              provenance: {
                'description': text.AiFieldProvenance.gitLab(
                  instance: GitLabInstance.parse(session.instance.toString()),
                  projectId: session.identity!.projectId,
                  projectPath: session.identity!.path,
                  resource: 'issues',
                  iid: 3,
                ),
              },
            ),
            fixture: (_, identity) async => Mr7ScenarioFixtures(
              providerScript: [
                if (readFirst)
                  [
                    AiToolCall(
                      id: 'read',
                      name: 'get_issue',
                      arguments: {'iid': 3},
                    ),
                  ],
                [call(identity)],
              ],
              onProviderRequest: requests.add,
            ),
          );
        }

        final receipt = await runMr7Sandbox(
          policy: Mr7Policy.candidate,
          releaseSha: _sha,
          session: _session(server),
          scenarios: [
            edit('first', readFirst: true),
            edit('second', readFirst: false),
          ],
          conversationId: sharedConversation ? 'shared-placeholder' : null,
          confirm: (_) async => true,
        );
        final rows = _rows(receipt);
        expect(rows.first['status'], 'PASS', reason: jsonEncode(receipt));
        expect(rows.first['mutationCount'], 1);
        expect(jsonEncode(requests), contains('[[upload:u-1]]'));
        expect(jsonEncode(requests), isNot(contains(secret)));
        if (sharedConversation) {
          expect(rows.last['status'], 'PASS', reason: jsonEncode(receipt));
          expect(rows.last['mutationCount'], 1);
          expect(server.scenarioWrites, 2);
          expect(description, 'second $link');
        } else {
          expect(
            rows.last['coreOutcome'],
            'notExecuted',
            reason: jsonEncode(receipt),
          );
          expect(rows.last['reason'], text.AiTextBlockCode.rereadField);
          expect(rows.last['mutationCount'], 0);
          expect(server.scenarioWrites, 1);
          expect(description, 'first $link');
        }
      },
    );
  }

  test(
    'provider rejects attachment bytes before accepting a request',
    () async {
      final bytes = Uint8List.fromList(
        utf8.encode('unique-leak-fixture-483921'),
      );
      final attachments = AiAttachmentSession(
        accountKey: 'synthetic',
        conversationId: 'leak',
        fileCapBytes: 1024,
      );
      final stored = await attachments.reserveAndRead(
        picker: const _MemoryPicker(),
        uploadToolInSegment: true,
        intake: AiAttachmentIntake(
          filename: 'sample.txt',
          length: bytes.length,
          mediaType: 'text/plain',
          open: () => Stream.value(bytes),
        ),
      );
      expect(stored.status, AiAttachStatus.stored);
      final provider = Mr7SyntheticProvider(
        AiToolCall(id: 'x', name: 'get_issue', arguments: const {}),
        attachments: [attachments.lookup('att-1')!],
      );
      await expectLater(
        provider.fetch(
          RequestOptions(
            path: 'https://provider.invalid/v1/responses',
            method: 'POST',
            data: jsonEncode({
              'input': base64Encode(attachments.lookup('att-1')!.bytes),
            }),
          ),
          null,
          null,
        ),
        throwsA(isA<Mr7Refused>()),
      );
      expect(provider.attachmentLeakDetected, isTrue);
      expect(provider.requests, 0);
    },
  );

  test(
    'edited approval reconfirms changed digest; cancellation sends nothing',
    () async {
      for (final acceptEdited in [true, false]) {
        final server = Mr7SyntheticGitLab();
        final proposals = <Mr7HostProposal>[];
        final receipt = await runMr7Sandbox(
          policy: Mr7Policy.candidate,
          releaseSha: _sha,
          session: _session(server),
          scenarios: [_createNote(server)],
          editConfirm: (p) async {
            expect(p.editableField, 'body');
            return 'Edited synthetic note.';
          },
          confirm: (p) async {
            proposals.add(p);
            return proposals.length == 1 || acceptEdited;
          },
        );
        expect(proposals, hasLength(2), reason: jsonEncode(receipt));
        expect(
          proposals.first.payloadDigest,
          isNot(proposals.last.payloadDigest),
        );
        expect(proposals.last.previewText, contains('Edited synthetic note.'));
        expect(server.scenarioWrites, acceptEdited ? 1 : 0);
        expect(
          _rows(receipt).single['status'],
          acceptEdited ? 'PASS' : 'NOT_RUN',
          reason: jsonEncode(receipt),
        );
      }
    },
  );

  test(
    'attachment bytes stay off provider and upload is observed independently',
    () async {
      final bytes = Uint8List.fromList(
        utf8.encode('unique-fixture-bytes-938475'),
      );
      final originalBytes = Uint8List.fromList(bytes);
      final hash = sha256.convert(originalBytes).toString();
      final bodies = <String>[];
      final server = Mr7SyntheticGitLab();
      server.routes['POST projects/909/uploads'] = (_) {
        server.scenarioWrites++;
        server.addEvent(target: 909);
        return mr7Json({
          'alt': 'fixture.txt',
          'url': '/uploads/0123456789abcdef0123456789abcdef/fixture.txt',
          'markdown':
              '[fixture.txt](/uploads/0123456789abcdef0123456789abcdef/fixture.txt)',
        }, status: 201);
      };
      AiAttachmentSession? attachmentSession;
      final scenario = Mr7Scenario(
        id: 'upload-memory',
        suite: 'rest',
        operation: 'upload_attachment',
        variant: 'metadata-only',
        tier: 'T2',
        fixture: (session, identity) async {
          attachmentSession = AiAttachmentSession(
            accountKey: '${session.instance}#${session.expectedUserId}',
            conversationId: 'upload-memory',
            fileCapBytes: 1024,
          );
          final stored = await attachmentSession!.reserveAndRead(
            picker: const _MemoryPicker(),
            uploadToolInSegment: true,
            intake: AiAttachmentIntake(
              filename: 'fixture.txt',
              length: bytes.length,
              mediaType: 'text/plain',
              open: () => Stream.value(Uint8List.fromList(bytes)),
            ),
          );
          expect(stored.status, AiAttachStatus.stored);
          return Mr7ScenarioFixtures(
            attachments: attachmentSession,
            onProviderRequest: (body) => bodies.add(jsonEncode(body)),
          );
        },
        utterance: (p) => 'Upload the synthetic file to project ${p.path}.',
        call: (p) => AiToolCall(
          id: 'upload-memory',
          name: 'upload_attachment',
          arguments: {
            'projectId': p.projectId,
            'attachmentId': 'att-1',
            'reason': 'User requested the synthetic file upload.',
          },
        ),
        paths: (p) => {'POST projects/${p.projectId}/uploads'},
        readbackPaths: (p, _) => {
          'projects/${p.projectId}/uploads/mr7-observation',
        },
        observe: (observer, _) => observer.observe(
          Mr7UploadObservation(byteCount: bytes.length, sha256: hash),
        ),
      );
      final receipt = await runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(server),
        scenarios: [scenario],
        confirm: (_) async => true,
      );
      expect(
        _rows(receipt).single['status'],
        'PASS',
        reason: jsonEncode(receipt),
      );
      expect(server.scenarioWrites, 1);
      expect(bodies, isNotEmpty);
      expect(bodies.first, contains('attachment_metadata'));
      expect(bodies.first, contains('fixture.txt'));
      for (final body in bodies) {
        expect(body, isNot(contains(utf8.decode(originalBytes))));
        expect(body, isNot(contains(base64Encode(originalBytes))));
        expect(body, isNot(contains(jsonEncode(originalBytes))));
      }
      expect(jsonEncode(receipt), isNot(contains(utf8.decode(originalBytes))));
      expect(attachmentSession!.lookup('att-1'), isNull);
    },
  );

  test('candidate receipt includes explicit typed closed variants', () async {
    var providerUsed = false;
    final receipt = await runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _sha,
      session: _session(Mr7SyntheticGitLab()),
      scenarios: [
        _star(
          'open',
          fixture: (_, _) async => Mr7ScenarioFixtures(
            onProviderRequest: (_) => providerUsed = true,
          ),
        ),
      ],
      closedVariants: const [
        Mr7ClosedVariant(
          id: 'closed-package',
          suite: 'advanced',
          operation: 'deletePackage',
          variant: 'fixture',
          tier: 'T4',
          refusal: Mr7ClosedRefusal(
            Mr7ClosureCause.fixtureUnavailable,
            'runCreatedPackageUnavailable',
          ),
        ),
      ],
      confirm: (_) async => true,
    );
    expect(providerUsed, isTrue);
    final row = _rows(receipt).singleWhere((r) => r['id'] == 'closed-package');
    expect(row['status'], 'NOT_RUN');
    expect(row['readback'], 'NOT_RUN');
    expect(row['mutationCount'], 0);
    expect(row['providerCalls'], 0);
    expect(row['suite'], 'advanced');
    expect(row['operation'], 'deletePackage');
    expect(row['variant'], 'fixture');
    expect(row['tier'], 'T4');
    expect(row['releaseSha'], receipt['releaseSha']);
    expect(row['live'], 'NOT_RUN');
    expect(row['reason'], 'runCreatedPackageUnavailable');
    expect(row['refusal'], {
      'type': 'closedVariant',
      'cause': 'fixtureUnavailable',
      'code': 'runCreatedPackageUnavailable',
    });
    expect(receipt['evidenceClass'], 'CANDIDATE_ONLY');
    expect(receipt['finalEligible'], isFalse);
  });

  test('shared GitLab request budget blocks overspend across cases', () async {
    for (final alreadyUsed in [39, 40]) {
      final budget = AiToolBudget();
      expect(
        budget.reserve(requests: alreadyUsed, search: false, countCall: false),
        isNull,
      );
      final server = Mr7SyntheticGitLab();
      final receipt = await runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(server),
        scenarios: [_star('at-$alreadyUsed')],
        sharedBudget: budget,
        confirm: (_) async => true,
      );
      expect(server.scenarioWrites, 0, reason: jsonEncode(receipt));
      expect(budget.gitLabRequests, lessThanOrEqualTo(40));
      expect(
        budget.reserve(
          requests: 41 - alreadyUsed,
          search: false,
          countCall: false,
        ),
        isNotNull,
      );
    }
  });

  test(
    'shared journal enforces conversation 39/40/41 and restart account window',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'mr7-wave2-journal-test-',
      );
      addTearDown(() => scratch.delete(recursive: true));
      final keys = MemoryAiJournalKeyStore();
      var clock = DateTime.utc(2026, 10, 29, 12);
      AiWriteJournal journal(String process) => AiWriteJournal(
        keys: keys,
        applicationSupport: scratch,
        processId: process,
      )..now = () => clock;
      const account = 'https://gitlab.invalid/install#7';
      final owner = journal('first-process');
      await owner.recoverAfterAccountsLoaded([account]);
      await owner.ensureInitialized(account);
      for (var i = 0; i < 39; i++) {
        await _seedJournal(owner, account, i, 'shared');
      }
      final firstServer = Mr7SyntheticGitLab();
      final first = await runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(firstServer),
        scenarios: [_star('write-40')],
        conversationId: 'shared',
        journal: owner,
        now: () => clock,
        confirm: (_) async => true,
      );
      expect(firstServer.scenarioWrites, 1, reason: jsonEncode(first));
      expect(_rows(first).single['status'], 'PASS', reason: jsonEncode(first));

      final restarted = journal('second-process');
      await restarted.recoverAfterAccountsLoaded([account]);
      final secondServer = Mr7SyntheticGitLab();
      final second = await runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(secondServer),
        scenarios: [_star('write-41')],
        conversationId: 'shared',
        journal: restarted,
        now: () => clock,
        confirm: (_) async => true,
      );
      expect(secondServer.scenarioWrites, 0, reason: jsonEncode(second));

      for (var i = 39; i < 59; i++) {
        await _seedJournal(restarted, account, i, 'other-$i');
      }
      final blockedServer = Mr7SyntheticGitLab();
      final blocked = await runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(blockedServer),
        scenarios: [_star('account-limit')],
        conversationId: 'fresh',
        journal: restarted,
        now: () => clock,
        confirm: (_) async => true,
      );
      expect(blockedServer.scenarioWrites, 0, reason: jsonEncode(blocked));
      clock = clock.add(const Duration(minutes: 61));
      final afterServer = Mr7SyntheticGitLab();
      final after = await runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(afterServer),
        scenarios: [_star('account-window-expired')],
        conversationId: 'fresh',
        journal: restarted,
        now: () => clock,
        confirm: (_) async => true,
      );
      expect(afterServer.scenarioWrites, 1, reason: jsonEncode(after));
    },
    // A rolling-hour window of 60 encrypted journal writes: seconds on an idle
    // host, more than a minute on a loaded runner.
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'injected journal preserves another account and uncertain entry',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'mr7-shared-accounts-',
      );
      addTearDown(() => scratch.delete(recursive: true));
      final keys = MemoryAiJournalKeyStore();
      const accountA = 'https://gitlab.invalid/install#7';
      const accountB = 'https://gitlab.invalid/install#8';
      AiWriteJournal makeJournal(String process) => AiWriteJournal(
        keys: keys,
        applicationSupport: scratch,
        processId: process,
      );
      final original = makeJournal('original');
      await original.recoverAfterAccountsLoaded([accountA, accountB]);
      await original.ensureInitialized(accountA);
      await original.ensureInitialized(accountB);
      final draft = AiJournalDraft(
        executionId: 'uncertain-b',
        accountKey: accountB,
        conversationId: 'b',
        runId: 'b-run',
        operationId: 'setStar',
        writeKeys: {
          AiConflictKey([accountB, 'project:909']),
        },
        payloadSha256: 'a' * 64,
        releaseName: 'synthetic',
        instance: 'https://gitlab.invalid/install',
        confirmed: true,
      );
      await original.prepare(draft: draft);
      await original.markDispatching(executionId: draft.executionId);
      await original.finish(
        executionId: draft.executionId,
        terminal: AiJournalState.writeUncertain,
      );
      final files = AiJournalFiles(scratch);
      final beforeFile = await File(files.pathFor(accountB)).readAsBytes();
      final beforeKey = Uint8List.fromList(keys.keys[accountB]!);
      final restarted = makeJournal('restarted');
      await restarted.recoverAfterAccountsLoaded([accountA, accountB]);
      final receipt = await runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(Mr7SyntheticGitLab()),
        scenarios: [_star('account-a')],
        journal: restarted,
        confirm: (_) async => true,
      );
      expect(
        _rows(receipt).single['status'],
        'PASS',
        reason: jsonEncode(receipt),
      );
      expect(await File(files.pathFor(accountB)).readAsBytes(), beforeFile);
      expect(keys.keys[accountB], beforeKey);
      final reader = makeJournal('reader');
      await reader.recoverAfterAccountsLoaded([accountA, accountB]);
      expect(
        reader.entries(accountB).single.state,
        AiJournalState.writeUncertain,
      );
    },
  );

  test(
    'shared budget cannot exceed product limits including searches',
    () async {
      final product = AiToolBudget();
      Future<Map<String, Object?>> run(AiToolBudget budget) => runMr7Sandbox(
        releaseSha: _sha,
        scenarios: [],
        sharedBudget: budget,
        session: _session(Mr7SyntheticGitLab()),
        confirm: (_) async => true,
      );
      final dimensions =
          <String, ({int limit, AiToolBudget Function(int) create})>{
            'maxCallsPerTurn': (
              limit: product.maxCallsPerTurn,
              create: (limit) => AiToolBudget(maxCallsPerTurn: limit),
            ),
            'maxCallsPerRun': (
              limit: product.maxCallsPerRun,
              create: (limit) => AiToolBudget(maxCallsPerRun: limit),
            ),
            'maxOutputChars': (
              limit: product.maxOutputChars,
              create: (limit) => AiToolBudget(maxOutputChars: limit),
            ),
            'maxSingleOutputChars': (
              limit: product.maxSingleOutputChars,
              create: (limit) => AiToolBudget(maxSingleOutputChars: limit),
            ),
            'maxGitLabRequests': (
              limit: product.maxGitLabRequests,
              create: (limit) => AiToolBudget(maxGitLabRequests: limit),
            ),
            'maxSearches': (
              limit: product.maxSearches,
              create: (limit) => AiToolBudget(maxSearches: limit),
            ),
          };
      for (final entry in dimensions.entries) {
        final dimension = entry.value;
        await expectLater(
          run(dimension.create(dimension.limit + 1)),
          throwsA(
            isA<Mr7Refused>().having((e) => e.code, 'code', 'scenarioBound'),
          ),
          reason: entry.key,
        );
        for (final limit in [dimension.limit, dimension.limit - 1]) {
          final receipt = await run(dimension.create(limit));
          expect(_rows(receipt), isEmpty, reason: '${entry.key}=$limit');
        }
      }
    },
  );

  test(
    'provider rejects metadata block repeated outside the user projection',
    () async {
      const raw = 'distinctive-attachment-content';
      final bytes = Uint8List.fromList(utf8.encode(raw));
      final attachments = AiAttachmentSession(
        accountKey: 'synthetic',
        conversationId: 'leak',
        fileCapBytes: 1024,
      );
      final stored = await attachments.reserveAndRead(
        picker: const _MemoryPicker(),
        uploadToolInSegment: true,
        intake: AiAttachmentIntake(
          filename: '$raw.txt',
          length: bytes.length,
          mediaType: 'text/plain',
          open: () => Stream.value(bytes),
        ),
      );
      expect(stored.status, AiAttachStatus.stored);
      final block = attachments.metadataForModel()['block']! as String;
      for (final sameUser in [false, true]) {
        final provider = Mr7SyntheticProvider(
          AiToolCall(id: 'x', name: 'get_issue', arguments: const {}),
          attachments: [attachments.lookup('att-1')!],
          allowedMetadata: block,
        );
        final input = [
          {
            'role': 'user',
            'content': [
              {
                'type': 'input_text',
                'text': sameUser ? '$block\n\n$block' : 'Upload.\n\n$block',
              },
            ],
          },
          if (!sameUser) {'role': 'assistant', 'content': block},
        ];
        await expectLater(
          provider.fetch(
            RequestOptions(
              path: 'https://provider.invalid/v1/responses',
              method: 'POST',
              data: jsonEncode({'input': input}),
            ),
            null,
            null,
          ),
          throwsA(isA<Mr7Refused>()),
        );
        expect(provider.attachmentLeakDetected, isTrue);
        expect(provider.requests, 0);
      }
      attachments.discardAll();
    },
  );

  test(
    'protocol-valued attachments upload with only the host-built metadata projection',
    () async {
      for (final raw in [
        'a',
        'e',
        'fixture',
        'user',
        'assistant',
        'input_text',
        'synthetic-model',
        'get_issue',
      ]) {
        final bytes = Uint8List.fromList(utf8.encode(raw));
        final digest = sha256.convert(bytes).toString();
        final bodies = <Map<String, Object?>>[];
        var expectedUtterance = '';
        final server = Mr7SyntheticGitLab();
        server.routes['POST projects/909/uploads'] = (_) {
          server.scenarioWrites++;
          server.addEvent(target: 909);
          return mr7Json({
            'alt': 'fixture.txt',
            'url': '/uploads/0123456789abcdef0123456789abcdef/fixture.txt',
            'markdown':
                '[fixture.txt](/uploads/0123456789abcdef0123456789abcdef/fixture.txt)',
          }, status: 201);
        };
        final scenario = Mr7Scenario(
          id: 'short-upload',
          suite: 'rest',
          operation: 'upload_attachment',
          variant: 'metadata-only',
          tier: 'T2',
          fixture: (session, identity) async {
            expectedUtterance =
                'Upload the synthetic file to project ${identity.path}.';
            final attachments = AiAttachmentSession(
              accountKey: '${session.instance}#${session.expectedUserId}',
              conversationId: 'short-upload',
              fileCapBytes: 1024,
            );
            final stored = await attachments.reserveAndRead(
              picker: const _MemoryPicker(),
              uploadToolInSegment: true,
              intake: AiAttachmentIntake(
                filename: 'fixture.txt',
                length: bytes.length,
                mediaType: 'text/plain',
                open: () => Stream.value(Uint8List.fromList(bytes)),
              ),
            );
            expect(stored.status, AiAttachStatus.stored);
            return Mr7ScenarioFixtures(
              attachments: attachments,
              onProviderRequest: bodies.add,
            );
          },
          utterance: (p) => 'Upload the synthetic file to project ${p.path}.',
          call: (p) => AiToolCall(
            id: 'short-upload',
            name: 'upload_attachment',
            arguments: {
              'projectId': p.projectId,
              'attachmentId': 'att-1',
              'reason': 'User requested the synthetic file upload.',
            },
          ),
          paths: (p) => {'POST projects/${p.projectId}/uploads'},
          readbackPaths: (p, _) => {
            'projects/${p.projectId}/uploads/mr7-observation',
          },
          observe: (observer, _) => observer.observe(
            Mr7UploadObservation(byteCount: bytes.length, sha256: digest),
          ),
        );
        final receipt = await runMr7Sandbox(
          policy: Mr7Policy.candidate,
          releaseSha: _sha,
          session: _session(server),
          scenarios: [scenario],
          confirm: (_) async => true,
        );
        expect(
          _rows(receipt).single['status'],
          'PASS',
          reason: jsonEncode(receipt),
        );
        expect(jsonEncode(receipt), isNot(contains('providerAttachmentBytes')));
        expect(server.scenarioWrites, 1);
        expect(bodies, isNotEmpty);
        final input = bodies.first['input']! as List;
        final user = input.first as Map;
        expect(user['role'], 'user');
        final content = (user['content']! as List).single as Map;
        expect(content['type'], 'input_text');
        final message = content['text']! as String;
        final nonce = RegExp(
          r'<gitlab_data source="attachment_metadata" nonce="([0-9a-f]{32})">',
        ).firstMatch(message)!.group(1)!;
        final expectedBlock = wrapUntrustedGitLabData(
          source: 'attachment_metadata',
          nonce: nonce,
          text: jsonEncode([
            {
              'id': 'att-1',
              'filename': 'fixture.txt',
              'size': raw.length,
              'mediaType': 'text/plain',
            },
          ]),
        );
        expect(message, '$expectedUtterance\n\n$expectedBlock');
      }
    },
  );

  for (final wire in <WireFormatBase>[
    const ResponsesFormat(),
    const ChatCompletionsFormat(),
    const AnthropicMessagesFormat(),
  ]) {
    test(
      '${wire.format.name} wire protocol values are not attachment payloads',
      () async {
        for (final raw in [
          'user',
          'assistant',
          'input_text',
          'synthetic-model',
          'upload_attachment',
          'function',
          'object',
          'string',
          'auto',
        ]) {
          final bytes = Uint8List.fromList(utf8.encode(raw));
          final session = AiAttachmentSession(
            accountKey: 'synthetic',
            conversationId: 'wire',
            fileCapBytes: 1024,
          );
          await session.reserveAndRead(
            picker: const _MemoryPicker(),
            uploadToolInSegment: true,
            intake: AiAttachmentIntake(
              filename: 'fixture.txt',
              length: bytes.length,
              mediaType: 'text/plain',
              open: () => Stream.value(Uint8List.fromList(bytes)),
            ),
          );
          final block = session.metadataForModel()['block']! as String;
          final projection = 'Upload.\n\n$block';
          final provider = Mr7SyntheticProvider(
            AiToolCall(id: 'x', name: 'get_issue', arguments: const {}),
            attachments: session.items,
            allowedMetadata: block,
            allowedUserText: projection,
            hostText: _attachmentHostText,
          );
          await provider.fetch(
            RequestOptions(
              path: 'https://provider.invalid/v1/responses',
              method: 'POST',
              data: jsonEncode(
                _attachmentWireBody(
                  wire,
                  projection,
                  result: 'The user asked for an upload.',
                ),
              ),
            ),
            null,
            null,
          );
          expect(provider.attachmentLeakDetected, isFalse, reason: raw);
          expect(provider.requests, 1, reason: raw);
          session.discardAll();
        }
      },
    );

    test(
      '${wire.format.name} free text rejects raw base64 and numeric leaks',
      () async {
        for (final raw in [
          'user',
          '123456789012345',
          '1234567890123456',
          'distinctive-attachment-content',
        ]) {
          final bytes = Uint8List.fromList(utf8.encode(raw));
          final session = AiAttachmentSession(
            accountKey: 'synthetic',
            conversationId: 'wire',
            fileCapBytes: 1024,
          );
          await session.reserveAndRead(
            picker: const _MemoryPicker(),
            uploadToolInSegment: true,
            intake: AiAttachmentIntake(
              filename: 'fixture.txt',
              length: bytes.length,
              mediaType: 'text/plain',
              open: () => Stream.value(Uint8List.fromList(bytes)),
            ),
          );
          final block = session.metadataForModel()['block']! as String;
          final projection = 'Upload.\n\n$block';
          for (final leak in [
            raw,
            base64Encode(bytes),
            bytes.toList(),
            jsonEncode(bytes),
            'prefix:$raw:suffix',
            'prefix:${base64Encode(bytes)}:suffix',
            'prefix:${jsonEncode(bytes)}:suffix',
          ]) {
            final plain = _attachmentWireBody(wire, projection);
            final described = _attachmentWireBody(wire, projection);
            final tools = described['tools']! as List;
            final tool = tools.single as Map<String, Object?>;
            final declaration = wire.format == AiFormat.chatCompletions
                ? tool['function']! as Map<String, Object?>
                : tool;
            final bodies = {
              // Unknown payload objects must not inherit protocol exemptions.
              'unknown': {
                ...plain,
                'extension': {'role': leak},
              },
              'instructions': {
                ...plain,
                if (wire.format == AiFormat.responses)
                  'instructions': leak
                else
                  'system': leak,
              },
              'arguments': _attachmentWireBody(
                wire,
                projection,
                arguments: {'type': leak},
              ),
              'result': _attachmentWireBody(
                wire,
                projection,
                result: leak is String ? leak : jsonEncode(leak),
              ),
              'description': described,
            };
            declaration['description'] = leak;
            final schemaOnly =
                jsonDecode(jsonEncode(described)) as Map<String, Object?>;
            final schemaTools = schemaOnly['tools']! as List;
            final schemaTool = schemaTools.single as Map<String, Object?>;
            final schemaDeclaration = wire.format == AiFormat.chatCompletions
                ? schemaTool['function']! as Map<String, Object?>
                : schemaTool;
            schemaDeclaration['description'] = 'Upload a synthetic file.';
            final schema =
                schemaDeclaration[wire.format == AiFormat.anthropicMessages
                        ? 'input_schema'
                        : 'parameters']!
                    as Map<String, Object?>;
            schema['description'] = leak;
            bodies['schema description'] = schemaOnly;
            for (final list in [false, true]) {
              final nestedResult =
                  jsonDecode(jsonEncode(plain)) as Map<String, Object?>;
              final messages =
                  (nestedResult['input'] ?? nestedResult['messages'])! as List;
              final last = messages.last as Map<String, Object?>;
              final nested = list
                  ? [
                      {'type': leak},
                    ]
                  : {'type': leak};
              if (wire.format == AiFormat.responses) {
                last['output'] = nested;
              } else if (wire.format == AiFormat.chatCompletions) {
                last['content'] = nested;
              } else {
                final part =
                    (last['content']! as List).single as Map<String, Object?>;
                part['content'] = nested;
              }
              bodies['tool content list=$list'] = nestedResult;
            }
            for (final entry in bodies.entries) {
              final provider = Mr7SyntheticProvider(
                AiToolCall(id: 'x', name: 'get_issue', arguments: const {}),
                script: entry.key == 'arguments'
                    ? [
                        [
                          AiToolCall(
                            id: 'assistant',
                            name: 'upload_attachment',
                            arguments: {'type': leak},
                          ),
                        ],
                      ]
                    : null,
                attachments: session.items,
                allowedMetadata: block,
                allowedUserText: projection,
                hostText: _attachmentHostText,
              );
              await expectLater(
                provider.fetch(
                  RequestOptions(
                    path: 'https://provider.invalid/v1/responses',
                    method: 'POST',
                    data: jsonEncode(entry.value),
                  ),
                  null,
                  null,
                ),
                throwsA(isA<Mr7Refused>()),
                reason: '$raw ${entry.key}: $leak',
              );
              expect(provider.attachmentLeakDetected, isTrue);
              expect(provider.requests, 0);
            }
          }
          session.discardAll();
        }
      },
    );
  }

  test(
    'short attachment refuses attachment-derived read result before writing',
    () async {
      final server = Mr7SyntheticGitLab();
      server.routes['GET projects/909/issues/3'] = (_) => mr7Json({
        'id': 300,
        'iid': 3,
        'project_id': 909,
        'title': 'prefix:user:suffix',
        'description': 'Synthetic data',
        'confidential': false,
        'state': 'opened',
      });
      server.routes['GET projects/909/issues/3/notes'] = (_) => mr7Json([]);
      final base = _star('short-result');
      final receipt = await runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(server),
        scenarios: [
          Mr7Scenario(
            id: base.id,
            suite: base.suite,
            operation: base.operation,
            variant: base.variant,
            tier: base.tier,
            readNames: const {'get_issue'},
            resource: (_) =>
                const AiResourceRef(kind: AiResourceKind.issue, id: 3),
            utterance: (p) => 'Read issue #3 then star project ${p.path}.',
            call: base.call,
            paths: base.paths,
            observe: base.observe,
            fixture: (session, identity) async {
              final attachments = AiAttachmentSession(
                accountKey: '${session.instance}#${session.expectedUserId}',
                conversationId: base.id,
                fileCapBytes: 1024,
              );
              await attachments.reserveAndRead(
                picker: const _MemoryPicker(),
                uploadToolInSegment: true,
                intake: AiAttachmentIntake(
                  filename: 'fixture.txt',
                  length: 4,
                  mediaType: 'text/plain',
                  open: () => Stream.value(utf8.encode('user')),
                ),
              );
              return Mr7ScenarioFixtures(
                attachments: attachments,
                providerScript: [
                  [
                    AiToolCall(
                      id: 'read',
                      name: 'get_issue',
                      arguments: {'iid': 3},
                    ),
                  ],
                  [base.call(identity)],
                ],
              );
            },
          ),
        ],
        confirm: (_) async => true,
      );
      final row = _rows(receipt).single;
      expect(
        (row['provider']! as Map)['attachmentLeakScan'],
        'FAIL',
        reason: jsonEncode(receipt),
      );
      expect((row['provider']! as Map)['calls'], 1);
      expect(server.scenarioWrites, 0);
      expect(row['status'], isNot('PASS'));
    },
  );

  test('short attachment user text must equal the host projection', () async {
    final session = AiAttachmentSession(
      accountKey: 'synthetic',
      conversationId: 'projection',
      fileCapBytes: 1024,
    );
    await session.reserveAndRead(
      picker: const _MemoryPicker(),
      uploadToolInSegment: true,
      intake: AiAttachmentIntake(
        filename: 'fixture.txt',
        length: 4,
        mediaType: 'text/plain',
        open: () => Stream.value(Uint8List.fromList(utf8.encode('user'))),
      ),
    );
    final block = session.metadataForModel()['block']! as String;
    final provider = Mr7SyntheticProvider(
      AiToolCall(id: 'x', name: 'get_issue', arguments: const {}),
      attachments: session.items,
      allowedMetadata: block,
      allowedUserText: 'Upload.\n\n$block',
      hostText: _attachmentHostText,
    );
    await expectLater(
      provider.fetch(
        RequestOptions(
          path: 'https://provider.invalid/v1/responses',
          method: 'POST',
          data: jsonEncode(
            _attachmentWireBody(
              const ResponsesFormat(),
              'Upload user.\n\n$block',
            ),
          ),
        ),
        null,
        null,
      ),
      throwsA(isA<Mr7Refused>()),
    );
    expect(provider.attachmentLeakDetected, isTrue);
    expect(provider.requests, 0);
    session.discardAll();
  });
}
