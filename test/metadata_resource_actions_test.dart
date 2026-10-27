import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/shared/resource_share.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show workspaceHost;

String _apiPath(RequestOptions request) {
  final parts = request.uri.pathSegments;
  return parts.skip(parts.indexOf('v4') + 1).join('/');
}

final class _MetadataFixture extends WorkspaceFixture {
  _MetadataFixture({required this.kind, required this.rows, this.host});

  final MetadataKind kind;
  final List<Map<String, dynamic>> rows;
  final String? host;

  late final _metadataApi = testApi(adapter, host: host ?? 'https://example.com/gitlab');
  @override
  GitLabApi get api => _metadataApi;

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (_apiPath(request) == 'projects/42/${kind.name}') {
      return jsonResponse(rows);
    }
    return super.respond(request);
  }
}

Widget _page(_MetadataFixture fixture, {double scale = 1}) => workspaceHost(
  MetadataPage(
    account: fixture.account,
    api: fixture.api,
    project: fixture.project,
    kind: fixture.kind,
  ),
  scale: scale,
);

Future<void> _openRow(WidgetTester tester, String title) async {
  await settleNetworkWidgets(tester);
  await tester.tap(find.text(title));
  await settleNetworkWidgets(tester);
}

final class _OwnerHarness extends StatefulWidget {
  const _OwnerHarness({super.key, required this.first, required this.second});

  final _MetadataFixture first;
  final _MetadataFixture second;

  @override
  State<_OwnerHarness> createState() => _OwnerHarnessState();
}

final class _OwnerHarnessState extends State<_OwnerHarness> {
  bool replaced = false;

  void replace() => setState(() => replaced = true);

  @override
  Widget build(BuildContext context) {
    final fixture = replaced ? widget.second : widget.first;
    return MetadataPage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
      kind: fixture.kind,
    );
  }
}

