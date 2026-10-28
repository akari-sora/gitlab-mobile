// MR6c QA mailbox primitives. This library is not imported by production main.
// No account data, permits, tickets, approval values, or exception text belong
// in this mailbox. Device case drivers must supply independently verified
// evidence before emitting any successful result.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _maxSequence = 9007199254740991;
final _safeSession = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');
final _safeVariant = RegExp(r'^[A-Za-z0-9._:-]{1,64}$');
final _caseId = RegExp(r'^V(?:[1-9]|1[0-2])$');

bool qaMayStart({required bool enabled, required bool android}) =>
    enabled && android;

/// Only fixed codes are exported; parser input and exception text stay private.
final class QaProtocolException implements Exception {
  const QaProtocolException(this.code);
  final String code;
}

/// A content-free refusal of an unproved synthetic sandbox.
final class QaSandboxUnavailable implements Exception {
  const QaSandboxUnavailable();
}

Map<String, Object?> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.toSet().containsAll(keys)) {
    throw const QaProtocolException('invalid_shape');
  }
  return Map<String, Object?>.from(value);
}

final class QaCommand {
  const QaCommand._({
    required this.session,
    required this.caseId,
    required this.variant,
    required this.phase,
    required this.sequence,
  });

  final String session;
  final String caseId;
  final String variant;
  final String phase;
  final int sequence;

  static const keys = {
    'schema',
    'session',
    'case',
    'variant',
    'phase',
    'sequence',
  };

  static QaCommand parse(Object? value) {
    final map = _object(value, keys);
    final session = map['session'];
    final caseId = map['case'];
    final variant = map['variant'];
    final phase = map['phase'];
    final sequence = map['sequence'];
    if (map['schema'] is! int ||
        map['schema'] != 1 ||
        session is! String ||
        !_safeSession.hasMatch(session) ||
        caseId is! String ||
        !_caseId.hasMatch(caseId) ||
        variant is! String ||
        !_safeVariant.hasMatch(variant) ||
        (phase != 'prepare' && phase != 'recover') ||
        sequence is! int ||
        sequence < 1 ||
        sequence > _maxSequence) {
      throw const QaProtocolException('invalid_command');
    }
    return QaCommand._(
      session: session,
      caseId: caseId,
      variant: variant,
      phase: phase! as String,
      sequence: sequence,
    );
  }

  Map<String, Object> toJson() => {
    'schema': 1,
    'session': session,
    'case': caseId,
    'variant': variant,
    'phase': phase,
    'sequence': sequence,
  };
}

enum QaEventKind { ready, barrier, done, error }

enum QaOutcome { running, pass, fail, notRun }

enum QaReason {
  fixtureUnavailable,
  deadline,
  invalidCommand,
  ioError,
  unexpectedError,
}

final _digest = RegExp(r'^[0-9a-f]{64}$');

/// Case evidence has a fixed shape. Arbitrary objects and private strings
/// cannot be serialized through the QA mailbox.
sealed class QaCaseEvidence {
  const QaCaseEvidence();
  Map<String, Object> toJson();
  bool validFor(QaCommand command, QaEventKind kind, QaOutcome outcome);
}

bool _journalCase(QaCommand command) =>
    command.caseId == 'V9' &&
    const {
      'recents_swipe',
      'task_manager_stop',
      'settings_force_stop',
    }.contains(command.variant);

final class QaJournalBarrier extends QaCaseEvidence {
  const QaJournalBarrier({
    required this.executionDigest,
    required this.fileDigest,
    required this.dispatchAccepted,
    required this.journalFlushed,
    required this.nativeServiceActive,
    required this.modelCalls,
    required this.mutationCalls,
  });
  final String executionDigest;
  final String fileDigest;
  final bool dispatchAccepted;
  final bool journalFlushed;
  final bool nativeServiceActive;
  final int modelCalls;
  final int mutationCalls;

  @override
  bool validFor(QaCommand command, QaEventKind kind, QaOutcome outcome) =>
      _journalCase(command) &&
      command.phase == 'prepare' &&
      kind == QaEventKind.barrier &&
      outcome == QaOutcome.running &&
      _digest.hasMatch(executionDigest) &&
      _digest.hasMatch(fileDigest) &&
      dispatchAccepted &&
      journalFlushed &&
      nativeServiceActive &&
      modelCalls >= 0 &&
      mutationCalls >= 0;

  @override
  Map<String, Object> toJson() => {
    'execution_digest': executionDigest,
    'file_digest': fileDigest,
    'dispatch_accepted': dispatchAccepted,
    'journal_flushed': journalFlushed,
    'native_service_active': nativeServiceActive,
    'model_calls': modelCalls,
    'mutation_calls': mutationCalls,
  };
}

