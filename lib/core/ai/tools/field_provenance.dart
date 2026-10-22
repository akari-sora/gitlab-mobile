import '../../instance.dart';
import '../write_text.dart';

/// Shared by project read tools and the write-side provenance handoff. These
/// keys match the existing text layer's project/resource identity convention;
/// account and conversation isolation belongs to the placeholder table owner.
abstract final class AiProjectFieldProvenance {
  static AiFieldProvenance releaseDescription({
    required GitLabInstance instance,
    required int projectId,
    required String? projectPath,
    required String tagName,
  }) => _description(
    instance: instance,
    projectId: projectId,
    projectPath: projectPath,
    resource: 'releases',
    kind: 'release',
    id: tagName,
    fieldName: AiWritableField.releaseDescription,
  );

  static AiFieldProvenance milestoneDescription({
    required GitLabInstance instance,
    required int projectId,
    required String? projectPath,
    required int milestoneId,
    required int milestoneIid,
  }) => _description(
    instance: instance,
    projectId: projectId,
    projectPath: projectPath,
    resource: 'milestones',
    kind: 'milestone',
    id: '$milestoneId',
    webId: '$milestoneIid',
    fieldName: AiWritableField.milestoneDescription,
  );

  static AiFieldProvenance snippetDescription({
    required GitLabInstance instance,
    required int projectId,
    required String? projectPath,
    required int snippetId,
  }) => _description(
    instance: instance,
    projectId: projectId,
    projectPath: projectPath,
    resource: 'snippets',
    kind: 'snippet',
    id: '$snippetId',
    fieldName: AiWritableField.snippetDescription,
  );
}

AiFieldProvenance _description({
  required GitLabInstance instance,
  required int projectId,
  required String? projectPath,
  required String resource,
  required String kind,
  required String id,
  required String fieldName,
  String? webId,
}) {
  final path = projectPath == null || projectPath.isEmpty ? null : projectPath;
  final collection = path == null
      ? null
      : instance.projectWeb('$path/-/$resource');
  return AiFieldProvenance(
    resourceKey: AiConflictKey('project:$projectId/$kind:$id'),
    fieldName: fieldName,
    completeValue: true,
    resourceWeb: collection?.replace(
      pathSegments: [...collection.pathSegments, webId ?? id],
    ),
    projectId: projectId,
    projectFullPath: path,
  );
}
