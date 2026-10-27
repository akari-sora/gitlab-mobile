import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_run_notifications.dart';

import '../support/ai_run_notification_shell.dart' show notificationChannel;

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');
const _sentinels = [
  'PROJECT_SENTINEL',
  'TITLE_SENTINEL',
  'PATH_SENTINEL',
  'TOKEN_SENTINEL',
  'PROMPT_SENTINEL',
];
const _text = AiRunNotificationText(
  approvalChannelName: 'Generic approvals',
  resultChannelName: 'Generic results',
  title: 'Generic work',
  needsApproval: 'Generic approval needed',
  completed: 'Generic completion',
  failed: 'Generic failure',
  interrupted: 'Generic interruption',
);

final class _Chat extends ChangeNotifier
    implements AiChatSession, AiWriteChatSession {
  _Chat(this.id);
  @override
  String id;
  @override
  final origin = const AiWorkItemOrigin(
    project: Project(id: 9, name: 'PROJECT_SENTINEL', path: 'PATH_SENTINEL'),
    kind: AiWorkItemKind.mergeRequest,
    iid: 7,
    title: 'TITLE_SENTINEL',
  );
  @override
  List<AiWriteProposal> proposals = [];
  @override
  AiChatPhase phase = AiChatPhase.awaitingApproval;

  void resolve(String action) {
    if (action != 'expire') proposals.single.invalidate();
    phase = AiChatPhase.idle;
    notifyListeners();
  }

  void changed() => notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected session access: ${invocation.memberName}');
}

final class _Registry extends ChangeNotifier
    implements AiRunRegistry, AiExecutionRunRegistry {
  _Registry(this.chat);
  _Chat? chat;
  final otherChats = <String, _Chat>{};
  int generation = 8;
  bool current = true;
  final events = StreamController<AiRunNotificationEvent>.broadcast(sync: true);

  @override
  AiChatSession? sessionForConversation(
    String conversationId,
    int generation,
  ) => current && this.generation == generation
      ? (chat?.id == conversationId ? chat : otherChats[conversationId])
      : null;

  @override
  Stream<AiRunNotificationEvent> get notificationEvents => events.stream;

  void emit(AiRunNotificationKind kind, {String? id, int? generation}) =>
      events.add(
        AiRunNotificationEvent(
          kind: kind,
          conversationId: id ?? chat!.id,
          generation: generation ?? this.generation,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected registry access: ${invocation.memberName}');

  @override
  void dispose() {
    unawaited(events.close());
    super.dispose();
  }
}

/// Uses the pinned plugin's real serialization and tap handler, replacing only
/// the Android channel. Captures every displayed field, not a fake view model.
final class _Native {
  final calls = <MethodCall>[];
  final liveIds = <int>{6100, 6199, 6200, 6250, 6299, 6300, 6399, 6400};
  String? launchPayload;
  Completer<void>? launchBarrier;
  Completer<void>? launchRequested;
  Completer<void>? showBarrier;
  Completer<void>? showRequested;
  int? failCancel;
  bool permission = true;
  bool? notificationsEnabled = true;
  List<Map<String, Object?>>? channels = [];
  bool failState = false;
  bool failShow = false;
  bool failActive = false;

  List<Map<String, Object?>> get shows => calls
      .where((call) => call.method == 'show')
      .map((call) => Map<String, Object?>.from(call.arguments as Map))
      .toList();

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'initialize':
        return true;
      case 'getNotificationAppLaunchDetails':
        final details = {
          'notificationLaunchedApp': launchPayload != null,
          if (launchPayload != null)
            'notificationResponse': response(launchPayload!),
        };
        launchRequested?.complete();
        await launchBarrier?.future;
        return details;
      case 'cancel':
        final id = (call.arguments as Map)['id'] as int;
        if (id == failCancel) throw PlatformException(code: 'synthetic');
        liveIds.remove(id);
        return null;
      case 'show':
        if (failShow) throw PlatformException(code: 'TOKEN_SENTINEL');
        if (!(showRequested?.isCompleted ?? true)) showRequested!.complete();
        await showBarrier?.future;
        liveIds.add((call.arguments as Map)['id'] as int);
        return null;
      case 'getActiveNotifications':
        if (failActive) throw PlatformException(code: 'synthetic');
        return liveIds.map((id) => <String, Object?>{'id': id}).toList();
      case 'requestNotificationsPermission':
        return permission;
      case 'areNotificationsEnabled':
        if (failState) throw PlatformException(code: 'synthetic');
        return notificationsEnabled;
      case 'getNotificationChannels':
        return channels;
      default:
        throw StateError('Unexpected platform call: ${call.method}');
    }
  }

  Map<String, Object?> response(
    String payload, {
    int type = 0,
    String? actionId,
    String? input,
  }) => {
    'notificationId': 6200,
    'notificationResponseType': type,
    'payload': payload,
    'actionId': actionId,
    'input': input,
  };

  Future<void> tap(
    String payload, {
    int type = 0,
    String? actionId,
    String? input,
  }) async {
    final done = Completer<void>();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(
              'didReceiveNotificationResponse',
              response(payload, type: type, actionId: actionId, input: input),
            ),
          ),
          (_) => done.complete(),
        );
    await done.future;
  }
}

