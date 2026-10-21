import '../app_text.dart';
import 'dart:convert';
import 'dart:math';

import '../ai_transcript.dart';
import '../redaction.dart';
import '../wire/wire_format.dart';
import 'gitlab_read_port.dart';
import 'sensitive_paths.dart';
import 'tool_scope.dart';

const aiToolCatalogueVersion = 1;
const aiSensitivePathBlocked = '[blocked by policy: sensitive file]';

final class AiToolBudget {
  AiToolBudget({
    this.maxCallsPerTurn = 4,
    this.maxCallsPerRun = 12,
    this.maxOutputChars = 120000,
    this.maxSingleOutputChars = 20000,
    this.maxGitLabRequests = 40,
    this.maxSearches = 2,
  });

  final int maxCallsPerTurn;
  final int maxCallsPerRun;
  final int maxOutputChars;
  final int maxSingleOutputChars;
  final int maxGitLabRequests;
  final int maxSearches;

  int _turnCalls = 0;
  int _runCalls = 0;
  int _outputChars = 0;
  int _gitLabRequests = 0;
  int _searches = 0;

  int get calls => _runCalls;
  int get outputChars => _outputChars;
  int get gitLabRequests => _gitLabRequests;
  int get searches => _searches;
  bool get exhausted =>
      _runCalls >= maxCallsPerRun ||
      _outputChars >= maxOutputChars ||
      _gitLabRequests >= maxGitLabRequests ||
      _searches >= maxSearches;

  void beginTurn() => _turnCalls = 0;

  String? reserve({required int requests, required bool search}) {
    if (_turnCalls >= maxCallsPerTurn) return 'per-turn tool limit reached';
    if (_runCalls >= maxCallsPerRun) return 'per-send tool limit reached';
    if (_gitLabRequests + requests > maxGitLabRequests) {
      return 'GitLab request limit reached';
    }
    if (search && _searches >= maxSearches) return 'search limit reached';
    _turnCalls++;
    _runCalls++;
    _gitLabRequests += requests;
    if (search) _searches++;
    return null;
  }

  void refundRequests(int requests) {
    if (requests < 0 || requests > _gitLabRequests) {
      throw RangeError.value(requests, 'requests');
    }
    _gitLabRequests -= requests;
  }

  int availableOutput(int requested) {
    final runRemaining = maxOutputChars - _outputChars;
    if (runRemaining <= 0) return 0;
    final single = requested < maxSingleOutputChars
        ? requested
        : maxSingleOutputChars;
    return single < runRemaining ? single : runRemaining;
  }

  void recordOutput(int chars) => _outputChars += chars;
}

final class AiToolExecution {
  const AiToolExecution({
    required this.result,
    required this.provenance,
    required this.blocked,
    required this.truncated,
    required this.redactions,
    required this.withheldPrivateKeyContext,
    required this.gitLabRequests,
  });

  final AiToolResult result;
  final AiToolProvenance provenance;
  final bool blocked;
  final bool truncated;
  final int redactions;
  final bool withheldPrivateKeyContext;
  final int gitLabRequests;
}

