import 'release_policy_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';

const _account = 'https://gitlab.example.test#7';

AiWriteScope _scope(AiScopeKind kind, {int? projectId}) => AiWriteScope(
  accountKey: _account,
  grants: <AiScopeGrant>[
    AiScopeGrant(kind: kind, projectId: projectId, projectPath: 'group/app'),
  ],
);

const _global = AiCapability(
  operationId: 'markAllTodosDone',
  baseTier: AiWriteTier.t4,
  scopeClass: AiScopeClass.accountGlobalOnly,
);
const _create = AiCapability(
  operationId: 'createProject',
  baseTier: AiWriteTier.hardLine,
  scopeClass: AiScopeClass.personalNamespace,
);
const _fork = AiCapability(
  operationId: 'forkProject',
  baseTier: AiWriteTier.hardLine,
  scopeClass: AiScopeClass.personalNamespace,
);

final class _TestLedger implements AiCapabilityLedger {
  const _TestLedger(this.rows);

  final List<AiCapability> rows;

  @override
  AiCapability? find(String operationId) {
    for (final row in rows) {
      if (row.operationId == operationId) return row;
    }
    return null;
  }

  @override
  List<AiCapability> get modelVisible => rows;
}

const _newScopeRows = _TestLedger(<AiCapability>[_global, _create, _fork]);

void main() {
  test('new scope classes are offered only by their intended grants', () {
    expect(
      toolsForScope(_scope(AiScopeKind.accountGlobal), ledger: _newScopeRows, releasePolicy: fixtureReleasePolicy),
      <AiCapability>[_global],
    );
    expect(
      toolsForScope(
        _scope(AiScopeKind.project, projectId: 42),
        ledger: _newScopeRows, releasePolicy: fixtureReleasePolicy
      ),
      <AiCapability>[_create, _fork],
    );
    expect(
      toolsForScope(
        _scope(AiScopeKind.workItem, projectId: 42),
        ledger: _newScopeRows, releasePolicy: fixtureReleasePolicy
      ),
      isEmpty,
    );
  });

  test('account-global-only rows require an account-global grant', () {
    final account = _scope(AiScopeKind.accountGlobal);
    final project = _scope(AiScopeKind.project, projectId: 42);
    final target = AiTargetRef(kind: AiTargetKind.project);

    expect(scopeAdmits(account, _global, target), isTrue);
    expect(scopeAdmits(project, _global, target), isFalse);
  });

  test('createProject is offered and admitted by a project grant', () {
    final project = _scope(AiScopeKind.project, projectId: 42);
    final issue = _scope(AiScopeKind.workItem, projectId: 42);
    final target = AiTargetRef(kind: AiTargetKind.project);

    expect(scopeAdmits(project, _create, target), isTrue);
    expect(scopeAdmits(issue, _create, target), isFalse);
  });

  test('forkProject admits only the matching source project grant', () {
    final project = _scope(AiScopeKind.project, projectId: 42);
    final matching = AiTargetRef(kind: AiTargetKind.project, projectId: 42);
    final other = AiTargetRef(kind: AiTargetKind.project, projectId: 99);

    expect(scopeAdmits(project, _fork, matching), isTrue);
    expect(scopeAdmits(project, _fork, other), isFalse);
  });
}
