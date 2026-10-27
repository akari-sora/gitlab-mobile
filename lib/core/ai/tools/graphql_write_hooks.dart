/// The journal phase, independent of a core method's error or result shape.
enum GraphWriteSpanState {
  notHooked,
  hookFailed,
  hookReturned,
  mayStartFalse,
  pastAcceptance,
}

typedef GraphBeforeMutation = Future<void> Function();

final class GraphHookContractException implements Exception {
  const GraphHookContractException();
}

/// One pair per invocation. Acceptance is monotonic even on a protocol error.
final class GraphHooks {
  GraphHooks({
    required GraphBeforeMutation beforeMutation,
    required bool Function() mayStart,
  }) : _beforeMutation = beforeMutation,
       _mayStart = mayStart;

  final GraphBeforeMutation _beforeMutation;
  final bool Function() _mayStart;
  GraphWriteSpanState _state = GraphWriteSpanState.notHooked;
  bool _beforeCalled = false;
  bool _startCalled = false;
  bool _invalid = false;
  bool _sent = false;
  Object? _blockedBeforeSend;
  Future<void>? _beforeFlight;

  GraphWriteSpanState get state => _state;
  bool get accepted => _state == GraphWriteSpanState.pastAcceptance;
  bool get sent => _sent;
  void markSent() => _sent = true;
  Object? get blockedBeforeSend => _blockedBeforeSend;
  bool get definitelyBlockedBeforeSend => !_sent && _blockedBeforeSend != null;
  void markBlockedBeforeSend(Object failure) => _blockedBeforeSend = failure;
  bool get contractViolated => _invalid;
  Future<void>? get beforeCompletion => _beforeFlight;

  Never _violation() {
    _invalid = true;
    throw const GraphHookContractException();
  }

  Future<void> beforeMutation() async {
    if (_beforeCalled || _startCalled) _violation();
    _beforeCalled = true;
    _state = GraphWriteSpanState.hookFailed;
    await (_beforeFlight = _runBeforeMutation());
  }

  Future<void> _runBeforeMutation() async {
    await _beforeMutation();
    if (_invalid) _violation();
    _state = GraphWriteSpanState.hookReturned;
  }

  bool mayStart() {
    if (_startCalled || _state != GraphWriteSpanState.hookReturned) {
      _violation();
    }
    _startCalled = true;
    _state = GraphWriteSpanState.mayStartFalse;
    if (!_mayStart()) return false;
    _state = GraphWriteSpanState.pastAcceptance;
    return true;
  }
}
