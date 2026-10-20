part of 'gitlab_api.dart';

const _pipelineAnalyticsQuery = r'''
query MobilePipelineAnalytics($path: ID!, $ref: String!, $fromTime: Time!, $toTime: Time!, $period: AnalyticsAggregationPeriod!, $source: CiPipelineSources) {
  project(fullPath: $path) {
    id
    pipelineAnalytics(ref: $ref, fromTime: $fromTime, toTime: $toTime, source: $source) {
      aggregate {
        label
        all: count
        success: count(status: SUCCESS)
        failed: count(status: FAILED)
        other: count(status: OTHER)
        durationStatistics { p50 p95 }
      }
      timeSeries(period: $period) {
        label
        all: count
        success: count(status: SUCCESS)
        failed: count(status: FAILED)
        other: count(status: OTHER)
        durationStatistics { p50 p95 }
      }
    }
  }
}
''';

const _codeCoverageSummaryQuery = r'''
query MobileCodeCoverageSummary($path: ID!) {
  project(fullPath: $path) {
    id
    codeCoverageSummary { averageCoverage coverageCount lastUpdatedOn }
  }
}
''';

const _analyticsSchemaErrors = {
  'undefinedField',
  'undefinedArgument',
  'variableRequiresValidType',
  'argumentLiteralsIncompatible',
  'missingRequiredArguments',
};
const _maximumAnalyticsRows = 400;
const _maximumAnalyticsWindow = Duration(days: 366);
final _signed64Maximum = BigInt.parse('9223372036854775807');

void _validateAnalyticsProject(Project project) {
  if (project.id <= 0 || project.path.trim().isEmpty) {
    throw const ApiFailure(FailureKind.validation);
  }
}

String _validatedAnalyticsRef(String ref) {
  if (ref.isEmpty ||
      ref.trim() != ref ||
      ref.length > 1024 ||
      ref.runes.any((value) => value < 0x20 || value == 0x7f)) {
    throw const ApiFailure(FailureKind.validation);
  }
  return ref;
}

void _validateAnalyticsWindow(
  DateTime from,
  DateTime to, {
  bool bounded = false,
}) {
  final duration = to.toUtc().difference(from.toUtc());
  if (duration <= Duration.zero ||
      (bounded && duration > _maximumAnalyticsWindow)) {
    throw const ApiFailure(FailureKind.validation);
  }
}

int _nonNegativeInt(Json json, String key) {
  final value = json[key];
  if (value is! int || value < 0) {
    throw const FormatException('Expected non-negative integer');
  }
  return value;
}

DateTime _parseZonedAnalyticsDate(String raw) {
  final parts = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(raw);
  if (parts == null) throw const FormatException('Expected zoned date');
  final localFields = DateTime.utc(
    int.parse(parts.group(1)!),
    int.parse(parts.group(2)!),
    int.parse(parts.group(3)!),
    int.parse(parts.group(4)!),
    int.parse(parts.group(5)!),
    int.parse(parts.group(6)!),
  );
  if (localFields.year != int.parse(parts.group(1)!) ||
      localFields.month != int.parse(parts.group(2)!) ||
      localFields.day != int.parse(parts.group(3)!) ||
      localFields.hour != int.parse(parts.group(4)!) ||
      localFields.minute != int.parse(parts.group(5)!) ||
      localFields.second != int.parse(parts.group(6)!)) {
    throw const FormatException('Expected real date');
  }
  final value = DateTime.tryParse(raw);
  if (value == null) throw const FormatException('Expected date');
  return value.toUtc();
}

DateTime _requiredAnalyticsDate(Json json, String key) {
  final raw = json[key];
  if (raw is! String) throw const FormatException('Expected date');
  return _parseZonedAnalyticsDate(raw);
}

DateTime? _optionalAnalyticsDate(Object? raw) {
  if (raw == null) return null;
  if (raw is! String) throw const FormatException('Expected date');
  final dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
  if (dateOnly != null) {
    final value = DateTime.utc(
      int.parse(dateOnly.group(1)!),
      int.parse(dateOnly.group(2)!),
      int.parse(dateOnly.group(3)!),
    );
    if ('${value.year.toString().padLeft(4, '0')}-'
            '${value.month.toString().padLeft(2, '0')}-'
            '${value.day.toString().padLeft(2, '0')}' !=
        raw) {
      throw const FormatException('Expected date');
    }
    return value;
  }
  throw const FormatException('Expected date');
}

