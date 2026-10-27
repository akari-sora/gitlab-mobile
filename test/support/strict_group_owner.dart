import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/group_work_item_identity.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

/// Creates the same verified identity that a strict namespace read would
/// deliver, using synthetic evidence belonging to this test API.
VerifiedGroupWorkItemIdentity strictGroupOwner(
  GitLabApi api,
  WorkItemGraphSummary summary,
) {
  final namespace = summary.namespace!;
  final groupId = groupKeyNumericId(namespace.id)!;
  return VerifiedGroupWorkItemIdentity.fromServerEvidence(
    instance: api.instance,
    expectedUserId: 7,
    actorUserId: 7,
    expectedGroupId: groupId,
    expectedFullPath: namespace.fullPath,
    expectedIid: summary.iid,
    namespace: {
      'id': namespace.id,
      'fullPath': namespace.fullPath,
      'workItem': {
        'id': summary.id,
        'iid': summary.iid,
        'project': null,
        'namespace': {'id': namespace.id, 'fullPath': namespace.fullPath},
      },
    },
    apiOwner: api,
    generation: 1,
    readEpoch: 0,
  )!;
}

WorkItemGraphDetail strictGroupDetail(
  GitLabApi api,
  WorkItemGraphDetail detail,
) {
  return detail.withStrictGroupOwner(strictGroupOwner(api, detail.summary));
}

/// Corrupts only the owner evidence on a synthetic Work Item response.
void corruptGroupOwner(Map<String, Object?> item, String problem) {
  switch (problem) {
    case 'missing':
      item.remove('project');
    case 'project':
      item['project'] = {
        'id': 'gid://gitlab/Project/42',
        'fullPath': 'foreign',
      };
    case 'namespace':
      item['namespace'] = {
        'id': 'gid://gitlab/Group/85',
        'fullPath': 'foreign',
      };
    case 'exact':
      break;
    default:
      throw ArgumentError.value(problem);
  }
}
