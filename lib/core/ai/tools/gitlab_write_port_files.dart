part of 'gitlab_write_port.dart';

extension _FilesPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareFiles(AiWriteRequest request) async {
    final op = request.operationId;
    if (!const {
      'edit_file', 'createFile', 'deleteFile',
      'applySuggestion', 'batchApplySuggestions',
    }.contains(op)) {
      return null;
    }
    final a = request.arguments;
    final project = _positive(a, 'projectId');
    final suggestion = op == 'applySuggestion' || op == 'batchApplySuggestions';
    final iid = suggestion ? _positive(a, 'iid') : null;
    if (!_granted(request.scope, project,
        suggestion ? 'merge_requests' : null, iid, projectOnly: !suggestion)) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    // Validate every model coordinate before starting even read-only traffic.
    if (suggestion) {
      _fileSuggestionItems(request);
      if (a.containsKey('commitMessage') && a['commitMessage'] is! String) {
        throw const ApiFailure(FailureKind.validation);
      }
    } else {
      _filePath(_text(a, 'path'));
      _fileBranch(_text(a, 'branch'));
      _text(a, 'commitMessage');
      if (op == 'edit_file') _fileExactEdits(a['edits']);
      if (op == 'createFile') _fileContent(a['content']);
    }
    final user = await _api.currentUser();
    if ('${_api.instance.key}#${user.id}' != accountKey) {
      throw const ApiFailure(FailureKind.unauthenticated);
    }
    final p = await _api.record(['projects', '$project']);
    if (p['id'] != project) throw const ApiFailure(FailureKind.invalidResponse);
    final projectPath = _responseText(p, 'path_with_namespace');
    if (suggestion) {
      return _prepareFileSuggestions(request, project, iid!, p, projectPath);
    }
    final path = _text(a, 'path');
    final branch = _text(a, 'branch');
    final message = _text(a, 'commitMessage');
    final branchValue = await _fileBranchRead(project, branch);
    final protected = _fileProtected(p, branchValue);
    final ci = isCiConfigPath(path, AiCiConfig.fromProject(p['ci_config_path']));
    final keys = {_key([accountKey, 'project:$project', 'ref', branch, path])};
    final dependencies = {_key([accountKey, 'project:$project', 'ref', branch])};
    String? lastCommit;
    var original = '';
    if (op == 'createFile') {
      // A 404 permits attempting POST; it does not prove nonexistence.
      try {
        await _api.fileMetadata(project, path, branch);
        _fileReject('fileExists');
      } on ApiFailure catch (failure) {
        if (failure.status != 404) _fileReadFailure(failure);
      }
    } else {
      final snapshot = await _fileSnapshot(project, path, branch);
      lastCommit = snapshot.lastCommit;
      original = snapshot.content;
    }
    var content = '';
    List<AiDiffLine> diff;
    AiTextScan? scan;
    if (op == 'edit_file') {
      final applied = applyExactEdits(original, _fileExactEdits(a['edits']));
      if (applied is AiExactEditRejected) _fileReject(applied.reasonCode);
      final edited = applied as AiExactEditApplied;
      content = _fileContent(edited.finalText);
      diff = edited.diff;
      // Preserve engine-created window identities: the checker owns their
      // changed-span provenance, including deletion seams and existing markers.
      scan = AiTextScan(
        original: edited.scan.original,
        newTexts: edited.scan.newTexts,
        windows: edited.scan.windows,
        markdown: isRenderedMarkdownPath(path),
      );
    } else if (op == 'createFile') {
      content = _fileContent(a['content']);
      diff = unifiedDiff('', content);
      scan = AiTextScan(newTexts: [content],
          markdown: isRenderedMarkdownPath(path));
    } else {
      diff = unifiedDiff(original, '');
    }
    Future<Object?> Function() mutation;
    if (op == 'edit_file') {
      final revision = lastCommit!;
      mutation = () => _api.updateRepositoryFile(project, path,
          branch: branch, content: content, message: message,
          lastCommit: revision);
    } else if (op == 'createFile') {
      mutation = () => _api.createRepositoryFile(project, path,
          branch: branch, content: content, message: message);
    } else {
      final revision = lastCommit!;
      mutation = () => _api.deleteFile(project, path,
          branch: branch, message: message, lastCommit: revision);
    }
    final visibility = p['visibility'];
    return AiWritePrepared._(
      request: request,
      releaseName: path,
      confirmName: ci || op == 'deleteFile' ? path :
          protected ? _responseText(branchValue, 'name') : null,
      facts: AiTierFacts(protectedOrDefaultBranch: protected, touchesCiConfig: ci),
      writeKeys: keys,
      dependencyKeys: dependencies,
      bindingTargets: [AiTargetRef(kind: AiTargetKind.file,
          projectId: project, projectPath: projectPath, refName: branch, path: path)],
      bindingDigest: _fileDigest([
        accountKey, op, project, branch, path, lastCommit,
        _fileDigest(original), _fileDiffDigest(diff),
        p['default_branch'], p['ci_config_path'], branchValue['protected'],
        branchValue['default'], message,
      ]),
      journal: AiJournalBindings(lastCommitId: lastCommit),
      preview: op == 'deleteFile'
          ? AiDeletePreview(targetName: path, path: path, ref: branch)
          : AiDiffPreview(path: path, ref: branch, lines: diff,
              newFile: op == 'createFile', ciPath: ci),
      textScan: scan,
      owner: _owner,
      mutation: mutation,
      readback: op == 'deleteFile' ? null : (_) async {
        final read = await _fileSnapshot(project, path, branch);
        if (read.content != content) throw const ApiFailure(FailureKind.conflict);
        return true;
      },
      classify: _resultClassifier,
      projectPath: projectPath,
      projectVisibility: visibility is String ? visibility : null,
    );
  }

  Future<Map<String, dynamic>> _fileBranchRead(int project, String branch) async {
    final value = await _api.record(
        ['projects', '$project', 'repository', 'branches', branch]);
    if (value['name'] != branch || value['protected'] is! bool ||
        value['default'] is! bool) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    return value;
  }

  Future<({String lastCommit, String content})> _fileSnapshot(
      int project, String path, String branch) async {
    try {
      final metadata = await _api.fileMetadata(project, path, branch);
      final revision = metadata['last_commit_id'];
      if (revision is! String || !isFullCommitSha(revision)) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      // The immutable L is essential: a branch-based raw read could silently
      // overwrite a push that happened after the metadata HEAD.
      final content = await _api.textFile(project, revision, path);
      return (lastCommit: revision, content: _fileContent(content));
    } on ApiFailure catch (failure) {
      if (failure.status == 404) _fileReject('fileMissing');
      _fileReadFailure(failure);
    }
  }

  Future<AiWritePrepared> _prepareFileSuggestions(AiWriteRequest request,
      int project, int iid, Map<String, dynamic> p, String projectPath) async {
    final items = _fileSuggestionItems(request);
    final mrPath = ['projects', '$project', 'merge_requests', '$iid'];
    final mr = await _api.record(mrPath);
    if (mr['project_id'] != project || mr['iid'] != iid ||
        mr['source_project_id'] != project) {
      // A fork writes a different repository. An MR grant alone cannot grant
      // that repository; this family supports only a verified in-project source.
      _fileReject('suggestionForeign');
    }
    final branch = _responseText(mr, 'source_branch');
    _fileBranch(branch);
    final branchValue = await _fileBranchRead(project, branch);
    final protected = _fileProtected(p, branchValue);
    final config = AiCiConfig.fromProject(p['ci_config_path']);
    final discussions = <String, Map<String, dynamic>>{};
    final changes = <({String path, String before, String after,
        Map<String, dynamic> position, int id})>[];
    final keys = <AiConflictKey>{};
    final bindings = <AiTargetRef>[AiTargetRef(kind: AiTargetKind.mergeRequest,
        projectId: project, projectPath: projectPath, iid: iid)];
    final diffs = <Map<String, Object?>>[];
    final ciPaths = <String>{};
    for (final item in items) {
      final discussion = item.discussion;
      final value = discussions[discussion] ??=
          await _api.record([...mrPath, 'discussions', discussion]);
      final note = _fileSuggestionNote(value, item);
      final raw = note['suggestions'];
      if (raw is! List) _fileReject('suggestionForeign');
      final matches = raw.whereType<Map<String, dynamic>>()
          .where((s) => s['id'] == item.suggestion).toList();
      if (matches.length != 1) _fileReject('suggestionForeign');
      final server = matches.single;
      if ((server['appliable'] ?? server['applicable']) != true ||
          server['applied'] != false) {
        _fileReject('suggestionNotAppliable');
      }
      if (server['from_content'] is! String || server['to_content'] is! String ||
          (server.containsKey('project_id') && server['project_id'] != project) ||
          (server.containsKey('note_id') && server['note_id'] != item.note)) {
        _fileReject('suggestionForeign');
      }
      // Only the scoped discussion supplies the id passed to the global API.
      final parsed = parseNoteSuggestions(note)
          .where((s) => s.id == item.suggestion).toList();
      if (parsed.length != 1 || !parsed.single.appliable || parsed.single.applied) {
        _fileReject('suggestionNotAppliable');
      }
      final position = note['position'];
      if (position is! Map<String, dynamic> || position['position_type'] != 'text') {
        _fileReject('suggestionForeign');
      }
      final refs = mr['diff_refs'];
      if (refs is! Map<String, dynamic> || mr['sha'] != refs['head_sha']) {
        _fileReject('suggestionForeign');
      }
      for (final name in ['base_sha', 'start_sha', 'head_sha']) {
        final sha = refs[name];
        if (sha is! String || !isFullCommitSha(sha) || position[name] != sha) {
          _fileReject('suggestionForeign');
        }
      }
      final newPath = position['new_path'];
      final oldPath = position['old_path'];
      if ((newPath != null && newPath is! String) ||
          (oldPath != null && oldPath is! String)) {
        _fileReject('suggestionForeign');
      }
      final path = newPath is String && newPath.isNotEmpty ? newPath : oldPath;
      if (path is! String) _fileReject('invalidPath');
      _filePath(path);
      for (final candidate in [oldPath, newPath]) {
        if (candidate is String && candidate.isNotEmpty) {
          _filePath(candidate);
          if (isCiConfigPath(candidate, config)) ciPaths.add(candidate);
        }
      }
      final before = _fileContent(parsed.single.fromContent);
      final after = _fileContent(parsed.single.toContent);
      changes.add((path: path, before: before, after: after,
          position: position, id: item.suggestion));
      keys.add(_key([accountKey, 'project:$project', 'ref', branch, path]));
      bindings.add(AiTargetRef(kind: AiTargetKind.file, projectId: project,
          projectPath: projectPath, refName: branch, path: path));
      diffs.add({'path': path, 'ref': branch, 'suggestionId': item.suggestion,
          'lines': _fileDiffValue(unifiedDiff(before, after))});
    }
    final orderedCi = ciPaths.toList()..sort();
    final message = request.arguments['commitMessage'] as String?;
    final visibility = p['visibility'];
    return AiWritePrepared._(
      request: request,
      releaseName: '!${mr['iid']}',
      confirmName: orderedCi.isNotEmpty ? orderedCi.first :
          protected ? _responseText(branchValue, 'name') : null,
      facts: AiTierFacts(protectedOrDefaultBranch: protected,
          touchesCiConfig: orderedCi.isNotEmpty),
      writeKeys: keys,
      dependencyKeys: {_key([accountKey, 'project:$project', 'mergeRequest', '$iid'])},
      bindingTargets: bindings,
      bindingDigest: _fileDigest([
        accountKey, request.operationId, project, iid, branch, mr['sha'], mr['diff_refs'],
        p['default_branch'], p['ci_config_path'], branchValue['protected'],
        branchValue['default'], message?.trim(),
        for (final change in changes) [change.id, change.path, change.position,
            _fileDigest(change.before), _fileDigest(change.after)],
      ]),
      preview: AiFieldsPreview({'sourceBranch': branch, 'iid': iid,
          'changes': List<Map<String, Object?>>.unmodifiable(diffs),
          'ciPaths': List<String>.unmodifiable(orderedCi),
          if (message != null) 'commitMessage': message.trim()}),
      textScan: AiTextScan(newTexts: [for (final change in changes) change.after],
          // Only rendered paths get Markdown windows; code replacements still
          // receive the independent secret and marker scan in newTexts.
          windows: [for (final change in changes)
            if (isRenderedMarkdownPath(change.path))
              AiTextWindow(before: '', after: change.after)],
          markdown: changes.any((c) => isRenderedMarkdownPath(c.path))),
      journal: AiJournalBindings(headSha: mr['sha'] is String ? mr['sha'] as String : null),
      owner: _owner,
      mutation: request.operationId == 'applySuggestion'
          ? () => _api.applySuggestion(items.single.suggestion, commitMessage: message)
          : () => _api.batchApplySuggestions(
              [for (final item in items) item.suggestion], commitMessage: message),
      readback: (_) async {
        final values = <String, Map<String, dynamic>>{};
        for (final item in items) {
          final value = values[item.discussion] ??=
              await _api.record([...mrPath, 'discussions', item.discussion]);
          final note = _fileSuggestionNote(value, item);
          final matches = parseNoteSuggestions(note)
              .where((s) => s.id == item.suggestion).toList();
          if (matches.length != 1 || !matches.single.applied) {
            throw const ApiFailure(FailureKind.invalidResponse);
          }
        }
        return true;
      },
      classify: _resultClassifier,
      projectPath: projectPath,
      projectVisibility: visibility is String ? visibility : null,
    );
  }
}

