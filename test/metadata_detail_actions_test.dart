import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/commit_page.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/resource_share.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;

const _branchSha = 'cccccccccccccccccccccccccccccccccccccccc';
const _tagSha = 'dddddddddddddddddddddddddddddddddddddddd';

String _apiPath(RequestOptions request) {
  final parts = request.uri.pathSegments;
  return parts.skip(parts.indexOf('v4') + 1).join('/');
}

Map<String, dynamic> _item(
  int iid,
  String title,
  String state, {
  bool mr = false,
}) => {
  'id': 5000 + iid,
  'iid': iid,
  'project_id': 42,
  'title': title,
  'state': state,
  'updated_at': '2026-09-19T08:00:00Z',
  if (mr) ...{'source_branch': 'feature/x', 'target_branch': 'main'},
};

final class _DetailFixture extends WorkspaceFixture {
  _DetailFixture({required this.kind, required this.rows, this.host});

  final MetadataKind kind;
  final List<Map<String, dynamic>> rows;
  final String? host;

  /// Responses by decoded API path; a [Completer] holds its response.
  final responses = <String, Object>{};

  late final _detailApi = testApi(
    adapter,
    host: host ?? 'https://example.com/gitlab',
  );
  @override
  GitLabApi get api => _detailApi;

  List<RequestOptions> requestsTo(String path) => [
    for (final request in adapter.requests)
      if (_apiPath(request) == path) request,
  ];

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = _apiPath(request);
    final metadataPath = switch (kind) {
      MetadataKind.branches ||
      MetadataKind.tags => 'projects/42/repository/${kind.name}',
      _ => 'projects/42/${kind.name}',
    };
    if (path == metadataPath) return jsonResponse(rows);
    final response = responses[path];
    if (response is Completer<ResponseBody>) return response.future;
    if (response != null) return jsonResponse(response);
    if (path == 'projects/42/repository/commits/$_branchSha') {
      return jsonResponse({
        'id': _branchSha,
        'short_id': 'cccccccc',
        'title': 'Branch head commit',
        'author_name': 'Developer',
        'committed_date': '2026-09-19T08:00:00Z',
        'parent_ids': <String>[],
      });
    }
    if (path == 'projects/42/repository/commits/$_branchSha/diff') {
      return jsonResponse(<Object>[]);
    }
    return super.respond(request);
  }
}

Widget _page(_DetailFixture fixture) => workspaceHost(
  MetadataPage(
    account: fixture.account,
    api: fixture.api,
    project: fixture.project,
    kind: fixture.kind,
  ),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await settleNetworkWidgets(tester);
}

Future<void> _openRow(WidgetTester tester, String title) async {
  await settleNetworkWidgets(tester);
  await _tap(tester, find.text(title));
}

Finder _detailRow(String key) => find.byKey(ValueKey('metadata-detail-$key'));

final class _OwnerHarness extends StatefulWidget {
  const _OwnerHarness({super.key, required this.first, required this.second});
  final _DetailFixture first;
  final _DetailFixture second;
  @override
  State<_OwnerHarness> createState() => _OwnerHarnessState();
}

final class _OwnerHarnessState extends State<_OwnerHarness> {
  bool replaced = false;
  void replace() => setState(() => replaced = true);
  @override
  Widget build(BuildContext context) {
    final fixture = replaced ? widget.second : widget.first;
    return MetadataPage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
      kind: fixture.kind,
    );
  }
}

Map<String, dynamic> _branch() => {
  'name': 'feature/x',
  'default': true,
  'protected': true,
  'commit': {
    'id': _branchSha,
    'short_id': 'cccccccc',
    'title': 'Branch head commit',
  },
};

Map<String, dynamic> _tag({bool release = true}) => {
  'name': 'test/v0.1',
  'message': 'Annotated tag message',
  'protected': false,
  'commit': {'id': _tagSha, 'title': 'Tagged commit'},
  if (release)
    'release': {'tag_name': 'test/v0.1', 'description': 'Short notes'},
};