final class QaJournalRecovered extends QaCaseEvidence {
  const QaJournalRecovered({
    required this.executionDigest,
    required this.fileDigest,
    required this.uncertain,
    required this.isolated,
    required this.permitAbsent,
    required this.persistentAccountsVerified,
    required this.modelCalls,
    required this.mutationCalls,
  });
  final String executionDigest;
  final String fileDigest;
  final bool uncertain;
  final bool isolated;
  final bool permitAbsent;
  final bool persistentAccountsVerified;
  final int modelCalls;
  final int mutationCalls;

  @override
  bool validFor(QaCommand command, QaEventKind kind, QaOutcome outcome) =>
      _journalCase(command) &&
      command.phase == 'recover' &&
      kind == QaEventKind.done &&
      outcome == QaOutcome.pass &&
      _digest.hasMatch(executionDigest) &&
      _digest.hasMatch(fileDigest) &&
      uncertain &&
      isolated &&
      permitAbsent &&
      persistentAccountsVerified &&
      modelCalls == 0 &&
      mutationCalls == 0;

  @override
  Map<String, Object> toJson() => {
    'execution_digest': executionDigest,
    'file_digest': fileDigest,
    'uncertain': uncertain,
    'isolated': isolated,
    'permit_absent': permitAbsent,
    'persistent_accounts_verified': persistentAccountsVerified,
    'model_calls': modelCalls,
    'mutation_calls': mutationCalls,
  };
}

extension on QaOutcome {
  String get wire => switch (this) {
    QaOutcome.running => 'RUNNING',
    QaOutcome.pass => 'PASS',
    QaOutcome.fail => 'FAIL',
    QaOutcome.notRun => 'NOT_RUN',
  };
}

extension on QaReason {
  String get wire => switch (this) {
    QaReason.fixtureUnavailable => 'fixture_unavailable',
    QaReason.deadline => 'deadline',
    QaReason.invalidCommand => 'invalid_command',
    QaReason.ioError => 'io_error',
    QaReason.unexpectedError => 'unexpected_error',
  };
}

/// Events deliberately accept no arbitrary string, account object, permit or
/// exception. Add case-specific typed fields only with the real case driver.
final class QaEvent {
  QaEvent(this.command, this.kind, this.outcome, {this.reason, this.evidence}) {
    final valid = evidence != null
        ? reason == null && evidence!.validFor(command, kind, outcome)
        : switch ((kind, outcome)) {
            (QaEventKind.ready || QaEventKind.barrier, QaOutcome.running) =>
              reason == null,
            (QaEventKind.done, QaOutcome.notRun) =>
              reason == QaReason.fixtureUnavailable,
            (QaEventKind.error, QaOutcome.fail) => reason != null,
            _ => false,
          };
    // In particular, a transport marker cannot stand in for a case PASS.
    if (!valid) throw const QaProtocolException('invalid_event');
  }

  final QaCommand command;
  final QaEventKind kind;
  final QaOutcome outcome;
  final QaReason? reason;
  final QaCaseEvidence? evidence;

  Map<String, Object> toJson() => {
    ...command.toJson(),
    'event': kind.name,
    'outcome': outcome.wire,
    'evidence':
        evidence?.toJson() ??
        <String, Object>{if (reason != null) 'reason': reason!.wire},
  };

  /// An ack echoes exactly the command envelope and the event kind.
  bool isAcknowledgedBy(Object? value) {
    try {
      final map = _object(value, {...QaCommand.keys, 'event'});
      final event = map.remove('event');
      final ack = QaCommand.parse(map);
      return event == kind.name &&
          ack.session == command.session &&
          ack.caseId == command.caseId &&
          ack.variant == command.variant &&
          ack.phase == command.phase &&
          ack.sequence == command.sequence;
    } on QaProtocolException {
      return false;
    }
  }
}

/// Classify by type, never exception text. Unknown failures must not claim I/O.
QaEvent qaFailureEvent(QaCommand command, Object error) => QaEvent(
  command,
  QaEventKind.error,
  QaOutcome.fail,
  reason: switch (error) {
    TimeoutException() => QaReason.deadline,
    IOException() => QaReason.ioError,
    _ => QaReason.unexpectedError,
  },
);

/// Refusal before prepare is NOT_RUN; losing recovery evidence after an
/// accepted prepare/termination is a failure of an attempted case.
QaEvent qaPreflightRejected(QaCommand command, Object error) =>
    command.phase == 'prepare' && error is QaSandboxUnavailable
    ? QaEvent(
        command,
        QaEventKind.done,
        QaOutcome.notRun,
        reason: QaReason.fixtureUnavailable,
      )
    : qaFailureEvent(command, error);

