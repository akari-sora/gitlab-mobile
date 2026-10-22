part of 'gitlab_write_port.dart';

extension _RefsPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareRefs(AiWriteRequest request) async {
    final op = request.operationId;
    if (!aiRefRows.any((row) => row.operationId == op)) return null;
    final a = request.arguments;
    final project = _positive(a, 'projectId');
    if (!_granted(request.scope, project, null, null, projectOnly: true)) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final fields = op == 'createRelease' || op == 'updateRelease'
        ? _refReleaseFields(a, op) : null;
    final name = _refName(fields != null && op == 'createRelease' ? fields : a,
        op.endsWith('Branch') ? 'branch' : 'tag_name');
    final source = op == 'createBranch' || op == 'createTag'
        ? _refName(a, 'ref') : null;
    if (a.containsKey('message') && a['message'] is! String) {
      throw const ApiFailure(FailureKind.validation);
    }
    final user = await _api.currentUser();
    if ('${_api.instance.key}#${user.id}' != accountKey) {
      throw const ApiFailure(FailureKind.unauthenticated);
    }
    final p = await _api.record(['projects', '$project']);
    if (p['id'] != project) throw const ApiFailure(FailureKind.invalidResponse);
    final projectPath = _responseText(p, 'path_with_namespace');
    final prefix = <String>[accountKey, 'project:$project'];
    final refKey = _key([...prefix, 'ref', name]);
    final releaseKey = _key([...prefix, 'release', name]);
    final release = op.endsWith('Release');
    var releaseName = release ? projectPath : name;
    String? confirmName;
    Map<String, dynamic> snapshot;
    List<String> readbackPath;
    late Future<Object?> Function() mutation;
    final dependencies = <AiConflictKey>{};
    final binding = <AiTargetRef>[];
    String? sha;
    switch (op) {
      case 'createBranch':
      case 'createTag':
        snapshot = await _refRecord(
          ['projects', '$project', 'repository', 'commits', source!],
          'refMissing',
        );
        sha = _refCommit(snapshot);
        dependencies.add(_key([...prefix, 'ref', source]));
        readbackPath = ['projects', '$project', 'repository',
          op == 'createBranch' ? 'branches' : 'tags', name];
        if (op == 'createBranch') {
          binding.add(AiTargetRef(kind: AiTargetKind.newBranch,
            projectId: project, projectPath: projectPath,
            name: name, sourceRef: source));
          mutation = () => _api.createBranch(project, name, sha!);
        } else {
          confirmName = name;
          binding.addAll([
            AiTargetRef(kind: AiTargetKind.tag, projectId: project,
              projectPath: projectPath, name: name),
            AiTargetRef(kind: AiTargetKind.ref, projectId: project,
              projectPath: projectPath, refName: source),
          ]);
          mutation = () => _api.createTag(project, name, sha!,
              message: a['message'] as String? ?? '');
        }
      case 'deleteBranch':
        readbackPath = ['projects', '$project', 'repository', 'branches', name];
        snapshot = await _refRecord(readbackPath, 'refMissing');
        _refIdentity(snapshot, 'name', name);
        if (snapshot['default'] == true || p['default_branch'] == name) {
          throw const AiJournalException('defaultBranch');
        }
        if (snapshot['protected'] == true) {
          throw const AiJournalException('protectedBranch');
        }
        if (snapshot['default'] is! bool || snapshot['protected'] is! bool) {
          throw const ApiFailure(FailureKind.invalidResponse);
        }
        sha = _refCommit(snapshot['commit']);
        confirmName = releaseName = _responseText(snapshot, 'name');
        binding.add(AiTargetRef(kind: AiTargetKind.branch, projectId: project,
          projectPath: projectPath, name: confirmName));
        mutation = () => _api.deleteBranch(project, name);
      case 'deleteTag':
      case 'createRelease':
        readbackPath = ['projects', '$project', 'repository', 'tags', name];
        snapshot = await _refRecord(readbackPath, 'tagMissing');
        _refIdentity(snapshot, 'name', name);
        sha = _refCommit(snapshot['commit']);
        binding.add(AiTargetRef(kind: AiTargetKind.tag, projectId: project,
          projectPath: projectPath, name: _responseText(snapshot, 'name')));
        if (op == 'deleteTag') {
          confirmName = releaseName = _responseText(snapshot, 'name');
          mutation = () => _api.deleteTag(project, name);
        } else {
          dependencies.add(refKey);
          readbackPath = ['projects', '$project', 'releases', name];
          mutation = () => _api.createRelease(project, fields!);
        }
      case 'updateRelease':
      case 'deleteRelease':
        readbackPath = ['projects', '$project', 'releases', name];
        snapshot = await _refRecord(readbackPath, 'releaseMissing');
        _refIdentity(snapshot, 'tag_name', name);
        binding.add(AiTargetRef(kind: AiTargetKind.release, projectId: project,
          projectPath: projectPath, name: name));
        if (op == 'deleteRelease') {
          // Tag-only releases may omit optional metadata. Confirmation still
          // uses a name from this read, with the verified tag as its fallback.
          final title = snapshot['name'] == null || snapshot['name'] == ''
              ? _responseText(snapshot, 'tag_name') : _responseText(snapshot, 'name');
          confirmName = title;
          mutation = () => _api.deleteRelease(project, name);
        } else {
          mutation = () => _api.updateRelease(project, name, fields!);
        }
      default:
        throw const ApiFailure(FailureKind.unsupported);
    }
    final deleting = op.startsWith('delete');
    // Bind decision metadata and the exact before-value for edits, rather
    // than a project's unrelated updated_at. Raw text stays process-local.
    final digest = sha256.convert(utf8.encode(jsonEncode({
      'project': project,
      'path': projectPath,
      'name': name,
      'source': source,
      'sha': sha,
      if (op == 'deleteBranch') ...{
        'default': snapshot['default'], 'protected': snapshot['protected'],
        'defaultBranch': p['default_branch'],
      },
      if (op == 'updateRelease' || op == 'deleteRelease')
        for (final key in const ['name', 'description', 'created_at',
          'released_at', 'updated_at', 'commit']) key: snapshot[key],
    }))).toString();
    return AiWritePrepared._(
      request: request,
      releaseName: releaseName,
      confirmName: confirmName,
      writeKeys: {release ? releaseKey : refKey},
      dependencyKeys: dependencies,
      owner: _owner,
      mutation: mutation,
      readback: deleting ? null : (_) => _api.record(readbackPath),
      classify: deleting ? null : (prepared, {result, readback,
          mutationError, readbackError}) {
        if (mutationError != null || readbackError != null) return null;
        bool matches(Object? value) {
          if (value is! Map) return false;
          if (value[release ? 'tag_name' : 'name'] != name) return false;
          if (!release) {
            final commit = value['commit'];
            return commit is Map && commit['id'] == sha;
          }
          return fields!.entries.every((entry) => value[entry.key] == entry.value);
        }
        return matches(result) && matches(readback) ? null : _outcome(
          prepared, AiJournalState.writeUncertain, 'invalidResponse');
      },
      projectPath: projectPath,
      projectVisibility: p['visibility'] is String ? p['visibility'] as String : null,
      bindingTargets: binding,
      bindingDigest: digest,
      journal: AiJournalBindings(headSha: sha,
        updatedAt: snapshot['updated_at'] is String ? snapshot['updated_at'] as String : null),
      preview: deleting ? AiDeletePreview(targetName: confirmName!, ref: name)
          : AiFieldsPreview(request.arguments),
    );
  }

  Future<Map<String, dynamic>> _refRecord(List<String> path, String code) async {
    try {
      return await _api.record(path);
    } on ApiFailure catch (failure) {
      // The code describes missing preflight evidence, never proven absence.
      // This existing coordinator carrier preserves reason codes across parts.
      if (failure.status == 404) throw AiJournalException(code);
      rethrow;
    }
  }
}

