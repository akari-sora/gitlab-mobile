import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/repository_ref.dart';

void main() {
  group('RepositoryRef domain model', () {
    test('parses branch correctly with valid 40-char commit SHA', () {
      final json = {
        'name': 'main',
        'protected': true,
        'default': true,
        'commit': {
          'id': '6dcfcfd77732931ad5a616f336d73c8f3cdbc2d1',
          'short_id': '6dcfcfd7',
          'title': 'fix: something',
        },
      };

      final ref = RepositoryRef.fromBranch(json);
      expect(ref.kind, RepositoryRefKind.branch);
      expect(ref.name, 'main');
      expect(ref.sha, '6dcfcfd77732931ad5a616f336d73c8f3cdbc2d1');
      expect(ref.protected, isTrue);
      expect(ref.isDefault, isTrue);
      expect(ref.writable, isTrue);
      expect(ref.identity, 'branch:main@6dcfcfd77732931ad5a616f336d73c8f3cdbc2d1');
    });

    test('parses tag correctly using commit.id instead of target object', () {
      final json = {
        'name': 'v1.0.0',
        'target': 'c912389123891238912389123891238912389123',
        'protected': true,
        'commit': {
          'id': '11223344556677889900aabbccddeeff00112233',
        },
      };

      final ref = RepositoryRef.fromTag(json);
      expect(ref.kind, RepositoryRefKind.tag);
      expect(ref.name, 'v1.0.0');
      expect(ref.sha, '11223344556677889900aabbccddeeff00112233');
      expect(ref.protected, isTrue);
      expect(ref.isDefault, isFalse);
      expect(ref.writable, isFalse);
      expect(ref.identity, 'tag:v1.0.0@11223344556677889900aabbccddeeff00112233');
    });

    test('handles 64-character SHA-256 commit IDs', () {
      const sha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
      final json = {
        'name': 'feature',
        'protected': false,
        'commit': {'id': sha256.toUpperCase()},
      };

      final ref = RepositoryRef.fromBranch(json);
      expect(ref.sha, sha256);
    });

    test('throws ApiFailure(invalidResponse) on malformed commit SHA', () {
      final json = {
        'name': 'invalid-branch',
        'commit': {'id': 'not-a-valid-sha'},
      };

      expect(() => RepositoryRef.fromBranch(json), throwsA(isA<ApiFailure>()));
    });

    test('branch and tag with identical name have distinct identities', () {
      const sha = '11223344556677889900aabbccddeeff00112233';
      const branch = RepositoryRef(
        kind: RepositoryRefKind.branch,
        name: 'release',
        sha: sha,
        protected: true,
      );
      const tag = RepositoryRef(
        kind: RepositoryRefKind.tag,
        name: 'release',
        sha: sha,
        protected: true,
      );

      expect(branch == tag, isFalse);
      expect(branch.identity, isNot(equals(tag.identity)));
      expect(branch.writable, isTrue);
      expect(tag.writable, isFalse);
    });
  });

  group('repositoryBlobWebUri permalink builder', () {
    test('builds standard permalink on gitlab.com without line', () {
      final instance = GitLabInstance.parse('https://gitlab.com');
      final uri = repositoryBlobWebUri(
        instance: instance,
        projectPath: 'aa22396584/gitlab-mobile',
        sha: '6dcfcfd77732931ad5a616f336d73c8f3cdbc2d1',
        filePath: 'lib/main.dart',
      );

      expect(
        uri.toString(),
        'https://gitlab.com/aa22396584/gitlab-mobile/-/blob/6dcfcfd77732931ad5a616f336d73c8f3cdbc2d1/lib/main.dart',
      );
    });

    test('builds permalink with line fragment on self-managed instance with installation subpath and port', () {
      final instance = GitLabInstance.parse('https://gitlab.internal:8080/company');
      final uri = repositoryBlobWebUri(
        instance: instance,
        projectPath: 'infra/tools',
        sha: '11223344556677889900aabbccddeeff00112233',
        filePath: 'configs/app.yaml',
        line: 42,
      );

      expect(
        uri.toString(),
        'https://gitlab.internal:8080/company/infra/tools/-/blob/11223344556677889900aabbccddeeff00112233/configs/app.yaml#L42',
      );
      expect(uri.fragment, 'L42');
    });

    test('encodes spaces and special characters in file and project paths', () {
      final instance = GitLabInstance.parse('https://gitlab.com');
      final uri = repositoryBlobWebUri(
        instance: instance,
        projectPath: 'group/sub group',
        sha: '11223344556677889900aabbccddeeff00112233',
        filePath: 'assets/file with space.txt',
        line: 10,
      );

      expect(
        uri.toString(),
        'https://gitlab.com/group/sub%20group/-/blob/11223344556677889900aabbccddeeff00112233/assets/file%20with%20space.txt#L10',
      );
    });

    test('ignores non-positive line numbers for fragment', () {
      final instance = GitLabInstance.parse('https://gitlab.com');
      final uriZero = repositoryBlobWebUri(
        instance: instance,
        projectPath: 'demo/repo',
        sha: '11223344556677889900aabbccddeeff00112233',
        filePath: 'README.md',
        line: 0,
      );
      expect(uriZero.fragment, isEmpty);

      final uriNegative = repositoryBlobWebUri(
        instance: instance,
        projectPath: 'demo/repo',
        sha: '11223344556677889900aabbccddeeff00112233',
        filePath: 'README.md',
        line: -5,
      );
      expect(uriNegative.fragment, isEmpty);
    });

    test('never appends tokens or query credentials in permalink URI', () {
      final instance = GitLabInstance.parse('https://gitlab.com');
      final uri = repositoryBlobWebUri(
        instance: instance,
        projectPath: 'secret/project',
        sha: '11223344556677889900aabbccddeeff00112233',
        filePath: 'lib/secret.dart',
        line: 100,
      );

      expect(uri.query, isEmpty);
      expect(uri.userInfo, isEmpty);
      expect(uri.toString().contains('token'), isFalse);
    });

    test('rejects empty project path or file path with FormatException', () {
      final instance = GitLabInstance.parse('https://gitlab.com');
      const sha = '11223344556677889900aabbccddeeff00112233';

      expect(
        () => repositoryBlobWebUri(
          instance: instance,
          projectPath: '',
          sha: sha,
          filePath: 'lib/main.dart',
        ),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => repositoryBlobWebUri(
          instance: instance,
          projectPath: '   ///   ',
          sha: sha,
          filePath: 'lib/main.dart',
        ),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => repositoryBlobWebUri(
          instance: instance,
          projectPath: 'group/project',
          sha: sha,
          filePath: '',
        ),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => repositoryBlobWebUri(
          instance: instance,
          projectPath: 'group/project',
          sha: sha,
          filePath: '   ///   ',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects path traversal attempts in projectPath and filePath', () {
      final instance = GitLabInstance.parse('https://gitlab.com');
      const sha = '11223344556677889900aabbccddeeff00112233';

      expect(
        () => repositoryBlobWebUri(
          instance: instance,
          projectPath: 'group/project',
          sha: sha,
          filePath: '../../etc/passwd',
        ),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => repositoryBlobWebUri(
          instance: instance,
          projectPath: 'group/../other',
          sha: sha,
          filePath: 'lib/main.dart',
        ),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => repositoryBlobWebUri(
          instance: instance,
          projectPath: 'group/project',
          sha: sha,
          filePath: r'lib\main.dart',
        ),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => repositoryBlobWebUri(
          instance: instance,
          projectPath: 'group/project',
          sha: sha,
          filePath: '%2e%2e/secret.txt',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('normalizes leading, trailing, and internal consecutive slashes', () {
      final instance = GitLabInstance.parse('https://gitlab.com');
      const sha = '11223344556677889900aabbccddeeff00112233';

      final uri = repositoryBlobWebUri(
        instance: instance,
        projectPath: '/group//project/',
        sha: sha,
        filePath: '/lib//src///main.dart/',
        line: 15,
      );

      expect(
        uri.toString(),
        'https://gitlab.com/group/project/-/blob/$sha/lib/src/main.dart#L15',
      );
    });
  });
}
