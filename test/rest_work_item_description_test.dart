import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'support/rest_work_item_description_fixture.dart';
import 'support/widget_settle.dart';

const _expandLabel = '展開完整說明';
const _collapseLabel = '收合說明';
const _previewKey = ValueKey('work-item-description-preview');
const _endMarker = 'END_OF_DESCRIPTION_MARKER';

const _shortMarkdown =
    'Short **bold** note with [docs](https://example.com/gitlab/team/example/-/wikis/home) and `inline_code`.\n\n'
    '```\nblock_code()\n```';

final _longLatin =
    '${List.generate(60, (i) => 'Paragraph $i explains **rollout** step $i with `code_$i` and [link $i](https://example.com/$i).').join('\n\n')}\n\n$_endMarker';

const _cjkUnit = '測試說明👨‍👩‍👧‍👦🇹🇼 ';
final _longCjk = '${List.filled(300, _cjkUnit).join()}$_endMarker';

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  theme: appTheme(Brightness.light),
  builder: textScale == 1
      ? null
      : (context, inner) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: inner!,
        ),
  home: child,
);

WorkItemPage _page(
  RestWorkItemDescriptionFixture fixture, {
  String resource = 'issues',
  int iid = 1,
}) => WorkItemPage(
  account: fixture.account,
  api: fixture.api,
  project: fixture.project,
  resource: resource,
  iid: iid,
);

void _surface(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

RestWorkItemDescriptionFixture _fixture() {
  final fixture = RestWorkItemDescriptionFixture();
  addTearDown(fixture.api.close);
  return fixture;
}

Finder get _markdown => find.byType(MarkdownView);

Finder _button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.bySubtype<ButtonStyleButton>(),
);
Finder get _expand => _button(_expandLabel);
Finder get _collapse => _button(_collapseLabel);

String _previewText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(_previewKey)).data!;

Future<void> _tap(WidgetTester tester, Finder button) async {
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _refresh(WidgetTester tester) async {
  await tester.tap(find.byTooltip('重新整理'));
  await settleNetworkWidgets(tester);
}

void _expectInside(Rect rect, Rect viewport) {
  expect(rect.top, greaterThanOrEqualTo(viewport.top));
  expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
  expect(rect.left, greaterThanOrEqualTo(viewport.left));
  expect(rect.right, lessThanOrEqualTo(viewport.right));
}

Finder get _summaryScrollable => find
    .descendant(
      of: find.byType(TabBarView),
      matching: find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      ),
    )
    .first;

/// Scrolls to the end of the work item summary list using bounded drag gestures
/// until the target row is rendered and hit-testable.
Future<void> _scrollToEnd(
  WidgetTester tester, [
  Finder? scrollable,
  Finder? target,
]) async {
  final lastRow = target ?? find.text('Linked issue 15');
  final list = scrollable ?? _summaryScrollable;
  final position = tester.state<ScrollableState>(list).position;
  for (var i = 0; i < 60 && lastRow.hitTestable().evaluate().isEmpty; i++) {
    final before = position.pixels;
    await tester.drag(list, const Offset(0, -300));
    await settleNetworkWidgets(tester);
    if (lastRow.hitTestable().evaluate().isEmpty) {
      expect(
        position.pixels,
        isNot(equals(before)),
        reason: 'Summary scrollable made no progress toward bottom target',
      );
    }
  }
  expect(lastRow.hitTestable(), findsOneWidget);
}

/// Scrolls back to the top of the work item summary list using bounded drag gestures
/// until the top target is rendered and hit-testable.
Future<void> _scrollToTop(
  WidgetTester tester, [
  Finder? scrollable,
  Finder? target,
]) async {
  final topTarget = target ?? _expand;
  final list = scrollable ?? _summaryScrollable;
  final position = tester.state<ScrollableState>(list).position;
  for (var i = 0; i < 60 && topTarget.hitTestable().evaluate().isEmpty; i++) {
    final before = position.pixels;
    await tester.drag(list, const Offset(0, 300));
    await settleNetworkWidgets(tester);
    if (topTarget.hitTestable().evaluate().isEmpty) {
      expect(
        position.pixels,
        isNot(equals(before)),
        reason: 'Summary scrollable made no progress toward top target',
      );
    }
  }
  expect(topTarget.hitTestable(), findsOneWidget);
}

