import '../app_text.dart';
import 'dart:convert';
import 'dart:math';

import '../../request_meter.dart';
import '../ai_transcript.dart';
import '../redaction.dart';
import '../wire/wire_format.dart';
import '../write_text.dart'
    show AiFieldProvenance, AiTextBlockCode, UploadPlaceholderTable;
import 'field_provenance.dart';
import 'gitlab_read_port.dart';
import 'release_policy.dart';
import 'sensitive_paths.dart';
import 'tool_scope.dart';

export 'tool_catalogue_version.dart' show aiToolCatalogueVersion;

const aiSensitivePathBlocked = '[blocked by policy: sensitive file]';

/// No read name is released without its own evidence (MR7 §3.1).
const Set<String> aiReleasedReadNames = <String>{};

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

  String? reserve({
    required int requests,
    required bool search,
    bool countCall = true,
  }) {
    if (countCall && _turnCalls >= maxCallsPerTurn) {
      return 'per-turn tool limit reached';
    }
    if (countCall && _runCalls >= maxCallsPerRun) {
      return 'per-send tool limit reached';
    }
    if (_gitLabRequests + requests > maxGitLabRequests) {
      return 'GitLab request limit reached';
    }
    if (countCall && search && _searches >= maxSearches) {
      return 'search limit reached';
    }
    if (countCall) {
      _turnCalls++;
      _runCalls++;
    }
    _gitLabRequests += requests;
    if (countCall && search) _searches++;
    return null;
  }

  void refundRequests(int requests) {
    if (requests < 0 || requests > _gitLabRequests) {
      throw RangeError.value(requests, 'requests');
    }
    _gitLabRequests -= requests;
  }

  void settleRequests({required int reserved, required int measured}) {
    if (reserved < 0 || reserved > _gitLabRequests) {
      throw RangeError.value(reserved, 'reserved');
    }
    if (measured < 0) throw RangeError.value(measured, 'measured');
    // Physical sends remain chargeable even when a lower reservation was
    // breached by a transport hidden behind the narrow read port.
    _gitLabRequests += measured - reserved;
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
    this.fetchedAt,
    this.recordDelivery,
  });

  final AiToolResult result;
  final AiToolProvenance provenance;
  final bool blocked;
  final bool truncated;
  final int redactions;
  final bool withheldPrivateKeyContext;
  final int gitLabRequests;
  final DateTime? fetchedAt;
  final void Function(AiAppText delivered)? recordDelivery;
}

final class AiToolCatalogue {
  AiToolCatalogue({
    required AiGitLabReadPort port,
    required AiResourceScope scope,
    required this.redactor,
    this.releasePolicy = productionAiReleasePolicy,
    this.refreshSecrets,
    this.placeholders,
    DateTime Function()? now,
  }) : _port = port,
       _scope = scope,
       _groupPort = null,
       _groupScope = null,
       _now = now ?? DateTime.now;

  AiToolCatalogue.group({
    required AiGitLabGroupReadPort port,
    required AiGroupResourceScope scope,
    required this.redactor,
    this.releasePolicy = productionAiReleasePolicy,
    this.refreshSecrets,
    this.placeholders,
    DateTime Function()? now,
  }) : _port = null,
       _scope = null,
       _groupPort = port,
       _groupScope = scope,
       _now = now ?? DateTime.now;

  final AiGitLabReadPort? _port;
  final AiResourceScope? _scope;
  final AiGitLabGroupReadPort? _groupPort;
  final AiGroupResourceScope? _groupScope;
  AiGitLabReadPort get port =>
      _port ?? (throw const _ToolValidation('project tools unavailable'));
  AiResourceScope get scope =>
      _scope ?? (throw const _ToolValidation('project tools unavailable'));
  final Redactor redactor;
  final AiReleasePolicyView releasePolicy;
  final Future<void> Function()? refreshSecrets;

