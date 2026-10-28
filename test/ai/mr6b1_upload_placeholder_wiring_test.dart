import 'release_policy_support.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';

// Plan v6 §3.1 and §15 rows 23 and 32 on the production path: the chat
// controller, its runner, the read catalogue over GitLabAiReadPort, the
// coordinator and GitLabAiWritePort, with GitLab and the provider faked at
// the Dio adapter.

const _hexA = '0123456789abcdef0123456789abcdef';
const _hexB = 'fedcba9876543210fedcba9876543210';
const _hexC = '00112233445566778899aabbccddeeff';
const _hexD = 'ffeeddccbbaa99887766554433221100';
const _hexE = 'abcdefabcdefabcdefabcdefabcdef01';
const _hexF = '1234567890abcdef1234567890abcdef';
const _hexG = '9876543210fedcba9876543210fedcba';

/// The instance is installed under `/gitlab` (see `testApi`).
const _ownProject = 'https://example.com/gitlab/studio/mobile-workspace';
const _targetA = '/uploads/$_hexA/screen.png';
const _targetB = '$_ownProject/uploads/$_hexB/log.txt';
const _targetC = '/uploads/$_hexC/note.png';
const _targetD = '/uploads/$_hexD/preview.png';

String _issueDescription(String a, String b) =>
    'Steps to reproduce\n\n![shot]($a)\n\nFull log: [log]($b "build log")\n';
String _noteBody(String c) => 'Same here ![repro]($c)';
String _mrDescription(String d) => 'Preview\n\n<img src="$d" width="300">\n';

final _issue5Description = _issueDescription(_targetA, _targetB);
final _note77Body = _noteBody(_targetC);
final _mr12Description = _mrDescription(_targetD);

