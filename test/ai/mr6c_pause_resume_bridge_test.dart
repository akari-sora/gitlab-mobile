import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/execution_gate.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/request_meter.dart';
import 'package:gitlab_mobile/features/ai/ai_background_execution.dart';

import '../support/fake_adapter.dart';

Future<T> _guardedRead<T>(
  AiBackgroundRunGate gate,
  Future<T> Function() read,
) {
  bool current() {
    if (!gate.executionEligible) {
      throw const AiExecutionPaused(AiExecutionPause(
        AiExecutionPauseReason.foregroundRequired,
      ));
    }
    return true;
  }
  return RequestMeter(onRequest: current).runAsync(
    () => CachedRead.run(read, mayStart: current),
  );
}

final class _Peer {
  _Peer(this.channel);
  final MethodChannel channel;
  final calls = <MethodCall>[];
  String? rejection;
  String? exceptionCode;
  bool cleanupFails = false;
  bool callbackBeforeRejection = false;
  String? permit;
  int starts = 0;
  int ticket = 0;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = call.arguments as Map<Object?, Object?>;
    switch (call.method) {
      case 'startRuns':
        starts++;
        if (exceptionCode case final code?) throw PlatformException(code: code);
        if (rejection case final reason?) {
          if (callbackBeforeRejection) {
            final done = Completer<void>();
            await TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .handlePlatformMessage(
                  channel.name,
                  const StandardMethodCodec().encodeMethodCall(
                    MethodCall('permitInvalidated', {
                      'version': 1,
                      'permitId': 'refused-pending-permit',
                      'startRequestId': args['startRequestId'],
                      'reason': reason,
                    }),
                  ),
                  (_) => done.complete(),
                );
            await done.future;
          }
          return {'version': 1, 'status': 'rejected', 'reason': reason};
        }
        permit = 'permit-$starts';
        return {
          'version': 1,
          'status': 'active',
          'permitId': permit,
          'startRequestId': args['startRequestId'],
          'opSeq': args['opSeq'],
        };
      case 'releaseRuns':
        if (cleanupFails) {
          return {
            'version': 1,
            'status': 'rejected',
            'reason': 'cleanup_failed',
          };
        }
        final didRelease = permit != null && args['permitId'] == permit;
        if (didRelease) permit = null;
        return {'version': 1, 'status': 'released', 'didRelease': didRelease};
      case 'updateProgress':
        if (permit == null || args['permitId'] != permit) {
          return {
            'version': 1,
            'status': 'rejected',
            'reason': 'permit_inactive',
          };
        }
        return {'version': 1, 'status': 'updated', 'permitId': permit};
      case 'acquireContinuation':
        return {
          'version': 1,
          'status': 'ticket',
          'permitId': args['permitId'],
          'kind': args['kind'],
          'nonce': args['nonce'],
          'ticketId':
              '00000000-0000-4000-8000-${(++ticket).toString().padLeft(12, '0')}',
        };
      case 'stopAll':
        permit = null;
        return {'version': 1, 'status': 'stopped'};
    }
    throw StateError('Unexpected method ${call.method}');
  }

  Future<void> invalidate(String reason) async {
    final old = permit!;
    permit = null;
    final done = Completer<void>();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('permitInvalidated', {
              'version': 1,
              'permitId': old,
              'reason': reason,
            }),
          ),
          (_) => done.complete(),
        );
    await done.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var channelIndex = 0;

  Future<(AiBackgroundExecution, AiBackgroundRunGate, _Peer)> setup(
    bool Function() visible,
  ) async {
    final channel = MethodChannel('mr6c-c5-bridge-${channelIndex++}');
    final peer = _Peer(channel);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, peer.handle);
    final owner = AiBackgroundExecution(
      accountKey: 'synthetic',
      generation: 1,
      ownerApi: Object(),
      isCurrent: () => true,
      appInForeground: visible,
      channel: channel,
    );
    final gate = owner.createGate(
      conversationId: () => 'conversation',
      isCurrent: () => true,
    );
    addTearDown(() async {
      await owner.releaseRuns();
      owner.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });
    return (owner, gate, peer);
  }

  test(
    'serviceless context admission gates raw GET after a settled file HEAD',
    () async {
      var foreground = true;
      final (owner, gate, peer) = await setup(() => foreground);
      peer.rejection = 'start_denied';
      await gate.beginRun(runId: 'logical-run');
      final entered = Completer<void>();
      final response = Completer<void>();
      addTearDown(() {
        if (!response.isCompleted) response.complete();
      });
      final adapter = FakeAdapter((request) async {
        if (request.method == 'HEAD') {
          if (!entered.isCompleted) entered.complete();
          await response.future;
          return ResponseBody.fromString('', 200);
        }
        return ResponseBody.fromString('synthetic file', 200);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      Future<String> read() => _guardedRead(
        gate,
        () => api.textFile(42, 'main', 'README.md', refresh: true),
      );
      final reading = read();
      await entered.future;
      foreground = false;
      owner.didChangeAppLifecycleState(AppLifecycleState.hidden);
      final paused = expectLater(reading, throwsA(isA<AiExecutionPaused>()));
      response.complete();
      await paused;
      expect(adapter.requests.map((request) => request.method), ['HEAD']);
      foreground = true;
      owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await owner.onForeground();
      expect(gate.executionEligible, isFalse);
      expect(adapter.requests, hasLength(1));
      await gate.resumeRun();
      expect(await read(), 'synthetic file');
      expect(adapter.requests.map((request) => request.method), [
        'HEAD', 'HEAD', 'GET',
      ]);
      expect(gate.binding.runId, 'logical-run');
      expect(peer.starts, 2);
    },
  );

  for (final boundary in ['unauthorized response', 'token response']) {
    test(
      'serviceless context pauses API replay but preserves OAuth after $boundary',
      () async {
        var foreground = true;
        final (owner, gate, peer) = await setup(() => foreground);
        peer.rejection = 'start_denied';
        await gate.beginRun(runId: 'logical-run');
        final entered = Completer<void>();
        final response = Completer<void>();
        addTearDown(() {
          if (!response.isCompleted) response.complete();
        });
        final adapter = FakeAdapter((request) async {
          if (request.uri.path.endsWith('/repository/branches/main')) {
            return jsonResponse({
              'name': 'main',
              'commit': {'id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'},
            });
          }
          if (request.uri.path.endsWith('/repository/tree')) {
            fail('an unrelated pinned disk entry must remain eligible');
          }
          if (request.headers['Authorization'] == 'Bearer old-access') {
            if (boundary == 'unauthorized response') {
              if (!entered.isCompleted) entered.complete();
              await response.future;
            }
            return jsonResponse({}, status: 401);
          }
          return jsonResponse({'id': 1, 'title': 'Synthetic issue'});
        });
        final tokens = FakeAdapter((_) async {
          if (boundary == 'token response') {
            if (!entered.isCompleted) entered.complete();
            await response.future;
          }
          return jsonResponse({
            'access_token': 'new-access',
            'refresh_token': 'new-refresh',
            'token_type': 'bearer',
          });
        });
        final instance = GitLabInstance.parse('https://example.com/gitlab');
        final api = GitLabApi(
          instance: instance,
          credential: const OAuthCredential(
            accessToken: 'old-access',
            refreshToken: 'old-refresh',
            clientId: 'synthetic-client',
          ),
          dio: Dio()..httpClientAdapter = adapter,
          oauth: OAuthTokenClient(
            instance: instance,
            clientId: 'synthetic-client',
            dio: Dio()..httpClientAdapter = tokens,
          ),
          readCacheSource: (uri, _) async =>
              uri.path.endsWith('/repository/tree')
                  ? CacheDiskEntry(
                      value: ApiPage<Json>(const [
                        {'name': 'README.md', 'path': 'README.md', 'type': 'blob'},
                      ]),
                      fetchedAt: DateTime.now().subtract(const Duration(hours: 2)),
                      responseBytes: 64,
                    )
                  : null,
        );
        api.bindReadCache('${instance.key}#7', 1);
        addTearDown(api.close);
        Future<CachedRead<Json>> read() => _guardedRead(
          gate,
          () => api.cachedRecord(['projects', '42', 'issues', '1'], fresh: true),
        );
        final reading = read();
        await entered.future;
        foreground = false;
        owner.didChangeAppLifecycleState(AppLifecycleState.hidden);
        final paused = expectLater(reading, throwsA(isA<AiExecutionPaused>()));
        response.complete();
        await paused;
        expect(adapter.requests, hasLength(1));
        // OAuth rotation is account work; the AI meter fences only API sends.
        expect(tokens.requests, hasLength(1));
        expect(api.credential.accessToken, 'new-access');
        foreground = true;
        owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await owner.onForeground();
        expect(gate.executionEligible, isFalse);
        expect(adapter.requests, hasLength(1));
        final ui = await api.cachedRecord(['projects', '42', 'issues', '1']);
        expect(ui.value['title'], 'Synthetic issue');
        expect(ui.superseded, isFalse);
        await api.cachedRecord([
          'projects', '42', 'repository', 'branches', 'main',
        ]);
        final tree = await api.cachedRecords(
          ['projects', '42', 'repository', 'tree'],
          query: const {
            'ref': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'path': '',
            'per_page': '50',
          },
        );
        expect(tree.lineage, CacheLineage.disk);
        expect(tree.value.items.single['name'], 'README.md');
        expect(gate.executionEligible, isFalse);
        expect(peer.starts, 1);
        await gate.resumeRun();
        expect((await read()).value['title'], 'Synthetic issue');
        expect(adapter.requests, hasLength(4));
        expect(tokens.requests, hasLength(1));
        expect(gate.binding.runId, 'logical-run');
        expect(peer.starts, 2);
      },
    );
  }

  test(
    'a refusal callback racing the reply still permits safe degradation',
    () async {
      final (_, gate, peer) = await setup(() => true);
      peer.rejection = 'security_exception';
      peer.callbackBeforeRejection = true;
      final result = await gate.beginRun(runId: 'run');
      expect(result.disposition, AiBackgroundStartDisposition.foregroundOnly);
      expect(result.failure, AiBackgroundStartFailure.securityException);
      expect(gate.executionEligible, isTrue);
      expect(peer.starts, 1);
    },
  );

  for (final (reason, expected) in [
    ('start_denied', AiBackgroundStartFailure.startDenied),
    ('security_exception', AiBackgroundStartFailure.securityException),
    ('foreground_required', AiBackgroundStartFailure.foregroundRequired),
    ('start_failed', AiBackgroundStartFailure.channelRefused),
  ]) {
    test('rejected $reason degrades once after scoped cleanup', () async {
      var visible = true;
      final (owner, gate, peer) = await setup(() => visible);
      peer.rejection = reason;
      final result = await gate.beginRun(runId: 'same-run');
      expect(result.disposition, AiBackgroundStartDisposition.foregroundOnly);
      expect(result.failure, expected);
      expect(gate.binding.permitId, isNull);
      expect(gate.executionEligible, isTrue);
      expect(peer.starts, 1);
      final cleanup = peer.calls.singleWhere((c) => c.method == 'releaseRuns');
      final start = peer.calls.singleWhere((c) => c.method == 'startRuns');
      expect(
        (cleanup.arguments as Map)['startRequestId'],
        (start.arguments as Map)['startRequestId'],
      );
      visible = false;
      expect(gate.executionEligible, isFalse);
      visible = true;
      await owner.onForeground();
      expect(peer.starts, 1);
    });
  }

  for (final (code, expected) in [
    ('SecurityException', AiBackgroundStartFailure.securityException),
    (
      'ForegroundServiceStartNotAllowedException',
      AiBackgroundStartFailure.startDenied,
    ),
  ]) {
    test('$code gets typed refusal and cleanup', () async {
      final (_, gate, peer) = await setup(() => true);
      peer.exceptionCode = code;
      final result = await gate.beginRun(runId: 'run');
      expect(result.disposition, AiBackgroundStartDisposition.foregroundOnly);
      expect(result.failure, expected);
      expect(peer.calls.where((c) => c.method == 'releaseRuns'), hasLength(1));
      expect(peer.starts, 1);
    });
  }

  test('failed cleanup denies even foreground continuation', () async {
    final (_, gate, peer) = await setup(() => true);
    peer.rejection = 'start_denied';
    peer.cleanupFails = true;
    final result = await gate.beginRun(runId: 'run');
    expect(result.disposition, AiBackgroundStartDisposition.unavailable);
    expect(result.failure, AiBackgroundStartFailure.cleanupFailed);
    expect(gate.executionEligible, isFalse);
  });

  test(
    'invalidation needs explicit same-run resume even when foreground',
    () async {
      final (owner, gate, peer) = await setup(() => true);
      expect(
        (await gate.beginRun(runId: 'logical-run')).disposition,
        AiBackgroundStartDisposition.active,
      );
      final old = gate.binding;
      final ticket = await gate.acquire(AiContinuationKind.model);
      await peer.invalidate('timeout');
      expect(gate.executionEligible, isFalse);
      await owner.onForeground();
      expect(peer.starts, 1);
      expect(
        (await gate.resumeRun()).disposition,
        AiBackgroundStartDisposition.active,
      );
      expect(gate.binding.runId, 'logical-run');
      expect(gate.binding, isNot(same(old)));
      expect(peer.starts, 2);
      expect(
        () => ticket.consumeOnce(
          binding: gate.binding,
          kind: AiContinuationKind.model,
        ),
        throwsA(isA<AiExecutionPaused>()),
      );
    },
  );

  test('foreground return does not revive permitless in-flight work', () async {
    var visible = true;
    final (owner, gate, peer) = await setup(() => visible);
    peer.rejection = 'start_denied';
    await gate.beginRun(runId: 'logical-run');
    final issued = await gate.acquire(AiContinuationKind.model);
    visible = false;
    owner.didChangeAppLifecycleState(AppLifecycleState.hidden);
    visible = true;
    owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(peer.starts, 1);
    expect(gate.requiresExplicitResume, isTrue);
    expect(gate.executionEligible, isFalse);
    expect(
      () => issued.consumeOnce(
        binding: gate.binding,
        kind: AiContinuationKind.model,
      ),
      throwsA(isA<AiExecutionPaused>()),
    );
    peer.rejection = null;
    final result = await gate.resumeRun();
    expect(result.disposition, AiBackgroundStartDisposition.active);
    expect(gate.binding.runId, 'logical-run');
    expect(peer.starts, 2);
  });

  test('unsupported platform observes lifecycle and requires resume', () async {
    var visible = true;
    final owner = AiBackgroundExecution(
      accountKey: 'synthetic',
      generation: 1,
      ownerApi: Object(),
      isCurrent: () => true,
      appInForeground: () => visible,
    );
    addTearDown(owner.dispose);
    final gate = owner.createGate(
      conversationId: () => 'conversation',
      isCurrent: () => true,
    );
    final first = await gate.beginRun(runId: 'logical-run');
    expect(first.disposition, AiBackgroundStartDisposition.foregroundOnly);
    expect(first.failure, AiBackgroundStartFailure.unsupported);
    final ticket = await gate.acquire(AiContinuationKind.model);
    visible = false;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.hidden,
    );
    visible = true;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    expect(gate.requiresExplicitResume, isTrue);
    expect(gate.executionEligible, isFalse);
    expect(
      () => ticket.consumeOnce(
        binding: gate.binding,
        kind: AiContinuationKind.model,
      ),
      throwsA(isA<AiExecutionPaused>()),
    );
    final resumed = await gate.resumeRun();
    expect(resumed.disposition, AiBackgroundStartDisposition.foregroundOnly);
    expect(resumed.failure, AiBackgroundStartFailure.unsupported);
    expect(gate.binding.runId, 'logical-run');
    expect(gate.executionEligible, isTrue);
  });

  test(
    'explicit approval restarts after normal release and preserves binding',
    () async {
      final (_, gate, peer) = await setup(() => true);
      await gate.beginRun(runId: 'logical-run');
      final binding = gate.binding;
      final oldTicket = await gate.acquire(AiContinuationKind.mutation);
      gate.setWork(active: false, backProtected: true, awaitingApproval: true);
      await gate.pendingNormalRelease;
      expect(peer.permit, isNull);
      expect(gate.binding, same(binding));
      expect(peer.starts, 1);
      final localTicket = await gate.acquire(AiContinuationKind.mutation);
      final result = await gate.restartForApproval();
      expect(result.disposition, AiBackgroundStartDisposition.active);
      expect(peer.starts, 2);
      expect(gate.binding, same(binding));
      expect(binding.runId, 'logical-run');
      expect(
        () => oldTicket.consumeOnce(
          binding: binding,
          kind: AiContinuationKind.mutation,
        ),
        throwsA(isA<AiExecutionPaused>()),
      );
      final fresh = await gate.acquire(AiContinuationKind.mutation);
      fresh.consumeOnce(binding: binding, kind: AiContinuationKind.mutation);
      gate.setWork(active: false, backProtected: true, awaitingApproval: true);
      await gate.pendingNormalRelease;
      expect(binding.permitId, isNull);
      expect(
        () => localTicket.consumeOnce(
          binding: binding,
          kind: AiContinuationKind.mutation,
        ),
        throwsA(isA<AiExecutionPaused>()),
      );
    },
  );
}
