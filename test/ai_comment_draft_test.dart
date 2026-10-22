import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/comment_editor.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import 'support/workspace_fixture.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

String _key(WorkspaceFixture fixture, String resource) =>
    'draft.v2.${base64Url.encode(utf8.encode(fixture.account.key))}.'
    '${base64Url.encode(utf8.encode(resource))}';

void main() {
  setUp(() {
    useLanguage(languageForTag('en')!);
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final resource in ['issues', 'merge_requests']) {
    testWidgets('$resource appends after restore and leaves without a write', (
      tester,
    ) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final key = _key(fixture, 'projects/42/$resource/12/root/new');
      const previous = '  Original Markdown  \n';
      const answer = ' **AI answer**\n';
      FlutterSecureStorage.setMockInitialValues({
        key: jsonEncode({'body': previous}),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => openCommentEditor(
                context,
                account: fixture.account,
                api: fixture.api,
                project: fixture.project,
                resource: resource,
                iid: 12,
                isCurrent: () => true,
                appendBody: answer,
              ),
              child: const Text('Open draft'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open draft'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextFormField>(find.byType(TextFormField));
      expect(field.controller!.text, '$previous\n\n$answer');
      expect(fixture.adapter.requests, isEmpty);
      await tester.tap(find.byTooltip(l10n.keepDraftAndGoBack));
      await tester.pumpAndSettle();
      expect(fixture.adapter.requests, isEmpty);
      final stored = jsonDecode(
        (await const FlutterSecureStorage().read(key: key))!,
      );
      expect(stored['body'], '$previous\n\n$answer');
    });
  }

  testWidgets('a new draft is scoped and persists without tapping Save', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ResourceEditor(
          account: fixture.account,
          title: 'Comment',
          resource: 'new-ai-comment',
          fields: const [EditField('body', 'Body', markdown: true)],
          appendValues: const {'body': 'Answer'},
          save: (_) async => fail('no automatic Save'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      'Answer',
    );
    expect(
      await const FlutterSecureStorage().read(
        key: _key(fixture, 'new-ai-comment'),
      ),
      '{"body":"Answer"}',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final raw in [
    'not-json',
    '[]',
    '{"body":5}',
    '{"body":"Existing","__writeUncertain":42}',
  ]) {
    testWidgets('unrecognized stored draft is preserved: $raw', (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final key = _key(fixture, 'unrecognized');
      FlutterSecureStorage.setMockInitialValues({key: raw});
      await tester.pumpWidget(
        MaterialApp(
          home: ResourceEditor(
            account: fixture.account,
            title: 'Comment',
            resource: 'unrecognized',
            blockRetryOnWriteUncertain: true,
            fields: const [EditField('body', 'Body')],
            appendValues: const {'body': 'Answer'},
            save: (_) async => fail('Cannot replace an unrecognized draft'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('editorSave')))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextFormField), 'Replacement');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(await const FlutterSecureStorage().read(key: key), raw);
    });
  }

  for (final resource in ['issues', 'merge_requests']) {
    testWidgets('only explicit Save posts the reviewed $resource comment', (
      tester,
    ) async {
      final fixture = WorkspaceFixture();
      fixture.issues[12] = fixture.issue(12, 'Synthetic issue');
      addTearDown(fixture.api.close);
      late Future<bool> editorResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => editorResult = openCommentEditor(
                context,
                account: fixture.account,
                api: fixture.api,
                project: fixture.project,
                resource: resource,
                iid: 12,
                isCurrent: () => true,
                appendBody: 'Answer',
              ),
              child: const Text('Open draft'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open draft'));
      await tester.pumpAndSettle();
      expect(fixture.adapter.requests, isEmpty);
      await tester.enterText(find.byType(TextFormField), 'Reviewed answer');
      await tester.tap(find.byKey(const Key('editorSave')));
      await pumpUntil(
        tester,
        () => find.byType(ResourceEditor).evaluate().isEmpty,
        description: 'successful comment save closes the editor',
      );
      expect(find.byType(ResourceEditor), findsNothing);
      expect(await editorResult, isTrue);
      final writes = fixture.adapter.requests
          .where((r) => r.method == 'POST')
          .toList();
      expect(writes, hasLength(1));
      expect(
        writes.single.uri.path,
        '/gitlab/api/v4/projects/42/$resource/12/notes',
      );
      expect(writes.single.data, {'body': 'Reviewed answer'});
      if (resource == 'merge_requests') {
        expect(
          fixture.mergeRequestDiscussions.any(
            (discussion) =>
                discussion['individual_note'] == true &&
                (discussion['notes'] as List<dynamic>).any(
                  (note) =>
                      note is Map<String, dynamic> &&
                      note['body'] == 'Reviewed answer',
                ),
          ),
          isTrue,
        );
      }
    });
  }

  for (final outcome in ['success', 'cancellation', 'server error']) {
    testWidgets(
      'in-flight comment $outcome ${outcome == 'success' ? 'consumes the old draft' : 'stays fenced'}',
      (tester) async {
        final fixture = _DelayedCommentFixture();
        addTearDown(fixture.api.close);
        var current = true;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => openCommentEditor(
                  context,
                  account: fixture.account,
                  api: fixture.api,
                  project: fixture.project,
                  resource: 'issues',
                  iid: 12,
                  appendBody: 'Answer',
                  isCurrent: () => current,
                ),
                child: const Text('Open draft'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open draft'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('editorSave')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          fixture.adapter.requests.where((r) => r.method == 'POST'),
          hasLength(1),
        );
        final key = _key(fixture, 'projects/42/issues/12/root/new');
        expect(
          jsonDecode(
            (await const FlutterSecureStorage().read(key: key))!,
          )['__writeUncertain'],
          'true',
        );
        current = false;
        if (outcome == 'cancellation') fixture.api.close();
        fixture.response.complete(
          outcome == 'server error'
              ? jsonResponse({'message': 'lost acknowledgement'}, status: 500)
              : jsonResponse({'id': 99, 'body': 'Answer'}),
        );
        await settleNetworkWidgets(tester);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        final stored = await const FlutterSecureStorage().read(key: key);
        if (outcome == 'success') {
          expect(stored, isNull);
        } else {
          expect(jsonDecode(stored!)['body'], 'Answer');
          expect(jsonDecode(stored)['__writeUncertain'], 'true');
          await tester.pumpWidget(
            MaterialApp(
              home: ResourceEditor(
                account: fixture.account,
                title: 'Comment',
                resource: 'projects/42/issues/12/root/new',
                blockRetryOnWriteUncertain: true,
                fields: const [EditField('body', 'Body')],
                save: (_) async =>
                    fail('An uncertain write cannot be replayed'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextFormField>(find.byType(TextFormField))
                .controller!
                .text,
            'Answer',
          );
          expect(
            tester
                .widget<FilledButton>(find.byKey(const Key('editorSave')))
                .onPressed,
            isNull,
          );
        }
        expect(
          fixture.adapter.requests.where((r) => r.method == 'POST'),
          hasLength(1),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'an invalidated owner cannot persist or submit an inserted draft',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      var current = true;
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ResourceEditor(
            account: fixture.account,
            title: 'Comment',
            resource: 'owner-invalidated',
            fields: const [EditField('body', 'Body')],
            appendValues: const {'body': 'Answer'},
            isCurrent: () => current,
            save: (_) async {
              saves++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      current = false;
      await tester.tap(find.byKey(const Key('editorSave')));
      await tester.pump();
      expect(saves, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(fixture.adapter.requests, isEmpty);
    },
  );

  testWidgets('a failed draft read never replaces a stored draft', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final storage = _ReadFailingStorage({});
    FlutterSecureStoragePlatform.instance = storage;
    await tester.pumpWidget(
      MaterialApp(
        home: ResourceEditor(
          account: fixture.account,
          title: 'Comment',
          resource: 'locked-storage',
          fields: const [EditField('body', 'Body')],
          appendValues: const {'body': 'Answer'},
          save: (_) async =>
              fail('Cannot submit without restoring the existing draft'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      '',
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('editorSave')))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(storage.reads, 1);
    expect(storage.writes, 0);
  });
}

class _DelayedCommentFixture extends WorkspaceFixture {
  final response = Completer<ResponseBody>();

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/issues/12/notes')) {
      return response.future;
    }
    return super.respond(request);
  }
}

class _ReadFailingStorage extends TestFlutterSecureStoragePlatform {
  _ReadFailingStorage(super.data);
  var reads = 0;
  var writes = 0;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    reads++;
    throw StateError('storage locked');
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    writes++;
    await super.write(key: key, value: value, options: options);
  }
}
