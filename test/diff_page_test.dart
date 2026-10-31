import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/unified_diff.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

final class _FakeUrlLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

_FakeUrlLauncher _stubLauncher() {
  final launcher = _FakeUrlLauncher();
  final original = UrlLauncherPlatform.instance;
  UrlLauncherPlatform.instance = launcher;
  addTearDown(() => UrlLauncherPlatform.instance = original);
  return launcher;
}

/// A merge request version diff item in GitLab's response shape.
Map<String, dynamic> _gitLabDiffItem({
  required String path,
  required String diff,
  bool deletedFile = false,
  bool tooLarge = false,
}) => {
  'diff': diff,
  'new_path': path,
  'old_path': path,
  'a_mode': '100644',
  'b_mode': deletedFile ? '0' : '100644',
  'new_file': false,
  'renamed_file': false,
  'deleted_file': deletedFile,
  'generated_file': false,
  'collapsed': false,
  'too_large': tooLarge,
};

/// A single-hunk diff whose parse yields exactly [parsedLines] rows: the hunk
/// header plus `parsedLines - 1` added lines.
String _syntheticDiff(int parsedLines, String prefix) {
  final added = parsedLines - 1;
  final buffer = StringBuffer('@@ -0,0 +1,$added @@\n');
  for (var i = 1; i <= added; i++) {
    buffer.writeln('+$prefix-$i');
  }
  return buffer.toString();
}

/// The screen's own retained-size estimate: UTF-8 source, parsed UTF-8 text
/// and 64 bytes per row.
int _estimatedBytes(String source, List<DiffLine> lines) {
  var bytes = utf8.encode(source).length + lines.length * 64;
  for (final line in lines) {
    bytes += utf8.encode(line.text).length;
  }
  return bytes;
}

Widget _fixturePage(WorkspaceFixture fixture) => MaterialApp(
  home: Scaffold(
    body: ReviewDiffPage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
      iid: 12,
      expectedSha: WorkspaceFixture.sha,
    ),
  ),
);

