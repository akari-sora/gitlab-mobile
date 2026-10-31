import 'dart:async';
import 'dart:io' show Platform;

import 'package:mergeline_on_device_ai/mergeline_on_device_ai.dart';

import 'ai_events.dart';
import 'ai_failure.dart';
import 'ai_provider.dart';
import 'ai_transcript.dart';
import 'redaction.dart';
import 'wire/on_device_wire.dart';
import 'wire/wire_format.dart';

/// Default back-off delay before the single retry on [OnDeviceAiErrorCode.busy].
const Duration kOnDeviceBusyRetryDelay = Duration(milliseconds: 1500);

/// Narrow plugin interface injected into [OnDeviceAiTransport] so unit tests
/// can supply a fake without touching platform channels or Google ML Kit.
///
/// Implementations must never accept a caller-supplied `requestId` on
/// [generate]; the plugin generates and returns the ID on
/// [OnDeviceGenerationStream.requestId].
abstract interface class OnDeviceAiPlugin {
  OnDeviceGenerationStream generate({
    required String system,
    required List<OnDeviceTurn> turns,
    int? maxOutputTokens,
    double? temperature,
  });

  Future<void> cancel(String requestId);
}

final class _DefaultOnDeviceAiPlugin implements OnDeviceAiPlugin {
  const _DefaultOnDeviceAiPlugin();

  @override
  OnDeviceGenerationStream generate({
    required String system,
    required List<OnDeviceTurn> turns,
    int? maxOutputTokens,
    double? temperature,
  }) {
    // Elsewhere the plugin answers with an empty stream; never reach it.
    if (!Platform.isAndroid) {
      throw const OnDeviceAiException(
        OnDeviceAiErrorCode.unsupported,
        debugMessage: 'not_android',
      );
    }
    return MergelineOnDeviceAi.instance.generate(
      system: system,
      turns: turns,
      maxOutputTokens: maxOutputTokens,
      temperature: temperature,
    );
  }

  @override
  Future<void> cancel(String requestId) =>
      MergelineOnDeviceAi.instance.cancel(requestId);
}

/// Maps a plugin [OnDeviceAiException] to the corresponding [AiFailure].
AiFailure mapOnDeviceAiException(
  OnDeviceAiException error, {
  bool notSent = false,
}) => switch (error.code) {
  OnDeviceAiErrorCode.backgroundBlocked => AiFailure(
    AiFailureKind.onDeviceForegroundOnly,
    notSent: notSent,
  ),
  OnDeviceAiErrorCode.busy => AiFailure(
    AiFailureKind.onDeviceBusy,
    notSent: notSent,
  ),
  OnDeviceAiErrorCode.quotaExceeded => AiFailure(
    AiFailureKind.onDeviceQuotaExceeded,
    notSent: notSent,
  ),
  OnDeviceAiErrorCode.notDownloaded ||
  OnDeviceAiErrorCode.insufficientStorage => AiFailure(
    AiFailureKind.onDeviceModelNotReady,
    notSent: notSent,
  ),
  OnDeviceAiErrorCode.unsupported => AiFailure(
    AiFailureKind.onDeviceUnavailable,
    notSent: notSent,
  ),
  OnDeviceAiErrorCode.inputTooLong => AiFailure(
    AiFailureKind.contextTooLong,
    notSent: notSent,
  ),
  OnDeviceAiErrorCode.cancelled => AiFailure(
    AiFailureKind.cancelled,
    notSent: notSent,
  ),
  OnDeviceAiErrorCode.invalidArgument || OnDeviceAiErrorCode.other => AiFailure(
    AiFailureKind.onDeviceError,
    notSent: notSent,
  ),
};

final class _NoKnownSecrets implements KnownSecretsSource {
  const _NoKnownSecrets();

  @override
  Iterable<String> get current => const <String>[];
}

bool _alreadyRedacted(OnDeviceAssembledPrompt prompt, Redactor redactor) {
  try {
    return prompt.plainStrings.every(
      (value) => redactor.redactSource(value).text == value,
    );
  } on AiFailure {
    return false;
  }
}

final class _OnDeviceBusyRetry implements Exception {
  const _OnDeviceBusyRetry();
}

/// Transport for Android AICore / Gemini Nano via [OnDeviceAiPlugin].
///
/// Unlike [MergelineOnDeviceAi.instance], constructing this transport never
/// touches Google ML Kit; the plugin is invoked only when [complete] sends a
/// request.
final class OnDeviceAiTransport {
  OnDeviceAiTransport({
    OnDeviceAiPlugin? plugin,
    this.busyRetryDelay = kOnDeviceBusyRetryDelay,
    Future<void> Function(Duration)? wait,
  }) : _plugin = plugin ?? const _DefaultOnDeviceAiPlugin(),
       _wait = wait ?? Future<void>.delayed;

