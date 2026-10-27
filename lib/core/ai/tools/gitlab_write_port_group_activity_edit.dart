part of 'gitlab_write_port.dart';

/// Family implementation is delivered in a later packet; it cannot send yet.
extension _GroupActivityEditPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupActivityEdit(
    AiWriteRequest request,
  ) async => null;
}
