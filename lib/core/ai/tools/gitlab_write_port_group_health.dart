part of 'gitlab_write_port.dart';

/// Family implementation is delivered in a later packet; it cannot send yet.
extension _GroupHealthPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupHealth(AiWriteRequest request) async =>
      null;
}
