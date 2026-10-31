import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/project_analytics_page.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

Account _account(GitLabApi api, {int user = 7}) => Account(
  instance: api.instance,
  user: GitLabUser(id: user, username: 'user$user', name: 'User $user'),
  token: 'synthetic-test-token',
);
Project _project([int id = 42, String? branch = 'main']) => Project.fromJson({
  ...projectJson(id),
  'default_branch': branch,
  'path_with_namespace': 'group/project-$id',
});

Widget _host(Widget child, {double scale = 1}) => MaterialApp(
  theme: appTheme(Brightness.light),
  locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: child,
);

Map<String, Object?> _contributor(String name) => {
  'name': name,
  'email': '$name@private.example',
  'commits': 7,
  'additions': 20,
  'deletions': 3,
};

final class _AnalyticsBackend {
  _AnalyticsBackend({
    this.delayFirstContributor,
    this.failSecondCommitPage = false,
    this.pipelineUnsupported = false,
    this.coverageForbidden = false,
    this.languageForbidden = false,
    this.partialCounts = false,
    this.emptyPipelines = false,
    this.contributorCount = 2,
    this.mixedCommitStats = false,
    this.secondCommitStatus,
    this.differentPipelineDates = false,
  });
  final Completer<ResponseBody>? delayFirstContributor;
  final bool failSecondCommitPage,
      pipelineUnsupported,
      coverageForbidden,
      languageForbidden,
      partialCounts,
      emptyPipelines,
      mixedCommitStats,
      differentPipelineDates;
  final int contributorCount;
  final int? secondCommitStatus;
  /// Holds the languages read until completed (#56 part 2).
  Completer<void>? holdLanguages;
  bool failLanguages = false;
  late final adapter = FakeAdapter(respond);
  late final api = testApi(adapter);
  int contributorReads = 0;

  ResponseBody _graphql(RequestOptions request) {
    final body = request.data as Map<String, dynamic>;
    final query = body['query'] as String;
    if (query.contains('MobilePipelineAnalytics')) {
      if (pipelineUnsupported) {
        return jsonResponse({
          'data': {'project': null},
          'errors': [
            {
              'message': 'undefined',
              'extensions': {'code': 'undefinedField'},
            },
          ],
        });
      }
      final variables = body['variables'] as Map<String, dynamic>;
      final from = DateTime.parse(
        variables['fromTime'] as String,
      ).add(const Duration(days: 1)).toIso8601String().substring(0, 10);
      return jsonResponse({
        'data': {
          'project': {
            'id': 'gid://gitlab/Project/42',
            'pipelineAnalytics': {
              'aggregate': emptyPipelines
                  ? null
                  : {
                      'label': null,
                      'all': 20,
                      if (!partialCounts) 'success': 8,
                      'failed': 2,
                      'other': 10,
                      'durationStatistics': {'p50': 2.75, 'p95': 11.5},
                    },
              'timeSeries': emptyPipelines
                  ? <Object?>[]
                  : <Object?>[
                      {
                        'label': from,
                        'all': 20,
                        'success': 8,
                        'failed': 2,
                        'other': 10,
                        'durationStatistics': {'p50': 1.25, 'p95': 9.5},
                      },
                      {
                        'label': differentPipelineDates
                            ? DateTime.parse(from)
                                  .add(const Duration(days: 3))
                                  .toIso8601String()
                                  .substring(0, 10)
                            : from,
                        'all': 0,
                        if (!partialCounts) 'success': 0,
                        'failed': 0,
                        'other': 0,
                        'durationStatistics': {'p50': null, 'p95': 0},
                      },
                    ],
            },
          },
        },
      });
    }
    if (coverageForbidden) {
      return jsonResponse({'message': 'forbidden'}, status: 403);
    }
    return jsonResponse({
      'data': {
        'project': {
          'id': 'gid://gitlab/Project/42',
          'codeCoverageSummary': {
            'averageCoverage': 87.5,
            'coverageCount': 0,
            'lastUpdatedOn': '2026-10-02',
          },
        },
      },
    });
  }

  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = request.uri.path;
    if (path.endsWith('/api/graphql')) return _graphql(request);
    if (path.endsWith('/repository/contributors')) {
      contributorReads++;
      if (delayFirstContributor != null && contributorReads == 1) {
        return delayFirstContributor!.future;
      }
      final ref = request.uri.queryParameters['ref'];
      return jsonResponse([
        for (var index = 0; index < contributorCount; index++)
          _contributor(
            ref == 'release/2'
                ? index == 0
                      ? 'New Author'
                      : 'Another Author $index'
                : contributorCount == 2
                ? 'Same Name'
                : 'Author $index',
          ),
      ]);
    }
    if (path.endsWith('/repository/commits')) {
      if (request.uri.queryParameters['page'] == '2') {
        if (secondCommitStatus != null) {
          return jsonResponse({
            'message': 'failed',
          }, status: secondCommitStatus!);
        }
        if (failSecondCommitPage) {
          return jsonResponse({'message': 'failed'}, status: 500);
        }
        return jsonResponse([_commit(request, 'c' * 40, parents: 1)]);
      }
      return jsonResponse(
        [
          _commit(request, 'a' * 40, parents: 1),
          if (mixedCommitStats)
            _commit(request, 'd' * 40, parents: 1, includeStats: false),
          _commit(request, 'b' * 40, parents: 2),
        ],
        headers: {
          'x-next-page': ['2'],
        },
      );
    }
    if (path.endsWith('/languages')) {
      ResponseBody answer() {
        if (languageForbidden) {
          return jsonResponse({'message': 'forbidden'}, status: 403);
        }
        if (failLanguages) {
          return jsonResponse({'message': 'failed'}, status: 500);
        }
        return jsonResponse({'Dart': 100});
      }

      if (holdLanguages case final gate?) {
        return gate.future.then((_) => answer());
      }
      return answer();
    }
    if (path.endsWith('/starrers')) return jsonResponse([]);
    if (RegExp(r'/projects/\d+$').hasMatch(path)) {
      final id = int.parse(path.split('/').last);
      return jsonResponse({...projectJson(id), 'star_count': 0});
    }
    return jsonResponse({'message': 'not found'}, status: 404);
  }

  Map<String, Object?> _commit(
    RequestOptions request,
    String id, {
    required int parents,
    bool includeStats = true,
  }) {
    final from = DateTime.parse(
      request.uri.queryParameters['since']!,
    ).add(const Duration(days: 1));
    return {
      'id': id,
      'committed_date': from.toIso8601String(),
      'parent_ids': [for (var i = 0; i < parents; i++) '${i + 1}' * 40],
      if (includeStats) 'stats': {'additions': 4, 'deletions': 2},
    };
  }
}

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(Tab, label));
  await settleNetworkWidgets(tester);
}

