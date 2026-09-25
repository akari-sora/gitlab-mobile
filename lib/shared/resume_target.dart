final class ResumeTarget {
  const ResumeTarget({
    this.projectId,
    this.projectPath,
    required this.resource,
    this.iid,
    this.path,
  });

  final int? projectId;
  final String? projectPath;
  final String resource;
  final int? iid;
  final String? path;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResumeTarget &&
          runtimeType == other.runtimeType &&
          projectId == other.projectId &&
          projectPath == other.projectPath &&
          resource == other.resource &&
          iid == other.iid &&
          path == other.path;

  @override
  int get hashCode => Object.hash(projectId, projectPath, resource, iid, path);

  @override
  String toString() =>
      'ResumeTarget(projectId: $projectId, projectPath: $projectPath, resource: $resource, iid: $iid, path: $path)';
}