String _payload([String id = 'conversation-1', int generation = 8]) =>
    AiRunNotificationRoute(conversationId: id, generation: generation).encode();

Future<void> _drain() => Future<void>.delayed(Duration.zero);

AiWriteProposal _proposal(String id, {DateTime? expiry}) => AiWriteProposal(
  executionId: id,
  operationId: 'synthetic-operation',
  tier: const AiTierDecision.unknown(),
  payloadDigest: 'synthetic-digest',
  previewText: _sentinels.join(' '),
  userUtterance: 'PROMPT_SENTINEL',
  modelReason: 'TOKEN_SENTINEL',
  expiresAt: expiry ?? DateTime.now().add(const Duration(minutes: 30)),
  proposalEpoch: 1,
  writePolicyRevision: 1,
  consentHash: 'synthetic-consent',
  scopeRevision: 1,
  releaseName: 'PROJECT_SENTINEL',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Native native;
  late _Chat chat;
  late _Registry registry;
  late AiRunNotifications notifications;
  var currentText = _text;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    native = _Native();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, native.handle);
    chat = _Chat('conversation-1')..proposals = [_proposal('approval-1')];
    registry = _Registry(chat);
    currentText = _text;
    notifications = AiRunNotifications(text: () => currentText);
  });

  tearDown(() {
    notifications.dispose();
    registry.dispose();
    chat.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  AiRunNotificationOpen? take({bool loaded = true, bool unlocked = true}) =>
      notifications.takePendingOpen(
        appLockLoaded: loaded,
        appLockUnlocked: unlocked,
      );

  test(
    'late cold payload is invalid after cancelled unlock; new tap works',
    () async {
      notifications.bindRegistry(registry);
      native.launchPayload = _payload();
      native.launchRequested = Completer<void>();
      native.launchBarrier = Completer<void>();
      final initializing = notifications.initialize();
      await native.launchRequested!.future;
      notifications.discardPendingOpen();
      native.launchBarrier!.complete();
      expect(await initializing, isTrue);
      expect(notifications.pendingOpen, isNull);
      expect(
        take(),
        isNull,
        reason: 'a later successful unlock has no old tap',
      );
      await native.tap(_payload());
      expect(take()!.session, same(chat));
    },
  );

  for (final consumeWarm in [false, true]) {
    test(
      'older cold tap cannot replace newer ${consumeWarm ? "consumed" : "waiting"} warm tap',
      () async {
        notifications.bindRegistry(registry);
        native.launchPayload = _payload('old-cold');
        native.launchRequested = Completer<void>();
        native.launchBarrier = Completer<void>();
        final initializing = notifications.initialize();
        await native.launchRequested!.future;
        await native.tap(_payload());
        if (consumeWarm) expect(take()!.session, same(chat));
        native.launchBarrier!.complete();
        expect(await initializing, isTrue);
        if (consumeWarm) {
          expect(notifications.pendingOpen, isNull);
          expect(take(), isNull);
        } else {
          expect(notifications.pendingOpen!.route.conversationId, chat.id);
          expect(take()!.session, same(chat));
        }
      },
    );
  }

  for (final action in ['approve', 'reject', 'expire']) {
    test('$action cancels only its own approval notification ID', () async {
      notifications.bindRegistry(registry);
      await notifications.initialize();
      final other = _Chat('other-conversation')
        ..proposals = [_proposal('other')];
      addTearDown(other.dispose);
      registry.otherChats[other.id] = other;
      registry.emit(AiRunNotificationKind.needsApproval);
      registry.emit(AiRunNotificationKind.needsApproval, id: other.id);
      await _drain();
      final ownId = native.shows.first['id'];
      final otherId = native.shows.last['id'];
      expect(ownId, isNot(otherId));
      native.calls.clear();
      chat.resolve(action);
      await _drain();
      expect(
        native.calls
            .where((c) => c.method == 'cancel')
            .map((c) => (c.arguments as Map)['id']),
        [ownId],
      );
      expect(native.liveIds, isNot(contains(ownId)));
      expect(native.liveIds, contains(otherId));
    });
  }

  test(
    'proposal expiry cancels approval even before phase catches up',
    () async {
      notifications.bindRegistry(registry);
      await notifications.initialize();
      registry.emit(AiRunNotificationKind.needsApproval);
      await _drain();
      final id = native.shows.single['id'];
      native.calls.clear();
      chat.proposals = [
        _proposal(
          'expired',
          expiry: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
      ];
      chat.changed();
      await _drain();
      expect(
        native.calls
            .where((c) => c.method == 'cancel')
            .map((c) => (c.arguments as Map)['id']),
        [id],
      );
    },
  );

  test('pending approval stays until the final proposal resolves', () async {
    notifications.bindRegistry(registry);
    await notifications.initialize();
    registry.emit(AiRunNotificationKind.needsApproval);
    await _drain();
    final id = native.shows.single['id'];
    chat.proposals.add(_proposal('second'));
    chat.proposals.first.invalidate();
    native.calls.clear();
    chat.changed();
    await _drain();
    expect(native.calls.where((c) => c.method == 'cancel'), isEmpty);
    expect(native.liveIds, contains(id));
    chat.proposals.last.invalidate();
    chat.changed();
    await _drain();
    expect(
      native.calls
          .where((c) => c.method == 'cancel')
          .map((c) => (c.arguments as Map)['id']),
      [id],
    );
  });

  test(
    'resolved proposal is rechecked before delayed approval delivery',
    () async {
      notifications.bindRegistry(registry);
      native.launchRequested = Completer<void>();
      native.launchBarrier = Completer<void>();
      final initializing = notifications.initialize();
      await native.launchRequested!.future;
      registry.emit(AiRunNotificationKind.needsApproval);
      chat.resolve('approve');
      native.launchBarrier!.complete();
      expect(await initializing, isTrue);
      await _drain();
      expect(native.shows, isEmpty);
    },
  );

  test(
    'approval resolved during show is cancelled after show finishes',
    () async {
      notifications.bindRegistry(registry);
      await notifications.initialize();
      native.calls.clear();
      native.showRequested = Completer<void>();
      native.showBarrier = Completer<void>();
      registry.emit(AiRunNotificationKind.needsApproval);
      await native.showRequested!.future;
      final id = native.shows.single['id'];
      chat.resolve('reject');
      native.showBarrier!.complete();
      await _drain();
      expect(
        native.calls
            .where((c) => c.method == 'cancel')
            .map((c) => (c.arguments as Map)['id']),
        [id],
      );
      expect(native.liveIds, isNot(contains(id)));
    },
  );

  test(
    'startup cancels exactly the approval range once, preserving other IDs',
    () async {
      final first = notifications.initialize();
      expect(identical(first, notifications.initialize()), isTrue);
      expect(await first, isTrue);
      expect(await notifications.initialize(), isTrue);
      final cancelled = native.calls
          .where((c) => c.method == 'cancel')
          .map((c) => (c.arguments as Map)['id'])
          .toList();
      expect(cancelled, List.generate(100, (i) => 6200 + i));
      expect(native.liveIds, {6100, 6199, 6300, 6399, 6400});
      expect(native.calls.where((c) => c.method == 'initialize'), hasLength(1));
      expect(
        native.calls.where((c) => c.method.contains('Permission')),
        isEmpty,
      );
      final init = native.calls.first.arguments as Map;
      expect(init['defaultIcon'], 'ic_ai_runs');
      expect(init.containsKey('dispatcher_handle'), isFalse);
      expect(init.containsKey('callback_handle'), isFalse);
      expect(
        native.calls.indexWhere(
          (c) => c.method == 'getNotificationAppLaunchDetails',
        ),
        lessThan(native.calls.indexWhere((c) => c.method == 'cancel')),
      );
    },
  );

  test(
    'failed startup cleanup is unavailable and cannot send notifications',
    () async {
      native.failCancel = 6250;
      notifications.bindRegistry(registry);
      expect(await notifications.initialize(), isFalse);
      registry.emit(AiRunNotificationKind.completed);
      await _drain();
      expect(notifications.available, isFalse);
      expect(notifications.failure, AiRunNotificationFailure.initialization);
      expect(native.shows, isEmpty);
    },
  );

  test(
    'restart reserves retained result IDs before allocating new results',
    () async {
      final occupied = 6300 + _payload().hashCode % 100;
      native.liveIds.add(occupied);
      notifications.bindRegistry(registry);
      await notifications.initialize();
      registry.emit(AiRunNotificationKind.completed);
      await _drain();
      expect(native.shows.single['id'], isNot(occupied));
      expect(native.liveIds, contains(occupied));
      expect(
        native.calls.where((c) => c.method == 'getActiveNotifications'),
        hasLength(1),
      );
    },
  );

  test(
    'a drawer full of retained results reports capacity without overwriting',
    () async {
      native.liveIds.addAll(List.generate(100, (i) => 6300 + i));
      notifications.bindRegistry(registry);
      await notifications.initialize();
      registry.emit(AiRunNotificationKind.completed);
      await _drain();
      expect(native.shows, isEmpty);
      expect(notifications.failure, AiRunNotificationFailure.idRangeFull);
      expect(notifications.available, isFalse);
      registry.emit(AiRunNotificationKind.needsApproval);
      await _drain();
      expect(native.shows.single['id'], inInclusiveRange(6200, 6299));
      expect(notifications.failure, AiRunNotificationFailure.idRangeFull);
      expect(notifications.available, isFalse);
      native.liveIds.remove(6307);
      registry.emit(AiRunNotificationKind.completed);
      await _drain();
      expect(native.shows.last['id'], 6307);
      expect(notifications.failure, isNull);
      expect(notifications.available, isTrue);
    },
  );

  test(
    'active-ID read failure stops initialization without guessing a free ID',
    () async {
      native.failActive = true;
      notifications.bindRegistry(registry);
      expect(await notifications.initialize(), isFalse);
      registry.emit(AiRunNotificationKind.completed);
      await _drain();
      expect(native.shows, isEmpty);
      expect(notifications.failure, AiRunNotificationFailure.initialization);
    },
  );

  test(
    'delivery and text provider failures expose safe status and notify UI',
    () async {
      var failText = false;
      final other = AiRunNotifications(
        text: () {
          if (failText) throw StateError('PROMPT_SENTINEL');
          return _text;
        },
      )..bindRegistry(registry);
      addTearDown(other.dispose);
      await other.initialize();
      var changes = 0;
      other.addListener(() => changes++);
      native.failShow = true;
      registry.emit(AiRunNotificationKind.completed);
      await _drain();
      expect(other.failure, AiRunNotificationFailure.delivery);
      expect(other.available, isFalse);
      expect(changes, 1);
      native.failShow = false;
      registry.emit(AiRunNotificationKind.completed);
      await _drain();
      expect(other.failure, isNull);
      expect(other.available, isTrue);
      expect(changes, 2);
      failText = true;
      registry.emit(AiRunNotificationKind.failed);
      await _drain();
      expect(other.failure, AiRunNotificationFailure.delivery);
      expect(changes, 3);
    },
  );

  test('four kinds map exactly to generic private displayed fields', () async {
    notifications.bindRegistry(registry);
    await notifications.initialize();
    for (final kind in AiRunNotificationKind.values) {
      registry.emit(kind);
    }
    await _drain();
    expect(native.shows.map((s) => s['body']), [
      _text.needsApproval,
      _text.completed,
      _text.failed,
      _text.interrupted,
    ]);
    expect(native.shows, hasLength(4));
    for (final show in native.shows) {
      expect(show['title'], _text.title);
      expect(jsonDecode(show['payload']! as String), {
        'conversationId': chat.id,
        'generation': 8,
      });
      final android = show['platformSpecifics']! as Map;
      expect(android['visibility'], NotificationVisibility.private.index);
      expect(android['actions'] ?? <Object?>[], isEmpty);
      // Entire platform map includes channel labels, ticker/subText, style and
      // any plugin default display fields; no sensitive sentinel may appear.
      for (final sentinel in _sentinels) {
        expect(jsonEncode(show), isNot(contains(sentinel)));
      }
    }
    final approval = native.shows.first['platformSpecifics']! as Map;
    expect(approval['importance'], Importance.high.value);
    expect(approval['priority'], Priority.high.value);
    expect(native.shows.first['id'], inInclusiveRange(6200, 6299));
    for (final result in native.shows.skip(1)) {
      expect(result['id'], inInclusiveRange(6300, 6399));
      final android = result['platformSpecifics']! as Map;
      expect(android['importance'], Importance.defaultImportance.value);
      expect(android['priority'], Priority.defaultPriority.value);
    }
  });

  test(
    'delivery reads the current injected language without conversation text',
    () async {
      notifications.bindRegistry(registry);
      await notifications.initialize();
      registry.emit(AiRunNotificationKind.completed);
      await _drain();
      currentText = const AiRunNotificationText(
        approvalChannelName: 'Locale B approvals',
        resultChannelName: 'Locale B results',
        title: 'Locale B work',
        needsApproval: 'Locale B approval',
        completed: 'Locale B completion',
        failed: 'Locale B failure',
        interrupted: 'Locale B interruption',
      );
      registry.emit(AiRunNotificationKind.completed);
      await _drain();
      expect(native.shows.map((s) => s['body']), [
        _text.completed,
        currentText.completed,
      ]);
      expect(native.shows.last['title'], currentText.title);
      expect(
        (native.shows.last['platformSpecifics']! as Map)['channelName'],
        currentText.resultChannelName,
      );
      expect(native.shows.first['id'], native.shows.last['id']);
    },
  );

  test(
    'hash collisions probe within each reserved range and IDs remain stable',
    () async {
      final seen = <int, String>{};
      late String a;
      late String b;
      for (var i = 0; i <= 100; i++) {
        final id = 'collision-$i';
        final slot = _payload(id).hashCode % 100;
        final previous = seen[slot];
        if (previous != null) {
          a = previous;
          b = id;
          break;
        }
        seen[slot] = id;
      }
      notifications.bindRegistry(registry);
      await notifications.initialize();
      for (final kind in [
        AiRunNotificationKind.needsApproval,
        AiRunNotificationKind.completed,
      ]) {
        for (final id in [a, b, a]) {
          chat.id = id;
          registry.emit(kind);
          await _drain();
        }
      }
      final ids = native.shows.map((s) => s['id']).toList();
      expect(ids[0], isNot(ids[1]));
      expect(ids[0], ids[2]);
      expect(ids[3], isNot(ids[4]));
      expect(ids[3], ids[5]);
      expect(ids.take(3), everyElement(inInclusiveRange(6200, 6299)));
      expect(ids.skip(3), everyElement(inInclusiveRange(6300, 6399)));
    },
  );

  test(
    'saturated allocator replaces an old ID without leaving its range',
    () async {
      notifications.bindRegistry(registry);
      await notifications.initialize();
      for (var i = 0; i <= 100; i++) {
        chat.id = 'bounded-$i';
        registry.emit(AiRunNotificationKind.needsApproval);
        await _drain();
      }
      final ids = native.shows.map((s) => s['id']).toList();
      expect(ids.take(100).toSet(), hasLength(100));
      expect(ids.last, ids.first);
      chat.id = 'bounded-0';
      registry.emit(AiRunNotificationKind.needsApproval);
      await _drain();
      expect(native.shows.last['id'], ids[1]);
      expect(
        native.shows.map((s) => s['id']),
        everyElement(inInclusiveRange(6200, 6299)),
      );
    },
  );

  for (final cold in [true, false]) {
    final source = cold ? 'cold' : 'warm';
    test(
      '$source tap waits for loaded AND unlocked gate and opens current card',
      () async {
        notifications.bindRegistry(registry);
        if (cold) native.launchPayload = _payload();
        await notifications.initialize();
        if (!cold) await native.tap(_payload());
        expect(notifications.pendingOpen?.route.conversationId, chat.id);
        expect(take(loaded: false), isNull);
        expect(take(loaded: false, unlocked: false), isNull);
        expect(take(unlocked: false), isNull);
        final result = take()!;
        expect(result.session, same(chat));
        expect(result.proposal, same(chat.proposals.single));
        expect(take(), isNull);
      },
    );

    test(
      '$source cancelled unlock cannot navigate, including a later consume',
      () async {
        notifications.bindRegistry(registry);
        if (cold) native.launchPayload = _payload();
        await notifications.initialize();
        if (!cold) await native.tap(_payload());
        var navigations = 0;
        if (take(unlocked: false)?.session != null) navigations++;
        notifications.discardPendingOpen();
        if (take()?.session != null) navigations++;
        expect(navigations, 0);
      },
    );

    for (final stale in [
      'id',
      'generation',
      'owner',
      'membership',
      'session',
    ]) {
      test(
        '$source tap refuses stale $stale without restoring a session',
        () async {
          notifications.bindRegistry(registry);
          if (cold) native.launchPayload = _payload();
          await notifications.initialize();
          if (!cold) await native.tap(_payload());
          switch (stale) {
            case 'id':
              chat.id = 'changed-id';
            case 'generation':
              registry.generation++;
            case 'owner':
              final replacement = _Registry(chat);
              addTearDown(replacement.dispose);
              notifications.bindRegistry(replacement);
            case 'membership':
              registry.current = false;
            case 'session':
              final replacement = _Chat(chat.id);
              addTearDown(replacement.dispose);
              registry.chat = replacement;
          }
          final result = take()!;
          expect(result.session, isNull);
          expect(result.proposal, isNull);
        },
      );
    }
  }

  test(
    'cold tap before binding resolves only an existing current session',
    () async {
      native.launchPayload = _payload();
      await notifications.initialize();
      notifications.bindRegistry(registry);
      expect(take()!.session, same(chat));
    },
  );

  test(
    'cold tap with a reused generation but no live conversation falls home',
    () async {
      native.launchPayload = _payload();
      await notifications.initialize();
      registry.chat = null;
      notifications.bindRegistry(registry);
      expect(take()!.session, isNull);
    },
  );

  test(
    'stale ID or generation at receipt cannot create navigation authority',
    () async {
      notifications.bindRegistry(registry);
      await notifications.initialize();
      for (final payload in [_payload('absent'), _payload(chat.id, 7)]) {
        await native.tap(payload);
        expect(take()!.session, isNull);
      }
    },
  );

  test(
    'a gone card falls back to conversation; a replacement is read at consume',
    () async {
      notifications.bindRegistry(registry);
      await notifications.initialize();
      await native.tap(_payload());
      chat.proposals = [];
      final gone = take()!;
      expect(gone.session, same(chat));
      expect(gone.proposal, isNull);
      await native.tap(_payload());
      final replacement = _proposal('replacement');
      chat.proposals = [
        _proposal('invalid')..invalidate(),
        _proposal(
          'expired',
          expiry: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
        replacement,
      ];
      expect(take()!.proposal, same(replacement));
    },
  );

  test('malformed payloads and notification actions are ignored', () async {
    notifications.bindRegistry(registry);
    await notifications.initialize();
    for (final payload in [
      '',
      'not-json',
      '[]',
      '{}',
      '{"conversationId":"conversation-1","generation":true}',
      '{"conversationId":"conversation-1","generation":8.0}',
      '{"conversationId":"conversation-1","generation":-1}',
      '{"conversationId":"conversation-1","generation":8,"approve":true}',
      _payload(''),
      _payload('bad\nroute'),
      _payload('a' * 129),
      _payload('ok', 9007199254740992),
      'a' * 513,
    ]) {
      await native.tap(payload);
      expect(notifications.pendingOpen, isNull, reason: payload);
    }
    await native.tap(_payload(), type: 1);
    await native.tap(_payload(), actionId: 'approve');
    await native.tap(_payload(), input: 'PROMPT_SENTINEL');
    expect(notifications.pendingOpen, isNull);
    expect(take(), isNull);
  });

  test(
    'stale events and queued events from a replaced owner are not displayed',
    () async {
      notifications.bindRegistry(registry);
      await notifications.initialize();
      registry.emit(AiRunNotificationKind.failed, generation: 7);
      registry.emit(AiRunNotificationKind.failed, id: 'absent');
      registry.emit(AiRunNotificationKind.completed);
      notifications.bindRegistry(null);
      await _drain();
      registry.emit(AiRunNotificationKind.failed);
      await _drain();
      expect(native.shows, isEmpty);
    },
  );

  test(
    'permission is explicit and refusal leaves notification routing usable',
    () async {
      notifications.bindRegistry(registry);
      await notifications.initialize();
      registry.emit(AiRunNotificationKind.completed);
      await _drain();
      expect(
        native.calls.where((c) => c.method.contains('Permission')),
        isEmpty,
      );
      native.permission = false;
      expect(await notifications.requestPermission(), isFalse);
      await native.tap(_payload());
      expect(take()!.session, same(chat));
      expect(
        native.calls.where((c) => c.method == 'requestNotificationsPermission'),
        hasLength(1),
      );
    },
  );

  test(
    'iOS is unsupported and never initializes or requests permission',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(notifications.supported, isFalse);
      expect(await notifications.initialize(), isFalse);
      expect(await notifications.requestPermission(), isNull);
      expect(await notifications.areNotificationsEnabled(), isNull);
      expect(native.calls, isEmpty);
    },
  );

  test(
    'notification state reads app permission without requesting it',
    () async {
      expect(await notifications.areNotificationsEnabled(), isTrue);
      native.notificationsEnabled = false;
      expect(await notifications.areNotificationsEnabled(), isFalse);
      native.notificationsEnabled = null;
      expect(await notifications.areNotificationsEnabled(), isNull);
      native.failState = true;
      expect(await notifications.areNotificationsEnabled(), isNull);
      expect(
        native.calls.where((c) => c.method == 'requestNotificationsPermission'),
        isEmpty,
      );
    },
  );

  for (final id in ['ai_run_approvals_v1', 'ai_run_results_v1']) {
    test('blocked $id channel counts as notifications disabled', () async {
      native.channels = [notificationChannel(id, importance: 0)];
      expect(await notifications.areNotificationsEnabled(), isFalse);
      native.channels = [notificationChannel(id)];
      expect(await notifications.areNotificationsEnabled(), isTrue);
    });
  }

  test(
    'absent or unrelated channels are allowed; unreadable is unknown',
    () async {
      native.channels = [];
      expect(await notifications.areNotificationsEnabled(), isTrue);
      native.channels = [notificationChannel('unrelated', importance: 0)];
      expect(await notifications.areNotificationsEnabled(), isTrue);
      native.channels = null;
      expect(await notifications.areNotificationsEnabled(), isNull);
    },
  );

  test('disposed owner ignores taps and pending event delivery', () async {
    final other = AiRunNotifications(text: () => _text)..bindRegistry(registry);
    await other.initialize();
    registry.emit(AiRunNotificationKind.completed);
    other.dispose();
    await _drain();
    await native.tap(_payload());
    expect(native.shows, isEmpty);
    expect(other.pendingOpen, isNull);
    expect(await other.initialize(), isFalse);
    expect(other.available, isFalse);
  });
}
