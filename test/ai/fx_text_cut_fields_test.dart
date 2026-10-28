import 'release_policy_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart' show buildAiProjectionData;
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_context.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';

import '../support/fake_adapter.dart';

// Plan v6 §3.1, first condition for a restorable placeholder: 「欄位值在投影中
// 被截斷時，這個欄位不提供整欄寫回，回「這個欄位太長，AI 無法完整編輯」」.
// A whole-field write of a field whose latest copy reached the provider cut
// is refused with `fieldTooLong`; a later whole copy lifts that.

const _head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _base = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _root = 'https://gitlab.example.com';

void main() {
  group('get_issue / get_merge_request output limit', () {
    test(
      'a cut description blocks updateIssue; a whole read lifts it',
      () async {
        final table = _table();
        final port = _Port(description: 'Line of the description. ' * 200);
        final catalogue = _catalogue(port, table);

        final cut = await catalogue.execute(
          _call('get_issue', {'iid': 3}),
          budget: AiToolBudget(maxSingleOutputChars: 800),
        );
        expect(cut.truncated, isTrue);
        expect(table.seenOnlyCut(_issueField()), isTrue);
        final blocked = _prepare(table, _issueField());
        expect(blocked.policyBlocked, isTrue);
        expect(blocked.blockedReasonCode, AiTextBlockCode.fieldTooLong);
        expect(blocked.finalText, isNull);

        final whole = await catalogue.execute(
          _call('get_issue', {'iid': 3}),
          budget: AiToolBudget(),
        );
        expect(whole.truncated, isFalse);
        expect(table.seenOnlyCut(_issueField()), isFalse);
        final allowed = _prepare(table, _issueField());
        expect(allowed.policyBlocked, isFalse);
        expect(allowed.finalText, 'Rewritten description');
      },
    );

    test('a later cut read marks the field again', () async {
      final table = _table();
      final port = _Port(description: 'Long text. ' * 300);
      final catalogue = _catalogue(port, table);
      await catalogue.execute(
        _call('get_issue', {'iid': 3}),
        budget: AiToolBudget(),
      );
      expect(_prepare(table, _issueField()).policyBlocked, isFalse);
      await catalogue.execute(
        _call('get_issue', {'iid': 3}),
        budget: AiToolBudget(maxSingleOutputChars: 600),
      );
      expect(
        _prepare(table, _issueField()).blockedReasonCode,
        AiTextBlockCode.fieldTooLong,
      );
    });

    test('only the fields that were cut are marked', () async {
      final table = _table();
      final port = _Port(
        description: 'Short description',
        notes: [
          {'id': 11, 'body': 'First note, short', 'system': false},
          {'id': 12, 'body': 'Second note. ' * 200, 'system': false},
          {'id': 13, 'body': 'Third note, dropped', 'system': false},
        ],
      );
      final catalogue = _catalogue(port, table);
      final execution = await catalogue.execute(
        _call('get_issue', {'iid': 3}),
        budget: AiToolBudget(maxSingleOutputChars: 900),
      );
      expect(execution.truncated, isTrue);
      // The projection lists the notes in reverse: 13, 12, 11.
      expect(table.seenOnlyCut(_issueField()), isFalse);
      expect(table.seenOnlyCut(_noteField(13)), isFalse);
      expect(table.seenOnlyCut(_noteField(12)), isTrue);
      expect(table.seenOnlyCut(_noteField(11)), isTrue);
      expect(_prepare(table, _issueField()).policyBlocked, isFalse);
      expect(
        _prepare(table, _noteField(12)).blockedReasonCode,
        AiTextBlockCode.fieldTooLong,
      );
    });

    test('a merge request description cut by the limit is marked', () async {
      final table = _table();
      final port = _Port(description: 'MR text. ' * 300);
      final catalogue = _catalogue(port, table);
      await catalogue.execute(
        _call('get_merge_request', {'iid': 3}),
        budget: AiToolBudget(maxSingleOutputChars: 700),
      );
      final field = _field('merge_requests');
      expect(table.seenOnlyCut(field), isTrue);
      expect(table.seenOnlyCut(_issueField()), isFalse);
      expect(
        _prepare(table, field).blockedReasonCode,
        AiTextBlockCode.fieldTooLong,
      );
    });

    test('a description the clip drops entirely is marked', () async {
      final table = _table();
      final port = _Port(
        title: 'A long title. ' * 100,
        description: 'Never reached',
      );
      await _catalogue(port, table).execute(
        _call('get_issue', {'iid': 3}),
        budget: AiToolBudget(maxSingleOutputChars: 400),
      );
      expect(table.seenOnlyCut(_issueField()), isTrue);
    });
  });

  group('page context', () {
    test('a cut page-context description blocks updateIssue', () async {
      final context = await _loadIssueContext('Context text. ' * 400);
      final field = context.field!;
      expect(field.provenance.sameField(_issueField(project: 42)), isTrue);
      final table = _table();

      // The first request of a segment carries the page context whole.
      context.recordDelivery(table, context.built.blocks);
      expect(table.seenOnlyCut(field.provenance), isFalse);
      expect(_prepare(table, field.provenance).policyBlocked, isFalse);

      // A later segment carries a summary cut from it.
      final summary = buildAiProjectionData(
        context: context.built.blocks,
        entries: const [],
        budget: 2000,
        redact: (value) => value,
      );
      context.recordDelivery(table, [
        AiContextBlock.fromData(source: 'conversation_summary', data: summary),
      ]);
      expect(table.seenOnlyCut(field.provenance), isTrue);
      final blocked = _prepare(table, field.provenance);
      expect(blocked.blockedReasonCode, AiTextBlockCode.fieldTooLong);

      // A request that carries no context changes nothing.
      context.recordDelivery(table, const []);
      expect(table.seenOnlyCut(field.provenance), isTrue);

      // A summary roomy enough keeps the description whole.
      final roomy = buildAiProjectionData(
        context: context.built.blocks,
        entries: const [],
        budget: 60000,
        redact: (value) => value,
      );
      context.recordDelivery(table, [
        AiContextBlock.fromData(source: 'conversation_summary', data: roomy),
      ]);
      expect(table.seenOnlyCut(field.provenance), isFalse);
    });

    test('a description with a secret still matches as sent', () async {
      final context = await _loadIssueContext(
        'Deploy with token: glpat-ABCDEFGHIJKLMNOPQRST today',
      );
      final table = _table();
      context.recordDelivery(table, context.built.blocks);
      expect(table.seenOnlyCut(context.field!.provenance), isFalse);
    });
  });
}

