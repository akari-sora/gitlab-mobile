import 'instance.dart';

/// Only an exact, positive, representable Group GID identifies a group.
int? groupKeyNumericId(String gid) => _gidNumericId(gid, 'Group');

/// Encodes a numeric grant only when matching server Group evidence exists.
/// A bare numeric Work Item ID cannot be converted into a Group GID.
String? groupKeyGid(int groupId, {required String serverGroupGid}) {
  return groupKeyNumericId(serverGroupGid) == groupId
      ? 'gid://gitlab/Group/$groupId'
      : null;
}

int? _gidNumericId(String gid, String type) {
  final prefix = 'gid://gitlab/$type/';
  if (!gid.startsWith(prefix)) return null;
  return _positiveId(gid.substring(prefix.length));
}

int? _positiveId(Object? value) {
  if (value is int) return value > 0 ? value : null;
  if (value is! String) return null;
  final match = RegExp(r'[1-9][0-9]*').matchAsPrefix(value);
  if (match == null || match.end != value.length) return null;
  final number = int.tryParse(value);
  return number != null && number > 0 && '$number' == value ? number : null;
}

bool _validFullPath(String path) =>
    path.isNotEmpty &&
    !RegExp(r'[\s\x00-\x20\x7f\\%?#]').hasMatch(path) &&
    path
        .split('/')
        .every((part) => part.isNotEmpty && part != '.' && part != '..');

/// Immutable evidence of one directly Group-owned Work Item.
///
/// Only the trusted API read boundary may call [fromServerEvidence], using
/// the raw namespace node and actor from server reads, with the captured API,
/// generation and read epoch. Model arguments and restored display models are
/// not server evidence. There is no scalar or "verified" flag constructor.
/// Consumers must check [isCurrent] before reusing an asynchronous read.
final class VerifiedGroupWorkItemIdentity {
  const VerifiedGroupWorkItemIdentity._({
    required this.instance,
    required this.userId,
    required this.groupId,
    required this.groupGid,
    required this.fullPath,
    required this.iid,
    required this.workItemGid,
    required this.apiOwner,
    required this.generation,
    required this.readEpoch,
  });

  /// Validates the raw `namespace(fullPath) { id fullPath workItem(iid) }`
  /// response against app-owned account/grant coordinates. Missing `project`
  /// cannot be substituted for the explicit null required for a group item.
  static VerifiedGroupWorkItemIdentity? fromServerEvidence({
    required GitLabInstance instance,
    required int expectedUserId,
    required int actorUserId,
    required int expectedGroupId,
    required String expectedFullPath,
    required int expectedIid,
    required Map<String, Object?> namespace,
    required Object apiOwner,
    required int generation,
    required int readEpoch,
  }) {
    if (_positiveId(expectedUserId) == null ||
        actorUserId != expectedUserId ||
        _positiveId(expectedGroupId) == null ||
        _positiveId(expectedIid) == null ||
        !_validFullPath(expectedFullPath) ||
        generation < 0 ||
        readEpoch < 0) {
      return null;
    }
    final groupGid = namespace['id'];
    if (groupGid is! String ||
        groupKeyGid(expectedGroupId, serverGroupGid: groupGid) == null ||
        namespace['fullPath'] != expectedFullPath) {
      return null;
    }
    final item = namespace['workItem'];
    if (item is! Map<String, Object?> ||
        !item.containsKey('project') ||
        item['project'] != null ||
        _positiveId(item['iid']) != expectedIid) {
      return null;
    }
    final workItemGid = item['id'];
    final owner = item['namespace'];
    if (workItemGid is! String ||
        _gidNumericId(workItemGid, 'WorkItem') == null ||
        owner is! Map<String, Object?> ||
        owner['id'] != groupGid ||
        owner['fullPath'] != expectedFullPath) {
      return null;
    }
    return VerifiedGroupWorkItemIdentity._(
      instance: instance,
      userId: expectedUserId,
      groupId: expectedGroupId,
      groupGid: groupGid,
      fullPath: expectedFullPath,
      iid: expectedIid,
      workItemGid: workItemGid,
      apiOwner: apiOwner,
      generation: generation,
      readEpoch: readEpoch,
    );
  }

  final GitLabInstance instance;
  final int userId;
  final int groupId;
  final String groupGid;
  final String fullPath;
  final int iid;
  final String workItemGid;
  final Object apiOwner;
  final int generation;
  final int readEpoch;

  String get accountKey => '${instance.key}#$userId';

  /// Shared components for journal keys; paths and WI GIDs are not owners.
  List<String> get keyParts => List<String>.unmodifiable([
    accountKey,
    'group:$groupId',
    'workItem',
    '$iid',
  ]);

  /// The scope/provenance spelling of the same numeric resource identity.
  String get canonicalKey => '($accountKey, group:$groupId, workItem, $iid)';

  /// Note and DiscussionNote GIDs are aliases of the same numeric note.
  /// Neither a WorkItem nor a Group GID can be used as a note alias.
  String? canonicalNoteKey({int? noteId, String? noteGid}) {
    final fromGid = noteGid == null
        ? null
        : _gidNumericId(noteGid, 'Note') ??
              _gidNumericId(noteGid, 'DiscussionNote');
    if ((noteGid != null && fromGid == null) ||
        (noteId != null && _positiveId(noteId) == null) ||
        (noteId != null && fromGid != null && noteId != fromGid)) {
      return null;
    }
    final number = noteId ?? fromGid;
    return number == null ? null : '$canonicalKey/note:$number';
  }

  bool isCurrent({
    required String accountKey,
    required Object apiOwner,
    required int generation,
    required int readEpoch,
  }) =>
      accountKey == this.accountKey &&
      identical(apiOwner, this.apiOwner) &&
      generation == this.generation &&
      readEpoch == this.readEpoch;
}
