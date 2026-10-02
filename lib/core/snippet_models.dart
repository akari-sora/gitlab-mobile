import 'failure.dart';
import 'models.dart';

typedef SnippetJson = Map<String, dynamic>;

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
        final path =
            optionalString(raw, 'path') ?? optionalString(raw, 'file_path');
        if (path == null || path.trim().isEmpty || paths.contains(path)) {
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
      visibility: optionalString(json, 'visibility') ?? 'private',
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

Map<String, dynamic> createSnippetPayload({
  required String title,
  required String description,
  required String visibility,
  required List<SnippetFileInput> files,
}) {
  final cleanTitle = title.trim();
  if (cleanTitle.isEmpty ||
      !const {'private', 'internal', 'public'}.contains(visibility) ||
      files.isEmpty) {
    throw const ApiFailure(FailureKind.validation);
  }
  final paths = <String>{};
  final serialized = <Map<String, String>>[];
  for (final file in files) {
    final path = file.path.trim();
    if (path.isEmpty || path.startsWith('/') || !paths.add(path)) {
      throw const ApiFailure(FailureKind.validation);
    }
    serialized.add({'file_path': path, 'content': file.content});
  }
  return {
    'title': cleanTitle,
    'description': description,
    'visibility': visibility,
    'files': serialized,
  };
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
  return {
    'title': base['title'],
    'description': description,
    'visibility': visibility,
    if (renamed)
      'files': [
        {
          'action': 'move',
          'previous_path': before.fileName,
          'file_path': cleanName,
        },
      ]
    else if (changed)
      'files': [
        {'action': 'update', 'file_path': cleanName, 'content': content},
      ],
  };
}
