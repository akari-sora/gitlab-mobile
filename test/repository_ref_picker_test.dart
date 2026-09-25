import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/repository_ref.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

void main() {
  final instance = GitLabInstance.parse('https://example.com/gitlab');
  final account = Account(
    instance: instance,
    user: const GitLabUser(id: 7, username: 'coder', name: 'Coder'),
    token: 'synthetic-token',
  );
  final project = Project.fromJson({
    'id': 42,
    'name': 'Project',
    'path': 'project',
    'path_with_namespace': 'group/project',
    'description': '',
    'visibility': 'private',
    'default_branch': 'main',
    'archived': false,
    'last_activity_at': '2026-09-20T10:00:00Z',
  });

  const mainSha = '1111111111111111111111111111111111111111';
  const featSha = '2222222222222222222222222222222222222222';
  const tagSha = '3333333333333333333333333333333333333333';

  testWidgets('RepositoryRefPickerPage switches between branches and tags, shows protected status and selects ref', (tester) async {
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/repository/branches')) {
        return jsonResponse([
          {
            'name': 'main',
            'protected': true,
            'default': true,
            'commit': {'id': mainSha},
          },
          {
            'name': 'feature/code-reader',
            'protected': false,
            'default': false,
            'commit': {'id': featSha},
          },
        ]);
      }
      if (path.endsWith('/repository/tags')) {
        return jsonResponse([
          {
            'name': 'v1.0.0',
            'protected': true,
            'commit': {'id': tagSha},
          },
        ]);
      }
      return jsonResponse([]);
    });

    final api = testApi(adapter);
    addTearDown(api.close);

    RepositoryRef? chosenRef;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              chosenRef = await Navigator.push<RepositoryRef>(
                context,
                MaterialPageRoute(
                  builder: (_) => RepositoryRefPickerPage(
                    account: account,
                    api: api,
                    project: project,
                    selected: const RepositoryRef(
                      kind: RepositoryRefKind.branch,
                      name: 'main',
                      sha: mainSha,
                      protected: true,
                      isDefault: true,
                    ),
                  ),
                ),
              );
            },
            child: const Text('Open Picker'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Picker'));
    await settleNetworkWidgets(tester);

    // Initial mode is branches
    expect(find.text('選擇版本'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(find.text('feature/code-reader'), findsOneWidget);
    expect(find.text('預設'), findsOneWidget);
    expect(find.text('受保護'), findsOneWidget);

    // Switch to tags tab
    await tester.tap(find.text('標籤'));
    await settleNetworkWidgets(tester);

    expect(find.text('v1.0.0'), findsOneWidget);
    expect(find.text('feature/code-reader'), findsNothing);

    // Select tag v1.0.0
    await tester.tap(find.text('v1.0.0'));
    await settleNetworkWidgets(tester);

    expect(chosenRef, isNotNull);
    expect(chosenRef!.kind, RepositoryRefKind.tag);
    expect(chosenRef!.name, 'v1.0.0');
    expect(chosenRef!.sha, tagSha);
    expect(chosenRef!.writable, isFalse);
  });
}
