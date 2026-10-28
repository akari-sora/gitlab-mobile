import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/ai/execution_gate.dart';
import '../../l10n/l10n.dart';

// MethodChannel handlers are installed per messenger and channel name. Several
// account/controller owners can coexist briefly during a tree transition.
final class _ExecutionChannelListeners {
  _ExecutionChannelListeners(this.channel, this.messenger);

  final MethodChannel channel;
  final BinaryMessenger messenger;
  final Set<AiBackgroundExecution> owners = <AiBackgroundExecution>{};
  Future<void> serialTail = Future<void>.value();
  int pendingOperations = 0;
  int immediateCleanups = 0;
  int releasePending = 0;
  AiBackgroundExecution? leaseOwner;
  String? leasePermit;
  bool orphan = false;
  int stopRevision = 0;
  int stopsInFlight = 0;
  // Correlation outlives permit authorization, but only until the next native
  // lifecycle on this messenger/channel, regardless of which owner starts it.
  ({AiBackgroundExecution owner, String startRequestId, String? permitId})?
  stopLifecycle;

  void retireIfIdle() {
    if (owners.isNotEmpty ||
        pendingOperations != 0 ||
        immediateCleanups != 0 ||
        leaseOwner != null ||
        orphan ||
        stopsInFlight != 0) {
      return;
    }
    final channels = AiBackgroundExecution._listeners[messenger];
    if (!identical(channels?[channel.name], this)) return;
    channel.setMethodCallHandler(null);
    channels!.remove(channel.name);
    if (channels.isEmpty) AiBackgroundExecution._listeners.remove(messenger);
  }

  Future<void> dispatch(MethodCall call) async {
    if (call.method != 'permitInvalidated') return;
    final args = call.arguments;
    if (args is! Map<Object?, Object?> ||
        (args.length != 3 && args.length != 4) ||
        args['version'] is! int ||
        args['version'] != 1 ||
        !AiBackgroundExecution._validId(args['permitId']) ||
        (args.length == 4 &&
            !AiBackgroundExecution._validId(args['startRequestId'])) ||
        !const {
          'user_stop',
          'timeout',
          'synthetic_timeout',
          'service_destroyed',
          'activity_destroyed',
          'start_failed',
          'security_exception',
          'start_denied',
          'notification_failed',
        }.contains(args['reason'])) {
      return;
    }
    final permit = args['permitId']! as String;
    final startRequest = args['startRequestId'] as String?;
    // Consume once at the channel boundary before any owner/registry is
    // notified. Retained gate bindings cannot promote a superseded callback.
    final stoppedOwner = consumeStop(
      permitId: permit,
      startRequestId: startRequest,
    );
    for (final owner in owners.toList(growable: false)) {
      owner._handleInvalidation(
        permit,
        startRequest,
        args['reason']! as String,
      );
    }
    if (args['reason'] == 'user_stop' && stoppedOwner != null) {
      emitStop(stoppedOwner);
    }
  }

  AiBackgroundExecution? consumeStop({
    String? permitId,
    String? startRequestId,
  }) {
    final lifecycle = stopLifecycle;
    if (lifecycle == null) return null;
    final matchingPermit = permitId != null && lifecycle.permitId == permitId;
    final matchingStart =
        lifecycle.permitId == null &&
        startRequestId != null &&
        lifecycle.startRequestId == startRequestId;
    if (!matchingPermit && !matchingStart) return null;
    stopLifecycle = null;
    return lifecycle.owner;
  }

  void emitStop(AiBackgroundExecution lifecycleOwner) {
    for (final owner in owners.toList(growable: false)) {
      if (owner._current &&
          owner.accountKey == lifecycleOwner.accountKey &&
          owner.generation == lifecycleOwner.generation &&
          identical(owner.ownerApi, lifecycleOwner.ownerApi)) {
        owner._stopEvents.add(null);
      }
    }
  }
}

/// Execution state for presentation; it carries no native identifiers.
enum AiBackgroundExecutionStatus {
  foregroundOnly,
  starting,
  active,
  released,
  invalidated,
  unavailable,
}

/// The result of one user-initiated service-start attempt. It contains no
/// platform exception text or native identifiers.
enum AiBackgroundStartDisposition {
  active,
  foregroundOnly,
  invalidated,
  unavailable,
}

/// Whether the native service has any unconfirmed cleanup in progress.
enum AiBackgroundCleanupConfirmation { pending, confirmed }

enum AiBackgroundStartFailure {
  unsupported,
  foregroundRequired,
  startDenied,
  securityException,
  channelRefused,
  channelUnavailable,
  cleanupFailed,
  timeout,
  runChanged,
}

final class AiBackgroundStartResult {
  const AiBackgroundStartResult(this.disposition, {this.failure});

  final AiBackgroundStartDisposition disposition;
  final AiBackgroundStartFailure? failure;
}

/// A task movement result, without platform exception text or run authority.
enum AiTaskBackResult {
  moved,
  notMoved,
  notEligible,
  unsupported,
  foregroundRequired,
  unavailable,
  failed,
}

