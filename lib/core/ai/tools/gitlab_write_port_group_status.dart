part of 'gitlab_write_port.dart';

/// Family implementation is delivered in a later packet; it cannot send yet.
extension _GroupStatusPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupStatus(AiWriteRequest request) async =>
      null;
}
