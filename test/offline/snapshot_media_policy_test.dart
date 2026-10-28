import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/offline/snapshot_media_policy.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';

void main() {
  const policy = SnapshotMediaPolicy(
    accountKey: 'account',
    instanceKey: 'instance',
    projectId: 10,
    projectPath: 'team/project',
    sha: 'sha',
    refName: 'main',
    subPath: 'docs',
  );
  SnapshotMediaCoordinate source({
    String account = 'account',
    String instance = 'instance',
    int? project = 10,
    String projectPath = 'team/project',
    String ref = 'sha',
    String path = 'docs/a.png',
    bool relative = true,
  }) => SnapshotMediaCoordinate(
    accountKey: account,
    instanceKey: instance,
    projectId: project,
    projectPath: projectPath,
    ref: ref,
    path: path,
    relative: relative,
  );
  SnapshotTreeEntry entry({
    String path = 'docs/a.png',
    SnapshotContentKind kind = SnapshotContentKind.image,
    SnapshotEntryState state = SnapshotEntryState.saved,
  }) => SnapshotTreeEntry(
    path: path,
    type: SnapshotEntryType.blob,
    mode: '100644',
    id: 'a' * 40,
    state: state,
    kind: kind,
    size: 1,
  );
  test('identity, project, ref, subpath and saved image must all match', () {
    expect(policy.permits(source(), entry()), isTrue);
    expect(
      policy.permits(source(relative: false, ref: 'main'), entry()),
      isTrue,
    );
    for (final s in <SnapshotMediaCoordinate>[
      source(account: 'other'),
      source(instance: 'other'),
      source(project: 11),
      source(ref: 'main'),
      source(path: 'other/a.png'),
      source(relative: false, projectPath: 'other/project'),
      source(relative: false, ref: 'other'),
    ]) {
      expect(policy.permits(s, entry(path: s.path)), isFalse);
    }
    expect(
      policy.permits(source(), entry(state: SnapshotEntryState.missing)),
      isFalse,
    );
    expect(
      policy.permits(source(), entry(kind: SnapshotContentKind.text)),
      isFalse,
    );
    expect(
      policy.permits(
        source(path: 'docs/a.svg'),
        entry(path: 'docs/a.svg', kind: SnapshotContentKind.text),
      ),
      isTrue,
    );
  });
}