Never _fileReject(String reason) => throw AiWriteRefused(reason);

Never _fileReadFailure(ApiFailure failure) {
  if (failure.kind == FailureKind.tooLarge) _fileReject('fileTooLarge');
  if (failure.kind == FailureKind.unsupported) _fileReject('binaryFile');
  throw failure;
}

void _filePath(String path) {
  if (!isValidRepositoryPath(path) || path.isEmpty ||
      path.split('/').any((p) => p.isEmpty || p == '.') ||
      RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(path)) {
    _fileReject('invalidPath');
  }
  if (isSensitiveRepositoryPath(path)) _fileReject('sensitivePath');
}

void _fileBranch(String branch) {
  if (branch.isEmpty || branch.startsWith('-') || branch.endsWith('.') ||
      branch.endsWith('.lock') || branch.contains('..') || branch.contains('@{') ||
      RegExp(r'[\x00-\x20\x7f~^:?*\[\]\\]').hasMatch(branch) ||
      branch.split('/').any((p) => p.isEmpty || p.startsWith('.'))) {
    throw const ApiFailure(FailureKind.validation);
  }
}

bool _fileProtected(Map<String, dynamic> project, Map<String, dynamic> branch) =>
    branch['protected'] == true || branch['default'] == true ||
    project['default_branch'] is! String || project['default_branch'] == branch['name'];