/// One native service owner for an account, API and session generation.
/// Native permits only prepare work: every continuation still obtains a ticket.
final class AiBackgroundExecution extends ChangeNotifier
    with WidgetsBindingObserver {
  AiBackgroundExecution({
    required this.backgroundEnabled,
    required this.accountKey,
    required this.generation,
    required this.ownerApi,
    required bool Function() isCurrent,
    required bool Function() appInForeground,
    MethodChannel? channel,
    AiExecutionClock? clock,
  }) : _isCurrent = isCurrent,
       _appInForeground = appInForeground,
       _nativeSupported = channel != null || (!kIsWeb && Platform.isAndroid),
       _channel = channel ?? const MethodChannel('io.gitlabmobile/agent_runs'),
       _clock = clock ?? _monotonic {
    _attach();
  }

  /// Fixed by production wiring; tests explicitly opt into native execution.
  final bool backgroundEnabled;
  final String accountKey;
  final int generation;
  final Object ownerApi;
  final bool Function() _isCurrent;
  final bool Function() _appInForeground;
  final bool _nativeSupported;
  final MethodChannel _channel;
  final AiExecutionClock _clock;
  static final Stopwatch _watch = Stopwatch()..start();
  static Duration _monotonic() => _watch.elapsed;
  static int _sequence = 0;
  static const int _maxSequence = 9007199254740991;
  static final Random _random = Random.secure();
  static final Map<BinaryMessenger, Map<String, _ExecutionChannelListeners>>
  _listeners =
      HashMap<
        BinaryMessenger,
        Map<String, _ExecutionChannelListeners>
      >.identity();
  BinaryMessenger? _attachedMessenger;
  _ExecutionChannelListeners? _shared;
  WidgetsBinding? _widgetsBinding;
  static const Duration _interval = Duration(milliseconds: 1000);

  final Set<AiBackgroundRunGate> _gates = <AiBackgroundRunGate>{};
  final Set<String> _invalidatedPermits = <String>{};
  Future<void> _localSerialTail = Future<void>.value();
  Future<bool>? _seedFuture;
  bool _seeded = false;
  bool _disposed = false;
  bool _localOrphan = false;
  int _localStopRevision = 0;
  int _localStopsInFlight = 0;
  int _localImmediateCleanups = 0;
  int _localReleasePending = 0;
  String? _permit;
  Timer? _progressTimer;
  Timer? _languageTimer;
  Duration? _lastProgressAt;
  (int, int, String, String, String)? _lastProgress;
  final _stopEvents = StreamController<void>.broadcast(sync: true);
  bool _progressInFlight = false;
  AiBackgroundExecutionStatus _status =
      AiBackgroundExecutionStatus.foregroundOnly;

  AiBackgroundExecutionStatus get status => _status;

  /// User stop requests reach the account registry without carrying content.
  Stream<void> get stopEvents => _stopEvents.stream;
  int get serviceWorkCount => _gates.where((gate) => gate._active).length;
  int get backProtectedCount =>
      _gates.where((gate) => gate._backProtected).length;

  bool get _current => !_disposed && _isCurrent();
  AiBackgroundCleanupConfirmation get cleanupConfirmation =>
      _orphan ||
          _stopsInFlight != 0 ||
          _immediateCleanups != 0 ||
          _releasePending != 0
      ? AiBackgroundCleanupConfirmation.pending
      : AiBackgroundCleanupConfirmation.confirmed;

  void _notifyCleanupChange(AiBackgroundCleanupConfirmation previous) {
    if (previous == cleanupConfirmation) return;
    for (final owner in _shared?.owners.toList(growable: false) ?? [this]) {
      if (!owner._disposed) owner.notifyListeners();
    }
  }

  bool get _orphan => _shared?.orphan ?? _localOrphan;
  set _orphan(bool value) {
    final previous = cleanupConfirmation;
    if (_shared case final shared?) {
      shared.orphan = value;
    } else {
      _localOrphan = value;
    }
    _notifyCleanupChange(previous);
  }

  int get _stopRevision => _shared?.stopRevision ?? _localStopRevision;
  set _stopRevision(int value) {
    if (_shared case final shared?) {
      shared.stopRevision = value;
    } else {
      _localStopRevision = value;
    }
  }

  int get _stopsInFlight => _shared?.stopsInFlight ?? _localStopsInFlight;
  set _stopsInFlight(int value) {
    final previous = cleanupConfirmation;
    if (_shared case final shared?) {
      shared.stopsInFlight = value;
    } else {
      _localStopsInFlight = value;
    }
    _notifyCleanupChange(previous);
  }

  int get _immediateCleanups =>
      _shared?.immediateCleanups ?? _localImmediateCleanups;
  set _immediateCleanups(int value) {
    final previous = cleanupConfirmation;
    if (_shared case final shared?) {
      shared.immediateCleanups = value;
    } else {
      _localImmediateCleanups = value;
    }
    _notifyCleanupChange(previous);
  }

  int get _releasePending => _shared?.releasePending ?? _localReleasePending;
  set _releasePending(int value) {
    final previous = cleanupConfirmation;
    if (_shared case final shared?) {
      shared.releasePending = value;
    } else {
      _localReleasePending = value;
    }
    _notifyCleanupChange(previous);
  }

  AiBackgroundRunGate createGate({
    required String Function() conversationId,
    required bool Function() isCurrent,
    bool Function()? appInForeground,
  }) {
    final gate = AiBackgroundRunGate._(
      this,
      conversationId,
      isCurrent,
      appInForeground ?? _appInForeground,
    );
    _gates.add(gate);
    return gate;
  }

  static String _newId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool _validId(Object? id) =>
      id is String &&
      id.isNotEmpty &&
      id.length <= 128 &&
      RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(id);

  static bool _validTicketId(Object? id) =>
      id is String &&
      RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
      ).hasMatch(id);

  int _nextSequence() {
    if (_sequence >= _maxSequence) {
      throw StateError('Channel sequence exhausted');
    }
    return ++_sequence;
  }

  Map<Object?, Object?>? _reply(Object? value) {
    if (value is! Map<Object?, Object?> ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['status'] is! String) {
      return null;
    }
    return value;
  }

  Future<Map<Object?, Object?>?> _invoke(
    String method,
    Map<String, Object> args,
  ) async {
    try {
      return _reply(
        await _channel.invokeMethod<Object?>(method, args).timeout(_interval),
      );
    } on Object {
      return null;
    }
  }

  /// A non-UUID permit can never match a native-generated UUID. Its rejected
  /// progress request advances the sequence without changing work or the task.
  /// A peer that still answers this probe with the historical
  /// `unsupported` / `not_implemented` handshake also started no work and
  /// moved no task. Treating that reply as a missing channel skips the start,
  /// so a timed-out or cleanup-failed run never enters scoped cleanup or
  /// explicit continuation. A stale reply supplies the process high-water
  /// mark before the real call.
  Future<bool> _seed() {
    if (_seeded) return Future<bool>.value(true);
    if (!_attach()) return Future<bool>.value(false);
    return _seedFuture ??= () async {
      try {
        final reply = await _invoke('updateProgress', {
          'opSeq': _nextSequence(),
          'permitId': 'sequence-probe',
          'workCount': 1,
          'step': 0,
        });
        if ((reply?['status'] == 'rejected' &&
                reply?['reason'] == 'permit_inactive') ||
            (reply?['status'] == 'unsupported' &&
                reply?['reason'] == 'not_implemented')) {
          _seeded = true;
          return true;
        }
        if (reply?['status'] == 'rejected' &&
            reply?['reason'] == 'stale_operation') {
          final floor = reply?['opSeqFloor'];
          if (floor is int && floor >= 1 && floor < _maxSequence) {
            if (floor > _sequence) _sequence = floor;
            _seeded = true;
            return true;
          }
        }
        return false;
      } finally {
        _seedFuture = null;
      }
    }();
  }

  bool _attach() {
    try {
      if (_widgetsBinding == null) {
        final binding = WidgetsBinding.instance;
        _widgetsBinding = binding;
        binding.addObserver(this);
      }
      if (!_nativeSupported) return false;
      if (_shared != null) return true;
      final messenger = _channel.binaryMessenger;
      final channels = _listeners.putIfAbsent(messenger, () => {});
      var listeners = channels[_channel.name];
      if (listeners == null) {
        listeners = _ExecutionChannelListeners(_channel, messenger);
        _channel.setMethodCallHandler(listeners.dispatch);
        channels[_channel.name] = listeners;
      }
      final previousShared =
          listeners.orphan ||
              listeners.stopsInFlight != 0 ||
              listeners.immediateCleanups != 0 ||
              listeners.releasePending != 0
          ? AiBackgroundCleanupConfirmation.pending
          : AiBackgroundCleanupConfirmation.confirmed;
      listeners.orphan = listeners.orphan || _localOrphan;
      listeners.stopRevision += _localStopRevision;
      listeners.stopsInFlight += _localStopsInFlight;
      listeners.immediateCleanups += _localImmediateCleanups;
      listeners.releasePending += _localReleasePending;
      _localOrphan = false;
      _localStopRevision = 0;
      _localStopsInFlight = 0;
      _localImmediateCleanups = 0;
      _localReleasePending = 0;
      listeners.owners.add(this);
      _shared = listeners;
      _notifyCleanupChange(previousShared);
      _attachedMessenger = messenger;
      return true;
    } on Object {
      // A plain Dart fixture may not have a Flutter binding. It retains the
      // foreground-only gate until one exists; never initialize one here.
      return false;
    }
  }

  Future<void> _serial(Future<void> Function() action) {
    final shared = _shared;
    if (shared != null) shared.pendingOperations++;
    final tail = shared?.serialTail ?? _localSerialTail;
    final operation = tail.then((_) async {
      try {
        await action();
      } finally {
        if (shared != null) {
          shared.pendingOperations--;
          shared.retireIfIdle();
        }
      }
    });
    final next = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace stack) {},
    );
    if (shared != null) {
      shared.serialTail = next;
    } else {
      _localSerialTail = next;
    }
    return operation;
  }

  void _setStatus(AiBackgroundExecutionStatus value) {
    if (_status == value || _disposed) return;
    _status = value;
    notifyListeners();
  }

  Future<AiBackgroundStartResult> startRuns(AiBackgroundRunGate gate) =>
      gate.beginRun(runId: _newId());

  /// Called after the shell has consumed detail/tab back and checked app lock.
  /// Works without an active service, including approval and paused work.
  Future<AiTaskBackResult> moveTaskToBack({
    required bool Function() isBackEligible,
  }) async {
    if (!_nativeSupported) return AiTaskBackResult.unsupported;
    if (!_current) return AiTaskBackResult.unavailable;
    if (!_appInForeground()) return AiTaskBackResult.foregroundRequired;
    if (!isBackEligible()) return AiTaskBackResult.notEligible;
    if (!_attach()) return AiTaskBackResult.unavailable;
    var result = AiTaskBackResult.unavailable;
    await _serial(() async {
      if (!_current) return;
      if (!_appInForeground()) {
        result = AiTaskBackResult.foregroundRequired;
        return;
      }
      if (!isBackEligible()) {
        result = AiTaskBackResult.notEligible;
        return;
      }
      if (_sequence >= _maxSequence) return;
      if (!await _seed() || !_current || _sequence >= _maxSequence) return;
      if (!_appInForeground()) {
        result = AiTaskBackResult.foregroundRequired;
        return;
      }
      if (!isBackEligible()) {
        result = AiTaskBackResult.notEligible;
        return;
      }
      final reply = await _invoke('moveTaskToBack', {'opSeq': _nextSequence()});
      if (!_current || reply == null) return;
      result = switch (reply['status']) {
        'moved' when reply.length == 2 => AiTaskBackResult.moved,
        'not_moved' when reply.length == 2 => AiTaskBackResult.notMoved,
        'unsupported'
            when reply.length == 3 && reply['reason'] == 'not_implemented' =>
          AiTaskBackResult.unsupported,
        'rejected'
            when reply.length == 3 &&
                reply['reason'] == 'foreground_required' =>
          AiTaskBackResult.foregroundRequired,
        'rejected' when reply.length == 3 && reply['reason'] == 'unavailable' =>
          AiTaskBackResult.unavailable,
        'rejected'
            when (reply.length == 3 &&
                    const {
                      'invalid_arguments',
                      'security_exception',
                      'move_failed',
                    }.contains(reply['reason'])) ||
                (reply.length == 4 &&
                    reply['reason'] == 'stale_operation' &&
                    reply['opSeqFloor'] is int &&
                    (reply['opSeqFloor']! as int) >= 1 &&
                    (reply['opSeqFloor']! as int) <= _maxSequence) =>
          AiTaskBackResult.failed,
        _ => AiTaskBackResult.unavailable,
      };
    });
    return result;
  }

  Future<(Map<Object?, Object?>?, AiBackgroundStartFailure?)> _invokeStart(
    Map<String, Object> args,
  ) async {
    try {
      final result = await _channel
          .invokeMethod<Object?>('startRuns', args)
          .timeout(_interval);
      final reply = _reply(result);
      return (
        reply,
        reply == null ? AiBackgroundStartFailure.channelUnavailable : null,
      );
    } on TimeoutException {
      return (null, AiBackgroundStartFailure.timeout);
    } on PlatformException catch (error) {
      final code = error.code.toLowerCase();
      if (code.contains('security')) {
        return (null, AiBackgroundStartFailure.securityException);
      }
      if (code.contains('startnotallowed') || code.contains('start_denied')) {
        return (null, AiBackgroundStartFailure.startDenied);
      }
      return (null, AiBackgroundStartFailure.channelUnavailable);
    } on Object {
      return (null, AiBackgroundStartFailure.channelUnavailable);
    }
  }

  Future<void> _start(AiBackgroundRunGate gate, int revision) {
    if (!backgroundEnabled || !_attach()) {
      gate._startFailure = AiBackgroundStartFailure.unsupported;
      return Future<void>.value();
    }
    final shared = _shared!;
    if (shared.leaseOwner != null &&
        !identical(shared.leaseOwner, this) &&
        shared.releasePending == 0) {
      gate._startFailure = AiBackgroundStartFailure.channelUnavailable;
      return Future<void>.value();
    }
    shared.leaseOwner ??= this;
    return _serial(() async {
      try {
        if (!gate._stillStarting(revision) || !_current) return;
        if (_orphan || !gate._appInForeground()) {
          gate._startFailure = _orphan
              ? AiBackgroundStartFailure.cleanupFailed
              : AiBackgroundStartFailure.foregroundRequired;
          return;
        }
        if (!await _seed() || !gate._stillStarting(revision) || !_current) {
          gate._startFailure = AiBackgroundStartFailure.channelUnavailable;
          return;
        }
        if (_orphan || !gate._appInForeground()) {
          gate._startFailure = _orphan
              ? AiBackgroundStartFailure.cleanupFailed
              : AiBackgroundStartFailure.foregroundRequired;
          return;
        }
        if (shared.leaseOwner != null && !identical(shared.leaseOwner, this)) {
          gate._startFailure = AiBackgroundStartFailure.channelUnavailable;
          return;
        }
        shared.leaseOwner = this;
        final existing = _permit;
        if (existing != null && _status == AiBackgroundExecutionStatus.active) {
          gate._bind(existing, revision);
          updateProgress();
          return;
        }
        final request = _newId();
        final stopRevision = _stopRevision;
        gate._requestId = request;
        shared.stopLifecycle = (
          owner: this,
          startRequestId: request,
          permitId: null,
        );
        _setStatus(AiBackgroundExecutionStatus.starting);
        final sequence = _nextSequence();
        final progress = _progress();
        final (reply, invokeFailure) = await _invokeStart({
          'opSeq': sequence,
          'startRequestId': request,
          'workCount': progress.$1,
          'step': progress.$2,
          'title': progress.$3,
          'text': progress.$4,
          'stopAllLabel': progress.$5,
        });
        if (_current &&
            reply?['status'] == 'rejected' &&
            reply?['reason'] == 'user_stop' &&
            shared.consumeStop(startRequestId: request) != null) {
          // Native finishPending precedes its best-effort callback. Consume
          // this request now so a lost or replayed callback cannot lose/repeat it.
          _stopRevision++;
          gate._requestId = null;
          gate._invalidated = true;
          gate._released = false;
          _setStatus(AiBackgroundExecutionStatus.invalidated);
          shared.emitStop(this);
        }
        if (!gate._stillStarting(revision) || !_current) {
          if (stopRevision == _stopRevision) {
            await gate._cleanupRequest(request);
          }
          return;
        }
        gate._requestId = null;
        if (reply == null) {
          gate._startFailure = invokeFailure;
          await gate._cleanupRequest(
            request,
            confirmedRejected:
                invokeFailure == AiBackgroundStartFailure.securityException ||
                invokeFailure == AiBackgroundStartFailure.startDenied,
          );
          if (!_orphan) _setStatus(AiBackgroundExecutionStatus.foregroundOnly);
          return;
        }
        final permit = reply['permitId'];
        if (reply['status'] == 'active' &&
            reply['startRequestId'] == request &&
            reply['opSeq'] is int &&
            reply['opSeq'] == sequence &&
            _validId(permit) &&
            !_invalidatedPermits.contains(permit)) {
          _permit = permit! as String;
          shared.stopLifecycle = (
            owner: this,
            startRequestId: request,
            permitId: _permit,
          );
          shared.leasePermit = _permit;
          _lastProgressAt = _clock();
          _lastProgress = progress;
          gate._bind(_permit!, revision);
          _setStatus(AiBackgroundExecutionStatus.active);
          _languageTimer?.cancel();
          _languageTimer = Timer.periodic(_interval, (_) => updateProgress());
          updateProgress();
          return;
        }
        if (reply['status'] == 'rejected') {
          shared.consumeStop(startRequestId: request);
          final reason = reply['reason'];
          if (reason == 'cleanup_failed') {
            _orphan = true;
            _setStatus(AiBackgroundExecutionStatus.unavailable);
          } else if (const {
            'user_stop',
            'timeout',
            'synthetic_timeout',
            'service_destroyed',
            'activity_destroyed',
            'released',
          }.contains(reason)) {
            gate._invalidated = true;
            _setStatus(AiBackgroundExecutionStatus.invalidated);
          } else {
            gate._startFailure = switch (reason) {
              'foreground_required' =>
                AiBackgroundStartFailure.foregroundRequired,
              'start_denied' => AiBackgroundStartFailure.startDenied,
              'security_exception' =>
                AiBackgroundStartFailure.securityException,
              _ => AiBackgroundStartFailure.channelRefused,
            };
            // A rejected start has no live permit, but a newer scoped release
            // also reveals sticky native cleanup failure before degrading.
            await gate._cleanupRequest(request, confirmedRejected: true);
            if (_orphan) return;
            _setStatus(AiBackgroundExecutionStatus.foregroundOnly);
          }
          return;
        }
        // An unexpected or already-invalidated success cannot authorize a
        // permitless foreground fallback while its request is cleaned up.
        gate._invalidated = true;
        gate._released = false;
        await gate._cleanupRequest(request);
      } finally {
        if (identical(shared.leaseOwner, this) &&
            shared.leasePermit == null &&
            shared.immediateCleanups == 0 &&
            !shared.orphan) {
          shared.leaseOwner = null;
        }
      }
    });
  }

  Future<void> _cleanupRequest(
    String request, {
    bool confirmedRejected = false,
    bool cleanupAfterDetach = false,
  }) async {
    final shared = _shared;
    final stopRevision = _stopRevision;
    _immediateCleanups++;
    _releasePending++;
    try {
      final reply = await _invoke('releaseRuns', {
        'opSeq': _nextSequence(),
        'startRequestId': request,
      });
      if (stopRevision != _stopRevision) return;
      if (reply?['status'] != 'released' ||
          (reply?['didRelease'] != true &&
              !(confirmedRejected && reply?['didRelease'] == false))) {
        _orphan = true;
        _setStatus(AiBackgroundExecutionStatus.unavailable);
      } else {
        shared?.consumeStop(startRequestId: request);
        if (shared != null &&
            identical(shared.leaseOwner, this) &&
            shared.leasePermit == null) {
          shared.leaseOwner = null;
        }
        if (_permit == null &&
            _status == AiBackgroundExecutionStatus.starting) {
          _setStatus(AiBackgroundExecutionStatus.released);
        }
      }
    } finally {
      _immediateCleanups--;
      _releasePending--;
      shared?.retireIfIdle();
      if (cleanupAfterDetach && _orphan && _current && _appInForeground()) {
        unawaited(onForeground());
      }
    }
  }

  (int, int, String, String, String) _progress() {
    final count = serviceWorkCount.clamp(1, 3);
    var step = 0;
    for (final gate in _gates) {
      if (gate._active && gate._step > step) step = gate._step;
    }
    return (
      count,
      step.clamp(0, 1000000),
      l10n.aiRunServiceTitle,
      l10n.aiRunServiceText,
      l10n.aiRunServiceStopAll,
    );
  }

  /// Schedule the latest count, step and app-language strings, no more often
  /// than once per second. A periodic check notices app-language changes.
  void updateProgress() {
    if (!_current ||
        _permit == null ||
        _status != AiBackgroundExecutionStatus.active ||
        serviceWorkCount == 0) {
      return;
    }
    final current = _progress();
    if (current == _lastProgress) return;
    final elapsed = _lastProgressAt == null
        ? _interval
        : _clock() - _lastProgressAt!;
    if (_progressInFlight || elapsed < _interval) {
      if (!_progressInFlight && _progressTimer == null) {
        final delay = elapsed < Duration.zero ? _interval : _interval - elapsed;
        _progressTimer = Timer(delay, () {
          _progressTimer = null;
          updateProgress();
        });
      }
      return;
    }
    final permit = _permit!;
    _lastProgressAt = _clock();
    _lastProgress = current;
    _progressInFlight = true;
    unawaited(() async {
      final reply = await _invoke('updateProgress', {
        'opSeq': _nextSequence(),
        'permitId': permit,
        'workCount': current.$1,
        'step': current.$2,
        'title': current.$3,
        'text': current.$4,
        'stopAllLabel': current.$5,
      });
      _progressInFlight = false;
      if (!_current || _permit != permit) return;
      if (reply?['status'] != 'updated' || reply?['permitId'] != permit) {
        _invalidatePermit(
          permit,
          inactiveConfirmed:
              reply?['status'] == 'rejected' &&
              reply?['reason'] == 'permit_inactive',
        );
        return;
      }
      updateProgress();
    }());
  }

  void _workChanged() {
    if (_disposed) return;
    notifyListeners();
    if (serviceWorkCount == 0 && _permit != null) {
      unawaited(releaseRuns());
    } else {
      updateProgress();
    }
  }

  /// Normal release is scoped to the current permit and serial with starts.
  Future<void> releaseRuns() {
    final permit = _permit;
    if (permit != null) {
      for (final gate in _gates) {
        if (gate.binding.permitId == permit) gate.cancelStart();
      }
    }
    if (permit == null) {
      return Future.wait<void>([
        for (final gate in _gates)
          if (gate._cleanup != null) gate._cleanup!,
      ]);
    }
    final approvalWaits = [
      for (final gate in _gates)
        if (gate.binding.permitId == permit &&
            gate._current &&
            !gate._invalidated &&
            !gate._starting &&
            !gate._active &&
            gate._awaitingApproval)
          (gate, gate.binding, gate._revision),
    ];
    _permit = null;
    _cancelProgress();
    for (final gate in _gates) {
      if (gate.binding.permitId == permit) {
        gate._invalidated = true;
        gate._released = true;
      }
    }
    final release = _queuePermitRelease(permit, approvalWaits: approvalWaits);
    for (final (gate, _, _) in approvalWaits) {
      gate._normalRelease = release;
    }
    unawaited(
      release.then((_) {
        for (final (gate, _, _) in approvalWaits) {
          if (identical(gate._normalRelease, release)) {
            gate._normalRelease = null;
          }
        }
      }),
    );
    _setStatus(AiBackgroundExecutionStatus.released);
    return release;
  }

  Future<void> _queuePermitRelease(
    String permit, {
    bool cleanupAfterDetach = false,
    List<(AiBackgroundRunGate, AiExecutionRunBinding, int)> approvalWaits =
        const [],
  }) {
    final shared = _shared;
    final stopRevision = _stopRevision;
    _releasePending++;
    return _serial(() async {
      try {
        final reply = await _invoke('releaseRuns', {
          'opSeq': _nextSequence(),
          'permitId': permit,
        });
        if (stopRevision != _stopRevision) return;
        if (reply?['status'] != 'released' || reply?['didRelease'] != true) {
          _orphan = true;
          _setStatus(AiBackgroundExecutionStatus.unavailable);
        } else {
          shared?.consumeStop(permitId: permit);
          if (shared != null &&
              identical(shared.leaseOwner, this) &&
              shared.leasePermit == permit) {
            shared.leaseOwner = null;
            shared.leasePermit = null;
          }
          var rebound = false;
          if (_current && !_invalidatedPermits.contains(permit)) {
            for (final (gate, binding, revision) in approvalWaits) {
              if (gate._current &&
                  identical(gate.binding, binding) &&
                  gate._revision == revision &&
                  gate._released &&
                  !gate._starting &&
                  !gate._active &&
                  gate._awaitingApproval &&
                  binding.rebindForForegroundApproval(
                    releasedPermitId: permit,
                  )) {
                gate._invalidated = false;
                gate._released = false;
                rebound = true;
              }
            }
          }
          if (rebound) notifyListeners();
        }
      } finally {
        _releasePending--;
        // Reattachment may precede a failed detach cleanup reply. A visible
        // owner must still clean the orphan without restarting any run.
        if (cleanupAfterDetach && _orphan && _current && _appInForeground()) {
          unawaited(onForeground());
        }
      }
    });
  }

  /// Stop invalidates Dart synchronously and does not wait on progress or the
  /// start/release queue. Native handles stop before any callback to Dart.
  Future<void> stopAll() async {
    _stopRevision++;
    _stopsInFlight++;
    final shared = _shared;
    shared?.stopLifecycle = null;
    for (final owner in shared?.owners.toList(growable: false) ?? [this]) {
      owner._permit = null;
      owner._cancelProgress();
      for (final gate in owner._gates) {
        gate._invalidated = true;
        gate._released = false;
        gate._revision++;
      }
      owner._setStatus(AiBackgroundExecutionStatus.invalidated);
      if (!owner._disposed) owner._stopEvents.add(null);
    }
    if (!await _seed()) {
      _orphan = true;
      _setStatus(AiBackgroundExecutionStatus.unavailable);
      _stopsInFlight--;
      return;
    }
    final reply = await _invoke('stopAll', {'opSeq': _nextSequence()});
    if (reply?['status'] == 'stopped') {
      _orphan = false;
      if (shared != null) {
        shared.leaseOwner = null;
        shared.leasePermit = null;
      }
    } else {
      _orphan = true;
      _setStatus(AiBackgroundExecutionStatus.unavailable);
    }
    _stopsInFlight--;
    shared?.retireIfIdle();
  }

  Future<void> onForeground() async {
    if (_orphan && _appInForeground() && _current) await stopAll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // Dart can outlive its Activity. Native owns destruction and stopping,
      // but a lost callback must not leave an already-issued ticket usable.
      final permit = _permit;
      for (final gate in _gates) {
        gate.cancelStart(cleanupAfterDetach: true);
        gate._invalidated = true;
        gate._released = false;
        gate._needsExplicitResume = true;
        gate._revision++;
      }
      _cancelProgress();
      if (permit != null) _invalidatePermit(permit, cleanupAfterDetach: true);
      _setStatus(AiBackgroundExecutionStatus.invalidated);
      return;
    }
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      var changed = false;
      for (final gate in _gates) {
        if (gate._current &&
            gate._active &&
            gate.binding.permitId == null &&
            !gate._needsExplicitResume) {
          gate._needsExplicitResume = true;
          changed = true;
        }
      }
      if (changed && !_disposed) notifyListeners();
    } else if (state == AppLifecycleState.resumed) {
      unawaited(onForeground());
    }
  }

  void _handleInvalidation(String permit, String? startRequest, String reason) {
    if (!_current) return;
    final shared = _shared;
    final pendingStart =
        shared != null &&
        identical(shared.leaseOwner, this) &&
        shared.leasePermit == null &&
        _validId(startRequest) &&
        _gates.any(
          (gate) =>
              gate._starting &&
              gate._current &&
              !gate._invalidated &&
              gate._requestId == startRequest,
        );
    final refusedStart = const {
      'start_failed',
      'security_exception',
      'start_denied',
      'notification_failed',
    }.contains(reason);
    if (pendingStart && !refusedStart) {
      _stopRevision++;
      for (final gate in _gates) {
        if (gate._starting && gate._requestId == startRequest) {
          gate._invalidated = true;
          gate._released = false;
          gate._starting = false;
          gate._requestId = null;
          gate._revision++;
        }
      }
      shared.leaseOwner = null;
      _setStatus(AiBackgroundExecutionStatus.invalidated);
    }
    _invalidatedPermits.add(permit);
    _invalidatePermit(permit, inactiveConfirmed: true);
  }

  void _invalidatePermit(
    String permit, {
    bool inactiveConfirmed = false,
    bool cleanupAfterDetach = false,
  }) {
    _invalidatedPermits.add(permit);
    var affected = false;
    for (final gate in _gates) {
      if (gate.binding.permitId == permit) {
        gate._invalidated = true;
        gate._released = false;
        affected = true;
      }
    }
    if (_permit != permit) {
      if (affected && !_disposed) notifyListeners();
      return;
    }
    _permit = null;
    _cancelProgress();
    _setStatus(AiBackgroundExecutionStatus.invalidated);
    final shared = _shared;
    if (shared != null &&
        identical(shared.leaseOwner, this) &&
        shared.leasePermit == permit) {
      if (inactiveConfirmed) {
        shared.leaseOwner = null;
        shared.leasePermit = null;
        shared.retireIfIdle();
      } else {
        unawaited(
          _queuePermitRelease(permit, cleanupAfterDetach: cleanupAfterDetach),
        );
      }
    }
  }

  void _cancelProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _languageTimer?.cancel();
    _languageTimer = null;
    _lastProgress = null;
    _lastProgressAt = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final permit = _permit;
    _permit = null;
    _cancelProgress();
    for (final gate in _gates.toList()) {
      gate.dispose();
    }
    if (permit != null) unawaited(_queuePermitRelease(permit));
    _widgetsBinding?.removeObserver(this);
    final messenger = _attachedMessenger;
    if (messenger != null) {
      final channels = _listeners[messenger];
      final listeners = channels?[_channel.name];
      listeners?.owners.remove(this);
      listeners?.retireIfIdle();
    }
    unawaited(_stopEvents.close());
    super.dispose();
  }
}

