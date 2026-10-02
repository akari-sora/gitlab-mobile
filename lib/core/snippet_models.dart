import 'failure.dart';
import 'models.dart';

typedef SnippetJson = Map<String, dynamic>;

const _allSnippetVisibilities = ['private', 'internal', 'public'];
const _gitLabComSnippetVisibilities = ['private', 'public'];

List<String> snippetVisibilitiesForHost(String host) =>
    host.toLowerCase() == 'gitlab.com'
    ? _gitLabComSnippetVisibilities
    : _allSnippetVisibilities;

String snippetVisibilityLabel(String value) => switch (value) {
  'private' => '私人',
  'internal' => '內部',
  'public' => '公開',
  _ => value,
};

final class ProjectSnippet {
  const ProjectSnippet({
    required this.id,
    required this.projectId,
    required this.title,
    required this.description,
    required this.fileName,
    required this.updatedAt,
    required this.visibility,
    required this.authorName,
    required this.filePaths,
    required this.hasExplicitFiles,
  });

  factory ProjectSnippet.fromJson(SnippetJson json) {
    final author = json['author'];
    final files = json['files'];
    if (files != null && files is! List) {
      throw const FormatException('Invalid snippet files');
    }
    final paths = <String>[];
    if (files is List) {
      for (final raw in files) {
        if (raw is! SnippetJson) {
          throw const FormatException('Invalid snippet file');
        }
        final rawPath =
            optionalString(raw, 'path') ?? optionalString(raw, 'file_path');
        if (rawPath == null) {
          throw const FormatException('Invalid snippet file path');
        }
        final path = _snippetPath(rawPath, serverResponse: true);
        if (paths.contains(path)) {
          throw const FormatException('Invalid snippet file path');
        }
        paths.add(path);
      }
    }
    final fileName = optionalString(json, 'file_name')?.trim() ?? '';
    return ProjectSnippet(
      id: requiredInt(json, 'id'),
      projectId: requiredInt(json, 'project_id'),
      title: requiredString(json, 'title'),
      description: optionalString(json, 'description') ?? '',
      fileName: fileName,
      updatedAt: requiredString(json, 'updated_at'),
      visibility: requiredString(json, 'visibility'),
      authorName: author is SnippetJson
          ? optionalString(author, 'name') ??
                optionalString(author, 'username') ??
                '未知作者'
          : '未知作者',
      filePaths: List.unmodifiable(paths),
      hasExplicitFiles: files != null,
    );
  }

  final int id;
  final int projectId;
  final String title;
  final String description;
  final String fileName;
  final String updatedAt;
  final String visibility;
  final String authorName;
  final List<String> filePaths;
  final bool hasExplicitFiles;

  bool get canUseLegacyRaw {
    if (!hasExplicitFiles) return false;
    return filePaths.length == 1 &&
        fileName.isNotEmpty &&
        filePaths.single == fileName;
  }

  void requireProject(int expectedProjectId) {
    if (projectId != expectedProjectId) {
      throw const ApiFailure(
        FailureKind.invalidResponse,
        title: 'Snippet 專案身分不一致',
        detail: '伺服器回傳了其他專案的 Snippet，已停止顯示與寫入。',
      );
    }
  }
}

final class SnippetFileInput {
  const SnippetFileInput({required this.path, required this.content});
  final String path;
  final String content;
}

enum SnippetFileActionType { create, update, delete, move }

/// One documented project-Snippet file action. A move deliberately has no
/// content field: GitLab models moving and updating as separate operations.
final class SnippetFileAction {
  const SnippetFileAction.create({required this.path, required this.content})
    : type = SnippetFileActionType.create,
      previousPath = null;

  const SnippetFileAction.update({required this.path, required this.content})
    : type = SnippetFileActionType.update,
      previousPath = null;

  const SnippetFileAction.delete({required this.path})
    : type = SnippetFileActionType.delete,
      previousPath = null,
      content = null;

  const SnippetFileAction.move({required this.previousPath, required this.path})
    : type = SnippetFileActionType.move,
      content = null;

  final SnippetFileActionType type;
  final String path;
  final String? previousPath;
  final String? content;
}

String validatedSnippetPath(String raw) {
  return _snippetPath(raw, serverResponse: false);
}

String _snippetPath(String raw, {required bool serverResponse}) {
  final path = raw.trim();
  if (path.isEmpty ||
      (serverResponse && path != raw) ||
      path.length > 1024 ||
      path.startsWith('/') ||
      path.endsWith('/') ||
      path.contains('\\') ||
      path.contains('//') ||
      path.runes.any((value) => value < 0x20 || value == 0x7f) ||
      path.split('/').any((segment) => segment == '.' || segment == '..')) {
    if (serverResponse) {
      throw const FormatException('Invalid snippet file path');
    }
    throw const ApiFailure(FailureKind.validation);
  }
  return path;
}

