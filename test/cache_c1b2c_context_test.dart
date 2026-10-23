import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_context.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';

import 'support/fake_adapter.dart';

const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _project = Project(
  id: 42,
  name: 'Fixture',
  path: 'team/fixture',
  defaultBranch: 'main',
);
const _origin = AiWorkItemOrigin(
  project: _project,
  kind: AiWorkItemKind.issue,
  iid: 3,
  title: 'Fixture issue',
);
const _fileOrigin = AiFileOrigin(
  project: _project,
  path: 'README.md',
  sha: _sha,
);

final class _Secrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => const ['synthetic-private-value'];
}

final class _Fixture {
  _Fixture({this.pages = 1, ReadCacheSource? source}) {
    adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.contains('/repository/files/README.md')) {
        if (fileUnavailable) return jsonResponse({}, status: 503);
        return ResponseBody.fromString(
          request.method == 'HEAD' ? '' : fileText,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        );
      }
      if (path.endsWith('/notes')) {
        final page = int.parse(request.uri.queryParameters['page'] ?? '1');
        return jsonResponse(
          [
            {
              'id': page,
              'body': 'note $page synthetic-private-value',
              'created_at': '2026-10-23T00:00:00Z',
              'system': pages > 1,
              'internal': true,
            },
          ],
          headers: {
            if (page < pages) 'x-next-page': ['${page + 1}'],
          },
        );
      }
      if (path.endsWith('/issues/3')) {
        return jsonResponse({
          'title': 'network issue',
          'description': 'synthetic-private-value',
          'state': 'opened',
          'confidential': true,
        });
      }
      if (path.endsWith('/repository/branches/main')) {
        return jsonResponse({
          'commit': {'id': _sha},
        });
      }
      if (path.endsWith('/projects/42')) {
        return jsonResponse({
          ...projectJson(42),
          'path_with_namespace': _project.path,
        });
      }
      return jsonResponse({'message': 'not found'}, status: 404);
    });
    api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-pat',
      dio: Dio()..httpClientAdapter = adapter,
      readCacheClock: () => now,
      readCacheSource: source,
    );
    api.bindReadCache('${api.instance.key}#7', 1);
    addTearDown(api.close);
  }

  DateTime now = DateTime.utc(2026, 10, 23);
  final int pages;
  String fileText = 'network-file';
  bool fileUnavailable = false;
  late final FakeAdapter adapter;
  late final GitLabApi api;

  Future<void> warmMetadata() async {
    await api.cachedRecord(['projects', '42']);
    await api.cachedRecord([
      'projects',
      '42',
      'repository',
      'branches',
      'main',
    ]);
  }

  Future<AiChatContext> load({AiChatOrigin origin = _origin}) =>
      loadAiChatContext(
        origin: origin,
        api: api,
        redactor: Redactor(secrets: _Secrets()),
        accountKey: '${api.instance.key}#7',
        refreshSecrets: () async {},
        isCurrent: () => true,
        now: () => now,
      );

  Map<String, int> get endpointCounts {
    final counts = <String, int>{};
    for (final request in adapter.requests) {
      final path = request.uri.path;
      counts[path] = (counts[path] ?? 0) + 1;
    }
    return counts;
  }
}

