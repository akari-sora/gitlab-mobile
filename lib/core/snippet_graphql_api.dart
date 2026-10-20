part of 'gitlab_api.dart';

enum SnippetBlobAvailability {
  text,
  nullContent,
  binary,
  tooLarge,
  unretrievable,
  renderError,
}

/// A project-bound GraphQL identity discovered from the server. [graphId] is
/// opaque and cannot be reconstructed by callers from [snippetId].
final class SnippetGraphSnapshot {
  const SnippetGraphSnapshot._({
    required this.snippet,
    required this.projectPath,
    required this.graphId,
    required this.graphUpdatedAt,
  });

  final ProjectSnippet snippet;
  final String projectPath;
  final String graphId;
  final DateTime graphUpdatedAt;

  int get projectId => snippet.projectId;
  int get snippetId => snippet.id;
  String get restUpdatedAt => snippet.updatedAt;
  List<String> get filePaths => snippet.filePaths;
}

/// Raw source for one explicitly requested, REST-enumerated path. No rendered
/// HTML is accepted or exposed by this contract.
final class SnippetBlob {
  const SnippetBlob._({
    required this.path,
    required this.name,
    required this.rawPath,
    required this.size,
    required this.content,
    required this.binary,
    required this.renderedAsText,
    required this.tooLarge,
    required this.unretrievable,
    required this.hasUnretrievableBlobs,
    required this.renderError,
    required this.availability,
  });

  final String path;
  final String? name;
  final String? rawPath;
  final int? size;
  final String? content;
  final bool binary;
  final bool renderedAsText;
  final bool tooLarge;

  /// True only when this explicitly requested path had no retrievable node.
  final bool unretrievable;

  /// Snippet-level aggregate reported by GitLab; other blobs may be affected.
  final bool hasUnretrievableBlobs;
  final String? renderError;
  final SnippetBlobAvailability availability;
}

const _projectSnippetsQuery = r'''
query MobileProjectSnippets($projectId: ProjectID!, $first: Int!, $after: String) {
  snippets(projectId: $projectId, first: $first, after: $after) {
    nodes { id project { id fullPath } updatedAt }
    pageInfo { hasNextPage endCursor }
  }
}
''';

const _snippetBlobQuery = r'''
query MobileSnippetBlob($ids: [SnippetID!], $paths: [String!]) {
  snippets(ids: $ids) {
    nodes {
      id
      project { id fullPath }
      updatedAt
      blobs(paths: $paths) {
        hasUnretrievableBlobs
        nodes {
          binary
          name
          path
          rawPath
          size
          rawPlainData
          renderedAsText
          simpleViewer { tooLarge renderError }
        }
      }
    }
  }
}
''';

const _snippetSchemaErrors = {
  'undefinedField',
  'undefinedArgument',
  'variableRequiresValidType',
  'argumentLiteralsIncompatible',
  'missingRequiredArguments',
};
const _maximumSnippetLookupPages = 20;
const _maximumSnippetLookupRows = 2000;
const _maximumSnippetPageRows = 100;

ApiFailure get _snippetConflict => ApiFailure(
  FailureKind.conflict,
  title: l10n.snippetHasChanged,
  detail: l10n.snippetVersionUpdatedReload,
);

void _validateSnippetProject(Project project) {
  if (project.id <= 0 || project.path.trim().isEmpty) {
    throw const ApiFailure(FailureKind.validation);
  }
}

DateTime _snippetGraphDate(Object? raw) {
  if (raw is! String) throw const FormatException('Invalid snippet date');
  final parts = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(raw);
  if (parts == null) {
    throw const FormatException('Invalid snippet date');
  }
  final localFields = DateTime.utc(
    int.parse(parts.group(1)!),
    int.parse(parts.group(2)!),
    int.parse(parts.group(3)!),
    int.parse(parts.group(4)!),
    int.parse(parts.group(5)!),
    int.parse(parts.group(6)!),
  );
  if (localFields.year != int.parse(parts.group(1)!) ||
      localFields.month != int.parse(parts.group(2)!) ||
      localFields.day != int.parse(parts.group(3)!) ||
      localFields.hour != int.parse(parts.group(4)!) ||
      localFields.minute != int.parse(parts.group(5)!) ||
      localFields.second != int.parse(parts.group(6)!)) {
    throw const FormatException('Invalid snippet date');
  }
  final value = DateTime.tryParse(raw);
  if (value == null) throw const FormatException('Invalid snippet date');
  return value.toUtc();
}

