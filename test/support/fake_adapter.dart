import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

typedef Responder = FutureOr<ResponseBody> Function(RequestOptions request);

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.respond);
  final Responder respond;
  final List<RequestOptions> requests = [];
  final List<Future<void>?> cancelFutures = [];
  bool closed = false;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    requests.add(options);
    cancelFutures.add(cancelFuture);
    return await respond(options);
  }
  @override
  void close({bool force = false}) { closed = true; }
}

ResponseBody jsonResponse(Object? value, {int status = 200, Map<String, List<String>> headers = const {}}) =>
    ResponseBody.fromString(jsonEncode(value), status,
      headers: {'content-type': ['application/json'], ...headers});

GitLabApi testApi(FakeAdapter adapter, {String host = 'https://example.com/gitlab'}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return GitLabApi(instance: GitLabInstance.parse(host), token: 'synthetic-test-token', dio: dio);
}

Map<String, Object?> projectJson(int id, {String? branch = 'main'}) => {
  'id': id, 'name': 'Example $id', 'path_with_namespace': 'team/example-$id',
  'visibility': 'private', 'default_branch': branch, 'archived': false,
};
