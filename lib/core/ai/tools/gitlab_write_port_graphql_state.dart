part of 'gitlab_write_port.dart';

extension _GraphqlStatePrepare on GitLabAiWritePort {
  Future<AiWritePrepared?> _prepareGraphqlState(AiWriteRequest request) =>
      Future<AiWritePrepared?>.value(null);
}
