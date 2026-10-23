part of 'gitlab_write_port.dart';

extension _ProjectPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareProject(AiWriteRequest request) async {
    final op = request.operationId;
    if (!aiProjectRows.any((row) => row.operationId == op)) return null;
    final a = request.arguments;
    final creating = op == 'createProject';
    final personal = creating || op == 'forkProject';
    final project = creating ? null : _positive(a, 'projectId');
    if (!request.scope.grants.any((grant) =>
        grant.kind == AiScopeKind.project &&
        grant.projectId != null &&
        grant.projectId! > 0 &&
        (creating || grant.projectId == project))) {
      throw const ApiFailure(FailureKind.forbidden);
    }

    // This is also the coordinator's existing typed reason-code envelope.
    // No journal mutation occurs during preparation.
    final user = await _api.currentUser();
    if ('${_api.instance.key}#${user.id}' != accountKey) {
      throw const ApiFailure(FailureKind.unauthenticated);
    }
    if (personal && !_projectSegment(user.username)) {
      throw const AiWriteRefused('personalNamespaceUnknown');
    }
    final p = creating
        ? <String, dynamic>{}
        : await _api.record(['projects', '$project']);
    if (!creating && p['id'] != project) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final projectName = creating ? null : _responseText(p, 'path_with_namespace');
    final projectKey = <String>[accountKey, 'project:$project'];
    var keys = <AiConflictKey>{_key(projectKey)};
    final dependencies = <AiConflictKey>{};
    var confirmName = projectName ?? '';
    var releaseName = projectName ?? '';
    final binding = <Object?>[
      user.id, user.username, project, projectName, p['visibility'],
    ];
    late Future<Object?> Function() mutation;
    late Future<Object?> Function(Object?) readback;
    late bool Function(Object?) confirmed;
    late AiWritePreview preview;
    AiTargetRef? bindingTarget;

