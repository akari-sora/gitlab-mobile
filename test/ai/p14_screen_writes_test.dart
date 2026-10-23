import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';

import '../crud_controls_test.dart' show CrudFixture;
import '../support/fake_adapter.dart';
import '../workspace_widget_test.dart' show workspaceHost;

// Wait for observable state with a wall-clock deadline, including real Dio work.
Future<void> _until(WidgetTester tester, bool Function() ready) async {
  final clock = Stopwatch()..start();
  while (!ready() ||
      find
          .byWidgetPredicate(
            (widget) =>
                widget is RowsSkeleton ||
                widget is CircularProgressIndicator && widget.value == null ||
                widget is LinearProgressIndicator && widget.value == null,
          )
          .evaluate()
          .isNotEmpty) {
    if (clock.elapsed > const Duration(seconds: 20)) {
      fail('Screen state did not become ready within 20 seconds');
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pumpAndSettle();
}

Future<void> _host(
  WidgetTester tester,
  CrudFixture fixture,
  Widget page,
) async {
  addTearDown(fixture.api.close);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(workspaceHost(page));
}

Future<ResourceEditor> _newMetadataEditor(
  WidgetTester tester,
  CrudFixture fixture,
  MetadataKind kind,
) async {
  await _host(
    tester,
    fixture,
    MetadataPage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
      kind: kind,
    ),
  );
  await _until(
    tester,
    () => find.byType(RefreshIndicator).evaluate().isNotEmpty,
  );
  await tester.tap(find.byTooltip(metadataAddTitle(kind)));
  await _until(tester, () => find.byType(ResourceEditor).evaluate().isNotEmpty);
  return tester.widget<ResourceEditor>(find.byType(ResourceEditor));
}

Future<void> _menu(WidgetTester tester, String tooltip, String choice) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
  await tester.tap(find.text(choice));
  await tester.pumpAndSettle();
}

List<RequestOptions> _writes(FakeAdapter adapter) => adapter.requests
    .where((request) => !const ['GET', 'HEAD'].contains(request.method))
    .toList();

