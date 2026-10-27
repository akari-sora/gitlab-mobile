part of 'gitlab_write_port.dart';

/// Family implementation is delivered in a later packet; it cannot send yet.
extension _GroupActivityCreatePrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupActivityCreate(
    AiWriteRequest request,
  ) async => null;
}
