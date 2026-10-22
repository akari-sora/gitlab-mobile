import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart'
    show AiScopeGrant, AiScopeKind;
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/instance.dart';

// Plan v6 §5 item 9: in a merge request description, a closing pattern that
// names an issue outside the conversation's scope is confirmed at every
// level (bypass included); in-scope ones are listed for the preview. Only
// references new against the field's current value count.

const _mrGrant = AiScopeGrant(
  kind: AiScopeKind.mergeRequest,
  projectId: 42,
  projectPath: 'group/proj',
  iid: 3,
);
const _projectGrant = AiScopeGrant(
  kind: AiScopeKind.project,
  projectId: 42,
  projectPath: 'group/proj',
);

void main() {
  test('every keyword form, in any case, needs confirmation', () {
    const stems = <String>[
      'Close', 'Closes', 'Closed', 'Closing', //
      'Fix', 'Fixes', 'Fixed', 'Fixing', //
      'Resolve', 'Resolves', 'Resolved', 'Resolving', //
      'Implement', 'Implements', 'Implemented', 'Implementing',
    ];
    for (final stem in stems) {
      for (final keyword in [stem, stem.toLowerCase(), stem.toUpperCase()]) {
        final prepared = _prepare('Summary\n\n$keyword #999');
        expect(prepared.policyBlocked, isFalse, reason: keyword);
        expect(
          prepared.confirmReasons,
          contains(AiFixedConfirmReason.closingOrCrossProject),
          reason: keyword,
        );
        expect(prepared.foreignClosingRefs, [
          'group/proj#999',
        ], reason: keyword);
        expect(prepared.closingRefs, isEmpty, reason: keyword);
      }
    }
  });

  test('a colon after the keyword still counts', () {
    for (final text in ['Closes: #999', 'Fixes:#999', 'resolves :  #999']) {
      final prepared = _prepare(text);
      expect(
        prepared.confirmReasons,
        contains(AiFixedConfirmReason.closingOrCrossProject),
        reason: text,
      );
      expect(prepared.foreignClosingRefs, ['group/proj#999'], reason: text);
    }
  });

  test('a list joined by commas and "and" names every issue', () {
    final inScope = _prepare(
      'Fixes #7, #8 and #9',
      grants: const [_projectGrant],
    );
    expect(inScope.closingRefs, [
      'group/proj#7',
      'group/proj#8',
      'group/proj#9',
    ]);
    expect(inScope.foreignClosingRefs, isEmpty);
    expect(inScope.confirmReasons, isEmpty);

    final mixed = _prepare(
      'Closes issue #7,#8, and issues #9',
      grants: const [
        AiScopeGrant(
          kind: AiScopeKind.workItem,
          projectId: 42,
          projectPath: 'group/proj',
          iid: 7,
        ),
      ],
    );
    expect(mixed.closingRefs, ['group/proj#7']);
    expect(mixed.foreignClosingRefs, ['group/proj#8', 'group/proj#9']);
    expect(
      mixed.confirmReasons,
      contains(AiFixedConfirmReason.closingOrCrossProject),
    );
  });

  test('a cross-project closing reference needs confirmation', () {
    final prepared = _prepare(
      'Closes other/proj#5',
      grants: const [_projectGrant],
    );
    expect(
      prepared.confirmReasons,
      contains(AiFixedConfirmReason.closingOrCrossProject),
    );
    expect(prepared.foreignClosingRefs, ['other/proj#5']);
    expect(
      prepared.confirmReasons
          .where((r) => r == AiFixedConfirmReason.closingOrCrossProject)
          .length,
      1,
    );
  });

  test('an issue URL on this instance is a closing reference', () {
    const url = 'https://gitlab.example.com/group/proj/-/issues/5';
    final inScope = _prepare('Resolves $url.', grants: const [_projectGrant]);
    expect(inScope.closingRefs, ['group/proj#5']);
    expect(inScope.confirmReasons, isEmpty);

    final outside = _prepare('Resolves $url');
    expect(outside.foreignClosingRefs, ['group/proj#5']);
    expect(
      outside.confirmReasons,
      contains(AiFixedConfirmReason.closingOrCrossProject),
    );

    final workItem = _prepare(
      'Closes https://gitlab.example.com/group/proj/-/work_items/6',
      grants: const [_projectGrant],
    );
    expect(workItem.closingRefs, ['group/proj#6']);
  });

  test('a reference the current value already closes is not counted', () {
    final kept = _prepare(
      'Rewritten summary\n\nCloses #999',
      current: 'Old summary\n\nCloses #999',
    );
    expect(kept.confirmReasons, isEmpty);
    expect(kept.foreignClosingRefs, isEmpty);
    expect(kept.closingRefs, isEmpty);

    final qualified = _prepare('Fixes group/proj#999', current: 'closes #999');
    expect(qualified.foreignClosingRefs, isEmpty);
    expect(qualified.confirmReasons, isEmpty);

    // Mentioned before, closing now: that is a new effect.
    final mentioned = _prepare('Closes #999', current: 'Related to #999');
    expect(mentioned.foreignClosingRefs, ['group/proj#999']);
    expect(
      mentioned.confirmReasons,
      contains(AiFixedConfirmReason.closingOrCrossProject),
    );
  });

  test('in-scope closing references are listed without a reason', () {
    final prepared = _prepare(
      'Closes #12 and #12',
      grants: const [_projectGrant],
    );
    expect(prepared.closingRefs, ['group/proj#12']);
    expect(prepared.foreignClosingRefs, isEmpty);
    expect(prepared.confirmReasons, isEmpty);
    expect(prepared.policyBlocked, isFalse);
  });

  test('an issue description has no closing semantics', () {
    final prepared = _prepare('Closes #999', field: _issueField);
    expect(prepared.confirmReasons, isEmpty);
    expect(prepared.closingRefs, isEmpty);
    expect(prepared.foreignClosingRefs, isEmpty);
  });

  test('plain mentions and other words are not closing references', () {
    for (final text in [
      'Related to #999',
      'Prefixes #999 with a hash',
      'The closest match is #999',
      'Closes the gap described in #999',
    ]) {
      final prepared = _prepare(text);
      expect(prepared.confirmReasons, isEmpty, reason: text);
      expect(prepared.foreignClosingRefs, isEmpty, reason: text);
    }
  });

  test('a new merge request is scanned when the caller says so', () {
    final unnamed = _prepare('Closes #999', field: null);
    expect(unnamed.confirmReasons, isEmpty);

    final created = _prepare(
      'Closes #999',
      field: null,
      closesIssuesOnMerge: true,
    );
    expect(created.foreignClosingRefs, ['group/proj#999']);
    expect(
      created.confirmReasons,
      contains(AiFixedConfirmReason.closingOrCrossProject),
    );
  });

  test('without grants every new closing reference needs confirmation', () {
    final prepared = _prepare('Closes #1', grants: const []);
    expect(prepared.foreignClosingRefs, ['group/proj#1']);
    expect(
      prepared.confirmReasons,
      contains(AiFixedConfirmReason.closingOrCrossProject),
    );
  });
}