String _fileContent(Object? content) {
  if (content is! String) throw const ApiFailure(FailureKind.validation);
  if (content.contains('\u0000')) _fileReject('binaryFile');
  if (utf8.encode(content).length > 2 * 1024 * 1024 ||
      '\n'.allMatches(content).length + 1 > 20000) {
    _fileReject('fileTooLarge');
  }
  return content;
}

List<AiExactEdit> _fileExactEdits(Object? value) {
  if (value is! List || value.isEmpty || value.length > 20) {
    throw const ApiFailure(FailureKind.validation);
  }
  return [for (final item in value) _fileExactEdit(item)];
}

AiExactEdit _fileExactEdit(Object? value) {
  if (value is! Map<String, Object?> || value.length != 2 ||
      value['old'] is! String || value['new'] is! String) {
    throw const ApiFailure(FailureKind.validation);
  }
  return AiExactEdit(value['old']! as String, value['new']! as String);
}

typedef _FileSuggestion = ({String discussion, int note, int suggestion});

List<_FileSuggestion> _fileSuggestionItems(AiWriteRequest request) {
  final a = request.arguments;
  final Object? raw = request.operationId == 'applySuggestion'
      ? [{'discussionId': a['discussionId'], 'noteId': a['noteId'],
          'suggestionId': a['suggestionId']}]
      : a['suggestions'];
  if (raw is! List || raw.isEmpty) throw const ApiFailure(FailureKind.validation);
  if (raw.length > 20) _fileReject('batchTooLarge');
  final ids = <int>{};
  return [for (final item in raw) () {
    if (item is! Map<String, Object?> || item.length != 3 ||
        item.keys.any((k) => !const {'discussionId', 'noteId', 'suggestionId'}.contains(k))) {
      throw const ApiFailure(FailureKind.validation);
    }
    final discussion = _text(item, 'discussionId');
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(discussion)) {
      throw const ApiFailure(FailureKind.validation);
    }
    final suggestion = _positive(item, 'suggestionId');
    if (!ids.add(suggestion)) _fileReject('suggestionForeign');
    return (discussion: discussion, note: _positive(item, 'noteId'), suggestion: suggestion);
  }()];
}

Map<String, dynamic> _fileSuggestionNote(Map<String, dynamic> value, _FileSuggestion item) {
  final notes = value['notes'];
  if (value['id'] != item.discussion || notes is! List) _fileReject('suggestionForeign');
  final found = notes.whereType<Map<String, dynamic>>()
      .where((n) => n['id'] == item.note).toList();
  if (found.length != 1) _fileReject('suggestionForeign');
  return found.single;
}

String _fileDigest(Object? value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();

List<Object?> _fileDiffValue(List<AiDiffLine> diff) => [
  for (final line in diff) [line.kind.name, line.text, line.oldLine, line.newLine],
];

String _fileDiffDigest(List<AiDiffLine> diff) => _fileDigest(_fileDiffValue(diff));