/// State contains only session/sequence and the case-variant-phase identifiers.
/// Switching session requires scoped removal of the old QA mailbox after the
/// host verifies the sandbox is synthetic; this never clears app data.
final class QaSequenceState {
  const QaSequenceState(this.session, this.sequence, this.seen);
  final String session;
  final int sequence;
  final List<String> seen;

  static String _key(QaCommand command, [String? phase]) =>
      '${command.caseId}|${command.variant}|${phase ?? command.phase}';

  static QaSequenceState? parse(Object? value) {
    if (value == null) return null;
    final map = _object(value, {'schema', 'session', 'sequence', 'seen'});
    final session = map['session'];
    final sequence = map['sequence'];
    final seen = map['seen'];
    if (map['schema'] is! int ||
        map['schema'] != 1 ||
        session is! String ||
        !_safeSession.hasMatch(session) ||
        sequence is! int ||
        sequence < 1 ||
        sequence > _maxSequence ||
        seen is! List<Object?> ||
        seen.isEmpty ||
        seen.length > 128) {
      throw const QaProtocolException('invalid_state');
    }
    final keys = <String>[];
    for (final entry in seen) {
      if (entry is! String) throw const QaProtocolException('invalid_state');
      final parts = entry.split('|');
      if (parts.length != 3 ||
          !_caseId.hasMatch(parts[0]) ||
          !_safeVariant.hasMatch(parts[1]) ||
          (parts[2] != 'prepare' && parts[2] != 'recover') ||
          keys.contains(entry)) {
        throw const QaProtocolException('invalid_state');
      }
      if (parts[2] == 'recover' &&
          !keys.contains('${parts[0]}|${parts[1]}|prepare')) {
        throw const QaProtocolException('invalid_state');
      }
      keys.add(entry);
    }
    return QaSequenceState(session, sequence, List.unmodifiable(keys));
  }

  static QaSequenceState accept(QaSequenceState? previous, QaCommand command) {
    if (previous != null && previous.session != command.session) {
      throw const QaProtocolException('session_mismatch');
    }
    if (previous != null && command.sequence <= previous.sequence) {
      throw const QaProtocolException('replayed_command');
    }
    final seen = previous?.seen ?? <String>[];
    if (seen.length >= 128 || seen.contains(_key(command))) {
      throw const QaProtocolException('replayed_phase');
    }
    if (command.phase == 'recover' &&
        !seen.contains(_key(command, 'prepare'))) {
      throw const QaProtocolException('missing_prepare');
    }
    return QaSequenceState(
      command.session,
      command.sequence,
      List.unmodifiable([...seen, _key(command)]),
    );
  }

  Map<String, Object> toJson() => {
    'schema': 1,
    'session': session,
    'sequence': sequence,
    'seen': seen,
  };
}

/// Isolated file operations under files/mr6c_qa. No account loading or network.
final class QaMailbox {
  QaMailbox(this.directory);
  final Directory directory;

  Future<Object?> _read(String name) async {
    final file = File('${directory.path}/$name');
    if (!await file.exists()) return null;
    // Limit parsing and prevent accidental export of arbitrary app data.
    if (await file.length() > 16384) {
      throw const QaProtocolException('invalid_shape');
    }
    try {
      return jsonDecode(await file.readAsString());
    } on FormatException {
      throw const QaProtocolException('invalid_shape');
    }
  }

  Future<void> _write(String name, Map<String, Object> data) async {
    await directory.create(recursive: true);
    final temp = File('${directory.path}/$name.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    await temp.rename('${directory.path}/$name');
  }

  Future<QaCommand> acceptCommand() async {
    final command = QaCommand.parse(await _read('command.json'));
    final previous = QaSequenceState.parse(await _read('state.json'));
    final next = QaSequenceState.accept(previous, command);
    // Persist before publishing ready so a crash cannot replay a command.
    await _write('state.json', next.toJson());
    return command;
  }

  Future<void> publish(QaEvent event) => _write('event.json', event.toJson());

  Future<bool> acknowledged(QaEvent event) async {
    try {
      return event.isAcknowledgedBy(await _read('ack.json'));
    } on QaProtocolException {
      return false;
    }
  }

  Future<void> publishInvalidCommand() => _write('error.json', {
    'schema': 1,
    'event': 'error',
    'outcome': 'FAIL',
    'reason': 'invalid_command',
  });
}
