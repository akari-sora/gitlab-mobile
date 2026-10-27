import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';

const _path = 'team/sub';
const _gid = 'gid://gitlab/Group/7';
const _item = 'gid://gitlab/WorkItem/91';
const _account = 'https://example.com/gitlab#5';
const _scope = AiGroupResourceScope(
  accountKey: _account,
  instanceKey: 'https://example.com/gitlab',
  groupId: 7,
  groupFullPath: _path,
  iid: 3,
  workItemGid: _item,
);

final class _Secrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => const [];
}

Map<String, Object?> _node({String? description = 'Synthetic description'}) => {
  'id': _item,
  'iid': '3',
  'title': 'Group item',
  'state': 'OPEN',
  'createdAt': '2026-10-01T00:00:00Z',
  'updatedAt': '2026-10-02T00:00:00Z',
  'project': null,
  'namespace': {'id': _gid, 'fullPath': _path},
  'workItemType': {'id': 'gid://gitlab/WorkItems::Type/1', 'name': 'Task'},
  'description': description,
  'widgets': [
    if (description != null)
      {'type': 'DESCRIPTION', 'description': description, 'edited': false},
  ],
};

Map<String, Object?> _envelope(Map<String, Object?> node) => {
  'data': {
    'namespace': {'id': _gid, 'fullPath': _path, 'workItem': node},
  },
};

AiToolCall _call(String name, Object? args) =>
    AiToolCall(id: 'call', name: name, arguments: args);

({
  AiToolCatalogue catalogue,
  GitLabAiGroupReadPort port,
  UploadPlaceholderTable table,
})
_catalogue(GitLabApi api, {bool Function()? current}) {
  final port = GitLabAiGroupReadPort(
    api,
    instance: api.instance,
    actorUserId: 5,
    generation: 1,
    isCurrent: current ?? () => true,
  );
  final table = UploadPlaceholderTable(
    instance: api.instance,
    accountKey: _account,
    conversationId: 'test-conversation',
  );
  return (
    catalogue: AiToolCatalogue.group(
      port: port,
      scope: _scope,
      redactor: Redactor(secrets: _Secrets()),
      placeholders: table,
    ),
    port: port,
    table: table,
  );
}

void _assertGraphRequest(RequestOptions request) {
  expect(request.method, 'POST');
  expect(request.uri.toString(), 'https://example.com/gitlab/api/graphql');
  final body = request.data as Map<String, Object?>;
  expect(body.keys.toSet(), {'query', 'variables'});
  expect(body['query'], namespaceWorkItemQuery);
  expect((body['query']! as String).trimLeft(), startsWith('query '));
  expect(body['variables'], {'path': _path, 'iid': '3'});
  expect(request.followRedirects, isFalse);
}