    switch (op) {
      case 'deletePackage':
      case 'deletePackageFile':
        _projectNotArchived(p);
        final package = _positive(a, 'packageId');
        final path = ['projects', '$project', 'packages', '$package'];
        final value = await _api.record(path);
        if (value['id'] != package ||
            (value.containsKey('project_id') && value['project_id'] != project)) {
          throw const ApiFailure(FailureKind.forbidden);
        }
        final links = value['_links'];
        if (links is! Map ||
            links['delete_api_path'] is! String ||
            (links['delete_api_path'] as String).isEmpty) {
          throw const AiWriteRefused('packageNotDeletable');
        }
        // Match RegistryPackage.identity without following its supplied URL.
        final name = _responseText(value, 'name');
        final version = value['version'];
        if (version != null && version is! String) {
          throw const ApiFailure(FailureKind.invalidResponse);
        }
        confirmName = '$name@${version == null || version == '' ? 'versionless' : version}';
        binding.addAll([package, name, version]);
        keys = {_key([...projectKey, 'packages', '$package'])};
        if (op == 'deletePackage') {
          mutation = () => _api.deletePackage(project!, package);
          readback = (_) => _projectAbsent(path);
        } else {
          final file = _positive(a, 'fileId');
          final filesPath = [...path, 'package_files'];
          final files = await _projectPackageFiles(filesPath);
          final matches = files.where((item) => item['id'] == file).toList();
          if (matches.length != 1) {
            throw const ApiFailure(FailureKind.conflict);
          }
          final selected = matches.single;
          if ((selected.containsKey('package_id') && selected['package_id'] != package) ||
              (selected.containsKey('project_id') && selected['project_id'] != project)) {
            throw const ApiFailure(FailureKind.forbidden);
          }
          confirmName = _responseText(selected, 'file_name');
          binding.addAll([file, confirmName, selected['file_sha256']]);
          keys = {_key([...projectKey, 'packages', '$package', 'files', '$file'])};
          mutation = () => _api.deletePackageFile(project!, package, file);
          readback = (_) async =>
              !(await _projectPackageFiles(filesPath)).any((item) => item['id'] == file);
        }
        confirmed = (value) => value == true;
        preview = AiDeletePreview(targetName: confirmName, path: projectName);
        bindingTarget = AiTargetRef(
          kind: AiTargetKind.other,
          projectId: project,
          projectPath: projectName,
          name: confirmName,
        );
      case 'deleteContainerRepository':
      case 'deleteContainerTag':
        _projectNotArchived(p);
        if (await _api.effectiveProjectAccess(project!, user.id) < 40) {
          throw const AiWriteRefused('maintainerRequired');
        }
        final repository = _positive(a, 'repositoryId');
        final repositoryPath = ['registry', 'repositories', '$repository'];
        final value = await _projectContainer(repositoryPath);
        if (value['id'] != repository || value['project_id'] != project) {
          throw const AiWriteRefused('containerMissing');
        }
        final repositoryName = _responseText(value, 'path');
        confirmName = repositoryName;
        binding.addAll([repository, repositoryName]);
        keys = {_key([...projectKey, 'registry', '$repository'])};
        if (op == 'deleteContainerRepository') {
          mutation = () => _api.deleteContainerRepository(project, repository);
          readback = (_) => _containerDeletionState(repositoryPath, project);
        } else {
          final tag = _text(a, 'tag');
          final tagPath = [
            'projects',
            '$project',
            'registry',
            'repositories',
            '$repository',
            'tags',
            tag,
          ];
          final value = await _projectContainer(tagPath);
          if (_responseText(value, 'name') != tag) {
            throw const AiWriteRefused('containerMissing');
          }
          confirmName = '$repositoryName:${value['name']}';
          binding.addAll([tag, value['digest'], value['revision']]);
          keys = {_key([...projectKey, 'registry', '$repository', tag])};
          mutation = () => _api.deleteContainerTag(project, repository, tag);
          readback = (_) => _projectAbsent(tagPath);
        }
        confirmed = (value) => value == true;
        preview = AiDeletePreview(targetName: confirmName, path: projectName);
        bindingTarget = AiTargetRef(
          kind: AiTargetKind.other,
          projectId: project,
          projectPath: projectName,
          name: confirmName,
        );
      case 'createProject':
        final name = _text(a, 'name');
        final path = _text(a, 'path');
        if (!_projectSegment(path)) {
          throw const ApiFailure(FailureKind.validation);
        }
        final description = _projectOptionalText(a, 'description') ?? '';
        final destination = '${user.username}/$path';
        confirmName = releaseName = destination;
        binding.add(destination);
        keys = {_key([accountKey, 'namespace:${user.id}', 'projects'])};
        mutation = () async {
          final created = await _api.createProject(
            name: name, path: path, description: description,
          );
          return {'id': created.id};
        };
        readback = _projectCreatedReadback;
        confirmed = (value) => value is Map && value['path_with_namespace'] == destination &&
            value['visibility'] == 'private' && value['name'] == name &&
            (value['description'] ?? '') == description;
        preview = AiFieldsPreview({
          'name': name, 'path': destination, 'description': description,
          'visibility': 'private', 'initialize_with_readme': true,
        });
      case 'editProject':
        if (!a.containsKey('name') && !a.containsKey('description')) {
          throw const ApiFailure(FailureKind.validation);
        }
        final name = a.containsKey('name')
            ? _text(a, 'name') : _responseText(p, 'name');
        final description = a.containsKey('description')
            ? _projectOptionalText(a, 'description')!
            : p['description'] == null ? '' : _projectOptionalText(p, 'description')!;
        // The wrapper sends both fields. Bind their fresh snapshot to avoid
        // silently overwriting a concurrent edit to an omitted field.
        binding.addAll([p['name'], p['description'], name, description]);
        keys = {_key([...projectKey, 'settings'])};
        mutation = () async {
          final edited = await _api.editProject(project!, name: name, description: description);
          return {'id': edited.id};
        };
        readback = (_) => _api.record(['projects', '$project']);
        confirmed = (value) => value is Map && value['id'] == project &&
            value['path_with_namespace'] == projectName && value['name'] == name &&
            (value['description'] ?? '') == description;
        preview = AiFieldsPreview({'name': name, 'description': description});
      case 'deleteProject':
        mutation = () => _api.deleteProject(project!);
        readback = (_) => _projectDeletionState(['projects', '$project']);
        confirmed = (value) => value == true;
        preview = AiDeletePreview(targetName: confirmName, path: projectName);
      case 'forkProject':
        final path = _responseText(p, 'path');
        if (!_projectSegment(path)) {
          throw const AiWriteRefused('personalNamespaceUnknown');
        }
        final destination = '${user.username}/$path';
        confirmName = releaseName = destination;
        binding.add(destination);
        keys = {_key([accountKey, 'namespace:${user.id}', 'projects'])};
        // Retain the source dependency despite the destination collection key.
        dependencies.add(_key(projectKey));
        mutation = () => _api.forkProject(project!);
        readback = _projectCreatedReadback;
        confirmed = (value) => value is Map && value['path_with_namespace'] == destination;
        preview = AiFieldsPreview({'sourcePath': projectName, 'destinationPath': destination});
      default:
        return null;
    }
    return AiWritePrepared._(
      request: request,
      releaseName: releaseName,
      confirmName: confirmName,
      writeKeys: keys,
      dependencyKeys: dependencies,
      owner: _owner,
      mutation: mutation,
      readback: readback,
      projectPath: projectName,
      projectVisibility: creating ? 'private' : p['visibility'] as String?,
      bindingTargets: [
        bindingTarget ?? AiTargetRef(
          kind: AiTargetKind.project,
          projectId: project,
          projectPath: projectName,
          name: personal ? confirmName : projectName,
        ),
      ],
      bindingDigest: sha256.convert(utf8.encode(jsonEncode(binding))).toString(),
      preview: preview,
      classify: (prepared, {result, readback, mutationError, readbackError}) {
        if (mutationError == null &&
            readbackError == null &&
            readback == _deletionScheduled) {
          return _outcome(
            prepared,
            AiJournalState.succeeded,
            'deletionScheduled',
            readbackVerified: true,
          );
        }
        if (mutationError == null && readbackError == null && !confirmed(readback)) {
          return _outcome(prepared, AiJournalState.writeUncertain, 'readbackUnconfirmed');
        }
        return _resultClassifier?.call(prepared, result: result, readback: readback,
            mutationError: mutationError, readbackError: readbackError);
      },
    );
  }

  Future<Map<String, dynamic>> _projectCreatedReadback(Object? result) async {
    final id = _resultInt(result, 'id');
    final value = await _api.record(['projects', '$id']);
    if (value['id'] != id) throw const ApiFailure(FailureKind.invalidResponse);
    return value;
  }

  Future<Map<String, dynamic>> _projectContainer(List<String> path) async {
    try {
      return await _api.record(path);
    } on ApiFailure catch (error) {
      if (error.status != 404) rethrow;
      throw const AiWriteRefused('containerMissing');
    }
  }

  Future<bool> _projectAbsent(List<String> path) async {
    try {
      await _api.record(path);
      return false;
    } on ApiFailure catch (error) {
      if (error.status != 404) rethrow;
      // Acknowledged deletion followed by absence/inaccessibility. This does
      // not make an arbitrary preflight 404 proof of a deleted resource.
      return true;
    }
  }

  Future<Object> _projectDeletionState(List<String> path) async {
    try {
      final value = await _api.record(path);
      final markedOn = value['marked_for_deletion_on'];
      final markedAt = value['marked_for_deletion_at'];
      if ((markedOn is String && markedOn.trim().isNotEmpty) ||
          (markedAt is String && markedAt.trim().isNotEmpty)) {
        return _deletionScheduled;
      }
      return false;
    } on ApiFailure catch (error) {
      if (error.status != 404) rethrow;
      return true;
    }
  }

  Future<Object> _containerDeletionState(
    List<String> path,
    int project,
  ) async {
    try {
      final value = await _api.record(path);
      if (value['project_id'] != project) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (value['status'] == 'delete_scheduled' ||
          value['status'] == 'delete_ongoing') {
        return _deletionScheduled;
      }
      return false;
    } on ApiFailure catch (error) {
      if (error.status != 404) rethrow;
      return true;
    }
  }

  Future<List<Map<String, dynamic>>> _projectPackageFiles(List<String> path) async {
    final files = <Map<String, dynamic>>[];
    Uri? next;
    for (var page = 0; page < 3; page++) {
      final response = await _api.records(path, query: const {'per_page': '100'}, next: next);
      files.addAll(response.items);
      next = response.next;
      if (next == null) return files;
    }
    throw const ApiFailure(FailureKind.tooLarge);
  }
}

const _deletionScheduled = 'deletionScheduled';

void _projectNotArchived(Map<String, dynamic> project) {
  if (project['archived'] == true) throw const AiWriteRefused('projectArchived');
}

bool _projectSegment(String value) =>
    RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*$').hasMatch(value) &&
    value != '.' && value != '..';

String? _projectOptionalText(Map<String, Object?> value, String key) {
  if (!value.containsKey(key)) return null;
  final text = value[key];
  if (text is! String) throw const ApiFailure(FailureKind.validation);
  return text;
}
