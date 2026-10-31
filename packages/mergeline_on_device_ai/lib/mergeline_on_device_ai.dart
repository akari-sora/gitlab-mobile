import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Pre-consent device capability state returned by
/// [MergelineOnDeviceAi.deviceSupport].
enum OnDeviceSupportState {
  likely,
  unsupported,
  unknown,
}

/// Pre-consent device capability check result from
/// [MergelineOnDeviceAi.deviceSupport].
///
/// Unlike [OnDeviceStatus], obtaining [OnDeviceSupport] never touches or
/// initializes any Google ML Kit class.
@immutable
class OnDeviceSupport {
  const OnDeviceSupport({
    required this.state,
    this.reason,
    this.debugMessage,
  });

  const OnDeviceSupport.likely({
    this.debugMessage,
  }) : state = OnDeviceSupportState.likely,
       reason = null;

  const OnDeviceSupport.unsupported({
    String this.reason = 'unsupported',
    this.debugMessage,
  }) : state = OnDeviceSupportState.unsupported;

  const OnDeviceSupport.unknown({
    this.reason,
    this.debugMessage,
  }) : state = OnDeviceSupportState.unknown;

  final OnDeviceSupportState state;

  /// Machine-readable reason when [state] is [OnDeviceSupportState.unsupported]
  /// (for example `not_android`, `sdk_too_old`, `aicore_missing`, or
  /// `aicore_disabled`).
  final String? reason;

  /// Non-UI diagnostic detail from the native layer.
  final String? debugMessage;

  bool get isLikely => state == OnDeviceSupportState.likely;
  bool get isUnsupported => state == OnDeviceSupportState.unsupported;
  bool get isUnknown => state == OnDeviceSupportState.unknown;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OnDeviceSupport &&
          other.state == state &&
          other.reason == reason &&
          other.debugMessage == debugMessage;

  @override
  int get hashCode => Object.hash(state, reason, debugMessage);

  @override
  String toString() =>
      'OnDeviceSupport(state: ${state.name}, reason: $reason)';
}

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
  String toString() =>
      'OnDeviceTurn(role: ${role.name}, text: ${text.length} chars)';
}

/// Typed error codes for on-device AI operations.
///
/// The native layer maps `GenAiException.ErrorCode` integers to canonical
/// string codes; [fromNative] maps those string codes only, while
/// [OnDeviceAiException.nativeErrorCode] retains the numeric code as
/// non-UI debug information.
enum OnDeviceAiErrorCode {
  unsupported,
  notDownloaded,
  insufficientStorage,
  backgroundBlocked,
  busy,
  quotaExceeded,
  inputTooLong,
  invalidArgument,
  cancelled,
  other;

  static OnDeviceAiErrorCode fromNative(String? rawCode) {
    final normalized = rawCode?.trim();
    if (normalized == null || normalized.isEmpty) {
      return OnDeviceAiErrorCode.other;
    }
    switch (normalized) {
      case 'unsupported':
      case 'not_supported':
      case 'NOT_SUPPORTED':
      case 'NOT_AVAILABLE_UNSUPPORTED':
      case 'AICORE_INCOMPATIBLE':
      case 'NEEDS_SYSTEM_UPDATE':
      case 'sdk_too_old':
      case 'not_android':
      case 'on_device_unavailable':
        return OnDeviceAiErrorCode.unsupported;
      case 'notDownloaded':
      case 'not_downloaded':
      case 'NOT_DOWNLOADED':
      case 'NOT_AVAILABLE':
      case 'DOWNLOAD_FAILURE':
      case 'NEEDS_DOWNLOAD':
      case 'DOWNLOADING':
      case 'on_device_model_not_ready':
        return OnDeviceAiErrorCode.notDownloaded;
      case 'insufficientStorage':
      case 'insufficient_storage':
      case 'NOT_ENOUGH_DISK_SPACE':
        return OnDeviceAiErrorCode.insufficientStorage;
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
      case 'invalidArgument':
      case 'invalid_argument':
      case 'INVALID_ARGUMENT':
        return OnDeviceAiErrorCode.invalidArgument;
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
      nativeCode = MergelineOnDeviceAi._asInt(details['nativeErrorCode']);
    }
    return OnDeviceAiException(
      OnDeviceAiErrorCode.fromNative(error.code),
      debugMessage: error.message,
      nativeErrorCode: nativeCode,
    );
  }

  final OnDeviceAiErrorCode code;