  final OnDeviceAiPlugin _plugin;
  final Duration busyRetryDelay;
  final Future<void> Function(Duration) _wait;

  final Set<String> _activeRequestIds = <String>{};
  final Set<StreamSubscription<String>> _activeSubscriptions =
      <StreamSubscription<String>>{};
  final Set<void Function()> _cancelCallbacks = <void Function()>{};
  int _generationId = 0;
  bool _closed = false;

  bool get isClosed => _closed;

  Set<String> get activeRequestIds =>
      Set<String>.unmodifiable(_activeRequestIds);

  /// Cancels any in-flight generation requests owned by this transport while
  /// keeping the transport open for subsequent turns in the same session.
  void cancelActive() {
    _generationId += 1;
    final requestIds = _activeRequestIds.toList(growable: false);
    _activeRequestIds.clear();
    final subscriptions = _activeSubscriptions.toList(growable: false);
    _activeSubscriptions.clear();
    final callbacks = _cancelCallbacks.toList(growable: false);
    _cancelCallbacks.clear();
    for (final callback in callbacks) {
      callback();
    }
    for (final sub in subscriptions) {
      unawaited(sub.cancel());
    }
    for (final requestId in requestIds) {
      unawaited(_plugin.cancel(requestId));
    }
  }

  /// Marks this transport permanently closed and cancels only its own active
  /// request IDs via [OnDeviceAiPlugin.cancel].
  ///
  /// Note: This method must NOT call [MergelineOnDeviceAi.close] because the
  /// plugin's `close()` is process-wide (closing the shared event stream and
  /// native model for every caller). Process-wide plugin teardown is reserved
  /// for MR 3's consent withdrawal flow.
  void close() {
    if (_closed) return;
    _closed = true;
    cancelActive();
  }

  /// Sends [plan]. Its content must already be redacted by the runner: this
  /// never redacts or rewrites it. The runner's single assembly, bound with
  /// [bindOnDevicePrompt], is sent as is; an unbound plan is assembled here
  /// and refused (`contextTooLong`) where it would need a cut.
  ///
  /// [redactor] (else the runner's, else the built-in patterns) only checks:
  /// if any outgoing plain value changes under `redactSource`, nothing is
  /// sent (`policyBlocked`, notSent).
  Future<AiDecodedTurn> complete(
    AiRequestPlan plan, {
    void Function(AiEvent)? onEvent,
    Redactor? redactor,
  }) async {
    if (_closed) {
      throw const AiFailure(AiFailureKind.cancelled, notSent: true);
    }
    final bound = boundOnDevicePrompt(plan);
    final assembled =
        bound?.prompt ?? assembleOnDevicePrompt(plan, redactor: redactor);
    final checker =
        redactor ??
        bound?.redactor ??
        Redactor(secrets: const _NoKnownSecrets());
    if (!_alreadyRedacted(assembled, checker)) {
      throw const AiFailure(
        AiFailureKind.policyBlocked,
        notSent: true,
        requiresNewSegment: true,
      );
    }
    final callGeneration = _generationId;
    try {
      return await _runAttempt(
        assembled,
        callGeneration: callGeneration,
        allowBusyRetry: true,
        onEvent: onEvent,
      );
    } on _OnDeviceBusyRetry {
      if (_closed || callGeneration != _generationId) {
        throw const AiFailure(AiFailureKind.cancelled, notSent: true);
      }
      await _waitInterruptibly(busyRetryDelay, callGeneration);
      if (_closed || callGeneration != _generationId) {
        throw const AiFailure(AiFailureKind.cancelled, notSent: true);
      }
      return _runAttempt(
        assembled,
        callGeneration: callGeneration,
        allowBusyRetry: false,
        onEvent: onEvent,
      );
    }
  }