String _refName(Map<String, Object?> values, String field) {
  final name = _text(values, field);
  if (name != name.trim() || name == '@' || name.startsWith('-') ||
      name.contains('..') || name.contains('@{') || name.contains('//') ||
      RegExp(r'[\s\x00-\x20\x7f~^:?*\[\\]').hasMatch(name) ||
      name.split('/').any((part) => part.isEmpty || part.startsWith('.') ||
          part.endsWith('.') || part.endsWith('.lock'))) {
    throw const ApiFailure(FailureKind.validation);
  }
  return name;
}

Map<String, dynamic> _refReleaseFields(Map<String, Object?> args, String op) {
  final raw = args['fields'];
  final allowed = _fieldKeys(op)!;
  if (raw is! Map<String, Object?> || raw.isEmpty ||
      raw.entries.any((entry) => !allowed.contains(entry.key) || entry.value is! String)) {
    throw const ApiFailure(FailureKind.validation);
  }
  if (op == 'createRelease') _refName(raw, 'tag_name');
  return Map<String, dynamic>.from(raw);
}

void _refIdentity(Map<String, dynamic> value, String key, String expected) {
  if (value[key] != expected) throw const ApiFailure(FailureKind.invalidResponse);
}

String _refCommit(Object? value) {
  if (value is! Map || value['id'] is! String ||
      !RegExp(r'^[0-9a-fA-F]{40,64}$').hasMatch(value['id'] as String)) {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
  return value['id'] as String;
}
