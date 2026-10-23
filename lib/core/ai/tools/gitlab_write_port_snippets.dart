part of 'gitlab_write_port.dart';

extension _SnippetsPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareSnippets(AiWriteRequest request) async {
    final op = request.operationId;
    if (!aiSnippetRows.any((row) => row.operationId == op)) return null;
    final a = request.arguments;
    final project = _positive(a, 'projectId');
    if (!_granted(request.scope, project, null, null, projectOnly: true)) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final id = op == 'createSnippet' ? null : _positive(a, 'snippetId');
    final fields = op == 'updateSnippetMetadata'
        ? _snippetFields(a['fields']) : const <String, Object?>{};
    final inputs = op == 'updateSnippetFiles'
        ? _snippetActions(a['actions']) : const <Map<String, Object?>>[];
    if (op == 'createSnippet') {
      _snippetTitle(a['title']);
      _snippetPath(_text(a, 'path'));
      _snippetContent(a['content']);
      if (a.containsKey('description') && a['description'] is! String) {
        throw const ApiFailure(FailureKind.validation);
      }
    }
    if (op == 'updateSnippet') _snippetEdits(a['edits']);
    if (op == 'deleteSnippetFile') _snippetPath(_text(a, 'path'));
    final desiredVisibility = op == 'createSnippet'
        ? a['visibility'] ?? 'private' : fields['visibility'];
    if (desiredVisibility != null &&
        (desiredVisibility is! String ||
            !snippetVisibilitiesForHost(_api.instance.base.host)
                .contains(desiredVisibility))) {
      throw const ApiFailure(FailureKind.validation);
    }
    final user = await _api.currentUser();
    if ('${_api.instance.key}#${user.id}' != accountKey) {
      throw const ApiFailure(FailureKind.unauthenticated);
    }
    final p = await _api.record(['projects', '$project']);
    if (p['id'] != project) throw const ApiFailure(FailureKind.invalidResponse);
    final projectPath = _responseText(p, 'path_with_namespace');
    final keyParts = [accountKey, 'project:$project', 'snippet',
      if (id != null) '$id'];
    final keys = {_key(keyParts)};
    final changedPaths = <String>[];
    final diffLines = <AiDiffLine>[];
    final beforeContents = <String, String>{};
    final afterContents = <String, String>{};
    final newTexts = <String>[];
    final windows = <AiTextWindow>[];
    var markdown = false;
    var original = '';
    String? confirmName;
    _SnippetRest? rest;
    var title = '';
    var description = '';
    var visibility = 'private';
    var paths = <String>[];
    Future<Object?> Function() mutation;
    Future<Object?> Function(Object?)? readback;
    AiCreatedRef? created;

    void preview(String path, String before, String after,
        {String? previousPath, AiExactEditApplied? edited}) {
      final diff = edited?.diff ?? unifiedDiff(before, after);
      changedPaths.add(path);
      diffLines.add(AiDiffLine(kind: AiDiffLineKind.hunk,
          text: previousPath == null ? path : '$previousPath → $path'));
      diffLines.addAll(diff);
      if (edited != null) {
        newTexts.addAll(edited.scan.newTexts);
        // Keep the engine-owned window identities and their changed offsets.
        windows.addAll(edited.scan.windows);
        original += edited.scan.original;
      } else if (before.isEmpty && after.isNotEmpty) {
        newTexts.add(after);
        windows.add(AiTextWindow(before: '', after: after));
      }
      markdown = markdown || isRenderedMarkdownPath(path);
    }