/// Stable gate object shared by a conversation's runner and coordinator.
final class AiBackgroundRunGate implements AiExecutionGate {
  AiBackgroundRunGate._(
    this._owner,
    this._conversationId,
    this._isCurrent,
    this._appInForeground,
  ) {
    _binding = _newBinding('');
  }

  final AiBackgroundExecution _owner;
  final String Function() _conversationId;
  final bool Function() _isCurrent;
  final bool Function() _appInForeground;
  late AiExecutionRunBinding _binding;
  bool _active = false;
  bool _backProtected = false;
  bool _awaitingApproval = false;
  bool _invalidated = false;
  bool _released = false;
  bool _starting = false;
  bool _disposed = false;
  int _step = 0;
  int _revision = 0;
  String? _requestId;
  Future<void>? _cleanup;
  String? _cleaningRequest;
  Future<void>? _normalRelease;
  bool _approvalRestart = false;
  bool _needsExplicitResume = false;
  AiBackgroundStartFailure? _startFailure;
  AiBackgroundStartResult? _lastStartResult;

  AiBackgroundStartResult? get lastStartResult => _lastStartResult;
  AiBackgroundCleanupConfirmation get cleanupConfirmation =>
      _owner.cleanupConfirmation;
  bool get requiresExplicitResume => _needsExplicitResume || _invalidated;