  /// Non-UI debug message from the native exception.
  final String? debugMessage;

  /// Optional raw integer `GenAiException.ErrorCode` kept as debug info.
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
/// Before asking the user for consent, call [deviceSupport], which checks
/// `SDK_INT >= 26` and queries `PackageManager` for `com.google.android.aicore`
/// without touching or initializing any Google ML Kit class.
///
/// Calling [status], [download], or [generate] initializes Google ML Kit
/// (`MlKit.initialize`), which sends diagnostics and usage analytics
/// (including per-installation identifiers) to Google
/// (https://developers.google.com/ml-kit/android-data-disclosure). Call those
/// methods only after the user explicitly opts in (never at app startup or in
/// Demo mode).
///
/// Calling [close] cancels active work and releases the native
/// `GenerativeModel`, but Google ML Kit (`MlKitContext`) cannot be
/// de-initialized once initialized in the current process, and `datatransport`
/// may still upload queued diagnostics after consent is withdrawn. MR 3 must
/// explain this in its consent disclosure text.
class MergelineOnDeviceAi {
  @visibleForTesting
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

  static final String _isolateNonce = _createIsolateNonce();
  static int _requestCounter = 0;

  static StreamController<Object?>? _multiplexer;
  static StreamSubscription<Object?>? _eventSubscription;
  static EventChannel? _subscribedEventChannel;
  static int _activeListeners = 0;
  static bool _closing = false;

  static bool _defaultIsAndroid() => !kIsWeb && Platform.isAndroid;

  static String _createIsolateNonce() {
    Random random;
    try {
      random = Random.secure();
    } on UnsupportedError {
      random = Random();
    }
    final high = random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0');
    final low = random.nextInt(0x100000000).toRadixString(16, ).padLeft(8, '0');
    return '$high$low';
  }