  /// The conversation's upload placeholder table. With it, the complete
  /// descriptions and note bodies returned by project resource reads carry
  /// restorable
  /// `[[upload:u-<n>]]` tokens; every other value keeps ordinary markers.
  final UploadPlaceholderTable? placeholders;
  final DateTime Function() _now;
  final Random _nonceRandom = Random.secure();
  final _fetchedAt = Expando<DateTime>();
  final _deliveryRecords = Expando<void Function(AiAppText)>();

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

  static final List<AiToolSpec> _fieldSpecs = List.unmodifiable([
    _spec(
      'get_release',
      'Read one existing release by its exact tag name.',
      {'tag_name': _string},
      ['tag_name'],
    ),
    _spec(
      'get_milestone',
      'Read one project milestone by its numeric ID, not its iid.',
      {'milestone_id': _positiveInteger},
      ['milestone_id'],
    ),
    _spec(
      'get_snippet',
      'Read project snippet metadata, file paths and one text file. '
          'Defaults to the first listed file at HEAD.',
      {'snippet_id': _positiveInteger, 'file_path': _string, 'ref': _string},
      ['snippet_id'],
      optional: ['file_path', 'ref'],
    ),
  ]);

  static final List<AiToolSpec> _groupSpecs = List.unmodifiable([
    _spec(
      'get_group_work_item',
      'Read the bound group work item.',
      {'groupId': _positiveInteger, 'iid': _positiveInteger},
      ['groupId', 'iid'],
    ),
  ]);

  List<AiToolSpec> get specs => List.unmodifiable(
    _availableSpecs.where((spec) => releasePolicy.allowsRead(spec.name)),
  );

  List<AiToolSpec> get _availableSpecs => _groupPort != null
      ? _groupSpecs
      : port is AiGitLabFieldReadPort
      ? List.unmodifiable([..._specs, ..._fieldSpecs])
      : _specs;

  Future<AiToolResult> executeResult(
    AiToolCall call, {
    required AiToolBudget budget,
  }) async {
    return _result(await execute(call, budget: budget));
  }

  AiToolResult _result(AiToolExecution execution) => AiToolResult.fromData(
    callId: execution.result.callId,
    name: execution.result.name,
    data: execution.result.plainData,
    isError: execution.result.isError,
    withheldPrivateKeyContext: execution.withheldPrivateKeyContext,
    truncated: execution.truncated,
    blockedSensitive: execution.blocked,
    readConfidential: execution.result.readConfidential,
    readInternal: execution.result.readInternal,
    readVisibility: execution.result.readVisibility,
    uploadPlaceholders: execution.result.uploadPlaceholders,
  );

  /// Re-read each expired pending result once, then fail closed after the last
  /// asynchronous secret/owner check. Already delivered transcript entries are
  /// never passed here.
  Future<
    ({List<AiToolResult> results, void Function(List<AiToolResult>) delivered})
  >
  prepareDelivery(
    List<AiToolCall> calls,
    List<AiToolResult> results, {
    required AiToolBudget budget,
    required Future<void> Function() beforeDelivery,
  }) async {
    final prepared = [...results];
    final fetchedAt = [for (final call in calls) _fetchedAt[call]];
    final recordDelivery = <void Function(AiAppText)?>[
      for (final call in calls) _deliveryRecords[call],
    ];
    for (var i = 0; i < prepared.length; i++) {
      if (!prepared[i].isError && _expired(fetchedAt[i])) {
        // The owner checks cancellation before every new source operation.
        await beforeDelivery();
        final execution = await _execute(
          calls[i],
          budget: budget,
          reread: true,
        );
        prepared[i] = _result(execution);
        fetchedAt[i] = execution.fetchedAt;
        recordDelivery[i] = execution.recordDelivery;
      }
    }
    await beforeDelivery();
    final delivery = [
      for (var i = 0; i < prepared.length; i++)
        if (!prepared[i].isError && _expired(fetchedAt[i]))
          AiToolResult.fromData(
            callId: calls[i].id,
            name: calls[i].name,
            data: const AiAppText.plain('read failed'),
            isError: true,
          )
        else
          prepared[i],
    ];
    return (
      results: delivery,
      delivered: (List<AiToolResult> results) {
        for (var i = 0; i < results.length; i++) {
          if (!results[i].isError) {
            recordDelivery[i]?.call(results[i].plainData);
          }
        }
      },
    );
  }

