part of 'gitlab_write_port.dart';

extension _CiPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareCi(AiWriteRequest request) async {
    final op = request.operationId;
    if (!const {
      'createPipeline', 'pipelineAction', 'jobAction',
      'playPipelineSchedule', 'deletePipeline',
    }.contains(op)) {
      return null;
    }
    final a = request.arguments;
    final project = _positive(a, 'projectId');
    if (!_granted(request.scope, project, null, null, projectOnly: true)) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final action = op == 'pipelineAction' || op == 'jobAction'
        ? _text(a, 'action') : null;
    if (action != null &&
        !(op == 'jobAction' ? const {'cancel', 'retry', 'play'}
            : const {'cancel', 'retry'}).contains(action)) {
      throw const ApiFailure(FailureKind.validation);
    }
    final user = await _api.currentUser();
    if ('${_api.instance.key}#${user.id}' != accountKey) {
      throw const ApiFailure(FailureKind.unauthenticated);
    }
    final p = await _api.record(['projects', '$project']);
    if (p['id'] != project) throw const ApiFailure(FailureKind.forbidden);
    final projectPath = _responseText(p, 'path_with_namespace');
    final root = [accountKey, 'project:$project', 'pipeline'];
    final apiRoot = ['projects', '$project'];
    var keys = {_key(root)};
    var releaseName = projectPath;
    String? confirmName;
    late String ref;
    late AiTargetRef target;
    late AiPipelinePreview preview;
    var facts = const AiTierFacts();
    late String bindingDigest;
    late Future<Object?> Function() mutation;
    Future<Object?> Function(Object?)? readback;
    AiCreatedRef? created;

