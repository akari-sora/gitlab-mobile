import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';

const _account = 'https://gitlab.example.test#7';

AiWriteScope _scope(AiScopeKind kind, int projectId) => AiWriteScope(
  accountKey: _account,
  grants: [
    AiScopeGrant(
      kind: kind,
      projectId: projectId,
      projectPath: 'group/project-$projectId',
      iid: kind == AiScopeKind.project ? null : 12,
    ),
  ],
);

AiCapability _row(String operationId) => productionAiLedger.modelVisible
    .firstWhere((row) => row.operationId == operationId);

final _project42 = AiTargetRef(kind: AiTargetKind.project, projectId: 42);

void main() {
  final upload = _row('upload_attachment');

  test('an issue or merge request conversation offers uploads', () {
    for (final kind in [
      AiScopeKind.project,
      AiScopeKind.workItem,
      AiScopeKind.mergeRequest,
    ]) {
      expect(
        toolsForScope(_scope(kind, 42)),
        contains(upload),
        reason: '$kind',
      );
    }
  });

  test('uploads go only into the project of a grant', () {
    for (final kind in [
      AiScopeKind.project,
      AiScopeKind.workItem,
      AiScopeKind.mergeRequest,
    ]) {
      expect(scopeAdmits(_scope(kind, 42), upload, _project42), isTrue);
      expect(scopeAdmits(_scope(kind, 99), upload, _project42), isFalse);
    }
  });

  test('an issue grant still does not cover project-wide writes', () {
    final createLabel = _row('createLabel');
    expect(
      toolsForScope(_scope(AiScopeKind.workItem, 42)),
      isNot(contains(createLabel)),
    );
    expect(
      scopeAdmits(_scope(AiScopeKind.workItem, 42), createLabel, _project42),
      isFalse,
    );
  });
}
