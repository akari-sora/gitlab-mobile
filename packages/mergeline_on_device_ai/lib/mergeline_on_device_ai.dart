import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Availability state reported by Android AICore / ML Kit GenAI Prompt.
enum OnDeviceAvailability {
  unavailable,
  downloadable,
  downloading,
  available,
}

/// Current status of the on-device Gemini Nano model.
@immutable
class OnDeviceStatus {
  const OnDeviceStatus({
    required this.availability,
    this.reason,
    this.modelName,
    this.debugMessage,
  });

  const OnDeviceStatus.unavailable({
    this.reason = 'unsupported',
    this.debugMessage,
  }) : availability = OnDeviceAvailability.unavailable,
       modelName = null;

  const OnDeviceStatus.downloadable({
    this.reason,
    this.modelName,
    this.debugMessage,
  }) : availability = OnDeviceAvailability.downloadable;

  const OnDeviceStatus.downloading({
    this.reason,
    this.modelName,
    this.debugMessage,
  }) : availability = OnDeviceAvailability.downloading;

  const OnDeviceStatus.available({
    this.modelName,
    this.debugMessage,
  }) : availability = OnDeviceAvailability.available,
       reason = null;

  final OnDeviceAvailability availability;

  /// Alias for [availability].
  OnDeviceAvailability get state => availability;

  /// Machine-readable unavailability reason, e.g. `sdk_too_old`,
  /// `not_android`, or `unsupported`.
  final String? reason;

  /// Optional base model identifier reported by AICore when available.
  final String? modelName;

  /// Non-UI diagnostic detail from the native layer.
  final String? debugMessage;

  bool get isUnavailable => availability == OnDeviceAvailability.unavailable;
  bool get isDownloadable => availability == OnDeviceAvailability.downloadable;
  bool get isDownloading => availability == OnDeviceAvailability.downloading;
  bool get isAvailable => availability == OnDeviceAvailability.available;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OnDeviceStatus &&
          other.availability == availability &&
          other.reason == reason &&
          other.modelName == modelName &&
          other.debugMessage == debugMessage;

  @override
  int get hashCode =>
      Object.hash(availability, reason, modelName, debugMessage);

  @override
  String toString() =>
      'OnDeviceStatus(availability: ${availability.name}, '
      'reason: $reason, modelName: $modelName)';
}

/// Speaker role for a prompt conversation turn.
enum OnDeviceRole {
  user,
  model,
}

/// Single conversation turn passed to [MergelineOnDeviceAi.generate].
@immutable
class OnDeviceTurn {
  const OnDeviceTurn({
    required this.role,
    required this.text,
  });

  const OnDeviceTurn.user(this.text) : role = OnDeviceRole.user;

  const OnDeviceTurn.model(this.text) : role = OnDeviceRole.model;

  final OnDeviceRole role;
  final String text;

  Map<String, Object?> toMap() => <String, Object?>{
    'role': role.name,
    'text': text,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OnDeviceTurn && other.role == role && other.text == text;

  @override
  int get hashCode => Object.hash(role, text);

  @override
  String toString() => 'OnDeviceTurn(role: ${role.name}, text: ${text.length} chars)';
}

/// Typed error codes mapped from `com.google.mlkit.genai.common.GenAiException`.
enum OnDeviceAiErrorCode {
  unsupported,
  notDownloaded,
  backgroundBlocked,
  busy,
  quotaExceeded,
  inputTooLong,
  cancelled,
  other;