void main() {
  for (final path in ['README.md', '.env']) {
    test('SHA-pinned context has no expiry, including $path', () async {
      final fixture = _Fixture();
      final context = await fixture.load(
        origin: AiFileOrigin(project: _project, path: path, sha: _sha),
      );
      expect(context.fetchedAt, isNull);
      expect(
        context.isExpired(fixture.now.add(const Duration(days: 1))),
        isFalse,
      );
      if (path == '.env') {
        expect(fixture.adapter.requests, isEmpty);
        expect(context.built.blockedSensitivePaths, [path]);
      } else {
        expect(fixture.adapter.requests, hasLength(2));
      }
    });
  }

  for (final warmIssue in [false, true]) {
    test(
      'AI issue opening: metadata warm, issue warm=$warmIssue, notes=1 page, '
      'viewport=logic, clock=fixed, all reads settled costs at most 2 HTTP requests',
      () async {
        final fixture = _Fixture();
        await fixture.warmMetadata();
        if (warmIssue) {
          await fixture.api.cachedRecord(['projects', '42', 'issues', '3']);
        }
        fixture.adapter.requests.clear();
        final context = await fixture.load();
        expect(fixture.adapter.requests.length, lessThanOrEqualTo(2));
        expect(fixture.endpointCounts, {
          if (!warmIssue) '/gitlab/api/v4/projects/42/issues/3': 1,
          '/gitlab/api/v4/projects/42/issues/3/notes': 1,
        });
        final text = context.built.blocks.single.text;
        expect(text, contains('network issue'));
        expect(text, isNot(contains('synthetic-private-value')));
        expect(context.built.readInternal, isTrue);
      },
    );
  }

  for (final pages in [3, 9]) {
    test(
      'AI issue opening: metadata warm, notes=$pages pages of system notes, '
      'viewport=logic, clock=fixed, all reads settled obeys five-page bound',
      () async {
        final fixture = _Fixture(pages: pages);
        await fixture.warmMetadata();
        fixture.adapter.requests.clear();
        await fixture.load();
        expect(fixture.endpointCounts, {
          '/gitlab/api/v4/projects/42/issues/3': 1,
          '/gitlab/api/v4/projects/42/issues/3/notes': pages < 5 ? pages : 5,
        });
      },
    );
  }

  test('page context refuses disk lineage promoted into memory', () async {
    var diskReads = 0;
    final fixture = _Fixture(
      source: (uri, _) async {
        if (!uri.path.endsWith('/issues/3')) return null;
        diskReads++;
        return CacheDiskEntry(
          value: <String, Object?>{
            'title': 'disk-only-title',
            'description': 'disk-only-description',
            'state': 'opened',
          },
          fetchedAt: DateTime.utc(2026, 10, 23),
          responseBytes: 200,
        );
      },
    );
    await fixture.warmMetadata();
    final hydrated = await fixture.api.cachedRecord([
      'projects',
      '42',
      'issues',
      '3',
    ]);
    expect(hydrated.lineage, CacheLineage.disk);
    fixture.adapter.requests.clear();
    final context = await fixture.load();
    expect(diskReads, 1);
    expect(context.built.blocks.single.text, contains('network issue'));
    expect(context.built.blocks.single.text, isNot(contains('disk-only')));
    expect(fixture.endpointCounts['/gitlab/api/v4/projects/42/issues/3'], 1);
  });

  test(
    'context expiry preserves the oldest fetchedAt rather than build time',
    () async {
      final fixture = _Fixture();
      final start = fixture.now;
      await fixture.warmMetadata();
      fixture.now = start.add(const Duration(seconds: 45));
      final context = await fixture.load();
      expect(context.fetchedAt, start);
      expect(
        context.isExpired(start.add(const Duration(seconds: 59))),
        isFalse,
      );
      expect(context.isExpired(start.add(const Duration(seconds: 60))), isTrue);
      expect(
        context.isExpired(start.subtract(const Duration(seconds: 1))),
        isTrue,
      );
    },
  );

  test(
    'pinned file page context refuses disk lineage promoted into memory',
    () async {
      var diskReads = 0;
      final fixture = _Fixture(
        source: (uri, _) async {
          if (!uri.path.contains('/repository/files/')) return null;
          diskReads++;
          return CacheDiskEntry(
            value: 'disk-only-file',
            fetchedAt: DateTime.utc(2026, 10, 23),
            responseBytes: 14,
          );
        },
      );
      await fixture.warmMetadata();
      await fixture.api.defaultBranchSha(_project);
      expect(
        await fixture.api.textFile(42, _sha, 'README.md'),
        'disk-only-file',
      );
      fixture.adapter.requests.clear();
      final context = await fixture.load(origin: _fileOrigin);
      expect(diskReads, 1);
      expect(fixture.adapter.requests, hasLength(2));
      expect(context.built.blocks.single.text, contains('network-file'));
      expect(
        context.built.blocks.single.text,
        isNot(contains('disk-only-file')),
      );
    },
  );

  for (final unavailable in [false, true]) {
    test(
      'pinned file page context cannot restamp old memory; network unavailable=$unavailable',
      () async {
        final fixture = _Fixture();
        await fixture.warmMetadata();
        await fixture.api.defaultBranchSha(_project);
        await fixture.api.textFile(42, _sha, 'README.md');
        fixture.now = fixture.now.add(const Duration(seconds: 61));
        fixture.fileText = 'replacement-file';
        fixture.fileUnavailable = unavailable;
        fixture.adapter.requests.clear();
        if (unavailable) {
          await expectLater(
            fixture.load(origin: _fileOrigin),
            throwsA(isA<ApiFailure>()),
          );
        } else {
          final context = await fixture.load(origin: _fileOrigin);
          expect(
            context.built.blocks.single.text,
            contains('replacement-file'),
          );
          expect(
            context.built.blocks.single.text,
            isNot(contains('network-file')),
          );
        }
        expect(fixture.adapter.requests, hasLength(unavailable ? 1 : 2));
      },
    );
  }
}