  /// Approval keeps its waiting state until the bridge confirms release.
  /// Completion is not authorization; the coordinator still checks all gates.
  Future<void>? get pendingNormalRelease => _normalRelease;

  AiExecutionRunBinding _newBinding(String runId, [String? permit]) =>
      AiExecutionRunBinding(
        accountKey: _owner.accountKey,
        generation: _owner.generation,
        ownerApi: _owner.ownerApi,
        conversationId: _conversationId(),
        runId: runId,
        permitId: permit,
      );

  @override
  AiExecutionRunBinding get binding => _binding;

  AiBackgroundExecutionStatus get status {
    if (_invalidated) {
      return _released
          ? AiBackgroundExecutionStatus.released
          : AiBackgroundExecutionStatus.invalidated;
    }
    if (_starting) return AiBackgroundExecutionStatus.starting;
    if (_binding.permitId != null && executionEligible) {
      return AiBackgroundExecutionStatus.active;
    }
    if (_owner._orphan && _binding.runId.isNotEmpty) {
      return AiBackgroundExecutionStatus.unavailable;
    }
    return AiBackgroundExecutionStatus.foregroundOnly;
  }

  bool get _current =>
      !_disposed &&
      _owner._current &&
      _isCurrent() &&
      _binding.conversationId == _conversationId();