  static OnDeviceAiErrorCode fromNative(
    String? rawCode, {
    int? nativeErrorCode,
  }) {
    if (nativeErrorCode != null) {
      switch (nativeErrorCode) {
        case 7:
          return OnDeviceAiErrorCode.cancelled;
        case 8:
        case 501:
          if (rawCode == 'unsupported' || rawCode == 'NOT_AVAILABLE_UNSUPPORTED') {
            return OnDeviceAiErrorCode.unsupported;
          }
          return OnDeviceAiErrorCode.notDownloaded;
        case 9:
          return OnDeviceAiErrorCode.busy;
        case 12:
        case -112:
          return OnDeviceAiErrorCode.inputTooLong;
        case 16:
        case -101:
        case 604:
          return OnDeviceAiErrorCode.unsupported;
        case 27:
          return OnDeviceAiErrorCode.quotaExceeded;
        case 30:
          return OnDeviceAiErrorCode.backgroundBlocked;
      }
    }
    final normalized = rawCode?.trim();
    if (normalized == null || normalized.isEmpty) {
      return OnDeviceAiErrorCode.other;
    }
    switch (normalized) {
      case 'unsupported':
      case 'not_supported':
      case 'NOT_SUPPORTED':
      case 'NOT_AVAILABLE':
      case 'AICORE_INCOMPATIBLE':
      case 'NEEDS_SYSTEM_UPDATE':
      case 'sdk_too_old':
      case 'not_android':
      case 'on_device_unavailable':
        return OnDeviceAiErrorCode.unsupported;
      case 'notDownloaded':
      case 'not_downloaded':
      case 'NOT_DOWNLOADED':
      case 'NOT_ENOUGH_DISK_SPACE':
      case 'DOWNLOAD_FAILURE':
      case 'NEEDS_DOWNLOAD':
      case 'DOWNLOADING':
      case 'on_device_model_not_ready':
        return OnDeviceAiErrorCode.notDownloaded;
      case 'backgroundBlocked':
      case 'background_blocked':
      case 'BACKGROUND_USE_BLOCKED':
      case 'on_device_foreground_only':
        return OnDeviceAiErrorCode.backgroundBlocked;
      case 'busy':
      case 'BUSY':
      case 'on_device_busy':
        return OnDeviceAiErrorCode.busy;
      case 'quotaExceeded':
      case 'quota_exceeded':
      case 'PER_APP_BATTERY_USE_QUOTA_EXCEEDED':
      case 'on_device_quota_exceeded':
        return OnDeviceAiErrorCode.quotaExceeded;
      case 'inputTooLong':
      case 'input_too_long':
      case 'REQUEST_TOO_LARGE':
      case 'MAX_TURNS_EXCEEDED':
      case 'CONTEXT_TOO_LONG':
      case 'context_too_long':
        return OnDeviceAiErrorCode.inputTooLong;
      case 'cancelled':
      case 'canceled':
      case 'CANCELLED':
        return OnDeviceAiErrorCode.cancelled;
      case 'other':
      default:
        return OnDeviceAiErrorCode.other;
    }
  }
}

/// Exception thrown or emitted when an on-device AI operation fails.
///
/// [debugMessage] holds raw native diagnostic text for non-UI logging only
/// and must never be displayed directly in user-facing widgets.
@immutable
class OnDeviceAiException implements Exception {
  const OnDeviceAiException(
    this.code, {
    this.debugMessage,
    this.nativeErrorCode,
  });

  factory OnDeviceAiException.fromPlatformException(PlatformException error) {
    final details = error.details;
    int? nativeCode;
    if (details is Map<Object?, Object?>) {
      final rawNative = details['nativeErrorCode'];
      if (rawNative is int) {
        nativeCode = rawNative;
      }
    }
    return OnDeviceAiException(
      OnDeviceAiErrorCode.fromNative(
        error.code,
        nativeErrorCode: nativeCode,
      ),
      debugMessage: error.message,
      nativeErrorCode: nativeCode,
    );
  }

  final OnDeviceAiErrorCode code;

  /// Non-UI debug message from the native exception.
  final String? debugMessage;

  /// Optional raw integer `GenAiException.ErrorCode`.
  final int? nativeErrorCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OnDeviceAiException &&
          other.code == code &&
          other.debugMessage == debugMessage &&
          other.nativeErrorCode == nativeErrorCode;

