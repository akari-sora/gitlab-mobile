// Run only in the dedicated, inspected LIVE_SMOKE pipeline. Never compile a PAT into an App.
import 'dart:convert';
import 'dart:io';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';

Future<void> main() async {
  final tokenFile = Platform.environment['SMOKE_TOKEN_FILE'];
  if (tokenFile == null) { stderr.writeln('Missing file-type smoke credential'); exitCode = 2; return; }
  final token = (await File(tokenFile).readAsString()).trim();
  final api = GitLabApi(instance: GitLabInstance.parse('https://gitlab.com'), token: token);
  final expected = int.parse(Platform.environment['SMOKE_EXPECTED_USER_ID'] ?? '9571238');
  final suffix = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
  final name = 'gitlab-mobile-smoke-$suffix';
  final checks = <Map<String, Object?>>[];
  Project? sandbox;
  var failed = false;
  void require(bool valid) { if (!valid) throw const FormatException('Contract assertion failed'); }
  Future<void> check(String label, Future<void> Function() work) async {
    final start = DateTime.now();
    try {
      await work();
      checks.add({'name': label, 'status': 'PASS', 'milliseconds': DateTime.now().difference(start).inMilliseconds});
      stdout.writeln('PASS $label');
    } catch (error) {
      final safe = error is ApiFailure ? '${error.kind.name}:${error.status}' : error.runtimeType.toString();
      checks.add({'name': label, 'status': 'FAIL', 'error_type': safe});
      stdout.writeln('FAIL $label ($safe)');
      rethrow;
    }
  }
  Future<void> absent(List<String> path, {Map<String, String>? query}) async {
    try { await api.record(path, query: query); }
    on ApiFailure catch (e) { if (e.status == 404) return; rethrow; }
    throw const FormatException('Deleted resource still readable');
  }
  Future<Json> waitPipeline(int project, int id) async {
    for (var i = 0; i < 60; i++) {
      final p = await api.record(['projects', '$project', 'pipelines', '$id']);
      if (const ['success', 'failed', 'canceled', 'skipped', 'manual'].contains(p['status'])) return p;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    throw const FormatException('Pipeline deadline');
  }
  try {
    await check('identity.matches_expected_account', () async { require((await api.currentUser()).id == expected); });
    await check('projects.member.real_header_and_second_page', () async {
      final first = await api.projects(scope: ProjectScope.member);
      require(first.items.isNotEmpty);
      if (first.next != null) {
        final second = await api.projects(scope: ProjectScope.member, next: first.next);
        require(second.items.isNotEmpty);
      }
    });
    await check('projects.create_private_sandbox', () async {
      sandbox = await api.createProject(name: name, path: name);
      require(sandbox!.visibility == 'private' && sandbox!.path.endsWith('/$name') && sandbox!.id != 86648389);
    });
    final p = sandbox!.id;
    final root = ['projects', '$p'];
    var branch = 'main';
    await check('projects.read_by_id_and_encoded_namespace', () async {
      final byId = await api.project('$p');
      final byPath = await api.project(sandbox!.path);
      require(byId.id == byPath.id && byId.visibility == 'private');
      branch = byId.defaultBranch ?? 'main';
    });
    await check('projects.accessible_search_private', () async {
      final page = await api.projects(scope: ProjectScope.accessibleSearch, search: name);
      require(page.items.any((x) => x.id == p));
    });
    await check('projects.update_and_read_back', () async {
      await api.editProject(p, name: name, description: 'Isolated synthetic smoke fixture');
      require((await api.project('$p')).description == 'Isolated synthetic smoke fixture');
    });
    await check('projects.star_read_unstar', () async {
      await api.setStar(p, true);
      require((await api.projects(scope: ProjectScope.starred, search: name)).items.any((x) => x.id == p));
      await api.setStar(p, false);
      require(!(await api.projects(scope: ProjectScope.starred, search: name)).items.any((x) => x.id == p));
    });
    var sha = '';
    await check('repository.fixed_sha_tree_and_readme', () async {
      sha = await api.defaultBranchSha(await api.project('$p'));
      require((await api.tree(p, sha)).items.any((x) => x.name == 'README.md'));
      require((await api.textFile(p, sha, 'README.md')).isNotEmpty);
    });
    final scratch = 'smoke/edit-$suffix';
    const file = 'nested/範例 file.txt';
    await check('branches.create_and_read_encoded_name', () async {
      await api.createBranch(p, scratch, sha);
      require((await api.record([...root, 'repository', 'branches', scratch]))['name'] == scratch);
    });
    await check('files.create_unicode_path_and_read_back', () async {
      await api.saveFile(p, file, branch: scratch, content: 'first\n第二行\n', message: 'smoke create [skip ci]');
      require(await api.textFile(p, scratch, file) == 'first\n第二行\n');
    });
    var oldCommit = '';
    await check('files.update_with_last_commit_and_read_back', () async {
      oldCommit = (await api.fileMetadata(p, file, scratch))['last_commit_id'] as String;
      await api.saveFile(p, file, branch: scratch, content: 'updated\n', message: 'smoke update [skip ci]', lastCommit: oldCommit);
      require(await api.textFile(p, scratch, file) == 'updated\n');
    });
    await check('files.stale_write_rejected_without_overwriting', () async {
      var rejected = false;
      try {
        await api.saveFile(p, file, branch: scratch, content: 'must not overwrite', message: 'stale [skip ci]', lastCommit: oldCommit);
      } on ApiFailure catch (e) { rejected = const [400, 409, 412, 422].contains(e.status); }
      require(rejected && await api.textFile(p, scratch, file) == 'updated\n');
    });
    await check('files.delete_and_verify_404', () async {
      final last = (await api.fileMetadata(p, file, scratch))['last_commit_id'] as String;
      await api.deleteFile(p, file, branch: scratch, message: 'smoke delete [skip ci]', lastCommit: last);
      await absent([...root, 'repository', 'files', file], query: {'ref': scratch});
    });
    await check('branches.delete_and_verify_404', () async {
      await api.deleteBranch(p, scratch);
      await absent([...root, 'repository', 'branches', scratch]);
    });
    var issue = 0;
    await check('issues.create_and_read', () async {
      issue = requiredInt(await api.createIssue(p, {'title': 'Smoke issue', 'description': 'Synthetic description'}), 'iid');
      require((await api.record([...root, 'issues', '$issue']))['title'] == 'Smoke issue');
    });
    await check('issues.update_close_reopen', () async {
      await api.updateIssue(p, issue, {'title': 'Smoke updated', 'description': 'Changed'});
      require((await api.record([...root, 'issues', '$issue']))['description'] == 'Changed');
      require((await api.updateIssue(p, issue, {'state_event': 'close'}))['state'] == 'closed');
      require((await api.updateIssue(p, issue, {'state_event': 'reopen'}))['state'] == 'opened');
    });
    await check('issue_notes.create_read_update_delete', () async {
      final id = requiredInt(await api.createNote(p, 'issues', issue, 'Synthetic note'), 'id');
      final path = [...root, 'issues', '$issue', 'notes', '$id'];
      require((await api.record(path))['body'] == 'Synthetic note');
      await api.updateNote(p, 'issues', issue, id, 'Updated note');
      require((await api.record(path))['body'] == 'Updated note');
      await api.deleteNote(p, 'issues', issue, id);
      await absent(path);
    });
    await check('labels.create_read_update_delete', () async {
      final created = await api.writeRecord('POST', [...root, 'labels'], {'name': 'smoke-label', 'color': '#4763e4'});
      final path = [...root, 'labels', '${requiredInt(created, 'id')}'];
      require((await api.record(path))['name'] == 'smoke-label');
      await api.writeRecord('PUT', path, {'description': 'Updated synthetic label'});
      require((await api.record(path))['description'] == 'Updated synthetic label');
      await api.removeRecord(path); await absent(path);
    });
    await check('milestones.create_read_update_delete', () async {
      final created = await api.writeRecord('POST', [...root, 'milestones'], {'title': 'Smoke milestone'});
      final path = [...root, 'milestones', '${requiredInt(created, 'id')}'];
      require((await api.record(path))['title'] == 'Smoke milestone');
      await api.writeRecord('PUT', path, {'description': 'Updated milestone', 'state_event': 'close'});
      require((await api.record(path))['state'] == 'closed');
      await api.removeRecord(path); await absent(path);
    });
    await check('todos.create_on_fixture_and_complete_only_fixture', () async {
      final todo = await api.writeRecord('POST', [...root, 'issues', '$issue', 'todo'], {});
      final id = requiredInt(todo, 'id');
      final page = await api.records(['todos'], query: {'project_id': '$p', 'state': 'pending'});
      require(page.items.any((x) => x['id'] == id));
      require((await api.markTodoDone(id))['state'] == 'done');
    });
    await check('issues.delete_and_verify_404', () async {
      await api.deleteIssue(p, issue); await absent([...root, 'issues', '$issue']);
    });
    const tag = 'smoke-v0.0.1';
    await check('tags.create_and_read', () async {
      await api.createTag(p, tag, branch, message: 'Synthetic test tag');
      require((await api.record([...root, 'repository', 'tags', tag]))['name'] == tag);
    });
    await check('releases.create_read_update_delete', () async {
      await api.createRelease(p, {'tag_name': tag, 'name': 'Smoke release', 'description': 'Synthetic release'});
      final path = [...root, 'releases', tag];
      require((await api.record(path))['name'] == 'Smoke release');
      await api.updateRelease(p, tag, {'name': 'Updated release', 'description': 'Changed'});
      require((await api.record(path))['name'] == 'Updated release');
      await api.deleteRelease(p, tag); await absent(path);
    });
    await check('tags.delete_and_verify_404', () async {
      await api.deleteTag(p, tag); await absent([...root, 'repository', 'tags', tag]);
    });
    final source = 'smoke/review-$suffix';
    var mr = 0;
    await check('merge_requests.create_and_read', () async {
      await api.createBranch(p, source, branch);
      await api.saveFile(p, 'review.txt', branch: source, content: 'review fixture\n', message: 'smoke review [skip ci]');
      mr = requiredInt(await api.createMergeRequest(p, {
        'source_branch': source, 'target_branch': branch, 'title': 'Smoke MR', 'description': 'Synthetic review',
      }), 'iid');
      require((await api.record([...root, 'merge_requests', '$mr']))['source_branch'] == source);
    });
    await check('merge_requests.update_close_reopen', () async {
      await api.updateMergeRequest(p, mr, {'title': 'Smoke updated MR'});
      require((await api.record([...root, 'merge_requests', '$mr']))['title'] == 'Smoke updated MR');
      require((await api.updateMergeRequest(p, mr, {'state_event': 'close'}))['state'] == 'closed');
      require((await api.updateMergeRequest(p, mr, {'state_event': 'reopen'}))['state'] == 'opened');
    });
    await check('merge_request_notes.create_read_update_delete', () async {
      final id = requiredInt(await api.createNote(p, 'merge_requests', mr, 'Review note'), 'id');
      final path = [...root, 'merge_requests', '$mr', 'notes', '$id'];
      require((await api.record(path))['body'] == 'Review note');
      await api.updateNote(p, 'merge_requests', mr, id, 'Updated review');
      require((await api.record(path))['body'] == 'Updated review');
      await api.deleteNote(p, 'merge_requests', mr, id); await absent(path);
    });
    await check('merge_request_diffs_and_discussion_resolve_reopen_delete', () async {
      final diffs = await api.records([...root, 'merge_requests', '$mr', 'diffs']);
      require(diffs.items.any((x) => x['new_path'] == 'review.txt'));
      final discussion = await api.writeRecord('POST', [...root, 'merge_requests', '$mr', 'discussions'], {'body': 'Synthetic discussion'});
      final discussionId = requiredString(discussion, 'id');
      final path = [...root, 'merge_requests', '$mr', 'discussions', discussionId];
      await api.writeRecord('PUT', path, {'resolved': true});
      await api.writeRecord('PUT', path, {'resolved': false});
      final note = objectJson((discussion['notes'] as List<dynamic>).first);
      await api.removeRecord([...path, 'notes', '${requiredInt(note, 'id')}']);
    });
    await check('merge_requests.stale_sha_rejected', () async {
      var rejected = false;
      try { await api.mergeRequest(p, mr, '0000000000000000000000000000000000000000'); }
      on ApiFailure catch (e) { rejected = e.status == 409; }
      require(rejected);
    });
    await check('merge_requests.merge_expected_sha_and_read_back', () async {
      Json current = {};
      for (var i = 0; i < 20; i++) {
        current = await api.record([...root, 'merge_requests', '$mr']);
        if (current['detailed_merge_status'] == 'mergeable') break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await api.mergeRequest(p, mr, requiredString(current, 'sha'));
      for (var i = 0; i < 20; i++) {
        current = await api.record([...root, 'merge_requests', '$mr']);
        if (current['state'] == 'merged') break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      require(current['state'] == 'merged');
    });
    await check('merge_requests.delete_and_branch_cleanup', () async {
      await api.deleteMergeRequest(p, mr); await absent([...root, 'merge_requests', '$mr']);
      await api.deleteBranch(p, source);
    });
    var pipeline = 0;
    const config = '''workflow:
  rules:
    - if: '\$CI_PIPELINE_SOURCE == "api"'
default:
  image: busybox:1.37
  tags: [saas-linux-small-amd64]
smoke:
  script: ["echo synthetic-smoke-ok"]
manual_probe:
  when: manual
  allow_failure: true
  script: ["echo synthetic-manual-ok"]
retry_probe:
  allow_failure: true
  script: ["exit 1"]
''';
    await check('pipelines.create_read_and_jobs', () async {
      await api.saveFile(p, '.gitlab-ci.yml', branch: branch, content: config, message: 'smoke CI fixture [skip ci]');
      pipeline = requiredInt(await api.createPipeline(p, branch), 'id');
      require((await api.record([...root, 'pipelines', '$pipeline']))['id'] == pipeline);
      await waitPipeline(p, pipeline);
      require((await api.records([...root, 'pipelines', '$pipeline', 'jobs'])).items.isNotEmpty);
    });
    await check('jobs.read_trace_retry_new_attempt_and_manual_play', () async {
      final jobs = (await api.records([...root, 'pipelines', '$pipeline', 'jobs'])).items;
      final passed = jobs.firstWhere((x) => x['name'] == 'smoke');
      require((await api.jobTrace(p, requiredInt(passed, 'id'))).contains('synthetic-smoke-ok'));
      final failedJob = jobs.firstWhere((x) => x['name'] == 'retry_probe');
      final retried = await api.jobAction(p, requiredInt(failedJob, 'id'), 'retry');
      require(retried['id'] != failedJob['id']);
      final manual = jobs.firstWhere((x) => x['name'] == 'manual_probe');
      await api.jobAction(p, requiredInt(manual, 'id'), 'play');
      await waitPipeline(p, pipeline);
    });
    await check('pipelines.retry_then_cancel_then_delete', () async {
      await api.pipelineAction(p, pipeline, 'retry');
      await api.pipelineAction(p, pipeline, 'cancel');
      await waitPipeline(p, pipeline);
      await api.deletePipeline(p, pipeline);
      await absent([...root, 'pipelines', '$pipeline']);
    });
  } catch (_) {
    failed = true;
  } finally {
    final created = sandbox;
    if (created != null) {
      try {
        await check('cleanup.delete_only_owned_synthetic_project', () async {
          final found = await api.project('${created.id}');
          require(found.id != 86648389 && found.path == created.path && found.path.endsWith('/$name'));
          await api.deleteProject(found.id);
          try {
            final remaining = await api.record(['projects', '${found.id}']);
            require(remaining['marked_for_deletion_at'] != null || remaining['marked_for_deletion_on'] != null);
          } on ApiFailure catch (e) { if (e.status != 404) rethrow; }
        });
      } catch (_) { failed = true; }
    }
    api.close();
    final report = <String, Object?>{
      'source_sha': Platform.environment['CI_COMMIT_SHA'],
      'pipeline_id': Platform.environment['CI_PIPELINE_ID'],
      'finished_at': DateTime.now().toUtc().toIso8601String(),
      'credential_embedded': false,
      'suite': 'production-Dart-client / GitLab.com / isolated-private-sandbox',
      'status': failed ? 'FAIL' : 'PASS', 'checks': checks,
      'not_run': ['independent-reviewer approval', 'Android device UI', 'iOS device UI'],
    };
    Directory('smoke-output').createSync(recursive: true);
    File('smoke-output/report.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('BEGIN_SANITIZED_SMOKE_REPORT');
    stdout.writeln(jsonEncode(report));
    stdout.writeln('END_SANITIZED_SMOKE_REPORT');
    if (failed) exitCode = 1;
  }
}