Future<void> _openFile(WidgetTester tester, String path, Finder shown) async {
  await tester.tap(find.text(path));
  await pumpUntil(
    tester,
    () => shown.evaluate().isNotEmpty,
    maxCycles: 400,
    description: '$path shown',
  );
  await settleNetworkWidgets(tester);
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  final instance = GitLabInstance.parse('https://example.com/gitlab');
  final account = Account(
    instance: instance,
    user: const GitLabUser(id: 7, username: 'reviewer', name: 'Reviewer'),
    token: 'synthetic-token',
  );
  final project = Project.fromJson({
    'id': 42,
    'name': 'Project',
    'path': 'project',
    'path_with_namespace': 'group/project',
    'description': '',
    'visibility': 'private',
    'default_branch': 'main',
    'archived': false,
    'last_activity_at': '2026-09-20T10:00:00Z',
  });

  const baseSha = '1111111111111111111111111111111111111111';
  const startSha = '2222222222222222222222222222222222222222';
  const headSha = '3333333333333333333333333333333333333333';

  final validDiff = '''
@@ -1,3 +1,4 @@
 line1
-old_line2
+new_line2
+new_line3
 line4
''';

  final sampleVersion = {
    'id': 1,
    'head_commit_sha': headSha,
    'base_commit_sha': baseSha,
    'start_commit_sha': startSha,
    'diffs': [
      {
        'old_path': 'lib/sample.dart',
        'new_path': 'lib/sample.dart',
        'a_mode': '100644',
        'b_mode': '100644',
        'new_file': false,
        'renamed_file': false,
        'deleted_file': false,
        'diff': validDiff,
      },
    ],
  };

  testWidgets('DiffPage shows empty state when no diffs available', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/versions')) {
        return jsonResponse([
          {'id': 1, 'head_commit_sha': headSha},
        ]);
      }
      if (request.uri.path.endsWith('/versions/1')) {
        return jsonResponse({
          'id': 1,
          'head_commit_sha': headSha,
          'base_commit_sha': baseSha,
          'start_commit_sha': startSha,
          'diffs': <Map<String, dynamic>>[],
        });
      }
      return jsonResponse([]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReviewDiffPage(
            account: account,
            api: api,
            project: project,
            iid: 10,
            expectedSha: headSha,
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('沒有可顯示的文字差異'), findsOneWidget);
  });

  testWidgets('ReviewDiffPage shows error notice on network failure', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({'message': 'not found'}, status: 404),
    );
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReviewDiffPage(
            account: account,
            api: api,
            project: project,
            iid: 10,
            expectedSha: headSha,
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('無法開啟此資源'), findsOneWidget);
    expect(find.text('App 帳號：@reviewer'), findsOneWidget);
  });

  testWidgets(
    'ReviewDiffPage lists diff files and opens file with >= 48 dp line tap target',
    (tester) async {
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/versions')) {
          return jsonResponse([
            {'id': 1, 'head_commit_sha': headSha},
          ]);
        }
        if (request.uri.path.endsWith('/versions/1')) {
          return jsonResponse(sampleVersion);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReviewDiffPage(
              account: account,
              api: api,
              project: project,
              iid: 10,
              expectedSha: headSha,
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(find.text('lib/sample.dart'), findsOneWidget);
      await tester.tap(find.text('lib/sample.dart'));
      await settleNetworkWidgets(tester);

      // Verify file diff screen is presented
      expect(find.text('點選程式碼行新增留言 · 33333333'), findsOneWidget);
      expect(find.text('line1'), findsOneWidget);
      expect(find.text('old_line2'), findsOneWidget);
      expect(find.text('new_line2'), findsOneWidget);

      // Verify tap target height satisfies the 48 dp minimum requirement
      for (var i = 0; i < 4; i++) {
        final lineFinder = find.byKey(ValueKey('diff-line-$i'));
        expect(lineFinder, findsOneWidget);
        final size = tester.getSize(lineFinder);
        expect(
          size.height,
          greaterThanOrEqualTo(48.0),
          reason: 'Line $i tap target height must be at least 48 dp',
        );
      }
    },
  );

  testWidgets('DiffFileScreen too_large diff offers open in GitLab', (
    tester,
  ) async {
    final launcher = _stubLauncher();
    final collapsedVersion = {
      'id': 1,
      'head_commit_sha': headSha,
      'base_commit_sha': baseSha,
      'start_commit_sha': startSha,
      'state': 'collected',
      'diffs': [
        _gitLabDiffItem(path: 'assets/big.bin', diff: '', tooLarge: true),
        _gitLabDiffItem(
          path: 'assets/gone.bin',
          diff: '',
          deletedFile: true,
          tooLarge: true,
        ),
        _gitLabDiffItem(path: 'assets/empty.bin', diff: ''),
      ],
    };

    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/versions')) {
        return jsonResponse([
          {'id': 1, 'head_commit_sha': headSha},
        ]);
      }
      if (request.uri.path.endsWith('/versions/1')) {
        return jsonResponse(collapsedVersion);
      }
      return jsonResponse([]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReviewDiffPage(
            account: account,
            api: api,
            project: project,
            iid: 10,
            expectedSha: headSha,
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('assets/big.bin'));
    await settleNetworkWidgets(tester);

    expect(find.text('無法顯示差異'), findsOneWidget);
    expect(find.text('GitLab 未提供這份文字差異，或內容為二進位檔案。'), findsOneWidget);
    final openWeb = find.byKey(const ValueKey('diff-file-open-web'));
    expect(
      find.descendant(of: openWeb, matching: find.text('在 GitLab 開啟')),
      findsOneWidget,
    );
    await tester.tap(openWeb);
    await tester.pump();
    expect(launcher.launched, [
      'https://example.com/gitlab/group/project/-/blob/$headSha/assets/big.bin',
    ]);

    // A deleted file no longer exists at the head: open it at the base.
    await tester.pageBack();
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('assets/gone.bin'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('diff-file-open-web')));
    await tester.pump();
    expect(
      launcher.launched.last,
      'https://example.com/gitlab/group/project/-/blob/$baseSha/assets/gone.bin',
    );

    // An empty diff GitLab did not mark too_large keeps the plain message.
    await tester.pageBack();
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('assets/empty.bin'));
    await settleNetworkWidgets(tester);
    expect(find.text('GitLab 未提供這份文字差異，或內容為二進位檔案。'), findsOneWidget);
    expect(find.byKey(const ValueKey('diff-file-open-web')), findsNothing);
    expect(launcher.launched, hasLength(2));
  });

  group('version state (#59)', () {
    testWidgets('an overflow version shows the partial diff notice', (
      tester,
    ) async {
      final fixture = WorkspaceFixture()
        ..omitSeedDiscussions = true
        ..versionState = 'overflow';
      addTearDown(fixture.api.close);

      await tester.pumpWidget(_fixturePage(fixture));
      await settleNetworkWidgets(tester);

      expect(find.text('lib/session.dart'), findsOneWidget);
      expect(find.text(l10n.partialDiffNotComplete), findsOneWidget);
    });

    testWidgets('a collected version shows no partial diff notice', (
      tester,
    ) async {
      final fixture = WorkspaceFixture()..omitSeedDiscussions = true;
      addTearDown(fixture.api.close);

      await tester.pumpWidget(_fixturePage(fixture));
      await settleNetworkWidgets(tester);

      expect(find.text('lib/session.dart'), findsOneWidget);
      expect(find.text(l10n.partialDiffNotComplete), findsNothing);
    });
  });

  group('large diff baselines (#59)', () {
    testWidgets(
      'parses 5,000- and 20,000-line diffs through the real parser and caches them',
      (tester) async {
        final diff5k = _syntheticDiff(5000, 'fivek');
        final diff20k = _syntheticDiff(20000, 'twentyk');
        final parsed5k = parseUnifiedDiff(diff5k);
        final parsed20k = parseUnifiedDiff(diff20k);
        expect(parsed5k, hasLength(5000));
        expect(parsed20k, hasLength(20000));

        final fixture = WorkspaceFixture()
          ..omitSeedDiscussions = true
          ..versionDiffs = [
            _gitLabDiffItem(path: 'lib/five_k.dart', diff: diff5k),
            _gitLabDiffItem(path: 'lib/twenty_k.dart', diff: diff20k),
          ];
        addTearDown(fixture.api.close);
        await tester.pumpWidget(_fixturePage(fixture));
        await settleNetworkWidgets(tester);

        await _openFile(tester, 'lib/five_k.dart', find.text('fivek-1'));
        final after5k = debugDiffCacheStats(fixture.api);
        expect(after5k.entries, 1);
        expect(after5k.parsedLines, 5000);
        expect(after5k.estimatedBytes, _estimatedBytes(diff5k, parsed5k));

        await tester.pageBack();
        await settleNetworkWidgets(tester);
        await _openFile(tester, 'lib/twenty_k.dart', find.text('twentyk-1'));
        expect(find.byKey(const ValueKey('diff-file-open-web')), findsNothing);
        final after20k = debugDiffCacheStats(fixture.api);
        expect(after20k.entries, 2);
        expect(after20k.parsedLines, 25000);
        expect(
          after20k.estimatedBytes,
          _estimatedBytes(diff5k, parsed5k) +
              _estimatedBytes(diff20k, parsed20k),
        );
      },
    );

    testWidgets(
      'a diff over 20,000 lines or 2 MiB takes the too-large path with open in GitLab',
      (tester) async {
        final launcher = _stubLauncher();
        final overLines = _syntheticDiff(20001, 'over-lines');
        // The parser itself refuses more than 20,000 rows.
        expect(() => parseUnifiedDiff(overLines), throwsFormatException);
        final overBytes = '@@ -0,0 +1,1 @@\n+${'x' * (2 * 1024 * 1024 + 32)}\n';

        final fixture = WorkspaceFixture()
          ..omitSeedDiscussions = true
          ..versionDiffs = [
            _gitLabDiffItem(path: 'lib/over_lines.dart', diff: overLines),
            _gitLabDiffItem(path: 'lib/over_bytes.dart', diff: overBytes),
          ];
        addTearDown(fixture.api.close);
        await tester.pumpWidget(_fixturePage(fixture));
        await settleNetworkWidgets(tester);

        final openWeb = find.byKey(const ValueKey('diff-file-open-web'));
        await _openFile(tester, 'lib/over_lines.dart', openWeb);
        expect(find.text(l10n.cannotDisplayDiff), findsOneWidget);
        expect(find.text(l10n.inlineCommentsDisabled), findsOneWidget);
        expect(find.text('over-lines-1'), findsNothing);
        expect(debugDiffCacheStats(fixture.api).entries, 0);
        await tester.tap(openWeb);
        await tester.pump();
        expect(launcher.launched, [
          'https://example.com/gitlab/studio/mobile-workspace/-/blob/'
              '${WorkspaceFixture.sha}/lib/over_lines.dart',
        ]);

        await tester.pageBack();
        await settleNetworkWidgets(tester);
        await _openFile(tester, 'lib/over_bytes.dart', openWeb);
        expect(find.text(l10n.cannotDisplayDiff), findsOneWidget);
        expect(find.text(l10n.inlineCommentsDisabled), findsOneWidget);
        expect(debugDiffCacheStats(fixture.api).entries, 0);
      },
    );

    testWidgets('the diff cache stays within 8 MiB and 40,000 lines', (
      tester,
    ) async {
      const maxCacheBytes = 8 * 1024 * 1024;
      const maxCacheLines = 40000;
      final pad = 'p' * 85;
      // A, B and C are about 3 MiB each by the estimate, so the third one
      // evicts by bytes; D's 18,000 rows then evict by lines.
      final files = {
        'lib/budget_a.dart': _syntheticDiff(12000, 'budA-$pad'),
        'lib/budget_b.dart': _syntheticDiff(12000, 'budB-$pad'),
        'lib/budget_c.dart': _syntheticDiff(12000, 'budC-$pad'),
        'lib/budget_d.dart': _syntheticDiff(18000, 'budD'),
      };
      final fixture = WorkspaceFixture()
        ..omitSeedDiscussions = true
        ..versionDiffs = [
          for (final file in files.entries)
            _gitLabDiffItem(path: file.key, diff: file.value),
        ];
      addTearDown(fixture.api.close);
      await tester.pumpWidget(_fixturePage(fixture));
      await settleNetworkWidgets(tester);

      final entries = <int>[];
      for (final file in files.entries) {
        final firstRow = file.value.split('\n')[1].substring(1);
        await _openFile(tester, file.key, find.text(firstRow));
        final stats = debugDiffCacheStats(fixture.api);
        expect(stats.estimatedBytes, lessThanOrEqualTo(maxCacheBytes));
        expect(stats.parsedLines, lessThanOrEqualTo(maxCacheLines));
        entries.add(stats.entries);
        await tester.pageBack();
        await settleNetworkWidgets(tester);
      }
      // Two entries after B (A + B), still two after C (A evicted for bytes)
      // and after D (B evicted for lines).
      expect(entries, [1, 2, 2, 2]);
      final last = debugDiffCacheStats(fixture.api);
      expect(last.parsedLines, 12000 + 18000);
    });
  });

  testWidgets(
    'tapping commentable line opens editor and posts discussion with position',
    (tester) async {
      Map<String, dynamic>? postedDiscussion;

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/versions')) {
          return jsonResponse([
            {'id': 1, 'head_commit_sha': headSha},
          ]);
        }
        if (path.endsWith('/versions/1')) {
          return jsonResponse(sampleVersion);
        }
        if (path.endsWith('/projects/42/merge_requests/10') &&
            request.method == 'GET') {
          return jsonResponse({'sha': headSha});
        }
        if (path.endsWith('/projects/42/merge_requests/10/discussions') &&
            request.method == 'POST') {
          postedDiscussion = request.data is Map<String, dynamic>
              ? request.data as Map<String, dynamic>
              : null;
          return jsonResponse({
            'id': 'new-disc',
            'notes': <dynamic>[],
          }, status: 201);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReviewDiffPage(
              account: account,
              api: api,
              project: project,
              iid: 10,
              expectedSha: headSha,
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      // Open file
      await tester.tap(find.text('lib/sample.dart'));
      await settleNetworkWidgets(tester);

      // Tap on line "new_line2"
      await tester.tap(find.text('new_line2'));
      await settleNetworkWidgets(tester);

      // Editor should be open
      expect(find.text('對這一行留言'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'Looks good to me!');
      await tester.tap(find.text('儲存'));
      await settleNetworkWidgets(tester);

      expect(postedDiscussion, isNotNull);
      expect(postedDiscussion!['body'], 'Looks good to me!');
      final position = postedDiscussion!['position'] as Map<String, dynamic>;
      expect(position['position_type'], 'text');
      expect(position['base_sha'], baseSha);
      expect(position['head_sha'], headSha);
      expect(position['start_sha'], startSha);
      expect(position['new_path'], 'lib/sample.dart');
      expect(position['new_line'], 2);
    },
  );

  testWidgets(
    'Diff lines satisfy >= 48 dp tap target and top-aligned layout on 320 dp screen with 2.0x scale',
    (tester) async {
      const largeLineDiff = '''
@@ -1024,3 +1024,4 @@
 line1024
-old_line1025_with_very_long_content_that_will_wrap_to_multiple_lines_on_narrow_mobile_screen
+new_line1025_with_very_long_content_that_will_wrap_to_multiple_lines_on_narrow_mobile_screen
+new_line1026
 line1027
''';
      final largeVersion = {
        'id': 2,
        'head_commit_sha': headSha,
        'base_commit_sha': baseSha,
        'start_commit_sha': startSha,
        'diffs': [
          {
            'old_path': 'lib/sample_large.dart',
            'new_path': 'lib/sample_large.dart',
            'a_mode': '100644',
            'b_mode': '100644',
            'new_file': false,
            'renamed_file': false,
            'deleted_file': false,
            'diff': largeLineDiff,
          },
        ],
      };

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/versions')) {
          return jsonResponse([
            {'id': 2, 'head_commit_sha': headSha},
          ]);
        }
        if (path.endsWith('/versions/2')) {
          return jsonResponse(largeVersion);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2.0)),
            child: child!,
          ),
          home: Scaffold(
            body: ReviewDiffPage(
              account: account,
              api: api,
              project: project,
              iid: 10,
              expectedSha: headSha,
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('lib/sample_large.dart'));
      await settleNetworkWidgets(tester);

      expect(tester.takeException(), isNull);
      for (var i = 0; i < 4; i++) {
        final lineFinder = find.byKey(ValueKey('diff-line-$i'));
        expect(lineFinder, findsOneWidget);
        final size = tester.getSize(lineFinder);
        expect(size.height, greaterThanOrEqualTo(48.0));
      }
    },
  );
}