  @override
  int get hashCode => Object.hash(code, debugMessage, nativeErrorCode);

  @override
  String toString() =>
      'OnDeviceAiException(code: ${code.name}, nativeErrorCode: $nativeErrorCode)';
}

/// Lifecycle state of an on-device model download.
enum OnDeviceDownloadState {
  started,
  progress,
  completed,
  failed,
}

/// Event emitted by [MergelineOnDeviceAi.download].
@immutable
class OnDeviceDownloadEvent {
  const OnDeviceDownloadEvent({
    required this.state,
    this.bytesToDownload,
    this.bytesDownloaded,
    this.error,
  });

  const OnDeviceDownloadEvent.started({
    this.bytesToDownload,
  }) : state = OnDeviceDownloadState.started,
       bytesDownloaded = 0,
       error = null;

  const OnDeviceDownloadEvent.progress({
    required int this.bytesDownloaded,
    this.bytesToDownload,
  }) : state = OnDeviceDownloadState.progress,
       error = null;

  const OnDeviceDownloadEvent.completed()
    : state = OnDeviceDownloadState.completed,
      bytesToDownload = null,
      bytesDownloaded = null,
      error = null;

  const OnDeviceDownloadEvent.failed(
    OnDeviceAiException this.error,
  ) : state = OnDeviceDownloadState.failed,
      bytesToDownload = null,
      bytesDownloaded = null;

  final OnDeviceDownloadState state;

  /// Alias for [state].
  OnDeviceDownloadState get type => state;

  final int? bytesToDownload;
  final int? bytesDownloaded;
  final OnDeviceAiException? error;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OnDeviceDownloadEvent &&
          other.state == state &&
          other.bytesToDownload == bytesToDownload &&
          other.bytesDownloaded == bytesDownloaded &&
          other.error == error;

  @override
  int get hashCode =>
      Object.hash(state, bytesToDownload, bytesDownloaded, error);

  @override
  String toString() =>
      'OnDeviceDownloadEvent(state: ${state.name}, '
      'bytesDownloaded: $bytesDownloaded, bytesToDownload: $bytesToDownload, '
      'error: $error)';
}

/// A [Stream] of text chunks from [MergelineOnDeviceAi.generate] that also
/// exposes its [requestId] for [MergelineOnDeviceAi.cancel].
class OnDeviceGenerationStream extends StreamView<String> {
  OnDeviceGenerationStream({
    required this.requestId,
    required Stream<String> stream,
  }) : super(stream);

  final String requestId;
}

/// Flutter bridge to Android's ML Kit GenAI Prompt API (Gemini Nano).
///
/// Calling any method ([status], [download], or [generate]) initializes Google
/// ML Kit (`MlKit.initialize`), which sends diagnostics and usage analytics
/// (including per-installation identifiers) to Google
/// (https://developers.google.com/ml-kit/android-data-disclosure).
///
/// The app must call methods on [MergelineOnDeviceAi] only after the user
/// explicitly opts in (never at app startup or in Demo mode). Constructing
/// [MergelineOnDeviceAi] or accessing [instance] makes no platform channel
/// calls and does not initialize ML Kit.
class MergelineOnDeviceAi {
  MergelineOnDeviceAi({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    bool Function()? isAndroid,
  }) : _methodChannel = methodChannel ?? const MethodChannel(methodChannelName),
       _eventChannel = eventChannel ?? const EventChannel(eventChannelName),
       _isAndroid = isAndroid ?? _defaultIsAndroid;

  static const String methodChannelName = 'io.gitlabmobile/on_device_ai';
  static const String eventChannelName = 'io.gitlabmobile/on_device_ai/events';

  static final MergelineOnDeviceAi instance = MergelineOnDeviceAi();

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final bool Function() _isAndroid;

  int _requestCounter = 0;
  String? _lastRequestId;

  /// Most recent request identifier created by [generate].
  String? get lastRequestId => _lastRequestId;