  @override
  bool get executionEligible =>
      _current &&
      !_invalidated &&
      !_needsExplicitResume &&
      !_owner._orphan &&
      (_binding.permitId == null
          ? _appInForeground()
          : _owner._permit == _binding.permitId &&
                _owner.status == AiBackgroundExecutionStatus.active);

  Future<AiBackgroundStartResult> beginRun({required String runId}) =>
      _beginRun(runId: runId, preserveBinding: false);

  /// A user-requested continuation retains the logical run identifier. It
  /// creates a new binding so tickets from the previous permit stay invalid.
  Future<AiBackgroundStartResult> resumeRun() {
    if (!_current || _binding.runId.isEmpty || !_appInForeground()) {
      return Future.value(
        _recordStart(
          AiBackgroundStartResult(
            AiBackgroundStartDisposition.invalidated,
            failure: !_appInForeground()
                ? AiBackgroundStartFailure.foregroundRequired
                : AiBackgroundStartFailure.runChanged,
          ),
        ),
      );
    }
    return _beginRun(runId: _binding.runId, preserveBinding: false);
  }

  /// Only a visible approval action can start the service after a normal
  /// approval-wait release. Its run binding stays identical for the proposal.
  Future<AiBackgroundStartResult> restartForApproval() async {
    final release = _normalRelease;
    if (release != null) await release;
    if (!_current ||
        _invalidated ||
        _needsExplicitResume ||
        !_awaitingApproval ||
        _binding.runId.isEmpty ||
        !_appInForeground()) {
      return _recordStart(
        AiBackgroundStartResult(
          AiBackgroundStartDisposition.invalidated,
          failure: !_appInForeground()
              ? AiBackgroundStartFailure.foregroundRequired
              : AiBackgroundStartFailure.runChanged,
        ),
      );
    }
    return _beginRun(runId: _binding.runId, preserveBinding: true);
  }

