import 'models.dart';

enum TestReportStatus {
  success,
  failed,
  skipped,
  error,
  suiteError,
  noReport,
  inProgress,
}

int _asInt(Object? value, [int defaultValue = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? defaultValue;
  return defaultValue;
}

double _asDouble(Object? value, [double defaultValue = 0.0]) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? defaultValue;
  return defaultValue;
}

/// Summary metrics for an individual test suite within a pipeline.
final class TestSuiteSummary {
  const TestSuiteSummary({
    required this.name,
    required this.totalTime,
    required this.totalCount,
    required this.successCount,
    required this.failedCount,
    required this.skippedCount,
    required this.errorCount,
    this.suiteError,
    this.buildIds = const [],
  });

  factory TestSuiteSummary.fromJson(Map<String, dynamic> j) {
    final rawBuildIds = j['build_ids'];
    final ids = <int>[
      if (rawBuildIds is List)
        for (final item in rawBuildIds)
          if (item is int && item > 0)
            item
          else if (item is num && item > 0)
            item.toInt()
          else if (item is String && int.tryParse(item) != null)
            int.parse(item),
    ];
    return TestSuiteSummary(
      name: optionalString(j, 'name') ?? '未命名測試套件',
      totalTime: _asDouble(j['total_time'] ?? j['time']),
      totalCount: _asInt(j['total_count'] ?? j['count']),
      successCount: _asInt(j['success_count'] ?? j['success']),
      failedCount: _asInt(j['failed_count'] ?? j['failed']),
      skippedCount: _asInt(j['skipped_count'] ?? j['skipped']),
      errorCount: _asInt(j['error_count'] ?? j['error']),
      suiteError: optionalString(j, 'suite_error'),
      buildIds: List.unmodifiable(ids),
    );
  }

  final String name;
  final double totalTime;
  final int totalCount;
  final int successCount;
  final int failedCount;
  final int skippedCount;
  final int errorCount;
  final String? suiteError;
  final List<int> buildIds;

  bool get hasSuiteError => suiteError != null && suiteError!.isNotEmpty;
  bool get hasFailures => failedCount > 0 || errorCount > 0 || hasSuiteError;
}

/// Overall test report summary from `GET /projects/:id/pipelines/:id/test_report_summary`.
final class TestReportSummary {
  const TestReportSummary({
    required this.totalTime,
    required this.totalCount,
    required this.successCount,
    required this.failedCount,
    required this.skippedCount,
    required this.errorCount,
    this.suiteError,
    this.testSuites = const [],
  });

  factory TestReportSummary.fromJson(Map<String, dynamic> j) {
    final totalObj = j['total'];
    final Map<String, dynamic> total =
        totalObj is Map<String, dynamic> ? totalObj : j;

    final rawSuites = j['test_suites'];
    final suites = <TestSuiteSummary>[
      if (rawSuites is List)
        for (final item in rawSuites)
          if (item is Map<String, dynamic>)
            TestSuiteSummary.fromJson(item),
    ];

    final totalCount = _asInt(total['count'] ?? total['total_count']);
    final successCount = _asInt(total['success'] ?? total['success_count']);
    final failedCount = _asInt(total['failed'] ?? total['failed_count']);
    final skippedCount = _asInt(total['skipped'] ?? total['skipped_count']);
    final errorCount = _asInt(total['error'] ?? total['error_count']);
    final totalTime = _asDouble(total['time'] ?? total['total_time']);
    final suiteError =
        optionalString(total, 'suite_error') ?? optionalString(j, 'suite_error');

    return TestReportSummary(
      totalTime: totalTime,
      totalCount: totalCount,
      successCount: successCount,
      failedCount: failedCount,
      skippedCount: skippedCount,
      errorCount: errorCount,
      suiteError: suiteError,
      testSuites: List.unmodifiable(suites),
    );
  }

  final double totalTime;
  final int totalCount;
  final int successCount;
  final int failedCount;
  final int skippedCount;
  final int errorCount;
  final String? suiteError;
  final List<TestSuiteSummary> testSuites;

  bool get hasSuiteError =>
      (suiteError != null && suiteError!.isNotEmpty) ||
      testSuites.any((s) => s.hasSuiteError);

  bool get isEmpty => totalCount == 0 && testSuites.isEmpty;
  bool get isSuccess =>
      totalCount > 0 && failedCount == 0 && errorCount == 0 && !hasSuiteError;
  bool get isFailed => failedCount > 0 || errorCount > 0 || hasSuiteError;

  TestReportStatus get status {
    if (isEmpty) return TestReportStatus.noReport;
    if (hasSuiteError) return TestReportStatus.suiteError;
    if (failedCount > 0) return TestReportStatus.failed;
    if (errorCount > 0) return TestReportStatus.error;
    if (skippedCount > 0 && successCount == 0) return TestReportStatus.skipped;
    return TestReportStatus.success;
  }
}

/// A single test case execution within a suite.
final class TestCase {
  const TestCase({
    required this.status,
    required this.name,
    this.classname,
    this.file,
    this.executionTime,
    this.systemOutput,
    this.stackTrace,
    this.recentFailures,
    this.jobId,
    this.suiteName,
  });

