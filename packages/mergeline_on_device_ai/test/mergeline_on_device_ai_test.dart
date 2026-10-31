import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mergeline_on_device_ai/mergeline_on_device_ai.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(MergelineOnDeviceAi.methodChannelName);
  const eventChannel = EventChannel(MergelineOnDeviceAi.eventChannelName);

  late List<MethodCall> methodCalls;
  late Future<Object?> Function(MethodCall call) onMethodCall;
  MockStreamHandler? streamHandler;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    methodCalls = <MethodCall>[];
    onMethodCall = (MethodCall call) async => null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
          methodCalls.add(call);
          return onMethodCall(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    if (streamHandler != null) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, null);
      streamHandler = null;
    }
    debugDefaultTargetPlatformOverride = null;
  });

  group('lazy initialization', () {
    test('constructing MergelineOnDeviceAi makes no channel call', () async {
      var eventChannelListened = false;
      streamHandler = MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          eventChannelListened = true;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, streamHandler);

      final plugin = MergelineOnDeviceAi();
      final singleton = MergelineOnDeviceAi.instance;

      expect(plugin.lastRequestId, isNull);
      expect(singleton, isNotNull);
      expect(methodCalls, isEmpty);
      expect(eventChannelListened, isFalse);

      // Even creating download() or generate() streams without listening makes
      // no platform channel calls until a listener subscribes.
      final unsubscribedDownload = plugin.download();
      final unsubscribedGenerate = plugin.generate(
        system: 'System',
        turns: const <OnDeviceTurn>[OnDeviceTurn.user('Hi')],
      );
      expect(unsubscribedDownload, isA<Stream<OnDeviceDownloadEvent>>());
      expect(unsubscribedGenerate.requestId, isNotEmpty);
      expect(methodCalls, isEmpty);
      expect(eventChannelListened, isFalse);
    });
  });

  group('status()', () {
    test('maps all four availability states and reasons', () async {
      final plugin = MergelineOnDeviceAi();

      onMethodCall = (_) async => <String, Object?>{
        'status': 'available',
        'modelName': 'gemini-nano-v2',
      };
      final available = await plugin.status();
      expect(available.availability, OnDeviceAvailability.available);
      expect(available.state, OnDeviceAvailability.available);
      expect(available.isAvailable, isTrue);
      expect(available.modelName, 'gemini-nano-v2');
      expect(available.reason, isNull);

      onMethodCall = (_) async => <String, Object?>{
        'status': 'downloadable',
      };
      final downloadable = await plugin.status();
      expect(downloadable.availability, OnDeviceAvailability.downloadable);
      expect(downloadable.isDownloadable, isTrue);

      onMethodCall = (_) async => <String, Object?>{
        'status': 'downloading',
      };
      final downloading = await plugin.status();
      expect(downloading.availability, OnDeviceAvailability.downloading);
      expect(downloading.isDownloading, isTrue);

      onMethodCall = (_) async => <String, Object?>{
        'status': 'unavailable',
        'reason': 'sdk_too_old',
      };
      final sdkTooOld = await plugin.status();
      expect(sdkTooOld.availability, OnDeviceAvailability.unavailable);
      expect(sdkTooOld.isUnavailable, isTrue);
      expect(sdkTooOld.reason, 'sdk_too_old');

      onMethodCall = (_) async => <String, Object?>{
        'status': 'unavailable',
        'reason': 'unsupported',
      };
      final unsupported = await plugin.status();
      expect(unsupported.availability, OnDeviceAvailability.unavailable);
      expect(unsupported.reason, 'unsupported');
    });

    test('falls back to unavailable(unsupported) on PlatformException', () async {
      final plugin = MergelineOnDeviceAi();
      onMethodCall = (_) async {
        throw PlatformException(
          code: 'unsupported',
          message: 'AICore service missing',
        );
      };

      final status = await plugin.status();
      expect(status.availability, OnDeviceAvailability.unavailable);
      expect(status.reason, 'unsupported');
      expect(status.debugMessage, 'AICore service missing');
    });
  });

  group('download()', () {
    test('streams started, progress, and completed events', () async {
      final plugin = MergelineOnDeviceAi();
      late String capturedRequestId;

      streamHandler = MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          onMethodCall = (MethodCall call) async {
            if (call.method == 'download') {
              final args = call.arguments as Map<Object?, Object?>;
              capturedRequestId = args['requestId'] as String;
              events.success(<String, Object?>{
                'event': 'download',
                'requestId': capturedRequestId,
                'state': 'started',
                'bytesToDownload': 104857600,
              });
              events.success(<String, Object?>{
                'event': 'download',
                'requestId': capturedRequestId,
                'state': 'progress',
                'bytesDownloaded': 52428800,
              });
              events.success(<String, Object?>{
                'event': 'download',
                'requestId': capturedRequestId,
                'state': 'completed',
              });
            }
            return <String, Object?>{'requestId': capturedRequestId};
          };
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, streamHandler);

      final received = await plugin.download().toList();
      expect(received, <OnDeviceDownloadEvent>[
        const OnDeviceDownloadEvent.started(bytesToDownload: 104857600),
        const OnDeviceDownloadEvent.progress(
          bytesDownloaded: 52428800,
          bytesToDownload: 104857600,
        ),
        const OnDeviceDownloadEvent.completed(),
      ]);
    });

    test('streams failed event with mapped OnDeviceAiException', () async {
      final plugin = MergelineOnDeviceAi();

      streamHandler = MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          onMethodCall = (MethodCall call) async {
            if (call.method == 'download') {
              final args = call.arguments as Map<Object?, Object?>;
              final requestId = args['requestId'] as String;
              events.success(<String, Object?>{
                'event': 'download',
                'requestId': requestId,
                'state': 'failed',
                'code': 'notDownloaded',
                'debugMessage': 'Not enough disk space',
                'nativeErrorCode': 501,
              });
            }
            return null;
          };
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, streamHandler);

      final received = await plugin.download().toList();
      expect(received, hasLength(1));
      expect(received.single.state, OnDeviceDownloadState.failed);
      expect(received.single.error?.code, OnDeviceAiErrorCode.notDownloaded);
      expect(received.single.error?.debugMessage, 'Not enough disk space');
      expect(received.single.error?.nativeErrorCode, 501);
    });
  });

  group('generate() and cancel()', () {
    test('streams chunks and exposes requestId for cancel', () async {
      final plugin = MergelineOnDeviceAi();
      String? callbackId;

      streamHandler = MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          onMethodCall = (MethodCall call) async {
            if (call.method == 'generate') {
              final args = call.arguments as Map<Object?, Object?>;
              final requestId = args['requestId'] as String;
              // Emit an event for a different requestId first (must be ignored).
              events.success(<String, Object?>{
                'event': 'generate',
                'requestId': 'other_request',
                'type': 'chunk',
                'text': 'ignored',
              });
              events.success(<String, Object?>{
                'event': 'generate',
                'requestId': requestId,
                'type': 'chunk',
                'text': 'Hello ',
              });
              events.success(<String, Object?>{
                'event': 'generate',
                'requestId': requestId,
                'type': 'chunk',
                'text': 'world!',
              });
              events.success(<String, Object?>{
                'event': 'generate',
                'requestId': requestId,
                'type': 'done',
              });
              return <String, Object?>{'requestId': requestId};
            }
            return null;
          };
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, streamHandler);

      final stream = plugin.generate(
        system: 'Be concise.',
        turns: const <OnDeviceTurn>[
          OnDeviceTurn.user('Summarize MR !12'),
          OnDeviceTurn.model('Sure.'),
          OnDeviceTurn(role: OnDeviceRole.user, text: 'Focus on security.'),
        ],
        maxOutputTokens: 512,
        temperature: 0.2,
        onRequestId: (String id) {
          callbackId = id;
        },
      );

      expect(stream.requestId, isNotEmpty);
      expect(callbackId, stream.requestId);
      expect(plugin.lastRequestId, stream.requestId);

      final chunks = await stream.toList();
      expect(chunks, <String>['Hello ', 'world!']);

      final generateCall = methodCalls.singleWhere(
        (MethodCall c) => c.method == 'generate',
      );
      final args = generateCall.arguments as Map<Object?, Object?>;
      expect(args['requestId'], stream.requestId);
      expect(args['system'], 'Be concise.');
      expect(args['maxOutputTokens'], 512);
      expect(args['temperature'], 0.2);
      expect(args['turns'], <Map<String, Object?>>[
        <String, Object?>{'role': 'user', 'text': 'Summarize MR !12'},
        <String, Object?>{'role': 'model', 'text': 'Sure.'},
        <String, Object?>{'role': 'user', 'text': 'Focus on security.'},
      ]);
    });

    test('explicit cancel(requestId) and subscription cancel invoke native cancel', () async {
      final plugin = MergelineOnDeviceAi();
      final firstChunkReceived = Completer<void>();

      streamHandler = MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          onMethodCall = (MethodCall call) async {
            if (call.method == 'generate') {
              final args = call.arguments as Map<Object?, Object?>;
              final requestId = args['requestId'] as String;
              events.success(<String, Object?>{
                'event': 'generate',
                'requestId': requestId,
                'type': 'chunk',
                'text': 'Partial...',
              });
            }
            return null;
          };
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, streamHandler);

      final stream = plugin.generate(
        system: 'System prompt',
        turns: const <OnDeviceTurn>[OnDeviceTurn.user('Hello')],
      );
      final received = <String>[];
      final sub = stream.listen((String chunk) {
        received.add(chunk);
        if (!firstChunkReceived.isCompleted) {
          firstChunkReceived.complete();
        }
      });
      await firstChunkReceived.future;
      expect(received, <String>['Partial...']);

      await plugin.cancel(stream.requestId);
      final cancelCalls = methodCalls
          .where((MethodCall c) => c.method == 'cancel')
          .toList();
      expect(cancelCalls, hasLength(1));
      expect(
        cancelCalls.single.arguments,
        <String, Object?>{'requestId': stream.requestId},
      );

      await sub.cancel();
      // Cancelling an unfinished stream subscription also sends cancel.
      final allCancelCalls = methodCalls
          .where((MethodCall c) => c.method == 'cancel')
          .toList();
      expect(allCancelCalls.length, greaterThanOrEqualTo(1));
    });
  });

  group('OnDeviceAiException error code mapping', () {
    final cases = <({
      String rawCode,
      int? nativeCode,
      OnDeviceAiErrorCode expected,
    })>[
      (
        rawCode: 'unsupported',
        nativeCode: 16,
        expected: OnDeviceAiErrorCode.unsupported,
      ),
      (
        rawCode: 'AICORE_INCOMPATIBLE',
        nativeCode: -101,
        expected: OnDeviceAiErrorCode.unsupported,
      ),
      (
        rawCode: 'notDownloaded',
        nativeCode: 501,
        expected: OnDeviceAiErrorCode.notDownloaded,
      ),
      (
        rawCode: 'BACKGROUND_USE_BLOCKED',
        nativeCode: 30,
        expected: OnDeviceAiErrorCode.backgroundBlocked,
      ),
      (
        rawCode: 'BUSY',
        nativeCode: 9,
        expected: OnDeviceAiErrorCode.busy,
      ),
      (
        rawCode: 'PER_APP_BATTERY_USE_QUOTA_EXCEEDED',
        nativeCode: 27,
        expected: OnDeviceAiErrorCode.quotaExceeded,
      ),
      (
        rawCode: 'REQUEST_TOO_LARGE',
        nativeCode: 12,
        expected: OnDeviceAiErrorCode.inputTooLong,
      ),
      (
        rawCode: 'CANCELLED',
        nativeCode: 7,
        expected: OnDeviceAiErrorCode.cancelled,
      ),
      (
        rawCode: 'UNKNOWN_INTERNAL_FAILURE',
        nativeCode: 0,
        expected: OnDeviceAiErrorCode.other,
      ),
    ];

    for (final testCase in cases) {
      test(
        'maps ${testCase.rawCode} (${testCase.nativeCode}) to ${testCase.expected}',
        () async {
          final plugin = MergelineOnDeviceAi();
          streamHandler = MockStreamHandler.inline(
            onListen: (Object? arguments, MockStreamHandlerEventSink events) {
              onMethodCall = (MethodCall call) async {
                if (call.method == 'generate') {
                  final args = call.arguments as Map<Object?, Object?>;
                  final requestId = args['requestId'] as String;
                  events.success(<String, Object?>{
                    'event': 'generate',
                    'requestId': requestId,
                    'type': 'error',
                    'code': testCase.rawCode,
                    'debugMessage': 'raw-native-detail-${testCase.rawCode}',
                    'nativeErrorCode': testCase.nativeCode,
                  });
                }
                return null;
              };
            },
          );
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockStreamHandler(eventChannel, streamHandler);

          final stream = plugin.generate(
            system: 'System',
            turns: const <OnDeviceTurn>[OnDeviceTurn.user('Hi')],
          );

          await expectLater(
            stream.toList(),
            throwsA(
              isA<OnDeviceAiException>()
                  .having(
                    (OnDeviceAiException e) => e.code,
                    'code',
                    testCase.expected,
                  )
                  .having(
                    (OnDeviceAiException e) => e.debugMessage,
                    'debugMessage',
                    'raw-native-detail-${testCase.rawCode}',
                  )
                  .having(
                    (OnDeviceAiException e) => e.toString(),
                    'toString omits raw debugMessage',
                    isNot(contains('raw-native-detail')),
                  ),
            ),
          );
        },
      );
    }
  });

  group('non-Android fallback', () {
    test('returns unavailable(not_android) and never throws on iOS/desktop', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final plugin = MergelineOnDeviceAi();

      final status = await plugin.status();
      expect(status.availability, OnDeviceAvailability.unavailable);
      expect(status.reason, 'not_android');

      final downloadEvents = await plugin.download().toList();
      expect(downloadEvents, isEmpty);

      final genStream = plugin.generate(
        system: 'System',
        turns: const <OnDeviceTurn>[OnDeviceTurn.user('Test')],
      );
      expect(genStream.requestId, isNotEmpty);
      final chunks = await genStream.toList();
      expect(chunks, isEmpty);

      await plugin.cancel(genStream.requestId);
      expect(methodCalls, isEmpty);
    });
  });
}
