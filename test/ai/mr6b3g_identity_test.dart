import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/core/group_work_item_identity.dart';
import 'package:gitlab_mobile/core/instance.dart';

void main() {
  group('G0a exact Group GIDs', () {
    test('accepts positive canonical IDs through the native integer limit', () {
      for (final id in <int>[1, 7, 91, 9223372036854775807]) {
        expect(groupKeyNumericId('gid://gitlab/Group/$id'), id);
        expect(
          groupKeyGid(id, serverGroupGid: 'gid://gitlab/Group/$id'),
          'gid://gitlab/Group/$id',
        );
      }
    });

    test('rejects wrong GID types, noncanonical numbers and trailing data', () {
      for (final gid in <String>[
        '',
        '7',
        'gid://gitlab/WorkItem/7',
        'gid://gitlab/Project/7',
        'gid://gitlab/Namespaces::ProjectNamespace/7',
        'gid://gitlab/Epic/7',
        'gid://gitlab/Note/7',
        'gid://gitlab/Group/',
        'gid://gitlab/Group/0',
        'gid://gitlab/Group/-1',
        'gid://gitlab/Group/+1',
        'gid://gitlab/Group/01',
        'gid://gitlab/Group/007',
        'gid://gitlab/Group/1.0',
        'gid://gitlab/Group/1e2',
        'gid://gitlab/Group/0x7',
        'gid://gitlab/Group/７',
        'gid://gitlab/Group/9223372036854775808',
        'gid://gitlab/Group/18446744073709551615',
        'gid://gitlab/Group/${'9' * 100}',
        'gid://gitlab/Group/7/',
        'gid://gitlab/Group/7x',
        'gid://gitlab/Group/7?x=1',
        'gid://gitlab/Group/7#x',
        'gid://gitlab/Group/7\n',
        'gid://gitlab/Group/7\r\n',
        'gid://gitlab/Group/7\u0000',
        'gid://gitlab/Group/7 ',
        ' gid://gitlab/Group/7',
        'GID://gitlab/Group/7',
        'gid://GitLab/Group/7',
        'gid://gitlab/group/7',
        'gid://other/Group/7',
        'gid://user@gitlab/Group/7',
        'gid://gitlab:443/Group/7',
        'gid://gitlab//Group/7',
        'gid://gitlab/Group/%37',
        'gid://gitlab/Group/../7',
      ]) {
        expect(groupKeyNumericId(gid), isNull, reason: gid);
        expect(groupKeyGid(7, serverGroupGid: gid), isNull, reason: gid);
      }
      for (final id in <int>[0, -1, -9223372036854775807]) {
        expect(
          groupKeyGid(id, serverGroupGid: 'gid://gitlab/Group/$id'),
          isNull,
          reason: '$id',
        );
      }
    });
  });

  group('G0a server identity', () {
    test('identity key parts equal the ledger scope key and journal lock', () {
      final identity = _identity()!;
      final scopeKey = aiWriteScopeKey(
        identity.accountKey,
        AiScopeGrant(
          kind: AiScopeKind.groupWorkItem,
          groupId: identity.groupId,
          groupFullPath: identity.fullPath,
          iid: identity.iid,
        ),
      );
      final scopeParts = scopeKey.substring(1, scopeKey.length - 1).split(', ');
      expect(identity.keyParts, scopeParts);
      expect(identity.canonicalKey, scopeKey);
      expect(
        AiConflictKey(identity.keyParts).intersects(AiConflictKey(scopeParts)),
        isTrue,
      );
    });

    test('captures the direct owner, account and read binding', () {
      final identity = _identity()!;
      expect(identity.accountKey, 'https://gitlab.example:8443/gitlab#5');
      expect(identity.groupId, 7);
      expect(identity.groupGid, 'gid://gitlab/Group/7');
      expect(identity.fullPath, 'team/sub');
      expect(identity.iid, 4);
      expect(identity.workItemGid, 'gid://gitlab/WorkItem/91');
      expect(identity.keyParts, <String>[
        identity.accountKey,
        'group:7',
        'workItem',
        '4',
      ]);
      expect(() => identity.keyParts.add('other'), throwsUnsupportedError);
      expect(
        identity.canonicalKey,
        '(https://gitlab.example:8443/gitlab#5, group:7, workItem, 4)',
      );
    });

    test('a numeric Work Item ID never substitutes for a numeric Group ID', () {
      expect(
        groupKeyGid(91, serverGroupGid: 'gid://gitlab/WorkItem/91'),
        isNull,
      );
      expect(groupKeyGid(91, serverGroupGid: 'gid://gitlab/Group/7'), isNull);
      expect(_identity(groupId: 91), isNull);
      final raw = _namespace();
      raw['id'] = 'gid://gitlab/WorkItem/7';
      (raw['workItem']!
          as Map<String, Object?>)['namespace'] = <String, Object?>{
        'id': 'gid://gitlab/WorkItem/7',
        'fullPath': 'team/sub',
      };
      expect(_identity(namespace: raw), isNull);
    });

    test(
      'requires explicit project:null and exact nested namespace evidence',
      () {
        final mutations = <void Function(Map<String, Object?>)>[
          (raw) => raw.remove('id'),
          (raw) => raw['id'] = 'gid://gitlab/Group/8',
          (raw) => raw['fullPath'] = 'other',
          (raw) => raw.remove('workItem'),
          (raw) => raw['workItem'] = <Object?>[],
          (raw) => _item(raw).remove('project'),
          (raw) => _item(raw)['project'] = <String, Object?>{
            'id': 'gid://gitlab/Project/7',
            'fullPath': 'team/sub/project',
          },
          (raw) => _item(raw).remove('namespace'),
          (raw) => _item(raw)['namespace'] = null,
          (raw) => _item(raw)['namespace'] = <String, Object?>{
            'id': 'gid://gitlab/Group/8',
            'fullPath': 'team/sub',
          },
          (raw) => _item(raw)['namespace'] = <String, Object?>{
            'id': 'gid://gitlab/Group/7',
            'fullPath': 'team/sub/descendant',
          },
          (raw) => _item(raw)['id'] = 'gid://gitlab/Epic/91',
          (raw) => _item(raw)['id'] = 'gid://gitlab/Group/91',
          (raw) => _item(raw)['id'] = '91',
          (raw) => _item(raw)['id'] = 'gid://gitlab/WorkItem/091',
          (raw) =>
              _item(raw)['id'] = 'gid://gitlab/WorkItem/9223372036854775808',
          (raw) => _item(raw)['iid'] = '5',
          (raw) => _item(raw)['iid'] = '04',
          (raw) => _item(raw)['iid'] = 4.0,
          (raw) => _item(raw)['iid'] = null,
        ];
        for (var index = 0; index < mutations.length; index++) {
          final raw = _namespace();
          mutations[index](raw);
          expect(_identity(namespace: raw), isNull, reason: 'evidence $index');
        }
        final numericIid = _namespace();
        _item(numericIid)['iid'] = 4;
        expect(_identity(namespace: numericIid), isNotNull);
      },
    );

    test('requires a numeric actor and safe app-owned coordinates', () {
      expect(_identity(userId: 0), isNull);
      expect(_identity(actorUserId: 6), isNull);
      expect(_identity(groupId: 0), isNull);
      expect(_identity(iid: 0), isNull);
      expect(_identity(generation: -1), isNull);
      expect(_identity(readEpoch: -1), isNull);
      for (final path in <String>[
        '',
        '/team',
        'team/',
        'team//sub',
        'team/../sub',
        'team/./sub',
        'team\\sub',
        'team/%2e%2e/sub',
        'team?x',
        'team#x',
        'team/ sub',
        'team/sub\n',
        'team/sub\u200b',
        'team/中文',
        'team/@sub',
        'team/sub:other',
        'team/-/sub',
      ]) {
        expect(
          _identity(
            path: path,
            namespace: _namespace(path: path),
          ),
          isNull,
          reason: path,
        );
      }
      for (final path in ['team-1/sub_group.v2', 'Team/123']) {
        expect(
          _identity(
            path: path,
            namespace: _namespace(path: path),
          ),
          isNotNull,
          reason: path,
        );
      }
    });

    test(
      'rename keeps the numeric key; owners and sibling IIDs stay distinct',
      () {
        final identity = _identity()!;
        final renamed = _identity(
          path: 'renamed/sub',
          namespace: _namespace(path: 'renamed/sub'),
        )!;
        expect(renamed.canonicalKey, identity.canonicalKey);
        expect(renamed.keyParts, identity.keyParts);
        expect(renamed.fullPath, isNot(identity.fullPath));
        expect(
          _identity(
            groupId: 8,
            namespace: _namespace(groupId: 8),
          )!.canonicalKey,
          isNot(identity.canonicalKey),
        );
        expect(
          _identity(iid: 5, namespace: _namespace(iid: 5))!.canonicalKey,
          isNot(identity.canonicalKey),
        );
        expect(identity.keyParts, isNot(contains('project:7')));
      },
    );

    test(
      'reusing evidence requires account, identical API, generation and epoch',
      () {
        final owner = Object();
        final identity = _identity(apiOwner: owner)!;
        bool current({
          String? account,
          Object? api,
          int generation = 3,
          int epoch = 2,
        }) => identity.isCurrent(
          accountKey: account ?? identity.accountKey,
          apiOwner: api ?? owner,
          generation: generation,
          readEpoch: epoch,
        );
        expect(current(), isTrue);
        expect(current(api: Object()), isFalse);
        expect(current(generation: 4), isFalse);
        expect(current(epoch: 3), isFalse);
        for (final account in <String>[
          'https://gitlab.example:8443/gitlab#6',
          'https://other.example:8443/gitlab#5',
          'https://gitlab.example/gitlab#5',
          'https://gitlab.example:8443/other#5',
          'http://gitlab.example:8443/gitlab#5',
        ]) {
          expect(current(account: account), isFalse, reason: account);
        }
      },
    );

    test(
      'note numeric IDs and typed GID aliases share one parent-bound key',
      () {
        final identity = _identity()!;
        final key = '${identity.canonicalKey}/note:12';
        expect(identity.canonicalNoteKey(noteId: 12), key);
        for (final type in <String>['Note', 'DiscussionNote']) {
          expect(
            identity.canonicalNoteKey(noteGid: 'gid://gitlab/$type/12'),
            key,
          );
          expect(
            identity.canonicalNoteKey(
              noteId: 12,
              noteGid: 'gid://gitlab/$type/12',
            ),
            key,
          );
        }
        expect(identity.canonicalNoteKey(noteId: 0), isNull);
        expect(identity.canonicalNoteKey(noteId: -1), isNull);
        expect(identity.canonicalNoteKey(), isNull);
        expect(
          identity.canonicalNoteKey(
            noteId: 13,
            noteGid: 'gid://gitlab/Note/12',
          ),
          isNull,
        );
        for (final gid in <String>[
          '12',
          'gid://gitlab/Group/12',
          'gid://gitlab/WorkItem/12',
          'gid://gitlab/Note/0',
          'gid://gitlab/Note/012',
          'gid://gitlab/Note/9223372036854775808',
          'gid://gitlab/Note/12\n',
        ]) {
          expect(identity.canonicalNoteKey(noteGid: gid), isNull, reason: gid);
        }
      },
    );
  });
}

