import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';

import 'support/fake_adapter.dart';

void main() {
  const source = '''
![diagram](https://media.example/a.png)

<img src="https://media.example/b.png" alt="html image">

<video src="https://media.example/c.mp4"></video>

![upload](/uploads/0123456789abcdef0123456789abcdef/d.png)

![](https://media.example/e.svg)

[the docs](https://docs.example/guide)
''';

  Future<(FakeAdapter, FakeAdapter)> pump(WidgetTester tester) async {
    final external = FakeAdapter((_) => jsonResponse({}));
    final client = Dio()..httpClientAdapter = external;
    addTearDown(client.close);
    final gitlab = FakeAdapter((_) => jsonResponse({}));
    final account = Account(
      instance: GitLabInstance.parse('https://gitlab.example.test'),
      user: const GitLabUser(id: 7, username: 'river', name: 'River'),
      token: 'synthetic-token',
    );
    final api = testApi(gitlab, host: 'https://gitlab.example.test');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownView(
              source,
              api: api,
              projectId: 3,
              base: Uri.parse('https://gitlab.example.test/group/project'),
              externalMediaClient: client,
              account: account,
              offline: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (external, gitlab);
  }

  testWidgets('an offline view fetches no image, SVG, media or upload', (
    tester,
  ) async {
    final (external, gitlab) = await pump(tester);

    expect(tester.takeException(), isNull);
    expect(external.requests, isEmpty);
    expect(gitlab.requests, isEmpty);
    expect(find.byType(MarkdownMediaImage), findsNothing);
    expect(find.byType(MarkdownMediaCard), findsNothing);
    // Named by their alt text, or by the generic notice without one.
    expect(find.text('diagram'), findsOneWidget);
    expect(find.text('upload'), findsOneWidget);
    expect(find.text(l10n.markdownOfflineMedia), findsWidgets);
  });

  testWidgets('an offline link opens only after its address is confirmed', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.text('the docs', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text(l10n.markdownOpenLinkTitle), findsOneWidget);
    expect(find.text('https://docs.example/guide'), findsOneWidget);

    await tester.tap(find.text(l10n.cancelAction));
    await tester.pumpAndSettle();
    expect(find.text(l10n.markdownOpenLinkTitle), findsNothing);
  });

  testWidgets('tapping a media placeholder asks before opening it too', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.text('diagram'));
    await tester.pumpAndSettle();
    expect(find.text('https://media.example/a.png'), findsOneWidget);
  });
}