final class AiToolCatalogue {
  AiToolCatalogue({
    required this.port,
    required this.scope,
    required this.redactor,
    this.refreshSecrets,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AiGitLabReadPort port;
  final AiResourceScope scope;
  final Redactor redactor;
  final Future<void> Function()? refreshSecrets;
  final DateTime Function() _now;
  final Random _nonceRandom = Random.secure();

  static final List<AiToolSpec> _specs = List.unmodifiable([
    _spec(
      'read_file',
      'Read a text file at the pinned head or base commit.',
      {
        'path': _string,
        'revision': _enum(['head', 'base']),
      },
      ['path', 'revision'],
    ),
    _spec(
      'list_directory',
      'List names and types at a pinned commit.',
      {
        'path': _string,
        'revision': _enum(['head', 'base']),
      },
      ['path', 'revision'],
    ),
    _spec(
      'get_issue',
      'Read one issue and its newest non-system notes.',
      {'iid': _positiveInteger},
      ['iid'],
    ),
    _spec(
      'get_merge_request',
      'Read one merge request and its newest non-system notes.',
      {'iid': _positiveInteger},
      ['iid'],
    ),
    _spec(
      'get_merge_request_diff',
      'Read the current merge request diff.',
      const {},
      const [],
    ),
    _spec(
      'get_pipeline_jobs',
      'Read jobs from the current pipeline.',
      const {},
      const [],
    ),
    _spec(
      'get_job_log',
      'Read a project job trace from offset zero.',
      {'job_id': _positiveInteger, 'tail_lines': _positiveInteger},
      ['job_id'],
      optional: ['tail_lines'],
    ),
    _spec(
      'get_commit',
      'Read one commit by its complete SHA.',
      {'sha': _string},
      ['sha'],
    ),
    _spec(
      'get_commit_diff',
      'Read one commit diff by its complete SHA.',
      {'sha': _string},
      ['sha'],
    ),
    _spec(
      'search_project',
      'Search only this GitLab project.',
      {
        'scope': _enum(['blobs', 'issues', 'merge_requests', 'commits']),
        'query': _string,
      },
      ['scope', 'query'],
    ),
  ]);

  List<AiToolSpec> get specs => _specs;

  Future<AiToolResult> executeResult(
    AiToolCall call, {
    required AiToolBudget budget,
  }) async {
    final execution = await execute(call, budget: budget);
    return AiToolResult.fromData(
      callId: execution.result.callId,
      name: execution.result.name,
      data: execution.result.plainData,
      isError: execution.result.isError,
      withheldPrivateKeyContext: execution.withheldPrivateKeyContext,
      truncated: execution.truncated,
      blockedSensitive: execution.blocked,
    );
  }

  Future<AiToolExecution> execute(
    AiToolCall call, {
    required AiToolBudget budget,
  }) async {
    final fallback = _live('bound project');
    var reservedRequests = 0;
    var completedRequests = 0;
    try {
      final arguments = _arguments(call);
      final requestCost = _requestCost(call.name);
      // GitLabApi may retry each logical read once after a 401 token refresh.
      // Reserve that worst case because the narrow port intentionally exposes
      // logical reads rather than GitLabApi transport internals.
      final reservedCost = requestCost * 2;
      final budgetError = budget.reserve(
        requests: reservedCost,
        search: call.name == 'search_project',
      );
      if (budgetError != null) {
        return await _error(call, fallback, budgetError, budget: budget);
      }
      reservedRequests = reservedCost;
      final raw = await _dispatch(call.name, arguments);
      completedRequests = raw.requestCount;
      if (completedRequests > requestCost) {
        throw _ToolValidation(
          'tool exceeded its request allowance',
          requestCount: completedRequests,
        );
      }
      final completedRequestAllowance = raw.requestCount * 2;
      if (completedRequestAllowance < reservedCost) {
        budget.refundRequests(reservedCost - completedRequestAllowance);
        reservedRequests = completedRequestAllowance;
      }
      await refreshSecrets?.call();
      final provenance = raw.provenance;
      final cleanValue = _sanitizeJson(raw.value);
      final cleanText = raw.json
          ? jsonEncode(cleanValue)
          : cleanValue as String;
      if (utf8.encode(cleanText).length > 2 * 1024 * 1024) {
        throw _ToolValidation(
          'tool source exceeds the redaction limit',
          requestCount: completedRequests,
        );
      }
      final structured = raw.json
          ? _redactStructured(cleanValue, raw.fragmentFields)
          : null;
      final redacted =
          structured?.redaction ?? redactor.redactSource(cleanText);
      final redactedProvenance = redactor.redactSource(provenance.label);
      final redactedText = raw.tailLines == null
          ? redacted.text
          : _lastLines(redacted.text, raw.tailLines!);
      final data = AiAppText.join([
        AiAppText.plain(redactedProvenance.text).escaped(),
        AiAppText.untrusted(
          source: call.name,
          nonce: _nextNonce(),
          body: structured?.data ?? AiAppText.plain(redactedText),
        ),
      ]);
      final completeContent = data.encode();
      final available = budget.availableOutput(completeContent.length);
      final clipped = data.clipped(available);
      final content = clipped.encode();
      final truncated = content.length != completeContent.length;
      budget.recordOutput(content.length);
      return AiToolExecution(
        result: AiToolResult.fromData(
          callId: call.id,
          name: call.name,
          data: clipped,
        ),
        provenance: provenance,
        blocked: raw.blocked,
        truncated: truncated,
        redactions: redacted.redactions + redactedProvenance.redactions,
        withheldPrivateKeyContext:
            redacted.withheldPrivateKeyContext ||
            redactedProvenance.withheldPrivateKeyContext,
        gitLabRequests: raw.requestCount,
      );
    } on _ToolValidation catch (error) {
      completedRequests = completedRequests > error.requestCount
          ? completedRequests
          : error.requestCount;
      final refundable = reservedRequests - (completedRequests * 2);
      if (refundable > 0) budget.refundRequests(refundable);
      return await _error(
        call,
        fallback,
        error.message,
        budget: budget,
        gitLabRequests: completedRequests,
      );
    } on Object {
      return await _error(
        call,
        fallback,
        'read failed',
        budget: budget,
        gitLabRequests: reservedRequests ~/ 2,
      );
    }
  }

  Future<_RawToolResult> _dispatch(
    String name,
    Map<String, Object?> arguments,
  ) => switch (name) {
    'read_file' => _readFile(arguments),
    'list_directory' => _listDirectory(arguments),
    'get_issue' => _issue(arguments),
    'get_merge_request' => _mergeRequest(arguments),
    'get_merge_request_diff' => _mergeRequestDiff(),
    'get_pipeline_jobs' => _pipelineJobs(),
    'get_job_log' => _jobLog(arguments),
    'get_commit' => _commit(arguments),
    'get_commit_diff' => _commitDiff(arguments),
    'search_project' => _search(arguments),
    _ => throw const _ToolValidation('unknown tool'),
  };

  Future<_RawToolResult> _readFile(Map<String, Object?> args) async {
    _exactKeys(args, required: const {'path', 'revision'});
    final path = _path(args['path']);
    final revision = _revision(args['revision']);
    if (isSensitiveRepositoryPath(path)) {
      return _RawToolResult(
        aiSensitivePathBlocked,
        _pinned('file $path', revision),
        blocked: true,
        requestCount: 0,
      );
    }
    final read = await port.readFile(revision.sha, path);
    return _RawToolResult(
      read.value,
      _pinned('file $path', revision),
      requestCount: read.requestCount,
    );
  }

  Future<_RawToolResult> _listDirectory(Map<String, Object?> args) async {
    _exactKeys(args, required: const {'path', 'revision'});
    final path = _path(args['path']);
    final revision = _revision(args['revision']);
    final read = await port.listDirectory(revision.sha, path);
    final projected = [
      for (final item in read.value)
        {'name': item.name, 'path': item.path, 'type': item.type},
    ];
    return _RawToolResult.json(
      {'items': projected, 'incomplete': read.incomplete},
      _pinned('directory ${path.isEmpty ? '/' : path}', revision),
      requestCount: read.requestCount,
    );
  }

  Future<_RawToolResult> _issue(Map<String, Object?> args) async {
    _exactKeys(args, required: const {'iid'});
    final iid = _positiveInt(args['iid'], 'iid');
    final read = await port.issue(iid);
    return _RawToolResult.json(
      _projectDiscussion(read.value),
      _live('issue #$iid'),
      requestCount: read.requestCount,
    );
  }

  Future<_RawToolResult> _mergeRequest(Map<String, Object?> args) async {
    _exactKeys(args, required: const {'iid'});
    final iid = _positiveInt(args['iid'], 'iid');
    final read = await port.mergeRequest(iid);
    return _RawToolResult.json(
      _projectDiscussion(read.value),
      _live('merge request !$iid'),
      requestCount: read.requestCount,
    );
  }

  Future<_RawToolResult> _mergeRequestDiff() async {
    if (scope.current.kind != AiResourceKind.mergeRequest) {
      throw const _ToolValidation('no current merge request');
    }
    final head = _headRevision().sha;
    final base = scope.baseSha;
    if (base == null || !isFullCommitSha(base)) {
      throw const _ToolValidation('current resource has no pinned base commit');
    }
    final read = await port.mergeRequestDiff(
      scope.current.id,
      headSha: head,
      baseSha: base,
    );
    final refs = read.value['diff_refs'];
    if (refs is! Map<String, Object?> ||
        refs['head_sha'] != scope.headSha ||
        refs['base_sha'] != scope.baseSha) {
      throw _ToolValidation(
        'merge request diff revision changed',
        requestCount: read.requestCount,
      );
    }
    final changes = read.value['changes'];
    if (changes is! List<Object?>) {
      throw _ToolValidation(
        'merge request diff is invalid',
        requestCount: read.requestCount,
      );
    }
    return _diffResult(
      [
        for (final value in changes)
          if (value is AiJson) value,
      ],
      _pinned('merge request !${scope.current.id} diff', _headRevision()),
      requestCount: read.requestCount,
      incomplete: read.incomplete,
    );
  }

  Future<_RawToolResult> _pipelineJobs() async {
    final pipelineId = scope.pipelineId;
    if (pipelineId == null) throw const _ToolValidation('no current pipeline');
    final read = await port.pipelineJobs(pipelineId);
    return _RawToolResult.json(
      {
        'items': [
          for (final row in read.value)
            _pick(row, const [
              'id',
              'name',
              'stage',
              'status',
              'failure_reason',
              'ref',
              'created_at',
              'started_at',
              'finished_at',
              'duration',
            ]),
        ],
        'incomplete': read.incomplete,
      },
      _live('pipeline #$pipelineId jobs'),
      requestCount: read.requestCount,
    );
  }

  Future<_RawToolResult> _jobLog(Map<String, Object?> args) async {
    _exactKeys(
      args,
      required: const {'job_id'},
      optional: const {'tail_lines'},
    );
    final jobId = _positiveInt(args['job_id'], 'job_id');
    final tailLines = args['tail_lines'] == null
        ? 300
        : _positiveInt(args['tail_lines'], 'tail_lines');
    if (tailLines > 2000) throw const _ToolValidation('tail_lines too large');
    final read = await port.jobLog(jobId);
    return _RawToolResult(
      _stripTrace(read.value),
      _live('job #$jobId log'),
      requestCount: read.requestCount,
      tailLines: tailLines,
    );
  }

  Future<_RawToolResult> _commit(Map<String, Object?> args) async {
    _exactKeys(args, required: const {'sha'});
    final sha = _sha(args['sha']);
    final read = await port.commit(sha);
    return _RawToolResult.json(
      _pick(read.value, const [
        'id',
        'short_id',
        'title',
        'message',
        'author_name',
        'authored_date',
        'committer_name',
        'committed_date',
        'parent_ids',
        'web_url',
      ]),
      _live('commit ${_short(sha)}'),
      requestCount: read.requestCount,
    );
  }

  Future<_RawToolResult> _commitDiff(Map<String, Object?> args) async {
    _exactKeys(args, required: const {'sha'});
    final sha = _sha(args['sha']);
    final read = await port.commitDiff(sha);
    return _diffResult(
      read.value,
      _live('commit ${_short(sha)} diff'),
      requestCount: read.requestCount,
      incomplete: read.incomplete,
    );
  }

  Future<_RawToolResult> _search(Map<String, Object?> args) async {
    _exactKeys(args, required: const {'scope', 'query'});
    final searchScope = _oneOf(args['scope'], const {
      'blobs',
      'issues',
      'merge_requests',
      'commits',
    }, 'scope');
    final query = _nonEmptyString(args['query'], 'query', max: 256);
    final read = await port.search(searchScope, query);
    final rows = <AiJson>[];
    for (final row in read.value) {
      if (searchScope == 'blobs') {
        final path = row['path'];
        if (path is! String || isSensitiveRepositoryPath(path)) continue;
        rows.add(
          _pick(row, const ['path', 'filename', 'ref', 'startline', 'data']),
        );
      } else {
        rows.add(
          _pick(row, const [
            'id',
            'iid',
            'title',
            'description',
            'state',
            'web_url',
            'created_at',
            'updated_at',
            'path',
            'filename',
            'ref',
            'startline',
            'data',
          ]),
        );
      }
    }
    return _RawToolResult.json(
      {'items': rows, 'incomplete': read.incomplete},
      _live(
        'search $searchScope on ${scope.defaultBranch ?? 'default branch'}',
      ),
      fragmentFields: searchScope == 'blobs' ? const {'data'} : const {},
      requestCount: read.requestCount,
    );
  }

  _RawToolResult _diffResult(
    List<AiJson> rows,
    AiToolProvenance provenance, {
    required int requestCount,
    required bool incomplete,
  }) {
    var blocked = false;
    final projected = <AiJson>[];
    for (final row in rows) {
      final oldPath = row['old_path'];
      final newPath = row['new_path'];
      final sensitive =
          oldPath is String && isSensitiveRepositoryPath(oldPath) ||
          newPath is String && isSensitiveRepositoryPath(newPath);
      blocked |= sensitive;
      projected.add({
        ..._pick(row, const [
          'old_path',
          'new_path',
          'new_file',
          'renamed_file',
          'deleted_file',
        ]),
        'diff': sensitive ? aiSensitivePathBlocked : _sanitizeJson(row['diff']),
      });
    }
    return _RawToolResult.json(
      {'items': projected, 'incomplete': incomplete},
      provenance,
      blocked: blocked,
      fragmentFields: const {'diff'},
      requestCount: requestCount,
    );
  }

  Future<AiToolExecution> _error(
    AiToolCall call,
    AiToolProvenance provenance,
    String message, {
    required AiToolBudget budget,
    int gitLabRequests = 0,
  }) async {
    try {
      await refreshSecrets?.call();
    } on Object {
      // Error text below is static; an unavailable refresh must not replace the
      // original bounded failure with provider or transport detail.
    }
    final redactedProvenance = redactor.redactSource(provenance.label);
    final redactedMessage = redactor.redactSource(message);
    final data = AiAppText.join([
      AiAppText.plain(redactedProvenance.text).escaped(),
      AiAppText.join([
        const AiAppText.plain('error: '),
        AiAppText.plain(redactedMessage.text).escaped(),
      ], ''),
    ]);
    final completeContent = data.encode();
    final available = budget.availableOutput(completeContent.length);
    final clipped = data.clipped(available);
    final content = clipped.encode();
    budget.recordOutput(content.length);
    return AiToolExecution(
      result: AiToolResult.fromData(
        callId: call.id,
        name: call.name,
        data: clipped,
        isError: true,
      ),
      provenance: provenance,
      blocked: message.contains('sensitive'),
      truncated: content.length != completeContent.length,
      redactions: redactedProvenance.redactions + redactedMessage.redactions,
      withheldPrivateKeyContext:
          redactedProvenance.withheldPrivateKeyContext ||
          redactedMessage.withheldPrivateKeyContext,
      gitLabRequests: gitLabRequests,
    );
  }

  String _nextNonce() =>
      'tool-${_nonceRandom.nextInt(0x7fffffff).toRadixString(16)}'
      '${_nonceRandom.nextInt(0x7fffffff).toRadixString(16)}';

  AiToolProvenance _live(String resource) => AiToolProvenance(
    resource: resource,
    freshness: AiProvenanceFreshness.live,
    observedAt: _now(),
  );

  AiToolProvenance _pinned(String resource, _Revision revision) =>
      AiToolProvenance(
        resource: resource,
        freshness: revision.freshness,
        revision: revision.sha,
      );

  ({AiAppText data, RedactionResult redaction}) _redactStructured(
    Object? value,
    Set<String> fragmentFields,
  ) {
    var redactions = 0;
    var withheld = false;
    Object? visit(Object? current, {String? field}) => switch (current) {
      String text => () {
        final result = fragmentFields.contains(field)
            ? redactor.redactFragment(text)
            : redactor.redactSource(text);
        redactions += result.redactions;
        withheld |= result.withheldPrivateKeyContext;
        return result.text;
      }(),
      List<Object?> values => [for (final item in values) visit(item)],
      Map<String, Object?> values => {
        for (final entry in values.entries)
          entry.key: visit(entry.value, field: entry.key),
      },
      _ => current,
    };
    final data = AiAppText.json(visit(value));
    return (
      data: data,
      redaction: RedactionResult(
        data.encode(),
        redactions,
        withheldPrivateKeyContext: withheld,
      ),
    );
  }

  _Revision _headRevision() {
    final sha = scope.headSha;
    if (sha == null || !isFullCommitSha(sha)) {
      throw const _ToolValidation('current resource has no pinned commit');
    }
    return _Revision(sha, AiProvenanceFreshness.pinnedHead);
  }

  _Revision _revision(Object? value) {
    if (value == 'head') return _headRevision();
    if (value == 'base') {
      final sha = scope.baseSha;
      if (sha == null || !isFullCommitSha(sha)) {
        throw const _ToolValidation(
          'current resource has no pinned base commit',
        );
      }
      return _Revision(sha, AiProvenanceFreshness.pinnedBase);
    }
    throw const _ToolValidation('revision must be head or base');
  }
}

final class _RawToolResult {
  const _RawToolResult(
    String this.value,
    this.provenance, {
    this.blocked = false,
    this.requestCount = 0,
    this.tailLines,
  }) : json = false,
       fragmentFields = const {};

  const _RawToolResult.json(
    this.value,
    this.provenance, {
    this.blocked = false,
    this.requestCount = 0,
    this.fragmentFields = const {},
  }) : json = true,
       tailLines = null;

  final Object? value;
  final AiToolProvenance provenance;
  final bool blocked;
  final bool json;
  final Set<String> fragmentFields;
  final int requestCount;
  final int? tailLines;
}

final class _Revision {
  const _Revision(this.sha, this.freshness);
  final String sha;
  final AiProvenanceFreshness freshness;
}

final class _ToolValidation implements Exception {
  const _ToolValidation(this.message, {this.requestCount = 0});
  final String message;
  final int requestCount;
}

const _string = <String, Object?>{'type': 'string'};
const _positiveInteger = <String, Object?>{'type': 'integer', 'minimum': 1};

Map<String, Object?> _enum(List<String> values) => {
  'type': 'string',
  'enum': values,
};

AiToolSpec _spec(
  String name,
  String description,
  Map<String, Object?> properties,
  List<String> required, {
  List<String> optional = const [],
}) => AiToolSpec(
  name: name,
  description: description,
  parameters: {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  },
);

Map<String, Object?> _arguments(AiToolCall call) {
  final value = call.arguments;
  if (value is! Map<String, Object?>) {
    throw const _ToolValidation('arguments must be an object');
  }
  return value;
}

void _exactKeys(
  Map<String, Object?> args, {
  required Set<String> required,
  Set<String> optional = const {},
}) {
  if (!args.keys.toSet().containsAll(required) ||
      args.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      )) {
    throw const _ToolValidation('arguments do not match the schema');
  }
}

String _path(Object? value) {
  final path = _nonEmptyString(value, 'path', max: 1024, allowEmpty: true);
  if (!isValidRepositoryPath(path) || _controlCharacters.hasMatch(path)) {
    throw const _ToolValidation('invalid path');
  }
  return path;
}

String _sha(Object? value) {
  final sha = _nonEmptyString(value, 'sha', max: 64);
  if (!isFullCommitSha(sha)) {
    throw const _ToolValidation('complete SHA required');
  }
  return sha;
}

int _positiveInt(Object? value, String name) {
  if (value is! int || value <= 0) {
    throw _ToolValidation('$name must be positive');
  }
  return value;
}

String _oneOf(Object? value, Set<String> choices, String name) {
  if (value is! String || !choices.contains(value)) {
    throw _ToolValidation('invalid $name');
  }
  return value;
}

String _nonEmptyString(
  Object? value,
  String name, {
  required int max,
  bool allowEmpty = false,
}) {
  if (value is! String ||
      value.length > max ||
      (!allowEmpty && value.trim().isEmpty)) {
    throw _ToolValidation('invalid $name');
  }
  return value;
}

int _requestCost(String name) => switch (name) {
  'read_file' => 2,
  'list_directory' => 4,
  'get_issue' || 'get_merge_request' => 2,
  'get_merge_request_diff' => 2,
  'get_job_log' => 4,
  _ => 1,
};

AiJson _pick(AiJson source, List<String> keys) => {
  for (final key in keys)
    if (source.containsKey(key)) key: source[key],
};

AiJson _projectDiscussion(AiJson source) {
  final notes = source['notes'];
  final projectedNotes = <AiJson>[];
  if (notes is List<Object?>) {
    for (final value in notes.reversed) {
      if (value is! Map<String, Object?> || value['system'] == true) continue;
      final note = _pick(value, const [
        'id',
        'body',
        'created_at',
        'updated_at',
      ]);
      final author = _projectAuthor(value['author']);
      if (author != null) note['author'] = author;
      projectedNotes.add(note);
    }
  }
  final projected = {
    ..._pick(source, const [
      'id',
      'iid',
      'title',
      'description',
      'state',
      'labels',
      'created_at',
      'updated_at',
      'closed_at',
      'merged_at',
      'web_url',
    ]),
    'notes': projectedNotes,
  };
  final author = _projectAuthor(source['author']);
  if (author != null) projected['author'] = author;
  return projected;
}

AiJson? _projectAuthor(Object? value) => value is AiJson
    ? _pick(value, const ['id', 'username', 'name', 'state', 'web_url'])
    : null;

String _stripTrace(String text) {
  final marker = RegExp(
    r'section_(?:start|end):\d+:[A-Za-z0-9_.-]+(?:\[collapsed=(?:true|false)\])?\r?',
  );
  final timestamp = RegExp(
    r'^\d{4}-[01]\d-[0-3]\dT[0-2]\d:[0-5]\d:[0-5]\d\.\d{6}Z [0-9a-f]{2}[EO][+ ]',
    multiLine: true,
  );
  return text
      .replaceAll(_ansi, '')
      .replaceAll(marker, '')
      .replaceAll(timestamp, '');
}

final _ansi = RegExp(
  r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-_])',
);
final _controlCharacters = RegExp(r'[\x00-\x1f\x7f]');

String _stripAnsi(String value) => value.replaceAll(_ansi, '');

Object? _sanitizeJson(Object? value) => switch (value) {
  String text => _stripAnsi(text),
  List<Object?> values => [for (final item in values) _sanitizeJson(item)],
  Map<String, Object?> values => {
    for (final entry in values.entries) entry.key: _sanitizeJson(entry.value),
  },
  _ => value,
};

String _lastLines(String value, int count) {
  final lines = value.split('\n');
  final start = lines.length > count ? lines.length - count : 0;
  return lines.sublist(start).join('\n');
}

String _short(String value) =>
    value.substring(0, value.length < 12 ? value.length : 12);
