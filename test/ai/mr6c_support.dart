import 'dart:async';

import 'package:gitlab_mobile/core/ai/execution_gate.dart';

/// A monotonic clock controlled by the test; advancing does not wait in real time.
final class Mr6cClock {
  Duration elapsed = Duration.zero;

  Duration now() => elapsed;

  void advance(Duration duration) {
    if (duration.isNegative) throw ArgumentError.value(duration, 'duration');
    elapsed += duration;
  }
}

/// A one-use barrier that signals entry before waiting for release.
final class Mr6cBarrier {
  final Completer<void> _entered = Completer<void>();
  final Completer<void> _released = Completer<void>();

  Future<void> get entered => _entered.future;

  Future<void> wait() async {
    if (!_entered.isCompleted) _entered.complete();
    await _released.future;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

/// Fake bridge with separate native and observed invalidation states.
/// A ticket issued before native revocation may still arrive if its callback
/// was lost; a delivered invalidation or changed binding always fences it.
final class Mr6cExecutionGate implements AiExecutionGate {
  Mr6cExecutionGate({required this.binding, required this.clock});

  @override
  AiExecutionRunBinding binding;
  final Mr6cClock clock;
  bool nativeActive = true;
  bool invalidated = false;
  bool foreground = false;
  Future<void> Function(AiContinuationKind kind)? onAcquire;
  AiExecutionPauseReason? refuse;
  AiExecutionTicket? reuseTicket;
  final List<AiContinuationKind> acquisitions = [];
  final List<AiExecutionTicket> tickets = [];
  final List<String> events = [];
  int _sequence = 0;

  @override
  bool get executionEligible =>
      !invalidated && (binding.permitId != null || foreground);

  @override
  Future<AiExecutionTicket> acquire(AiContinuationKind kind) async {
    final captured = binding;
    final startedAt = clock.now();
    final nonce = '${++_sequence}';
    acquisitions.add(kind);
    events.add('acquire:${kind.name}');
    final reason =
        refuse ??
        (invalidated || (captured.permitId != null && !nativeActive)
            ? AiExecutionPauseReason.permitInactive
            : captured.permitId == null && !foreground
            ? AiExecutionPauseReason.foregroundRequired
            : null);
    if (reason != null) {
      throw AiExecutionPaused(AiExecutionPause(reason, kind: kind));
    }

    final ticket =
        reuseTicket ??
        AiExecutionTicket(
          binding: captured,
          kind: kind,
          nonce: nonce,
          ticketId: nonce,
          requestStartedAt: startedAt,
          clock: clock.now,
          isCurrent: () {
            // This records reaching consume's currentness check; an expired
            // ticket can still be refused immediately after this observation.
            events.add('consume:${kind.name}');
            return identical(binding, captured) &&
                !invalidated &&
                (captured.permitId != null || foreground);
          },
        );
    tickets.add(ticket);
    try {
      await onAcquire?.call(kind);
    } on Object {
      ticket.discard();
      rethrow;
    }
    return ticket;
  }
}