  Future<void> _waitInterruptibly(Duration delay, int callGeneration) {
    final completer = Completer<void>();
    void onCancelled() {
      if (!completer.isCompleted) {
        completer.completeError(
          const AiFailure(AiFailureKind.cancelled, notSent: true),
        );
      }
    }

    _cancelCallbacks.add(onCancelled);
    _wait(delay).then(
      (_) {
        _cancelCallbacks.remove(onCancelled);
        if (!completer.isCompleted) {
          if (_closed || callGeneration != _generationId) {
            completer.completeError(
              const AiFailure(AiFailureKind.cancelled, notSent: true),
            );
          } else {
            completer.complete();
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _cancelCallbacks.remove(onCancelled);
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );
    return completer.future;
  }

  Future<AiDecodedTurn> _runAttempt(
    OnDeviceAssembledPrompt assembled, {
    required int callGeneration,
    required bool allowBusyRetry,
    void Function(AiEvent)? onEvent,
  }) {
    if (_closed || callGeneration != _generationId) {
      return Future<AiDecodedTurn>.error(
        const AiFailure(AiFailureKind.cancelled, notSent: true),
      );
    }
    final OnDeviceGenerationStream stream;
    try {
      stream = _plugin.generate(
        system: assembled.system,
        turns: assembled.turns,
        maxOutputTokens: assembled.maxOutputTokens,
      );
    } on OnDeviceAiException catch (error) {
      if (error.code == OnDeviceAiErrorCode.busy && allowBusyRetry) {
        return Future<AiDecodedTurn>.error(const _OnDeviceBusyRetry());
      }
      return Future<AiDecodedTurn>.error(
        mapOnDeviceAiException(error, notSent: true),
      );
    } on AiFailure catch (error) {
      return Future<AiDecodedTurn>.error(error);
    } on Object {
      return Future<AiDecodedTurn>.error(
        const AiFailure(AiFailureKind.onDeviceError, notSent: true),
      );
    }

    final requestId = stream.requestId;
    _activeRequestIds.add(requestId);
    final completer = Completer<AiDecodedTurn>();
    final buffer = StringBuffer();
    var started = false;
    var receivedAnyChunk = false;
    StreamSubscription<String>? sub;

    void cleanup() {
      _activeRequestIds.remove(requestId);
      if (sub != null) {
        _activeSubscriptions.remove(sub);
      }
    }

    void onCancelled() {
      cleanup();
      if (!completer.isCompleted) {
        completer.completeError(
          AiFailure(AiFailureKind.cancelled, notSent: !receivedAnyChunk),
        );
      }
    }

    _cancelCallbacks.add(onCancelled);

    sub = stream.listen(
      (String chunk) {
        if (_closed ||
            callGeneration != _generationId ||
            completer.isCompleted) {
          return;
        }
        try {
          if (!started) {
            started = true;
            onEvent?.call(const AiStarted());
          }
          if (chunk.isNotEmpty) {
            receivedAnyChunk = true;
            buffer.write(chunk);
            onEvent?.call(AiTextDelta(chunk));
          }
        } on Object catch (error, stackTrace) {
          _cancelCallbacks.remove(onCancelled);
          cleanup();
          unawaited(sub?.cancel());
          unawaited(_plugin.cancel(requestId));
          if (!completer.isCompleted) {
            completer.completeError(
              error is AiFailure
                  ? error
                  : const AiFailure(AiFailureKind.onDeviceError),
              stackTrace,
            );
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _cancelCallbacks.remove(onCancelled);
        cleanup();
        if (completer.isCompleted) return;
        if (_closed || callGeneration != _generationId) {
          completer.completeError(
            AiFailure(AiFailureKind.cancelled, notSent: !receivedAnyChunk),
          );
          return;
        }
        if (error is OnDeviceAiException) {
          if (error.code == OnDeviceAiErrorCode.busy &&
              allowBusyRetry &&
              !receivedAnyChunk) {
            completer.completeError(const _OnDeviceBusyRetry());
            return;
          }
          completer.completeError(
            mapOnDeviceAiException(error, notSent: !receivedAnyChunk),
            stackTrace,
          );
          return;
        }
        if (error is AiFailure) {
          completer.completeError(error, stackTrace);
          return;
        }
        completer.completeError(
          AiFailure(AiFailureKind.onDeviceError, notSent: !receivedAnyChunk),
          stackTrace,
        );
      },
      onDone: () {
        _cancelCallbacks.remove(onCancelled);
        cleanup();
        if (completer.isCompleted) return;
        if (_closed || callGeneration != _generationId) {
          completer.completeError(
            AiFailure(AiFailureKind.cancelled, notSent: !receivedAnyChunk),
          );
          return;
        }
        if (!receivedAnyChunk) {
          // An empty reply is never a complete answer.
          completer.completeError(
            const AiFailure(AiFailureKind.onDeviceError, notSent: true),
          );
          return;
        }
        try {
          final fullText = buffer.toString();
          final usage = AiUsage(
            inputTokens: assembled.estimatedInputTokens,
            outputTokens: estimateOnDeviceTokens(fullText),
          );
          if (!started) {
            started = true;
            onEvent?.call(const AiStarted());
          }
          onEvent?.call(AiFinished(AiStopReason.endTurn, usage: usage));
          completer.complete(
            AiDecodedTurn(
              ProviderOutputEntry(AiFormat.onDevicePrompt, <String, Object?>{
                'role': 'assistant',
                'content': fullText,
              }, toolCalls: const <AiToolCall>[]),
              AiStopReason.endTurn,
              usage,
            ),
          );
        } on Object catch (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(
              error is AiFailure
                  ? error
                  : const AiFailure(AiFailureKind.onDeviceError),
              stackTrace,
            );
          }
        }
      },
      cancelOnError: true,
    );
    _activeSubscriptions.add(sub);
    return completer.future;
  }
}