void main() {
  test('§15 row 32 an issue description round trips through the placeholder '
      'table', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.provider.script.add((_) => _toolTurn('get_issue', {'iid': 5}));

    await h.controller.send('Read issue 5');

    final read = h.provider.bodies[1];
    final ids = _placeholderIds(read);
    expect(ids, hasLength(3), reason: 'description: 2 links, note: 1 link');
    _expectNoUploadSecret(read);
    expect(read, isNot(contains('example.com')));

    h.provider.script.add(
      (_) => _toolTurn('updateIssue', {
        'projectId': 42,
        'iid': 5,
        'fields': {
          'description': _issueDescription(
            '[[upload:u-${ids[0]}]]',
            '[[upload:u-${ids[1]}]]',
          ),
        },
        'reason': 'Reword the issue as the user asked.',
      }),
    );
    final sending = h.controller.send('Tidy the description of issue 5');
    await _waitFor(() => h.controller.proposals.isNotEmpty);
    final outcome = await h.controller.approveWrite(
      h.controller.proposals.single,
    );
    await sending;

    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
    expect(h.server.mutations, hasLength(1));
    final mutation = h.server.mutations.single;
    expect(mutation.method, 'PUT');
    expect(mutation.path, 'projects/42/issues/5');
    expect(mutation.body['description'], _issue5Description);
    for (final body in h.provider.bodies) {
      _expectNoUploadSecret(body);
    }
  });

  test('§15 row 32 a merge request description round trips through the '
      'placeholder table', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.provider.script.add((_) => _toolTurn('get_merge_request', {'iid': 12}));

    await h.controller.send('Read merge request 12');

    final read = h.provider.bodies[1];
    final ids = _placeholderIds(read);
    expect(ids, hasLength(1));
    _expectNoUploadSecret(read);
    expect(read, isNot(contains('example.com')));

    h.provider.script.add(
      (_) => _toolTurn('updateMergeRequest', {
        'projectId': 42,
        'iid': 12,
        'fields': {'description': _mrDescription('[[upload:u-${ids.single}]]')},
        'reason': 'Reword the merge request as the user asked.',
      }),
    );
    final sending = h.controller.send('Tidy the description of !12');
    await _waitFor(() => h.controller.proposals.isNotEmpty);
    final outcome = await h.controller.approveWrite(
      h.controller.proposals.single,
    );
    await sending;

    expect(outcome.state, AiJournalState.succeeded, reason: outcome.reasonCode);
    final mutation = h.server.mutations.single;
    expect(mutation.method, 'PUT');
    expect(mutation.path, 'projects/42/merge_requests/12');
    expect(mutation.body['description'], _mr12Description);
    for (final body in h.provider.bodies) {
      _expectNoUploadSecret(body);
    }
  });

  test(
    '§15 row 32 a note body round trips through the placeholder table',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.provider.script.add((_) => _toolTurn('get_issue', {'iid': 5}));

      await h.controller.send('Read issue 5');

      final ids = _placeholderIds(h.provider.bodies[1]);
      expect(ids, hasLength(3));
      // updateNote's HTTP allowance does not fit beside the read in one send.
      h.provider.script.add(
        (_) => _toolTurn('updateNote', {
          'projectId': 42,
          'resource': 'issues',
          'iid': 5,
          'noteId': 77,
          'body': _noteBody('[[upload:u-${ids[2]}]]'),
          'reason': 'Fix my own comment as the user asked.',
        }),
      );
      final sending = h.controller.send('Tidy my comment on issue 5');
      await _waitFor(() => h.controller.proposals.isNotEmpty);
      final outcome = await h.controller.approveWrite(
        h.controller.proposals.single,
      );
      await sending;

      expect(
        outcome.state,
        AiJournalState.succeeded,
        reason: outcome.reasonCode,
      );
      final mutation = h.server.mutations.single;
      expect(mutation.method, 'PUT');
      expect(mutation.path, 'projects/42/issues/5/notes/77');
      expect(mutation.body['body'], _note77Body);
      for (final body in h.provider.bodies) {
        _expectNoUploadSecret(body);
      }
    },
  );

  group('§15 row 32 a placeholder is refused outside its own field', () {
    Future<void> refused(
      String reasonCode,
      Map<String, Object?> Function(List<int> ids) write,
      String writeName,
    ) async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.provider.script.add((_) => _toolTurn('get_issue', {'iid': 5}));
      await h.controller.send('Read issue 5');
      final ids = _placeholderIds(h.provider.bodies[1]);
      expect(ids, hasLength(3));

      h.provider.script.add((_) => _toolTurn(writeName, write(ids)));
      await h.controller.send('Make the edit');

      expect(h.controller.proposals, isEmpty);
      expect(h.server.mutations, isEmpty);
      final reported = h.provider.bodies.last;
      expect(reported, contains('notExecuted'));
      expect(reported, contains(reasonCode));
    }

    test('the description id written into another issue', () async {
      await refused(
        AiTextBlockCode.rereadField,
        (ids) => {
          'projectId': 42,
          'iid': 6,
          'fields': {'description': 'Copied ![shot]([[upload:u-${ids[0]}]])'},
          'reason': 'Copy the screenshot.',
        },
        'updateIssue',
      );
    });

    test('the description id written into a new note', () async {
      await refused(
        AiTextBlockCode.rereadField,
        (ids) => {
          'projectId': 42,
          'resource': 'issues',
          'iid': 5,
          'body': 'Again ![shot]([[upload:u-${ids[0]}]])',
          'reason': 'Repost the screenshot.',
        },
        'createNote',
      );
    });

    test('the description id written into the title', () async {
      await refused(
        AiTextBlockCode.rereadField,
        (ids) => {
          'projectId': 42,
          'iid': 5,
          'fields': {'title': 'Crash [[upload:u-${ids[0]}]]'},
          'reason': 'Retitle the issue.',
        },
        'updateIssue',
      );
    });

    test('the note id written into the description', () async {
      await refused(
        AiTextBlockCode.rereadField,
        (ids) => {
          'projectId': 42,
          'iid': 5,
          'fields': {
            'description': _issueDescription(
              '[[upload:u-${ids[2]}]]',
              '[[upload:u-${ids[1]}]]',
            ),
          },
          'reason': 'Swap the screenshot.',
        },
        'updateIssue',
      );
    });

    test('a forged id in the same description', () async {
      await refused(
        AiTextBlockCode.rereadField,
        (ids) => {
          'projectId': 42,
          'iid': 5,
          'fields': {
            'description': _issueDescription(
              '[[upload:u-${ids[0]}]]',
              '[[upload:u-${ids.last + 50}]]',
            ),
          },
          'reason': 'Reword the issue.',
        },
        'updateIssue',
      );
    });

    test('the right id in a bad position', () async {
      await refused(
        AiTextBlockCode.badPlaceholderPosition,
        (ids) => {
          'projectId': 42,
          'iid': 5,
          'fields': {
            'description':
                'See https://x.example/[[upload:u-${ids[0]}]] '
                '[[upload:u-${ids[1]}]]',
          },
          'reason': 'Reword the issue.',
        },
        'updateIssue',
      );
    });
  });

  test('§15 rows 23 and 32 another instance upload and a Job log link stay '
      'ordinary markers', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.provider.script
      ..add((_) => _toolTurn('get_issue', {'iid': 7}))
      ..add((_) => _toolTurn('get_job_log', {'job_id': 501}, id: 'call-log'));

    await h.controller.send('Read issue 7 and job 501');

    final sent = h.provider.bodies.last;
    expect(sent, contains('Mirrored'));
    expect(sent, contains('Uploading'));
    expect(sent, contains('[REDACTED]'));
    expect(sent, isNot(contains('[[upload:')));
    expect(sent, isNot(contains('other.example')));
    _expectNoUploadSecret(sent);

    // Nothing was numbered, so no id can be put back into issue 7.
    h.provider.script.add(
      (_) => _toolTurn('updateIssue', {
        'projectId': 42,
        'iid': 7,
        'fields': {'description': 'Mirrored ![x]([[upload:u-1]])'},
        'reason': 'Reword the issue.',
      }),
    );
    await h.controller.send('Reword issue 7');
    expect(h.server.mutations, isEmpty);
    expect(h.provider.bodies.last, contains(AiTextBlockCode.rereadField));
  });

  test('§15 row 32 an upload link pasted in the user message is not '
      'restorable', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    const pasted = '$_ownProject/uploads/$_hexG/pasted.png';
    h.provider.script.add(
      (_) => _toolTurn('updateIssue', {
        'projectId': 42,
        'iid': 5,
        'fields': {'description': 'Screenshot: ![p]($pasted)'},
        'reason': 'Add the screenshot the user pasted.',
      }),
    );

    await h.controller.send('Put $pasted into the description of issue 5');

    expect(h.provider.bodies.first, isNot(contains(_hexG)));
    expect(h.provider.bodies.first, isNot(contains('uploads/')));
    expect(h.controller.proposals, isEmpty);
    expect(h.server.mutations, isEmpty);
    expect(h.provider.bodies.last, contains(AiTextBlockCode.pasteOnScreen));
  });

  test('§3.1 a field past the 1,000-entry limit says why it keeps ordinary '
      'markers', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final many = StringBuffer();
    for (var i = 0; i < UploadPlaceholderTable.maxEntries; i++) {
      many.writeln(
        '![n](/uploads/${i.toRadixString(16).padLeft(32, '0')}/n.png)',
      );
    }
    h.server.issues[8] = _issueJson(8, many.toString());
    h.server.issues[9] = _issueJson(9, 'One more ![x](/uploads/$_hexF/x.png)');
    h.provider.script
      ..add((_) => _toolTurn('get_issue', {'iid': 8}))
      ..add((_) => _toolTurn('get_issue', {'iid': 9}, id: 'call-9'));

    await h.controller.send('Read issues 8 and 9');

    final sent = h.provider.bodies.last;
    // Issue 8 filled the table, but its description is cut by the tool
    // output limit, and a cut value keeps only ordinary markers.
    expect(sent, contains('"iid\\":8'));
    expect(sent, isNot(contains('[[upload:')));
    expect(sent, contains(AiTextBlockCode.tooManyUploadLinks));
    expect(sent, contains('One more'));
    expect(sent, isNot(contains(_hexF)));
    expect(h.server.mutations, isEmpty);
  });
}