BigInt? _optionalAnalyticsCount(Object? raw) {
  if (raw == null) return null;
  final BigInt value;
  if (raw is int) {
    value = BigInt.from(raw);
  } else if (raw is String &&
      raw.length <= 19 &&
      RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(raw)) {
    value = BigInt.parse(raw);
  } else {
    throw const FormatException('Expected non-negative integer');
  }
  if (value < BigInt.zero || value > _signed64Maximum) {
    throw const FormatException('Integer outside signed 64-bit range');
  }
  return value;
}

double? _optionalAnalyticsDuration(Object? raw) {
  if (raw == null) return null;
  if (raw is! num) throw const FormatException('Expected duration');
  final value = raw.toDouble();
  if (!value.isFinite || value < 0) {
    throw const FormatException('Expected finite non-negative duration');
  }
  return value;
}

PipelineAnalyticsBucket _pipelineAnalyticsBucket(Object? raw) {
  final bucket = objectJson(raw);
  final durations = bucket['durationStatistics'] == null
      ? null
      : objectJson(bucket['durationStatistics']);
  return PipelineAnalyticsBucket(
    label: _optionalAnalyticsDate(bucket['label']),
    total: _optionalAnalyticsCount(bucket['all']),
    successful: _optionalAnalyticsCount(bucket['success']),
    failed: _optionalAnalyticsCount(bucket['failed']),
    other: _optionalAnalyticsCount(bucket['other']),
    p50Seconds: _optionalAnalyticsDuration(durations?['p50']),
    p95Seconds: _optionalAnalyticsDuration(durations?['p95']),
  );
}

DateTime _analyticsPeriodStart(DateTime value, AnalyticsPeriod period) {
  final utc = value.toUtc();
  final day = DateTime.utc(utc.year, utc.month, utc.day);
  return switch (period) {
    AnalyticsPeriod.day => day,
    AnalyticsPeriod.week => day.subtract(Duration(days: day.weekday - 1)),
    AnalyticsPeriod.month => DateTime.utc(utc.year, utc.month),
  };
}