void main() {
  test('metadata phrases space a Latin title only', () {
    expect(metadataAddTitle(MetadataKind.milestones), '新增里程碑');
    expect(metadataEmpty(MetadataKind.releases), '尚無 Releases');
    expect(metadataDeleteQuestion(MetadataKind.tags), '刪除標籤版本？');
  });

  testWidgets('milestone detail shares project IID rather than database ID', (
    tester,
  ) async {
    final fixture = _MetadataFixture(
      kind: MetadataKind.milestones,
      rows: [
        {
          'id': 901,
          'iid': 7,
          'title': 'Sprint seven',
          'description': 'Plan',
          'state': 'active',
        },
      ],
    );
    addTearDown(fixture.api.close);
    await tester.pumpWidget(_page(fixture));
    await _openRow(tester, 'Sprint seven');

    final share = tester.widget<ResourceShareButton>(
      find.byType(ResourceShareButton),
    );
    expect(
      share.uri.toString(),
      'https://example.com/gitlab/studio/mobile-workspace/-/milestones/7',
    );
    expect(share.uri.path, isNot(contains('/milestones/901')));
  });

  testWidgets('release detail encodes the complete slash tag as one segment', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final fixture = _MetadataFixture(
      kind: MetadataKind.releases,
      rows: [
        {
          'tag_name': 'test/v0.1',
          'name': 'A release with a deliberately long title',
          'description': 'Notes',
          '_links': {'self': 'https://attacker.example/stolen'},
        },
      ],
    );
    addTearDown(fixture.api.close);
    await tester.pumpWidget(_page(fixture, scale: 2));
    await _openRow(tester, 'A release with a deliberately long title');

    final share = tester.widget<ResourceShareButton>(
      find.byType(ResourceShareButton),
    );
    expect(
      share.uri.toString(),
      'https://example.com/gitlab/studio/mobile-workspace/-/releases/test%2Fv0.1',
    );
    expect(share.uri.pathSegments.last, 'test/v0.1');
    expect(share.uri.host, isNot('attacker.example'));
    expect(
      tester.getRect(find.byTooltip('分享連結')).right,
      lessThanOrEqualTo(320),
    );
    expect(tester.takeException(), isNull);
  });

  for (final entry in [
    (
      MetadataKind.milestones,
      'Milestone without IID',
      <String, dynamic>{
        'id': 901,
        'title': 'Milestone without IID',
        'description': 'Plan',
      },
    ),
    (
      MetadataKind.releases,
      'Release without tag',
      <String, dynamic>{'name': 'Release without tag', 'description': 'Notes'},
    ),
  ]) {
    testWidgets(
      '${entry.$1.name} omits share when its web identifier is missing',
      (tester) async {
        final fixture = _MetadataFixture(kind: entry.$1, rows: [entry.$3]);
        addTearDown(fixture.api.close);
        await tester.pumpWidget(_page(fixture));
        await _openRow(tester, entry.$2);
        expect(find.byType(ResourceShareButton), findsNothing);
        expect(find.byTooltip('分享連結'), findsNothing);
      },
    );
  }

  testWidgets('closing the captured API dismisses its detail after rebuild', (
    tester,
  ) async {
    final fixture = _MetadataFixture(
      kind: MetadataKind.milestones,
      rows: [
        {
          'id': 901,
          'iid': 7,
          'title': 'Closing owner private title',
          'description': 'Closing owner private body',
        },
      ],
    );
    addTearDown(fixture.api.close);
    await tester.pumpWidget(_page(fixture));
    await _openRow(tester, 'Closing owner private title');
    final share = tester.widget<ResourceShareButton>(
      find.byType(ResourceShareButton),
    );
    expect(share.isCurrent?.call(), isTrue);
    fixture.api.close();
    await tester.pumpWidget(_page(fixture));
    await tester.pumpAndSettle();
    expect(share.isCurrent?.call(), isFalse);
    expect(find.text('Closing owner private title'), findsNothing);
    expect(find.text('Closing owner private body'), findsNothing);
    expect(find.byType(ResourceShareButton), findsNothing);
  });

  testWidgets('replacing the metadata owner dismisses its private detail', (
    tester,
  ) async {
    final first = _MetadataFixture(
      kind: MetadataKind.releases,
      rows: [
        {
          'tag_name': 'v1',
          'name': 'First private release title',
          'description': 'First private release body',
        },
      ],
    );
    final second = _MetadataFixture(
      kind: MetadataKind.releases,
      rows: [
        {'tag_name': 'v2', 'name': 'Second release'},
      ],
      host: 'https://next.example/gitlab',
    );
    addTearDown(first.api.close);
    addTearDown(second.api.close);
    final key = GlobalKey<_OwnerHarnessState>();
    await tester.pumpWidget(
      workspaceHost(_OwnerHarness(key: key, first: first, second: second)),
    );
    await _openRow(tester, 'First private release title');
    final share = tester.widget<ResourceShareButton>(
      find.byType(ResourceShareButton),
    );
    expect(share.isCurrent?.call(), isTrue);
    expect(find.text('First private release body'), findsOneWidget);
    key.currentState!.replace();
    await settleNetworkWidgets(tester);
    expect(share.isCurrent?.call(), isFalse);
    expect(find.text('First private release title'), findsNothing);
    expect(find.text('First private release body'), findsNothing);
    expect(find.text('Second release'), findsOneWidget);
    expect(find.byType(ResourceShareButton), findsNothing);
  });

  testWidgets('ending the session dismisses the open private detail', (
    tester,
  ) async {
    final fixture = _MetadataFixture(
      kind: MetadataKind.releases,
      rows: [
        {
          'tag_name': 'private-v1',
          'name': 'Session private release title',
          'description': 'Session private release body',
        },
      ],
    );
    final store = MemoryAccountStore();
    final session = SessionController(store, readCache: store.readCache)
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    addTearDown(session.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _page(fixture),
      ),
    );
    await _openRow(tester, 'Session private release title');
    expect(find.text('Session private release body'), findsOneWidget);

    await session.endSession();
    await tester.pumpAndSettle();

    expect(find.text('Session private release title'), findsNothing);
    expect(find.text('Session private release body'), findsNothing);
    expect(find.byType(ResourceShareButton), findsNothing);
    await pumpUntilComplete(tester, session.readCache.quiesced);
  });

  testWidgets('an initially mismatched session cannot show metadata', (
    tester,
  ) async {
    final fixture = _MetadataFixture(
      kind: MetadataKind.releases,
      rows: [
        {
          'tag_name': 'private-v1',
          'name': 'Denied private release title',
          'description': 'Denied private release body',
        },
      ],
    );
    final active = _MetadataFixture(
      kind: MetadataKind.releases,
      rows: const [],
      host: 'https://active.example/gitlab',
    );
    final session = SessionController(MemoryAccountStore())
      ..active = active.account
      ..api = active.api
      ..initializing = false;
    addTearDown(fixture.api.close);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _page(fixture),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Denied private release title'), findsNothing);
    expect(find.text('Denied private release body'), findsNothing);
    expect(find.byTooltip(metadataAddTitle(MetadataKind.releases)), findsNothing);
    expect(fixture.adapter.requests, isEmpty);
  });
}