  StreamController<Object?>? _multiplexer;
  StreamSubscription<Object?>? _eventSubscription;
  int _activeListeners = 0;

  static bool _defaultIsAndroid() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Stream<Object?> _sharedEventStream() {
    var controller = _multiplexer;
    if (controller == null || controller.isClosed) {
      controller = StreamController<Object?>.broadcast();
      _multiplexer = controller;
    }
    return controller.stream;
  }

  void _retainEventSubscription() {
    _activeListeners++;
    if (_eventSubscription != null) {
      return;
    }
    final controller = _multiplexer;
    if (controller == null) {
      return;
    }
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (Object? event) {
        if (!controller.isClosed) {
          controller.add(event);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
        }
      },
    );
  }

  void _releaseEventSubscription() {
    if (_activeListeners > 0) {
      _activeListeners--;
    }
    if (_activeListeners == 0) {
      final sub = _eventSubscription;
      _eventSubscription = null;
      if (sub != null) {
        unawaited(sub.cancel());
      }
    }
  }

  /// Queries the current AICore / Gemini Nano status on this device.
  ///
  /// Calling this method on Android (API 26+) lazily initializes Google ML Kit,
  /// which sends diagnostics to Google. Call only after the user opts in.
  ///
  /// On non-Android platforms, returns `unavailable` with reason `not_android`
  /// without invoking platform channels.
  Future<OnDeviceStatus> status() async {
    if (!_isAndroid()) {
      return const OnDeviceStatus.unavailable(reason: 'not_android');
    }
    try {
      final raw = await _methodChannel.invokeMethod<Object?>('status');
      if (raw is Map<Object?, Object?>) {
        final statusStr = raw['status'] as String?;
        final reason = raw['reason'] as String?;
        final modelName = raw['modelName'] as String?;
        final debugMessage = raw['debugMessage'] as String?;
        switch (statusStr) {
          case 'available':
            return OnDeviceStatus.available(
              modelName: modelName,
              debugMessage: debugMessage,
            );
          case 'downloadable':
            return OnDeviceStatus.downloadable(
              reason: reason,
              modelName: modelName,
              debugMessage: debugMessage,
            );
          case 'downloading':
            return OnDeviceStatus.downloading(
              reason: reason,
              modelName: modelName,
              debugMessage: debugMessage,
            );
          case 'unavailable':
          default:
            return OnDeviceStatus.unavailable(
              reason: reason ?? 'unsupported',
              debugMessage: debugMessage,
            );
        }
      }
      return const OnDeviceStatus.unavailable(reason: 'unsupported');
    } on MissingPluginException {
      return const OnDeviceStatus.unavailable(reason: 'unsupported');
    } on PlatformException catch (error) {
      return OnDeviceStatus.unavailable(
        reason: error.code.isNotEmpty ? error.code : 'unsupported',
        debugMessage: error.message,
      );
    }
  }