Json _analyticsGraphData(Uint8List bytes, {required String feature}) {
  try {
    final envelope = objectJson(jsonDecode(utf8.decode(bytes)));
    final errors = envelope['errors'];
    if (errors != null) {
      if (errors is! List) throw const ApiFailure(FailureKind.invalidResponse);
      if (errors.isNotEmpty) {
        final unsupported = errors.every(
          (error) =>
              error is Map &&
              error['extensions'] is Map &&
              _analyticsSchemaErrors.contains(
                (error['extensions'] as Map)['code'],
              ),
        );
        throw ApiFailure(
          unsupported ? FailureKind.unsupported : FailureKind.invalidResponse,
          title: unsupported ? l10n.instanceFeatureUnavailable(feature) : null,
          detail: unsupported ? l10n.useExistingListsAndSummaries : null,
        );
      }
    }
    return objectJson(envelope['data']);
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

Json _analyticsProject(Json data, Project project) {
  if (data['project'] == null) {
    throw const ApiFailure(FailureKind.invisible);
  }
  try {
    final remote = objectJson(data['project']);
    if (remote['id'] != 'gid://gitlab/Project/${project.id}') {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    return remote;
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

Uri? _analyticsNextPage(GitLabInstance instance, Uri current, Headers headers) {
  final explicit = headers.value('x-next-page');
  if (explicit != null) {
    if (explicit.isEmpty) return null;
    final page = int.tryParse(explicit);
    if (page == null || page <= 0) {
      throw const FormatException('Invalid next page');
    }
    return checkedPageUri(
      instance,
      current,
      current.replace(
        queryParameters: {...current.queryParameters, 'page': '$page'},
      ),
    );
  }

  final link = headers.value('link');
  if (link == null) return null;
  for (final match in RegExp(
    r'<([^>]+)>\s*;\s*rel="?([^";,]+)"?',
  ).allMatches(link)) {
    if (!(match.group(2)?.trim().split(' ').contains('next') ?? false)) {
      continue;
    }
    final raw = Uri.parse(match.group(1)!);
    final candidate = raw.hasScheme ? raw : current.resolveUri(raw);
    if (!instance.allowsApi(candidate) ||
        candidate.path != current.path ||
        candidate.userInfo.isNotEmpty ||
        candidate.hasFragment ||
        candidate.queryParametersAll.values.any(
          (values) => values.length != 1,
        )) {
      throw const FormatException('Unsafe analytics pagination target');
    }
    final normalized = Map<String, String>.from(candidate.queryParameters);
    for (final key in const ['since', 'until']) {
      final original = current.queryParameters[key];
      final supplied = normalized[key];
      if (original != null &&
          supplied != null &&
          supplied != original &&
          _parseZonedAnalyticsDate(supplied) ==
              _parseZonedAnalyticsDate(original)) {
        normalized[key] = original;
      }
    }
    final segments = current.pathSegments;
    final projects = segments.lastIndexOf('projects');
    final projectId = projects >= 0 && projects + 1 < segments.length
        ? segments[projects + 1]
        : null;
    for (final entry in const {
      'order': 'default',
      'trailers': 'false',
    }.entries) {
      if (normalized[entry.key] == entry.value) normalized.remove(entry.key);
    }
    if (projectId != null && normalized['id'] == projectId) {
      normalized.remove('id');
    }
    final cursor = <String, String>{
      for (final entry in normalized.entries)
        if (paginationKeys.contains(entry.key)) entry.key: entry.value,
    };
    if (!const [
      'page',
      'id_after',
      'page_token',
      'cursor',
    ].any(cursor.containsKey)) {
      throw const FormatException('Analytics pagination cursor missing');
    }
    // Validate the complete normalized candidate. checkedPageUri then retains
    // only the validated cursor and the caller's original scope literals.
    return checkedPageUri(
      instance,
      current,
      candidate.replace(queryParameters: normalized),
    );
  }
  return null;
}

Future<ApiPage<T>> _analyticsPage<T>(
  GitLabApi api,
  Uri uri,
  T Function(Json) parse,
) async {
  try {
    final result = await api._read(uri);
    final data = jsonDecode(utf8.decode(result.bytes));
    if (data is! List<dynamic>) throw const FormatException('Expected array');
    return ApiPage(
      List.unmodifiable(data.map((value) => parse(objectJson(value)))),
      next: _analyticsNextPage(api.instance, uri, result.headers),
    );
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

extension AnalyticsApi on GitLabApi {
  Future<ApiPage<ContributorSummary>> repositoryContributors(
    Project project, {
    String? ref,
    Uri? next,
  }) {
    _validateAnalyticsProject(project);
    final selectedRef = ref == null ? null : _validatedAnalyticsRef(ref);
    final query = <String, String>{
      'ref': ?selectedRef,
      'order_by': 'commits',
      'sort': 'desc',
      'per_page': '100',
    };
    final first = instance.api([
      'projects',
      '${project.id}',
      'repository',
      'contributors',
    ], query);
    _validateContinuation(first, next);
    return _analyticsPage(this, next ?? first, (json) {
      final displayName = requiredString(json, 'name').trim();
      if (displayName.isEmpty || displayName.length > 4096) {
        throw const FormatException('Invalid contributor name');
      }
      return ContributorSummary(
        displayName: displayName,
        commits: _nonNegativeInt(json, 'commits'),
        additions: _nonNegativeInt(json, 'additions'),
        deletions: _nonNegativeInt(json, 'deletions'),
      );
    });
  }

  Future<ApiPage<RepositoryActivityCommit>> repositoryActivity(
    Project project, {
    required String ref,
    required DateTime from,
    required DateTime to,
    Uri? next,
  }) {
    _validateAnalyticsProject(project);
    final selectedRef = _validatedAnalyticsRef(ref);
    _validateAnalyticsWindow(from, to);
    final fromUtc = from.toUtc();
    final toUtc = to.toUtc();
    final inclusiveUntil = toUtc.subtract(const Duration(microseconds: 1));
    final first = instance.api(
      ['projects', '${project.id}', 'repository', 'commits'],
      {
        'ref_name': selectedRef,
        'since': fromUtc.toIso8601String(),
        'until': inclusiveUntil.toIso8601String(),
        'with_stats': 'true',
        'per_page': '100',
      },
    );
    _validateContinuation(first, next);
    return _analyticsPage(this, next ?? first, (json) {
      final id = requiredString(json, 'id');
      if (!RegExp(r'^[0-9a-fA-F]{7,64}$').hasMatch(id)) {
        throw const FormatException('Invalid commit id');
      }
      final parents = json['parent_ids'];
      if (parents is! List ||
          parents.length > 1024 ||
          parents.any(
            (parent) =>
                parent is! String ||
                !RegExp(r'^[0-9a-fA-F]{7,64}$').hasMatch(parent),
          )) {
        throw const FormatException('Invalid parent ids');
      }
      int? additions;
      int? deletions;
      final stats = json['stats'];
      if (stats != null) {
        final values = objectJson(stats);
        additions = _nonNegativeInt(values, 'additions');
        deletions = _nonNegativeInt(values, 'deletions');
      }
      final committedAt = _requiredAnalyticsDate(json, 'committed_date');
      if (committedAt.isBefore(fromUtc) || !committedAt.isBefore(toUtc)) {
        throw const FormatException('Commit outside requested window');
      }
      return RepositoryActivityCommit(
        id: id,
        committedAt: committedAt,
        parentCount: parents.length,
        additions: additions,
        deletions: deletions,
      );
    });
  }

  Future<PipelineAnalyticsSnapshot> pipelineAnalytics(
    Project project, {
    required String ref,
    required DateTime from,
    required DateTime to,
    AnalyticsPeriod period = AnalyticsPeriod.day,
    AnalyticsPipelineSource source = AnalyticsPipelineSource.any,
  }) async {
    _validateAnalyticsProject(project);
    final selectedRef = _validatedAnalyticsRef(ref);
    _validateAnalyticsWindow(from, to, bounded: true);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _pipelineAnalyticsQuery,
        'variables': {
          'path': project.path,
          'ref': selectedRef,
          'fromTime': from.toUtc().toIso8601String(),
          'toTime': to.toUtc().toIso8601String(),
          'period': period.graphQLValue,
          'source': ?source.graphQLValue,
        },
      },
    );
    try {
      final remote = _analyticsProject(
        _analyticsGraphData(response.bytes, feature: l10n.cicdAnalytics),
        project,
      );
      if (remote['pipelineAnalytics'] == null) {
        throw ApiFailure(
          FailureKind.unsupported,
          title: l10n.instanceNoCicdAnalytics,
          detail: l10n.stillViewPipelinesAndJobs,
        );
      }
      final analytics = objectJson(remote['pipelineAnalytics']);
      final series = analytics['timeSeries'];
      if (series is! List || series.length > _maximumAnalyticsRows) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      final firstBucket = _analyticsPeriodStart(from, period);
      final exclusiveEnd = to.toUtc();
      final buckets = series.map((raw) {
        final bucket = _pipelineAnalyticsBucket(raw);
        final label = bucket.label;
        if (label != null &&
            (label.isBefore(firstBucket) || !label.isBefore(exclusiveEnd))) {
          throw const FormatException('Bucket outside requested window');
        }
        return bucket;
      });
      final aggregate = analytics['aggregate'] == null
          ? null
          : _pipelineAnalyticsBucket(analytics['aggregate']);
      return PipelineAnalyticsSnapshot(buckets: buckets, aggregate: aggregate);
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  Future<CoverageSummary?> codeCoverageSummary(Project project) async {
    _validateAnalyticsProject(project);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _codeCoverageSummaryQuery,
        'variables': {'path': project.path},
      },
    );
    try {
      final remote = _analyticsProject(
        _analyticsGraphData(response.bytes, feature: l10n.codeCoverageSummary),
        project,
      );
      if (remote['codeCoverageSummary'] == null) return null;
      final summary = objectJson(remote['codeCoverageSummary']);
      final rawAverage = summary['averageCoverage'];
      final average = rawAverage == null
          ? null
          : _optionalAnalyticsDuration(rawAverage);
      if (average != null && average > 100) {
        throw const FormatException('Coverage outside percentage range');
      }
      return CoverageSummary(
        averageCoverage: average,
        coverageCount: _optionalAnalyticsCount(summary['coverageCount']),
        lastUpdatedOn: _optionalAnalyticsDate(summary['lastUpdatedOn']),
      );
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }
}