    if (op == 'createPipeline') {
      final requestedRef = _text(a, 'ref');
      final validated = validatePipelineVariables(a['variables'],
          knownSecrets: const <String>{});
      if (validated is AiPipelineVariablesRejected) {
        throw AiJournalException(switch (validated.reasonCode) {
          'secret' => 'pipelineVariableSecret',
          _ => 'pipelineVariableForbidden',
        });
      }
      final variables = (validated as AiPipelineVariablesAccepted).variables;
      ref = await _ciExistingRef(project, requestedRef);
      confirmName = ref;
      facts = AiTierFacts(pipelineVariables: variables.isNotEmpty);
      target = AiTargetRef(kind: AiTargetKind.ref, projectId: project,
          projectPath: projectPath, refName: ref);
      preview = AiPipelinePreview(ref: ref,
          newVariableNames: variables.map((v) => v['key']!).toList());
      bindingDigest = _ciDigest([project, ref]);
      mutation = () async {
        final result = await _api.createPipeline(project, ref,
            variables: variables.isEmpty ? null : variables);
        _resultInt(result, 'id');
        return result;
      };
      readback = (result) async {
        final id = _resultInt(result, 'id');
        final value = await _api.record([...apiRoot, 'pipelines', '$id']);
        _ciPipelineIdentity(value, project, id);
        created = AiCreatedRef(accountKey: accountKey,
            kind: AiTargetKind.pipeline, projectId: project, id: id);
        return value;
      };
    } else if (op == 'jobAction') {
      final jobId = _positive(a, 'jobId');
      final job = await _api.record([...apiRoot, 'jobs', '$jobId']);
      final parent = job['pipeline'];
      if (job['id'] != jobId || parent is! Map ||
          parent['id'] is! int || (parent['id']! as int) <= 0 ||
          (job.containsKey('project_id') && job['project_id'] != project) ||
          (parent.containsKey('project_id') && parent['project_id'] != project)) {
        throw const AiJournalException('jobNotInPipeline');
      }
      final pipelineId = parent['id']! as int;
      ref = _ciRef(job);
      final name = _responseText(job, 'name');
      final stage = _responseText(job, 'stage');
      releaseName = '${job['id']}';
      keys = {_key([...root, '$pipelineId', 'job', '$jobId'])};
      target = AiTargetRef(kind: AiTargetKind.job, projectId: project,
          projectPath: projectPath, pipelineId: pipelineId, jobId: jobId,
          jobBelongsToBoundPipeline: true);
      preview = AiPipelinePreview(ref: ref, pipelineId: pipelineId,
          jobId: jobId, jobName: name, stage: stage,
          environment: _ciEnvironment(job));
      bindingDigest = _ciDigest([project, pipelineId, jobId, ref, name, stage]);
      mutation = () => _api.jobAction(project, jobId, action!);
      readback = (result) async {
        final id = _resultInt(result, 'id');
        // Retry may return a new job ID. Its parent, ref, name and stage must
        // still identify the pre-read job; cancel/play retain the original ID.
        if (action != 'retry' && id != jobId) {
          throw const AiJournalException('jobNotInPipeline');
        }
        final value = await _api.record([...apiRoot, 'jobs', '$id']);
        final parent = value['pipeline'];
        if (value['id'] != id || parent is! Map ||
            parent['id'] != pipelineId ||
            _ciRef(value) != ref || _responseText(value, 'name') != name ||
            _responseText(value, 'stage') != stage ||
            (value.containsKey('project_id') && value['project_id'] != project) ||
            (parent.containsKey('project_id') && parent['project_id'] != project)) {
          throw const AiJournalException('jobNotInPipeline');
        }
        return value;
      };
    } else if (op == 'playPipelineSchedule') {
      final scheduleId = _positive(a, 'scheduleId');
      final key = request.scheduleHmacKey;
      if (key == null || key.length != 32 ||
          key.any((byte) => byte < 0 || byte > 255)) {
        throw const AiJournalException('scheduleParamsUnreadable');
      }
      Map<String, dynamic> schedule;
      try {
        schedule = await _api.record([
          ...apiRoot, 'pipeline_schedules', '$scheduleId',
        ]);
      } on ApiFailure catch (error) {
        if (error.kind == FailureKind.invisible) {
          throw const AiJournalException('scheduleMissing');
        }
        if (!const {FailureKind.forbidden, FailureKind.unsupported,
            FailureKind.invalidResponse, FailureKind.tooLarge}.contains(error.kind)) {
          rethrow;
        }
        // A list may still provide the independently verified confirmation ref
        // when detail parameters are unavailable. Never use a partial list.
        schedule = await _ciScheduleRef(project, scheduleId);
      }
      if (schedule['id'] != scheduleId) {
        throw const AiJournalException('scheduleMissing');
      }
      ref = _ciRef(schedule);
      final params = evaluateScheduleParams(schedule, key: key);
      confirmName = ref;
      facts = AiTierFacts(
          scheduleParamsUnsafe: params.state != AiScheduleParamsState.explicitEmpty);
      target = AiTargetRef(kind: AiTargetKind.ref, projectId: project,
          projectPath: projectPath, refName: ref);
      preview = AiPipelinePreview(ref: ref,
          scheduleVariableNames: [...params.variableNames, ...params.inputNames],
          scheduleParamsUnreadable: params.state == AiScheduleParamsState.unreadable);
      // Bind readability and the process key even when parameter values cannot
      // be read. This digest has no slot in journal metadata or projections.
      bindingDigest = Hmac(sha256, key).convert(utf8.encode(jsonEncode([
        project, scheduleId, ref, params.state.name, params.hmac,
      ]))).toString();
      mutation = () => _api.playPipelineSchedule(project, scheduleId);
      readback = (_) async {
        final value = await _api.record([
          ...apiRoot, 'pipeline_schedules', '$scheduleId',
        ]);
        if (value['id'] != scheduleId) {
          throw const AiJournalException('scheduleMissing');
        }
        return value;
      };
    } else {
      final pipelineId = _positive(a, 'pipelineId');
      final path = [...apiRoot, 'pipelines', '$pipelineId'];
      final pipeline = await _api.record(path);
      _ciPipelineIdentity(pipeline, project, pipelineId);
      ref = _ciRef(pipeline);
      final status = _responseText(pipeline, 'status');
      releaseName = '${pipeline['id']}';
      keys = {_key([...root, '$pipelineId'])};
      target = AiTargetRef(kind: AiTargetKind.pipeline, projectId: project,
          projectPath: projectPath, pipelineId: pipelineId);
      preview = AiPipelinePreview(ref: ref, pipelineId: pipelineId,
          environment: _ciEnvironment(pipeline));
      bindingDigest = _ciDigest([project, pipelineId, ref, status]);
      if (op == 'deletePipeline') {
        confirmName = releaseName;
        mutation = () => _api.deletePipeline(project, pipelineId);
        readback = (_) async {
          try {
            await _api.record(path);
          } on ApiFailure catch (error) {
            if (error.kind == FailureKind.invisible) return null;
            rethrow;
          }
          throw const ApiFailure(FailureKind.conflict);
        };
      } else {
        mutation = () => _api.pipelineAction(project, pipelineId, action!);
        readback = (_) async {
          final value = await _api.record(path);
          _ciPipelineIdentity(value, project, pipelineId);
          return value;
        };
      }
    }
    final visibility = p['visibility'];
    return AiWritePrepared._(
      request: request, owner: _owner, classify: _resultClassifier,
      releaseName: releaseName, confirmName: confirmName,
      writeKeys: keys, dependencyKeys: const {}, mutation: mutation,
      readback: readback, projectPath: projectPath,
      projectVisibility: visibility is String ? visibility : null,
      facts: facts, bindingTargets: [target], bindingDigest: bindingDigest,
      preview: preview, resolveCreatedOnSuccess: () => created,
    );
  }

  Future<String> _ciExistingRef(int project, String ref) async {
    for (final kind in ['branches', 'tags']) {
      try {
        final value = await _api.record([
          'projects', '$project', 'repository', kind, ref,
        ]);
        if (value['name'] != ref) throw const AiJournalException('refMissing');
        return _responseText(value, 'name');
      } on ApiFailure catch (error) {
        if (error.kind != FailureKind.invisible) rethrow;
      }
    }
    throw const AiJournalException('refMissing');
  }

  Future<Map<String, dynamic>> _ciScheduleRef(int project, int id) async {
    Map<String, dynamic>? found;
    Uri? next;
    for (var page = 0; page < 2; page++) {
      final values = await _api.records(
        ['projects', '$project', 'pipeline_schedules'],
        query: const {'per_page': '100'}, next: next,
      );
      for (final value in values.items) {
        if (value['id'] == id) {
          if (found != null) throw const AiJournalException('scheduleParamsUnreadable');
          // A list verifies only identity/ref; it is not a parameter snapshot.
          found = {'id': id, 'ref': value['ref']};
        }
      }
      if (values.next == null) {
        if (found == null) throw const AiJournalException('scheduleMissing');
        return found;
      }
      next = values.next;
    }
    throw const AiJournalException('scheduleParamsUnreadable');
  }
}

String _ciRef(Map<String, dynamic> value) {
  final ref = value['ref'];
  if (ref is! String || ref.trim().isEmpty) {
    throw const AiJournalException('refMissing');
  }
  return ref;
}

String? _ciEnvironment(Map<String, dynamic> value) {
  final environment = value['environment'];
  return environment is Map && environment['name'] is String
      ? environment['name']! as String : null;
}

String _ciDigest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

void _ciPipelineIdentity(Map<String, dynamic> value, int project, int id) {
  if (value['id'] != id ||
      (value.containsKey('project_id') && value['project_id'] != project)) {
    throw const ApiFailure(FailureKind.forbidden);
  }
}