  AiBackgroundStartResult _recordStart(AiBackgroundStartResult result) {
    _lastStartResult = result;
    return result;
  }

  Future<AiBackgroundStartResult> _beginRun({
    required String runId,
    required bool preserveBinding,
  }) async {
    if (!_owner._current || _disposed || !_isCurrent() || _starting) {
      return _recordStart(
        const AiBackgroundStartResult(
          AiBackgroundStartDisposition.invalidated,
          failure: AiBackgroundStartFailure.runChanged,
        ),
      );
    }
    if (_owner._stopsInFlight != 0) {
      throw const AiExecutionPaused(
        AiExecutionPause(AiExecutionPauseReason.unavailable),
      );
    }
    if (_owner.serviceWorkCount - (_active ? 1 : 0) >= 3) {
      throw const AiExecutionPaused(
        AiExecutionPause(AiExecutionPauseReason.runLimit),
      );
    }
    final revision = ++_revision;
    _startFailure = null;
    _invalidated = false;
    _needsExplicitResume = false;
    _released = false;
    _awaitingApproval = false;
    if (!preserveBinding) _binding = _newBinding(runId);
    _approvalRestart = preserveBinding;
    _active = true;
    _backProtected = true;
    _starting = true;
    _owner._workChanged();
    try {
      await _owner
          ._start(this, revision)
          .timeout(
            AiBackgroundExecution._interval,
            onTimeout: () {
              if (_revision == revision) {
                _startFailure = AiBackgroundStartFailure.timeout;
                cancelStart();
              }
            },
          );
    } finally {
      if (_revision == revision) {
        _starting = false;
        _owner._workChanged();
      }
    }
    final result = _invalidated
        ? AiBackgroundStartResult(
            AiBackgroundStartDisposition.invalidated,
            failure: _startFailure,
          )
        : _owner._orphan
        ? const AiBackgroundStartResult(
            AiBackgroundStartDisposition.unavailable,
            failure: AiBackgroundStartFailure.cleanupFailed,
          )
        : _binding.permitId != null && executionEligible
        ? const AiBackgroundStartResult(AiBackgroundStartDisposition.active)
        : AiBackgroundStartResult(
            AiBackgroundStartDisposition.foregroundOnly,
            failure: _startFailure,
          );
    return _recordStart(result);
  }