  Future<AiToolExecution> execute(
    AiToolCall call, {
    required AiToolBudget budget,
  }) => _execute(call, budget: budget);

  Future<AiToolExecution> _execute(
    AiToolCall call, {
    required AiToolBudget budget,
    bool reread = false,
  }) async {
    final fallback = _live(_groupScope?.workItemGid ?? 'bound project');
    if (!reread) {
      _fetchedAt[call] = null;
      _deliveryRecords[call] = null;
    }
    var reservedRequests = 0;
    var completedRequests = 0;
    RequestMeter? requestMeter;
    try {
      if (!releasePolicy.allowsRead(call.name)) {
        throw const _ToolValidation('unknown tool');
      }
      final arguments = _arguments(call);
      final requestCost = _requestCost(call.name);
      final nativePort = _port is GitLabAiReadPort ? _port : null;
      // Narrow custom ports retain their conservative allowance. The native
      // port reserves and settles each bounded read immediately around the API.
      final reservedCost = nativePort == null ? requestCost * 2 : 0;
      final budgetError = budget.reserve(
        requests: reservedCost,
        search: call.name == 'search_project',
        countCall: !reread,
      );
      if (budgetError != null) {
        return await _error(
          call,
          fallback,
          budgetError,
          budget: budget,
          countOutput: !reread,
        );
      }
      reservedRequests = reservedCost;
      requestMeter = RequestMeter();
      Future<_RawToolResult> dispatch() => requestMeter!.runAsync(
        () => nativePort == null
            ? _dispatch(call.name, arguments)
            : nativePort.withBeforeRead(
                () => _dispatch(call.name, arguments),
                beforeRead: (maximum) {
                  if (budget.gitLabRequests + maximum >
                      budget.maxGitLabRequests) {
                    throw const _ToolValidation('GitLab request limit reached');
                  }
                  final before = requestMeter!.count;
                  budget.settleRequests(reserved: 0, measured: maximum);
                  return () => budget.settleRequests(
                    reserved: maximum,
                    measured: requestMeter!.count - before,
                  );
                },
              ),
      );
      var raw = await dispatch();
      await refreshSecrets?.call();
      if (_expired(raw.fetchedAt)) {
        if (reread || raw.freshnessRetried) {
          throw const _ToolValidation('read failed');
        }
        raw = await dispatch();
        await refreshSecrets?.call();
        if (_expired(raw.fetchedAt)) {
          throw const _ToolValidation('read failed');
        }
      }
      completedRequests = requestMeter.count;
      if (nativePort == null && completedRequests > reservedCost) {
        throw _ToolValidation(
          'tool exceeded its request allowance',
          requestCount: completedRequests,
        );
      }
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
      var restorable = placeholders == null ? null : raw.restorable;
      var deliveries = placeholders == null
          ? null
          : raw.deliveries ?? raw.restorable;
      var structured = raw.json
          ? _redactStructured(
              cleanValue,
              raw.fragmentFields,
              restorable: restorable,
            )
          : null;
      var redacted = structured?.redaction ?? redactor.redactSource(cleanText);
      final redactedProvenance = redactor.redactSource(provenance.label);
      final nonce = _nextNonce();
      AiAppText buildData() {
        final redactedText = raw.tailLines == null
            ? redacted.text
            : _lastLines(redacted.text, raw.tailLines!);
        return AiAppText.join([
          AiAppText.plain(redactedProvenance.text).escaped(),
          AiAppText.untrusted(
            source: call.name,
            nonce: nonce,
            body: structured?.data ?? AiAppText.plain(redactedText),
          ),
        ]);
      }

      var data = buildData();
      var completeContent = data.encode();
      // Delivery replaces already charged output; the runner clips it to the
      // original result's allowance before encoding the provider request.
      var available = reread
          ? min(completeContent.length, budget.maxSingleOutputChars)
          : budget.availableOutput(completeContent.length);
      var groupClipped = false;
      if (_groupPort != null &&
          restorable != null &&
          data.clipped(available).encode().length != completeContent.length) {
        // A clipped group description must not expose a restorable token.
        // Invalidate any earlier whole delivery of this field in this table.
        final owner = cleanValue;
        if (owner is Map<String, Object?>) {
          final field = restorable(const ['description'], owner);
          if (field != null) {
            placeholders!.recordFieldDelivery(field, whole: false);
          }
        }
        structured = _redactStructured(cleanValue, raw.fragmentFields);
        redacted = structured.redaction;
        restorable = null;
        // Keep tracking the title after dropping restorable tokens. The
        // description remains cut until a later complete group delivery.
        final tracked = deliveries;
        deliveries = tracked == null
            ? null
            : (path, owner) => path.length == 1 && path.single == 'title'
                  ? tracked(path, owner)
                  : null;
        data = buildData();
        completeContent = data.encode();
        available = reread
            ? min(completeContent.length, budget.maxSingleOutputChars)
            : budget.availableOutput(completeContent.length);
        groupClipped = true;
      }
      final clipped = data.clipped(available);
      final content = clipped.encode();
      final truncated =
          groupClipped || content.length != completeContent.length;
      if (!reread) budget.recordOutput(content.length);
      if (structured != null && deliveries != null) {
        _recordDeliveries(
          data,
          clipped,
          structured.value,
          deliveries,
          allowWhole: !reread,
          allowTitleWhole: false,
        );
      }
      final fetchedAt = raw.fetchedAt ?? raw.provenance.observedAt;
      // A failed provider send restores the original pending result. Keep its
      // timestamp paired with that result; refreshed delivery data is local.
      if (!reread) _fetchedAt[call] = fetchedAt;
      final deliveryStructured = structured;
      final deliveryFields = deliveries;
      final deliveryData = data;
      final execution = AiToolExecution(
        result: AiToolResult.fromData(
          callId: call.id,
          name: call.name,
          data: clipped,
          readConfidential: !raw.blocked && raw.readConfidential,
          readInternal: !raw.blocked && raw.readInternal,
          readVisibility: raw.blocked ? null : raw.readVisibility,
          uploadPlaceholders: restorable != null,
        ),
        provenance: provenance,
        blocked: raw.blocked,
        truncated: truncated,
        redactions: redacted.redactions + redactedProvenance.redactions,
        withheldPrivateKeyContext:
            redacted.withheldPrivateKeyContext ||
            redactedProvenance.withheldPrivateKeyContext,
        gitLabRequests: completedRequests,
        fetchedAt: fetchedAt,
        recordDelivery: deliveryStructured != null && deliveryFields != null
            ? (delivered) => _recordDeliveries(
                deliveryData,
                delivered,
                deliveryStructured.value,
                deliveryFields,
              )
            : null,
      );
      if (!reread) _deliveryRecords[call] = execution.recordDelivery;
      return execution;
    } on _ToolValidation catch (error) {
      completedRequests = requestMeter?.count ?? 0;
      return await _error(
        call,
        fallback,
        error.message,
        budget: budget,
        gitLabRequests: completedRequests,
        countOutput: !reread,
      );
    } on Object {
      completedRequests = requestMeter?.count ?? 0;
      return await _error(
        call,
        fallback,
        'read failed',
        budget: budget,
        gitLabRequests: completedRequests,
        countOutput: !reread,
      );
    } finally {
      if (reservedRequests > 0) {
        completedRequests = requestMeter?.count ?? 0;
        budget.settleRequests(
          reserved: reservedRequests,
          measured: completedRequests,
        );
      }
    }
  }