List<int> _placeholderIds(String body) => [
  for (final match in RegExp(r'\[\[upload:u-([0-9]+)\]\]').allMatches(body))
    int.parse(match.group(1)!),
];

void _expectNoUploadSecret(String body) {
  for (final hex in [_hexA, _hexB, _hexC, _hexD, _hexE, _hexF, _hexG]) {
    expect(body, isNot(contains(hex)));
  }
  expect(body, isNot(contains('uploads/')));
}

Future<void> _waitFor(bool Function() condition) async {
  // Bounded by time, not by turns: under CI load the journal's file work can
  // need more turns than a fixed count allows.
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'the run did not reach the checkpoint');
}

Map<String, Object?> _issueJson(int iid, String description) => {
  'id': 1000 + iid,
  'iid': iid,
  'project_id': 42,
  'title': 'Issue $iid',
  'description': description,
  'state': 'opened',
  'labels': <String>[],
  'confidential': false,
  'created_at': '2026-10-01T00:00:00Z',
  'updated_at': '2026-10-01T00:00:00Z',
  'author': {'id': 7, 'username': 'developer', 'name': 'Developer'},
};

final class _Mutation {
  _Mutation(this.method, this.path, this.body);
  final String method;
  final String path;
  final Map<String, Object?> body;
}