  bool _stillStarting(int revision) =>
      _current && !_invalidated && _revision == revision && _active;

  void _bind(String permit, int revision) {
    if (!_stillStarting(revision)) return;
    _released = false;
    if (_approvalRestart) {
      if (!_binding.rebindForExplicitContinuation(
        runId: _binding.runId,
        permitId: permit,
      )) {
        _invalidated = true;
      }
    } else {
      _binding = _newBinding(_binding.runId, permit);
    }
  }

  Future<void> _cleanupRequest(
    String request, {
    bool confirmedRejected = false,
    bool cleanupAfterDetach = false,
  }) {
    if (_cleaningRequest == request) return _cleanup!;
    _cleaningRequest = request;
    return _cleanup = _owner._cleanupRequest(
      request,
      confirmedRejected: confirmedRejected,
      cleanupAfterDetach: cleanupAfterDetach,
    );
  }

  /// Updates lifetime counts from the controller, including accepted writes
  /// that still need settlement after the runner stops.
  void setWork({
    required bool active,
    required bool backProtected,
    bool awaitingApproval = false,
    int step = 0,
  }) {
    if (_disposed) return;
    if (active && !_active && _owner.serviceWorkCount >= 3) active = false;
    final waiting = awaitingApproval && !active;
    final changed =
        _active != active ||
        _backProtected != backProtected ||
        _awaitingApproval != waiting ||
        _step != step;
    _active = active;
    _backProtected = backProtected;
    _awaitingApproval = waiting;
    _step = step.clamp(0, 1000000);
    if (changed) _owner._workChanged();
  }

