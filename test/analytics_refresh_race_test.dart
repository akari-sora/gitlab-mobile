import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/project_analytics_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

typedef _Read =
    FutureOr<ResponseBody> Function(RequestOptions request, int read);

final class _Backend {
  _Read? contributors, commits, coverage, languages, pipelines;
  int contributorReads = 0, commitReads = 0, coverageReads = 0;
  int languageReads = 0, pipelineReads = 0;
  late final adapter = FakeAdapter(_respond);
  late final api = testApi(adapter);

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final path = request.uri.path;
    if (path.endsWith('/repository/contributors')) {
      final read = ++contributorReads;
      return contributors?.call(request, read) ?? contributor('Current Author');
    }
    if (path.endsWith('/repository/commits')) {
      final read = ++commitReads;
      return commits?.call(request, read) ?? activity(request, additions: 4);
    }
    if (path.endsWith('/languages')) {
      final read = ++languageReads;
      return languages?.call(request, read) ?? jsonResponse({'Dart': 100});
    }
    final query = (request.data as Map)['query'] as String;
    if (query.contains('MobilePipelineAnalytics')) {
      final read = ++pipelineReads;
      return pipelines?.call(request, read) ?? pipeline(request, total: 20);
    }
    final read = ++coverageReads;
    return coverage?.call(request, read) ?? coverageSummary(87.5);
  }

  ResponseBody contributor(String name) => jsonResponse([
    {
      'name': name,
      'email': 'synthetic@example.invalid',
      'commits': 1,
      'additions': 1,
      'deletions': 0,
    },
  ]);

  ResponseBody activity(RequestOptions request, {required int additions}) {
    final date = DateTime.parse(
      request.uri.queryParameters['since']!,
    ).add(const Duration(days: 1));
    return jsonResponse([
      {
        'id': 'a' * 40,
        'committed_date': date.toIso8601String(),
        'parent_ids': ['b' * 40],
        'stats': {'additions': additions, 'deletions': 2},
      },
    ]);
  }

  ResponseBody coverageSummary(double average) => jsonResponse({
    'data': {
      'project': {
        'id': 'gid://gitlab/Project/42',
        'codeCoverageSummary': {
          'averageCoverage': average,
          'coverageCount': 1,
          'lastUpdatedOn': '2026-10-02',
        },
      },
    },
  });

  ResponseBody pipeline(RequestOptions request, {required int total}) {
    final variables = (request.data as Map)['variables'] as Map;
    final label = DateTime.parse(
      variables['fromTime'] as String,
    ).add(const Duration(days: 1)).toIso8601String().substring(0, 10);
    final bucket = {
      'all': '$total',
      'success': '$total',
      'failed': '0',
      'other': '0',
      'durationStatistics': {'p50': 2, 'p95': 4},
    };
    return jsonResponse({
      'data': {
        'project': {
          'id': 'gid://gitlab/Project/42',
          'pipelineAnalytics': {
            'aggregate': {...bucket, 'label': null},
            'timeSeries': [
              {...bucket, 'label': label},
            ],
          },
        },
      },
    });
  }
}

Future<void> _show(WidgetTester tester, _Backend backend) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(backend.api.close);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.light),
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: ProjectAnalyticsPage(
        account: Account(
          instance: backend.api.instance,
          user: GitLabUser(id: 7, username: 'synthetic', name: 'Synthetic'),
          token: 'synthetic-test-token',
        ),
        api: backend.api,
        project: Project.fromJson(projectJson(42)),
      ),
    ),
  );
  await settleNetworkWidgets(tester);
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(Tab, label));
  await settleNetworkWidgets(tester);
}

Future<void> _refresh(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('analytics-refresh')));
  await settleNetworkWidgets(tester);
}

Future<void> _repositoryBottom(WidgetTester tester) async {
  await tester.drag(
    find.byKey(const PageStorageKey('analytics-repository')).hitTestable(),
    const Offset(0, -700),
  );
  await settleNetworkWidgets(tester);
}

