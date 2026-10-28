// Standalone, explicitly opted-in MR6c QA APK entrypoint. Production main does
// not import this file. Only V9 task-manager stop has a case driver.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../tool/mr6c_qa_fixture.dart';
import '../tool/mr6c_qa_protocol.dart';

const _qaEnabled = bool.fromEnvironment('MR6C_QA');
const _phaseDeadline = Duration(minutes: 30);

Future<void> _publishFailure(
  QaMailbox mailbox,
  QaEvent event,
  Object error,
) async {
  // Fixed identifiers and the exception type only; never messages or payloads.
  debugPrint(
    'MR6C_QA_FAILURE phase=${event.command.phase} '
    'reason=${event.reason!.name} exception_type=${error.runtimeType}',
  );
  await mailbox.publish(event);
}

Future<void> main() async {
  // Nothing, including plugin initialization or account access, runs without
  // the explicit build-time define and Android. There is no exported trigger.
  if (!qaMayStart(enabled: _qaEnabled, android: Platform.isAndroid)) return;
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(color: Colors.black),
    ),
  );

  QaMailbox? mailbox;
  QaCommand? command;
  try {
    // Android path_provider uses the app's files directory. The host writes the
    // corresponding files/mr6c_qa path via run-as, never external storage.
    final support = await getApplicationSupportDirectory();
    mailbox = QaMailbox(Directory('${support.path}/mr6c_qa'));
    command = await mailbox.acceptCommand();
    final ready = QaEvent(command, QaEventKind.ready, QaOutcome.running);
    await mailbox.publish(ready);
    final stopwatch = Stopwatch()..start();
    while (!await mailbox.acknowledged(ready)) {
      if (stopwatch.elapsed >= _phaseDeadline) {
        await mailbox.publish(
          QaEvent(
            command,
            QaEventKind.error,
            QaOutcome.fail,
            reason: QaReason.deadline,
          ),
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    if (qaSupportsV9(command)) {
      final sandbox = QaSandbox(
        support: support,
        storage: const FlutterSecureStorage(),
      );
      try {
        if (command.phase == 'prepare') {
          await sandbox.verifyEmpty();
        } else {
          await sandbox.verifyRecovery(command);
        }
      } on Object catch (error) {
        // No account, recovery or network side effects before preflight passes.
        await _publishFailure(
          mailbox,
          qaPreflightRejected(command, error),
          error,
        );
        return;
      }
      final fixture = QaV9Fixture(sandbox, command);
      if (command.phase == 'prepare') {
        final evidence = await fixture.prepare();
        final barrier = QaEvent(
          command,
          QaEventKind.barrier,
          QaOutcome.running,
          evidence: evidence,
        );
        await mailbox.publish(barrier);
        while (!await mailbox.acknowledged(barrier)) {
          if (stopwatch.elapsed >= _phaseDeadline) {
            throw TimeoutException('barrier');
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        // The host must verify this process and service died before recover.
        // No DONE event is emitted while the accepted mutation is in flight.
        while (stopwatch.elapsed < _phaseDeadline) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        throw TimeoutException('termination');
      }
      final evidence = await fixture.recover();
      await mailbox.publish(
        QaEvent(command, QaEventKind.done, QaOutcome.pass, evidence: evidence),
      );
      return;
    }

    await mailbox.publish(
      QaEvent(
        command,
        QaEventKind.done,
        QaOutcome.notRun,
        reason: QaReason.fixtureUnavailable,
      ),
    );
  } on QaProtocolException {
    if (mailbox != null) {
      try {
        await mailbox.publishInvalidCommand();
      } on Object {
        /* no raw errors */
      }
    }
  } on Object catch (error) {
    if (mailbox != null && command != null) {
      try {
        await _publishFailure(mailbox, qaFailureEvent(command, error), error);
      } on Object {
        /* no raw errors */
      }
    } else if (mailbox != null) {
      try {
        await mailbox.publishInvalidCommand();
      } on Object {
        /* no raw errors */
      }
    }
  }
}