  Future<_RawToolResult> _dispatch(
    String name,
    Map<String, Object?> arguments,
  ) {
    if (!releasePolicy.allowsRead(name)) {
      throw const _ToolValidation('unknown tool');
    }
    if (_groupPort != null) {
      if (name != 'get_group_work_item') {
        throw const _ToolValidation('unknown tool');
      }
      return _groupWorkItem(arguments);
    }
    return switch (name) {
      'read_file' => _readFile(arguments),
      'list_directory' => _listDirectory(arguments),
      'get_issue' => _issue(arguments),
      'get_merge_request' => _mergeRequest(arguments),
      'get_release' => _release(arguments),
      'get_milestone' => _milestone(arguments),
      'get_snippet' => _snippet(arguments),
      'get_merge_request_diff' => _mergeRequestDiff(),
      'get_pipeline_jobs' => _pipelineJobs(),
      'get_job_log' => _jobLog(arguments),
      'get_commit' => _commit(arguments),
      'get_commit_diff' => _commitDiff(arguments),
      'search_project' => _search(arguments),
      _ => throw const _ToolValidation('unknown tool'),
    };
  }

  Future<_RawToolResult> _groupWorkItem(Map<String, Object?> args) async {
    _exactKeys(args, required: const {'groupId', 'iid'});
    final groupId = _positiveInt(args['groupId'], 'groupId');
    final iid = _positiveInt(args['iid'], 'iid');
    final groupScope = _groupScope!;
    if (groupId != groupScope.groupId || iid != groupScope.iid) {
      throw const _ToolValidation('work item outside scope');
    }
    final read = await _groupPort!.workItem(groupScope);
    return _RawToolResult.json(
      read.value.value,
      _live('group work item #$iid'),
      requestCount: read.requestCount,
      fetchedAt: read.fetchedAt,
      restorable: read.value.value['description_status'] == 'complete'
          ? _descriptionField(
              () => AiFieldProvenance.groupWorkItem(
                identity: read.value.identity,
                completeValue: true,
              ),
            )
          : null,
      deliveries: (path, owner) {
        if (path.length != 1) return null;
        final description = AiFieldProvenance.groupWorkItem(
          identity: read.value.identity,
          completeValue: true,
        );
        if (path.single == 'title') return _titleField(description);
        if (path.single == 'description' &&
            read.value.value['description_status'] == 'complete') {
          return description;
        }
        return null;
      },
    );
  }