AiTextOutcome _prepare(UploadPlaceholderTable table, AiFieldProvenance field) =>
    prepareWriteText(
      textClass: AiTextClass.quickActionMarkdown,
      modelText: 'Rewritten description',
      field: field,
      placeholders: table,
      knownSecrets: const <String>{},
      aiAttribution: false,
      visibility: const AiVisibilityContext(targetProjectPath: 'group/project'),
    );

UploadPlaceholderTable _table() =>
    UploadPlaceholderTable(instance: GitLabInstance.parse(_root));

AiFieldProvenance _field(String resource, {int project = 9, int? noteId}) =>
    AiFieldProvenance.gitLab(
      instance: GitLabInstance.parse(_root),
      projectId: project,
      projectPath: 'group/project',
      resource: resource,
      iid: 3,
      noteId: noteId,
    );

AiFieldProvenance _issueField({int project = 9}) =>
    _field('issues', project: project);

AiFieldProvenance _noteField(int id) => _field('issues', noteId: id);

AiToolCatalogue _catalogue(_Port port, UploadPlaceholderTable table) =>
    AiToolCatalogue(
      releasePolicy: fixtureReleasePolicy,
      port: port,
      scope: const AiResourceScope(
        accountKey: '$_root#7',
        instanceKey: _root,
        projectId: 9,
        projectPath: 'group/project',
        current: AiResourceRef(kind: AiResourceKind.issue, id: 3),
        headSha: _head,
        baseSha: _base,
      ),
      redactor: Redactor(secrets: const _Secrets()),
      placeholders: table,
    );

AiToolCall _call(String name, Map<String, Object?> arguments) =>
    AiToolCall(id: 'call-1', name: name, arguments: arguments);

Future<AiChatContext> _loadIssueContext(String description) {
  final adapter = FakeAdapter((request) {
    final path = request.uri.path;
    if (path.endsWith('/projects/42/issues/3/notes')) {
      return jsonResponse(<Object?>[]);
    }
    if (path.endsWith('/projects/42/issues/3')) {
      return jsonResponse({
        'title': 'Issue title',
        'description': description,
        'state': 'opened',
        'labels': <Object?>[],
      });
    }
    if (path.endsWith('/projects/42')) {
      return jsonResponse({
        'id': 42,
        'name': 'Synthetic',
        'path_with_namespace': 'group/project',
      });
    }
    return jsonResponse({'error': 'not found'}, status: 404);
  });
  return loadAiChatContext(
    origin: const AiWorkItemOrigin(
      project: Project(id: 42, name: 'Synthetic', path: 'group/project'),
      kind: AiWorkItemKind.issue,
      iid: 3,
      title: 'Issue title',
    ),
    api: testApi(adapter),
    redactor: Redactor(secrets: const _Secrets()),
    accountKey: 'https://example.com/gitlab#7',
    refreshSecrets: () async {},
    isCurrent: () => true,
  );
}

final class _Secrets implements KnownSecretsSource {
  const _Secrets();

  @override
  Iterable<String> get current => const <String>[];
}

final class _Port implements AiGitLabReadPort {
  _Port({
    this.title = 'Issue title',
    required this.description,
    this.notes = const <AiJson>[],
  });

  final String title;
  final String description;
  final List<AiJson> notes;

  AiJson get _discussion => {
    'iid': 3,
    'title': title,
    'description': description,
    'state': 'opened',
    'notes': notes,
  };

  @override
  Future<AiPortRead<AiJson>> issue(int iid) async =>
      AiPortRead(_discussion, requestCount: 2);

  @override
  Future<AiPortRead<AiJson>> mergeRequest(int iid) async =>
      AiPortRead(_discussion, requestCount: 2);

  @override
  Future<AiPortRead<AiJson>> commit(String sha) => throw UnimplementedError();

  @override
  Future<AiPortRead<List<AiJson>>> commitDiff(String sha) =>
      throw UnimplementedError();

  @override
  Future<AiPortRead<String>> jobLog(int jobId) => throw UnimplementedError();

  @override
  Future<AiPortRead<List<AiTreeItem>>> listDirectory(String sha, String path) =>
      throw UnimplementedError();

  @override
  Future<AiPortRead<AiJson>> mergeRequestDiff(
    int iid, {
    required String headSha,
    required String baseSha,
  }) => throw UnimplementedError();

  @override
  Future<AiPortRead<List<AiJson>>> pipelineJobs(int pipelineId) =>
      throw UnimplementedError();

  @override
  Future<AiPortRead<String>> readFile(String sha, String path) =>
      throw UnimplementedError();

  @override
  Future<AiPortRead<List<AiJson>>> search(String scope, String query) =>
      throw UnimplementedError();
}
