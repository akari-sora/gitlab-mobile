// Public read-only integration checks. No PAT, CI_JOB_TOKEN or private data.
// Uses production parsing/pagination/HTTP streaming with only authentication
// removed for GitLab endpoints that explicitly permit anonymous public reads.
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/pipeline_graph.dart';
import 'package:gitlab_mobile/core/registry_models.dart';
import 'package:gitlab_mobile/core/repository_graph.dart';
import 'package:gitlab_mobile/core/snippet_models.dart';
import 'package:gitlab_mobile/core/unified_diff.dart';

const _publicProjectId = 86648389;
const _publicProjectPath = 'aa22396584/gitlab-mobile';
const _publicPipelineId = 2906089178;
const _pipelineGraphQuery = r'''
query MobilePipelineGraph($path: ID!, $pipeline: CiPipelineID!, $after: String) {
  project(fullPath: $path) {
    id
    pipeline(id: $pipeline) {
      id iid
      stages(first: 100) { nodes { name } pageInfo { hasNextPage } }
      jobs(first: 20, after: $after) {
        nodes {
          id name status kind retried schedulingType stage { name }
          needs(first: 100) {
            nodes { name }
            pageInfo { hasNextPage endCursor }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
''';

Future<void> main() async {
  final checks = <Map<String, Object?>>[];
  var failed = false, sawProjectsLink = false;
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final restRead =
            const ['GET', 'HEAD'].contains(request.method) &&
            request.uri.scheme == 'https' &&
            request.uri.host == 'gitlab.com' &&
            request.uri.path.startsWith('/api/v4/');
        final graphRead = _isExactPublicPipelineGraph(request);
        if (!restRead && !graphRead) {
          handler.reject(
            DioException(
              requestOptions: request,
              error: 'Public smoke permits only GitLab public reads',
            ),
          );
          return;
        }
        request.headers.removeWhere((key, _) {
          final lower = key.toLowerCase();
          return lower == 'cookie' ||
              lower == 'cookie2' ||
              lower == 'private-token' ||
              lower == 'job-token' ||
              lower == 'x-gitlab-token' ||
              lower.endsWith('authorization');
        });
        handler.next(request);
      },
      onResponse: (response, handler) {
        if (response.requestOptions.uri.path == '/api/v4/projects' &&
            response.headers.map.containsKey('link')) {
          sawProjectsLink = true;
        }
        handler.next(response);
      },
    ),
  );
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://gitlab.com'),
    token: 'unused-public-probe-placeholder',
    dio: dio,
  );
  void require(bool value) {
    if (!value) {
      throw const FormatException('Public contract assertion');
    }
  }

  Future<void> check(String name, Future<void> Function() run) async {
    final clock = Stopwatch()..start();
    try {
      await run();
      checks.add({
        'name': name,
        'status': 'PASS',
        'milliseconds': clock.elapsedMilliseconds,
      });
      stdout.writeln('PASS $name');
    } catch (error) {
      failed = true;
      final kind = error is ApiFailure
          ? '${error.kind.name}:${error.status}'
          : error.runtimeType.toString();
      checks.add({'name': name, 'status': 'FAIL', 'error_type': kind});
      stdout.writeln('FAIL $name ($kind)');
    }
  }

  Future<void> expectedGap(
    String name,
    Future<void> Function() run, {
    required int status,
  }) async {
    final clock = Stopwatch()..start();
    try {
      await run();
      failed = true;
      checks.add({
        'name': name,
        'status': 'FAIL',
        'error_type': 'unexpectedly_available_anonymously',
      });
      stdout.writeln('FAIL $name (unexpectedly available anonymously)');
    } on ApiFailure catch (error) {
      if (error.status != status) {
        failed = true;
        checks.add({
          'name': name,
          'status': 'FAIL',
          'error_type': '${error.kind.name}:${error.status}',
        });
        stdout.writeln('FAIL $name (${error.kind.name}:${error.status})');
        return;
      }
      checks.add({
        'name': name,
        'status': 'GAP',
        'expected_status': status,
        'milliseconds': clock.elapsedMilliseconds,
      });
      stdout.writeln('GAP $name (expected HTTP $status)');
    }
  }

  try {
    await check('public.project.numeric_id', () async {
      final project = await api.project('$_publicProjectId');
      require(
        project.path == _publicProjectPath && project.visibility == 'public',
      );
    });
    await check('public.project.encoded_namespace', () async {
      require((await api.project(_publicProjectPath)).id == _publicProjectId);
    });
    await check('public.repository.paged_topological_graph', () async {
      const query = {
        'ref_name': '0e1298e339bb5d23bdf80c31eef5d830d8716fe2',
        'order': 'topo',
        'per_page': '5',
      };
      final first = await api.records([
        'projects',
        '$_publicProjectId',
        'repository',
        'commits',
      ], query: query);
      require(first.items.length == 5 && first.next != null);
      final second = await api.records(
        ['projects', '$_publicProjectId', 'repository', 'commits'],
        query: query,
        next: first.next,
      );
      require(second.items.length == 5);
      final graph = RepositoryGraphLayout.fromJson([
        ...first.items,
        ...second.items,
      ]);
      require(graph.rows.length == 10 && graph.laneCount >= 1);
      require(graph.rows.any((row) => row.commit.parentIds.length > 1));
    });
    await check('public.pipeline.actual_dependency_graph', () async {
      final project = await api.project('$_publicProjectId');
      final graph = PipelineGraphPageData.fromJson(
        await api.pipelineGraphPage(project, _publicPipelineId),
      );
      final android = graph.jobs.singleWhere(
        (job) => job.name == 'android_debug',
      );
      require(graph.pipelineId == _publicPipelineId);
      require(android.kind == 'BUILD' && android.needs.length == 4);
      require(
        android.needs.toSet().containsAll(const {
          'public_api_smoke',
          'native_templates',
          'flutter_checks',
          'python_checks',
        }),
      );
      final resolved = resolvePipelineGraphNeeds(graph.jobs)[android.id]!;
      require(
        resolved.length == 4 &&
            resolved.every(
              (need) => need.state == PipelineGraphNeedState.resolved,
            ),
      );
    });
    await check('public.registry.list_detail_files', () async {
      final page = await api.records(
        ['projects', '$_publicProjectId', 'packages'],
        query: const {
          'package_name': 'gitlab-mobile-preview',
          'include_versionless': 'true',
          'order_by': 'created_at',
          'sort': 'desc',
          'per_page': '5',
        },
      );
      require(page.items.isNotEmpty);
      final listed = RegistryPackage.fromJson(page.items.first);
      final detail = RegistryPackage.fromJson(
        await api.record([
          'projects',
          '$_publicProjectId',
          'packages',
          '${listed.id}',
        ]),
      );
      final filesPage = await api.records(
        [
          'projects',
          '$_publicProjectId',
          'packages',
          '${listed.id}',
          'package_files',
        ],
        query: const {
          'order_by': 'created_at',
          'sort': 'desc',
          'per_page': '20',
        },
      );
      final files = filesPage.items
          .map(RegistryPackageFile.fromJson)
          .toList(growable: false);
      require(detail.id == listed.id && detail.name == 'gitlab-mobile-preview');
      require(files.any((file) => file.name == 'SHA256SUMS'));
      require(files.any((file) => file.name.endsWith('-debug.apk')));
    });
    await check('public.snippet.actual_multifile_metadata_not_crud', () async {
      final response = await api.record([
        'projects',
        '278964',
        'snippets',
        '6030720',
      ]);
      require(response['files'] is List<dynamic>);
      final snippets = <ProjectSnippet>[ProjectSnippet.fromJson(response)];
      final snippet = snippets.single..requireProject(278964);
      require(snippet.visibility == 'public' && snippet.hasExplicitFiles);
      require(snippet.filePaths.length > 1 && !snippet.canUseLegacyRaw);
      require(snippet.filePaths.every((path) => path.trim().isNotEmpty));
    });
    await expectedGap('public.boards.authentication_required', () async {
      await api.records(
        ['projects', '$_publicProjectId', 'boards'],
        query: const {'per_page': '1'},
      );
    }, status: 401);
    await check('public.projects.real_link_header_and_second_page', () async {
      const query = {
        'per_page': '1',
        'search': 'gitlab',
        'order_by': 'id',
        'sort': 'asc',
      };
      final first = await api.records(['projects'], query: query);
      require(first.items.length == 1 && first.next != null && sawProjectsLink);
      require(first.next!.queryParameters['search'] == 'gitlab');
      final next = await api.records(
        ['projects'],
        query: query,
        next: first.next,
      );
      require(
        next.items.length == 1 &&
            next.items.first['id'] != first.items.first['id'],
      );
    });
    await check('public.repository.fixed_sha_tree_readme', () async {
      final project = await api.project('86648389');
      final sha = await api.defaultBranchSha(project);
      final tree = await api.tree(project.id, sha);
      require(tree.items.any((row) => row.name == 'README.md'));
      require(
        (await api.textFile(
          project.id,
          sha,
          'README.md',
        )).contains('GitLab Mobile'),
      );
    });
    await check('public.metadata.branches_tags_releases', () async {
      require(
        (await api.records([
          'projects',
          '86648389',
          'repository',
          'branches',
        ])).items.isNotEmpty,
      );
      await api.records(['projects', '86648389', 'repository', 'tags']);
      await api.records(['projects', '86648389', 'releases']);
    });
    await check('public.compare.fixed_revisions', () async {
      final result = await api.record(
        ['projects', '86648389', 'repository', 'compare'],
        query: {
          'from': '911a953ee92b2e3ddd3e526c3691e6495c311ad3',
          'to': '0e1298e339bb5d23bdf80c31eef5d830d8716fe2',
          'straight': 'true',
          'unidiff': 'true',
        },
      );
      require(
        result['commits'] is List &&
            result['diffs'] is List &&
            result['compare_same_ref'] == false,
      );
      final files = result['diffs'] as List<dynamic>;
      final file = files.cast<Map<String, dynamic>>().firstWhere(
        (row) => row['new_path'] == 'lib/core/workspace_api.dart',
      );
      require(file['collapsed'] != true && file['too_large'] != true);
      final lines = parseUnifiedDiff(file['diff'] as String);
      require(lines.any((line) => line.commentable));
    });
    await check('public.missing_file_is_404_not_auth_failure', () async {
      try {
        await api.fileMetadata(
          _publicProjectId,
          '__nonexistent_public_smoke_fixture_86648389__.txt',
          'main',
        );
      } on ApiFailure catch (error) {
        require(error.status == 404);
        return;
      }
      throw const FormatException('Missing file unexpectedly readable');
    });
  } finally {
    api.close();
    final report = {
      'suite': 'production-Dart-public-read-integration',
      'source_sha': Platform.environment['CI_COMMIT_SHA'],
      'pipeline_id': Platform.environment['CI_PIPELINE_ID'],
      'authentication': 'anonymous; no credential read or sent',
      'writes': 0,
      'status': failed ? 'FAIL' : 'PASS',
      'checks': checks,
      'gaps': ['Issue boards return HTTP 401 to anonymous public reads'],
      'not_run': [
        'PAT authentication',
        'authenticated issue boards',
        'private project access',
        'snippet CRUD',
        'live writes/CRUD',
        'Android/iOS device UI',
      ],
    };
    Directory('public-smoke-output').createSync(recursive: true);
    File(
      'public-smoke-output/report.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('BEGIN_PUBLIC_SMOKE_REPORT');
    stdout.writeln(jsonEncode(report));
    stdout.writeln('END_PUBLIC_SMOKE_REPORT');
    if (failed) {
      exitCode = 1;
    }
  }
}

bool _isExactPublicPipelineGraph(RequestOptions request) {
  if (request.method != 'POST' ||
      request.uri != Uri.parse('https://gitlab.com/api/graphql')) {
    return false;
  }
  final body = request.data;
  if (body is! Map ||
      body.length != 2 ||
      !body.containsKey('query') ||
      !body.containsKey('variables') ||
      body['query'] != _pipelineGraphQuery) {
    return false;
  }
  final variables = body['variables'];
  return variables is Map &&
      variables.length == 3 &&
      variables['path'] == _publicProjectPath &&
      variables['pipeline'] == 'gid://gitlab/Ci::Pipeline/$_publicPipelineId' &&
      variables.containsKey('after') &&
      variables['after'] == null;
}