/// GitLab issues 5, 6, 7, merge request 12, note 77 on issue 5 and job 501;
/// every other request goes to [WorkspaceFixture].
final class _Server {
  _Server() {
    issues[5] = _issueJson(5, _issue5Description);
    issues[6] = _issueJson(6, 'No attachments here.');
    issues[7] = _issueJson(
      7,
      'Mirrored ![x](https://other.example/uploads/$_hexE/x.png)',
    );
    notes[77] = {
      'id': 77,
      'body': _note77Body,
      'system': false,
      'author': {'id': 7, 'username': 'developer', 'name': 'Developer'},
      'created_at': '2026-10-02T00:00:00Z',
      'updated_at': '2026-10-02T00:00:00Z',
    };
  }

  final workspace = WorkspaceFixture();
  late final adapter = FakeAdapter(_respond);
  final issues = <int, Map<String, Object?>>{};
  final notes = <int, Map<String, Object?>>{};
  final mergeRequest = <String, Object?>{
    'id': 2012,
    'iid': 12,
    'project_id': 42,
    'title': 'Merge request 12',
    'description': _mr12Description,
    'state': 'opened',
    'labels': <String>[],
    'sha': WorkspaceFixture.sha,
    'created_at': '2026-10-01T00:00:00Z',
    'updated_at': '2026-10-01T00:00:00Z',
    'author': {'id': 7, 'username': 'developer', 'name': 'Developer'},
  };
  final mutations = <_Mutation>[];

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final start = segments.indexOf('v4');
    final path = start < 0 ? '' : segments.skip(start + 1).join('/');
    final method = request.method;
    final body = switch (request.data) {
      final Map<String, Object?> map => map,
      final String text when text.isNotEmpty =>
        jsonDecode(text) as Map<String, Object?>,
      _ => <String, Object?>{},
    };
    if (method != 'GET' && method != 'HEAD') {
      mutations.add(_Mutation(method, path, body));
    }
    final issue = RegExp(r'^projects/42/issues/([0-9]+)$').firstMatch(path);
    if (issue != null) {
      final item = issues[int.parse(issue.group(1)!)];
      if (item == null) return jsonResponse({}, status: 404);
      if (method == 'PUT') item.addAll(body);
      return jsonResponse(item);
    }
    if (path == 'projects/42/issues/5/notes') {
      return jsonResponse(notes.values.toList());
    }
    if (RegExp(r'^projects/42/issues/[0-9]+/notes$').hasMatch(path)) {
      return jsonResponse(<Object?>[]);
    }
    final note = RegExp(
      r'^projects/42/issues/5/notes/([0-9]+)$',
    ).firstMatch(path);
    if (note != null) {
      final item = notes[int.parse(note.group(1)!)];
      if (item == null) return jsonResponse({}, status: 404);
      if (method == 'PUT') item.addAll(body);
      return jsonResponse(item);
    }
    if (path == 'projects/42/merge_requests/12') {
      if (method == 'PUT') mergeRequest.addAll(body);
      return jsonResponse(mergeRequest);
    }
    if (path == 'projects/42/merge_requests/12/notes') {
      return jsonResponse(<Object?>[]);
    }
    if (path == 'projects/42/jobs/501/trace') {
      return ResponseBody.fromString(
        'Uploading $_ownProject/uploads/$_hexF/trace.png\nAll tests passed.\n',
        200,
        headers: {
          'content-type': ['text/plain'],
          'x-gitlab-trace-eof': ['true'],
        },
      );
    }
    return workspace.respond(request);
  }
}