    if (op == 'createSnippet') {
      title = _snippetTitle(a['title']);
      description = a['description'] as String? ?? '';
      visibility = desiredVisibility! as String;
      final path = _text(a, 'path');
      final content = _snippetContent(a['content']);
      paths = [path];
      afterContents[path] = content;
      preview(path, '', content);
      confirmName = visibility != 'private' ? projectPath : null;
      mutation = () async {
        final result = await _api.createSnippet(project, title: title,
            description: description, visibility: visibility,
            files: [SnippetFileInput(path: path, content: content)]);
        final newId = _resultInt(result, 'id');
        created = AiCreatedRef(accountKey: accountKey, kind: AiTargetKind.snippet,
            projectId: project, id: newId);
        return result;
      };
      readback = (result) => _snippetReadback(project, _resultInt(result, 'id'),
          projectPath, title, description, visibility, paths, afterContents);
    } else {
      final snapshot = await _snippetRest(project, id!, projectPath);
      rest = snapshot;
      final before = snapshot.snippet;
      title = before.title;
      description = before.description;
      visibility = before.visibility;
      paths = [...before.filePaths];
      final affected = <String>{};
      if (op == 'updateSnippet') {
        if (!before.canUseLegacyRaw) _snippetRefuse('snippetFilesUnreadable');
        affected.add(before.fileName);
      } else if (op == 'deleteSnippetFile') {
        final path = _text(a, 'path');
        if (!paths.contains(path)) _snippetRefuse('snippetChanged');
        if (paths.length == 1) _snippetRefuse('snippetLastFile');
        affected.add(path);
        confirmName = path;
      } else if (op == 'deleteSnippet') {
        if (paths.length > 4) _snippetRefuse('snippetTooManyFiles');
        affected.addAll(paths);
        confirmName = '#${before.id}';
      } else if (op == 'updateSnippetFiles') {
        for (final input in inputs) {
          if (input['action'] == 'update') affected.add(input['file_path']! as String);
          if (input['action'] == 'move') affected.add(input['previous_path']! as String);
        }
      }
      for (final path in affected) {
        if (!paths.contains(path)) _snippetRefuse('snippetChanged');
        beforeContents[path] = await _snippetContentRead(project, id, snapshot, path,
            legacy: op == 'updateSnippet');
      }
      if (affected.isNotEmpty) {
        final fresh = await _snippetRest(project, id, projectPath);
        if (snapshot.digest != fresh.digest) _snippetRefuse('snippetChanged');
      }
      switch (op) {
        case 'updateSnippetMetadata':
          title = fields.containsKey('title') ? _snippetTitle(fields['title']) : title;
          description = fields['description'] as String? ?? description;
          visibility = desiredVisibility as String? ?? visibility;
          if (_snippetVisibility(visibility) > _snippetVisibility(before.visibility)) {
            confirmName = '#${before.id}';
          }
          mutation = () => _api.updateSnippetMetadata(project, id, title: title,
              description: description, visibility: visibility, currentPaths: paths);
        case 'updateSnippet':
          final path = before.fileName;
          final content = beforeContents[path]!;
          final edited = _snippetApply(content, a['edits']);
          final after = _snippetContent(edited.finalText);
          afterContents[path] = after;
          preview(path, content, after, edited: edited);
          mutation = () => _api.updateSnippet(project, id, before: before,
              title: title, description: description, visibility: visibility,
              fileName: path, content: after, previousContent: content);
        case 'updateSnippetFiles':
          final actions = <SnippetFileAction>[];
          final touched = <String>{};
          for (final input in inputs) {
            final path = input['file_path']! as String;
            final previous = input['previous_path'] as String?;
            final touches = {path, ?previous};
            if (touches.any(touched.contains)) _snippetRefuse('snippetPathInvalid');
            touched.addAll(touches);
            switch (input['action']) {
              case 'create':
                if (paths.contains(path)) _snippetRefuse('snippetChanged');
                final content = _snippetContent(input['content']);
                paths.add(path);
                afterContents[path] = content;
                preview(path, '', content);
                actions.add(SnippetFileAction.create(path: path, content: content));
              case 'update':
                final content = beforeContents[path]!;
                final edited = _snippetApply(content, input['edits']);
                final after = _snippetContent(edited.finalText);
                afterContents[path] = after;
                preview(path, content, after, edited: edited);
                actions.add(SnippetFileAction.update(path: path, content: after));
              case 'move':
                if (previous == path || paths.contains(path)) {
                  _snippetRefuse('snippetPathInvalid');
                }
                paths.remove(previous);
                paths.add(path);
                afterContents[path] = beforeContents[previous]!;
                preview(path, beforeContents[previous]!, beforeContents[previous]!,
                    previousPath: previous);
                actions.add(SnippetFileAction.move(previousPath: previous!, path: path));
            }
          }
          if (paths.length > 100) _snippetRefuse('snippetTooManyFiles');
          mutation = () => _api.updateSnippetFiles(project, id, title: title,
              description: description, visibility: visibility,
              currentPaths: before.filePaths, actions: actions);
        case 'deleteSnippetFile':
          final path = _text(a, 'path');
          paths.remove(path);
          preview(path, beforeContents[path]!, '');
          mutation = () => _api.deleteSnippetFile(project, id, title: title,
              description: description, visibility: visibility,
              currentPaths: before.filePaths, path: path);
        case 'deleteSnippet':
          mutation = () => _api.deleteSnippet(project, id);
        default:
          throw const ApiFailure(FailureKind.unsupported);
      }
      if (op != 'deleteSnippet') {
        readback = (_) => _snippetReadback(project, id, projectPath, title,
            description, visibility, paths, afterContents);
      }
    }
    final raised = rest != null &&
        _snippetVisibility(visibility) > _snippetVisibility(rest.snippet.visibility);
    if (op != 'deleteSnippet') {
      // The named PUTs also resend metadata from the server. Model-provided
      // fields have already passed write-text policy (including upload
      // restoration); unchanged metadata and paths still need a full scan.
      newTexts.addAll({...paths, ...beforeContents.keys});
      if (rest != null) {
        if (!fields.containsKey('title')) newTexts.add(title);
        if (!fields.containsKey('description')) newTexts.add(description);
      }
    }
    final projectVisibility = p['visibility'];
    return AiWritePrepared._(
      request: request,
      releaseName: projectPath,
      confirmName: confirmName,
      facts: AiTierFacts(newSnippetNotPrivate: op == 'createSnippet' &&
          visibility != 'private', visibilityRaised: raised),
      writeKeys: keys,
      dependencyKeys: const {},
      bindingTargets: [AiTargetRef(kind: AiTargetKind.snippet, projectId: project,
          projectPath: projectPath, iid: id,
          name: id == null ? title : '#$id')],
      bindingDigest: _snippetDigest([accountKey, op, project, id, projectPath,
        projectVisibility, rest?.digest,
        [for (final path in beforeContents.keys.toList()..sort())
          [path, _snippetDigest(beforeContents[path])]],
        title,
        // The approved payload digest is separate from the server baseline.
        if (op != 'updateSnippetMetadata') _snippetDigest(description),
        visibility, paths,
        [for (final path in afterContents.keys.toList()..sort())
          [path, _snippetDigest(afterContents[path])]]]),
      journal: AiJournalBindings(updatedAt: rest?.snippet.updatedAt),
      preview: op == 'deleteSnippet' || op == 'deleteSnippetFile'
          ? AiDeletePreview(targetName: confirmName!,
              path: op == 'deleteSnippetFile' ? confirmName : null,
              count: op == 'deleteSnippet' ? paths.length : 1)
          : op == 'updateSnippetMetadata'
              ? AiFieldsPreview({'title': title, 'description': description,
                  'visibility': visibility})
              : AiDiffPreview(path: changedPaths.join(', '),
                  ref: id == null ? projectPath : '#$id', lines: diffLines,
                  newFile: op == 'createSnippet'),
      textScan: newTexts.isEmpty && windows.isEmpty ? null
          : AiTextScan(newTexts: newTexts, windows: windows,
              original: original, markdown: markdown),
      owner: _owner,
      mutation: mutation,
      readback: readback,
      resolveCreatedOnSuccess: () => created,
      classify: _resultClassifier,
      projectPath: projectPath,
      projectVisibility: projectVisibility is String ? projectVisibility : null,
    );
  }

  Future<_SnippetRest> _snippetRest(int project, int id, String projectPath) async {
    final value = await _api.record(['projects', '$project', 'snippets', '$id']);
    if (value['id'] != id || value['project_id'] != project) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final files = value['files'];
    if (files is! List || files.isEmpty || files.length > 100) {
      _snippetRefuse('snippetFilesUnreadable');
    }
    final refs = <String, String>{};
    for (final file in files) {
      if (file is! Map<String, dynamic> || file['path'] is! String ||
          file['raw_url'] is! String) {
        _snippetRefuse('snippetFilesUnreadable');
      }
      final path = file['path']! as String;
      try {
        _snippetPath(path);
      } on AiWriteRefused {
        _snippetRefuse('snippetFilesUnreadable');
      }
      if (refs.containsKey(path)) _snippetRefuse('snippetFilesUnreadable');
      final uri = Uri.tryParse(file['raw_url']! as String);
      final List<String> prefix =
          _api.instance.projectWeb('$projectPath/-/snippets/$id/raw').pathSegments;
      if (uri == null || !_api.instance.sameOrigin(uri) || uri.hasQuery ||
          uri.hasFragment || uri.path.contains('\\') ||
          uri.pathSegments.any((s) => s == '.' || s == '..') ||
          uri.pathSegments.length <= prefix.length + 1 ||
          !_snippetPrefix(uri.pathSegments, prefix)) {
        _snippetRefuse('snippetFilesUnreadable');
      }
      final suffix = uri.pathSegments.skip(prefix.length).toList();
      if (suffix.first.isEmpty || suffix.first.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
          suffix.skip(1).join('/') != path) {
        _snippetRefuse('snippetFilesUnreadable');
      }
      refs[path] = suffix.first;
    }
    ProjectSnippet snippet;
    try {
      snippet = ProjectSnippet.fromJson(value);
    } on FormatException {
      _snippetRefuse('snippetFilesUnreadable');
    }
    if (snippet.title.trim().isEmpty || snippet.updatedAt.isEmpty ||
        DateTime.tryParse(snippet.updatedAt) == null ||
        _snippetVisibility(snippet.visibility) < 0 ||
        (value['description'] != null && value['description'] is! String)) {
      _snippetRefuse('snippetFilesUnreadable');
    }
    final ordered = refs.keys.toList()..sort();
    return (snippet: snippet, refs: refs, digest: _snippetDigest([
      project, id, snippet.updatedAt, snippet.visibility, snippet.title,
      snippet.description, snippet.fileName,
      [for (final path in ordered) [path, refs[path]]],
    ]));
  }

  Future<String> _snippetContentRead(int project, int id, _SnippetRest rest,
      String path, {bool legacy = false}) async {
    try {
      final ref = rest.refs[path];
      if (ref == null) _snippetRefuse('snippetChanged');
      return _snippetContent(legacy ? await _api.snippetText(project, id)
          : await _api.snippetText(project, id, ref: ref, filePath: path));
    } on ApiFailure catch (failure) {
      if (failure.kind == FailureKind.unsupported) _snippetRefuse('snippetBinary');
      if (failure.kind == FailureKind.tooLarge) _snippetRefuse('snippetTooLarge');
      if (failure.status == 404) _snippetRefuse('snippetChanged');
      rethrow;
    }
  }

  Future<bool> _snippetReadback(int project, int id, String projectPath,
      String title, String description, String visibility, List<String> paths,
      Map<String, String> contents) async {
    final rest = await _snippetRest(project, id, projectPath);
    final value = rest.snippet;
    if (value.title != title.trim() || value.description != description ||
        value.visibility != visibility || value.filePaths.length != paths.length ||
        !value.filePaths.toSet().containsAll(paths)) {
      _snippetRefuse('snippetChanged');
    }
    for (final entry in contents.entries) {
      if (await _snippetContentRead(project, id, rest, entry.key) != entry.value) {
        _snippetRefuse('snippetChanged');
      }
    }
    if (contents.isNotEmpty &&
        (await _snippetRest(project, id, projectPath)).digest != rest.digest) {
      _snippetRefuse('snippetChanged');
    }
    return true;
  }
}

