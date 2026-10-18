import 'package:dio/dio.dart';

import 'gitlab_api.dart';
import 'instance.dart';

/// Header names that carry a GitLab credential.
bool isCredentialHeader(String name) {
  final lower = name.toLowerCase();
  return lower == 'private-token' ||
      lower == 'job-token' ||
      lower == 'x-gitlab-token' ||
      lower == 'cookie' ||
      lower.endsWith('authorization');
}

/// A [GitLabApi] for public reads that never sends a credential, used for the
/// app's own update check. The client needs a token, so it gets a placeholder,
/// and an interceptor strips that and every other credential header from each
/// request. All of [GitLabApi]'s guards (same-origin API paths, byte budgets,
/// redirects, rate limits) still apply.
GitLabApi anonymousGitLabApi(GitLabInstance instance, {Dio? dio, HttpClientAdapter? cdnAdapter}) {
  final client = dio ?? Dio();
  client.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
    request.headers.removeWhere((name, _) => isCredentialHeader(name));
    handler.next(request);
  }));
  return GitLabApi(instance: instance, token: 'anonymous', dio: client, cdnAdapter: cdnAdapter);
}
