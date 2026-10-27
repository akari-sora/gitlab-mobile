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
    for (final owner in owners.toList(growable: false)) {
      await owner._handleCall(call);
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

/// One native service owner for an account, API and session generation.
/// Native permits only prepare work: every continuation still obtains a ticket.
final class AiBackgroundExecution extends ChangeNotifier
    with WidgetsBindingObserver {
  AiBackgroundExecution({
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
  String? _permit;
  Timer? _progressTimer;
  Timer? _languageTimer;
  Duration? _lastProgressAt;
  (int, int, String, String)? _lastProgress;
  bool _progressInFlight = false;
  AiBackgroundExecutionStatus _status =
      AiBackgroundExecutionStatus.foregroundOnly;

  AiBackgroundExecutionStatus get status => _status;
  int get serviceWorkCount => _gates.where((gate) => gate._active).length;
  int get backProtectedCount =>
      _gates.where((gate) => gate._backProtected).length;

  bool get _current => !_disposed && _isCurrent();
  bool get _orphan => _shared?.orphan ?? _localOrphan;
  set _orphan(bool value) {
    if (_shared case final shared?) {
      shared.orphan = value;
    } else {
      _localOrphan = value;
    }
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
    if (_shared case final shared?) {
      shared.stopsInFlight = value;
    } else {
      _localStopsInFlight = value;
    }
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

  /// The unsupported probe advances native's sequence without starting work.
  /// A stale reply supplies the process high-water mark before the real call.
  Future<bool> _seed() {
    if (_seeded) return Future<bool>.value(true);
    if (!_attach()) return Future<bool>.value(false);
    return _seedFuture ??= () async {
      try {
        final reply = await _invoke('moveTaskToBack', {
          'opSeq': _nextSequence(),
        });
        if (reply?['status'] == 'unsupported' &&
            reply?['reason'] == 'not_implemented') {
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
    if (!_nativeSupported) return false;
    if (_widgetsBinding != null) return true;
    try {
      final binding = WidgetsBinding.instance;
      final messenger = _channel.binaryMessenger;
      final channels = _listeners.putIfAbsent(messenger, () => {});
      var listeners = channels[_channel.name];
      if (listeners == null) {
        listeners = _ExecutionChannelListeners(_channel, messenger);
        _channel.setMethodCallHandler(listeners.dispatch);
        channels[_channel.name] = listeners;
      }
      listeners.orphan = listeners.orphan || _localOrphan;
      listeners.stopRevision += _localStopRevision;
      listeners.stopsInFlight += _localStopsInFlight;
      _localOrphan = false;
      _localStopRevision = 0;
      _localStopsInFlight = 0;
      listeners.owners.add(this);
      _shared = listeners;
      _attachedMessenger = messenger;
      _widgetsBinding = binding;
      binding.addObserver(this);
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

  Future<void> startRuns(AiBackgroundRunGate gate) =>
      gate.beginRun(runId: _newId());

  Future<void> _start(AiBackgroundRunGate gate, int revision) {
    if (!_attach()) return Future<void>.value();
    final shared = _shared!;
    if (shared.leaseOwner != null &&
        !identical(shared.leaseOwner, this) &&
        shared.releasePending == 0) {
      return Future<void>.value();
    }
    shared.leaseOwner ??= this;
    return _serial(() async {
      try {
        if (!gate._stillStarting(revision) || !_current) return;
        if (_orphan || !gate._appInForeground()) return;
        if (!await _seed() || !gate._stillStarting(revision) || !_current) {
          return;
        }
        if (_orphan || !gate._appInForeground()) return;
        if (shared.leaseOwner != null && !identical(shared.leaseOwner, this)) {
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
        _setStatus(AiBackgroundExecutionStatus.starting);
        final sequence = _nextSequence();
        final progress = _progress();
        final reply = await _invoke('startRuns', {
          'opSeq': sequence,
          'startRequestId': request,
          'workCount': progress.$1,
          'step': progress.$2,
          'title': progress.$3,
          'text': progress.$4,
        });
        if (!gate._stillStarting(revision) || !_current) {
          if (stopRevision == _stopRevision) {
            await gate._cleanupRequest(request);
          }
          return;
        }
        gate._requestId = null;
        if (reply == null) {
          await gate._cleanupRequest(request);
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
          final reason = reply['reason'];
          if (reason == 'cleanup_failed') {
            _orphan = true;
            _setStatus(AiBackgroundExecutionStatus.unavailable);
          } else if (const {
            'user_stop',
            'timeout',
            'service_destroyed',
            'activity_destroyed',
            'released',
            'notification_failed',
          }.contains(reason)) {
            gate._invalidated = true;
            _setStatus(AiBackgroundExecutionStatus.invalidated);
          } else {
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

  Future<void> _cleanupRequest(String request) async {
    final shared = _shared;
    final stopRevision = _stopRevision;
    if (shared != null) {
      shared.immediateCleanups++;
      shared.releasePending++;
    }
    try {
      final reply = await _invoke('releaseRuns', {
        'opSeq': _nextSequence(),
        'startRequestId': request,
      });
      if (stopRevision != _stopRevision) return;
      if (reply?['status'] != 'released' || reply?['didRelease'] != true) {
        _orphan = true;
        _setStatus(AiBackgroundExecutionStatus.unavailable);
      } else {
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
      if (shared != null) {
        shared.immediateCleanups--;
        shared.releasePending--;
        shared.retireIfIdle();
      }
    }
  }

  (int, int, String, String) _progress() {
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
    List<(AiBackgroundRunGate, AiExecutionRunBinding, int)> approvalWaits =
        const [],
  }) {
    final shared = _shared;
    final stopRevision = _stopRevision;
    if (shared != null) shared.releasePending++;
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
        if (shared != null) shared.releasePending--;
      }
    });
  }

  /// Stop invalidates Dart synchronously and does not wait on progress or the
  /// start/release queue. Native handles stop before any callback to Dart.
  Future<void> stopAll() async {
    _stopRevision++;
    _stopsInFlight++;
    final shared = _shared;
    for (final owner in shared?.owners.toList(growable: false) ?? [this]) {
      owner._permit = null;
      owner._cancelProgress();
      for (final gate in owner._gates) {
        gate._invalidated = true;
        gate._released = false;
        gate._revision++;
      }
      owner._setStatus(AiBackgroundExecutionStatus.invalidated);
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
    if (state == AppLifecycleState.resumed) unawaited(onForeground());
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'permitInvalidated' || !_current) return;
    final args = call.arguments;
    if (args is! Map<Object?, Object?> ||
        args.length != 3 ||
        args['version'] is! int ||
        args['version'] != 1 ||
        !_validId(args['permitId']) ||
        !const {
          'user_stop',
          'timeout',
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
    _invalidatedPermits.add(permit);
    _invalidatePermit(permit, inactiveConfirmed: true);
  }

  void _invalidatePermit(String permit, {bool inactiveConfirmed = false}) {
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
        unawaited(_queuePermitRelease(permit));
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
      (_binding.permitId == null
          ? _appInForeground()
          : _owner._permit == _binding.permitId &&
                _owner.status == AiBackgroundExecutionStatus.active);

  Future<void> beginRun({required String runId}) async {
    if (!_owner._current || _disposed || !_isCurrent()) return;
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
    _invalidated = false;
    _released = false;
    _awaitingApproval = false;
    _binding = _newBinding(runId);
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
              if (_revision == revision) cancelStart();
            },
          );
    } finally {
      if (_revision == revision) {
        _starting = false;
        _owner._workChanged();
      }
    }
  }

  bool _stillStarting(int revision) =>
      _current && !_invalidated && _revision == revision && _active;

  void _bind(String permit, int revision) {
    if (!_stillStarting(revision)) return;
    _released = false;
    _binding = _newBinding(_binding.runId, permit);
  }

  Future<void> _cleanupRequest(String request) {
    if (_cleaningRequest == request) return _cleanup!;
    _cleaningRequest = request;
    return _cleanup = _owner._cleanupRequest(request);
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

  void cancelStart() {
    if (!_starting) return;
    _invalidated = true;
    _released = false;
    _revision++;
    _starting = false;
    final request = _requestId;
    _requestId = null;
    if (request != null) unawaited(_cleanupRequest(request));
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
