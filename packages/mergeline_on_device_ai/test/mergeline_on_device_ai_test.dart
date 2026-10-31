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

  MergelineOnDeviceAi createAndroidPlugin() =>
      MergelineOnDeviceAi(isAndroid: () => true);

  setUp(() {
    methodCalls = <MethodCall>[];
    onMethodCall = (MethodCall call) async => null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
          methodCalls.add(call);
          return onMethodCall(call);
        });
  });

  tearDown(() async {
    await MergelineOnDeviceAi(isAndroid: () => false).close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    if (streamHandler != null) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, null);
      streamHandler = null;
    }
    debugDefaultTargetPlatformOverride = null;
  });

  group('lazy initialization and host platform guard', () {
    test('constructing MergelineOnDeviceAi makes no channel call', () async {
      var eventChannelListened = false;
      streamHandler = MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          eventChannelListened = true;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, streamHandler);

      final plugin = createAndroidPlugin();
      final singleton = MergelineOnDeviceAi.instance;

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

    test(
      'default isAndroid uses Platform.isAndroid so host widget tests never touch channels',
      () async {
        // In Flutter widget tests, debugDefaultTargetPlatformOverride defaults
        // to TargetPlatform.android on macOS/Linux/Windows hosts.
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final hostPlugin = MergelineOnDeviceAi();

        final support = await hostPlugin.deviceSupport();
        expect(support.state, OnDeviceSupportState.unsupported);
        expect(support.reason, 'not_android');

        final status = await hostPlugin.status();
        expect(status.availability, OnDeviceAvailability.unavailable);
        expect(status.reason, 'not_android');

        final downloadEvents = await hostPlugin.download().toList();
        expect(downloadEvents, isEmpty);

        final genStream = hostPlugin.generate(
          system: 'System',
          turns: const <OnDeviceTurn>[OnDeviceTurn.user('Test')],
        );
        expect(await genStream.toList(), isEmpty);

        await hostPlugin.cancel(genStream.requestId);
        await hostPlugin.close();
        expect(methodCalls, isEmpty);
      },
    );
  });

  group('deviceSupport()', () {
    test('maps likely, unsupported(reason), unknown, and PlatformException', () async {
      final plugin = createAndroidPlugin();

      onMethodCall = (_) async => <String, Object?>{
        'support': 'likely',
      };
      final likely = await plugin.deviceSupport();
      expect(likely.state, OnDeviceSupportState.likely);
      expect(likely.isLikely, isTrue);
      expect(likely.reason, isNull);

      onMethodCall = (_) async => <String, Object?>{
        'support': 'unsupported',
        'reason': 'sdk_too_old',
      };
      final sdkTooOld = await plugin.deviceSupport();
      expect(sdkTooOld.state, OnDeviceSupportState.unsupported);
      expect(sdkTooOld.isUnsupported, isTrue);
      expect(sdkTooOld.reason, 'sdk_too_old');

      onMethodCall = (_) async => <String, Object?>{
        'support': 'unsupported',
        'reason': 'aicore_missing',
      };
      final missing = await plugin.deviceSupport();
      expect(missing.state, OnDeviceSupportState.unsupported);
      expect(missing.reason, 'aicore_missing');

      onMethodCall = (_) async => <String, Object?>{
        'support': 'unsupported',
        'reason': 'aicore_disabled',
      };
      final disabled = await plugin.deviceSupport();
      expect(disabled.state, OnDeviceSupportState.unsupported);
      expect(disabled.reason, 'aicore_disabled');

      onMethodCall = (_) async => <String, Object?>{
        'support': 'unknown',
        'debugMessage': 'PackageManager failed',
      };
      final unknown = await plugin.deviceSupport();
      expect(unknown.state, OnDeviceSupportState.unknown);
      expect(unknown.isUnknown, isTrue);
      expect(unknown.debugMessage, 'PackageManager failed');

      onMethodCall = (_) async {
        throw PlatformException(
          code: 'pm_error',
          message: 'Binder transaction failed',
        );
      };
      final onError = await plugin.deviceSupport();
      expect(onError.state, OnDeviceSupportState.unknown);
      expect(onError.reason, 'pm_error');
      expect(onError.debugMessage, 'Binder transaction failed');
    });
  });

  group('status()', () {
    test('maps all four availability states and reasons', () async {
      final plugin = createAndroidPlugin();

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
      final plugin = createAndroidPlugin();
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

    test('throws OnDeviceAiException(other) instead of TypeError on malformed payloads', () async {
      final plugin = createAndroidPlugin();
      final malformedPayloads = <Object?>[
        null,
        'not-a-map',
        123,
        <String, Object?>{},
        <String, Object?>{'status': 42},
        <String, Object?>{'status': 'bogus_state'},
        <String, Object?>{'status': 'available', 'modelName': 999},
        <String, Object?>{'status': 'unavailable', 'reason': false},
        <String, Object?>{'status': 'available', 'debugMessage': <int>[1]},
      ];

      for (final payload in malformedPayloads) {
        onMethodCall = (_) async => payload;
        await expectLater(
          plugin.status(),
          throwsA(
            isA<OnDeviceAiException>().having(
              (OnDeviceAiException e) => e.code,
              'code',
              OnDeviceAiErrorCode.other,
            ),
          ),
        );
      }
    });
  });

  group('download()', () {
    test('streams started, progress, and completed events', () async {
      final plugin = createAndroidPlugin();
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

    test('streams failed event with mapped insufficientStorage exception', () async {
      final plugin = createAndroidPlugin();

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
                'code': 'insufficientStorage',
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
      expect(
        received.single.error?.code,
        OnDeviceAiErrorCode.insufficientStorage,
      );
      expect(received.single.error?.debugMessage, 'Not enough disk space');
      expect(received.single.error?.nativeErrorCode, 501);
    });

    test('invokeMethod(download) rejected exercises catchError and maps non-GenAI to other', () async {
      final plugin = createAndroidPlugin();

      streamHandler = MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {},
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, streamHandler);

      onMethodCall = (MethodCall call) async {
        if (call.method == 'download') {
          throw PlatformException(
            code: 'NOT_ENOUGH_DISK_SPACE',
            message: 'Low storage',
            details: <String, Object?>{'nativeErrorCode': 501},
          );
        }
        return null;
      };

      final platformFailed = await plugin.download().toList();
      expect(platformFailed, hasLength(1));
      expect(platformFailed.single.state, OnDeviceDownloadState.failed);
      expect(
        platformFailed.single.error?.code,
        OnDeviceAiErrorCode.insufficientStorage,
      );
      expect(platformFailed.single.error?.nativeErrorCode, 501);

      // Non-GenAI / non-PlatformException error during download maps to `other`,
      // not `notDownloaded`.
      onMethodCall = (MethodCall call) async {
        if (call.method == 'download') {
          throw StateError('Unexpected runtime failure');
        }
        return null;
      };

      final genericFailed = await plugin.download().toList();
      expect(genericFailed, hasLength(1));
      expect(genericFailed.single.state, OnDeviceDownloadState.failed);
      expect(genericFailed.single.error?.code, OnDeviceAiErrorCode.other);
    });

    test('unsubscribing from download sends cancel for its download id', () async {
      final plugin = createAndroidPlugin();
      final startedCompleter = Completer<void>();
      String? downloadRequestId;

      streamHandler = MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          onMethodCall = (MethodCall call) async {
            if (call.method == 'download') {
              final args = call.arguments as Map<Object?, Object?>;
              downloadRequestId = args['requestId'] as String;
              events.success(<String, Object?>{
                'event': 'download',
                'requestId': downloadRequestId,
                'state': 'started',
                'bytesToDownload': 1024,
              });
            }
            return null;
          };
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, streamHandler);

      final sub = plugin.download().listen((OnDeviceDownloadEvent event) {
        if (event.state == OnDeviceDownloadState.started &&
            !startedCompleter.isCompleted) {
          startedCompleter.complete();
        }
      });

      await startedCompleter.future;
      expect(downloadRequestId, isNotNull);

      await sub.cancel();
      final cancelCalls = methodCalls
          .where((MethodCall c) => c.method == 'cancel')
          .toList();
      expect(cancelCalls, hasLength(1));
      expect(
        cancelCalls.single.arguments,
        <String, Object?>{'requestId': downloadRequestId},
      );
    });

    test(
      'flow ending without Completed or Failed emits completed when model is available, else failed(other)',
      () async {
        final plugin = createAndroidPlugin();

        // Case 1: Model is now available -> emits completed and closes stream.
        streamHandler = MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            onMethodCall = (MethodCall call) async {
              if (call.method == 'download') {
                final args = call.arguments as Map<Object?, Object?>;
                final requestId = args['requestId'] as String;
                events.success(<String, Object?>{
                  'event': 'download',
                  'requestId': requestId,
                  'state': 'started',
                  'bytesToDownload': 1000,
                });
                events.endOfStream();
                return null;
              }
              if (call.method == 'status') {
                return <String, Object?>{'status': 'available'};
              }
              return null;
            };
          },
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(eventChannel, streamHandler);

        final availableOutcome = await plugin.download().toList();
        expect(availableOutcome, <OnDeviceDownloadEvent>[
          const OnDeviceDownloadEvent.started(bytesToDownload: 1000),
          const OnDeviceDownloadEvent.completed(),
        ]);

        // Case 2: Model is still not available -> emits failed(other) and closes stream.
        streamHandler = MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            onMethodCall = (MethodCall call) async {
              if (call.method == 'download') {
                final args = call.arguments as Map<Object?, Object?>;
                final requestId = args['requestId'] as String;
                events.success(<String, Object?>{
                  'event': 'download',
                  'requestId': requestId,
                  'state': 'progress',
                  'bytesDownloaded': 500,
                });
                events.endOfStream();
                return null;
              }
              if (call.method == 'status') {
                return <String, Object?>{'status': 'downloadable'};
              }
              return null;
            };
          },
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(eventChannel, streamHandler);

        final failedOutcome = await plugin.download().toList();
        expect(failedOutcome, hasLength(2));
        expect(failedOutcome.first.state, OnDeviceDownloadState.progress);
        expect(failedOutcome.last.state, OnDeviceDownloadState.failed);
        expect(failedOutcome.last.error?.code, OnDeviceAiErrorCode.other);
      },
    );
  });

  group('generate() and cancel()', () {
    test('validates temperature in [0, 1] and maxOutputTokens > 0 synchronously', () {
      final plugin = createAndroidPlugin();
      const turns = <OnDeviceTurn>[OnDeviceTurn.user('Hi')];

      for (final badTemp in <double>[-0.01, -1.0, 1.01, 2.0, double.nan]) {
        expect(
          () => plugin.generate(
            system: 'System',
            turns: turns,
            temperature: badTemp,
          ),
          throwsA(
            isA<OnDeviceAiException>().having(
              (OnDeviceAiException e) => e.code,
              'code',
              OnDeviceAiErrorCode.invalidArgument,
            ),
          ),
        );
      }

      for (final badTokens in <int>[0, -1, -100]) {
        expect(
          () => plugin.generate(
            system: 'System',
            turns: turns,
            maxOutputTokens: badTokens,
          ),
          throwsA(
            isA<OnDeviceAiException>().having(
              (OnDeviceAiException e) => e.code,
              'code',
              OnDeviceAiErrorCode.invalidArgument,
            ),
          ),
        );
      }

      // Valid boundary values do not throw and make no channel calls before listen.
      final validLow = plugin.generate(
        system: 'System',
        turns: turns,
        temperature: 0.0,
        maxOutputTokens: 1,
      );
      final validHigh = plugin.generate(
        system: 'System',
        turns: turns,
        temperature: 1.0,
        maxOutputTokens: 4096,
      );
      expect(validLow.requestId, isNot(equals(validHigh.requestId)));
      expect(methodCalls, isEmpty);
    });

    test('streams chunks and exposes requestId for cancel', () async {
      final plugin = createAndroidPlugin();
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

      expect(stream.requestId, matches(RegExp(r'^req_[0-9a-f]{16}_\d+$')));
      expect(callbackId, stream.requestId);

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
      final plugin = createAndroidPlugin();
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
      expect(allCancelCalls, hasLength(2));
      expect(
        allCancelCalls[1].arguments,
        <String, Object?>{'requestId': stream.requestId},
      );
    });

    test('invokeMethod(generate) rejected exercises catchError', () async {
      final plugin = createAndroidPlugin();

      streamHandler = MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {},
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, streamHandler);

      onMethodCall = (MethodCall call) async {
        if (call.method == 'generate') {
          throw PlatformException(
            code: 'busy',
            message: 'AICore busy',
            details: <String, Object?>{'nativeErrorCode': 9},
          );
        }
        return null;
      };

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
                OnDeviceAiErrorCode.busy,
              )
              .having(
                (OnDeviceAiException e) => e.debugMessage,
                'debugMessage',
                'AICore busy',
              )
              .having(
                (OnDeviceAiException e) => e.nativeErrorCode,
                'nativeErrorCode',
                9,
              ),
        ),
      );
    });

    test(
      'two concurrent generate() streams across instances share subscription and cancel only after last ends',
      () async {
        final pluginA = createAndroidPlugin();
        final pluginB = createAndroidPlugin();
        var listenCount = 0;
        var cancelCount = 0;
        MockStreamHandlerEventSink? activeSink;

        streamHandler = MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            listenCount++;
            activeSink = events;
          },
          onCancel: (Object? arguments) {
            cancelCount++;
            activeSink = null;
          },
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(eventChannel, streamHandler);

        final stream1 = pluginA.generate(
          system: 'System A',
          turns: const <OnDeviceTurn>[OnDeviceTurn.user('First')],
        );
        final stream2 = pluginB.generate(
          system: 'System B',
          turns: const <OnDeviceTurn>[OnDeviceTurn.user('Second')],
        );
        expect(stream1.requestId, isNot(equals(stream2.requestId)));

        final chunks1 = <String>[];
        final chunks2 = <String>[];
        final done1 = Completer<void>();
        final done2 = Completer<void>();

        final sub1 = stream1.listen(
          chunks1.add,
          onDone: done1.complete,
        );
        final sub2 = stream2.listen(
          chunks2.add,
          onDone: done2.complete,
        );

        expect(listenCount, 1);
        expect(cancelCount, 0);

        activeSink!.success(<String, Object?>{
          'event': 'generate',
          'requestId': stream1.requestId,
          'type': 'chunk',
          'text': 'A1',
        });
        activeSink!.success(<String, Object?>{
          'event': 'generate',
          'requestId': stream2.requestId,
          'type': 'chunk',
          'text': 'B1',
        });
        activeSink!.success(<String, Object?>{
          'event': 'generate',
          'requestId': stream1.requestId,
          'type': 'done',
        });

        await done1.future;
        expect(chunks1, <String>['A1']);
        // Stream 1 finished, but Stream 2 is still active: platform subscription stays open.
        expect(cancelCount, 0);

        activeSink!.success(<String, Object?>{
          'event': 'generate',
          'requestId': stream2.requestId,
          'type': 'chunk',
          'text': 'B2',
        });
        activeSink!.success(<String, Object?>{
          'event': 'generate',
          'requestId': stream2.requestId,
          'type': 'done',
        });

        await done2.future;
        expect(chunks2, <String>['B1', 'B2']);
        expect(cancelCount, 1);

        await sub1.cancel();
        await sub2.cancel();
      },
    );

    test(
      'EventChannel onError ends only targeted stream when requestId is present, or all streams otherwise',
      () async {
        final plugin = createAndroidPlugin();
        MockStreamHandlerEventSink? activeSink;

        streamHandler = MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            activeSink = events;
          },
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(eventChannel, streamHandler);

        // Part 1: Targeted EventChannel error with requestId in details.
        final stream1 = plugin.generate(
          system: 'S1',
          turns: const <OnDeviceTurn>[OnDeviceTurn.user('One')],
        );
        final stream2 = plugin.generate(
          system: 'S2',
          turns: const <OnDeviceTurn>[OnDeviceTurn.user('Two')],
        );

        final future1 = stream1.toList();
        final future2 = stream2.toList();

        activeSink!.error(
          code: 'quotaExceeded',
          message: 'Quota exceeded for stream 1',
          details: <String, Object?>{
            'requestId': stream1.requestId,
            'nativeErrorCode': 27,
          },
        );

        await expectLater(
          future1,
          throwsA(
            isA<OnDeviceAiException>()
                .having(
                  (OnDeviceAiException e) => e.code,
                  'code',
                  OnDeviceAiErrorCode.quotaExceeded,
                )
                .having(
                  (OnDeviceAiException e) => e.nativeErrorCode,
                  'nativeErrorCode',
                  27,
                ),
          ),
        );

        // Stream 2 is unaffected and still receives events.
        activeSink!.success(<String, Object?>{
          'event': 'generate',
          'requestId': stream2.requestId,
          'type': 'chunk',
          'text': 'Still alive',
        });
        activeSink!.success(<String, Object?>{
          'event': 'generate',
          'requestId': stream2.requestId,
          'type': 'done',
        });
        expect(await future2, <String>['Still alive']);

        // Part 2: Channel-wide EventChannel error without requestId ends all active streams.
        final stream3 = plugin.generate(
          system: 'S3',
          turns: const <OnDeviceTurn>[OnDeviceTurn.user('Three')],
        );
        final stream4 = plugin.generate(
          system: 'S4',
          turns: const <OnDeviceTurn>[OnDeviceTurn.user('Four')],
        );
        final future3 = stream3.toList();
        final future4 = stream4.toList();

        activeSink!.error(
          code: 'backgroundBlocked',
          message: 'App backgrounded',
          details: <String, Object?>{'nativeErrorCode': 30},
        );

        await expectLater(
          future3,
          throwsA(
            isA<OnDeviceAiException>().having(
              (OnDeviceAiException e) => e.code,
              'code',
              OnDeviceAiErrorCode.backgroundBlocked,
            ),
          ),
        );
        await expectLater(
          future4,
          throwsA(
            isA<OnDeviceAiException>().having(
              (OnDeviceAiException e) => e.code,
              'code',
              OnDeviceAiErrorCode.backgroundBlocked,
            ),
          ),
        );
      },
    );

    test('close() cancels active EventChannel subscription and invokes native close', () async {
      final plugin = createAndroidPlugin();
      var cancelCount = 0;

      streamHandler = MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {},
        onCancel: (Object? arguments) {
          cancelCount++;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, streamHandler);

      final stream = plugin.generate(
        system: 'System',
        turns: const <OnDeviceTurn>[OnDeviceTurn.user('Hello')],
      );
      final done = Completer<void>();
      final sub = stream.listen((_) {}, onDone: done.complete);

      await plugin.close();
      await done.future;
      expect(cancelCount, 1);
      expect(
        methodCalls.where((MethodCall c) => c.method == 'close'),
        hasLength(1),
      );
      await sub.cancel();
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
        nativeCode: 8,
        expected: OnDeviceAiErrorCode.notDownloaded,
      ),
      (
        rawCode: 'NOT_ENOUGH_DISK_SPACE',
        nativeCode: 501,
        expected: OnDeviceAiErrorCode.insufficientStorage,
      ),
      (
        rawCode: 'insufficientStorage',
        nativeCode: 501,
        expected: OnDeviceAiErrorCode.insufficientStorage,
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
        rawCode: 'MAX_TURNS_EXCEEDED',
        nativeCode: -112,
        expected: OnDeviceAiErrorCode.inputTooLong,
      ),
      (
        rawCode: 'invalidArgument',
        nativeCode: null,
        expected: OnDeviceAiErrorCode.invalidArgument,
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
          final plugin = createAndroidPlugin();
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
                    (OnDeviceAiException e) => e.nativeErrorCode,
                    'nativeErrorCode',
                    testCase.nativeCode,
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

    test('maps string-only error codes with no nativeErrorCode', () async {
      final plugin = createAndroidPlugin();
      final stringOnlyCases = <String, OnDeviceAiErrorCode>{
        'unsupported': OnDeviceAiErrorCode.unsupported,
        'notDownloaded': OnDeviceAiErrorCode.notDownloaded,
        'insufficientStorage': OnDeviceAiErrorCode.insufficientStorage,
        'backgroundBlocked': OnDeviceAiErrorCode.backgroundBlocked,
        'busy': OnDeviceAiErrorCode.busy,
        'quotaExceeded': OnDeviceAiErrorCode.quotaExceeded,
        'inputTooLong': OnDeviceAiErrorCode.inputTooLong,
        'invalidArgument': OnDeviceAiErrorCode.invalidArgument,
        'cancelled': OnDeviceAiErrorCode.cancelled,
        'other': OnDeviceAiErrorCode.other,
      };

      for (final entry in stringOnlyCases.entries) {
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
                  'code': entry.key,
                  'debugMessage': 'string-only-${entry.key}',
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
                  entry.value,
                )
                .having(
                  (OnDeviceAiException e) => e.nativeErrorCode,
                  'nativeErrorCode',
                  isNull,
                ),
          ),
        );
      }
    });
  });

  group('non-Android fallback', () {
    test('returns not_android and never touches channels when isAndroid is false', () async {
      final plugin = MergelineOnDeviceAi(isAndroid: () => false);

      final support = await plugin.deviceSupport();
      expect(support.state, OnDeviceSupportState.unsupported);
      expect(support.reason, 'not_android');

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
      await plugin.close();
      expect(methodCalls, isEmpty);
    });
  });
}
