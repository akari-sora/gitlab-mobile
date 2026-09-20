import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/pagination.dart';
import 'support/fake_adapter.dart';

void main() {
  test('real GitLab default expansion does not discard projects or break page two', () async {
    final adapter = FakeAdapter((r) {
      final next = r.uri.replace(queryParameters: {
        ...r.uri.queryParameters, 'page': '2', 'simple': 'false', 'starred': 'false',
        'owned': 'false', 'imported': 'false', 'include_hidden': 'false', 'statistics': 'false',
        'with_custom_attributes': 'false', 'with_issues_enabled': 'false',
        'with_merge_requests_enabled': 'false', 'repository_checksum_failed': 'false', 'wiki_checksum_failed': 'false',
      });
      return jsonResponse([projectJson(r.uri.queryParameters['page'] == '2' ? 2 : 1)],
        headers: r.uri.queryParameters['page'] == '2' ? {} : {'link': ['<$next>; rel="next"']});
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final first = await api.projects(scope: ProjectScope.member);
    expect(first.items.single.id, 1); expect(first.next, isNotNull);
    expect(first.next!.queryParameters['starred'], isNull);
    final second = await api.projects(scope: ProjectScope.member, next: first.next);
    expect(second.items.single.id, 2);
    expect(adapter.requests.last.uri.queryParameters['membership'], 'true');
  });
  test('unknown non-cursor parameters never reach the next request', () {
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    final current = instance.api(['projects'], {'membership': 'true', 'per_page': '30'});
    final candidate = current.replace(queryParameters: {...current.queryParameters,
      'page': '2', 'sudo': '42', 'simple': 'false'});
    final next = checkedPageUri(instance, current, candidate);
    expect(next.queryParameters.keys, unorderedEquals(['membership', 'per_page', 'page']));
  });
  test('credential query parameters are rejected rather than followed or logged', () {
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    final current = instance.api(['projects'], {'membership': 'true'});
    expect(() => checkedPageUri(instance, current, current.replace(queryParameters: {
      ...current.queryParameters, 'page': '2', 'private_token': 'synthetic-untrusted',
    })), throwsFormatException);
  });
  test('meaningful scope changes, duplicate keys and cross-origin cursors fail', () {
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    final current = instance.api(['projects'], {'membership': 'true'});
    for (final bad in [
      current.replace(queryParameters: {'membership': 'false', 'page': '2'}),
      current.replace(queryParameters: {'membership': 'true', 'starred': 'true', 'page': '2'}),
      Uri.parse('${current.toString()}&page=2&page=3'),
      Uri.parse('https://evil.example/gitlab/api/v4/projects?membership=true&page=2'),
    ]) { expect(() => checkedPageUri(instance, current, bad), throwsFormatException); }
  });
  test('tree links expand route id without forwarding route overrides', () {
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    final current = instance.api(['projects', '42', 'repository', 'tree'], {'ref': 'abc', 'path': '', 'per_page': '50'});
    final next = checkedPageUri(instance, current, current.replace(queryParameters: {
      ...current.queryParameters, 'id': '42', 'page': '2', 'pagination': 'legacy', 'recursive': 'false', 'with_last_commit': 'false',
    }));
    expect(next.queryParameters['id'], isNull);
    expect(next.queryParameters['ref'], 'abc'); expect(next.queryParameters['page'], '2');
  });
}