typedef _SnippetRest = ({ProjectSnippet snippet, Map<String, String> refs, String digest});

Never _snippetRefuse(String reason) => throw AiWriteRefused(reason);

String _snippetDigest(Object? value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();

bool _snippetPrefix(List<String> value, List<String> prefix) {
  for (var i = 0; i < prefix.length; i++) {
    if (value[i] != prefix[i]) return false;
  }
  return true;
}

int _snippetVisibility(String value) => switch (value) {
  'private' => 0, 'internal' => 1, 'public' => 2, _ => -1,
};

String _snippetTitle(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const ApiFailure(FailureKind.validation);
  }
  return value.trim();
}

void _snippetPath(String path) {
  try {
    if (path != path.trim() || RegExp(r'[\x7f-\x9f]').hasMatch(path)) {
      _snippetRefuse('snippetPathInvalid');
    }
    validatedSnippetPath(path);
  } on ApiFailure {
    _snippetRefuse('snippetPathInvalid');
  }
}

String _snippetContent(Object? value) {
  if (value is! String) throw const ApiFailure(FailureKind.validation);
  if (value.contains('\u0000')) _snippetRefuse('snippetBinary');
  if (utf8.encode(value).length > 2 * 1024 * 1024 ||
      '\n'.allMatches(value).length + 1 > 20000) {
    _snippetRefuse('snippetTooLarge');
  }
  return value;
}