  /// Starts or attaches to an on-device model download and streams
  /// [OnDeviceDownloadEvent] updates.
  ///
  /// Listening to the returned stream on Android (API 26+) lazily initializes
  /// Google ML Kit, which sends diagnostics to Google. Call only after the user
  /// opts in.
  ///
  /// On non-Android platforms, returns an empty stream without throwing.
  Stream<OnDeviceDownloadEvent> download() {
    if (!_isAndroid()) {
      return const Stream<OnDeviceDownloadEvent>.empty();
    }
    final requestId = 'download_${++_requestCounter}';
    late final StreamController<OnDeviceDownloadEvent> controller;
    StreamSubscription<Object?>? sub;
    var finished = false;
    int? lastTotalBytes;

    void closeCleanly() {
      if (finished) {
        return;
      }
      finished = true;
      final activeSub = sub;
      sub = null;
      if (activeSub != null) {
        unawaited(activeSub.cancel());
      }
      _releaseEventSubscription();
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
    }

    controller = StreamController<OnDeviceDownloadEvent>(
      onListen: () {
        final bus = _sharedEventStream();
        _retainEventSubscription();
        sub = bus.listen(
          (Object? raw) {
            if (finished || raw is! Map<Object?, Object?>) {
              return;
            }
            final eventKind = raw['event'] as String?;
            if (eventKind != null && eventKind != 'download') {
              return;
            }
            final eventRequestId = raw['requestId'] as String?;
            if (eventRequestId != null && eventRequestId != requestId) {
              return;
            }
            final state = (raw['state'] ?? raw['type']) as String?;
            switch (state) {
              case 'started':
              case 'download_started':
                final total = _asInt(raw['bytesToDownload']);
                if (total != null) {
                  lastTotalBytes = total;
                }
                controller.add(
                  OnDeviceDownloadEvent.started(bytesToDownload: total),
                );
              case 'progress':
              case 'download_progress':
                final downloaded = _asInt(raw['bytesDownloaded']) ?? 0;
                final total = _asInt(raw['bytesToDownload']) ?? lastTotalBytes;
                if (total != null) {
                  lastTotalBytes = total;
                }
                controller.add(
                  OnDeviceDownloadEvent.progress(
                    bytesDownloaded: downloaded,
                    bytesToDownload: total,
                  ),
                );
              case 'completed':
              case 'download_completed':
                controller.add(const OnDeviceDownloadEvent.completed());
                closeCleanly();
              case 'failed':
              case 'download_failed':
                final codeStr = raw['code'] as String?;
                final debugMsg = raw['debugMessage'] as String?;
                final nativeCode = _asInt(raw['nativeErrorCode']);
                controller.add(
                  OnDeviceDownloadEvent.failed(
                    OnDeviceAiException(
                      OnDeviceAiErrorCode.fromNative(
                        codeStr,
                        nativeErrorCode: nativeCode,
                      ),
                      debugMessage: debugMsg,
                      nativeErrorCode: nativeCode,
                    ),
                  ),
                );
                closeCleanly();
            }
          },
          onError: (Object error) {
            if (finished) {
              return;
            }
            final mapped = error is PlatformException
                ? OnDeviceAiException.fromPlatformException(error)
                : OnDeviceAiException(
                    OnDeviceAiErrorCode.notDownloaded,
                    debugMessage: error.toString(),
                  );
            controller.add(OnDeviceDownloadEvent.failed(mapped));
            closeCleanly();
          },
        );

        unawaited(
          _methodChannel
              .invokeMethod<Object?>(
                'download',
                <String, Object?>{'requestId': requestId},
              )
              .catchError((Object error) {
                if (!finished) {
                  final mapped = error is PlatformException
                      ? OnDeviceAiException.fromPlatformException(error)
                      : OnDeviceAiException(
                          OnDeviceAiErrorCode.notDownloaded,
                          debugMessage: error.toString(),
                        );
                  controller.add(OnDeviceDownloadEvent.failed(mapped));
                  closeCleanly();
                }
                return null;
              }),
        );
      },
      onCancel: () {
        final wasFinished = finished;
        closeCleanly();
        if (!wasFinished) {
          unawaited(cancel(requestId));
        }
      },
    );

    return controller.stream;
  }