VerifiedGroupWorkItemIdentity? _identity({
  int userId = 5,
  int actorUserId = 5,
  int groupId = 7,
  int iid = 4,
  String path = 'team/sub',
  Map<String, Object?>? namespace,
  Object? apiOwner,
  int generation = 3,
  int readEpoch = 2,
}) => VerifiedGroupWorkItemIdentity.fromServerEvidence(
  instance: GitLabInstance.parse('https://gitlab.example:8443/gitlab'),
  expectedUserId: userId,
  actorUserId: actorUserId,
  expectedGroupId: groupId,
  expectedFullPath: path,
  expectedIid: iid,
  namespace: namespace ?? _namespace(),
  apiOwner: apiOwner ?? Object(),
  generation: generation,
  readEpoch: readEpoch,
);

Map<String, Object?> _namespace({
  int groupId = 7,
  int iid = 4,
  String path = 'team/sub',
}) => <String, Object?>{
  'id': 'gid://gitlab/Group/$groupId',
  'fullPath': path,
  'workItem': <String, Object?>{
    'id': 'gid://gitlab/WorkItem/91',
    'iid': '$iid',
    'project': null,
    'namespace': <String, Object?>{
      'id': 'gid://gitlab/Group/$groupId',
      'fullPath': path,
    },
  },
};

Map<String, Object?> _item(Map<String, Object?> raw) =>
    raw['workItem']! as Map<String, Object?>;
