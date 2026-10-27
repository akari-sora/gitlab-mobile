part of 'gitlab_write_port.dart';

/// Family implementation is delivered in a later packet; it cannot send yet.
extension _GroupActivityDeletePrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupActivityDelete(
    AiWriteRequest request,
  ) async => null;
}
