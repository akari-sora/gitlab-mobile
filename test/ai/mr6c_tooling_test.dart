import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../../tool/mr6c_qa_fixture.dart';
import '../../tool/mr6c_qa_protocol.dart';

Map<String, Object> _command({
  int sequence = 1,
  String session = 'session-1',
}) => {
  'schema': 1,
  'session': session,
  'case': 'V9',
  'variant': 'user_stop',
  'phase': 'prepare',
  'sequence': sequence,
};

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('QA must be explicitly enabled and Android', () {
    expect(qaMayStart(enabled: false, android: false), isFalse);
    expect(qaMayStart(enabled: false, android: true), isFalse);
    expect(qaMayStart(enabled: true, android: false), isFalse);
    expect(qaMayStart(enabled: true, android: true), isTrue);
  });

  test('strict command schema rejects malformed, extra and private fields', () {
    final valid = _command();
    expect(QaCommand.parse(valid).toJson(), valid);
    for (final bad in <Map<String, Object?>>[
      {...valid, 'token': 'secret'},
      {...valid, 'schema': 1.0},
      {...valid, 'permit': 'secret'},
      {...valid, 'case': 'V13'},
      {...valid, 'case': 'V01'},
      {...valid, 'phase': 'execute'},
      {...valid, 'sequence': 0},
      {...valid, 'sequence': true},
      {...valid, 'sequence': 1.0},
      {...valid, 'sequence': 9007199254740992},
      {...valid, 'session': 'x\ny'},
      {...valid, 'variant': '../escape'},
      {...valid}..remove('phase'),
    ]) {
      expect(() => QaCommand.parse(bad), throwsA(isA<QaProtocolException>()));
    }
  });

  test('sequences are bound to a session and reject replay', () {
    final command = QaCommand.parse(_command());
    final state = QaSequenceState.accept(null, command);
    expect(
      () => QaSequenceState.accept(state, command),
      throwsA(isA<QaProtocolException>()),
    );
    final newer = QaCommand.parse(_command(sequence: 2));
    expect(
      () => QaSequenceState.accept(state, newer),
      throwsA(isA<QaProtocolException>()),
    );
    final recovered = QaCommand.parse({
      ..._command(sequence: 2),
      'phase': 'recover',
    });
    expect(QaSequenceState.accept(state, recovered).sequence, 2);
    expect(
      () => QaSequenceState.accept(null, recovered),
      throwsA(isA<QaProtocolException>()),
    );
    final foreign = QaCommand.parse(_command(sequence: 3, session: 'other'));
    expect(
      () => QaSequenceState.accept(state, foreign),
      throwsA(isA<QaProtocolException>()),
    );
    expect(
      () => QaSequenceState.parse({
        'schema': 1,
        'session': 'session-1',
        'sequence': true,
      }),
      throwsA(isA<QaProtocolException>()),
    );
  });

  test('ready ack requires exact envelope and event; stale acks fail', () {
    final command = QaCommand.parse(_command());
    final ready = QaEvent(command, QaEventKind.ready, QaOutcome.running);
    expect(
      ready.isAcknowledgedBy({...command.toJson(), 'event': 'ready'}),
      isTrue,
    );
    for (final bad in <Map<String, Object>>[
      {...command.toJson(), 'event': 'barrier'},
      {...command.toJson(), 'event': 'ready', 'sequence': 2},
      {...command.toJson(), 'event': 'ready', 'session': 'other'},
      {...command.toJson(), 'event': 'ready', 'phase': 'recover'},
      {...command.toJson(), 'event': 'ready', 'extra': 1},
    ]) {
      expect(ready.isAcknowledgedBy(bad), isFalse);
    }
  });

  test('markers cannot turn an unsupported case into PASS', () {
    final command = QaCommand.parse(_command());
    expect(
      () => QaEvent(command, QaEventKind.done, QaOutcome.pass),
      throwsA(isA<QaProtocolException>()),
    );
    expect(
      () => QaEvent(command, QaEventKind.ready, QaOutcome.pass),
      throwsA(isA<QaProtocolException>()),
    );
    final event = QaEvent(
      command,
      QaEventKind.done,
      QaOutcome.notRun,
      reason: QaReason.fixtureUnavailable,
    ).toJson();
    expect(event['outcome'], 'NOT_RUN');
    expect(event['evidence'], {'reason': 'fixture_unavailable'});
    final encoded = jsonEncode(event);
    expect(encoded, isNot(contains('permit')));
    expect(encoded, isNot(contains('ticket')));
    expect(encoded, isNot(contains('account')));
    expect(encoded, isNot(contains('token')));
  });

  test('real temporary mailbox persists replay fence before ready', () async {
    final dir = await Directory.systemTemp.createTemp('mr6c-mailbox-');
    addTearDown(() => dir.delete(recursive: true));
    final mailbox = QaMailbox(dir);
    await File(
      '${dir.path}/command.json',
    ).writeAsString(jsonEncode(_command()));
    final command = await mailbox.acceptCommand();
    final ready = QaEvent(command, QaEventKind.ready, QaOutcome.running);
    await mailbox.publish(ready);
    expect(await mailbox.acknowledged(ready), isFalse);
    await File(
      '${dir.path}/ack.json',
    ).writeAsString(jsonEncode({...command.toJson(), 'event': 'ready'}));
    expect(await mailbox.acknowledged(ready), isTrue);
    await expectLater(
      mailbox.acceptCommand(),
      throwsA(isA<QaProtocolException>()),
    );
    final recovered = _command(sequence: 2)..['phase'] = 'recover';
    await File('${dir.path}/command.json').writeAsString(jsonEncode(recovered));
    expect((await mailbox.acceptCommand()).phase, 'recover');
    expect(
      await mailbox.acknowledged(
        QaEvent(
          QaCommand.parse(recovered),
          QaEventKind.ready,
          QaOutcome.running,
        ),
      ),
      isFalse,
    );
  });

  test(
    'malformed or oversized mailbox input fails without echoing input',
    () async {
      final dir = await Directory.systemTemp.createTemp('mr6c-mailbox-');
      addTearDown(() => dir.delete(recursive: true));
      final mailbox = QaMailbox(dir);
      await File('${dir.path}/command.json').writeAsString('secret' * 3000);
      await expectLater(
        mailbox.acceptCommand(),
        throwsA(isA<QaProtocolException>()),
      );
      await mailbox.publishInvalidCommand();
      expect(
        await File('${dir.path}/error.json').readAsString(),
        isNot(contains('secret')),
      );
    },
  );

  test(
    'sandbox rejects unknown secure data and files before seeding',
    () async {
      final dir = await Directory.systemTemp.createTemp('mr6c-sandbox-');
      addTearDown(() => dir.delete(recursive: true));
      const storage = FlutterSecureStorage();
      FlutterSecureStorage.setMockInitialValues({'owner-key': 'private-value'});
      final sandbox = QaSandbox(support: dir, storage: storage);
      await expectLater(sandbox.seed(), throwsA(isA<QaSandboxUnavailable>()));
      expect(await storage.readAll(), {'owner-key': 'private-value'});
      FlutterSecureStorage.setMockInitialValues({});
      await File('${dir.path}/unknown.dat').writeAsString('private-value');
      await expectLater(sandbox.seed(), throwsA(isA<QaSandboxUnavailable>()));
      expect(await storage.readAll(), isEmpty);
      expect(
        await File('${dir.path}/unknown.dat').readAsString(),
        'private-value',
      );
    },
  );

  test(
    'recovery preflight binds the exact encrypted journal before recovery',
    () async {
      final dir = await Directory.systemTemp.createTemp('mr6c-journal-');
      addTearDown(() => dir.delete(recursive: true));
      FlutterSecureStorage.setMockInitialValues({});
      final sandbox = QaSandbox(
        support: dir,
        storage: const FlutterSecureStorage(),
      );
      await Directory('${dir.path}/mr6c_qa').create();
      await sandbox.seed();
      final journal = AiWriteJournal(
        keys: sandbox.keys,
        applicationSupport: dir,
        processId: 'synthetic-prepare',
      );
      await journal.recoverAfterAccountsLoaded([sandbox.account.key]);
      final conflict = AiConflictKey([
        sandbox.account.key,
        'project:42',
        'issue:synthetic',
      ]);
      final draft = AiJournalDraft(
        executionId: 'synthetic-execution',
        accountKey: sandbox.account.key,
        conversationId: 'synthetic-conversation',
        runId: 'synthetic-run',
        operationId: 'createIssue',
        writeKeys: {conflict},
        payloadSha256: List.filled(64, 'a').join(),
        releaseName: 'synthetic',
      );
      await journal.prepare(draft: draft);
      await journal.markDispatching(executionId: draft.executionId);
      final bytes = (await sandbox.files.read(sandbox.account.key))!;
      final key = (await sandbox.keys.readKey(sandbox.account.key)).value!;
      final plaintext = await AiHistoryCipher.decryptJson(
        bytes,
        key,
        sandbox.account.key,
        AiJournalFiles.fileName,
      );
      String objectHash(Object? value) =>
          sha256.convert(utf8.encode(jsonEncode(value))).toString();
      final fileDigest = sha256.convert(bytes).toString();
      final command = QaCommand.parse({
        ..._command(),
        'variant': 'task_manager_stop',
        'phase': 'recover',
        'sequence': 2,
      });
      final checkpoint = {
        'schema': 1,
        'session': command.session,
        'case': 'V9',
        'variant': command.variant,
        'execution_digest': objectHash(draft.executionId),
        'file_digest': fileDigest,
        'plaintext_digest': objectHash(plaintext),
      };
      await File(
        '${dir.path}/mr6c_qa/v9_checkpoint.json',
      ).writeAsString(jsonEncode(checkpoint));
      expect(
        (await sandbox.verifyRecovery(command))['file_digest'],
        fileDigest,
      );
      final foreign = QaCommand.parse({
        ...command.toJson(),
        'session': 'foreign',
      });
      await expectLater(
        sandbox.verifyRecovery(foreign),
        throwsA(isA<QaSandboxUnavailable>()),
      );
      final foreignFile = File('${dir.path}/ai_write_journal/unknown');
      await foreignFile.writeAsString('private-value');
      await expectLater(
        sandbox.verifyRecovery(command),
        throwsA(isA<QaSandboxUnavailable>()),
      );
      expect(await foreignFile.readAsString(), 'private-value');
      expect(
        sha256
            .convert((await sandbox.files.read(sandbox.account.key))!)
            .toString(),
        fileDigest,
      );
      await foreignFile.delete(); // This test created the file itself.
      final restarted = AiWriteJournal(
        keys: sandbox.keys,
        applicationSupport: dir,
        processId: 'synthetic-recover',
      );
      await restarted.recoverAfterAccountsLoaded([sandbox.account.key]);
      final recovered = restarted.entries(sandbox.account.key).single;
      expect(recovered.executionId, draft.executionId);
      expect(recovered.state, AiJournalState.writeUncertain);
      expect(
        restarted.isolated(sandbox.account.key, recovered.writeKeys),
        isTrue,
      );
    },
  );

  test(
    'V9 prepare reaches a held production journal dispatch on a host mock channel',
    () async {
      final dir = await Directory.systemTemp.createTemp('mr6c-v9-');
      addTearDown(() => dir.delete(recursive: true));
      await Directory('${dir.path}/mr6c_qa').create();
      FlutterSecureStorage.setMockInitialValues({});
      TestWidgetsFlutterBinding.ensureInitialized()
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      const channel = MethodChannel('mr6c-host-native-mock');
      var ticket = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map<Object?, Object?>;
            switch (call.method) {
              case 'moveTaskToBack':
                return {
                  'version': 1,
                  'status': 'unsupported',
                  'reason': 'not_implemented',
                };
              case 'startRuns':
                return {
                  'version': 1,
                  'status': 'active',
                  'permitId': 'host-test-permit',
                  'startRequestId': args['startRequestId'],
                  'opSeq': args['opSeq'],
                };
              case 'acquireContinuation':
                return {
                  'version': 1,
                  'status': 'ticket',
                  'permitId': 'host-test-permit',
                  'kind': args['kind'],
                  'nonce': args['nonce'],
                  'ticketId':
                      '00000000-0000-4000-8000-${(++ticket).toString().padLeft(12, '0')}',
                };
              case 'updateProgress':
                return {
                  'version': 1,
                  'status': 'updated',
                  'permitId': 'host-test-permit',
                };
              case 'stopAll':
                return {'version': 1, 'status': 'stopped'};
              case 'releaseRuns':
                return {'version': 1, 'status': 'released', 'didRelease': true};
            }
            throw StateError('unexpected native method');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final sandbox = QaSandbox(
        support: dir,
        storage: const FlutterSecureStorage(),
      );
      final command = QaCommand.parse({
        ..._command(),
        'variant': 'task_manager_stop',
      });
      final fixture = QaV9Fixture(sandbox, command, testChannel: channel);
      final barrier = await fixture.prepare().timeout(
        const Duration(seconds: 20),
      );
      expect(barrier.dispatchAccepted, isTrue);
      expect(barrier.journalFlushed, isTrue);
      expect(barrier.mutationCalls, 1);
      expect(barrier.modelCalls, greaterThan(0));
      expect(
        fixture.journal.entries(sandbox.account.key).single.state,
        AiJournalState.dispatching,
      );
      expect(
        await File('${dir.path}/mr6c_qa/v9_checkpoint.json').exists(),
        isTrue,
      );
      final recoverCommand = QaCommand.parse({
        ...command.toJson(),
        'phase': 'recover',
        'sequence': 2,
      });
      expect(
        (await sandbox.verifyRecovery(recoverCommand))['execution_digest'],
        barrier.executionDigest,
      );
      fixture.registry.dispose();
      fixture.settings.dispose();
      fixture.session.dispose();
    },
  );
}
