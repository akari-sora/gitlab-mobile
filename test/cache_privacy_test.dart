import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 20);
const _issuePath = ['projects', '8', 'issues', '1'];
const _notesPath = ['projects', '8', 'issues', '1', 'notes'];

void main() {
  test(
    'newly confidential direct issue revokes old subtree reads and list snapshots',
    () async {
      final oldIssue = Completer<ResponseBody>();
      final oldNotes = Completer<ResponseBody>();
      var issueCalls = 0;
      var noteCalls = 0;
      var userListCalls = 0;
      var groupListCalls = 0;
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/8/issues/1')) {
          issueCalls++;
          if (issueCalls == 1) return oldIssue.future;
          return jsonResponse(_issue(confidential: true, title: 'private'));
        }
        if (path.endsWith('/projects/8/issues/1/notes')) {
          noteCalls++;
          if (noteCalls == 1) return oldNotes.future;
          return jsonResponse([
            {'id': 2, 'body': 'new note'},
          ]);
        }
        if (path.endsWith('/issues')) {
          if (path.endsWith('/groups/3/issues')) {
            groupListCalls++;
          } else {
            userListCalls++;
          }
          return jsonResponse([
            _issue(
              confidential: issueCalls > 1,
              title: issueCalls > 1 ? 'private' : 'public',
            ),
          ]);
        }
        throw StateError('Unexpected request: ${request.method} $path');
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await api.cachedRecords(['issues']);
      await api.cachedRecords(['groups', '3', 'issues']);
      await api.cachedRecords(['issues']);
      await api.cachedRecords(['groups', '3', 'issues']);
      expect(userListCalls, 1);
      expect(groupListCalls, 1);

      final pendingIssue = api.cachedRecord(_issuePath);
      final pendingNotes = api.cachedRecords(_notesPath);
      await _until(() => issueCalls == 1 && noteCalls == 1);

      final current = await api.record(_issuePath).timeout(_deadline);
      expect(current['confidential'], isTrue);
      expect(current['title'], 'private');

      final issueRejected = expectLater(
        pendingIssue,
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      final notesRejected = expectLater(
        pendingNotes,
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      oldIssue.complete(jsonResponse(_issue(title: 'old issue')));
      oldNotes.complete(
        jsonResponse([
          {'id': 1, 'body': 'old note'},
        ]),
      );
      await Future.wait([issueRejected, notesRejected]).timeout(_deadline);

      expect(
        (await api.cachedRecords(['issues'])).value.items.single['title'],
        'private',
      );
      expect(
        (await api.cachedRecords([
          'groups',
          '3',
          'issues',
        ])).value.items.single['title'],
        'private',
      );
      expect(userListCalls, 2);
      expect(groupListCalls, 2);
    },
  );

  test('confidential cached issue remains displayable and reusable', () async {
    var calls = 0;
    final adapter = FakeAdapter((_) {
      calls++;
      return jsonResponse(_issue(confidential: true, title: 'private'));
    });
    final api = _boundApi(adapter);
    addTearDown(api.close);

    final first = await api.cachedRecord(_issuePath).timeout(_deadline);
    final second = await api.cachedRecord(_issuePath).timeout(_deadline);

    expect(first.value['confidential'], isTrue);
    expect(first.superseded, isFalse);
    expect(second.value['title'], 'private');
    expect(second.lineage, CacheLineage.memory);
    expect(calls, 1);
  });
}

Map<String, Object?> _issue({
  bool confidential = false,
  String title = 'issue',
}) => {
  'id': 101,
  'project_id': 8,
  'iid': 1,
  'title': title,
  'confidential': confidential,
};

GitLabApi _boundApi(FakeAdapter adapter) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-test-token',
    dio: Dio()..httpClientAdapter = adapter,
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}

Future<void> _until(bool Function() done) async {
  final until = DateTime.now().add(_deadline);
  while (!done()) {
    if (!DateTime.now().isBefore(until)) {
      throw TimeoutException('condition', _deadline);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