void main() {
  testWidgets('same-ref refresh rejects a delayed older contributor response', (
    tester,
  ) async {
    final backend = _Backend();
    final old = Completer<ResponseBody>();
    backend.contributors = (_, read) =>
        read == 1 ? old.future : backend.contributor('Fresh Author');
    await _show(tester, backend);
    await _refresh(tester);
    expect(backend.contributorReads, 2);
    expect(find.text('Fresh Author'), findsOneWidget);
    old.complete(backend.contributor('Old Author'));
    await settleNetworkWidgets(tester);
    expect(find.text('Fresh Author'), findsOneWidget);
    expect(find.text('Old Author'), findsNothing);
  });

  testWidgets('same-window refresh rejects older repository activity', (
    tester,
  ) async {
    final backend = _Backend();
    final old = Completer<ResponseBody>();
    late RequestOptions first;
    backend.commits = (request, read) {
      if (read == 1) {
        first = request;
        return old.future;
      }
      return backend.activity(request, additions: 31);
    };
    await _show(tester, backend);
    await _tab(tester, '儲存庫');
    await _refresh(tester);
    expect(backend.commitReads, 2);
    expect(find.text('+31 / -2'), findsOneWidget);
    old.complete(backend.activity(first, additions: 1));
    await settleNetworkWidgets(tester);
    expect(find.text('+31 / -2'), findsOneWidget);
    expect(find.text('+1 / -2'), findsNothing);
  });

  testWidgets('repository refresh replaces pending project-scoped sections', (
    tester,
  ) async {
    final backend = _Backend();
    final oldCoverage = Completer<ResponseBody>();
    final oldLanguages = Completer<ResponseBody>();
    backend.coverage = (_, read) =>
        read == 1 ? oldCoverage.future : backend.coverageSummary(88);
    backend.languages = (_, read) =>
        read == 1 ? oldLanguages.future : jsonResponse({'Fresh Language': 100});
    await _show(tester, backend);
    await _tab(tester, '儲存庫');
    await _refresh(tester);
    expect(backend.coverageReads, 2);
    expect(backend.languageReads, 2);
    await _repositoryBottom(tester);
    expect(find.textContaining('88.0%'), findsOneWidget);
    expect(find.textContaining('Fresh Language'), findsOneWidget);
    oldCoverage.complete(backend.coverageSummary(11));
    oldLanguages.complete(jsonResponse({'Old Language': 100}));
    await settleNetworkWidgets(tester);
    expect(find.textContaining('88.0%'), findsOneWidget);
    expect(find.textContaining('Fresh Language'), findsOneWidget);
    expect(find.textContaining('11.0%'), findsNothing);
    expect(find.textContaining('Old Language'), findsNothing);
  });

  testWidgets('same-window CI refresh rejects the older pipeline response', (
    tester,
  ) async {
    final backend = _Backend();
    final old = Completer<ResponseBody>();
    late RequestOptions first;
    backend.pipelines = (request, read) {
      if (read == 1) {
        first = request;
        return old.future;
      }
      return backend.pipeline(request, total: 31);
    };
    await _show(tester, backend);
    await _tab(tester, 'CI');
    await _refresh(tester);
    expect(backend.pipelineReads, 2);
    expect(find.text('成功率 · 全部 31'), findsOneWidget);
    old.complete(backend.pipeline(first, total: 1));
    await settleNetworkWidgets(tester);
    expect(find.text('成功率 · 全部 31'), findsOneWidget);
    expect(find.text('成功率 · 全部 1'), findsNothing);
  });

  testWidgets('refreshing contributors does not orphan a pending CI read', (
    tester,
  ) async {
    final backend = _Backend();
    final pending = Completer<ResponseBody>();
    late RequestOptions request;
    backend.pipelines = (value, _) {
      request = value;
      return pending.future;
    };
    await _show(tester, backend);
    await _tab(tester, 'CI');
    await _tab(tester, '貢獻者');
    await _refresh(tester);
    pending.complete(backend.pipeline(request, total: 23));
    await settleNetworkWidgets(tester);
    await _tab(tester, 'CI');
    expect(backend.pipelineReads, 1);
    expect(find.text('成功率 · 全部 23'), findsOneWidget);
  });

  testWidgets('returning to repository shares pending coverage and languages', (
    tester,
  ) async {
    final backend = _Backend();
    final pendingCoverage = Completer<ResponseBody>();
    final pendingLanguages = Completer<ResponseBody>();
    backend.coverage = (_, _) => pendingCoverage.future;
    backend.languages = (_, _) => pendingLanguages.future;
    await _show(tester, backend);
    await _tab(tester, '儲存庫');
    await _tab(tester, 'CI');
    await _tab(tester, '儲存庫');
    expect(backend.coverageReads, 1);
    expect(backend.languageReads, 1);
    pendingCoverage.complete(backend.coverageSummary(87.5));
    pendingLanguages.complete(jsonResponse({'Dart': 100}));
    await settleNetworkWidgets(tester);
    await _repositoryBottom(tester);
    expect(find.textContaining('87.5%'), findsOneWidget);
    expect(find.textContaining('Dart 100.0%'), findsOneWidget);
  });
}