  bool _expired(DateTime? fetchedAt) {
    if (fetchedAt == null) return false;
    final age = _now().difference(fetchedAt);
    return age.isNegative || age >= const Duration(seconds: 60);
  }

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
      readConfidential: read.value['confidential'] == true,
      readInternal: _readInternalNote(read.value),
      restorable: _discussionFields('issues', iid),
      deliveries: _discussionFields('issues', iid, includeTitle: true),
      fetchedAt: read.fetchedAt,
      freshnessRetried: read.freshnessRetried,
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
      readInternal: _readInternalNote(read.value),
      restorable: _discussionFields('merge_requests', iid),
      deliveries: _discussionFields('merge_requests', iid, includeTitle: true),
      fetchedAt: read.fetchedAt,
      freshnessRetried: read.freshnessRetried,
    );
  }

  AiGitLabFieldReadPort get _fieldPort {
    final Object candidate = port;
    if (candidate is AiGitLabFieldReadPort) return candidate;
    throw const _ToolValidation('fieldReadsUnavailable');
  }

  Future<_RawToolResult> _release(Map<String, Object?> args) async {
    _exactKeys(args, required: const {'tag_name'});
    final tagName = _resourceSegment(args['tag_name']);
    final read = await _fieldPort.release(tagName);
    return _RawToolResult.json(
      _pick(read.value, const [
        'tag_name',
        'name',
        'description',
        'created_at',
        'released_at',
        'upcoming_release',
      ]),
      _live('release $tagName'),
      requestCount: read.requestCount,
      restorable: _descriptionField(
        () => AiProjectFieldProvenance.releaseDescription(
          instance: placeholders!.instance,
          projectId: scope.projectId,
          projectPath: scope.projectPath,
          tagName: tagName,
        ),
      ),
    );
  }

  Future<_RawToolResult> _milestone(Map<String, Object?> args) async {
    _exactKeys(args, required: const {'milestone_id'});
    final id = _positiveInt(args['milestone_id'], 'milestone_id');
    final read = await _fieldPort.milestone(id);
    return _RawToolResult.json(
      _pick(read.value, const [
        'id',
        'iid',
        'project_id',
        'title',
        'description',
        'state',
        'created_at',
        'updated_at',
        'due_date',
        'start_date',
      ]),
      _live('milestone #$id'),
      requestCount: read.requestCount,
      restorable: _descriptionField(
        () => AiProjectFieldProvenance.milestoneDescription(
          instance: placeholders!.instance,
          projectId: scope.projectId,
          projectPath: scope.projectPath,
          milestoneId: id,
          milestoneIid: read.value['iid']! as int,
        ),
      ),
    );
  }

  Future<_RawToolResult> _snippet(Map<String, Object?> args) async {
    _exactKeys(
      args,
      required: const {'snippet_id'},
      optional: const {'file_path', 'ref'},
    );
    final id = _positiveInt(args['snippet_id'], 'snippet_id');
    final path = args.containsKey('file_path')
        ? _path(args['file_path'])
        : null;
    if (path == '') throw const _ToolValidation('invalidSnippetPath');
    final ref = args.containsKey('ref')
        ? _resourceSegment(args['ref'])
        : 'HEAD';
    final read = await _fieldPort.snippet(id, filePath: path, ref: ref);
    final file = read.value['file'];
    return _RawToolResult.json(
      {
        ..._pick(read.value, const [
          'id',
          'project_id',
          'title',
          'description',
          'visibility',
          'created_at',
          'updated_at',
          'file_name',
          'files',
          'content_unavailable',
        ]),
        if (file is AiJson)
          'file': _pick(file, const ['path', 'ref', 'content']),
      },
      _live('snippet #$id'),
      requestCount: read.requestCount,
      readConfidential:
          read.value['visibility'] != 'public' &&
          read.value['visibility'] != 'internal',
      readInternal: read.value['visibility'] == 'internal',
      readVisibility: read.value['visibility'] is String
          ? read.value['visibility'] as String
          : null,
      restorable: _descriptionField(
        () => AiProjectFieldProvenance.snippetDescription(
          instance: placeholders!.instance,
          projectId: scope.projectId,
          projectPath: scope.projectPath,
          snippetId: id,
        ),
      ),
      fetchedAt: read.fetchedAt,
      freshnessRetried: read.freshnessRetried,
    );
  }

  _RestorableFields _descriptionField(AiFieldProvenance Function() field) =>
      (path, owner) =>
          path.length == 1 && path.single == 'description' ? field() : null;

  /// The complete values in a `_projectDiscussion` projection that a write
  /// can put back whole: title, description and each note's body, keyed by
  /// the note's numeric ID. Title is tracked but is not restorable.
  _RestorableFields _discussionFields(
    String resource,
    int iid, {
    bool includeTitle = false,
  }) {
    AiFieldProvenance field({int? noteId}) => AiFieldProvenance.gitLab(
      instance: placeholders!.instance,
      projectId: scope.projectId,
      projectPath: scope.projectPath,
      resource: resource,
      iid: iid,
      noteId: noteId,
    );
    return (path, owner) {
      if (includeTitle && path.length == 1 && path.single == 'title') {
        return _titleField(field());
      }
      if (path.length == 1 && path.single == 'description') return field();
      if (path.length == 2 && path[0] == 'notes' && path[1] == 'body') {
        final id = owner['id'];
        if (id is int && id > 0) return field(noteId: id);
      }
      return null;
    };
  }

  AiFieldProvenance _titleField(AiFieldProvenance source) => AiFieldProvenance(
    resourceKey: source.resourceKey,
    fieldName: 'title',
    completeValue: source.completeValue,
    resourceWeb: source.resourceWeb,
    projectId: source.projectId,
    groupId: source.groupId,
    projectFullPath: source.projectFullPath,
    groupFullPath: source.groupFullPath,
    accountKey: source.accountKey,
  );

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
      fetchedAt: read.fetchedAt,
      freshnessRetried: read.freshnessRetried,
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
      fetchedAt: read.fetchedAt,
      freshnessRetried: read.freshnessRetried,
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
      readConfidential:
          searchScope == 'issues' &&
          read.value.any((row) => row['confidential'] == true),
      fragmentFields: searchScope == 'blobs' ? const {'data'} : const {},
      requestCount: read.requestCount,
    );
  }

  _RawToolResult _diffResult(
    List<AiJson> rows,
    AiToolProvenance provenance, {
    required int requestCount,
    required bool incomplete,
    DateTime? fetchedAt,
    bool freshnessRetried = false,
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
      fetchedAt: fetchedAt,
      freshnessRetried: freshnessRetried,
    );
  }

  Future<AiToolExecution> _error(
    AiToolCall call,
    AiToolProvenance provenance,
    String message, {
    required AiToolBudget budget,
    int gitLabRequests = 0,
    bool countOutput = true,
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
    final available = countOutput
        ? budget.availableOutput(completeContent.length)
        : min(completeContent.length, budget.maxSingleOutputChars);
    final clipped = data.clipped(available);
    final content = clipped.encode();
    if (countOutput) budget.recordOutput(content.length);
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

  ({AiAppText data, RedactionResult redaction, Object? value})
  _redactStructured(
    Object? value,
    Set<String> fragmentFields, {
    _RestorableFields? restorable,
  }) {
    var redactions = 0;
    var withheld = false;
    String count(RedactionResult result) {
      redactions += result.redactions;
      withheld |= result.withheldPrivateKeyContext;
      return result.text;
    }

    Object? visit(
      Object? current, {
      String? field,
      List<String> path = const [],
    }) => switch (current) {
      String text => count(
        fragmentFields.contains(field)
            ? redactor.redactFragment(text)
            : redactor.redactSource(text),
      ),
      List<Object?> values => [
        for (final item in values) visit(item, path: path),
      ],
      Map<String, Object?> values => () {
        final result = <String, Object?>{};
        for (final entry in values.entries) {
          final entryPath = [...path, entry.key];
          final provenance = restorable?.call(entryPath, values);
          final text = entry.value;
          if (provenance == null || text is! String) {
            result[entry.key] = visit(
              entry.value,
              field: entry.key,
              path: entryPath,
            );
            continue;
          }
          // The table neutralizes source-authored placeholders and numbers
          // this field's own upload links; the scan below keeps those ids.
          final table = placeholders!;
          final hits = table.limitHits;
          final outgoing = table.redactOutgoing(text, field: provenance);
          if (table.limitHits > hits) {
            result['${entry.key}_upload_links'] =
                AiTextBlockCode.tooManyUploadLinks;
          }
          result[entry.key] = count(
            redactor.redactSource(outgoing, keepAppPlaceholders: true),
          );
        }
        return result;
      }(),
      _ => current,
    };
    final projected = visit(value);
    final data = AiAppText.json(projected);
    return (
      data: data,
      redaction: RedactionResult(
        data.encode(),
        redactions,
        withheldPrivateKeyContext: withheld,
      ),
      value: projected,
    );
  }

  /// Tells the placeholder table which tracked fields of [complete] the
  /// provider gets whole in [clipped]. A clip keeps a prefix of the readable
  /// strings and may cut the last one, so a field is whole when its value
  /// survives at its own position unchanged. Plan §3.1: a field cut here
  /// offers no whole-field write.
  void _recordDeliveries(
    AiAppText complete,
    AiAppText clipped,
    Object? structured,
    _RestorableFields restorable, {
    bool allowWhole = true,
    bool allowTitleWhole = true,
  }) {
    final table = placeholders;
    if (table == null) return;
    final all = complete.plainStrings.toList();
    final kept = clipped.plainStrings.toList();
    final fields = _restorableValues(structured, restorable);
    final offset = all.length - fields.count;
    for (final entry in fields.values) {
      final index = offset + entry.index;
      final whole =
          index >= 0 &&
          index < all.length &&
          index < kept.length &&
          all[index] == entry.value &&
          kept[index] == entry.value;
      // Preparation can be rolled back after a failed provider send. It may
      // conservatively mark a cut, but cannot upgrade an earlier cut to whole.
      // A read can be followed by a write in the same tool batch, before the
      // provider receives its result. Only accepted delivery upgrades a title.
      if (!whole ||
          (allowWhole && (allowTitleWhole || entry.field.fieldName != 'title'))) {
        table.recordFieldDelivery(entry.field, whole: whole);
      }
    }
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
    this.fetchedAt,
    this.freshnessRetried = false,
  }) : json = false,
       readConfidential = false,
       readInternal = false,
       readVisibility = null,
       fragmentFields = const {},
       restorable = null,
       deliveries = null;

  const _RawToolResult.json(
    this.value,
    this.provenance, {
    this.blocked = false,
    this.readConfidential = false,
    this.readInternal = false,
    this.readVisibility,
    this.requestCount = 0,
    this.fragmentFields = const {},
    this.restorable,
    this.deliveries,
    this.fetchedAt,
    this.freshnessRetried = false,
  }) : json = true,
       tailLines = null;

  final Object? value;
  final AiToolProvenance provenance;
  final bool blocked;
  final bool readConfidential;
  final bool readInternal;
  final String? readVisibility;
  final bool json;
  final Set<String> fragmentFields;
  final int requestCount;
  final int? tailLines;
  final DateTime? fetchedAt;
  final bool freshnessRetried;

  /// Which string values, by their path of map keys, are a complete
  /// restorable field. Null for every other tool.
  final _RestorableFields? restorable;

  /// Fields whose complete or clipped model delivery must be tracked,
  /// including non-restorable titles.
  final _RestorableFields? deliveries;
}

