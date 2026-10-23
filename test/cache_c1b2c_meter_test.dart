import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/request_meter.dart';

const _head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

final class _Secrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => const [];
}

final class _MeterPort implements AiGitLabReadPort {
  _MeterPort(this.onReadFile);

  final Future<AiPortRead<String>> Function(String path) onReadFile;

  @override
  Future<AiPortRead<String>> readFile(String sha, String path) =>
      onReadFile(path);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(invocation.memberName.toString());
}

AiToolCatalogue _catalogue(_MeterPort port) => AiToolCatalogue(
  port: port,
  scope: const AiResourceScope(
    accountKey: 'instance|7',
    instanceKey: 'https://gitlab.example',
    projectId: 9,
    projectPath: 'group/project',
    current: AiResourceRef(kind: AiResourceKind.file, id: 1),
    headSha: _head,
    defaultBranch: 'main',
  ),
  redactor: Redactor(secrets: _Secrets()),
);

AiToolCall _readCall(String id, String path) => AiToolCall(
  id: id,
  name: 'read_file',
  arguments: {'path': path, 'revision': 'head'},
);

void main() {
  test('catalogue charges one HTTP unit for a normal transport send', () async {
    final catalogue = _catalogue(
      _MeterPort((_) async {
        expect(RequestMeter.current, isNotNull);
        RequestMeter.current!.increment();
        return const AiPortRead('body', requestCount: 1);
      }),
    );
    final budget = AiToolBudget();

    final result = await catalogue.execute(
      _readCall('normal', 'normal.dart'),
      budget: budget,
    );

    expect(result.result.isError, isFalse);
    expect(result.gitLabRequests, 1);
    expect(budget.gitLabRequests, 1);
  });

  test(
    'catalogue accepts three HTTP units within the four-unit reservation',
    () async {
      final catalogue = _catalogue(
        _MeterPort((_) async {
          RequestMeter.current!
            ..increment()
            ..increment()
            ..increment();
          return const AiPortRead('body', requestCount: 2);
        }),
      );
      final budget = AiToolBudget(maxGitLabRequests: 4);

      final result = await catalogue.execute(
        _readCall('oauth-replay', 'retry.dart'),
        budget: budget,
      );

      expect(result.result.isError, isFalse);
      expect(result.gitLabRequests, 3);
      expect(budget.gitLabRequests, 3);
    },
  );

  test(
    'catalogue refunds the whole reservation for a zero-send cache hit',
    () async {
      final catalogue = _catalogue(
        _MeterPort((_) async => const AiPortRead('cached', requestCount: 0)),
      );
      final budget = AiToolBudget(maxGitLabRequests: 4);

      final result = await catalogue.execute(
        _readCall('cache-hit', 'cached.dart'),
        budget: budget,
      );

      expect(result.result.isError, isFalse);
      expect(result.gitLabRequests, 0);
      expect(budget.gitLabRequests, 0);
    },
  );

  test(
    'advisory request count cannot override a zero physical count',
    () async {
      final catalogue = _catalogue(
        _MeterPort((_) async => const AiPortRead('cached', requestCount: 9)),
      );
      final budget = AiToolBudget(maxGitLabRequests: 4);

      final result = await catalogue.execute(
        _readCall('advisory-only', 'cached.dart'),
        budget: budget,
      );

      expect(result.result.isError, isFalse);
      expect(result.gitLabRequests, 0);
      expect(budget.gitLabRequests, 0);
    },
  );

  test('catalogue charges sends completed before a partial failure', () async {
    final catalogue = _catalogue(
      _MeterPort((_) async {
        RequestMeter.current!
          ..increment()
          ..increment();
        throw StateError('synthetic second-stage failure');
      }),
    );
    final budget = AiToolBudget(maxGitLabRequests: 4);

    final result = await catalogue.execute(
      _readCall('partial-failure', 'failure.dart'),
      budget: budget,
    );

    expect(result.result.isError, isTrue);
    expect(result.gitLabRequests, 2);
    expect(budget.gitLabRequests, 2);
  });

  test(
    'catalogue charges a dispatched request when the read is cancelled',
    () async {
      final catalogue = _catalogue(
        _MeterPort((_) async {
          RequestMeter.current!.increment();
          throw const ApiFailure(FailureKind.cancelled);
        }),
      );
      final budget = AiToolBudget(maxGitLabRequests: 4);

      final result = await catalogue.execute(
        _readCall('cancelled', 'cancelled.dart'),
        budget: budget,
      );

      expect(result.result.isError, isTrue);
      expect(result.gitLabRequests, 1);
      expect(budget.gitLabRequests, 1);
    },
  );

  test('concurrent catalogue calls keep independent request meters', () async {
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final catalogue = _catalogue(
      _MeterPort((path) async {
        if (path == 'first.dart') {
          RequestMeter.current!.increment();
          firstStarted.complete();
          await releaseFirst.future;
          return const AiPortRead('first', requestCount: 1);
        }
        RequestMeter.current!
          ..increment()
          ..increment();
        return const AiPortRead('second', requestCount: 2);
      }),
    );
    final firstBudget = AiToolBudget(maxGitLabRequests: 4);
    final secondBudget = AiToolBudget(maxGitLabRequests: 4);

    final first = catalogue.execute(
      _readCall('first', 'first.dart'),
      budget: firstBudget,
    );
    await firstStarted.future;
    final second = await catalogue.execute(
      _readCall('second', 'second.dart'),
      budget: secondBudget,
    );
    releaseFirst.complete();
    final firstResult = await first;

    expect(firstResult.gitLabRequests, 1);
    expect(firstBudget.gitLabRequests, 1);
    expect(second.gitLabRequests, 2);
    expect(secondBudget.gitLabRequests, 2);
  });
}