/// A scripted Responses provider. Each request takes the next turn; an empty
/// script answers in text.
final class _Provider {
  final bodies = <String>[];
  final script = <String Function(String body)>[];
  late final adapter = FakeAdapter((request) {
    final data = request.data;
    final body = data is String ? data : jsonEncode(data);
    bodies.add(body);
    final next = script.isEmpty ? (_) => _answerTurn : script.removeAt(0);
    return _sse(next(body));
  });
}

final class _Harness {
  _Harness(this.root, this.server, this.provider, this.session, this.settings);

  final Directory root;
  final _Server server;
  final _Provider provider;
  final SessionController session;
  final AiSettingsController settings;
  late final AiChatController controller;

  static Future<_Harness> create() async {
    final server = _Server();
    final workspace = server.workspace;
    final accounts = MemoryAccountStore()
      ..accounts = [workspace.account]
      ..lastActive = workspace.account.key;
    final session = controllerFor(accounts, server.adapter);
    await session.initialize();

    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    final config = await settings.saveProvider(_providerConfig);
    await settings.loadAccount(workspace.account.key);
    await settings.setAutonomySettings(
      workspace.account.key,
      ceiling: AiAutonomyLevel.lowRiskAuto,
      startingLevel: AiAutonomyLevel.lowRiskAuto,
    );
    await settings.grantConsent(
      workspace.account.key,
      settings.consentContractFor(
        workspace.account.key,
        config,
        releasePolicy: fixtureReleasePolicy,
        writePolicy: aiMr6b1WritePolicy(AiAutonomyLevel.lowRiskAuto, releasePolicy: fixtureReleasePolicy),
        agreedCeiling: AiAutonomyLevel.lowRiskAuto,
      ),
      const {'synthetic': true},
    );

    final root = Directory.systemTemp.createTempSync('mr6b1-placeholders-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'mr6b1-placeholder-test',
    );
    await journal.recoverAfterAccountsLoaded([workspace.account.key]);
    await journal.ensureInitialized(workspace.account.key);

    final provider = _Provider();
    final harness = _Harness(root, server, provider, session, settings);
    harness.controller = AiChatController(
      releasePolicy: fixtureReleasePolicy,
      origin: AiFileOrigin(
        project: workspace.project,
        path: 'README.md',
        sha: WorkspaceFixture.sha,
      ),
      session: session,
      settings: settings,
      runningCount: () => 0,
      appInForeground: () => true,
      clientMayStart: () => true,
      writeJournal: journal,
      wireClientFactory:
          ({required config, required apiKey, required conversationId}) =>
              AiWireClient(
                transport: AiTransport(
                  endpoint: AiEndpoint.parse(
                    config.baseUrl,
                    allowLanCleartext: false,
                  ),
                  apiKey: apiKey ?? '',
                  authStyle: config.authStyle,
                  adapter: provider.adapter,
                ),
                wire: const ResponsesFormat(),
                config: config,
                conversationId: conversationId,
                appVersion: 'test',
              ),
    );
    await harness.controller.recheck();
    expect(harness.controller.canSend, isTrue);
    return harness;
  }

  void dispose() {
    controller.dispose();
    settings.dispose();
    session.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

const _providerConfig = AiProviderConfig(
  id: 'mr6b1-placeholder-provider',
  name: 'Placeholder provider',
  presetId: 'custom',
  baseUrl: 'https://provider.example/v1',
  format: AiFormat.responses,
  model: 'synthetic-model',
  authStyle: AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    requiresKey: false,
    toolChoice: true,
  ),
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: 1,
);

var _callCounter = 0;

String _toolTurn(String name, Map<String, Object?> arguments, {String? id}) =>
    _event({
      'type': 'response.completed',
      'response': {
        'output': [
          {
            'type': 'function_call',
            'call_id': id ?? 'call-${++_callCounter}',
            'name': name,
            'arguments': jsonEncode(arguments),
            'status': 'completed',
          },
        ],
      },
    });

final _answerTurn = _event({
  'type': 'response.completed',
  'response': {
    'output': [
      {
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': 'Done'},
        ],
      },
    ],
  },
});

ResponseBody _sse(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/event-stream'],
  },
);

String _event(Object value) => 'data: ${jsonEncode(value)}\n\n';
