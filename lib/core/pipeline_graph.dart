typedef PipelineGraphJson = Map<String, dynamic>;

enum PipelineGraphNeedState { resolved, unloaded, ambiguous }

final class PipelineGraphNeed {
  const PipelineGraphNeed({
    required this.name,
    required this.state,
    this.target,
  });

  final String name;
  final PipelineGraphNeedState state;
  final PipelineGraphJob? target;
}

final class PipelineGraphJob {
  const PipelineGraphJob({
    required this.id,
    required this.numericId,
    required this.name,
    required this.status,
    required this.kind,
    required this.retried,
    required this.schedulingType,
    required this.stageName,
    required this.needs,
    required this.needsTruncated,
  });

  factory PipelineGraphJob.fromJson(PipelineGraphJson json) {
    final id = _requiredString(json, 'id');
    final name = _requiredString(json, 'name');
    final status = _requiredString(json, 'status');
    if (status != status.toUpperCase()) {
      throw const FormatException('Invalid pipeline job status');
    }
    final kind = _requiredString(json, 'kind');
    final parsedId = switch (kind) {
      'BUILD' => _globalId(id, 'Ci::Build'),
      'BRIDGE' => _globalId(id, 'Ci::Bridge'),
      _ => throw const FormatException('Invalid pipeline job kind'),
    };
    final retried = json['retried'];
    if (retried is! bool) throw const FormatException('Invalid retried flag');
    final schedulingType = _requiredString(
      json,
      'schedulingType',
    ).toUpperCase();
    if (schedulingType != 'DAG' && schedulingType != 'STAGE') {
      throw const FormatException('Invalid scheduling type');
    }
    final stage = _object(json['stage'], nullable: true);
    final needs = _object(json['needs']);
    final nodes = _list(needs?['nodes']);
    if (nodes.length > 100) throw const FormatException('Too many needs');
    final names = <String>[];
    for (final value in nodes) {
      names.add(_requiredString(_object(value)!, 'name'));
    }
    final needPageInfo = _object(needs?['pageInfo']);
    final needsTruncated = _requiredBool(needPageInfo!, 'hasNextPage');
    return PipelineGraphJob(
      id: id,
      numericId: kind == 'BUILD' ? parsedId : null,
      name: name,
      status: status,
      kind: kind,
      retried: retried,
      schedulingType: schedulingType,
      stageName: stage == null ? null : _requiredString(stage, 'name'),
      needs: List.unmodifiable(names),
      needsTruncated: needsTruncated,
    );
  }

  final String id;
  final int? numericId;
  final String name;
  final String status;
  final String kind;
  final bool retried;
  final String schedulingType;
  final String? stageName;
  final List<String> needs;
  final bool needsTruncated;

  bool get waitsForStage => schedulingType == 'STAGE';
  bool get canRunImmediately =>
      schedulingType == 'DAG' && needs.isEmpty && !needsTruncated;
  bool get canOpen => kind == 'BUILD' && numericId != null;
}

final class PipelineGraphPageData {
  const PipelineGraphPageData({
    required this.pipelineId,
    required this.iid,
    required this.stageNames,
    required this.stagesTruncated,
    required this.jobs,
    required this.hasNextPage,
    required this.endCursor,
  });

  factory PipelineGraphPageData.fromJson(PipelineGraphJson json) {
    final pipelineId = _globalId(_requiredString(json, 'id'), 'Ci::Pipeline');
    final iidValue = json['iid'];
    final iid = switch (iidValue) {
      int value when value > 0 => value,
      String value => int.tryParse(value),
      _ => null,
    };
    if (iid == null || iid <= 0) {
      throw const FormatException('Invalid pipeline iid');
    }
    final stages = _object(json['stages'])!;
    final stageNodes = _list(stages['nodes']);
    if (stageNodes.length > 100) throw const FormatException('Too many stages');
    final stageNames = <String>[];
    for (final value in stageNodes) {
      stageNames.add(_requiredString(_object(value)!, 'name'));
    }
    final stagePageInfo = _object(stages['pageInfo'])!;
    final jobsConnection = _object(json['jobs'])!;
    final jobNodes = _list(jobsConnection['nodes']);
    if (jobNodes.length > 20) {
      throw const FormatException('Too many jobs in page');
    }
    final jobs = jobNodes
        .map((value) => PipelineGraphJob.fromJson(_object(value)!))
        .toList(growable: false);
    final pageInfo = _object(jobsConnection['pageInfo'])!;
    final hasNextPage = _requiredBool(pageInfo, 'hasNextPage');
    final endCursor = pageInfo['endCursor'];
    if (endCursor != null && (endCursor is! String || endCursor.isEmpty)) {
      throw const FormatException('Invalid jobs cursor');
    }
    if (hasNextPage && endCursor == null) {
      throw const FormatException('Missing jobs cursor');
    }
    return PipelineGraphPageData(
      pipelineId: pipelineId,
      iid: iid,
      stageNames: List.unmodifiable(stageNames),
      stagesTruncated: _requiredBool(stagePageInfo, 'hasNextPage'),
      jobs: List.unmodifiable(jobs),
      hasNextPage: hasNextPage,
      endCursor: endCursor as String?,
    );
  }

  final int pipelineId;
  final int iid;
  final List<String> stageNames;
  final bool stagesTruncated;
  final List<PipelineGraphJob> jobs;
  final bool hasNextPage;
  final String? endCursor;
}

Map<String, List<PipelineGraphNeed>> resolvePipelineGraphNeeds(
  List<PipelineGraphJob> jobs,
) {
  final byName = <String, List<PipelineGraphJob>>{};
  for (final job in jobs) {
    byName.putIfAbsent(job.name, () => <PipelineGraphJob>[]).add(job);
  }
  final result = <String, List<PipelineGraphNeed>>{};
  for (final job in jobs) {
    result[job.id] = List<PipelineGraphNeed>.unmodifiable(
      job.needs.map(
        (name) =>
            _resolveNeed(name, byName[name] ?? const <PipelineGraphJob>[]),
      ),
    );
  }
  return Map.unmodifiable(result);
}

PipelineGraphNeed _resolveNeed(String name, List<PipelineGraphJob> matches) {
  if (matches.isEmpty) {
    return PipelineGraphNeed(
      name: name,
      state: PipelineGraphNeedState.unloaded,
    );
  }
  final normal = matches
      .where((value) => !value.retried)
      .toList(growable: false);
  final candidates = normal.isEmpty ? matches : normal;
  if (candidates.length != 1) {
    return PipelineGraphNeed(
      name: name,
      state: PipelineGraphNeedState.ambiguous,
    );
  }
  return PipelineGraphNeed(
    name: name,
    state: PipelineGraphNeedState.resolved,
    target: candidates.single,
  );
}

Map<String, dynamic>? _object(Object? value, {bool nullable = false}) {
  if (value == null && nullable) return null;
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected object');
  }
  return value;
}

List<dynamic> _list(Object? value) {
  if (value is! List<dynamic>) throw const FormatException('Expected list');
  return value;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) throw FormatException('Missing $key');
  return value;
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('Missing $key');
  return value;
}

int _globalId(String value, String type) {
  final match = RegExp(
    '^gid://gitlab/${RegExp.escape(type)}/([1-9][0-9]*)\$',
  ).firstMatch(value);
  final id = int.tryParse(match?.group(1) ?? '');
  if (id == null) throw FormatException('Invalid $type global id');
  return id;
}
