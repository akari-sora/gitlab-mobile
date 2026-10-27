import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_labels_models.dart';

import 'support/fake_adapter.dart';

const _user = 'gid://gitlab/User/7';
const _item = 'gid://gitlab/WorkItem/100';
const _type = 'gid://gitlab/WorkItems::Type/9';
const _project = 'gid://gitlab/Project/42';
const _projectPath = 'studio/mobile-workspace';
const _namespace = 'gid://gitlab/Namespaces::ProjectNamespace/42';
const _group = 'gid://gitlab/Group/84';
const _groupPath = 'qa/synthetic-group';
const _bug = 'gid://gitlab/ProjectLabel/3';
const _priority = 'gid://gitlab/GroupLabel/8';
const _docs = 'gid://gitlab/Label/11';
// Independent literal: these filters establish direct ownership on GitLab
// v18.5.0, whose Label type has no project/group owner fields.
const _groupWorkItemLabelCandidatesQuery = r'''
query MobileGroupWorkItemLabelCandidates($fullPath: ID!) {
  currentUser { id }
  group(fullPath: $fullPath) {
    id
    fullPath
    labels(
      onlyGroupLabels: true
      includeAncestorGroups: false
      includeDescendantGroups: false
      archived: false
      first: 100
    ) {
      nodes { id title color textColor }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';
final _opened = DateTime.utc(2026, 10, 3, 9);
final _touched = DateTime.utc(2026, 10, 3, 10);

void main() {
  test('UI group search retains opaque identity while AI candidates refuse it', () async {
    const opaqueGroup = 'gid://gitlab/Group/server-owned-group';
    final adapter = FakeAdapter((request) {
      expect(_query(request).trimLeft(), startsWith('query '));
      if (_query(request).contains('MobileGroupLabelCandidates')) {
        final envelope = _groupCandidateEnvelope([_label(_priority)]);
        final data = envelope['data']! as Map<String, Object?>;
        (data['group']! as Map<String, Object?>)['id'] = opaqueGroup;
        return jsonResponse(envelope);
      }
      return jsonResponse(_envelope(_groupNode(
        labels: <Object>[],
        groupId: opaqueGroup,
      )));
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = (await api.workItemLabels(
      _groupDetail(groupId: opaqueGroup),
      expectedUserId: 7,
      generation: 1,
    )).target!;
    await expectLater(api.workItemLabelCandidates(target), throwsA(isA<ApiFailure>()));
    expect(adapter.requests, hasLength(1));
    final page = await api.searchWorkItemLabelCandidates(target, search: 'scope', pageIndex: 0);
    expect(page.labels.single.id, _priority);
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.where(_isMutation), isEmpty);
  });

  test('fixed group candidates read one complete direct-owner page of 100', () async {
    final adapter = FakeAdapter((request) {
      expect(_query(request).trimLeft(), startsWith('query '));
      if (_query(request).contains('MobileGroupWorkItemLabelCandidates')) {
        return jsonResponse(_groupCandidateEnvelope([
          for (var i = 1; i <= 100; i++) _ownedGroupLabel(i),
        ]));
      }
      return jsonResponse(_envelope(_groupNode(labels: <Object>[])));
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final access = await api.workItemLabels(_groupDetail(), expectedUserId: 7, generation: 1);
    expect(access.snapshot.allowsScopedLabels, WorkItemLabelAllowsScoped.disabled);
    final target = access.target!;
    for (final cap in [0, 2]) {
      await expectLater(api.workItemLabelCandidates(target, maxPages: cap), throwsA(isA<ApiFailure>()));
      expect(adapter.requests, hasLength(1), reason: 'invalid cap is refused before a candidate read');
    }
    late List<WorkItemLabel> candidates;
    try {
      candidates = await api.workItemLabelCandidates(target, maxPages: 1);
    } finally {
      // Assert outside the adapter so a document mismatch stays an assertion
      // failure rather than being converted to an API transport failure.
      expect(_query(adapter.requests.last), _groupWorkItemLabelCandidatesQuery);
      expect(_variables(adapter.requests.last), {'fullPath': _groupPath});
    }
    expect(candidates, hasLength(100));
    expect(candidates.first.id, 'gid://gitlab/GroupLabel/1');
    expect(candidates.last.id, 'gid://gitlab/GroupLabel/100');
    expect(() => candidates.clear(), throwsUnsupportedError);
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.where(_isMutation), isEmpty);
  });

  test('fixed group candidates refuse unproven scope, GID types and incomplete pages', () async {
    for (final problem in [
      'wrongContainerId', 'wrongContainerPath', 'missingContainerId', 'missingContainerPath',
      'missingGroup', 'nullGroup', 'forgedGroupId', 'projectContainerId',
      'descendantGroupId', 'descendantGroupPath', 'ancestorGroupId', 'ancestorGroupPath',
      'projectLabel', 'baseLabel', 'unknownLabelType', 'missingLabelId', 'nullLabelId',
      'numericLabelId', 'zeroLabelId', 'leadingZeroLabelId', 'negativeLabelId',
      'overflowLabelId', 'suffixedLabelId', 'trailingNewlineLabelId', 'hasNext', 'oversized',
      'duplicate', 'emptyCursor', 'wrongCursor', 'schemaError',
    ]) {
      final nodes = <Map<String, Object?>>[_ownedGroupLabel(1), _ownedGroupLabel(2)];
      final response = _groupCandidateEnvelope(nodes);
      final data = response['data']! as Map<String, Object?>;
      final group = data['group']! as Map<String, Object?>;
      final labels = group['labels']! as Map<String, Object?>;
      final info = labels['pageInfo']! as Map<String, Object?>;
      final label = nodes.last;
      switch (problem) {
        case 'wrongContainerId': group['id'] = 'gid://gitlab/Group/85';
        case 'wrongContainerPath': group['fullPath'] = 'qa/other';
        case 'missingContainerId': group.remove('id');
        case 'missingContainerPath': group.remove('fullPath');
        case 'missingGroup': data.remove('group');
        case 'nullGroup': data['group'] = null;
        case 'forgedGroupId': group['id'] = 'gid://gitlab/Group/084';
        case 'projectContainerId': group['id'] = _project;
        case 'descendantGroupId': group['id'] = 'gid://gitlab/Group/85'; group['fullPath'] = '$_groupPath/child';
        case 'descendantGroupPath': group['fullPath'] = '$_groupPath/child';
        case 'ancestorGroupId': group['id'] = 'gid://gitlab/Group/85'; group['fullPath'] = 'qa';
        case 'ancestorGroupPath': group['fullPath'] = 'qa';
        case 'projectLabel': label['id'] = 'gid://gitlab/ProjectLabel/2';
        case 'baseLabel': label['id'] = 'gid://gitlab/Label/2';
        case 'unknownLabelType': label['id'] = 'gid://gitlab/UnknownLabel/2';
        case 'missingLabelId': label.remove('id');
        case 'nullLabelId': label['id'] = null;
        case 'numericLabelId': label['id'] = 2;
        case 'zeroLabelId': label['id'] = 'gid://gitlab/GroupLabel/0';
        case 'leadingZeroLabelId': label['id'] = 'gid://gitlab/GroupLabel/02';
        case 'negativeLabelId': label['id'] = 'gid://gitlab/GroupLabel/-2';
        case 'overflowLabelId': label['id'] = 'gid://gitlab/GroupLabel/999999999999999999999999999999999';
        case 'suffixedLabelId': label['id'] = 'gid://gitlab/GroupLabel/2/child';
        case 'trailingNewlineLabelId': label['id'] = 'gid://gitlab/GroupLabel/2\n';
        case 'hasNext': info['hasNextPage'] = true; info['endCursor'] = 'next';
        case 'oversized': labels['nodes'] = [for (var i = 1; i <= 101; i++) _ownedGroupLabel(i)];
        case 'duplicate': nodes[1] = _ownedGroupLabel(1);
        case 'emptyCursor': info['endCursor'] = '';
        case 'wrongCursor': info['endCursor'] = 12;
        case 'schemaError': response.clear(); response['errors'] = [{'message': 'unknown field'}];
      }
      final adapter = FakeAdapter((request) {
        expect(_query(request).trimLeft(), startsWith('query '), reason: problem);
        return jsonResponse(_query(request).contains('MobileGroupWorkItemLabelCandidates')
            ? response : _envelope(_groupNode(labels: <Object>[])));
      });
      final api = testApi(adapter);
      final target = (await api.workItemLabels(_groupDetail(), expectedUserId: 7, generation: 1)).target!;
      await expectLater(api.workItemLabelCandidates(target), throwsA(isA<ApiFailure>()), reason: problem);
      expect(adapter.requests, hasLength(2), reason: problem);
      expect(adapter.requests.where(_isMutation), isEmpty, reason: problem);
      api.close();
    }
  });

  test('failed fixed group batch registers no candidate IDs', () async {
    for (final truncated in [false, true]) {
      final nodes = [_ownedGroupLabel(1), _ownedGroupLabel(2)];
      if (!truncated) nodes.last['id'] = 'gid://gitlab/ProjectLabel/2';
      final adapter = FakeAdapter((request) {
        expect(_query(request).trimLeft(), startsWith('query '));
        return jsonResponse(_query(request).contains('MobileGroupWorkItemLabelCandidates')
            ? _groupCandidateEnvelope(nodes, hasNext: truncated, cursor: truncated ? 'next' : null)
            : _envelope(_groupNode(labels: <Object>[])));
      });
      final api = testApi(adapter);
      final target = (await api.workItemLabels(_groupDetail(), expectedUserId: 7, generation: 1)).target!;
      await expectLater(api.workItemLabelCandidates(target), throwsA(isA<ApiFailure>()));
      await expectLater(api.updateWorkItemLabels(target, desiredLabelIds: ['gid://gitlab/GroupLabel/1']),
        throwsA(isA<WorkItemLabelWriteFailure>().having((error) => error.mutationSent, 'sent', false)));
      expect(adapter.requests, hasLength(3));
      expect(adapter.requests.where(_isMutation), isEmpty);
      api.close();
    }
  });

  test('fixed group candidates register IDs for the existing add/remove delta', () async {
    var mutated = false;
    final adapter = FakeAdapter((request) {
      if (_isMutation(request)) {
        mutated = true;
        return jsonResponse(_ack(_touched));
      }
      expect(_query(request).trimLeft(), startsWith('query '));
      if (_query(request).contains('MobileGroupWorkItemLabelCandidates')) {
        return jsonResponse(_groupCandidateEnvelope([_ownedGroupLabel(1, title: 'scope::new')]));
      }
      return jsonResponse(_envelope(_groupNode(
        labels: mutated ? [_label('gid://gitlab/GroupLabel/1', title: 'scope::new')]
            : [_label(_priority, title: 'scope::old')],
        updatedAt: mutated ? _touched.toIso8601String() : null,
      )));
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = (await api.workItemLabels(_groupDetail(), expectedUserId: 7, generation: 1)).target!;
    final candidates = await api.workItemLabelCandidates(target);
    expect(candidates.single.title, 'scope::new');
    expect(workItemLabelScopeKey(candidates.single.title), 'scope');
    final result = await api.updateWorkItemLabels(target, desiredLabelIds: [candidates.single.id]);
    expect(result.status, WorkItemLabelSaveStatus.success);
    final input = _variables(adapter.requests.singleWhere(_isMutation))['input']! as Map;
    expect(input['labelsWidget'], {
      'addLabelIds': ['gid://gitlab/GroupLabel/1'], 'removeLabelIds': [_priority],
    });
    expect(adapter.requests.where(_isMutation), hasLength(1));
    expect(adapter.requests, hasLength(5));
  });

  test('scope uses the last delimiter, including empty and nested keys', () {
    // All rows of FINAL_PLAN.md lines 43-56 table
    expect(workItemLabelScopeKey('priority::high'), 'priority');
    expect(workItemLabelScopeKey('a::b::c'), 'a::b');
    expect(workItemLabelScopeKey('plain'), isNull);
    expect(workItemLabelScopeKey('::value'), '');
    expect(workItemLabelScopeKey('a::'), 'a');
    expect(workItemLabelScopeKey('a:::b'), 'a:');
    expect(workItemLabelScopeKey('a::b::'), 'a::b');
    expect(workItemLabelScopeKey('scope::a::x'), 'scope::a');
    expect(
      workItemLabelScopeKey('workflow::backend::review'),
      'workflow::backend',
    );
    expect(
      workItemLabelScopeKey('workflow::frontend::review'),
      'workflow::frontend',
    );
    expect(
      workItemLabelScopeKey('workflow::backend::done'),
      'workflow::backend',
    );

    // Equivalence assertions from FINAL_PLAN.md line 57
    expect(
      workItemLabelScopeKey('workflow::backend::review'),
      workItemLabelScopeKey('workflow::backend::done'),
    );
    expect(
      workItemLabelScopeKey('workflow::frontend::review'),
      isNot(workItemLabelScopeKey('workflow::backend::review')),
    );
    expect(workItemLabelScopeKey('a::b::'), workItemLabelScopeKey('a::b::c'));

    // CJK and nested keys
    expect(workItemLabelScopeKey('標籤::後端::待審查'), '標籤::後端');
    expect(workItemLabelScopeKey('::中文'), '');
    expect(workItemLabelScopeKey('純中文標籤'), isNull);
    expect(workItemLabelScopeKey('scope::child::value'), 'scope::child');
  });

  test('contrast accepts 4.5 and rejects invalid or low pairs', () {
    expect(workItemLabelContrastAccepted('#FFFFFF', '#000000'), isTrue);
    expect(workItemLabelContrastAccepted('#FFFFFF', '#767676'), isTrue);
    expect(workItemLabelContrastAccepted('#000000', '#757575'), isTrue);
    expect(workItemLabelContrastAccepted('#FFFFFF', '#777777'), isFalse);
    expect(workItemLabelContrastAccepted('#FFF', '#000000'), isFalse);
    expect(workItemLabelContrastAccepted('red', '#000000'), isFalse);
  });

  test(
    'full read keeps 20 pages of 100 and stamps the handoff epoch',
    () async {
      final adapter = FakeAdapter((request) {
        final after = _variables(request)['after'] as String?;
        final page = after == null ? 0 : int.parse(after.substring(1));
        return jsonResponse(
          _envelope(
            _itemNode(
              labels: _numbered(page * 100 + 1, 100),
              hasNext: page < 19,
              cursor: page < 19 ? 'p${page + 1}' : null,
            ),
          ),
        );
      });
      final api = testApi(adapter);
      final access = await api.workItemLabels(
        _detail(),
        expectedUserId: 7,
        generation: 4,
        isCurrent: () => true,
      );
      expect(adapter.requests, hasLength(20));
      expect(access.canWrite, isTrue);
      expect(access.target, isNotNull);
      expect(access.target!.consumed, isFalse);
      expect(access.snapshot.generation, 4);
      expect(access.snapshot.readEpoch, greaterThanOrEqualTo(0));
      expect(access.target!.opening.readEpoch, access.snapshot.readEpoch);
      expect(access.snapshot.labelIds, hasLength(2000));
      expect(access.snapshot.labelIds.first, 'gid://gitlab/ProjectLabel/1');
      expect(access.snapshot.labelIds.last, 'gid://gitlab/ProjectLabel/2000');
      expect(
        _queries(adapter).every((query) => query.contains('first: 100')),
        isTrue,
      );
    },
  );

  test(
    'page 20 still open fails closed and does not request page 21',
    () async {
      final adapter = FakeAdapter((request) {
        final after = _variables(request)['after'] as String?;
        final page = after == null ? 0 : int.parse(after.substring(1));
        return jsonResponse(
          _envelope(
            _itemNode(
              labels: _numbered(page * 100 + 1, 100),
              hasNext: true,
              cursor: 'p${page + 1}',
            ),
          ),
        );
      });
      final api = testApi(adapter);
      await expectLater(
        api.workItemLabels(_detail(), expectedUserId: 7, generation: 1),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
      expect(adapter.requests, hasLength(20));
    },
  );

  test(
    'duplicate, illegal, untitled and stale pages produce no target',
    () async {
      Future<void> expectRejected(Object? node) async {
        final adapter = FakeAdapter((_) => jsonResponse(_envelope(node)));
        final api = testApi(adapter);
        await expectLater(
          api.workItemLabels(_detail(), expectedUserId: 7, generation: 1),
          throwsA(
            isA<ApiFailure>().having(
              (error) => error.kind,
              'kind',
              FailureKind.unsupported,
            ),
          ),
        );
      }

      await expectRejected(_itemNode(labels: [_label(_bug), _label(_bug)]));
      await expectRejected(_itemNode(labels: [_label('gid://gitlab/User/3')]));
      await expectRejected(
        _itemNode(labels: [_label('gid://gitlab/ProjectLabel/0')]),
      );
      await expectRejected(
        _itemNode(labels: [_label('gid://gitlab/ProjectLabel/01')]),
      );
      await expectRejected(_itemNode(labels: [_label(_bug, title: null)]));
      await expectRejected(
        _itemNode(labels: [_label(_bug)], hasNext: true, cursor: null),
      );
    },
  );

  test(
    'permissions and scoped definition do not invent a write gate',
    () async {
      Future<WorkItemLabelAccess> load({
        Object? read = true,
        Object? set = true,
        Object? widgets = '_present',
        Object? scoped = true,
        bool omitScoped = false,
      }) {
        final adapter = FakeAdapter(
          (_) => jsonResponse(
            _envelope(
              _itemNode(
                read: read,
                set: set,
                widgets: widgets == '_present' ? null : widgets,
                scoped: scoped,
                omitScoped: omitScoped,
              ),
            ),
          ),
        );
        return testApi(
          adapter,
        ).workItemLabels(_detail(), expectedUserId: 7, generation: 2);
      }

      final writable = await load();
      expect(writable.canWrite, isTrue);
      expect(
        writable.snapshot.allowsScopedLabels,
        WorkItemLabelAllowsScoped.allowed,
      );
      expect(writable.snapshot.labels.single.color, isNull);
      expect(writable.snapshot.labels.single.textColor, '#0b1d36');

      final disabled = await load(scoped: false);
      expect(disabled.canWrite, isTrue);
      expect(
        disabled.snapshot.allowsScopedLabels,
        WorkItemLabelAllowsScoped.disabled,
      );
      expect(disabled.snapshot.labelIds, [_bug]);

      final unknown = await load(scoped: 'true');
      expect(
        unknown.snapshot.allowsScopedLabels,
        WorkItemLabelAllowsScoped.unknown,
      );
      final missing = await load(omitScoped: true);
      expect(
        missing.snapshot.allowsScopedLabels,
        WorkItemLabelAllowsScoped.unknown,
      );

      for (final read in [false, 0, 'yes', null]) {
        final adapter = FakeAdapter(
          (_) => jsonResponse(_envelope(_itemNode(read: read))),
        );
        await expectLater(
          testApi(
            adapter,
          ).workItemLabels(_detail(), expectedUserId: 7, generation: 1),
          throwsA(
            isA<ApiFailure>().having(
              (error) => error.kind,
              'kind',
              FailureKind.forbidden,
            ),
          ),
        );
        expect(adapter.requests.where(_isMutation), isEmpty);
      }

      for (final set in [false, 0, 'yes', null]) {
        final access = await load(set: set);
        expect(access.canWrite, isFalse);
        expect(access.target, isNull);
        expect(access.snapshot.labelsWidgetPresent, isTrue);
      }

      final noWidget = await load(widgets: const []);
      expect(noWidget.canWrite, isFalse);
      expect(noWidget.target, isNull);
      expect(noWidget.snapshot.setWorkItemMetadata, isTrue);
    },
  );

  test(
    'closed final gate does not announce or send a label mutation',
    () async {
      final events = <String>[];
      final adapter = FakeAdapter((request) {
        expect(_isMutation(request), isFalse);
        return jsonResponse(_envelope(_itemNode()));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemLabels(
        _detail(),
        expectedUserId: 7,
        generation: 1,
      )).target!;
      await expectLater(
        api.updateWorkItemLabels(
          target,
          desiredLabelIds: const [],
          beforeMutation: () async => events.add('before'),
          mayStart: () {
            events.add('gate');
            return false;
          },
          onMutationSent: () => events.add('sent'),
        ),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      expect(events, ['before', 'gate']);
      expect(adapter.requests.where(_isMutation), isEmpty);
    },
  );

  test('fresh unchanged read consumes the target and sends nothing', () async {
    var hooks = 0;
    final adapter = FakeAdapter((request) {
      expect(_isMutation(request), isFalse);
      return jsonResponse(_envelope(_itemNode()));
    });
    final api = testApi(adapter);
    final target = (await api.workItemLabels(
      _detail(),
      expectedUserId: 7,
      generation: 1,
    )).target!;
    final before = adapter.requests.length;
    final result = await api.updateWorkItemLabels(
      target,
      desiredLabelIds: [_bug],
      isCurrent: () => true,
      onMutationSent: () => hooks++,
    );
    expect(result.status, WorkItemLabelSaveStatus.noop);
    expect(result.mutationSent, isFalse);
    expect(result.acknowledgedUpdatedAt, isNull);
    expect(result.snapshot.labelIds, [_bug]);
    expect(target.consumed, isTrue);
    expect(hooks, 0);
    expect(adapter.requests.length, greaterThan(before));
    expect(adapter.requests.where(_isMutation), isEmpty);
    await expectLater(
      api.updateWorkItemLabels(target, desiredLabelIds: const []),
      throwsA(
        isA<WorkItemLabelWriteFailure>()
            .having((error) => error.mutationSent, 'sent', isFalse)
            .having(
              (error) => error.failure.kind,
              'kind',
              FailureKind.writeUncertain,
            ),
      ),
    );
    expect(adapter.requests.where(_isMutation), isEmpty);
  });

  test('preflight denial, non-bool and drift send zero mutations', () async {
    Future<void> expectFence(
      Map<String, Object?> node,
      FailureKind kind,
    ) async {
      var reads = 0;
      final adapter = FakeAdapter((request) {
        reads += 1;
        final nodeForCall = reads == 1 ? _itemNode() : node;
        return jsonResponse(_envelope(nodeForCall));
      });
      final api = testApi(adapter);
      final target = (await api.workItemLabels(
        _detail(),
        expectedUserId: 7,
        generation: 1,
      )).target!;
      await expectLater(
        api.updateWorkItemLabels(target, desiredLabelIds: [_bug, _docs]),
        throwsA(
          isA<WorkItemLabelWriteFailure>()
              .having((error) => error.mutationSent, 'sent', isFalse)
              .having((error) => error.failure.kind, 'kind', kind),
        ),
      );
      expect(adapter.requests.where(_isMutation), isEmpty);
    }

    await expectFence(_itemNode(set: false), FailureKind.forbidden);
    await expectFence(_itemNode(set: 0), FailureKind.forbidden);
    await expectFence(_itemNode(set: 'yes'), FailureKind.forbidden);
    await expectFence(
      _itemNode(actor: 'gid://gitlab/User/8'),
      FailureKind.cancelled,
    );
    await expectFence(
      _itemNode(updatedAt: _touched.toIso8601String()),
      FailureKind.conflict,
    );
    await expectFence(
      _itemNode(namespacePath: 'other/path'),
      FailureKind.conflict,
    );
    await expectFence(_itemNode(widgets: const []), FailureKind.unsupported);
    await expectFence(
      _itemNode(labels: [_label(_bug), _label(_docs)]),
      FailureKind.conflict,
    );
  });

  test(
    'delta uses only opaque project and group ids in connection order',
    () async {
      Map<String, Object?>? sent;
      var hooks = 0;
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) {
          expect(hooks, 1);
          sent = _variables(request)['input'] as Map<String, Object?>;
          return jsonResponse(_ack(_touched));
        }
        final query = _query(request);
        if (query.contains('MobileProjectLabelCandidates')) {
          return jsonResponse(
            _candidateEnvelope([_label(_docs, title: 'docs')]),
          );
        }
        final after = _variables(request)['after'];
        if (query.contains('MobileWorkItemLabels') &&
            after == null &&
            sent == null) {
          return jsonResponse(
            _envelope(
              _itemNode(
                labels: [
                  _label(_bug),
                  _label(_priority, title: 'priority::high'),
                ],
              ),
            ),
          );
        }
        return jsonResponse(
          _envelope(
            _itemNode(
              labels: [
                _label(_priority, title: 'priority::high'),
                _label(_docs, title: 'docs'),
              ],
              updatedAt: _touched.toIso8601String(),
            ),
          ),
        );
      });
      final api = testApi(adapter);
      final access = await api.workItemLabels(
        _detail(),
        expectedUserId: 7,
        generation: 3,
      );
      final target = access.target!;
      final page = await api.searchWorkItemLabelCandidates(
        target,
        search: ' docs ',
        pageIndex: 0,
      );
      expect(page.labels.single.id, _docs);
      final opened = target.opening.readEpoch;
      final result = await api.updateWorkItemLabels(
        target,
        desiredLabelIds: [_priority, _docs],
        onMutationSent: () => hooks++,
      );
      expect(hooks, 1);
      expect(sent!['id'], _item);
      expect(sent!.keys, ['id', 'labelsWidget']);
      final widget = sent!['labelsWidget'] as Map<String, Object?>;
      expect(widget.keys, ['addLabelIds', 'removeLabelIds']);
      expect(widget['addLabelIds'], [_docs]);
      expect(widget['removeLabelIds'], [_bug]);
      expect(jsonEncode(sent), isNot(contains('labelIds')));
      final mutation = adapter.requests.singleWhere(_isMutation);
      expect(_query(mutation), contains('workItem { id updatedAt }'));
      expect(_query(mutation), isNot(contains('currentUser')));
      expect(_query(mutation), isNot(contains('labels {')));
      expect(result.status, WorkItemLabelSaveStatus.success);
      expect(result.mutationSent, isTrue);
      expect(result.acknowledgedUpdatedAt, _touched);
      expect(result.snapshot.updatedAt, _touched);
      expect(result.snapshot.updatedAt, isNot(access.snapshot.updatedAt));
      expect(result.snapshot.labelIds, [_priority, _docs]);
      expect(result.snapshot.actorId, _user);
      expect(result.snapshot.readEpoch, opened);
      expect(adapter.requests.where(_isMutation), hasLength(1));
    },
  );

  test(
    'clear removes every known id and an incomplete catalog does not block it',
    () async {
      Map<String, Object?>? sent;
      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileProjectLabelCandidates')) {
          return jsonResponse(
            _candidateEnvelope(
              [_label(_docs, title: 'docs')],
              hasNext: true,
              cursor: 'more',
            ),
          );
        }
        if (_isMutation(request)) {
          sent = _variables(request)['input'] as Map<String, Object?>;
          return jsonResponse(_ack(_touched));
        }
        final updated = sent != null;
        return jsonResponse(
          _envelope(
            _itemNode(
              labels: updated
                  ? const []
                  : [_label(_bug), _label(_priority, title: 'priority::high')],
              updatedAt: updated ? _touched.toIso8601String() : null,
            ),
          ),
        );
      });
      final api = testApi(adapter);
      final target = (await api.workItemLabels(
        _detail(),
        expectedUserId: 7,
        generation: 1,
      )).target!;
      await api.searchWorkItemLabelCandidates(
        target,
        search: 'docs',
        pageIndex: 0,
      );
      await expectLater(
        api.searchWorkItemLabelCandidates(target, search: 'docs', pageIndex: 5),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
      final before = adapter.requests.length;
      await expectLater(
        api.searchWorkItemLabelCandidates(target, search: 'docs', pageIndex: 5),
        throwsA(isA<ApiFailure>()),
      );
      expect(adapter.requests, hasLength(before));
      final result = await api.updateWorkItemLabels(
        target,
        desiredLabelIds: const [],
      );
      final widget = sent!['labelsWidget'] as Map<String, Object?>;
      expect(widget.containsKey('addLabelIds'), isFalse);
      expect(widget['removeLabelIds'], [_bug, _priority]);
      expect(result.status, WorkItemLabelSaveStatus.success);
      expect(result.snapshot.labelIds, isEmpty);
    },
  );

  test(
    'completed candidate pages survive a bad next page and a scope race',
    () async {
      var candidateCalls = 0;
      var current = true;
      var mutated = false;
      final adapter = FakeAdapter((request) {
        final query = _query(request);
        if (query.contains('MobileGroupLabelCandidates')) {
          candidateCalls += 1;
          if (candidateCalls == 1) {
            return jsonResponse(
              _groupCandidateEnvelope(
                [_label(_docs, title: 'scope::docs')],
                hasNext: true,
                cursor: 'g2',
              ),
            );
          }
          if (candidateCalls == 2) {
            return jsonResponse(
              _groupCandidateEnvelope([_label('gid://gitlab/ProjectLabel/0')]),
            );
          }
          current = false;
          return jsonResponse(
            _groupCandidateEnvelope([
              _label(_priority, title: 'priority::high'),
            ]),
          );
        }
        if (_isMutation(request)) {
          mutated = true;
          return jsonResponse(_ack(_touched));
        }
        return jsonResponse(
          _envelope(
            _groupNode(
              labels: mutated
                  ? [_label(_docs, title: 'scope::docs')]
                  : const [],
              updatedAt: mutated ? _touched.toIso8601String() : null,
            ),
          ),
        );
      });
      final api = testApi(adapter);
      final target = (await api.workItemLabels(
        _groupDetail(),
        expectedUserId: 7,
        generation: 1,
      )).target!;
      final first = await api.searchWorkItemLabelCandidates(
        target,
        search: 'scope',
        pageIndex: 0,
      );
      expect(first.hasNextPage, isTrue);
      final saved = adapter.requests.length;
      await expectLater(
        api.searchWorkItemLabelCandidates(
          target,
          search: 'scope',
          after: 'g2',
          pageIndex: 1,
        ),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.unsupported,
          ),
        ),
      );
      await expectLater(
        api.searchWorkItemLabelCandidates(
          target,
          search: 'scope',
          after: 'stale',
          pageIndex: 1,
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(adapter.requests, hasLength(saved + 1));
      await expectLater(
        api.searchWorkItemLabelCandidates(
          target,
          search: 'scope',
          after: 'g2',
          pageIndex: 1,
          isCurrent: () => current,
        ),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      expect(candidateCalls, 3);
      final result = await api.updateWorkItemLabels(
        target,
        desiredLabelIds: [_docs],
      );
      expect(result.status, WorkItemLabelSaveStatus.success);
      final widget =
          (_variables(adapter.requests.singleWhere(_isMutation))['input']
                  as Map<String, Object?>)['labelsWidget']
              as Map<String, Object?>;
      expect(widget['addLabelIds'], [_docs]);
      expect(adapter.requests.where(_isMutation), hasLength(1));
      final groupQuery = adapter.requests
          .map(_query)
          .firstWhere((query) => query.contains('MobileGroupLabelCandidates'));
      expect(groupQuery, contains('onlyGroupLabels: true'));
      expect(groupQuery, isNot(contains('includeDescendantGroups')));
    },
  );

  test(
    'search rejects an empty, huge or control term before a request',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(_envelope(_itemNode())));
      final api = testApi(adapter);
      final target = (await api.workItemLabels(
        _detail(),
        expectedUserId: 7,
        generation: 1,
      )).target!;
      final before = adapter.requests.length;
      for (final term in ['   ', 'a' * 257, 'bad\nterm', 'bad\x7Fterm']) {
        await expectLater(
          api.searchWorkItemLabelCandidates(target, search: term, pageIndex: 0),
          throwsA(
            isA<ApiFailure>().having(
              (error) => error.kind,
              'kind',
              FailureKind.validation,
            ),
          ),
        );
        await expectLater(
          api.searchWorkItemLabelCandidates(
            target,
            searchTerm: term,
            pageIndex: 0,
          ),
          throwsA(
            isA<ApiFailure>().having(
              (error) => error.kind,
              'kind',
              FailureKind.validation,
            ),
          ),
        );
      }
      await expectLater(
        api.searchWorkItemLabelCandidates(target, pageIndex: 0),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.validation,
          ),
        ),
      );
      await expectLater(
        api.searchWorkItemLabelCandidates(
          target,
          search: 'docs',
          searchTerm: 'other',
          pageIndex: 0,
        ),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.validation,
          ),
        ),
      );
      expect(adapter.requests, hasLength(before));
      final other = testApi(
        FakeAdapter((_) => jsonResponse(_envelope(_itemNode()))),
      );
      await expectLater(
        other.searchWorkItemLabelCandidates(
          target,
          search: 'docs',
          pageIndex: 0,
        ),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
    },
  );

  test('screen candidate search keeps its 20 label page bound', () async {
    for (final count in [20, 21]) {
      final adapter = FakeAdapter((request) {
        if (_query(request).contains('MobileProjectLabelCandidates')) {
          expect(_query(request), contains('first: 20'));
          return jsonResponse(
            _candidateEnvelope([
              for (var i = 1; i <= count; i++)
                _label('gid://gitlab/ProjectLabel/$i', title: 'label$i'),
            ]),
          );
        }
        return jsonResponse(_envelope(_itemNode()));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemLabels(
        _detail(),
        expectedUserId: 7,
        generation: 1,
      )).target!;
      final search = api.searchWorkItemLabelCandidates(
        target,
        search: 'label',
        pageIndex: 0,
      );
      if (count == 20) {
        expect((await search).labels, hasLength(20));
      } else {
        await expectLater(
          search,
          throwsA(
            isA<ApiFailure>().having(
              (error) => error.kind,
              'kind',
              FailureKind.unsupported,
            ),
          ),
        );
      }
    }
  });

  test(
    'candidate search supports CJK terms and preserves CJK label titles',
    () async {
      final adapter = FakeAdapter((request) {
        if (_query(request).contains('MobileProjectLabelCandidates')) {
          return jsonResponse(
            _candidateEnvelope([
              _label(
                'gid://gitlab/ProjectLabel/88',
                title: '標籤::後端::待審查',
                color: '#112233',
              ),
            ]),
          );
        }
        return jsonResponse(_envelope(_itemNode()));
      });
      final api = testApi(adapter);
      final target = (await api.workItemLabels(
        _detail(),
        expectedUserId: 7,
        generation: 1,
      )).target!;
      final page = await api.searchWorkItemLabelCandidates(
        target,
        searchTerm: '  標籤  ',
        pageIndex: 0,
      );
      expect(page.labels.single.id, 'gid://gitlab/ProjectLabel/88');
      expect(page.labels.single.title, '標籤::後端::待審查');
      expect(page.labels.single.color, '#112233');
      expect(page.labels.single.textColor, '#0b1d36');
      expect(workItemLabelScopeKey(page.labels.single.title), '標籤::後端');
    },
  );

  test(
    'candidate search throws unsupported on malformed container or pageInfo',
    () async {
      Future<void> expectMalformed(Map<String, Object?> candidateData) async {
        final adapter = FakeAdapter((request) {
          if (_query(request).contains('MobileProjectLabelCandidates')) {
            return jsonResponse({'data': candidateData});
          }
          return jsonResponse(_envelope(_itemNode()));
        });
        final api = testApi(adapter);
        final target = (await api.workItemLabels(
          _detail(),
          expectedUserId: 7,
          generation: 1,
        )).target!;
        await expectLater(
          api.searchWorkItemLabelCandidates(
            target,
            searchTerm: 'docs',
            pageIndex: 0,
          ),
          throwsA(
            isA<ApiFailure>().having(
              (error) => error.kind,
              'kind',
              FailureKind.unsupported,
            ),
          ),
        );
      }

      // Container is null
      await expectMalformed({
        'currentUser': {'id': _user},
        'project': null,
      });

      // Container missing id
      await expectMalformed({
        'currentUser': {'id': _user},
        'project': {
          'fullPath': _projectPath,
          'labels': {'nodes': <Object>[]},
        },
      });

      // Connection missing pageInfo
      await expectMalformed({
        'currentUser': {'id': _user},
        'project': {
          'id': _project,
          'fullPath': _projectPath,
          'labels': {'nodes': <Object>[], 'pageInfo': null},
        },
      });

      // Node missing id
      await expectMalformed({
        'currentUser': {'id': _user},
        'project': {
          'id': _project,
          'fullPath': _projectPath,
          'labels': {
            'nodes': [
              {'title': 'bug'},
            ],
            'pageInfo': {'hasNextPage': false, 'endCursor': null},
          },
        },
      });
    },
  );

  test(
    'duplicate, empty and unknown ids are validation with zero writes',
    () async {
      Future<void> reject(List<String> desired) async {
        final adapter = FakeAdapter(
          (_) => jsonResponse(_envelope(_itemNode())),
        );
        final api = testApi(adapter);
        final target = (await api.workItemLabels(
          _detail(),
          expectedUserId: 7,
          generation: 1,
        )).target!;
        final before = adapter.requests.length;
        await expectLater(
          api.updateWorkItemLabels(target, desiredLabelIds: desired),
          throwsA(
            isA<WorkItemLabelWriteFailure>()
                .having((error) => error.mutationSent, 'sent', isFalse)
                .having(
                  (error) => error.failure.kind,
                  'kind',
                  FailureKind.validation,
                ),
          ),
        );
        expect(adapter.requests, hasLength(before + 1));
        expect(adapter.requests.where(_isMutation), isEmpty);
      }

      await reject([_bug, _bug]);
      await reject(['']);
      await reject([_docs]);
    },
  );

  test(
    'notApplied keeps the ack revision when the readback set is unchanged',
    () async {
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) return jsonResponse(_ack(_touched));
        if (_query(request).contains('MobileProjectLabelCandidates')) {
          return jsonResponse(
            _candidateEnvelope([_label(_docs, title: 'docs')]),
          );
        }
        return jsonResponse(
          _envelope(_itemNode(updatedAt: _touched.toIso8601String())),
        );
      });
      final api = testApi(adapter);
      final target = (await api.workItemLabels(
        _detail(),
        expectedUserId: 7,
        generation: 1,
      )).target!;
      await api.searchWorkItemLabelCandidates(
        target,
        search: 'docs',
        pageIndex: 0,
      );
      final result = await api.updateWorkItemLabels(
        target,
        desiredLabelIds: [_bug, _docs],
      );
      expect(result.status, WorkItemLabelSaveStatus.notApplied);
      expect(result.mutationSent, isTrue);
      expect(result.acknowledgedUpdatedAt, _touched);
      expect(result.snapshot.updatedAt, _touched);
      expect(result.snapshot.labelIds, [_bug]);
      expect(adapter.requests.where(_isMutation), hasLength(1));
    },
  );

  test(
    'post-read actor change or old revision is uncertain and is not replayed',
    () async {
      Future<void> expectOnce({required bool changeActor}) async {
        var itemReads = 0;
        var mutations = 0;
        final adapter = FakeAdapter((request) {
          if (_query(request).contains('MobileProjectLabelCandidates')) {
            return jsonResponse(
              _candidateEnvelope([_label(_docs, title: 'docs')]),
            );
          }
          if (_isMutation(request)) {
            mutations += 1;
            return jsonResponse(_ack(_touched));
          }
          itemReads += 1;
          final post = itemReads > 2;
          return jsonResponse(
            _envelope(
              _itemNode(
                actor: post && changeActor ? 'gid://gitlab/User/8' : _user,
                updatedAt: post && !changeActor
                    ? _opened.toIso8601String()
                    : (post ? _touched.toIso8601String() : null),
              ),
            ),
          );
        });
        final api = testApi(adapter);
        final target = (await api.workItemLabels(
          _detail(),
          expectedUserId: 7,
          generation: 1,
        )).target!;
        await api.searchWorkItemLabelCandidates(
          target,
          search: 'docs',
          pageIndex: 0,
        );
        await expectLater(
          api.updateWorkItemLabels(target, desiredLabelIds: [_bug, _docs]),
          throwsA(
            isA<WorkItemLabelWriteFailure>()
                .having((error) => error.mutationSent, 'sent', isTrue)
                .having(
                  (error) => error.failure.kind,
                  'kind',
                  FailureKind.writeUncertain,
                ),
          ),
        );
        expect(mutations, 1);
      }

      await expectOnce(changeActor: true);
      await expectOnce(changeActor: false);
    },
  );

  test(
    'handoff failure, malformed ack and transport are one write with no replay',
    () async {
      Future<void> expectSent(
        ResponseBody Function(RequestOptions request) mutation,
        FailureKind kind,
      ) async {
        var mutations = 0;
        var hooks = 0;
        var settled = 0;
        final adapter = FakeAdapter((request) {
          if (_isMutation(request)) {
            mutations += 1;
            expect(hooks, 1);
            return mutation(request);
          }
          return jsonResponse(_envelope(_itemNode()));
        });
        final api = testApi(adapter);
        final target = (await api.workItemLabels(
          _detail(),
          expectedUserId: 7,
          generation: 1,
        )).target!;
        try {
          await api.updateWorkItemLabels(
            target,
            desiredLabelIds: const [],
            onMutationSent: () => hooks++,
          );
          fail('expected write failure');
        } on WorkItemLabelWriteFailure catch (error) {
          expect(error.mutationSent, isTrue);
          expect(error.failure.kind, kind);
        } finally {
          if (hooks > 0) settled += 1;
        }
        expect(hooks, 1);
        expect(settled, 1);
        expect(mutations, 1);
      }

      await expectSent(
        (_) => jsonResponse(_ack(_touched), status: 400),
        FailureKind.writeUncertain,
      );
      await expectSent(
        (_) => jsonResponse(_ack(_touched), status: 422),
        FailureKind.writeUncertain,
      );
      await expectSent(
        (request) => throw DioException(
          requestOptions: request,
          type: DioExceptionType.cancel,
        ),
        FailureKind.writeUncertain,
      );
      await expectSent(
        (_) => jsonResponse({
          'data': {
            'workItemUpdate': {
              'errors': [1, 'bad'],
              'workItem': {
                'id': _item,
                'updatedAt': _touched.toIso8601String(),
              },
            },
          },
        }),
        FailureKind.writeUncertain,
      );
      await expectSent(
        (_) => jsonResponse({
          'data': {
            'workItemUpdate': {
              'errors': <String>[],
              'workItem': {
                'id': 'gid://gitlab/WorkItem/101',
                'updatedAt': _touched.toIso8601String(),
              },
            },
          },
        }),
        FailureKind.writeUncertain,
      );
      await expectSent(
        (_) => jsonResponse({
          'data': {
            'workItemUpdate': ['not-a-map'],
          },
        }),
        FailureKind.writeUncertain,
      );
      await expectSent(
        (_) => jsonResponse({
          'data': {
            'workItemUpdate': {
              'errors': <String>[],
              'workItem': {'id': _item, 'updatedAt': 'not-a-timestamp'},
            },
          },
        }),
        FailureKind.writeUncertain,
      );
      await expectSent(
        (_) => jsonResponse({
          'errors': [
            {'message': 'Top-level GraphQL error'},
          ],
        }),
        FailureKind.writeUncertain,
      );
      await expectSent(
        (_) => jsonResponse({
          'data': {
            'workItemUpdate': {
              'errors': ['Label is invalid'],
              'workItem': null,
            },
          },
        }),
        FailureKind.validation,
      );
    },
  );

  test('a closed client before send does not call the hook', () async {
    var hooks = 0;
    final adapter = FakeAdapter((_) => jsonResponse(_envelope(_itemNode())));
    final api = testApi(adapter);
    final target = (await api.workItemLabels(
      _detail(),
      expectedUserId: 7,
      generation: 1,
    )).target!;
    final before = adapter.requests.length;
    api.close();
    await expectLater(
      api.updateWorkItemLabels(
        target,
        desiredLabelIds: const [],
        onMutationSent: () => hooks++,
      ),
      throwsA(
        isA<WorkItemLabelWriteFailure>()
            .having((error) => error.mutationSent, 'sent', isFalse)
            .having(
              (error) => error.failure.kind,
              'kind',
              FailureKind.cancelled,
            ),
      ),
    );
    expect(hooks, 0);
    expect(adapter.requests, hasLength(before));
    final otherAdapter = FakeAdapter(
      (_) => jsonResponse(_envelope(_itemNode())),
    );
    final other = testApi(otherAdapter);
    await expectLater(
      other.searchWorkItemLabelCandidates(target, search: 'docs', pageIndex: 0),
      throwsA(
        isA<ApiFailure>().having(
          (error) => error.kind,
          'kind',
          FailureKind.cancelled,
        ),
      ),
    );
    expect(otherAdapter.requests, isEmpty);
  });

  test(
    'closing during mutation handoff is uncertain and is not replayed',
    () async {
      late GitLabApi api;
      var mutations = 0;
      final adapter = FakeAdapter((request) {
        if (_isMutation(request)) {
          mutations += 1;
          api.close();
          return jsonResponse(_ack(_touched));
        }
        return jsonResponse(_envelope(_itemNode()));
      });
      api = testApi(adapter);
      final target = (await api.workItemLabels(
        _detail(),
        expectedUserId: 7,
        generation: 1,
      )).target!;
      await expectLater(
        api.updateWorkItemLabels(target, desiredLabelIds: const []),
        throwsA(
          isA<WorkItemLabelWriteFailure>()
              .having((error) => error.mutationSent, 'sent', isTrue)
              .having(
                (error) => error.failure.kind,
                'kind',
                FailureKind.writeUncertain,
              ),
        ),
      );
      expect(mutations, 1);
    },
  );

  test('save and search source do not compare the read epoch', () {
    final source = File(
      'lib/core/work_item_labels_api.dart',
    ).readAsStringSync();
    String between(String start, String end) {
      final from = source.indexOf(start);
      final to = source.indexOf(end, from + start.length);
      expect(from, greaterThanOrEqualTo(0));
      expect(to, greaterThan(from));
      return source.substring(from, to);
    }

    final search = between(
      'searchWorkItemLabelCandidates',
      'updateWorkItemLabels',
    );
    final update = between('updateWorkItemLabels', '_readLabelCatalog');
    expect(search.contains('_readEpoch'), isFalse);
    expect(update.contains('_readEpoch'), isFalse);
    expect(update.contains('.readEpoch'), isFalse);
    expect(update.contains('opening.generation'), isFalse);
    expect(
      between(
        'workItemLabels',
        'searchWorkItemLabelCandidates',
      ).contains('_readEpoch'),
      isTrue,
    );
    expect(source.contains('addLabelIds'), isTrue);
    expect(source.contains('removeLabelIds'), isTrue);
    expect(source.contains('labelIds:'), isFalse);
  });
}

bool _isMutation(RequestOptions request) =>
    _query(request).contains('mutation MobileUpdateWorkItemLabels');

String _query(RequestOptions request) =>
    (request.data as Map)['query'] as String;

Map<String, Object?> _variables(RequestOptions request) =>
    ((request.data as Map)['variables'] as Map).cast<String, Object?>();

List<String> _queries(FakeAdapter adapter) =>
    adapter.requests.map(_query).toList();

Map<String, Object?> _label(
  String id, {
  String? title = 'bug',
  String? color = 'not-a-color',
}) => {'id': id, 'title': ?title, 'color': color, 'textColor': '#0b1d36'};

Map<String, Object?> _ownedGroupLabel(int id, {String title = 'group label'}) =>
    _label('gid://gitlab/GroupLabel/$id', title: title);

List<Map<String, Object?>> _numbered(int start, int count) => [
  for (var id = start; id < start + count; id++)
    {
      'id': 'gid://gitlab/ProjectLabel/$id',
      'title': 'label-$id',
      'color': '#112233',
      'textColor': '#ffffff',
    },
];

Map<String, Object?> _envelope(Object? workItem, {String? actor}) => {
  'data': {
    'currentUser': {
      'id':
          actor ??
          (workItem is Map ? workItem['_actor'] as String? : null) ??
          _user,
    },
    'workItem': workItem,
  },
};

Map<String, Object?> _itemNode({
  Object? labels,
  bool hasNext = false,
  String? cursor,
  Object? read = true,
  Object? set = true,
  Object? widgets,
  Object? scoped = true,
  bool omitScoped = false,
  String actor = _user,
  String? updatedAt,
  String namespacePath = _projectPath,
}) {
  final nodes = labels ?? [_label(_bug)];
  final widgetList =
      widgets ??
      [
        {
          'type': 'LABELS',
          'labels': {
            'nodes': nodes,
            'pageInfo': {'hasNextPage': hasNext, 'endCursor': cursor},
          },
        },
      ];
  return {
    '_actor': actor,
    'id': _item,
    'iid': '15',
    'title': 'Mobile parity',
    'state': 'OPEN',
    'createdAt': _opened.toIso8601String(),
    'updatedAt': updatedAt ?? _opened.toIso8601String(),
    'project': {'id': _project, 'fullPath': _projectPath},
    'namespace': {'id': _namespace, 'fullPath': namespacePath},
    'workItemType': {
      'id': _type,
      'name': 'Issue',
      'widgetDefinitions': [
        {'type': 'LABELS', if (!omitScoped) 'allowsScopedLabels': scoped},
      ],
    },
    'userPermissions': {
      'readWorkItem': read,
      'setWorkItemMetadata': set,
      'adminWorkItem': true,
      'updateWorkItem': true,
    },
    'widgets': widgetList,
  };
}

Map<String, Object?> _groupNode({
  required Object labels,
  String? updatedAt,
  String actor = _user,
  String groupId = _group,
}) => {
  '_actor': actor,
  'id': _item,
  'iid': '15',
  'title': 'Group parity',
  'state': 'OPEN',
  'createdAt': _opened.toIso8601String(),
  'updatedAt': updatedAt ?? _opened.toIso8601String(),
  'project': null,
  'namespace': {'id': groupId, 'fullPath': _groupPath},
  'workItemType': {
    'id': _type,
    'name': 'Issue',
    'widgetDefinitions': [
      {'type': 'LABELS', 'allowsScopedLabels': false},
    ],
  },
  'userPermissions': {'readWorkItem': true, 'setWorkItemMetadata': true},
  'widgets': [
    {
      'type': 'LABELS',
      'labels': {
        'nodes': labels,
        'pageInfo': {'hasNextPage': false, 'endCursor': null},
      },
    },
  ],
};

Map<String, Object?> _candidateEnvelope(
  List<Map<String, Object?>> labels, {
  bool hasNext = false,
  String? cursor,
}) => {
  'data': {
    'currentUser': {'id': _user},
    'project': {
      'id': _project,
      'fullPath': _projectPath,
      'labels': {
        'nodes': labels,
        'pageInfo': {'hasNextPage': hasNext, 'endCursor': cursor},
      },
    },
  },
};

Map<String, Object?> _groupCandidateEnvelope(
  List<Map<String, Object?>> labels, {
  bool hasNext = false,
  String? cursor,
}) => {
  'data': <String, Object?>{
    'currentUser': {'id': _user},
    'group': {
      'id': _group,
      'fullPath': _groupPath,
      'labels': {
        'nodes': labels,
        'pageInfo': {'hasNextPage': hasNext, 'endCursor': cursor},
      },
    },
  },
};

Map<String, Object?> _ack(DateTime updatedAt, {bool actorIgnored = false}) => {
  'data': {
    if (actorIgnored) 'currentUser': {'id': 'gid://gitlab/User/8'},
    'workItemUpdate': {
      'errors': <String>[],
      'workItem': {'id': _item, 'updatedAt': updatedAt.toIso8601String()},
    },
  },
};

WorkItemGraphDetail _detail() => WorkItemGraphDetail(
  summary: WorkItemGraphSummary(
    id: _item,
    iid: 15,
    title: 'Mobile parity',
    state: 'OPEN',
    createdAt: _opened,
    updatedAt: _opened,
    project: const GraphResourceRef(id: _project, fullPath: _projectPath),
    namespace: const GraphResourceRef(id: _namespace, fullPath: _projectPath),
    type: const WorkItemGraphType(id: _type, name: 'Issue'),
  ),
  description: null,
  widgetsAvailable: true,
  widgetTypes: const {'LABELS'},
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

WorkItemGraphDetail _groupDetail({String groupId = _group}) => WorkItemGraphDetail(
  summary: WorkItemGraphSummary(
    id: _item,
    iid: 15,
    title: 'Group parity',
    state: 'OPEN',
    createdAt: _opened,
    updatedAt: _opened,
    project: null,
    namespace: GraphResourceRef(id: groupId, fullPath: _groupPath),
    type: const WorkItemGraphType(id: _type, name: 'Issue'),
  ),
  description: null,
  widgetsAvailable: true,
  widgetTypes: const {'LABELS'},
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);
