import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

const _clearResult = DiskClearResult(
  keyGoneConfirmed: false,
  directoryGoneConfirmed: false,
  markerDurable: false,
  complete: false,
);

const _state = ReadCacheCleanupState(
  operation: ReadCacheCleanupOperation.mutation,
  disposition: ReadCacheCleanupDisposition.requestBlockedBeforeSend,
  code: ReadCacheCleanupCode.cleanupFailed,
  clearResult: _clearResult,
);

void main() {
  test(
    'all pre-existing kinds retain their exact title and detail mappings',
    () {
      final expected = <FailureKind, (String, String)>{
        FailureKind.unauthenticated: (
          l10n.signInNoLongerValid,
          l10n.reconnectThisAccount,
        ),
        FailureKind.forbidden: (
          l10n.noPermissionForAction,
          l10n.checkRoleScopeAndPolicy,
        ),
        FailureKind.invisible: (
          l10n.cannotOpenResource,
          l10n.accountCannotAccessOrMoved,
        ),
        FailureKind.rateLimited: (
          l10n.tryAgainLater,
          l10n.gitlabLimitingRequestsRetry,
        ),
        FailureKind.network: (
          l10n.cannotConnect,
          l10n.checkNetworkUrlThenRefresh,
        ),
        FailureKind.server: (
          l10n.gitlabTemporarilyUnresponsive,
          l10n.contentKeptConfirmWrite,
        ),
        FailureKind.tooLarge: (
          l10n.contentExceedsPreviewLimit,
          l10n.textPreviewLimitMibLines,
        ),
        FailureKind.attachmentTooLarge: (
          l10n.attachmentExceeds25Mib,
          l10n.chooseFileWithin25Mib,
        ),
        FailureKind.unsupported: (
          l10n.cannotPreviewContentNow,
          l10n.binaryOrFeatureUnsupported,
        ),
        FailureKind.redirectBlocked: (
          l10n.resourceUrlChanged,
          l10n.searchProjectOrUseBrowser,
        ),
        FailureKind.invalidResponse: (
          l10n.cannotReadResponse,
          l10n.serverDataUnparseable,
        ),
        FailureKind.cancelled: (
          l10n.requestCanceled,
          l10n.requestStoppedNoSideEffect,
        ),
        FailureKind.validation: (
          l10n.checkEnteredContent,
          l10n.nameBranchOrFieldsRejected,
        ),
        FailureKind.conflict: (
          l10n.contentHasChanged,
          l10n.reloadLatestThenSubmit,
        ),
        FailureKind.writeUncertain: (
          l10n.actionResultUnconfirmed,
          l10n.writeInterruptedCheckList,
        ),
        FailureKind.aiHistoryCleanup: (
          l10n.aiHistoryCleanupTitle,
          l10n.aiHistoryCleanupDetail,
        ),
        FailureKind.untrustedCertificate: (
          l10n.untrustedCertificateTitle,
          l10n.untrustedCertificateDetail,
        ),
      };

      expect(
        expected.keys,
        containsAll(
          FailureKind.values.where(
            (kind) => kind != FailureKind.readCacheCleanup,
          ),
        ),
      );
      for (final MapEntry(key: kind, value: texts) in expected.entries) {
        final failure = ApiFailure(kind);
        expect(failure.title, texts.$1, reason: kind.name);
        expect(failure.detail, texts.$2, reason: kind.name);
        expect(failure.status, isNull, reason: kind.name);
        expect(failure.retryAt, isNull, reason: kind.name);
        expect(failure.cleanup, isNull, reason: kind.name);
      }
    },
  );

  test(
    'status mapping, retry time and custom presentation remain unchanged',
    () {
      final retryAt = DateTime.utc(2026, 10, 23, 12);
      final cases = <int, FailureKind>{
        200: FailureKind.invalidResponse,
        301: FailureKind.redirectBlocked,
        399: FailureKind.redirectBlocked,
        400: FailureKind.validation,
        401: FailureKind.unauthenticated,
        403: FailureKind.forbidden,
        404: FailureKind.invisible,
        409: FailureKind.conflict,
        412: FailureKind.conflict,
        422: FailureKind.validation,
        429: FailureKind.rateLimited,
        499: FailureKind.invalidResponse,
        500: FailureKind.server,
        599: FailureKind.server,
      };
      for (final MapEntry(key: status, value: kind) in cases.entries) {
        final failure = ApiFailure.fromStatus(status, retryAt: retryAt);
        expect(failure.kind, kind, reason: '$status');
        expect(failure.status, status, reason: '$status');
        expect(
          failure.retryAt,
          status == 429 ? same(retryAt) : isNull,
          reason: '$status',
        );
      }

      const custom = ApiFailure(
        FailureKind.network,
        status: 598,
        title: 'Synthetic title',
        detail: 'Synthetic detail',
      );
      expect(custom.title, 'Synthetic title');
      expect(custom.detail, 'Synthetic detail');
      expect(custom.status, 598);
    },
  );

  test('typed cleanup failure carries the same state and all four flags', () {
    const failure = ApiFailure.readCacheCleanup(_state);
    expect(failure.kind, FailureKind.readCacheCleanup);
    expect(failure.cleanup, same(_state));
    expect(failure.status, isNull);
    expect(failure.retryAt, isNull);
    expect(failure.cleanup!.operation, ReadCacheCleanupOperation.mutation);
    expect(
      failure.cleanup!.disposition,
      ReadCacheCleanupDisposition.requestBlockedBeforeSend,
    );
    expect(failure.cleanup!.code, ReadCacheCleanupCode.cleanupFailed);
    expect(failure.cleanup!.clearResult.keyGoneConfirmed, isFalse);
    expect(failure.cleanup!.clearResult.directoryGoneConfirmed, isFalse);
    expect(failure.cleanup!.clearResult.markerDurable, isFalse);
    expect(failure.cleanup!.clearResult.complete, isFalse);
    expect(failure.title, l10n.tryAgainLater);
    expect(failure.detail, l10n.retryAction);
  });

  test('generic construction asserts cleanup state exactly for its kind', () {
    expect(
      () => ApiFailure(FailureKind.readCacheCleanup),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => ApiFailure(FailureKind.readCacheCleanup, cleanup: _state),
      returnsNormally,
    );
    // No other kind may carry cleanup state and pose as a cleanup failure.
    for (final kind in FailureKind.values.where(
      (kind) => kind != FailureKind.readCacheCleanup,
    )) {
      expect(
        () => ApiFailure(kind, cleanup: _state),
        throwsA(isA<AssertionError>()),
        reason: kind.name,
      );
    }
  });

  test(
    'notice accepts only an exact typed cleanup failure and sink keeps identity',
    () {
      const failure = ApiFailure.readCacheCleanup(_state);
      final notice = ReadCacheNotice(failure);
      ReadCacheNotice? received;
      void sink(ReadCacheNotice value) => received = value;
      expect(sink, isA<ReadCacheNoticeSink>());
      sink(notice);

      expect(notice.failure, same(failure));
      expect(received, same(notice));
      expect(
        () => ReadCacheNotice(const ApiFailure(FailureKind.network)),
        throwsA(isA<AssertionError>()),
      );
    },
  );

  test(
    'cleanup fallback resolves from the current language on every access',
    () {
      final original = l10n.language;
      addTearDown(() => useLanguage(original));
      final english = languageForTag('en')!;
      final japanese = languageForTag('ja')!;
      const failure = ApiFailure.readCacheCleanup(_state);

      useLanguage(english);
      expect(failure.title, l10n.tryAgainLater);
      expect(failure.detail, l10n.retryAction);
      final englishTitle = failure.title;
      final englishDetail = failure.detail;

      useLanguage(japanese);
      expect(failure.title, l10n.tryAgainLater);
      expect(failure.detail, l10n.retryAction);
      expect(failure.title, isNot(englishTitle));
      expect(failure.detail, isNot(englishDetail));
    },
  );

  test('diagnostics omit raw content, identity and cleanup internals', () {
    const rawBody = 'private issue body synthetic-secret';
    const account = 'account@example.invalid#42';
    const failure = ApiFailure.readCacheCleanup(_state);
    final diagnostic = '$failure';

    expect(diagnostic, 'ApiFailure(readCacheCleanup, status: null)');
    expect(diagnostic, isNot(contains(rawBody)));
    expect(diagnostic, isNot(contains(account)));
    expect(diagnostic, isNot(contains('requestBlockedBeforeSend')));
    expect(diagnostic, isNot(contains('cleanupFailed')));
  });

  test(
    'safeFailure preserves ApiFailure identity, status, retryAt and cleanup',
    () {
      final retryAt = DateTime.utc(2026, 10, 23, 12);
      final rate = ApiFailure(
        FailureKind.rateLimited,
        status: 429,
        retryAt: retryAt,
      );
      expect(safeFailure(rate), same(rate));
      expect(safeFailure(rate).status, 429);
      expect(safeFailure(rate).retryAt, same(retryAt));

      const cleanup = ApiFailure.readCacheCleanup(_state);
      expect(safeFailure(cleanup), same(cleanup));
      expect(safeFailure(cleanup).cleanup, same(_state));

      final converted = safeFailure(StateError('synthetic raw failure'));
      expect(converted.kind, FailureKind.invalidResponse);
      expect(converted.status, isNull);
      expect(converted.retryAt, isNull);
      expect(converted.cleanup, isNull);
    },
  );
}
