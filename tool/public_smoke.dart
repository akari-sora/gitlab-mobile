// Public read-only integration checks. No PAT, CI_JOB_TOKEN or private data.
// Uses production parsing/pagination/HTTP streaming with only authentication
// removed for GitLab endpoints that explicitly permit anonymous public reads.
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

Future<void> main() async {
  final checks = <Map<String, Object?>>[];
  var failed = false, sawProjectsLink = false;
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
    if (!const ['GET', 'HEAD'].contains(request.method) ||
        request.uri.scheme != 'https' || request.uri.host != 'gitlab.com' ||
        !request.uri.path.startsWith('/api/v4/')) {
      handler.reject(DioException(requestOptions: request, error: 'Public smoke permits only GitLab public reads'));
      return;
    }
    request.headers.removeWhere((key, _) => const ['private-token', 'authorization', 'job-token', 'cookie'].contains(key.toLowerCase()));
    handler.next(request);
  }, onResponse: (response, handler) {
    if (response.requestOptions.uri.path == '/api/v4/projects' && response.headers.map.containsKey('link')) {
      sawProjectsLink = true;
    }
    handler.next(response);
  }));
  final api = GitLabApi(instance: GitLabInstance.parse('https://gitlab.com'),
    token: 'unused-public-probe-placeholder', dio: dio);
  void require(bool value) { if (!value) { throw const FormatException('Public contract assertion'); } }
  Future<void> check(String name, Future<void> Function() run) async {
    final clock = Stopwatch()..start();
    try {
      await run(); checks.add({'name': name, 'status': 'PASS', 'milliseconds': clock.elapsedMilliseconds});
      stdout.writeln('PASS $name');
    } catch (error) {
      failed = true;
      final kind = error is ApiFailure ? '${error.kind.name}:${error.status}' : error.runtimeType.toString();
      checks.add({'name': name, 'status': 'FAIL', 'error_type': kind});
      stdout.writeln('FAIL $name ($kind)');
    }
  }
  try {
    await check('public.project.numeric_id', () async {
      final project = await api.project('86648389');
      require(project.path == 'aa22396584/gitlab-mobile' && project.visibility == 'public');
    });
    await check('public.project.encoded_namespace', () async {
      require((await api.project('aa22396584/gitlab-mobile')).id == 86648389);
    });
    await check('public.projects.real_link_header_and_second_page', () async {
      const query = {'per_page': '1', 'search': 'gitlab', 'order_by': 'id', 'sort': 'asc'};
      final first = await api.records(['projects'], query: query);
      require(first.items.length == 1 && first.next != null && sawProjectsLink);
      require(first.next!.queryParameters['search'] == 'gitlab');
      final next = await api.records(['projects'], query: query, next: first.next);
      require(next.items.length == 1 && next.items.first['id'] != first.items.first['id']);
    });
    await check('public.repository.fixed_sha_tree_readme', () async {
      final project = await api.project('86648389');
      final sha = await api.defaultBranchSha(project);
      final tree = await api.tree(project.id, sha);
      require(tree.items.any((row) => row.name == 'README.md'));
      require((await api.textFile(project.id, sha, 'README.md')).contains('GitLab Mobile'));
    });
    await check('public.metadata.branches_tags_releases', () async {
      require((await api.records(['projects', '86648389', 'repository', 'branches'])).items.isNotEmpty);
      await api.records(['projects', '86648389', 'repository', 'tags']);
      await api.records(['projects', '86648389', 'releases']);
    });
    await check('public.missing_file_is_404_not_auth_failure', () async {
      try {
        await api.fileMetadata(86648389, '__nonexistent_public_smoke_fixture_86648389__.txt', 'main');
      } on ApiFailure catch (error) { require(error.status == 404); return; }
      throw const FormatException('Missing file unexpectedly readable');
    });
  } finally {
    api.close();
    final report = {
      'suite': 'production-Dart-public-read-integration',
      'source_sha': Platform.environment['CI_COMMIT_SHA'],
      'pipeline_id': Platform.environment['CI_PIPELINE_ID'],
      'authentication': 'anonymous; no credential read or sent',
      'writes': 0, 'status': failed ? 'FAIL' : 'PASS', 'checks': checks,
      'not_run': ['PAT authentication', 'private project access', 'live writes/CRUD', 'Android/iOS device UI'],
    };
    Directory('public-smoke-output').createSync(recursive: true);
    File('public-smoke-output/report.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('BEGIN_PUBLIC_SMOKE_REPORT'); stdout.writeln(jsonEncode(report)); stdout.writeln('END_PUBLIC_SMOKE_REPORT');
    if (failed) { exitCode = 1; }
  }
}
