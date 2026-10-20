import '../l10n/l10n.dart';

/// A [FormatException] whose message is written for the user (and already in
/// their language), unlike a parser's technical message. Callers may show it
/// as is.
final class InputFormatException extends FormatException {
  const InputFormatException(super.message);
}
enum FailureKind {
  unauthenticated, forbidden, invisible, rateLimited, network,
  server, tooLarge, attachmentTooLarge, unsupported, redirectBlocked, invalidResponse, cancelled,
  validation, conflict, writeUncertain,
}

/// Diagnostics contain only allowlisted status information, never request data.
final class ApiFailure implements Exception {
  const ApiFailure(this.kind, {this.status, this.retryAt, String? title, String? detail})
      : _title = title,
        _detail = detail;
  final FailureKind kind;
  final int? status;
  final DateTime? retryAt;
  final String? _title;
  final String? _detail;

  /// Archive downloads are not text previews. The 2 MiB / 20,000-line copy does
  /// not describe the 256 MiB archive cap.
  static ApiFailure get artifactTooLarge => ApiFailure(
    FailureKind.tooLarge,
    title: l10n.artifactExceedsDownloadLimit,
    detail: l10n.singleDownloadLimit256Mib,
  );

  static ApiFailure get artifactStorage => ApiFailure(
    FailureKind.network,
    title: l10n.cannotSaveArtifact,
    detail: l10n.cannotWriteDownloadRetry,
  );

  /// Cache removal failed. The account must stay until a later attempt succeeds.
  static ApiFailure get artifactCleanup => ApiFailure(
    FailureKind.network,
    title: l10n.cannotClearArtifacts,
    detail: l10n.accountRemainsRetryRemoval,
  );
  static ApiFailure fromStatus(int status, {DateTime? retryAt}) => switch (status) {
    400 || 422 => ApiFailure(FailureKind.validation, status: status),
    401 => const ApiFailure(FailureKind.unauthenticated, status: 401),
    403 => const ApiFailure(FailureKind.forbidden, status: 403),
    404 => const ApiFailure(FailureKind.invisible, status: 404),
    409 || 412 => ApiFailure(FailureKind.conflict, status: status),
    429 => ApiFailure(FailureKind.rateLimited, status: 429, retryAt: retryAt),
    >= 500 => ApiFailure(FailureKind.server, status: status),
    >= 300 && < 400 => ApiFailure(FailureKind.redirectBlocked, status: status),
    _ => ApiFailure(FailureKind.invalidResponse, status: status),
  };
  String get title => _title ?? switch (kind) {
    FailureKind.unauthenticated => l10n.signInNoLongerValid,
    FailureKind.forbidden => l10n.noPermissionForAction,
    FailureKind.invisible => l10n.cannotOpenResource,
    FailureKind.rateLimited => l10n.tryAgainLater,
    FailureKind.network => l10n.cannotConnect,
    FailureKind.server => l10n.gitlabTemporarilyUnresponsive,
    FailureKind.tooLarge => l10n.contentExceedsPreviewLimit,
    FailureKind.attachmentTooLarge => l10n.attachmentExceeds25Mib,
    FailureKind.unsupported => l10n.cannotPreviewContentNow,
    FailureKind.redirectBlocked => l10n.resourceUrlChanged,
    FailureKind.invalidResponse => l10n.cannotReadResponse,
    FailureKind.cancelled => l10n.requestCanceled,
    FailureKind.validation => l10n.checkEnteredContent,
    FailureKind.conflict => l10n.contentHasChanged,
    FailureKind.writeUncertain => l10n.actionResultUnconfirmed,
  };
  String get detail => _detail ?? switch (kind) {
    FailureKind.invisible => l10n.accountCannotAccessOrMoved,
    FailureKind.forbidden => l10n.checkRoleScopeAndPolicy,
    FailureKind.unauthenticated => l10n.reconnectThisAccount,
    FailureKind.network => l10n.checkNetworkUrlThenRefresh,
    FailureKind.tooLarge => l10n.textPreviewLimitMibLines,
    FailureKind.attachmentTooLarge => l10n.chooseFileWithin25Mib,
    FailureKind.rateLimited => l10n.gitlabLimitingRequestsRetry,
    FailureKind.server => l10n.contentKeptConfirmWrite,
    FailureKind.unsupported => l10n.binaryOrFeatureUnsupported,
    FailureKind.redirectBlocked => l10n.searchProjectOrUseBrowser,
    FailureKind.invalidResponse => l10n.serverDataUnparseable,
    FailureKind.cancelled => l10n.requestStoppedNoSideEffect,
    FailureKind.validation => l10n.nameBranchOrFieldsRejected,
    FailureKind.conflict => l10n.reloadLatestThenSubmit,
    FailureKind.writeUncertain => l10n.writeInterruptedCheckList,
  };
  @override
  String toString() => 'ApiFailure(${kind.name}, status: $status)';
}
ApiFailure safeFailure(Object error) => error is ApiFailure
    ? error : const ApiFailure(FailureKind.invalidResponse);