void main() {
  testWidgets(
    'a branch detail keeps its chips and its commit opens the commit page',
    (tester) async {
      final fixture = _DetailFixture(
        kind: MetadataKind.branches,
        rows: [_branch()],
      );
      addTearDown(fixture.api.close);
      await tester.pumpWidget(_page(fixture));
      await _openRow(tester, 'feature/x');

      expect(find.text('尚未填寫說明。'), findsNothing);
      expect(find.text('預設'), findsOneWidget);
      expect(find.text('受保護'), findsOneWidget);
      expect(
        find.descendant(
          of: _detailRow('commit'),
          matching: find.text('Branch head commit'),
        ),
        findsOneWidget,
      );

      await _tap(tester, _detailRow('commit'));
      final page = tester.widget<CommitDetailPage>(
        find.byType(CommitDetailPage),
      );
      expect(page.sha, _branchSha);
      expect(page.project.id, 42);
      expect(
        fixture.requestsTo('projects/42/repository/commits/$_branchSha'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'browsing a branch reads the tree at its head SHA without re-resolving',
    (tester) async {
      final fixture = _DetailFixture(
        kind: MetadataKind.branches,
        rows: [_branch()],
      );
      addTearDown(fixture.api.close);
      await tester.pumpWidget(_page(fixture));
      await _openRow(tester, 'feature/x');
      expect(find.text('固定於 cccccccc'), findsOneWidget);

      await _tap(tester, _detailRow('browse'));
      expect(find.text('lib'), findsOneWidget);
      final trees = fixture.requestsTo('projects/42/repository/tree');
      expect(trees, isNotEmpty);
      for (final request in trees) {
        expect(request.uri.queryParameters['ref'], _branchSha);
      }
      expect(
        fixture.adapter.requests.where(
          (r) => _apiPath(r).startsWith('projects/42/repository/branches/'),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a tag detail shows its message and opens its release detail', (
    tester,
  ) async {
    final fixture = _DetailFixture(kind: MetadataKind.tags, rows: [_tag()]);
    fixture.responses['projects/42/releases/test/v0.1'] = {
      'tag_name': 'test/v0.1',
      'name': 'Release from tag',
      'description': 'Full release notes',
      'released_at': '2026-09-19T08:00:00Z',
    };
    addTearDown(fixture.api.close);
    await tester.pumpWidget(_page(fixture));
    await _openRow(tester, 'test/v0.1');

    expect(find.text('Annotated tag message'), findsOneWidget);
    expect(find.text('尚未填寫說明。'), findsNothing);
    expect(_detailRow('browse'), findsOneWidget);
    expect(find.byType(ResourceShareButton), findsNothing);

    await _tap(tester, _detailRow('release'));
    final reads = fixture.requestsTo('projects/42/releases/test/v0.1');
    expect(reads, hasLength(1));
    expect(
      reads.single.uri.path,
      endsWith('/projects/42/releases/test%2Fv0.1'),
    );
    expect(find.text('Release from tag'), findsOneWidget);
    expect(find.text('Full release notes'), findsOneWidget);
    final share = tester.widget<ResourceShareButton>(
      find.byType(ResourceShareButton),
    );
    expect(
      share.uri.toString(),
      'https://example.com/gitlab/studio/mobile-workspace/-/releases/test%2Fv0.1',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tag without a release offers no release row', (tester) async {
    final fixture = _DetailFixture(
      kind: MetadataKind.tags,
      rows: [_tag(release: false)],
    );
    addTearDown(fixture.api.close);
    await tester.pumpWidget(_page(fixture));
    await _openRow(tester, 'test/v0.1');
    expect(_detailRow('commit'), findsOneWidget);
    expect(_detailRow('release'), findsNothing);
  });

  testWidgets(
    'an unreadable tag release stays on the tag as an ambiguous failure',
    (tester) async {
      final fixture = _DetailFixture(kind: MetadataKind.tags, rows: [_tag()]);
      addTearDown(fixture.api.close);
      await tester.pumpWidget(_page(fixture));
      await _openRow(tester, 'test/v0.1');
      await _tap(tester, _detailRow('release'));

      expect(find.byType(FailureNotice), findsOneWidget);
      expect(
        find.text('目標：studio/mobile-workspace · Release test/v0.1'),
        findsOneWidget,
      );
      expect(find.text('App 帳號：@developer'), findsOneWidget);
      expect(find.text('切換帳號'), findsOneWidget);
      expect(find.text('Annotated tag message'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a milestone lists its issues and merge requests', (
    tester,
  ) async {
    final fixture = _DetailFixture(
      kind: MetadataKind.milestones,
      rows: [
        {'id': 901, 'iid': 7, 'title': 'Sprint seven', 'state': 'active'},
      ],
    );
    fixture.responses['projects/42/milestones/901/issues'] = [
      _item(3, 'Milestone open issue', 'opened'),
      _item(4, 'Milestone closed issue', 'closed'),
    ];
    fixture.responses['projects/42/milestones/901/merge_requests'] = [
      _item(12, 'Milestone merged request', 'merged', mr: true),
    ];
    fixture.issues[3] = fixture.issue(3, 'Milestone open issue');
    addTearDown(fixture.api.close);
    await tester.pumpWidget(_page(fixture));
    await _openRow(tester, 'Sprint seven');

    await _tap(tester, _detailRow('issues'));
    final issues = fixture.requestsTo('projects/42/milestones/901/issues');
    expect(issues, hasLength(1));
    expect(issues.single.uri.queryParameters.keys, isNot(contains('labels')));
    expect(issues.single.uri.queryParameters['with_labels_details'], 'true');
    Finder cardOf(String title) =>
        find.ancestor(of: find.text(title), matching: find.byType(EntityCard));
    expect(
      find.descendant(
        of: cardOf('Milestone open issue'),
        matching: find.text('開啟中'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: cardOf('Milestone closed issue'),
        matching: find.text('已關閉'),
      ),
      findsOneWidget,
    );

    await _tap(tester, find.text('Milestone open issue'));
    final item = tester.widget<WorkItemPage>(find.byType(WorkItemPage));
    expect(item.resource, 'issues');
    expect(item.iid, 3);
    expect(item.project.id, 42);

    Navigator.of(tester.element(find.byType(WorkItemPage))).pop();
    await settleNetworkWidgets(tester);
    Navigator.of(tester.element(find.text('Milestone open issue'))).pop();
    await settleNetworkWidgets(tester);
    await _tap(tester, _detailRow('merge_requests'));
    expect(
      fixture.requestsTo('projects/42/milestones/901/merge_requests'),
      hasLength(1),
    );
    expect(
      find.descendant(
        of: cardOf('Milestone merged request'),
        matching: find.text('已合併'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a label lists the open issues and merge requests carrying it', (
    tester,
  ) async {
    final fixture = _DetailFixture(
      kind: MetadataKind.labels,
      rows: [
        {
          'id': 1,
          'name': 'bug::critical',
          'color': '#d9534f',
          'description': 'Broken things',
          'open_issues_count': 2,
        },
      ],
    );
    fixture.responses['projects/42/issues'] = [
      _item(3, 'Labelled issue', 'opened'),
    ];
    fixture.responses['projects/42/merge_requests'] = [
      _item(12, 'Labelled request', 'opened', mr: true),
    ];
    addTearDown(fixture.api.close);
    await tester.pumpWidget(_page(fixture));
    await _openRow(tester, 'bug::critical');
    expect(find.text('Broken things'), findsOneWidget);

    await _tap(tester, _detailRow('issues'));
    final issues = fixture.requestsTo('projects/42/issues');
    expect(issues, hasLength(1));
    expect(issues.single.uri.queryParameters['labels'], 'bug::critical');
    expect(issues.single.uri.queryParameters['state'], 'opened');
    expect(issues.single.uri.queryParameters['with_labels_details'], 'true');
    expect(find.text('Labelled issue'), findsOneWidget);

    Navigator.of(tester.element(find.text('Labelled issue'))).pop();
    await settleNetworkWidgets(tester);
    await _tap(tester, _detailRow('merge_requests'));
    final requests = fixture.requestsTo('projects/42/merge_requests');
    expect(requests, hasLength(1));
    expect(requests.single.uri.queryParameters['labels'], 'bug::critical');
    expect(requests.single.uri.queryParameters['state'], 'opened');
    expect(find.text('Labelled request'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<SessionController> sessionHost(
    WidgetTester tester,
    _DetailFixture fixture,
  ) async {
    final store = MemoryAccountStore();
    final session = SessionController(store, readCache: store.readCache)
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    addTearDown(fixture.api.close);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _page(fixture),
      ),
    );
    return session;
  }

  testWidgets('ending the session hides an open milestone list at once', (
    tester,
  ) async {
    final fixture = _DetailFixture(
      kind: MetadataKind.milestones,
      rows: [
        {'id': 901, 'iid': 7, 'title': 'Session sprint', 'state': 'active'},
      ],
    );
    fixture.responses['projects/42/milestones/901/issues'] = [
      _item(3, 'Session private issue', 'opened'),
    ];
    final session = await sessionHost(tester, fixture);
    await _openRow(tester, 'Session sprint');
    await _tap(tester, _detailRow('issues'));
    expect(find.text('Session private issue'), findsOneWidget);

    await session.endSession();
    await tester.pump();
    expect(find.text('Session private issue'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Session private issue'), findsNothing);
    expect(find.text('Session sprint'), findsNothing);
    expect(_detailRow('issues'), findsNothing);
    expect(tester.takeException(), isNull);
    await pumpUntilComplete(tester, session.readCache.quiesced);
  });

  testWidgets(
    'a label list page landing after the session ends is never shown',
    (tester) async {
      final fixture = _DetailFixture(
        kind: MetadataKind.labels,
        rows: [
          {'id': 1, 'name': 'session-label', 'color': '#d9534f'},
        ],
      );
      final held = Completer<ResponseBody>();
      fixture.responses['projects/42/merge_requests'] = held;
      final session = await sessionHost(tester, fixture);
      await _openRow(tester, 'session-label');
      await tester.ensureVisible(_detailRow('merge_requests'));
      await tester.tap(_detailRow('merge_requests'));
      await pumpUntil(
        tester,
        () => fixture.requestsTo('projects/42/merge_requests').isNotEmpty,
        description: 'label merge requests requested',
      );

      await session.endSession();
      held.complete(
        jsonResponse([_item(12, 'Late private request', 'opened', mr: true)]),
      );
      await settleNetworkWidgets(tester);
      expect(find.text('Late private request'), findsNothing);
      expect(find.text('session-label'), findsNothing);
      expect(tester.takeException(), isNull);
      await pumpUntilComplete(tester, session.readCache.quiesced);
    },
  );

  testWidgets(
    'replacing the owner dismisses files opened from a branch detail',
    (tester) async {
      final first = _DetailFixture(
        kind: MetadataKind.branches,
        rows: [_branch()],
      );
      final second = _DetailFixture(
        kind: MetadataKind.branches,
        rows: [
          {
            'name': 'other',
            'commit': {'id': _tagSha, 'title': 'Other head'},
          },
        ],
        host: 'https://next.example/gitlab',
      );
      addTearDown(first.api.close);
      addTearDown(second.api.close);
      final key = GlobalKey<_OwnerHarnessState>();
      await tester.pumpWidget(
        workspaceHost(_OwnerHarness(key: key, first: first, second: second)),
      );
      await _openRow(tester, 'feature/x');
      await _tap(tester, _detailRow('browse'));
      expect(find.text('lib'), findsOneWidget);

      key.currentState!.replace();
      await settleNetworkWidgets(tester);
      expect(find.text('lib'), findsNothing);
      expect(_detailRow('browse'), findsNothing);
      expect(find.text('other'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