typedef _RestorableFields =
    AiFieldProvenance? Function(List<String> path, Map<String, Object?> owner);

/// The tracked string values of a projected JSON value with their index
/// among its readable strings (each map key, then its value; list items in
/// order), and how many readable strings it has in all.
({List<({int index, AiFieldProvenance field, String value})> values, int count})
_restorableValues(Object? value, _RestorableFields restorable) {
  final values = <({int index, AiFieldProvenance field, String value})>[];
  var count = 0;
  void walk(Object? current, List<String> path) {
    switch (current) {
      case String _:
        count++;
      case List<Object?> items:
        for (final item in items) {
          walk(item, path);
        }
      case Map<String, Object?> entries:
        for (final entry in entries.entries) {
          count++;
          final entryPath = [...path, entry.key];
          final text = entry.value;
          if (text is String) {
            final field = restorable(entryPath, entries);
            if (field != null) {
              values.add((index: count, field: field, value: text));
            }
          }
          walk(text, entryPath);
        }
    }
  }

  walk(value, const []);
  return (values: values, count: count);
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

String _resourceSegment(Object? value) {
  final segment = _nonEmptyString(value, 'resource', max: 1024);
  if (segment == '.' ||
      segment == '..' ||
      _controlCharacters.hasMatch(segment) ||
      segment.contains('\\')) {
    throw const _ToolValidation('invalidResourceSegment');
  }
  return segment;
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
  'get_snippet' => 2,
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

bool _readInternalNote(AiJson source) {
  final notes = source['notes'];
  if (notes is! List<Object?>) return false;
  return notes.any(
    (value) =>
        value is Map<String, Object?> &&
        value['system'] != true &&
        (value['internal'] == true || value['confidential'] == true),
  );
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
