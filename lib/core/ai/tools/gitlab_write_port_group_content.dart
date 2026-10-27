part of 'gitlab_write_port.dart';

/// Family implementation is delivered in a later packet; it cannot send yet.
extension _GroupContentPrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGroupContent(AiWriteRequest request) async =>
      null;
}
