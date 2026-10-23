import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/merge_request_state.dart';

void main() {
  group('isAutoMergeEnabled', () {
    test('recognises either explicit auto-merge flag for an active MR', () {
      expect(isAutoMergeEnabled(<String, dynamic>{}), isFalse);
      expect(
        isAutoMergeEnabled(<String, dynamic>{
          'state': 'opened',
          'merge_when_pipeline_succeeds': true,
        }),
        isTrue,
      );
      expect(
        isAutoMergeEnabled(<String, dynamic>{
          'state': 'opened',
          'auto_merge_enabled': true,
        }),
        isTrue,
      );
      expect(
        isAutoMergeEnabled(<String, dynamic>{
          'merge_when_pipeline_succeeds': false,
          'auto_merge_enabled': true,
        }),
        isTrue,
      );
    });

    test('closed and merged states override enabled flags', () {
      for (final state in <String>['closed', 'merged']) {
        expect(
          isAutoMergeEnabled(<String, dynamic>{
            'state': state,
            'merge_when_pipeline_succeeds': true,
            'auto_merge_enabled': true,
          }),
          isFalse,
          reason: state,
        );
      }
    });

    test('does not coerce malformed map values', () {
      expect(
        isAutoMergeEnabled(<String, dynamic>{
          'state': 'opened',
          'merge_when_pipeline_succeeds': 'true',
          'auto_merge_enabled': 1,
        }),
        isFalse,
      );
      expect(
        isAutoMergeEnabled(<String, dynamic>{
          'state': 42,
          'auto_merge_enabled': true,
        }),
        isTrue,
      );
    });
  });

  group('canAutoMerge', () {
    test('requires an opened MR that is not already scheduled', () {
      expect(canAutoMerge(<String, dynamic>{}), isFalse);
      for (final state in <String>['closed', 'merged']) {
        expect(
          canAutoMerge(<String, dynamic>{
            'state': state,
            'detailed_merge_status': 'ci_still_running',
          }),
          isFalse,
          reason: state,
        );
      }
      expect(
        canAutoMerge(<String, dynamic>{
          'state': 'opened',
          'auto_merge_enabled': true,
          'detailed_merge_status': 'ci_still_running',
        }),
        isFalse,
      );
      expect(
        canAutoMerge(<String, dynamic>{
          'state': 'opened',
          'merge_when_pipeline_succeeds': true,
          'detailed_merge_status': 'ci_must_pass',
        }),
        isFalse,
      );
    });

    test('accepts explicit statuses that are waiting for CI', () {
      for (final status in <String>['ci_still_running', 'ci_must_pass']) {
        expect(
          canAutoMerge(<String, dynamic>{
            'state': 'opened',
            'detailed_merge_status': status,
          }),
          isTrue,
          reason: status,
        );
      }
    });

    test('accepts pipeline fallback statuses', () {
      for (final status in <String>[
        'running',
        'pending',
        'created',
        'waiting_for_resource',
        'preparing',
        'manual',
      ]) {
        expect(
          canAutoMerge(<String, dynamic>{
            'state': 'opened',
            'head_pipeline': <String, dynamic>{'status': status},
          }),
          isTrue,
          reason: status,
        );
      }

      for (final status in <String>[
        'success',
        'failed',
        'canceled',
        'skipped',
      ]) {
        expect(
          canAutoMerge(<String, dynamic>{
            'state': 'opened',
            'head_pipeline': <String, dynamic>{'status': status},
          }),
          isFalse,
          reason: status,
        );
      }
    });

    test('draft, WIP and conflict flags block pipeline fallbacks', () {
      for (final flag in <String>[
        'draft',
        'work_in_progress',
        'has_conflicts',
      ]) {
        expect(
          canAutoMerge(<String, dynamic>{
            'state': 'opened',
            flag: true,
            'head_pipeline': <String, dynamic>{'status': 'running'},
          }),
          isFalse,
          reason: flag,
        );
      }
      expect(
        canAutoMerge(<String, dynamic>{
          'state': 'opened',
          'merge_status': 'cannot_be_merged',
          'head_pipeline': <String, dynamic>{'status': 'running'},
        }),
        isFalse,
      );
    });

    test('explicit non-candidate statuses override pipeline fallbacks', () {
      for (final status in <String>[
        'conflict',
        'need_rebase',
        'draft_status',
        'broken_status',
        'not_open',
        'cannot_be_merged',
        'mergeable',
      ]) {
        expect(
          canAutoMerge(<String, dynamic>{
            'state': 'opened',
            'detailed_merge_status': status,
            'head_pipeline': <String, dynamic>{'status': 'running'},
          }),
          isFalse,
          reason: status,
        );
      }
    });

    test('malformed values are ignored without coercion or exceptions', () {
      expect(
        canAutoMerge(<String, dynamic>{
          'state': 1,
          'detailed_merge_status': 'ci_still_running',
        }),
        isFalse,
      );
      expect(
        canAutoMerge(<String, dynamic>{
          'state': 'opened',
          'head_pipeline': 'running',
        }),
        isFalse,
      );
      expect(
        canAutoMerge(<String, dynamic>{
          'state': 'opened',
          'detailed_merge_status': 42,
          'head_pipeline': <String, dynamic>{'status': true},
        }),
        isFalse,
      );
      expect(
        canAutoMerge(<String, dynamic>{
          'state': 'opened',
          'draft': 'true',
          'work_in_progress': 1,
          'has_conflicts': <String, dynamic>{},
          'head_pipeline': <String, dynamic>{'status': 'pending'},
        }),
        isTrue,
      );
    });
  });

  test('core helper remains independent of UI and Flutter layers', () {
    final source = File('lib/core/merge_request_state.dart').readAsStringSync();

    expect(source, isNot(contains('shared/workspace_ui.dart')));
    expect(source, isNot(contains('features/')));
    expect(source, isNot(contains('package:flutter/')));
  });
}