  static String _nextRequestId(String prefix) =>
      '${prefix}_${_isolateNonce}_${++_requestCounter}';

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
    if (_eventSubscription != null &&
        _subscribedEventChannel?.name == _eventChannel.name &&
        _subscribedEventChannel?.binaryMessenger ==
            _eventChannel.binaryMessenger) {
      return;
    }
    final controller = _multiplexer;
    if (controller == null) {
      return;
    }
    final previous = _eventSubscription;
    _eventSubscription = null;
    if (previous != null) {
      unawaited(previous.cancel());
    }
    _subscribedEventChannel = _eventChannel;
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
      onDone: () {
        _eventSubscription = null;
        _subscribedEventChannel = null;
        if (!controller.isClosed) {
          unawaited(controller.close());
        }
      },
    );
  }

  static void _releaseEventSubscription() {
    if (_activeListeners > 0) {
      _activeListeners--;
    }
    if (_activeListeners == 0) {
      final sub = _eventSubscription;
      _eventSubscription = null;
      _subscribedEventChannel = null;
      if (sub != null) {
        unawaited(sub.cancel());
      }
    }
  }

  /// Checks whether this device is likely to support on-device AI without
  /// touching or initializing any Google ML Kit class.
  ///
  /// Checks `SDK_INT >= 26`, then uses `PackageManager` to see whether
  /// `com.google.android.aicore` is installed and enabled, returning
  /// [OnDeviceSupport.likely], [OnDeviceSupport.unsupported], or
  /// [OnDeviceSupport.unknown].
  ///
  /// The app must call [deviceSupport] before asking the user for consent, and
  /// call [status] only after the user agrees.
  ///
  /// On non-Android platforms, returns `unsupported(reason: 'not_android')`
  /// without invoking platform channels.
  Future<OnDeviceSupport> deviceSupport() async {
    if (!_isAndroid()) {
      return const OnDeviceSupport.unsupported(reason: 'not_android');
    }
    try {
      final raw = await _methodChannel.invokeMethod<Object?>('deviceSupport');
      if (raw is! Map<Object?, Object?>) {
        return const OnDeviceSupport.unknown();
      }
      final supportStr =
          _asString(raw['support']) ?? _asString(raw['state']);
      final reason = _asString(raw['reason']);
      final debugMessage = _asString(raw['debugMessage']);
      switch (supportStr) {
        case 'likely':
          return OnDeviceSupport.likely(debugMessage: debugMessage);
        case 'unsupported':
          return OnDeviceSupport.unsupported(
            reason: reason ?? 'unsupported',
            debugMessage: debugMessage,
          );
        case 'unknown':
        default:
          return OnDeviceSupport.unknown(
            reason: reason,
            debugMessage: debugMessage,
          );
      }
    } on MissingPluginException {
      return const OnDeviceSupport.unknown(reason: 'missing_plugin');
    } on PlatformException catch (error) {
      return OnDeviceSupport.unknown(
        reason: error.code.isNotEmpty ? error.code : null,
        debugMessage: error.message,
      );
    }
  }

  /// Queries the current AICore / Gemini Nano status on this device.
  ///
  /// Calling this method on Android (API 26+) lazily initializes Google ML Kit,
  /// which sends diagnostics to Google. Call [deviceSupport] before asking for
  /// consent, and call [status] only after the user agrees.
  ///
  /// Throws [OnDeviceAiException] with [OnDeviceAiErrorCode.other] if the
  /// platform channel returns a malformed payload with unexpected types.
  ///
  /// On non-Android platforms, returns `unavailable` with reason `not_android`
  /// without invoking platform channels.
  Future<OnDeviceStatus> status() async {
    if (!_isAndroid()) {
      return const OnDeviceStatus.unavailable(reason: 'not_android');
    }
    try {
      final raw = await _methodChannel.invokeMethod<Object?>('status');
      if (raw is! Map<Object?, Object?>) {
        throw const OnDeviceAiException(
          OnDeviceAiErrorCode.other,
          debugMessage: 'Invalid status payload: expected a Map',
        );
      }
      final statusStr = _requireOptionalString(raw, 'status');
      final reason = _requireOptionalString(raw, 'reason');
      final modelName = _requireOptionalString(raw, 'modelName');
      final debugMessage = _requireOptionalString(raw, 'debugMessage');
      if (statusStr == null) {
        throw const OnDeviceAiException(
          OnDeviceAiErrorCode.other,
          debugMessage: 'Invalid status payload: missing status',
        );
      }
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
          return OnDeviceStatus.unavailable(
            reason: reason ?? 'unsupported',
            debugMessage: debugMessage,
          );
        default:
          throw OnDeviceAiException(
            OnDeviceAiErrorCode.other,
            debugMessage: 'Unknown status value: $statusStr',
          );
      }
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
    final requestId = _nextRequestId('download');
    late final StreamController<OnDeviceDownloadEvent> controller;
    StreamSubscription<Object?>? sub;
    var finished = false;
    var resolvingCompletion = false;
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

    Future<void> resolveMissingTerminalEvent() async {
      if (finished || resolvingCompletion) {
        return;
      }
      if (_closing) {
        closeCleanly();
        return;
      }
      resolvingCompletion = true;
      try {
        final currentStatus = await status();
        if (finished) {
          return;
        }
        if (currentStatus.isAvailable) {
          controller.add(const OnDeviceDownloadEvent.completed());
        } else {
          controller.add(
            const OnDeviceDownloadEvent.failed(
              OnDeviceAiException(
                OnDeviceAiErrorCode.other,
                debugMessage:
                    'Download flow completed without a terminal event',
              ),
            ),
          );
        }
      } catch (error) {
        if (finished) {
          return;
        }
        final mapped = error is OnDeviceAiException
            ? error
            : OnDeviceAiException(
                OnDeviceAiErrorCode.other,
                debugMessage: error.toString(),
              );
        controller.add(OnDeviceDownloadEvent.failed(mapped));
      } finally {
        closeCleanly();
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
            final eventKind = _asString(raw['event']);
            if (eventKind != null && eventKind != 'download') {
              return;
            }
            final eventRequestId = _asString(raw['requestId']);
            if (eventRequestId != null && eventRequestId != requestId) {
              return;
            }
            final state =
                _asString(raw['state']) ?? _asString(raw['type']);
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
                final codeStr = _asString(raw['code']);
                final debugMsg = _asString(raw['debugMessage']);
                final nativeCode = _asInt(raw['nativeErrorCode']);
                controller.add(
                  OnDeviceDownloadEvent.failed(
                    OnDeviceAiException(
                      OnDeviceAiErrorCode.fromNative(codeStr),
                      debugMessage: debugMsg,
                      nativeErrorCode: nativeCode,
                    ),
                  ),
                );
                closeCleanly();
              case 'done':
              case 'ended':
                unawaited(resolveMissingTerminalEvent());
            }
          },
          onError: (Object error) {
            if (finished) {
              return;
            }
            final targetId = _errorRequestId(error);
            if (targetId != null && targetId != requestId) {
              return;
            }
            final mapped = _mapChannelError(error);
            controller.add(OnDeviceDownloadEvent.failed(mapped));
            closeCleanly();
          },
          onDone: () {
            if (!finished) {
              unawaited(resolveMissingTerminalEvent());
            }
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
                  final mapped = _mapChannelError(error);
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
  /// Parameter limits:
  /// - When provided, [temperature] must be within `[0.0, 1.0]`.
  /// - When provided, [maxOutputTokens] must be strictly greater than `0`.
  /// Passing a value outside these limits synchronously throws an
  /// [OnDeviceAiException] with [OnDeviceAiErrorCode.invalidArgument].
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
    if (temperature != null &&
        (temperature.isNaN || temperature < 0.0 || temperature > 1.0)) {
      throw const OnDeviceAiException(
        OnDeviceAiErrorCode.invalidArgument,
        debugMessage: 'temperature must be between 0.0 and 1.0',
      );
    }
    if (maxOutputTokens != null && maxOutputTokens <= 0) {
      throw const OnDeviceAiException(
        OnDeviceAiErrorCode.invalidArgument,
        debugMessage: 'maxOutputTokens must be greater than 0',
      );
    }

    final resolvedId =
        (requestId != null && requestId.isNotEmpty)
            ? requestId
            : _nextRequestId('req');
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
            final eventKind = _asString(raw['event']);
            if (eventKind != null && eventKind != 'generate') {
              return;
            }
            final eventRequestId = _asString(raw['requestId']);
            if (eventRequestId != null && eventRequestId != resolvedId) {
              return;
            }
            final type = _asString(raw['type']);
            switch (type) {
              case 'chunk':
                final text = _asString(raw['text']);
                if (text != null && text.isNotEmpty) {
                  controller.add(text);
                }
              case 'done':
              case 'completed':
                closeCleanly();
              case 'error':
                final codeStr = _asString(raw['code']);
                final debugMsg = _asString(raw['debugMessage']);
                final nativeCode = _asInt(raw['nativeErrorCode']);
                controller.addError(
                  OnDeviceAiException(
                    OnDeviceAiErrorCode.fromNative(codeStr),
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
            final targetId = _errorRequestId(error);
            if (targetId != null && targetId != resolvedId) {
              return;
            }
            final mapped = _mapChannelError(error);
            controller.addError(mapped);
            closeCleanly();
          },
          onDone: () {
            if (!finished) {
              closeCleanly();
            }
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
                  final mapped = _mapChannelError(error);
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

  /// Cancels all active downloads and generations and releases the native
  /// `GenerativeModel`.
  ///
  /// Note: Google ML Kit (`MlKitContext`) cannot be de-initialized once
  /// initialized in the current process, and Google's `datatransport` runtime
  /// may still upload queued diagnostics after consent is withdrawn. MR 3 must
  /// explain this limitation in its consent text.
  Future<void> close() async {
    _closing = true;
    try {
      final sub = _eventSubscription;
      _eventSubscription = null;
      _subscribedEventChannel = null;
      _activeListeners = 0;
      if (sub != null) {
        await sub.cancel();
      }
      final controller = _multiplexer;
      _multiplexer = null;
      if (controller != null && !controller.isClosed) {
        await controller.close();
      }
    } finally {
      _closing = false;
    }
    if (!_isAndroid()) {
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>('close');
    } on MissingPluginException {
      // No-op when native plugin is not registered in headless test runners.
    } on PlatformException {
      // Best-effort release.
    }
  }

  static String? _errorRequestId(Object error) {
    if (error is PlatformException) {
      final details = error.details;
      if (details is Map<Object?, Object?>) {
        final id = details['requestId'];
        if (id is String && id.isNotEmpty) {
          return id;
        }
      }
    }
    return null;
  }

  static OnDeviceAiException _mapChannelError(Object error) {
    if (error is OnDeviceAiException) {
      return error;
    }
    if (error is PlatformException) {
      return OnDeviceAiException.fromPlatformException(error);
    }
    return OnDeviceAiException(
      OnDeviceAiErrorCode.other,
      debugMessage: error.toString(),
    );
  }

  static String? _requireOptionalString(
    Map<Object?, Object?> map,
    String key,
  ) {
    final value = map[key];
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value;
    }
    throw OnDeviceAiException(
      OnDeviceAiErrorCode.other,
      debugMessage: 'Invalid status payload field type for $key',
    );
  }

  static String? _asString(Object? value) {
    if (value is String) {
      return value;
    }
    return null;
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