void main() {
  test(
    'fixed group read sends only the grant path and minimal projection',
    () async {
      final adapter = FakeAdapter((request) {
        _assertGraphRequest(request);
        return jsonResponse(_envelope(_node()));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final h = _catalogue(api);
      expect(h.catalogue.specs.map((e) => e.name), ['get_group_work_item']);
      final budget = AiToolBudget(maxGitLabRequests: 2);
      final result = await h.catalogue.execute(
        _call('get_group_work_item', {'groupId': 7, 'iid': 3}),
        budget: budget,
      );
      expect(result.result.isError, isFalse);
      expect(result.result.content, contains('Synthetic description'));
      expect(result.result.content, contains('complete'));
      expect(result.result.content, isNot(contains('assignees')));
      expect(result.result.content, isNot(contains('notes')));
      expect(result.gitLabRequests, 1);
      expect(budget.gitLabRequests, 1);
      expect(adapter.requests, hasLength(1));
      expect(h.port.verifiedIdentity!.groupId, 7);
      expect(h.port.verifiedIdentity!.workItemGid, _item);
    },
  );

  test(
    'group catalogue rejects project tools and arbitrary arguments before reads',
    () async {
      final adapter = FakeAdapter((_) => fail('request must not be sent'));
      final api = testApi(adapter);
      addTearDown(api.close);
      final h = _catalogue(api);
      final cases = <AiToolCall>[
        _call('get_issue', {'iid': 3}),
        _call('read_file', {'path': 'x', 'revision': 'head'}),
        _call('get_group_work_item', {'groupId': 8, 'iid': 3}),
        _call('get_group_work_item', {'groupId': 7, 'iid': 4}),
        _call('get_group_work_item', {'groupId': '7', 'iid': 3}),
        _call('get_group_work_item', {'groupId': 7.0, 'iid': 3}),
        _call('get_group_work_item', {'groupId': 0, 'iid': 3}),
        _call('get_group_work_item', {'groupId': 7}),
        for (final key in [
          'path',
          'query',
          'operationName',
          'variables',
          'url',
          'gid',
        ])
          _call('get_group_work_item', {
            'groupId': 7,
            'iid': 3,
            key: 'untrusted',
          }),
      ];
      for (final call in cases) {
        final result = await h.catalogue.executeResult(
          call,
          budget: AiToolBudget(),
        );
        expect(
          result.isError,
          isTrue,
          reason: '${call.name} ${call.arguments}',
        );
      }
      expect(adapter.requests, isEmpty);
    },
  );

  for (final field in ['project', 'namespace']) {
    test('strict group read refuses absent $field without content', () async {
      final adapter = FakeAdapter((request) {
        _assertGraphRequest(request);
        return jsonResponse(_envelope(_node()..remove(field)));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final h = _catalogue(api);
      final result = await h.catalogue.executeResult(
        _call('get_group_work_item', {'groupId': 7, 'iid': 3}),
        budget: AiToolBudget(),
      );
      expect(result.isError, isTrue);
      expect(result.content, isNot(contains('Synthetic description')));
      expect(h.port.verifiedIdentity, isNull);
      expect(adapter.requests, hasLength(1));
    });
  }

  test('identity mismatch refuses the response without content', () async {
    final adapter = FakeAdapter(
      (request) =>
          jsonResponse(_envelope(_node()..['id'] = 'gid://gitlab/WorkItem/92')),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final h = _catalogue(api);
    final result = await h.catalogue.executeResult(
      _call('get_group_work_item', {'groupId': 7, 'iid': 3}),
      budget: AiToolBudget(),
    );
    expect(result.isError, isTrue);
    expect(result.content, isNot(contains('Synthetic description')));
    expect(h.port.verifiedIdentity, isNull);
  });

  test('wrong namespace and stale session refuse all content', () async {
    var current = true;
    final adapter = FakeAdapter((request) {
      _assertGraphRequest(request);
      final node = _node();
      node['namespace'] = {'id': 'gid://gitlab/Group/8', 'fullPath': _path};
      return jsonResponse(_envelope(node));
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final h = _catalogue(api, current: () => current);
    final result = await h.catalogue.executeResult(
      _call('get_group_work_item', {'groupId': 7, 'iid': 3}),
      budget: AiToolBudget(),
    );
    expect(result.isError, isTrue);
    expect(result.content, isNot(contains('Synthetic description')));
    current = false;
    final stale = await h.catalogue.executeResult(
      _call('get_group_work_item', {'groupId': 7, 'iid': 3}),
      budget: AiToolBudget(),
    );
    expect(stale.isError, isTrue);
    expect(h.port.verifiedIdentity, isNull);
    expect(adapter.requests, hasLength(1));
  });

  test('group read refuses an account that does not match the actor', () async {
    final adapter = FakeAdapter((_) => fail('request must not be sent'));
    final api = testApi(adapter);
    addTearDown(api.close);
    final h = _catalogue(api);
    const foreignAccount = AiGroupResourceScope(
      accountKey: 'https://example.com/gitlab#6',
      instanceKey: 'https://example.com/gitlab',
      groupId: 7,
      groupFullPath: _path,
      iid: 3,
      workItemGid: _item,
    );
    await expectLater(
      h.port.workItem(foreignAccount),
      throwsA(isA<FormatException>()),
    );
    expect(h.port.verifiedIdentity, isNull);
    expect(adapter.requests, isEmpty);
  });

  for (final expireAtDelivery in [false, true]) {
    test(
      expireAtDelivery
          ? 'group read rechecks current state after the API current-state snapshot'
          : 'group read refuses content when the session expires during HTTP',
      () async {
        final entered = Completer<void>();
        final response = Completer<ResponseBody>();
        var responseReturned = false;
        var current = true;
        final adapter = FakeAdapter((request) async {
          _assertGraphRequest(request);
          entered.complete();
          final body = await response.future;
          responseReturned = true;
          return body;
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        final h = _catalogue(
          api,
          current: () {
            if (expireAtDelivery && responseReturned && current) {
              // Expire immediately after the API snapshots current state.
              // Its final gate sees true; the awaiting port must see false.
              final snapshot = current;
              current = false;
              return snapshot;
            }
            return current;
          },
        );
        final pending = h.catalogue.executeResult(
          _call('get_group_work_item', {'groupId': 7, 'iid': 3}),
          budget: AiToolBudget(),
        );
        await entered.future;
        if (!expireAtDelivery) current = false;
        response.complete(jsonResponse(_envelope(_node())));
        final result = await pending;
        expect(current, isFalse);
        expect(result.isError, isTrue);
        expect(result.content, isNot(contains('Synthetic description')));
        expect(h.port.verifiedIdentity, isNull);
        expect(adapter.requests, hasLength(1));
      },
    );
  }

  test(
    'unknown description is explicit and has no restorable provenance',
    () async {
      final api = testApi(
        FakeAdapter((_) => jsonResponse(_envelope(_node(description: null)))),
      );
      addTearDown(api.close);
      final result = await _catalogue(api).catalogue.executeResult(
        _call('get_group_work_item', {'groupId': 7, 'iid': 3}),
        budget: AiToolBudget(),
      );
      expect(result.isError, isFalse);
      expect(result.content, contains('unavailable'));
      expect(result.uploadPlaceholders, isFalse);
    },
  );

  test(
    'only a complete delivered description restores its group upload',
    () async {
      final description =
          '![image](/uploads/0123456789abcdef0123456789abcdef/pic.png) ${'x' * 2000}';
      final api = testApi(
        FakeAdapter(
          (_) => jsonResponse(_envelope(_node(description: description))),
        ),
      );
      addTearDown(api.close);
      final h = _catalogue(api);
      final execution = await h.catalogue.execute(
        _call('get_group_work_item', {'groupId': 7, 'iid': 3}),
        budget: AiToolBudget(),
      );
      expect(execution.result.isError, isFalse);
      final token = RegExp(
        r'\[\[upload:u-[0-9]+\]\]',
      ).firstMatch(execution.result.content)?.group(0);
      expect(token, isNotNull);
      final field = AiFieldProvenance.groupWorkItem(
        identity: h.port.verifiedIdentity!,
        completeValue: true,
      );
      expect(
        h.table.restoreIntoSameField(token!, field).finalText,
        contains('/uploads/0123456789abcdef0123456789abcdef/pic.png'),
      );
      final clipped = _catalogue(api);
      final short = await clipped.catalogue.execute(
        _call('get_group_work_item', {'groupId': 7, 'iid': 3}),
        budget: AiToolBudget(maxSingleOutputChars: 400),
      );
      expect(short.truncated, isTrue);
      final clippedField = AiFieldProvenance.groupWorkItem(
        identity: clipped.port.verifiedIdentity!,
        completeValue: true,
      );
      expect(short.result.content, isNot(contains('[[upload:')));
      expect(short.result.uploadPlaceholders, isFalse);
      expect(clipped.table.seenOnlyCut(clippedField), isTrue);
    },
  );

  test('reserves both OAuth resource requests before sending', () async {
    final adapter = FakeAdapter(
      (_) => fail('budget must refuse before network'),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    final result = await _catalogue(api).catalogue.executeResult(
      _call('get_group_work_item', {'groupId': 7, 'iid': 3}),
      budget: AiToolBudget(maxGitLabRequests: 1),
    );
    expect(result.isError, isTrue);
    expect(adapter.requests, isEmpty);
  });

  test('OAuth replays only the same fixed read document', () async {
    var graphRequests = 0;
    var refreshes = 0;
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/oauth/token')) {
        refreshes++;
        return jsonResponse({
          'access_token': 'new-token',
          'refresh_token': 'new-refresh',
          'token_type': 'bearer',
          'expires_in': 7200,
        });
      }
      _assertGraphRequest(request);
      graphRequests++;
      if (graphRequests == 1) return jsonResponse({}, status: 401);
      return jsonResponse(_envelope(_node()));
    });
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    final dio = Dio()..httpClientAdapter = adapter;
    final api = GitLabApi(
      instance: instance,
      dio: dio,
      credential: const OAuthCredential(
        accessToken: 'old-token',
        refreshToken: 'old-refresh',
        clientId: 'app',
      ),
      oauth: OAuthTokenClient(instance: instance, clientId: 'app', dio: dio),
    );
    addTearDown(api.close);
    final budget = AiToolBudget(maxGitLabRequests: 2);
    final result = await _catalogue(api).catalogue.execute(
      _call('get_group_work_item', {'groupId': 7, 'iid': 3}),
      budget: budget,
    );
    expect(result.result.isError, isFalse);
    expect(graphRequests, 2);
    expect(refreshes, 1);
    expect(result.gitLabRequests, 2);
    expect(budget.gitLabRequests, 2);
  });
}
