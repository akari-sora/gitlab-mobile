part of 'gitlab_write_port.dart';

/// Family implementation is delivered in a later packet; it cannot send yet.
extension _GroupMilestoneWeightPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupMilestoneWeight(
    AiWriteRequest request,
  ) async => null;
}