List<AiExactEdit> _snippetEdits(Object? value) {
  if (value is! List || value.isEmpty || value.length > 20) {
    throw const ApiFailure(FailureKind.validation);
  }
  return [for (final edit in value) () {
    if (edit is! Map<String, Object?> || edit.length != 2 ||
        edit['old'] is! String || edit['new'] is! String) {
      throw const ApiFailure(FailureKind.validation);
    }
    return AiExactEdit(edit['old']! as String, edit['new']! as String);
  }()];
}

AiExactEditApplied _snippetApply(String original, Object? edits) {
  final result = applyExactEdits(original, _snippetEdits(edits));
  if (result is AiExactEditRejected) _snippetRefuse(result.reasonCode);
  return result as AiExactEditApplied;
}

Map<String, Object?> _snippetFields(Object? value) {
  if (value is! Map<String, Object?> || value.isEmpty ||
      value.keys.any((k) => !const {'title', 'description', 'visibility'}.contains(k)) ||
      value.values.any((v) => v is! String)) {
    throw const ApiFailure(FailureKind.validation);
  }
  if (value.containsKey('title')) _snippetTitle(value['title']);
  return value;
}

List<Map<String, Object?>> _snippetActions(Object? value) {
  if (value is! List || value.isEmpty) throw const ApiFailure(FailureKind.validation);
  if (value.length > 2) _snippetRefuse('snippetTooManyFiles');
  return [for (final input in value) () {
    if (input is! Map<String, Object?> || input['action'] is! String ||
        input['file_path'] is! String) {
      throw const ApiFailure(FailureKind.validation);
    }
    final allowed = switch (input['action']) {
      'create' => {'action', 'file_path', 'content'},
      'update' => {'action', 'file_path', 'edits'},
      'move' => {'action', 'file_path', 'previous_path'},
      _ => throw const ApiFailure(FailureKind.validation),
    };
    if (input.length != allowed.length || !input.keys.every(allowed.contains)) {
      throw const ApiFailure(FailureKind.validation);
    }
    _snippetPath(input['file_path']! as String);
    if (input['action'] == 'create') _snippetContent(input['content']);
    if (input['action'] == 'update') _snippetEdits(input['edits']);
    if (input['action'] == 'move') {
      if (input['previous_path'] is! String) throw const ApiFailure(FailureKind.validation);
      _snippetPath(input['previous_path']! as String);
    }
    return input;
  }()];
}