  void cancelStart({bool cleanupAfterDetach = false}) {
    if (!_starting) return;
    _invalidated = true;
    _released = false;
    _revision++;
    _starting = false;
    final request = _requestId;
    _requestId = null;
    if (request != null) {
      unawaited(
        _cleanupRequest(request, cleanupAfterDetach: cleanupAfterDetach),
      );
    }
  }

  void release() {
    if (_disposed) return;
    cancelStart();
    _revision++;
    _invalidated = true;
    _released = true;
    setWork(active: false, backProtected: false);
  }

  @override
  Future<AiExecutionTicket> acquire(AiContinuationKind kind) async {
    void refuse(AiExecutionPauseReason reason) =>
        throw AiExecutionPaused(AiExecutionPause(reason, kind: kind));
    final captured = _binding;
    final started = _owner._clock();
    if (!executionEligible) {
      refuse(
        captured.permitId == null
            ? AiExecutionPauseReason.foregroundRequired
            : AiExecutionPauseReason.permitInactive,
      );
    }
    final nonce = AiBackgroundExecution._newId();
    String ticketId = nonce;
    if (captured.permitId case final permit?) {
      final reply = await _owner._invoke('acquireContinuation', {
        'opSeq': _owner._nextSequence(),
        'permitId': permit,
        'kind': kind.name,
        'nonce': nonce,
      });
      // A release/new run may overtake the reply. Discard it before treating
      // any old-permit rejection or missing reply as a fresh invalidation.
      if (!identical(captured, _binding) ||
          captured.permitId != permit ||
          !executionEligible) {
        refuse(AiExecutionPauseReason.runChanged);
      }
      if (reply?['status'] == 'rejected') {
        final reason = reply?['reason'];
        if (reason == 'permit_inactive' ||
            reason == 'unavailable' ||
            reason == 'notification_failed') {
          _owner._invalidatePermit(
            permit,
            inactiveConfirmed: reason == 'permit_inactive',
          );
        }
        refuse(switch (reason) {
          'permit_inactive' => AiExecutionPauseReason.permitInactive,
          'nonce_replayed' => AiExecutionPauseReason.nonceReplayed,
          'nonce_capacity' => AiExecutionPauseReason.nonceCapacity,
          _ => AiExecutionPauseReason.unavailable,
        });
      }
      if (reply == null) {
        _owner._invalidatePermit(permit);
        refuse(AiExecutionPauseReason.timeout);
      }
      if (reply?['status'] != 'ticket' ||
          reply?['permitId'] != permit ||
          reply?['kind'] != kind.name ||
          reply?['nonce'] != nonce ||
          !AiBackgroundExecution._validTicketId(reply?['ticketId'])) {
        _owner._invalidatePermit(permit);
        refuse(AiExecutionPauseReason.invalidTicket);
      }
      ticketId = reply!['ticketId']! as String;
      final elapsed = _owner._clock() - started;
      if (elapsed < Duration.zero || elapsed >= AiExecutionTicket.ttl) {
        refuse(AiExecutionPauseReason.ticketExpired);
      }
    }
    return AiExecutionTicket(
      binding: captured,
      kind: kind,
      nonce: nonce,
      ticketId: ticketId,
      requestStartedAt: started,
      clock: _owner._clock,
      isCurrent: () => identical(captured, _binding) && executionEligible,
    );
  }

  void dispose() {
    if (_disposed) return;
    release();
    _disposed = true;
    _owner._gates.remove(this);
  }
}
