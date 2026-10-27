part of 'gitlab_write_port.dart';

/// Family implementation is delivered in a later packet; it cannot send yet.
extension _GroupAssigneesPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupAssignees(
    AiWriteRequest request,
  ) async => null;
}
