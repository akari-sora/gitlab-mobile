/// The two native continuation kinds. A ticket never authorizes both.
enum AiContinuationKind { model, mutation }

/// Process-local identity; never persist a binding or restore it from history.
/// Identity is fixed. Only a confirmed normal release may clear its permit
/// through [rebindForForegroundApproval]; invalidation never grants that path.
final class AiExecutionRunBinding {
  AiExecutionRunBinding({
    required this.accountKey,
    required this.generation,
    required this.ownerApi,
    required this.conversationId,
    required this.runId,
    String? permitId,
  }) : _permitId = permitId;

  final String accountKey;
  final int generation;
  final Object ownerApi;
  final String conversationId;
  final String runId;
  String? _permitId;
  String? get permitId => _permitId;

  /// C-D5: the bridge calls this only after a successful normal release and
  /// only while this exact run waits solely for approval. It cannot attach a
  /// new permit or change the logical run. Old tickets retain their binding
  /// version through the permit value they captured when issued.
  bool rebindForForegroundApproval({required String releasedPermitId}) {
    if (_permitId == null || _permitId != releasedPermitId) return false;
    _permitId = null;
    return true;
  }
}

enum AiExecutionPauseReason {
  foregroundRequired,
  permitInactive,
  unavailable,
  runLimit,
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
  }) : _permitAtIssue = binding.permitId,
       _clock = clock,
       _isCurrent = isCurrent;

  static const ttl = Duration(milliseconds: 1000);
  final AiExecutionRunBinding binding;
  final AiContinuationKind kind;
  final String nonce;
  final String ticketId;
  final Duration requestStartedAt;
  final String? _permitAtIssue;
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
        this.binding.permitId != _permitAtIssue ||
        this.kind != kind ||
        nonce.isEmpty ||
        ticketId.isEmpty) {
      refuse(AiExecutionPauseReason.invalidTicket);
    }
    if (!_isCurrent()) {
      refuse(
        _permitAtIssue == null
            ? AiExecutionPauseReason.foregroundRequired
            : AiExecutionPauseReason.permitInactive,
      );
    }
    if (_permitAtIssue != null) {
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
