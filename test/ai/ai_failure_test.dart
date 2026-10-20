import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/features/ai/ai_gate.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

void main() {
  test('AI gate defaults off during MR1', () {
    expect(aiAssistantEnabled, isFalse);
  });

  test('HTTP failures preserve AI semantics and allowlisted metadata', () {
    final kinds = <int, AiFailureKind>{
      401: AiFailureKind.unauthenticated,
      403: AiFailureKind.forbidden,
      404: AiFailureKind.notFound,
      413: AiFailureKind.requestTooLarge,
      429: AiFailureKind.quotaExhausted,
      302: AiFailureKind.redirectBlocked,
      503: AiFailureKind.server,
      400: AiFailureKind.invalidResponse,
    };
    for (final entry in kinds.entries) {
      final failure = AiFailure.fromStatus(entry.key);
      expect(failure.kind, entry.value);
      expect(failure.status, entry.key);
      expect(failure.retryAt, isNull);
    }
    final now = DateTime.utc(2026, 10, 20);
    final limited = AiFailure.fromStatus(429, retryAfter: '12', now: now);
    expect(limited.kind, AiFailureKind.rateLimited);
    expect(limited.retryAt, now.add(const Duration(seconds: 12)));
    expect(
      AiFailure.parseRetryAfter('Tue, 20 Oct 2026 00:01:00 GMT'),
      DateTime.utc(2026, 10, 20, 0, 1),
    );
    for (final bad in ['-1', 'garbage', '']) {
      expect(AiFailure.parseRetryAfter(bad), isNull);
    }
    expect(AiFailure.fromStatus(503, retryAfter: '12').retryAt, isNull);
  });

  test(
    'failure text follows current locale without including raw exceptions',
    () {
      for (final kind in AiFailureKind.values) {
        final failure = AiFailure(kind, status: 400);
        expect(failure, isA<UserFacingFailure>());
        expect(failure.title, isNotEmpty);
        expect(failure.detail, isNotEmpty);
        expect(failure.toString(), 'AiFailure(${kind.name}, status: 400)');
      }
      const failure = AiFailure(AiFailureKind.cancelled);
      final original = failure.title;
      useLanguage(languageForTag('en')!);
      expect(failure.title, isNot(original));
      expect(failure.detail, contains('may have been billed'));
      expect(const ApiFailure(FailureKind.network), isA<UserFacingFailure>());
      expect(
        safeFailure(StateError('synthetic-private-body')).detail,
        isNot(contains('synthetic-private-body')),
      );
      useLanguage(sourceLanguage);
    },
  );

  for (final error in <Object>[
    const AiFailure(AiFailureKind.policyBlocked),
    const ApiFailure(FailureKind.forbidden),
    StateError('synthetic-private-body'),
  ]) {
    testWidgets('showFailure displays safe text for ${error.runtimeType}', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showFailure(context, error),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pump();
      final failure = error is UserFacingFailure ? error : safeFailure(error);
      expect(
        find.text(l10n.titleThenDetail(failure.title, failure.detail)),
        findsOneWidget,
      );
      expect(find.textContaining('synthetic-private-body'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
