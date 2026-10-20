import 'dart:io' show HttpDate, HttpException;

import '../failure.dart';
import '../../l10n/l10n.dart';

/// Only allowlisted status metadata belongs in a failure, never provider bodies.
enum AiFailureKind {
  unauthenticated,
  forbidden,
  notFound,
  rateLimited,
  quotaExhausted,
  network,
  server,
  requestTooLarge,
  responseTooLarge,
  invalidResponse,
  unsupported,
  redirectBlocked,
  cancelled,
  interrupted,
  timeout,
  contextTooLong,
  contentFilter,
  refusal,
  policyBlocked,
}

final class AiFailure implements Exception, UserFacingFailure {
  const AiFailure(this.kind, {this.status, this.retryAt});

  final AiFailureKind kind;
  final int? status;
  final DateTime? retryAt;

  static AiFailure fromStatus(int status, {String? retryAfter, DateTime? now}) {
    final retryAt = parseRetryAfter(retryAfter, now: now);
    final kind = switch (status) {
      401 => AiFailureKind.unauthenticated,
      403 => AiFailureKind.forbidden,
      404 => AiFailureKind.notFound,
      413 => AiFailureKind.requestTooLarge,
      429 =>
        retryAfter == null
            ? AiFailureKind.quotaExhausted
            : AiFailureKind.rateLimited,
      >= 300 && < 400 => AiFailureKind.redirectBlocked,
      >= 500 => AiFailureKind.server,
      _ => AiFailureKind.invalidResponse,
    };
    return AiFailure(
      kind,
      status: status,
      retryAt: status == 429 ? retryAt : null,
    );
  }

  static DateTime? parseRetryAfter(String? value, {DateTime? now}) {
    if (value == null) return null;
    final text = value.trim();
    final seconds = int.tryParse(text);
    final clock = now ?? DateTime.now();
    if (seconds != null) {
      if (seconds < 0) return null;
      try {
        return clock.add(Duration(seconds: seconds > 3600 ? 3600 : seconds));
      } on ArgumentError {
        return null;
      }
    }
    try {
      final parsed = HttpDate.parse(text);
      final cap = clock.add(const Duration(hours: 1));
      return parsed.isAfter(cap) ? cap : parsed;
    } on HttpException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  String get title => switch (kind) {
    AiFailureKind.unauthenticated => l10n.aiUnauthenticatedTitle,
    AiFailureKind.forbidden => l10n.aiForbiddenTitle,
    AiFailureKind.notFound => l10n.aiNotFoundTitle,
    AiFailureKind.rateLimited => l10n.aiRateLimitedTitle,
    AiFailureKind.quotaExhausted => l10n.aiQuotaExhaustedTitle,
    AiFailureKind.network => l10n.aiNetworkTitle,
    AiFailureKind.server => l10n.aiServerTitle,
    AiFailureKind.requestTooLarge => l10n.aiRequestTooLargeTitle,
    AiFailureKind.responseTooLarge => l10n.aiResponseTooLargeTitle,
    AiFailureKind.invalidResponse => l10n.aiInvalidResponseTitle,
    AiFailureKind.unsupported => l10n.aiUnsupportedTitle,
    AiFailureKind.redirectBlocked => l10n.aiRedirectBlockedTitle,
    AiFailureKind.cancelled => l10n.aiCancelledTitle,
    AiFailureKind.interrupted => l10n.aiInterruptedTitle,
    AiFailureKind.timeout => l10n.aiTimeoutTitle,
    AiFailureKind.contextTooLong => l10n.aiContextTooLongTitle,
    AiFailureKind.contentFilter => l10n.aiContentFilterTitle,
    AiFailureKind.refusal => l10n.aiRefusalTitle,
    AiFailureKind.policyBlocked => l10n.aiPolicyBlockedTitle,
  };

  @override
  String get detail => switch (kind) {
    AiFailureKind.unauthenticated => l10n.aiUnauthenticatedDetail,
    AiFailureKind.forbidden => l10n.aiForbiddenDetail,
    AiFailureKind.notFound => l10n.aiNotFoundDetail,
    AiFailureKind.rateLimited => l10n.aiRateLimitedDetail,
    AiFailureKind.quotaExhausted => l10n.aiQuotaExhaustedDetail,
    AiFailureKind.network => l10n.aiNetworkDetail,
    AiFailureKind.server => l10n.aiServerDetail,
    AiFailureKind.requestTooLarge =>
      status == 413
          ? l10n.aiContextTooLongDetail
          : l10n.aiRequestTooLargeDetail,
    AiFailureKind.responseTooLarge => l10n.aiResponseTooLargeDetail,
    AiFailureKind.invalidResponse => l10n.aiInvalidResponseDetail,
    AiFailureKind.unsupported => l10n.aiUnsupportedDetail,
    AiFailureKind.redirectBlocked => l10n.aiRedirectBlockedDetail,
    AiFailureKind.cancelled => l10n.aiCancelledDetail,
    AiFailureKind.interrupted => l10n.aiInterruptedDetail,
    AiFailureKind.timeout => l10n.aiTimeoutDetail,
    AiFailureKind.contextTooLong => l10n.aiContextTooLongDetail,
    AiFailureKind.contentFilter => l10n.aiContentFilterDetail,
    AiFailureKind.refusal => l10n.aiRefusalDetail,
    AiFailureKind.policyBlocked => l10n.aiPolicyBlockedDetail,
  };

  @override
  String toString() => 'AiFailure(${kind.name}, status: $status)';
}