Map<String, dynamic> _snippetMetadataPayload({
  required String title,
  required String description,
  required String visibility,
}) {
  final cleanTitle = title.trim();
  if (cleanTitle.isEmpty ||
      !const {'private', 'internal', 'public'}.contains(visibility)) {
    throw const ApiFailure(FailureKind.validation);
  }
  return {
    'title': cleanTitle,
    'description': description,
    'visibility': visibility,
  };
}

Map<String, dynamic> createSnippetPayload({
  required String title,
  required String description,
  required String visibility,
  required List<SnippetFileInput> files,
}) {
  final payload = _snippetMetadataPayload(
    title: title,
    description: description,
    visibility: visibility,
  );
  if (files.isEmpty || files.length > 100) {
    throw const ApiFailure(FailureKind.validation);
  }
  final paths = <String>{};
  final serialized = <Map<String, String>>[];
  for (final file in files) {
    final path = validatedSnippetPath(file.path);
    if (!paths.add(path)) {
      throw const ApiFailure(FailureKind.validation);
    }
    serialized.add({'file_path': path, 'content': file.content});
  }
  return {...payload, 'files': serialized};
}

/// Builds a documented multi-file update while validating the complete file
/// set locally. Metadata-only updates intentionally omit `files`.
Map<String, dynamic> updateSnippetPayload({
  required String title,
  required String description,
  required String visibility,
  required List<String> currentPaths,
  required List<SnippetFileAction> actions,
}) {
  final payload = _snippetMetadataPayload(
    title: title,
    description: description,
    visibility: visibility,
  );
  if (currentPaths.isEmpty ||
      currentPaths.length > 100 ||
      actions.length > 100) {
    throw const ApiFailure(FailureKind.validation);
  }
  final paths = <String>{};
  for (final raw in currentPaths) {
    if (!paths.add(validatedSnippetPath(raw))) {
      throw const ApiFailure(FailureKind.validation);
    }
  }
  final touched = <String>{};
  final serialized = <Map<String, String>>[];
  for (final action in actions) {
    final path = validatedSnippetPath(action.path);
    final previous = action.previousPath == null
        ? null
        : validatedSnippetPath(action.previousPath!);
    final touches = <String>{path};
    if (previous != null) touches.add(previous);
    if (touches.any(touched.contains)) {
      throw const ApiFailure(
        FailureKind.validation,
        title: '請分開修改同一個檔案',
        detail: '同一次儲存不可同時移動並更新同一個檔案。',
      );
    }
    touched.addAll(touches);
    switch (action.type) {
      case SnippetFileActionType.create:
        if (paths.contains(path) ||
            action.content == null ||
            previous != null) {
          throw const ApiFailure(FailureKind.validation);
        }
        paths.add(path);
        serialized.add({
          'action': 'create',
          'file_path': path,
          'content': action.content!,
        });
      case SnippetFileActionType.update:
        if (!paths.contains(path) ||
            action.content == null ||
            previous != null) {
          throw const ApiFailure(FailureKind.validation);
        }
        serialized.add({
          'action': 'update',
          'file_path': path,
          'content': action.content!,
        });
      case SnippetFileActionType.delete:
        if (!paths.remove(path) || action.content != null || previous != null) {
          throw const ApiFailure(FailureKind.validation);
        }
        serialized.add({'action': 'delete', 'file_path': path});
      case SnippetFileActionType.move:
        if (previous == null ||
            previous == path ||
            action.content != null ||
            !paths.remove(previous) ||
            paths.contains(path)) {
          throw const ApiFailure(FailureKind.validation);
        }
        paths.add(path);
        serialized.add({
          'action': 'move',
          'previous_path': previous,
          'file_path': path,
        });
    }
  }
  if (paths.isEmpty) throw const ApiFailure(FailureKind.validation);
  return {...payload, if (serialized.isNotEmpty) 'files': serialized};
}

Map<String, dynamic> updateSingleFileSnippetPayload({
  required ProjectSnippet before,
  required String title,
  required String description,
  required String visibility,
  required String fileName,
  required String content,
  required String previousContent,
}) {
  if (!before.canUseLegacyRaw) {
    throw const ApiFailure(FailureKind.validation);
  }
  final base = createSnippetPayload(
    title: title,
    description: description,
    visibility: visibility,
    files: [SnippetFileInput(path: fileName, content: content)],
  );
  final cleanName = fileName.trim();
  final renamed = cleanName != before.fileName;
  final changed = content != previousContent;
  if (renamed && changed) {
    throw const ApiFailure(
      FailureKind.validation,
      title: '請分兩次修改檔名與內容',
      detail: 'GitLab 將移動檔案與更新內容定義成不同動作。先儲存其中一項，再修改另一項。',
    );
  }
  return updateSnippetPayload(
    title: base['title'] as String,
    description: description,
    visibility: visibility,
    currentPaths: before.filePaths,
    actions: [
      if (renamed)
        SnippetFileAction.move(previousPath: before.fileName, path: cleanName)
      else if (changed)
        SnippetFileAction.update(path: cleanName, content: content),
    ],
  );
}