  factory TestCase.fromJson(
    Map<String, dynamic> j, {
    String? suiteName,
    int? defaultJobId,
  }) {
    final rawJobId = j['job_id'] ?? j['build_id'];
    int? jobId;
    if (rawJobId is int && rawJobId > 0) {
      jobId = rawJobId;
    } else if (rawJobId is num && rawJobId > 0) {
      jobId = rawJobId.toInt();
    } else if (rawJobId is String) {
      jobId = int.tryParse(rawJobId);
    } else if (j['job_url'] is String) {
      final match = RegExp(r'/jobs/(\d+)').firstMatch(j['job_url'] as String);
      if (match != null) jobId = int.tryParse(match.group(1)!);
    }
    jobId ??= defaultJobId;

    String? output;
    final rawOut = j['system_output'];
    if (rawOut is String) {
      output = rawOut;
    } else if (rawOut != null) {
      output = rawOut.toString();
    }

    String? trace;
    final rawTrace = j['stack_trace'];
    if (rawTrace is String) {
      trace = rawTrace;
    } else if (rawTrace != null) {
      trace = rawTrace.toString();
    }

    return TestCase(
      status: optionalString(j, 'status')?.toLowerCase() ?? 'unknown',
      name: optionalString(j, 'name') ?? '未命名測試案例',
      classname: optionalString(j, 'classname'),
      file: optionalString(j, 'file'),
      executionTime:
          j['execution_time'] != null ? _asDouble(j['execution_time']) : null,
      systemOutput: output,
      stackTrace: trace,
      recentFailures: j['recent_failures'] is Map<String, dynamic>
          ? j['recent_failures'] as Map<String, dynamic>
          : null,
      jobId: jobId,
      suiteName: suiteName,
    );
  }

  final String status;
  final String name;
  final String? classname;
  final String? file;
  final double? executionTime;
  final String? systemOutput;
  final String? stackTrace;
  final Map<String, dynamic>? recentFailures;
  final int? jobId;
  final String? suiteName;

  bool get isFailed => status == 'failed' || status == 'error';
  bool get isSuccess => status == 'success';
  bool get isSkipped => status == 'skipped';

  String get identity => '${suiteName ?? ''}:$classname:$name:${jobId ?? ''}';
}

/// A suite containing a group of test cases in `GET /projects/:id/pipelines/:id/test_report`.
final class TestSuite {
  const TestSuite({
    required this.name,
    required this.totalTime,
    required this.totalCount,
    required this.successCount,
    required this.failedCount,
    required this.skippedCount,
    required this.errorCount,
    this.suiteError,
    this.testCases = const [],
  });

  factory TestSuite.fromJson(Map<String, dynamic> j) {
    final name = optionalString(j, 'name') ?? '未命名測試套件';
    final rawBuildIds = j['build_ids'];
    int? defaultJobId;
    if (rawBuildIds is List &&
        rawBuildIds.length == 1 &&
        rawBuildIds.first is int) {
      defaultJobId = rawBuildIds.first as int;
    }
    final rawCases = j['test_cases'];
    final cases = <TestCase>[
      if (rawCases is List)
        for (final item in rawCases)
          if (item is Map<String, dynamic>)
            TestCase.fromJson(item, suiteName: name, defaultJobId: defaultJobId),
    ];
    return TestSuite(
      name: name,
      totalTime: _asDouble(j['total_time'] ?? j['time']),
      totalCount: _asInt(j['total_count'] ?? j['count']),
      successCount: _asInt(j['success_count'] ?? j['success']),
      failedCount: _asInt(j['failed_count'] ?? j['failed']),
      skippedCount: _asInt(j['skipped_count'] ?? j['skipped']),
      errorCount: _asInt(j['error_count'] ?? j['error']),
      suiteError: optionalString(j, 'suite_error'),
      testCases: List.unmodifiable(cases),
    );
  }

  final String name;
  final double totalTime;
  final int totalCount;
  final int successCount;
  final int failedCount;
  final int skippedCount;
  final int errorCount;
  final String? suiteError;
  final List<TestCase> testCases;

  bool get hasSuiteError => suiteError != null && suiteError!.isNotEmpty;
}

/// A paginated page of detailed test reports from `GET /projects/:id/pipelines/:id/test_report`.
final class PipelineTestReportPage {
  const PipelineTestReportPage({
    required this.totalTime,
    required this.totalCount,
    required this.successCount,
    required this.failedCount,
    required this.skippedCount,
    required this.errorCount,
    required this.suites,
    required this.testCases,
    this.next,
  });

  factory PipelineTestReportPage.fromJson(
    Map<String, dynamic> j, {
    Uri? next,
  }) {
    final rawSuites = j['test_suites'];
    final suites = <TestSuite>[
      if (rawSuites is List)
        for (final item in rawSuites)
          if (item is Map<String, dynamic>)
            TestSuite.fromJson(item),
    ];
    final allCases = <TestCase>[
      for (final suite in suites) ...suite.testCases,
    ];
    return PipelineTestReportPage(
      totalTime: _asDouble(j['total_time'] ?? j['time']),
      totalCount: _asInt(j['total_count'] ?? j['count']),
      successCount: _asInt(j['success_count'] ?? j['success']),
      failedCount: _asInt(j['failed_count'] ?? j['failed']),
      skippedCount: _asInt(j['skipped_count'] ?? j['skipped']),
      errorCount: _asInt(j['error_count'] ?? j['error']),
      suites: List.unmodifiable(suites),
      testCases: List.unmodifiable(allCases),
      next: next,
    );
  }

  final double totalTime;
  final int totalCount;
  final int successCount;
  final int failedCount;
  final int skippedCount;
  final int errorCount;
  final List<TestSuite> suites;
  final List<TestCase> testCases;
  final Uri? next;
}
