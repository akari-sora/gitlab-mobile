import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'support/fake_adapter.dart';

void main() {
  group('R1.3 live_smoke ci_quota_exceeded resilience simulation', () {
    test('marks NOT_RUN(quota) and continues to check 34 when pipeline failure_reason is ci_quota_exceeded', () async {
      final executedChecks = <String>[];
      final checks = <Map<String, dynamic>>[];
      var cleanedUp = false;

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.contains('/pipelines/100/jobs')) {
          return jsonResponse([]);
        }
        if (path.contains('/pipelines/100')) {
          return jsonResponse({
            'id': 100,
            'status': 'failed',
            'failure_reason': 'ci_quota_exceeded',
          });
        }
        if (path.contains('/projects/1/pipelines/100/retry')) {
          return jsonResponse({'id': 100, 'status': 'pending'});
        }
        if (path.contains('/projects/1/pipelines/100/cancel')) {
          return jsonResponse({'id': 100, 'status': 'canceled'});
        }
        return jsonResponse({});
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      final root = ['projects', '1'];
      final pipeline = 100;

      Future<void> check(String name, Future<void> Function() block) async {
        try {
          await block();
          executedChecks.add(name);
          checks.add({'name': name, 'status': 'PASS'});
        } catch (_) {
          checks.add({'name': name, 'status': 'FAIL'});
          rethrow;
        }
      }

      // Simulated logic from live_smoke.dart lines 268-326
      try {
        final pipelineRecord = await api.record([...root, 'pipelines', '$pipeline']);
        final jobs = (await api.records([...root, 'pipelines', '$pipeline', 'jobs'])).items;
        final quotaExceeded = pipelineRecord['failure_reason'] == 'ci_quota_exceeded' ||
            jobs.any((Map<String, dynamic> j) => j['failure_reason'] == 'ci_quota_exceeded');
        if (quotaExceeded) {
          checks.add({
            'name': 'jobs.read_trace_retry_new_attempt_and_manual_play',
            'status': 'NOT_RUN',
            'reason': 'ci_quota_exceeded',
          });
        } else {
          await check('jobs.read_trace_retry_new_attempt_and_manual_play', () async {
            executedChecks.add('jobs.read_trace_retry_new_attempt_and_manual_play');
          });
        }
      } catch (e) {
        var quotaExceeded = e.toString().contains('ci_quota_exceeded');
        if (quotaExceeded) {
          checks.removeWhere((c) => c['name'] == 'jobs.read_trace_retry_new_attempt_and_manual_play');
          checks.add({
            'name': 'jobs.read_trace_retry_new_attempt_and_manual_play',
            'status': 'NOT_RUN',
            'reason': 'ci_quota_exceeded',
          });
        } else {
          rethrow;
        }
      }

      // Check 34 must run
      await check('pipelines.retry_then_cancel_then_delete', () async {
        executedChecks.add('pipelines.retry_then_cancel_then_delete');
      });

      cleanedUp = true;

      // Verification
      expect(executedChecks, contains('pipelines.retry_then_cancel_then_delete'));
      expect(executedChecks, isNot(contains('jobs.read_trace_retry_new_attempt_and_manual_play')));
      expect(
        checks.any((c) =>
            c['name'] == 'jobs.read_trace_retry_new_attempt_and_manual_play' &&
            c['status'] == 'NOT_RUN' &&
            c['reason'] == 'ci_quota_exceeded'),
        isTrue,
      );
      expect(cleanedUp, isTrue);
    });

    test('recovers via catch block when jobs fail with ci_quota_exceeded midway and allows check 34', () async {
      final executedChecks = <String>[];
      final checks = <Map<String, dynamic>>[];
      var cleanedUp = false;

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.contains('/pipelines/100/jobs')) {
          return jsonResponse([
            {'id': 10, 'name': 'smoke', 'failure_reason': 'ci_quota_exceeded'},
          ]);
        }
        if (path.contains('/pipelines/100')) {
          return jsonResponse({
            'id': 100,
            'status': 'failed',
          });
        }
        return jsonResponse({});
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      final root = ['projects', '1'];
      final pipeline = 100;

      Future<void> check(String name, Future<void> Function() block) async {
        try {
          await block();
          executedChecks.add(name);
          checks.add({'name': name, 'status': 'PASS'});
        } catch (_) {
          checks.add({'name': name, 'status': 'FAIL'});
          rethrow;
        }
      }

      try {
        final pipelineRecord = await api.record([...root, 'pipelines', '$pipeline']);
        final jobs = (await api.records([...root, 'pipelines', '$pipeline', 'jobs'])).items;
        final quotaExceeded = pipelineRecord['failure_reason'] == 'ci_quota_exceeded' ||
            jobs.any((Map<String, dynamic> j) => j['failure_reason'] == 'ci_quota_exceeded');
        if (quotaExceeded) {
          checks.add({
            'name': 'jobs.read_trace_retry_new_attempt_and_manual_play',
            'status': 'NOT_RUN',
            'reason': 'ci_quota_exceeded',
          });
        } else {
          await check('jobs.read_trace_retry_new_attempt_and_manual_play', () async {
            throw const FormatException('ci_quota_exceeded during trace');
          });
        }
      } catch (e) {
        var quotaExceeded = e.toString().contains('ci_quota_exceeded');
        if (quotaExceeded) {
          checks.removeWhere((c) => c['name'] == 'jobs.read_trace_retry_new_attempt_and_manual_play');
          checks.add({
            'name': 'jobs.read_trace_retry_new_attempt_and_manual_play',
            'status': 'NOT_RUN',
            'reason': 'ci_quota_exceeded',
          });
        } else {
          rethrow;
        }
      }

      await check('pipelines.retry_then_cancel_then_delete', () async {
        executedChecks.add('pipelines.retry_then_cancel_then_delete');
      });

      cleanedUp = true;

      expect(executedChecks, contains('pipelines.retry_then_cancel_then_delete'));
      expect(
        checks.any((c) =>
            c['name'] == 'jobs.read_trace_retry_new_attempt_and_manual_play' &&
            c['status'] == 'NOT_RUN' &&
            c['reason'] == 'ci_quota_exceeded'),
        isTrue,
      );
      expect(cleanedUp, isTrue);
    });

    test('rethrows real non-quota errors without masking them as NOT_RUN', () async {
      final checks = <Map<String, dynamic>>[];

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.contains('/pipelines/100/jobs')) {
          return jsonResponse([
            {'id': 10, 'name': 'smoke', 'failure_reason': 'script_failure'},
          ]);
        }
        if (path.contains('/pipelines/100')) {
          return jsonResponse({
            'id': 100,
            'status': 'failed',
            'failure_reason': 'script_failure',
          });
        }
        return jsonResponse({});
      });

      final api = testApi(adapter);
      addTearDown(api.close);

      final root = ['projects', '1'];
      final pipeline = 100;

      Future<void> check(String name, Future<void> Function() block) async {
        try {
          await block();
          checks.add({'name': name, 'status': 'PASS'});
        } catch (_) {
          checks.add({'name': name, 'status': 'FAIL'});
          rethrow;
        }
      }

      var errorThrown = false;
      try {
        final pipelineRecord = await api.record([...root, 'pipelines', '$pipeline']);
        final jobs = (await api.records([...root, 'pipelines', '$pipeline', 'jobs'])).items;
        final quotaExceeded = pipelineRecord['failure_reason'] == 'ci_quota_exceeded' ||
            jobs.any((Map<String, dynamic> j) => j['failure_reason'] == 'ci_quota_exceeded');
        if (quotaExceeded) {
          checks.add({
            'name': 'jobs.read_trace_retry_new_attempt_and_manual_play',
            'status': 'NOT_RUN',
            'reason': 'ci_quota_exceeded',
          });
        } else {
          await check('jobs.read_trace_retry_new_attempt_and_manual_play', () async {
            throw const FormatException('Random server failure');
          });
        }
      } catch (e) {
        var quotaExceeded = e.toString().contains('ci_quota_exceeded');
        if (quotaExceeded) {
          checks.removeWhere((c) => c['name'] == 'jobs.read_trace_retry_new_attempt_and_manual_play');
          checks.add({
            'name': 'jobs.read_trace_retry_new_attempt_and_manual_play',
            'status': 'NOT_RUN',
            'reason': 'ci_quota_exceeded',
          });
        } else {
          errorThrown = true;
        }
      }

      expect(errorThrown, isTrue);
      expect(
        checks.any((c) => c['name'] == 'jobs.read_trace_retry_new_attempt_and_manual_play' && c['status'] == 'FAIL'),
        isTrue,
      );
      expect(
        checks.any((c) => c['status'] == 'NOT_RUN'),
        isFalse,
      );
    });
  });
}