  /// Streams generated text chunks for [system] and [turns].
  ///
  /// Returns an [OnDeviceGenerationStream] (which implements `Stream<String>`)
  /// exposing [OnDeviceGenerationStream.requestId] so callers can pass it to
  /// [cancel].
  ///
  /// Listening to the returned stream on Android (API 26+) lazily initializes
  /// Google ML Kit, which sends diagnostics to Google. Call only after the user
  /// opts in.
  ///
  /// On non-Android platforms, returns an empty stream without throwing.
  OnDeviceGenerationStream generate({
    required String system,
    required List<OnDeviceTurn> turns,
    int? maxOutputTokens,
    double? temperature,
    String? requestId,
    void Function(String requestId)? onRequestId,
  }) {
    final resolvedId =
        (requestId != null && requestId.isNotEmpty)
            ? requestId
            : 'req_${++_requestCounter}';
    _lastRequestId = resolvedId;
    if (onRequestId != null) {
      onRequestId(resolvedId);
    }

    if (!_isAndroid()) {
      return OnDeviceGenerationStream(
        requestId: resolvedId,
        stream: const Stream<String>.empty(),
      );
    }

    late final StreamController<String> controller;
    StreamSubscription<Object?>? sub;
    var finished = false;

    void closeCleanly() {
      if (finished) {
        return;
      }
      finished = true;
      final activeSub = sub;
      sub = null;
      if (activeSub != null) {
        unawaited(activeSub.cancel());
      }
      _releaseEventSubscription();
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
    }

    controller = StreamController<String>(
      onListen: () {
        final bus = _sharedEventStream();
        _retainEventSubscription();
        sub = bus.listen(
          (Object? raw) {
            if (finished || raw is! Map<Object?, Object?>) {
              return;
            }
            final eventKind = raw['event'] as String?;
            if (eventKind != null && eventKind != 'generate') {
              return;
            }
            final eventRequestId = raw['requestId'] as String?;
            if (eventRequestId != null && eventRequestId != resolvedId) {
              return;
            }
            final type = raw['type'] as String?;
            switch (type) {
              case 'chunk':
                final text = raw['text'] as String?;
                if (text != null && text.isNotEmpty) {
                  controller.add(text);
                }
              case 'done':
              case 'completed':
                closeCleanly();
              case 'error':
                final codeStr = raw['code'] as String?;
                final debugMsg = raw['debugMessage'] as String?;
                final nativeCode = _asInt(raw['nativeErrorCode']);
                controller.addError(
                  OnDeviceAiException(
                    OnDeviceAiErrorCode.fromNative(
                      codeStr,
                      nativeErrorCode: nativeCode,
                    ),
                    debugMessage: debugMsg,
                    nativeErrorCode: nativeCode,
                  ),
                );
                closeCleanly();
            }
          },
          onError: (Object error) {
            if (finished) {
              return;
            }
            final mapped = error is PlatformException
                ? OnDeviceAiException.fromPlatformException(error)
                : OnDeviceAiException(
                    OnDeviceAiErrorCode.other,
                    debugMessage: error.toString(),
                  );
            controller.addError(mapped);
            closeCleanly();
          },
        );

        unawaited(
          _methodChannel
              .invokeMethod<Object?>(
                'generate',
                <String, Object?>{
                  'requestId': resolvedId,
                  'system': system,
                  'turns': turns.map((OnDeviceTurn t) => t.toMap()).toList(),
                  'maxOutputTokens': maxOutputTokens,
                  'temperature': temperature,
                },
              )
              .catchError((Object error) {
                if (!finished) {
                  final mapped = error is PlatformException
                      ? OnDeviceAiException.fromPlatformException(error)
                      : OnDeviceAiException(
                          OnDeviceAiErrorCode.other,
                          debugMessage: error.toString(),
                        );
                  controller.addError(mapped);
                  closeCleanly();
                }
                return null;
              }),
        );
      },
      onCancel: () {
        final wasFinished = finished;
        closeCleanly();
        if (!wasFinished) {
          unawaited(cancel(resolvedId));
        }
      },
    );

    return OnDeviceGenerationStream(
      requestId: resolvedId,
      stream: controller.stream,
    );
  }

  /// Cancels the in-flight native generation or download identified by
  /// [requestId].
  ///
  /// On non-Android platforms, completes immediately without throwing.
  Future<void> cancel(String requestId) async {
    if (!_isAndroid()) {
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>(
        'cancel',
        <String, Object?>{'requestId': requestId},
      );
    } on MissingPluginException {
      // No-op when native plugin is not registered in headless test runners.
    } on PlatformException {
      // Cancellation is best-effort.
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
  }
}
