/// The two native continuation kinds. A ticket never authorizes both.
enum AiContinuationKind { model, mutation }

/// Process-local identity; never persist a binding or restore it from history.
/// A released/invalidated permit must not be replaced on an existing binding.
final class AiExecutionRunBinding {
  const AiExecutionRunBinding({
    required this.accountKey,
    required this.generation,
    required this.ownerApi,
    required this.conversationId,
    required this.runId,
    this.permitId,
  });

  final String accountKey;
  final int generation;
  final Object ownerApi;
  final String conversationId;
  final String runId;
  final String? permitId;
}

enum AiExecutionPauseReason {
  foregroundRequired,
  permitInactive,
  unavailable,
  timeout,
  ticketExpired,
  invalidTicket,
  runChanged,
  nonceReplayed,
  nonceCapacity,
}

/// Safe structured metadata, without credentials, native IDs or channel text.
final class AiExecutionPause {
  const AiExecutionPause(this.reason, {this.kind});

  final AiExecutionPauseReason reason;
  final AiContinuationKind? kind;
}

final class AiExecutionPaused implements Exception {
  const AiExecutionPaused(this.pause);
  final AiExecutionPause pause;
}

typedef AiExecutionClock = Duration Function();

/// Bridge implementations validate the v1 reply, fresh nonce, current owner
/// and invalidation latch before returning a ticket. Eligibility is only a
/// preparation predicate: every bound-permit send must still acquire a ticket,
/// including in the foreground. No Flutter/channel dependency belongs here.
abstract interface class AiExecutionGate {
  AiExecutionRunBinding get binding;
  bool get executionEligible;
  Future<AiExecutionTicket> acquire(AiContinuationKind kind);
}

/// Native permit tickets have a total lifetime starting BEFORE acquire's
/// asynchronous work, on one Dart monotonic clock. The bridge must pass that
/// original request time, never the reply time. Local foreground tickets have
/// no total TTL. A failed attempt also burns the ticket permanently.
final class AiExecutionTicket {
  AiExecutionTicket({
    required this.binding,
    required this.kind,
    required this.nonce,
    required this.ticketId,
    required this.requestStartedAt,
    required AiExecutionClock clock,
    required bool Function() isCurrent,
  }) : _clock = clock,
       _isCurrent = isCurrent;

  static const ttl = Duration(milliseconds: 1000);
  final AiExecutionRunBinding binding;
  final AiContinuationKind kind;
  final String nonce;
  final String ticketId;
  final Duration requestStartedAt;
  final AiExecutionClock _clock;
  final bool Function() _isCurrent;
  var _spent = false;

  void discard() => _spent = true;

  /// Synchronous final authorization. There must be no await before invoking
  /// the one model request or mutation this attempt authorizes.
  void consumeOnce({
    required AiExecutionRunBinding binding,
    required AiContinuationKind kind,
  }) {
    void refuse(AiExecutionPauseReason reason) =>
        throw AiExecutionPaused(AiExecutionPause(reason, kind: kind));

    final spent = _spent;
    _spent = true;
    if (spent ||
        !identical(this.binding, binding) ||
        this.kind != kind ||
        nonce.isEmpty ||
        ticketId.isEmpty) {
      refuse(AiExecutionPauseReason.invalidTicket);
    }
    if (!_isCurrent()) {
      refuse(
        this.binding.permitId == null
            ? AiExecutionPauseReason.foregroundRequired
            : AiExecutionPauseReason.permitInactive,
      );
    }
    if (this.binding.permitId != null) {
      final elapsed = _clock() - requestStartedAt;
      if (elapsed < Duration.zero || elapsed >= ttl) {
        refuse(AiExecutionPauseReason.ticketExpired);
      }
    }
  }
}

/// Unsupported platforms and runs without a native permit use actual
/// visibility at BOTH preparation and consumption. No native call is needed.
final class ForegroundAiExecutionGate implements AiExecutionGate {
  ForegroundAiExecutionGate({
    required bool Function() appInForeground,
    AiExecutionClock? clock,
  }) : _appInForeground = appInForeground,
       _clock = clock ?? _monotonic;

  final bool Function() _appInForeground;
  final AiExecutionClock _clock;
  var _nonce = 0;
  static final _watch = Stopwatch()..start();
  static Duration _monotonic() => _watch.elapsed;

  @override
  final binding = AiExecutionRunBinding(
    accountKey: '',
    generation: 0,
    ownerApi: Object(),
    conversationId: '',
    runId: '',
  );

  @override
  bool get executionEligible => _appInForeground();

  @override
  Future<AiExecutionTicket> acquire(AiContinuationKind kind) async {
    if (!executionEligible) {
      throw AiExecutionPaused(
        AiExecutionPause(AiExecutionPauseReason.foregroundRequired, kind: kind),
      );
    }
    final nonce = '${++_nonce}';
    return AiExecutionTicket(
      binding: binding,
      kind: kind,
      nonce: nonce,
      ticketId: nonce,
      requestStartedAt: _clock(),
      clock: _clock,
      isCurrent: () => executionEligible,
    );
  }
}