final _mrField = AiFieldProvenance(
  resourceKey: const AiConflictKey('project:42/merge_request:3'),
  fieldName: AiWritableField.mergeRequestDescription,
  completeValue: true,
  projectId: 42,
  projectFullPath: 'group/proj',
  resourceWeb: Uri.parse(
    'https://gitlab.example.com/group/proj/-/merge_requests/3',
  ),
);

final _issueField = AiFieldProvenance(
  resourceKey: const AiConflictKey('project:42/issue:3'),
  fieldName: AiWritableField.issueDescription,
  completeValue: true,
  projectId: 42,
  projectFullPath: 'group/proj',
  resourceWeb: Uri.parse('https://gitlab.example.com/group/proj/-/issues/3'),
);

AiTextOutcome _prepare(
  String text, {
  List<AiScopeGrant> grants = const [_mrGrant],
  String? current,
  Object? field = _sentinel,
  bool closesIssuesOnMerge = false,
}) => prepareWriteText(
  textClass: AiTextClass.quickActionMarkdown,
  modelText: text,
  field: identical(field, _sentinel) ? _mrField : field as AiFieldProvenance?,
  placeholders: UploadPlaceholderTable(
    instance: GitLabInstance.parse('https://gitlab.example.com'),
  ),
  knownSecrets: const <String>{},
  aiAttribution: false,
  visibility: AiVisibilityContext(
    targetProjectPath: 'group/proj',
    scopeGrants: grants,
    closesIssuesOnMerge: closesIssuesOnMerge,
  ),
  currentFieldValue: current,
);

const _sentinel = Object();