Future<void> _sameLegacyRequest(
  WidgetTester tester,
  RequestOptions actual,
  String method,
  List<String> path,
  Json? body,
) async {
  final adapter = FakeAdapter((_) => jsonResponse({}));
  final api = testApi(adapter);
  try {
    if (method == 'DELETE') {
      await tester.runAsync(
        () => api.removeRecord(path).timeout(const Duration(seconds: 20)),
      );
    } else {
      await tester.runAsync(
        () => api
            .writeRecord(method, path, body!)
            .timeout(const Duration(seconds: 20)),
      );
    }
    final legacy = adapter.requests.single;
    expect(actual.method, legacy.method);
    expect(actual.uri.toString(), legacy.uri.toString());
    expect(jsonEncode(actual.data), jsonEncode(legacy.data));
    expect(actual.followRedirects, isFalse);
  } finally {
    api.close();
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  String metadataSource() {
    final source = File(
      'lib/features/workspace/project_more_page.dart',
    ).readAsStringSync();
    return source.substring(
      source.indexOf('class _MetadataPageState'),
      source.indexOf('class _OwnerFence'),
    );
  }

  for (final method in [
    'createBranch',
    'createTag',
    'createRelease',
    'updateRelease',
    'deleteBranch',
    'deleteTag',
    'deleteRelease',
    'deleteLabel',
    'deleteMilestone',
  ]) {
    test('MetadataPage routes $method through its named wrapper', () {
      expect(metadataSource().contains('widget.api.$method('), isTrue);
    });
  }

  test('MetadataPage has no generic writes', () {
    expect(metadataSource().contains('.writeRecord('), isFalse);
    expect(metadataSource().contains('.removeRecord('), isFalse);
  });

  String repositorySource() =>
      File('lib/features/workspace/repository_page.dart').readAsStringSync();

  for (final method in ['createRepositoryFile', 'updateRepositoryFile']) {
    test('repository screen routes $method through its named wrapper', () {
      expect(repositorySource().contains('widget.api.$method('), isTrue);
    });
  }

  test('repository screens have no legacy saveFile call', () {
    expect(repositorySource().contains('.saveFile('), isFalse);
  });

  for (final kind in [
    MetadataKind.branches,
    MetadataKind.tags,
    MetadataKind.releases,
  ]) {
    testWidgets('${kind.name} create preserves the legacy HTTP request', (
      tester,
    ) async {
      final fixture = CrudFixture();
      final editor = await _newMetadataEditor(tester, fixture, kind);
      final values = switch (kind) {
        MetadataKind.branches => {'branch': 'topic/a % b', 'ref': 'main'},
        MetadataKind.tags => {
          'tag_name': 'release/a % b',
          'ref': 'main',
          'message': '  annotated\nmessage  ',
        },
        _ => {
          'tag_name': 'release/a % b',
          'name': 'Release',
          'description': '  notes\nunchanged  ',
        },
      };
      await tester.runAsync(() => editor.save(values));
      await _sameLegacyRequest(
        tester,
        _writes(fixture.adapter).single,
        'POST',
        [
          'projects',
          '42',
          if (kind != MetadataKind.releases) 'repository',
          kind.name,
        ],
        values,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty tag message follows the existing named wrapper', (
    tester,
  ) async {
    final fixture = CrudFixture();
    final editor = await _newMetadataEditor(tester, fixture, MetadataKind.tags);
    await tester.runAsync(
      () => editor.save({
        'tag_name': 'empty-message',
        'ref': 'main',
        'message': '',
      }),
    );
    final write = _writes(fixture.adapter).single;
    expect(write.method, 'POST');
    expect(write.data, {'tag_name': 'empty-message', 'ref': 'main'});
  });

  testWidgets('release edit preserves the tag segment and exact payload', (
    tester,
  ) async {
    final fixture = CrudFixture();
    fixture.collections['releases']!['release/a % b'] = {
      'tag_name': 'release/a % b',
      'name': 'Original',
      'description': 'Before',
    };
    await _host(
      tester,
      fixture,
      MetadataPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        kind: MetadataKind.releases,
      ),
    );
    await _until(tester, () => find.text('Original').evaluate().isNotEmpty);
    await _menu(tester, l10n.itemActions, l10n.editAction);
    final editor = tester.widget<ResourceEditor>(find.byType(ResourceEditor));
    final values = {'name': 'Changed', 'description': '  notes\nkept  '};
    await tester.runAsync(() => editor.save(values));
    await _sameLegacyRequest(tester, _writes(fixture.adapter).single, 'PUT', [
      'projects',
      '42',
      'releases',
      'release/a % b',
    ], values);
  });

  for (final kind in [
    MetadataKind.branches,
    MetadataKind.tags,
    MetadataKind.releases,
    MetadataKind.labels,
    MetadataKind.milestones,
  ]) {
    testWidgets('${kind.name} delete keeps its path and typed confirmation', (
      tester,
    ) async {
      final fixture = CrudFixture();
      final collection =
          kind == MetadataKind.branches || kind == MetadataKind.tags
          ? 'repository/${kind.name}'
          : kind.name;
      final id = kind == MetadataKind.labels || kind == MetadataKind.milestones
          ? '901'
          : 'release/a % b';
      const name = 'Original name';
      fixture.collections[collection]!
        ..clear()
        ..[id] = {
          'id': 901,
          'name': name,
          'title': name,
          'tag_name': id,
          'default': false,
          'protected': false,
        };
      // Branch and tag names are both their display and transport identifier.
      if (kind == MetadataKind.branches || kind == MetadataKind.tags) {
        fixture.collections[collection]![id]!['name'] = id;
      }
      final requiredName =
          kind == MetadataKind.branches || kind == MetadataKind.tags
          ? id
          : name;
      await _host(
        tester,
        fixture,
        MetadataPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          kind: kind,
        ),
      );
      await _until(tester, () => find.text(requiredName).evaluate().isNotEmpty);
      await _menu(tester, l10n.itemActions, l10n.delete);
      final confirm = find.widgetWithText(FilledButton, l10n.confirmAction);
      final input = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, 'wrong name');
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(_writes(fixture.adapter), isEmpty);
      await tester.enterText(input, requiredName);
      await tester.pump();
      await tester.tap(confirm);
      await _until(tester, () => fixture.collections[collection]!.isEmpty);
      await _sameLegacyRequest(
        tester,
        _writes(fixture.adapter).single,
        'DELETE',
        ['projects', '42', ...collection.split('/'), id],
        null,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('new repository file preserves POST, encoded path and body', (
    tester,
  ) async {
    final fixture = CrudFixture();
    await _host(
      tester,
      fixture,
      Scaffold(
        body: RepositoryTab(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
        ),
      ),
    );
    await _until(
      tester,
      () => find.byTooltip(l10n.addFile).evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip(l10n.addFile));
    await _until(
      tester,
      () => find.byType(ResourceEditor).evaluate().isNotEmpty,
    );
    final editor = tester.widget<ResourceEditor>(find.byType(ResourceEditor));
    await tester.runAsync(
      () => editor.save({
        'path': ' nested/a % b.txt ',
        'content': '  first\nsecond  ',
        'message': ' create file ',
      }),
    );
    await _sameLegacyRequest(
      tester,
      _writes(fixture.adapter).single,
      'POST',
      ['projects', '42', 'repository', 'files', 'nested/a % b.txt'],
      {
        'branch': 'main',
        'content': '  first\nsecond  ',
        'commit_message': 'create file',
      },
    );
  });

  for (final stale in [false, true]) {
    testWidgets(
      'file edit ${stale ? 'rejects a changed' : 'sends the loaded'} revision',
      (tester) async {
        final fixture = CrudFixture();
        final originalCommit = fixture.head;
        const path = 'nested/a % b.txt';
        fixture.files[path] = 'Original';
        await _host(
          tester,
          fixture,
          RepositoryFilePage(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
            branch: 'main',
            sha: originalCommit,
            filePath: path,
          ),
        );
        await _until(tester, () => find.text('Original').evaluate().isNotEmpty);
        await _menu(tester, l10n.fileActions, l10n.editFile);
        if (stale) fixture.revision++;
        final before = fixture.adapter.requests.length;
        final editor = tester.widget<ResourceEditor>(
          find.byType(ResourceEditor),
        );
        final values = {
          'content': '  replacement\nkept  ',
          'message': ' edit file ',
        };
        if (stale) {
          await tester.runAsync(
            () => expectLater(
              editor.save(values),
              throwsA(
                isA<ApiFailure>().having(
                  (failure) => failure.kind,
                  'kind',
                  FailureKind.conflict,
                ),
              ),
            ),
          );
          expect(_writes(fixture.adapter), isEmpty);
        } else {
          await tester.runAsync(() => editor.save(values));
          await _sameLegacyRequest(
            tester,
            _writes(fixture.adapter).single,
            'PUT',
            ['projects', '42', 'repository', 'files', path],
            {
              'branch': 'main',
              'content': '  replacement\nkept  ',
              'commit_message': 'edit file',
              'last_commit_id': originalCommit,
            },
          );
        }
        final preflight = fixture.adapter.requests[before];
        expect(preflight.method, 'HEAD');
        expect(preflight.uri.queryParameters, {'ref': 'main'});
      },
    );
  }

  testWidgets('missing loaded revision shows conflict with zero HTTP on Save', (
    tester,
  ) async {
    final fixture = CrudFixture();
    var denied = false;
    final adapter = FakeAdapter(
      (request) =>
          denied ? jsonResponse({}, status: 403) : fixture.respond(request),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await _host(
      tester,
      fixture,
      RepositoryFilePage(
        account: fixture.account,
        api: api,
        project: fixture.project,
        branch: 'main',
        sha: fixture.head,
        filePath: 'README.md',
      ),
    );
    await _until(
      tester,
      () =>
          find.byTooltip(l10n.fileActions).evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    final actions = tester.widget<PopupMenuButton<String>>(
      find.byWidgetPredicate(
        (widget) =>
            widget is PopupMenuButton<String> &&
            widget.tooltip == l10n.fileActions,
      ),
    );
    await _menu(tester, l10n.fileActions, l10n.editFile);
    await tester.enterText(
      find.byKey(const ValueKey('editor-content')),
      'Changed',
    );
    // A denied refresh clears the loaded source/revision under the open editor.
    denied = true;
    actions.onSelected!('refresh');
    await _until(
      tester,
      () => find
          .textContaining(
            const ApiFailure(FailureKind.forbidden).title,
            skipOffstage: false,
          )
          .evaluate()
          .isNotEmpty,
    );
    denied = false;
    final before = adapter.requests.length;
    await tester.tap(find.byKey(const Key('editorSave')));
    await _until(
      tester,
      () => find
          .textContaining(const ApiFailure(FailureKind.conflict).title)
          .evaluate()
          .isNotEmpty,
    );
    expect(adapter.requests.length - before, 0);
    expect(find.byType(ResourceEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