void _expectShortRichMarkdown(WidgetTester tester) {
  expect(_markdown, findsOneWidget);
  expect(tester.widget<MarkdownView>(_markdown).text, _shortMarkdown);
  expect(_expand, findsNothing);
  expect(find.byKey(_previewKey), findsNothing);
  expect(
    find.descendant(of: _markdown, matching: find.byType(SelectionArea)),
    findsOneWidget,
  );
  expect(find.textContaining('block_code()', findRichText: true), findsWidgets);
  expect(find.textContaining('inline_code', findRichText: true), findsWidgets);
  final links = <TextSpan>[];
  for (final rich in tester.widgetList<RichText>(
    find.descendant(of: _markdown, matching: find.byType(RichText)),
  )) {
    rich.text.visitChildren((span) {
      if (span is TextSpan &&
          span.recognizer != null &&
          (span.text ?? '').contains('docs')) {
        links.add(span);
      }
      return true;
    });
  }
  expect(
    links,
    isNotEmpty,
    reason: 'the short description keeps its guarded tappable link',
  );
}

/// Expands and collapses from where the reader is, without any scrolling.
Future<void> _expectCollapseReachableAfterExpand(WidgetTester tester) async {
  final summary = find
      .ancestor(of: _expand, matching: find.byType(Scrollable))
      .first;
  final viewport = tester.getRect(summary);
  final position = tester.state<ScrollableState>(summary).position;
  final pixels = position.pixels;
  expect(_markdown, findsNothing);
  expect(
    _expand.hitTestable(),
    findsOneWidget,
    reason: 'expand is on screen at the description start',
  );
  final anchor = tester.getRect(_expand);
  _expectInside(anchor, viewport);

  await _tap(tester, _expand);

  expect(_markdown, findsOneWidget);
  expect(position.pixels, pixels, reason: 'expanding does not scroll');
  expect(
    _collapse.hitTestable(),
    findsOneWidget,
    reason: 'collapse is reachable right where expand was',
  );
  final collapse = tester.getRect(_collapse);
  _expectInside(collapse, viewport);
  expect(collapse.height, greaterThanOrEqualTo(48));
  expect(collapse.width, greaterThanOrEqualTo(48));
  expect(collapse.top, closeTo(anchor.top, 1));
  expect(collapse.top, lessThanOrEqualTo(viewport.top + viewport.height / 2));

  await _tap(tester, _collapse);

  expect(position.pixels, pixels);
  expect(_markdown, findsNothing);
  expect(find.byKey(_previewKey).hitTestable(), findsOneWidget);
  expect(_expand.hitTestable(), findsOneWidget);
}

