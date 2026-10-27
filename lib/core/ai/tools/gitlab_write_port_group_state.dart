part of 'gitlab_write_port.dart';

/// Family implementation is delivered in a later packet; it cannot send yet.
extension _GroupStatePrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupState(AiWriteRequest request) async =>
      null;
}
