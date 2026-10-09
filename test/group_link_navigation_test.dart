import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/project_locator.dart';
import 'package:gitlab_mobile/features/workspace/navigation.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

Account _account(GitLabApi api) => Account(
  instance: api.instance,
  user: const GitLabUser(id: 7, username: 'user7', name: 'User 7'),
  token: 'synthetic-test-token',
);

Map<String, Object?> _group({int id = 9, String path = 'team/sub'}) => {
  'id': id,
  'name': 'Nested team',
  'full_path': path,
  'visibility': 'public',
  'description': null,
  'unknown_admin_field': 'must not enter the cache',
};

Map<String, Object?> _graphConnection() => {
  'nodes': <Object?>[],
  'pageInfo': {'hasNextPage': false, 'endCursor': null},
};

Map<String, Object?> _groupWorkItemVariables(
  Iterable<RequestOptions> requests,
) {
  final request = requests.lastWhere((request) {
    if (!request.uri.path.endsWith('/api/graphql')) return false;
    final body = request.data as Map;
    return (body['query'] as String).contains('MobileGroupWorkItems');
  });
  return Map<String, Object?>.from((request.data as Map)['variables'] as Map);
}

void main() {
  group('group link parser', () {
    test('recognises root, subgroup, installation subpath, and list URLs', () {
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final root = GitLabLink.parse(
        'https://example.com/gitlab/groups/team',
        instance,
      );
      final subgroup = GitLabLink.parse(
        'https://example.com/gitlab/groups/team/sub/',
        instance,
      );
      final list = GitLabLink.parse(
        'https://example.com/gitlab/groups/team/sub/-/work_items?sort=created_desc',
        instance,
      );

      expect((root.target, root.project), (LinkTarget.group, 'team'));
      expect(
        (subgroup.target, subgroup.project),
        (LinkTarget.group, 'team/sub'),
      );
      expect(
        (list.target, list.project, list.number),
        (LinkTarget.groupWorkItems, 'team/sub', null),
      );
    });

    test('keeps group item links distinct from the group list', () {
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final item = GitLabLink.parse(
        'https://example.com/gitlab/groups/team/sub/-/work_items/8',
        instance,
      );

      expect(
        (item.target, item.project, item.number, item.workItemScope),
        (LinkTarget.workItem, 'team/sub', 8, WorkItemLinkScope.group),
      );
    });

    test(
      'rejects unsupported, sensitive, cross-instance, and ambiguous URLs',
      () {
        final instance = GitLabInstance.parse('https://example.com/gitlab');
        for (final value in [
          'https://example.com/gitlab/groups/team/-/issues/8',
          'https://example.com/gitlab/groups/team/-/work_items/nope',
          'https://example.com/gitlab/groups/team/-/work_items/8/extra',
          'https://example.com/gitlab/groups//-/work_items',
          'https://example.com/gitlab/groups/team%2Fsub/-/work_items',
          'https://example.com/gitlab/groups/team/../sub/-/work_items',
          'https://example.com/gitlab/groups/team/-/work_items?private_token=x',
          'https://other.example/gitlab/groups/team/-/work_items',
          'https://example.com/other/groups/team/-/work_items',
        ]) {
          expect(
            () => GitLabLink.parse(value, instance),
            throwsFormatException,
            reason: value,
          );
        }
      },
    );
  });

  group('groupByPath', () {
    test(
      'uses one encoded path segment and validates the exact REST identity',
      () async {
        RequestOptions? captured;
        final api = testApi(
          FakeAdapter((request) {
            captured = request;
            return jsonResponse(_group());
          }),
        );
        addTearDown(api.close);

        final value = await api.groupByPath('team/sub');

        expect(value['id'], 9);
        expect(value['full_path'], 'team/sub');
        expect(value['visibility'], 'public');
        expect(value, isNot(contains('unknown_admin_field')));
        expect(() => value['id'] = 10, throwsUnsupportedError);
        expect(captured!.uri.path, endsWith('/groups/team%2Fsub'));
        expect(captured!.uri.pathSegments.last, 'team/sub');
        expect(captured!.uri.queryParameters, {'with_projects': 'false'});
      },
    );

    test(
      'rejects invalid input before transport and mismatched responses',
      () async {
        final noRequest = FakeAdapter(
          (_) => fail('must reject before request'),
        );
        final invalid = testApi(noRequest);
        await expectLater(
          invalid.groupByPath('../team'),
          throwsA(_failure(FailureKind.validation)),
        );
        expect(noRequest.requests, isEmpty);
        invalid.close();

        for (final response in [
          _group(id: 0),
          _group(path: 'team/other'),
          {..._group(), 'id': '9'},
          {..._group(), 'full_path': null},
        ]) {
          final api = testApi(FakeAdapter((_) => jsonResponse(response)));
          await expectLater(
            api.groupByPath('team/sub'),
            throwsA(_failure(FailureKind.invalidResponse)),
          );
          api.close();
        }
      },
    );

    test(
      'preflight, late generation, and closed client fences cancel reads',
      () async {
        final noRequest = FakeAdapter(
          (_) => fail('must reject before request'),
        );
        final stale = testApi(noRequest);
        await expectLater(
          stale.groupByPath('team/sub', isCurrent: () => false),
          throwsA(_failure(FailureKind.cancelled)),
        );
        expect(noRequest.requests, isEmpty);
        stale.close();

        var current = true;
        final pending = Completer<ResponseBody>();
        final late = testApi(FakeAdapter((_) => pending.future));
        final operation = late.groupByPath(
          'team/sub',
          isCurrent: () => current,
        );
        await Future<void>.delayed(Duration.zero);
        current = false;
        pending.complete(jsonResponse(_group()));
        await expectLater(operation, throwsA(_failure(FailureKind.cancelled)));
        late.close();

        final closed = testApi(FakeAdapter((_) => jsonResponse(_group())));
        closed.close();
        await expectLater(
          closed.groupByPath('team/sub'),
          throwsA(_failure(FailureKind.cancelled)),
        );
      },
    );
  });

  testWidgets(
    'group Work Items link resolves group and opens selected native tab',
    (tester) async {
      final requests = <RequestOptions>[];
      final adapter = FakeAdapter((request) {
        requests.add(request);
        if (request.uri.path.endsWith('/groups/team%2Fsub')) {
          return jsonResponse(_group());
        }
        if (request.uri.path.endsWith('/api/graphql')) {
          final query = (request.data as Map)['query'] as String;
          if (query.contains('MobileGroupWorkItems')) {
            return jsonResponse({
              'data': {
                'group': {
                  'id': 'gid://gitlab/Group/9',
                  'fullPath': 'team/sub',
                  'workItems': _graphConnection(),
                },
              },
            });
          }
          if (query.contains('MobileNamespaceWorkItemTypes')) {
            return jsonResponse({
              'data': {
                'namespace': {
                  'id': 'gid://gitlab/Group/9',
                  'fullPath': 'team/sub',
                  'workItemTypes': _graphConnection(),
                },
              },
            });
          }
        }
        return jsonResponse(<Object?>[]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final account = _account(api);
      final link = GitLabLink.parse(
        'https://example.com/gitlab/groups/team/sub/-/work_items',
        api.instance,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () =>
                    ResourceNavigator(account, api).link(context, link),
                child: const Text('Open group items'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open group items'));
      await settleNetworkWidgets(tester);

      expect(find.text('包含子群組與專案'), findsOneWidget);
      expect(find.text('開啟中 · 最新建立'), findsOneWidget);
      expect(_groupWorkItemVariables(requests), {
        'path': 'team/sub',
        'first': 20,
        'after': null,
        'includeDescendants': true,
        'state': 'opened',
        'search': '',
        'sort': 'CREATED_DESC',
      });
      expect(
        requests.where((request) => request.uri.path.contains('/projects/')),
        isEmpty,
      );
      expect(
        requests.where(
          (request) => request.uri.path.endsWith('/groups/team%2Fsub'),
        ),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'group 404 keeps account-aware retry and never guesses a project',
    (tester) async {
      var hidden = true;
      final requests = <RequestOptions>[];
      final api = testApi(
        FakeAdapter((request) {
          requests.add(request);
          if (request.uri.path.endsWith('/groups/team%2Fsub')) {
            return hidden
                ? jsonResponse({'message': '404 Group Not Found'}, status: 404)
                : jsonResponse(_group());
          }
          if (request.uri.path.endsWith('/api/graphql')) {
            final query = (request.data as Map)['query'] as String;
            final key = query.contains('MobileGroupWorkItems')
                ? 'group'
                : 'namespace';
            return jsonResponse({
              'data': {
                key: {
                  'id': 'gid://gitlab/Group/9',
                  'fullPath': 'team/sub',
                  if (key == 'group') 'workItems': _graphConnection(),
                  if (key == 'namespace') 'workItemTypes': _graphConnection(),
                },
              },
            });
          }
          return jsonResponse(<Object?>[]);
        }),
      );
      addTearDown(api.close);
      final account = _account(api);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => ResourceNavigator(
                  account,
                  api,
                ).groupWorkItems(context, 'team/sub'),
                child: const Text('Open hidden group'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open hidden group'));
      await settleNetworkWidgets(tester);
      expect(find.text('無法開啟'), findsOneWidget);
      expect(find.text('目標：群組 team/sub'), findsOneWidget);

      hidden = false;
      await tester.tap(find.text('重新整理'));
      await settleNetworkWidgets(tester);
      expect(find.text('包含子群組與專案'), findsOneWidget);
      expect(find.text('開啟中 · 最新建立'), findsOneWidget);
      expect(
        _groupWorkItemVariables(requests),
        containsPair('includeDescendants', true),
      );
      expect(
        _groupWorkItemVariables(requests),
        containsPair('state', 'opened'),
      );
      expect(
        requests.where((request) => request.uri.path.contains('/projects/')),
        isEmpty,
      );
    },
  );
}