void main() {
  testWidgets(
    'short issue description keeps rich Markdown links, code and selection',
    (tester) async {
      _surface(tester, const Size(390, 844));
      final fixture = _fixture()..putIssue(1, _shortMarkdown);

      await tester.pumpWidget(_host(_page(fixture)));
      await settleNetworkWidgets(tester);

      _expectShortRichMarkdown(tester);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'short merge request description keeps rich Markdown beside the review card',
    (tester) async {
      _surface(tester, const Size(390, 844));
      final fixture = _fixture()..putMergeRequest(5, _shortMarkdown);

      await tester.pumpWidget(
        _host(_page(fixture, resource: 'merge_requests', iid: 5)),
      );
      await settleNetworkWidgets(tester);

      _expectShortRichMarkdown(tester);
      expect(find.text('可以合併'), findsOneWidget);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'description at the threshold stays rich; one rune more is previewed',
    (tester) async {
      _surface(tester, const Size(390, 844));
      final atThreshold = List.filled(800, 'a').join();
      final fixture = _fixture()
        ..putIssue(1, atThreshold)
        ..putIssue(2, '${atThreshold}b');

      await tester.pumpWidget(_host(_page(fixture)));
      await settleNetworkWidgets(tester);
      expect(_markdown, findsOneWidget);
      expect(_expand, findsNothing);

      await tester.pumpWidget(_host(_page(fixture, iid: 2)));
      await settleNetworkWidgets(tester);
      expect(_markdown, findsNothing);
      expect(_expand, findsOneWidget);
    },
  );

  testWidgets(
    'a short but tall checklist is previewed instead of fully built',
    (tester) async {
      _surface(tester, const Size(390, 844));
      final checklist = List.generate(41, (i) => '- [ ] t$i').join('\n');
      expect(checklist.runes.length, lessThan(800));
      final fixture = _fixture()..putIssue(1, checklist);

      await tester.pumpWidget(_host(_page(fixture)));
      await settleNetworkWidgets(tester);

      expect(_markdown, findsNothing);
      expect(_previewText(tester), startsWith('- [ ] t0 - [ ] t1'));
      expect(_expand, findsOneWidget);
    },
  );

  testWidgets(
    'long issue description defers Markdown until expanded and toggles without requests',
    (tester) async {
      _surface(tester, const Size(390, 844));
      final fixture = _fixture()..putIssue(1, _longLatin);

      await tester.pumpWidget(_host(_page(fixture)));
      await settleNetworkWidgets(tester);

      expect(
        _markdown,
        findsNothing,
        reason: 'no Markdown tree is parsed or built while collapsed',
      );
      final preview = tester.widget<Text>(find.byKey(_previewKey));
      expect(preview.maxLines, isNotNull);
      expect(preview.data!.runes.length, lessThanOrEqualTo(400));
      expect(
        preview.data,
        startsWith('Paragraph 0 explains **rollout** step 0'),
      );
      expect(preview.data, endsWith('…'));
      expect(find.textContaining(_endMarker, findRichText: true), findsNothing);
      expect(
        find.textContaining('${_longLatin.runes.length} 字元'),
        findsOneWidget,
      );
      expect(find.text(_expandLabel), findsOneWidget);

      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel(_expandLabel), findsOneWidget);
      handle.dispose();

      final requests = fixture.adapter.requests.length;
      await _tap(tester, _expand);

      expect(_markdown, findsOneWidget);
      final full = tester.widget<MarkdownView>(_markdown);
      expect(
        full.text,
        _longLatin,
        reason: 'the expanded view renders the unchanged full source',
      );
      expect(full.selectable, isTrue);
      expect(find.byKey(_previewKey), findsNothing);
      expect(_expand, findsNothing);
      expect(find.text(_collapseLabel), findsOneWidget);

      await _tap(tester, _collapse);

      expect(_markdown, findsNothing);
      expect(find.byKey(_previewKey), findsOneWidget);
      expect(_expand, findsOneWidget);
      expect(
        fixture.adapter.requests.length,
        requests,
        reason: 'expand and collapse are local only',
      );
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'long merge request description is previewed and expands to the full source',
    (tester) async {
      _surface(tester, const Size(390, 844));
      final fixture = _fixture()..putMergeRequest(5, _longLatin);

      await tester.pumpWidget(
        _host(_page(fixture, resource: 'merge_requests', iid: 5)),
      );
      await settleNetworkWidgets(tester);

      expect(_markdown, findsNothing);
      expect(find.text('可以合併'), findsOneWidget);
      expect(find.byKey(_previewKey), findsOneWidget);
      final requests = fixture.adapter.requests.length;

      await _tap(tester, _expand);
      expect(tester.widget<MarkdownView>(_markdown).text, _longLatin);
      await _tap(tester, _collapse);
      expect(_markdown, findsNothing);
      expect(fixture.adapter.requests.length, requests);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets('long CJK and emoji preview never splits a grapheme', (
    tester,
  ) async {
    _surface(tester, const Size(390, 844));
    final fixture = _fixture()..putIssue(1, _longCjk);

    await tester.pumpWidget(_host(_page(fixture)));
    await settleNetworkWidgets(tester);

    expect(_markdown, findsNothing);
    final preview = _previewText(tester);
    expect(preview, endsWith('…'));
    expect(
      preview.runes.where((rune) => rune >= 0xD800 && rune <= 0xDFFF),
      isEmpty,
      reason: 'no lone surrogate',
    );
    const allowed = {'測', '試', '說', '明', '👨‍👩‍👧‍👦', '🇹🇼', ' ', '…'};
    expect(
      preview.characters.where((grapheme) => !allowed.contains(grapheme)),
      isEmpty,
    );
    expect(preview.characters.length, greaterThan(20));

    await _tap(tester, _expand);
    expect(tester.widget<MarkdownView>(_markdown).text, _longCjk);
  });

  testWidgets('320dp at 2x text keeps 48dp toggles and no overflow', (
    tester,
  ) async {
    _surface(tester, const Size(320, 760));
    final fixture = _fixture()..putIssue(1, _longCjk);

    await tester.pumpWidget(_host(_page(fixture), textScale: 2));
    await settleNetworkWidgets(tester);

    expect(tester.takeException(), isNull);
    expect(_markdown, findsNothing);
    final expand = tester.getSize(_expand);
    expect(expand.height, greaterThanOrEqualTo(48));
    expect(expand.width, greaterThanOrEqualTo(48));

    await _tap(tester, _expand);
    expect(tester.takeException(), isNull);
    expect(_markdown, findsOneWidget);
    final collapse = tester.getSize(_collapse);
    expect(collapse.height, greaterThanOrEqualTo(48));
    expect(collapse.width, greaterThanOrEqualTo(48));

    await _tap(tester, _collapse);
    expect(tester.takeException(), isNull);
    expect(_markdown, findsNothing);
  });

  for (final (size, scale) in [
    (const Size(390, 844), 1.0),
    (const Size(320, 760), 2.0),
  ]) {
    testWidgets(
      'collapse is reachable right after expanding at ${size.width.toInt()}dp ${scale}x text',
      (tester) async {
        _surface(tester, size);
        final fixture = _fixture()..putIssue(1, _longLatin);

        await tester.pumpWidget(_host(_page(fixture), textScale: scale));
        await settleNetworkWidgets(tester);

        await _expectCollapseReachableAfterExpand(tester);
        expect(tester.takeException(), isNull);
        expect(fixture.unhandled, isEmpty);
      },
    );
  }

  testWidgets(
    'the toggle keeps focus and reports its expanded state on the button',
    (tester) async {
      _surface(tester, const Size(390, 844));
      final fixture = _fixture()..putIssue(1, _longLatin);

      await tester.pumpWidget(_host(_page(fixture)));
      await settleNetworkWidgets(tester);
      final handle = tester.ensureSemantics();

      final button = tester.element(_expand);
      final focus = Focus.of(tester.element(find.text(_expandLabel)));
      focus.requestFocus();
      await tester.pump();
      // The focused flag reaches the semantics tree one frame after focus moves.
      await tester.pump();
      expect(focus.hasPrimaryFocus, isTrue);
      expect(
        tester.getSemantics(find.text(_expandLabel)),
        isSemantics(
          isButton: true,
          isFocused: true,
          hasExpandedState: true,
          isExpanded: false,
        ),
      );

      await _tap(tester, _expand);

      expect(
        tester.element(_collapse),
        same(button),
        reason: 'one toggle, not a replaced button',
      );
      expect(Focus.of(tester.element(find.text(_collapseLabel))), same(focus));
      expect(
        focus.hasPrimaryFocus,
        isTrue,
        reason: 'the reader keeps their place on the toggle',
      );
      expect(
        tester.getSemantics(find.text(_collapseLabel)),
        isSemantics(
          isButton: true,
          isFocused: true,
          hasExpandedState: true,
          isExpanded: true,
        ),
      );

      await _tap(tester, _collapse);

      expect(tester.element(_expand), same(button));
      expect(focus.hasPrimaryFocus, isTrue);
      expect(
        tester.getSemantics(find.text(_expandLabel)),
        isSemantics(
          isButton: true,
          isFocused: true,
          hasExpandedState: true,
          isExpanded: false,
        ),
      );
      handle.dispose();
    },
  );

  testWidgets(
    'expansion survives a metadata refresh and resets when the content is replaced',
    (tester) async {
      _surface(tester, const Size(390, 844));
      final fixture = _fixture()..putIssue(1, _longLatin);

      await tester.pumpWidget(_host(_page(fixture)));
      await settleNetworkWidgets(tester);
      await _tap(tester, _expand);
      expect(_markdown, findsOneWidget);

      fixture.touchMetadata('issues', 1);
      final reads = fixture.recordReads('issues', 1);
      await _refresh(tester);
      expect(fixture.recordReads('issues', 1), reads + 1);
      expect(
        _markdown,
        findsOneWidget,
        reason: 'same description source keeps the reader expanded',
      );
      expect(tester.widget<MarkdownView>(_markdown).text, _longLatin);

      final replacement = 'Replacement body ${List.filled(900, 'y').join()}';
      fixture.replaceDescription('issues', 1, replacement);
      await _refresh(tester);
      expect(fixture.recordReads('issues', 1), reads + 2);
      expect(
        _markdown,
        findsNothing,
        reason: 'new content starts collapsed instead of a stale expansion',
      );
      expect(_previewText(tester), startsWith('Replacement body'));
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets('switching to another work item resets an expanded description', (
    tester,
  ) async {
    _surface(tester, const Size(390, 844));
    final fixture = _fixture()
      ..putIssue(1, _longLatin)
      ..putIssue(2, _longLatin);
    final iid = ValueNotifier(1);
    addTearDown(iid.dispose);

    await tester.pumpWidget(
      _host(
        ValueListenableBuilder<int>(
          valueListenable: iid,
          builder: (context, value, _) => _page(fixture, iid: value),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await _tap(tester, _expand);
    expect(_markdown, findsOneWidget);

    iid.value = 2;
    await settleNetworkWidgets(tester);

    expect(fixture.recordReads('issues', 2), 1);
    expect(
      _markdown,
      findsNothing,
      reason: 'identical text on another resource must not inherit expansion',
    );
    expect(_expand, findsOneWidget);
    expect(
      fixture.adapter.requests.any(
        (r) => r.uri.path.contains('/issues/2/award_emoji'),
      ),
      isTrue,
      reason: 'switching work items rebinds sibling state cleanly',
    );
  });

  testWidgets(
    'expanded long description is kept while the list discards it off screen',
    (tester) async {
      _surface(tester, const Size(390, 844));
      final fixture = _fixture()
        ..putIssue(1, _longLatin)
        ..putRelations(1, 16);

      await tester.pumpWidget(_host(_page(fixture)));
      await settleNetworkWidgets(tester);
      final summary = _summaryScrollable;

      await _scrollToEnd(tester, summary);
      expect(find.text('Linked issue 15').hitTestable(), findsOneWidget);
      expect(
        find.byKey(_previewKey, skipOffstage: false),
        findsNothing,
        reason:
            'the trailing rows push a collapsed description out of the list entirely',
      );
      await _scrollToTop(tester, summary, _expand);
      expect(_expand.hitTestable(), findsOneWidget);
      expect(find.byKey(_previewKey).hitTestable(), findsOneWidget);

      await _tap(tester, _expand);
      expect(_markdown, findsOneWidget);
      final kept = tester.state<State<MarkdownView>>(_markdown);

      await _scrollToEnd(tester, summary);
      expect(find.text('Linked issue 15').hitTestable(), findsOneWidget);
      expect(
        _markdown,
        findsNothing,
        reason: 'the expanded description is fully off screen',
      );
      expect(
        tester.state<State<MarkdownView>>(
          find.byType(MarkdownView, skipOffstage: false),
        ),
        same(kept),
      );

      await _scrollToTop(tester, summary, _collapse);
      expect(tester.state<State<MarkdownView>>(_markdown), same(kept));
      expect(find.byKey(_previewKey, skipOffstage: false), findsNothing);
      expect(_collapse.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'long description with media reads nothing until expanded and keeps guarded Markdown inputs',
    (tester) async {
      _surface(tester, const Size(390, 844));
      const secret = '0123456789abcdef0123456789abcdef';
      final media =
          '![shot](/uploads/$secret/shot.png)\n\n[guide](docs/guide.md)\n\n'
          '${List.generate(30, (i) => 'Context line $i with filler text.').join('\n\n')}';
      final fixture = _fixture()
        ..putIssue(1, _shortMarkdown)
        ..putIssue(2, media);
      bool upload(RequestOptions request) =>
          request.uri.path.contains('/uploads/');

      await tester.pumpWidget(_host(_page(fixture)));
      await settleNetworkWidgets(tester);
      final short = tester.widget<MarkdownView>(_markdown);

      await tester.pumpWidget(_host(_page(fixture, iid: 2)));
      await settleNetworkWidgets(tester);
      expect(_markdown, findsNothing);
      expect(
        fixture.adapter.requests.where(upload),
        isEmpty,
        reason: 'a collapsed description reads no attachment',
      );
      expect(fixture.unhandled, isEmpty);

      await _tap(tester, _expand);
      await settleNetworkWidgets(tester);

      final full = tester.widget<MarkdownView>(_markdown);
      expect(full.text, media);
      expect(full.api, same(short.api));
      expect(
        full.base,
        short.base!.resolve('2'),
        reason: 'each item keeps its own web base',
      );
      expect(full.projectId, short.projectId);
      expect(full.projectWeb, short.projectWeb);
      expect(full.projectPath, short.projectPath);
      final uploads = fixture.adapter.requests
          .where(upload)
          .map((request) => request.uri.path)
          .toSet();
      expect(uploads, hasLength(1));
      expect(
        uploads.single,
        endsWith('/api/v4/projects/42/uploads/$secret/shot.png'),
      );
    },
  );

  testWidgets(
    'collapsed long description and siblings are retained across discussion tab roundtrip',
    (tester) async {
      _surface(tester, const Size(390, 844));
      final fixture = _fixture()
        ..putIssue(1, _longLatin)
        ..putRelations(1, 2);

      await tester.pumpWidget(_host(_page(fixture)));
      await settleNetworkWidgets(tester);

      expect(_markdown, findsNothing);
      expect(find.byKey(_previewKey), findsOneWidget);
      expect(_expand, findsOneWidget);
      expect(fixture.recordReads('issues', 1), 1);
      final initialRequests = fixture.adapter.requests.length;
      expect(
        initialRequests,
        4,
        reason: 'issue record, reactions, related merge requests, and links',
      );

      await _tap(tester, find.text('討論'));
      await settleNetworkWidgets(tester);

      final discussionsRequests = fixture.adapter.requests.length;
      expect(
        discussionsRequests,
        greaterThan(initialRequests),
        reason: 'discussions tab intentionally queries its initial notes',
      );
      expect(
        fixture.adapter.requests.any(
          (r) => r.uri.path.endsWith('/issues/1/discussions'),
        ),
        isTrue,
      );

      await _tap(tester, find.text('摘要'));
      await settleNetworkWidgets(tester);

      expect(
        fixture.adapter.requests.length,
        discussionsRequests,
        reason: 'returning to summary issues no new network requests',
      );
      expect(
        fixture.recordReads('issues', 1),
        1,
        reason: 'issue record is retained without reload',
      );
      expect(
        _markdown,
        findsNothing,
        reason: 'description remains collapsed after roundtrip',
      );
      expect(find.byKey(_previewKey), findsOneWidget);
      expect(_expand, findsOneWidget);
      expect(
        find.text('Linked issue 0'),
        findsOneWidget,
        reason: 'retained sibling binding remains original current resource',
      );
      expect(fixture.unhandled, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