Future<void> _scrollActive(WidgetTester tester, [double distance = 600]) async {
  final scroll = find.byType(CustomScrollView).hitTestable();
  await tester.drag(scroll, Offset(0, -distance));
  await tester.pumpAndSettle();
}

void main() {
  // #56 part 2: the languages and coverage cards' first read is a compact
  // skeleton under the tab's own live region; a refresh keeps the cards, and
  // a retry after a failed first read shows the skeleton again.
  testWidgets('repository cards show compact skeletons only on a first read', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final backend = _AnalyticsBackend()..holdLanguages = Completer<void>();
    addTearDown(backend.api.close);
    Widget page() => _host(
      ProjectAnalyticsPage(
        account: _account(backend.api),
        api: backend.api,
        project: _project(),
      ),
    );
    await tester.pumpWidget(page());
    await settleNetworkWidgets(tester);
    await _openTab(tester, '儲存庫');
    // Not _scrollActive: it settles, and a shimmer never does.
    await tester.drag(
      find.byType(CustomScrollView).hitTestable(),
      const Offset(0, -600),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final loading = find.byKey(const ValueKey('analytics-languages-loading'));
    expect(loading, findsOneWidget);
    expect(
      find.descendant(of: loading, matching: find.byType(ChipsSkeleton)),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // A card inside the loaded tab does not announce on its own.
    expect(find.bySemanticsLabel('正在載入'), findsNothing);

    backend.holdLanguages!.complete();
    backend.holdLanguages = null;
    await settleNetworkWidgets(tester);
    expect(loading, findsNothing);
    expect(find.byKey(const ValueKey('analytics-languages')), findsOneWidget);
    expect(find.byKey(const ValueKey('coverage-summary')), findsOneWidget);

    // A refresh keeps both cards while they are read again.
    backend.holdLanguages = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('analytics-refresh')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(loading, findsNothing);
    expect(
      find.byKey(const ValueKey('coverage-summary-loading')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('analytics-languages')), findsOneWidget);
    backend.holdLanguages!.complete();
    backend.holdLanguages = null;
    await settleNetworkWidgets(tester);
    expect(find.byKey(const ValueKey('analytics-languages')), findsOneWidget);

    // A failed first read, then retry: the skeleton again.
    await tester.pumpWidget(const SizedBox());
    backend.failLanguages = true;
    await tester.pumpWidget(page());
    await settleNetworkWidgets(tester);
    await _openTab(tester, '儲存庫');
    await tester.drag(
      find.byType(CustomScrollView).hitTestable(),
      const Offset(0, -600),
    );
    await settleNetworkWidgets(tester);
    expect(loading, findsNothing);
    final notice = find.byType(FailureNotice);
    expect(notice, findsOneWidget);
    backend
      ..failLanguages = false
      ..holdLanguages = Completer<void>();
    final retry = find.descendant(
      of: notice,
      matching: find.byIcon(Icons.refresh),
    );
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pump();
    expect(loading, findsOneWidget);
    backend.holdLanguages!.complete();
    backend.holdLanguages = null;
    await settleNetworkWidgets(tester);
    expect(loading, findsNothing);
    expect(find.byKey(const ValueKey('analytics-languages')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets(
    'loads only active tab and never exposes contributor email or merges equal names',
    (tester) async {
      final backend = _AnalyticsBackend();
      addTearDown(backend.api.close);
      await tester.pumpWidget(
        _host(
          ProjectAnalyticsPage(
            account: _account(backend.api),
            api: backend.api,
            project: _project(),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.text('Same Name'), findsNWidgets(2));
      expect(find.textContaining('@private.example'), findsNothing);
      expect(find.textContaining('日期範圍不適用'), findsOneWidget);
      expect(
        backend.adapter.requests.where(
          (r) => r.uri.path.endsWith('/repository/commits'),
        ),
        isEmpty,
      );
      expect(
        backend.adapter.requests.where(
          (r) => r.uri.path.endsWith('/api/graphql'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'ref apply clears stale contributor data and rejects delayed old response',
    (tester) async {
      final delayed = Completer<ResponseBody>();
      final backend = _AnalyticsBackend(delayFirstContributor: delayed);
      addTearDown(backend.api.close);
      await tester.pumpWidget(
        _host(
          ProjectAnalyticsPage(
            account: _account(backend.api),
            api: backend.api,
            project: _project(),
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('analytics-ref')),
        'release/2',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await pumpUntil(
        tester,
        () => backend.contributorReads == 2,
        description: 'new ref contributor request',
      );
      await settleNetworkWidgets(tester);
      expect(find.text('New Author'), findsOneWidget);
      delayed.complete(jsonResponse([_contributor('Old Author')]));
      await settleNetworkWidgets(tester);
      expect(find.text('Old Author'), findsNothing);
      final refs = backend.adapter.requests
          .where((r) => r.uri.path.endsWith('/repository/contributors'))
          .map((r) => r.uri.queryParameters['ref'])
          .toList();
      expect(refs, ['main', 'release/2']);
    },
  );

  testWidgets(
    'repository excludes merge commits and keeps page one after page two failure',
    (tester) async {
      final backend = _AnalyticsBackend(failSecondCommitPage: true);
      addTearDown(backend.api.close);
      await tester.pumpWidget(
        _host(
          ProjectAnalyticsPage(
            account: _account(backend.api),
            api: backend.api,
            project: _project(),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      await _openTab(tester, '儲存庫');
      expect(find.textContaining('已載入 2 / 2000'), findsOneWidget);
      expect(find.textContaining('尚有更多'), findsOneWidget);
      expect(find.byKey(const ValueKey('activity-')), findsNothing);
      expect(find.text('+4 / -2'), findsOneWidget);
      final firstRequest = backend.adapter.requests
          .where((request) => request.uri.path.endsWith('/repository/commits'))
          .first;
      final firstWindow = (
        firstRequest.uri.queryParameters['since'],
        firstRequest.uri.queryParameters['until'],
      );
      await tester.tap(find.byKey(const ValueKey('repository-load-more')));
      await settleNetworkWidgets(tester);
      expect(find.text('+4 / -2'), findsOneWidget);
      expect(find.text('GitLab 暫時無法回應'), findsOneWidget);
      final secondRequest = backend.adapter.requests
          .where((request) => request.uri.path.endsWith('/repository/commits'))
          .last;
      expect((
        secondRequest.uri.queryParameters['since'],
        secondRequest.uri.queryParameters['until'],
      ), firstWindow);
    },
  );

  testWidgets(
    'CI preserves null versus zero and computes exact success ratio without a fabricated median',
    (tester) async {
      final backend = _AnalyticsBackend();
      addTearDown(backend.api.close);
      await tester.pumpWidget(
        _host(
          ProjectAnalyticsPage(
            account: _account(backend.api),
            api: backend.api,
            project: _project(),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      await _openTab(tester, 'CI');
      expect(find.textContaining('80.0%'), findsOneWidget);
      expect(find.text('p50 1.25 秒'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('pipeline-bucket-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('p50 —'), findsOneWidget);
      expect(find.text('全部 0'), findsOneWidget);
      expect(find.textContaining('整體 p50 2.75 秒'), findsOneWidget);
      await _openTab(tester, '儲存庫');
      await _scrollActive(tester, 400);
      expect(find.textContaining('樣本 0'), findsOneWidget);
      expect(find.text('Dart 100.0%'), findsOneWidget);
    },
  );

  testWidgets('page two 404 keeps rows and shows account resource actions', (
    tester,
  ) async {
    final backend = _AnalyticsBackend(secondCommitStatus: 404);
    addTearDown(backend.api.close);
    await tester.pumpWidget(
      _host(
        ProjectAnalyticsPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await _openTab(tester, '儲存庫');
    await tester.tap(find.byKey(const ValueKey('repository-load-more')));
    await settleNetworkWidgets(tester);
    expect(find.text('+4 / -2'), findsOneWidget);
    expect(find.text('實例：https://example.com/gitlab'), findsOneWidget);
    expect(find.text('App 帳號：@user7'), findsOneWidget);
    expect(find.textContaining('儲存庫活動後續頁面'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
  });

  testWidgets(
    'unsupported pipeline and independent coverage failure preserve language section',
    (tester) async {
      final backend = _AnalyticsBackend(
        pipelineUnsupported: true,
        coverageForbidden: true,
      );
      addTearDown(backend.api.close);
      await tester.pumpWidget(
        _host(
          ProjectAnalyticsPage(
            account: _account(backend.api),
            api: backend.api,
            project: _project(),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      await _openTab(tester, 'CI');
      expect(find.text('實例未提供CI/CD 分析'), findsOneWidget);
      await _openTab(tester, '儲存庫');
      await _scrollActive(tester);
      expect(find.text('沒有操作權限'), findsOneWidget);
      expect(find.text('Dart 100.0%'), findsOneWidget);
    },
  );

  testWidgets(
    'partial counts suppress ratio instead of treating null as zero',
    (tester) async {
      final backend = _AnalyticsBackend(partialCounts: true);
      addTearDown(backend.api.close);
      await tester.pumpWidget(
        _host(
          ProjectAnalyticsPage(
            account: _account(backend.api),
            api: backend.api,
            project: _project(),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      await _openTab(tester, 'CI');
      expect(find.text('計數未完整，無法計算'), findsOneWidget);
      expect(find.textContaining('80.0%'), findsNothing);
    },
  );

  testWidgets('empty pipeline and language failure preserve coverage section', (
    tester,
  ) async {
    final backend = _AnalyticsBackend(
      emptyPipelines: true,
      languageForbidden: true,
    );
    addTearDown(backend.api.close);
    await tester.pumpWidget(
      _host(
        ProjectAnalyticsPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await _openTab(tester, 'CI');
    expect(find.text('這段期間沒有 Pipeline 分析資料'), findsOneWidget);
    await _openTab(tester, '儲存庫');
    await _scrollActive(tester, 250);
    expect(find.textContaining('平均 87.5%'), findsOneWidget);
    await _scrollActive(tester);
    expect(find.text('沒有操作權限'), findsOneWidget);
  });

  testWidgets(
    'same-account API and project replacement rejects delayed old data',
    (tester) async {
      final delayed = Completer<ResponseBody>();
      final old = _AnalyticsBackend(delayFirstContributor: delayed),
          current = _AnalyticsBackend();
      addTearDown(old.api.close);
      addTearDown(current.api.close);
      late StateSetter update;
      var api = old.api, project = _project(), user = 7;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ProjectAnalyticsPage(
                account: _account(api, user: user),
                api: api,
                project: project,
              );
            },
          ),
        ),
      );
      await tester.pump();
      update(() {
        api = current.api;
        project = _project(43);
        user = 8;
      });
      await settleNetworkWidgets(tester);
      expect(find.text('Same Name'), findsNWidgets(2));
      delayed.complete(jsonResponse([_contributor('Old Account Data')]));
      await settleNetworkWidgets(tester);
      expect(find.text('Old Account Data'), findsNothing);
      expect(find.text('group/project-43'), findsOneWidget);
    },
  );

  testWidgets('source apply only reloads pipeline and sends verified enum', (
    tester,
  ) async {
    final backend = _AnalyticsBackend();
    addTearDown(backend.api.close);
    await tester.pumpWidget(
      _host(
        ProjectAnalyticsPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await _openTab(tester, '儲存庫');
    await _openTab(tester, 'CI');
    final contributorsBefore = backend.adapter.requests
        .where(
          (request) => request.uri.path.endsWith('/repository/contributors'),
        )
        .length;
    final commitsBefore = backend.adapter.requests
        .where((request) => request.uri.path.endsWith('/repository/commits'))
        .length;
    await tester.tap(find.byKey(const ValueKey('analytics-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Schedule').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('analytics-apply')));
    await settleNetworkWidgets(tester);
    expect(
      backend.adapter.requests
          .where(
            (request) => request.uri.path.endsWith('/repository/contributors'),
          )
          .length,
      contributorsBefore,
    );
    expect(
      backend.adapter.requests
          .where((request) => request.uri.path.endsWith('/repository/commits'))
          .length,
      commitsBefore,
    );
    final pipelineRequests = backend.adapter.requests.where((request) {
      if (!request.uri.path.endsWith('/api/graphql')) return false;
      final data = request.data;
      return data is Map &&
          '${data['query']}'.contains('MobilePipelineAnalytics');
    }).toList();
    expect(pipelineRequests, hasLength(2));
    expect(
      (pipelineRequests.last.data as Map)['variables']['source'],
      'SCHEDULE',
    );
  });

  testWidgets(
    'branchless project is explicit and 2x text fits phone and tablet widths',
    (tester) async {
      final backend = _AnalyticsBackend();
      addTearDown(backend.api.close);
      for (final width in <double>[320, 412, 840]) {
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = Size(width * 2, 1800);
        await tester.pumpWidget(
          _host(
            ProjectAnalyticsPage(
              key: ValueKey(width),
              account: _account(backend.api),
              api: backend.api,
              project: _project(42, null),
            ),
            scale: 2,
          ),
        );
        await settleNetworkWidgets(tester);
        expect(find.textContaining('伺服器預設 ref'), findsOneWidget);
        await _openTab(tester, '儲存庫');
        expect(
          tester
              .getSize(find.byKey(const ValueKey('analytics-range-30')))
              .height,
          greaterThanOrEqualTo(48),
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'More entry owns analytics route and dismisses it on project replacement',
    (tester) async {
      final first = _AnalyticsBackend(), second = _AnalyticsBackend();
      addTearDown(first.api.close);
      addTearDown(second.api.close);
      late StateSetter update;
      var api = first.api, project = _project();
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ProjectMoreTab(
                account: _account(api),
                api: api,
                project: project,
                onChanged: (_) {},
              );
            },
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      await tester.ensureVisible(find.text('專案分析'));
      await tester.tap(find.text('專案分析'));
      await settleNetworkWidgets(tester);
      expect(find.byType(ProjectAnalyticsPage), findsOneWidget);
      update(() {
        api = second.api;
        project = _project(43);
      });
      await settleNetworkWidgets(tester);
      expect(find.byType(ProjectAnalyticsPage), findsNothing);
    },
  );

  testWidgets('CI controls remain reachable with 2x text and keyboard', (
    tester,
  ) async {
    final backend = _AnalyticsBackend();
    addTearDown(backend.api.close);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(640, 1280);
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 34);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      tester.view.resetViewInsets();
      tester.view.resetPadding();
      tester.view.resetViewPadding();
    });
    await tester.pumpWidget(
      _host(
        ProjectAnalyticsPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
        ),
        scale: 2,
      ),
    );
    await settleNetworkWidgets(tester);
    await _openTab(tester, 'CI');
    await tester.tap(find.byKey(const ValueKey('analytics-ref')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('analytics-controls')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('analytics-apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('analytics-ref')), findsOneWidget);
    expect(find.byKey(const ValueKey('analytics-apply')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('analytics-apply')));
    await tester.pump();
    final refEditor = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('analytics-ref')),
        matching: find.byType(EditableText),
      ),
    );
    expect(refEditor.focusNode.hasFocus, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening the keyboard preserves ref focus and input', (
    tester,
  ) async {
    final backend = _AnalyticsBackend();
    addTearDown(backend.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      tester.view.resetViewInsets();
    });
    await tester.pumpWidget(
      _host(
        ProjectAnalyticsPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await _openTab(tester, 'CI');
    final editor = find.descendant(
      of: find.byKey(const ValueKey('analytics-ref')),
      matching: find.byType(EditableText),
    );
    await tester.tap(find.byKey(const ValueKey('analytics-ref')));
    await tester.pump();
    expect(tester.widget<EditableText>(editor).focusNode.hasFocus, isTrue);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(editor).focusNode.hasFocus, isTrue);
    await tester.enterText(
      find.byKey(const ValueKey('analytics-ref')),
      'release/2',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleNetworkWidgets(tester);
    expect(tester.widget<EditableText>(editor).controller.text, 'release/2');
    expect(tester.widget<EditableText>(editor).focusNode.hasFocus, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CI shows the latest date first', (tester) async {
    final backend = _AnalyticsBackend(differentPipelineDates: true);
    addTearDown(backend.api.close);
    await tester.pumpWidget(
      _host(
        ProjectAnalyticsPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await _openTab(tester, 'CI');
    final request = backend.adapter.requests.singleWhere(
      (r) =>
          r.uri.path.endsWith('/api/graphql') &&
          (r.data as Map)['query'].toString().contains(
            'MobilePipelineAnalytics',
          ),
    );
    final from =
        ((request.data as Map)['variables'] as Map)['fromTime'] as String;
    final latest = DateTime.parse(
      from,
    ).add(const Duration(days: 4)).toIso8601String().substring(0, 10);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('pipeline-bucket-0')),
        matching: find.text(latest),
      ),
      findsOneWidget,
    );
  });

  testWidgets('2x text leaves meaningful space for CI results', (tester) async {
    final backend = _AnalyticsBackend();
    addTearDown(backend.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      _host(
        ProjectAnalyticsPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
        ),
        scale: 2,
      ),
    );
    await settleNetworkWidgets(tester);
    await _openTab(tester, 'CI');
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('pipeline-summary'))).dy,
      lessThan(915 * .65),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('short landscape keeps tabs and results without overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 320);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 16);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      tester.view.resetPadding();
      tester.view.resetViewPadding();
    });
    for (final scale in [1.0, 2.0]) {
      final backend = _AnalyticsBackend();
      addTearDown(backend.api.close);
      await tester.pumpWidget(
        _host(
          ProjectAnalyticsPage(
            key: ValueKey(scale),
            account: _account(backend.api),
            api: backend.api,
            project: _project(),
          ),
          scale: scale,
        ),
      );
      await settleNetworkWidgets(tester);
      await _openTab(tester, 'CI');
      expect(find.widgetWithText(Tab, 'CI').hitTestable(), findsOneWidget);
      expect(find.byKey(const ValueKey('pipeline-summary')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('long contributor result only builds visible lazy rows', (
    tester,
  ) async {
    final backend = _AnalyticsBackend(contributorCount: 2000);
    addTearDown(backend.api.close);
    await tester.pumpWidget(
      _host(
        ProjectAnalyticsPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.text('Author 0'), findsOneWidget);
    expect(find.byType(Card).evaluate().length, lessThan(50));
    expect(find.text('Author 1999'), findsNothing);
  });

  testWidgets('mixed missing commit stats mark aggregate unavailable', (
    tester,
  ) async {
    final backend = _AnalyticsBackend(mixedCommitStats: true);
    addTearDown(backend.api.close);
    await tester.pumpWidget(
      _host(
        ProjectAnalyticsPage(
          account: _account(backend.api),
          api: backend.api,
          project: _project(),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await _openTab(tester, '儲存庫');
    expect(find.text('+— / -—'), findsOneWidget);
    expect(find.text('+4 / -2'), findsNothing);
  });
}