bool _snippetVersionsShareSecond(
  String restUpdatedAt,
  DateTime graphUpdatedAt,
) {
  try {
    return _snippetGraphDate(restUpdatedAt).microsecondsSinceEpoch ~/
            Duration.microsecondsPerSecond ==
        graphUpdatedAt.toUtc().microsecondsSinceEpoch ~/
            Duration.microsecondsPerSecond;
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

Json _snippetGraphData(Uint8List bytes) {
  try {
    final envelope = objectJson(jsonDecode(utf8.decode(bytes)));
    final errors = envelope['errors'];
    if (errors != null) {
      if (errors is! List) throw const ApiFailure(FailureKind.invalidResponse);
      if (errors.isNotEmpty) {
        final unsupported = errors.every(
          (error) =>
              error is Map &&
              error['extensions'] is Map &&
              _snippetSchemaErrors.contains(
                (error['extensions'] as Map)['code'],
              ),
        );
        throw ApiFailure(
          unsupported ? FailureKind.unsupported : FailureKind.invalidResponse,
          title: unsupported ? l10n.instanceNoMultiFileSnippet : null,
          detail: unsupported ? l10n.singleFileSnippetPreviewOk : null,
        );
      }
    }
    return objectJson(envelope['data']);
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

Future<ProjectSnippet> _freshSnippet(
  GitLabApi api,
  Project project,
  int snippetId,
) async {
  try {
    final value = ProjectSnippet.fromJson(
      await api._object(
        api.instance.api([
          'projects',
          '${project.id}',
          'snippets',
          '$snippetId',
        ]),
      ),
    );
    value.requireProject(project.id);
    if (value.id != snippetId) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    return value;
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

bool _sameSnippetRestVersion(ProjectSnippet left, ProjectSnippet right) =>
    left.id == right.id &&
    left.projectId == right.projectId &&
    left.updatedAt == right.updatedAt &&
    _sameSnippetPaths(left.filePaths, right.filePaths);

bool _sameSnippetPaths(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

({String graphId, DateTime graphUpdatedAt}) _snippetGraphIdentity(
  Object? raw,
  Project project,
  int snippetId,
) {
  final node = objectJson(raw);
  final graphId = requiredString(node, 'id');
  final match = RegExp(
    r'^gid://gitlab/ProjectSnippet/([1-9][0-9]*)$',
  ).firstMatch(graphId);
  if (match == null || int.tryParse(match.group(1)!) != snippetId) {
    throw const FormatException('Invalid snippet identity');
  }
  final remoteProject = objectJson(node['project']);
  if (remoteProject['id'] != 'gid://gitlab/Project/${project.id}' ||
      remoteProject['fullPath'] != project.path) {
    throw const FormatException('Invalid snippet project');
  }
  return (
    graphId: graphId,
    graphUpdatedAt: _snippetGraphDate(node['updatedAt']),
  );
}

extension SnippetGraphQlApi on GitLabApi {
  /// Resolves the server-owned opaque GraphQL ID within the numeric project.
  /// The REST and GraphQL timestamps are intentionally stored separately
  /// because GitLab exposes them at different precision.
  Future<SnippetGraphSnapshot> projectSnippetSnapshot(
    Project project,
    ProjectSnippet snippet,
  ) async {
    _validateSnippetProject(project);
    if (snippet.id <= 0 ||
        snippet.projectId != project.id ||
        !snippet.hasExplicitFiles ||
        snippet.filePaths.isEmpty) {
      throw const ApiFailure(FailureKind.validation);
    }
    final before = await _freshSnippet(this, project, snippet.id);
    if (!_sameSnippetRestVersion(before, snippet)) throw _snippetConflict;

    String? after;
    final seenCursors = <String>{};
    var rows = 0;
    ({String graphId, DateTime graphUpdatedAt})? identity;
    for (var page = 0; page < _maximumSnippetLookupPages; page++) {
      final response = await _read(
        instance.graphQL,
        method: 'POST',
        graphQuery: true,
        data: {
          'query': _projectSnippetsQuery,
          'variables': {
            'projectId': 'gid://gitlab/Project/${project.id}',
            'first': _maximumSnippetPageRows,
            'after': after,
          },
        },
      );
      try {
        final data = _snippetGraphData(response.bytes);
        if (data['snippets'] == null) {
          throw const ApiFailure(FailureKind.forbidden);
        }
        final connection = objectJson(data['snippets']);
        final nodes = connection['nodes'];
        if (nodes is! List || nodes.length > _maximumSnippetPageRows) {
          throw const FormatException('Invalid snippet page');
        }
        rows += nodes.length;
        if (rows > _maximumSnippetLookupRows) {
          throw const ApiFailure(FailureKind.tooLarge);
        }
        for (final raw in nodes) {
          final node = objectJson(raw);
          final rawId = node['id'];
          final match = rawId is String
              ? RegExp(
                  r'^gid://gitlab/ProjectSnippet/([1-9][0-9]*)$',
                ).firstMatch(rawId)
              : null;
          if (match == null) {
            throw const FormatException('Invalid snippet identity');
          }
          final numericId = int.tryParse(match.group(1)!);
          if (numericId == null) {
            throw const FormatException('Invalid snippet identity');
          }
          final candidate = _snippetGraphIdentity(node, project, numericId);
          if (numericId != snippet.id) continue;
          if (identity != null) {
            throw const FormatException('Duplicate snippet identity');
          }
          identity = candidate;
        }
        final pageInfo = objectJson(connection['pageInfo']);
        final hasNext = pageInfo['hasNextPage'];
        if (hasNext is! bool) {
          throw const FormatException('Invalid snippet page info');
        }
        if (identity != null || !hasNext) break;
        final cursor = pageInfo['endCursor'];
        if (cursor is! String ||
            cursor.isEmpty ||
            cursor.length > 4096 ||
            !seenCursors.add(cursor)) {
          throw const FormatException('Invalid snippet cursor');
        }
        after = cursor;
        if (page + 1 == _maximumSnippetLookupPages) {
          throw const ApiFailure(FailureKind.tooLarge);
        }
      } on FormatException {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
    }
    final resolved = identity;
    if (resolved == null) throw const ApiFailure(FailureKind.invisible);
    if (!_snippetVersionsShareSecond(
      before.updatedAt,
      resolved.graphUpdatedAt,
    )) {
      throw _snippetConflict;
    }
    final current = await _freshSnippet(this, project, snippet.id);
    if (!_sameSnippetRestVersion(before, current)) throw _snippetConflict;
    return SnippetGraphSnapshot._(
      snippet: current,
      projectPath: project.path,
      graphId: resolved.graphId,
      graphUpdatedAt: resolved.graphUpdatedAt,
    );
  }

  /// Lazily reads exactly one path already bound into [snapshot]. Fresh REST
  /// metadata before and after the query prevents stale content from becoming
  /// active when the snippet changes during the request.
  Future<SnippetBlob> snippetBlob(
    Project project,
    SnippetGraphSnapshot snapshot, {
    required String path,
  }) async {
    _validateSnippetProject(project);
    final selectedPath = validatedSnippetPath(path);
    if (snapshot.projectId != project.id ||
        snapshot.projectPath != project.path ||
        !snapshot.filePaths.contains(selectedPath) ||
        !RegExp(
          r'^gid://gitlab/ProjectSnippet/[1-9][0-9]*$',
        ).hasMatch(snapshot.graphId)) {
      throw const ApiFailure(FailureKind.validation);
    }
    final before = await _freshSnippet(this, project, snapshot.snippetId);
    if (!_sameSnippetRestVersion(before, snapshot.snippet)) {
      throw _snippetConflict;
    }
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _snippetBlobQuery,
        'variables': {
          'ids': [snapshot.graphId],
          'paths': [selectedPath],
        },
      },
    );
    late final SnippetBlob blob;
    try {
      final data = _snippetGraphData(response.bytes);
      if (data['snippets'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final connection = objectJson(data['snippets']);
      final nodes = connection['nodes'];
      if (nodes is! List || nodes.length != 1) {
        throw const FormatException('Invalid snippet result');
      }
      final node = objectJson(nodes.single);
      final identity = _snippetGraphIdentity(node, project, snapshot.snippetId);
      if (identity.graphId != snapshot.graphId ||
          identity.graphUpdatedAt != snapshot.graphUpdatedAt) {
        throw _snippetConflict;
      }
      if (node['blobs'] == null) {
        throw const ApiFailure(FailureKind.forbidden);
      }
      final blobs = objectJson(node['blobs']);
      final unretrievable = blobs['hasUnretrievableBlobs'];
      final blobNodes = blobs['nodes'];
      if (unretrievable is! bool ||
          blobNodes is! List ||
          blobNodes.length > 1) {
        throw const FormatException('Invalid snippet blobs');
      }
      if (blobNodes.isEmpty) {
        if (!unretrievable) {
          throw const FormatException('Missing requested snippet blob');
        }
        blob = SnippetBlob._(
          path: selectedPath,
          name: null,
          rawPath: null,
          size: null,
          content: null,
          binary: false,
          renderedAsText: false,
          tooLarge: false,
          unretrievable: true,
          hasUnretrievableBlobs: true,
          renderError: null,
          availability: SnippetBlobAvailability.unretrievable,
        );
      } else {
        blob = _parseSnippetBlob(
          blobNodes.single,
          selectedPath,
          hasUnretrievableBlobs: unretrievable,
        );
      }
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    final current = await _freshSnippet(this, project, snapshot.snippetId);
    if (!_sameSnippetRestVersion(before, current)) throw _snippetConflict;
    return blob;
  }
}

SnippetBlob _parseSnippetBlob(
  Object? raw,
  String expectedPath, {
  required bool hasUnretrievableBlobs,
}) {
  final node = objectJson(raw);
  final path = requiredString(node, 'path');
  final name = requiredString(node, 'name');
  final rawPath = node['rawPath'];
  final binary = node['binary'];
  final renderedAsText = node['renderedAsText'];
  if (path != expectedPath ||
      name.length > 1024 ||
      rawPath is! String ||
      rawPath.length > 8192 ||
      binary is! bool ||
      renderedAsText is! bool) {
    throw const FormatException('Invalid snippet blob');
  }
  final size = _snippetBlobSize(node['size']);
  final viewer = objectJson(node['simpleViewer']);
  final serverTooLarge = viewer['tooLarge'];
  if (serverTooLarge is! bool) {
    throw const FormatException('Invalid snippet viewer');
  }
  final rawRenderError = viewer['renderError'];
  if (rawRenderError != null && rawRenderError is! String) {
    throw const FormatException('Invalid snippet render error');
  }
  final renderError = rawRenderError is String && rawRenderError.isNotEmpty
      ? rawRenderError
      : null;
  if (renderError != null && renderError.length > 4096) {
    throw const FormatException('Invalid snippet render error');
  }
  final rawContent = node['rawPlainData'];
  if (rawContent != null && rawContent is! String) {
    throw const FormatException('Invalid snippet content');
  }
  var localTooLarge = false;
  if (rawContent is String) {
    localTooLarge =
        utf8.encode(rawContent).length > GitLabApi.maxTextBytes ||
        '\n'.allMatches(rawContent).length + 1 > GitLabApi.maxTextLines;
    if (!binary && rawContent.contains('\u0000')) {
      throw const FormatException('Invalid text snippet content');
    }
  }
  final tooLarge = serverTooLarge || localTooLarge;
  final availability = binary
      ? SnippetBlobAvailability.binary
      : tooLarge
      ? SnippetBlobAvailability.tooLarge
      : renderError != null
      ? SnippetBlobAvailability.renderError
      : rawContent == null
      ? SnippetBlobAvailability.nullContent
      : SnippetBlobAvailability.text;
  return SnippetBlob._(
    path: path,
    name: name,
    rawPath: rawPath,
    size: size,
    content: availability == SnippetBlobAvailability.text
        ? rawContent as String
        : null,
    binary: binary,
    renderedAsText: renderedAsText,
    tooLarge: tooLarge,
    unretrievable: false,
    hasUnretrievableBlobs: hasUnretrievableBlobs,
    renderError: renderError,
    availability: availability,
  );
}

int _snippetBlobSize(Object? raw) {
  final int value;
  if (raw is int) {
    value = raw;
  } else if (raw is String &&
      raw.length <= 19 &&
      RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(raw)) {
    value = int.parse(raw);
  } else {
    throw const FormatException('Invalid snippet size');
  }
  if (value < 0) throw const FormatException('Invalid snippet size');
  return value;
}
