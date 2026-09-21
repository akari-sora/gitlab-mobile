import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/pagination.dart';
import 'package:gitlab_mobile/core/project_locator.dart';

void main() {
  group('instance identity and credential boundary', () {
    test(
      'normalizes host and default port but preserves installation path',
      () {
        expect(
          GitLabInstance.parse('https://EXAMPLE.com:443/gitlab/').key,
          'https://example.com/gitlab',
        );
        expect(
          GitLabInstance.parse('https://example.com:8443/gitlab').key,
          'https://example.com:8443/gitlab',
        );
      },
    );
    for (final invalid in [
      'http://example.com',
      'https://u:pw@example.com',
      'https://example.com?token=x',
      'https://example.com/#fragment',
      'https://example.com/../gitlab',
      'https://example.com/%2e%2e/gitlab',
      'https://example.com/a%2fb',
      'https://example.com//gitlab',
    ]) {
      test('rejects ambiguous instance: $invalid', () {
        expect(() => GitLabInstance.parse(invalid), throwsFormatException);
      });
    }
    test('encodes nested path exactly once as an endpoint parameter', () {
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final uri = instance.api(['projects', 'team/sub/project']);
      expect(
        uri.toString(),
        'https://example.com/gitlab/api/v4/projects/team%2Fsub%2Fproject',
      );
      expect(uri.pathSegments.last, 'team/sub/project');
    });
    test('refuses API credential forwarding outside instance API', () {
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      expect(
        instance.allowsApi(Uri.parse('https://evil.example/api/v4/user')),
        isFalse,
      );
      expect(
        instance.allowsApi(Uri.parse('https://example.com/api/v4/user')),
        isFalse,
      );
      expect(
        instance.allowsApi(
          Uri.parse('https://example.com/gitlab/api/v4/user?access_token=x'),
        ),
        isFalse,
      );
      expect(instance.allowsApi(instance.api(['user'])), isTrue);
      expect(
        instance.oauth('token').toString(),
        'https://example.com/gitlab/oauth/token',
      );
      expect(instance.allowsApi(instance.oauth('token')), isFalse);
    });
    test('account identity uses numeric ID, not mutable username', () {
      final instance = GitLabInstance.parse('https://example.com');
      final first = Account(
        instance: instance,
        user: const GitLabUser(id: 7, username: 'before', name: 'Test'),
        token: 'synthetic-test-token',
      );
      final second = Account(
        instance: instance,
        user: const GitLabUser(id: 7, username: 'after', name: 'Test'),
        token: 'other-synthetic-token',
      );
      expect(first.key, second.key);
      expect(first.toString(), isNot(contains('synthetic-test-token')));
    });
  });
  group('project locator', () {
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    test('supports numeric ID and nested namespace', () {
      expect(projectLocator(instance, '42'), '42');
      expect(projectLocator(instance, 'team/sub/project'), 'team/sub/project');
    });
    test('opens the project from a leaf URL without guessing branch names', () {
      expect(
        projectLocator(
          instance,
          'https://example.com/gitlab/team/repo/-/blob/feature/a/lib/a.dart',
        ),
        'team/repo',
      );
    });
    test(
      'accepts ordinary GitLab query and line fragment without forwarding either',
      () {
        expect(
          projectLocator(
            instance,
            'https://example.com/gitlab/team/repo/-/blob/main/a.dart?ref_type=heads#L12',
          ),
          'team/repo',
        );
      },
    );
    test('accepts HTTPS clone URL and trailing slash', () {
      expect(
        projectLocator(instance, 'https://example.com/gitlab/team/repo.git'),
        'team/repo',
      );
      expect(projectLocator(instance, 'team/repo/'), 'team/repo');
    });
    test('retains namespace but never guesses slash-containing branch', () {
      expect(
        projectLocator(
          instance,
          'https://example.com/gitlab/team/sub/repo/-/tree/feature%2Flogin',
        ),
        'team/sub/repo',
      );
    });
    test('rejects embedded credentials instead of silently reusing them', () {
      expect(
        () => projectLocator(
          instance,
          'https://example.com/gitlab/team/repo?private_token=synthetic',
        ),
        throwsFormatException,
      );
    });
    test('rejects literal and percent-encoded traversal', () {
      for (final link in [
        'https://example.com/gitlab/team/../repo',
        'https://example.com/gitlab/team/%2e%2e/repo',
        'https://example.com/gitlab/team%2Frepo/other',
      ]) {
        expect(() => projectLocator(instance, link), throwsFormatException);
      }
    });
    test('refuses a different origin or installation path', () {
      expect(
        () => projectLocator(instance, 'https://evil.example/team/repo'),
        throwsFormatException,
      );
      expect(
        () => projectLocator(instance, 'https://example.com/other/team/repo'),
        throwsFormatException,
      );
    });
  });
  group('pagination', () {
    final instance = GitLabInstance.parse('https://example.com');
    final first = instance.api(
      ['projects'],
      {'membership': 'true', 'per_page': '30'},
    );
    test('does not guess an extra page when headers are absent', () {
      expect(
        nextPageUri(instance: instance, current: first, headers: {}),
        isNull,
      );
    });
    test('accepts server next-page header preserving filters', () {
      final next = nextPageUri(
        instance: instance,
        current: first,
        headers: {
          'X-Next-Page': ['2'],
        },
      );
      expect(next?.queryParameters['page'], '2');
      expect(next?.queryParameters['membership'], 'true');
    });
    test('refuses a malicious Link header', () {
      expect(
        () => nextPageUri(
          instance: instance,
          current: first,
          headers: {
            'link': [
              '<https://evil.example/api/v4/projects?page=2>; rel="next"',
            ],
          },
        ),
        throwsFormatException,
      );
    });
    test('refuses backward pagination and changed scope', () {
      expect(
        () => nextPageUri(
          instance: instance,
          current: first,
          headers: {
            'x-next-page': ['1'],
          },
        ),
        throwsFormatException,
      );
      final next = instance.api(
        ['projects'],
        {'page': '2', 'membership': 'false'},
      );
      expect(
        () => nextPageUri(
          instance: instance,
          current: first,
          headers: {
            'link': ['<$next>; rel="next"'],
          },
        ),
        throwsFormatException,
      );
    });
  });
}
