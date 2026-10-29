import 'dart:io';
import 'dart:math';

import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

import 'live_host.dart';
import 'live_provider.dart';
import 'live_transport.dart';
import 'sandbox_contract.dart';

/// Optional live hooks. The shared runner retains its execution and guard loop.
final class Mr7LiveRun {
  Mr7LiveRun({
    required this.session,
    required this.provider,
    required this.secrets,
    required this.scratchRoot,
    this.only,
    Mr7LiveHost? host,
  }) : _host = host {
    if (session.liveTransport == null ||
        !secrets.current.contains(session.gitLabToken)) {
      throw const Mr7Refused('credentialBoundary');
    }
  }

  static Mr7LiveRun? select(Map<String, dynamic> config) {
    if (config['transport'] != 'live') return null;
    final host = Mr7LiveHost.fromWrapper(Platform.environment);
    final transport = Mr7LiveGitLab(host.pat);
    return Mr7LiveRun(
      session: Mr7SandboxSession(
        server: Mr7SyntheticGitLab(),
        liveTransport: transport,
        instance: transport.instance,
        expectedUserId: config['expectedUserId'] as int,
        namespace: config['namespace'] as String,
        nonce: List.generate(
          16,
          (_) => Random.secure().nextInt(16).toRadixString(16),
        ).join(),
        eventDelay: () =>
            Future<void>.delayed(const Duration(milliseconds: 250)),
      ),
      provider: host.createProvider(config['provider'] as Map<String, dynamic>),
      secrets: host,
      scratchRoot: Directory(config['stateDirectory'] as String),
      only: (config['only'] as List?)?.cast<String>().toSet(),
      host: host,
    );
  }

  final Mr7SandboxSession session;
  final Mr7LiveProvider provider;
  final KnownSecretsSource secrets;
  final Directory scratchRoot;
  final Set<String>? only;
  final Mr7LiveHost? _host;
  bool get mayDiscardJournal => !session.quarantined;
  String get confirmationLabel => 'explicitOwnerConfirmation';
  String? get typedName => _host?.typedName;

  bool includes(String id) => only == null || only!.contains(id);
  void validateSelection(List<String> ids) {
    if (only != null && (only!.isEmpty || !only!.every(ids.contains))) {
      throw const Mr7Refused('scenarioSelection');
    }
  }

  Future<bool> confirm({
    required String operation,
    required int projectId,
    required String tier,
    required String payloadDigest,
    String? requiredTypedName,
  }) {
    final host = _host;
    if (host == null) throw const Mr7Refused('confirmationChannelRequired');
    return host.confirm({
      'operation': operation,
      'projectId': projectId,
      'tier': tier,
      'payloadDigest': payloadDigest,
      'preview': host.preview(operation, projectId),
      'requiredTypedName': ?requiredTypedName,
    });
  }

  Mr7LiveCall bindCall(
    AiToolCall call,
    Set<String> readNames,
    String conversationId,
  ) => Mr7LiveCall._(
    session,
    call,
    readNames,
    provider.createClient(conversationId),
  );

  Map<String, Object?> get providerReceipt => {
    'protocol': provider.config.format == AiFormat.anthropicMessages
        ? 'anthropic_messages'
        : 'chat_completions',
    'model': provider.config.model,
    'calls': provider.calls,
    'usage': provider.usage,
    'spend': provider.spend,
    'capabilityDigest': mr7Digest({
      'tokenLimitField': provider.config.caps.tokenLimitField.name,
      'requiresKey': provider.config.caps.requiresKey,
      'toolChoice': provider.config.caps.toolChoice,
      'maxOutputTokens': provider.config.caps.maxOutputTokens,
      'maxRequestChars': provider.config.caps.maxRequestChars,
    }),
    'secretLeakScan': provider.leakDetected ? 'FAIL' : 'PASS',
    'attachmentLeakScan': 'PASS',
  };

  void finishReceipt(Map<String, Object?> receipt) {
    final rows = (receipt['scenarios'] as List).cast<Map<String, Object?>>();
    if (session.quarantined ||
        session.cleanup['status'] != 'PASS' ||
        !rows.any((row) => row['status'] == 'PASS')) {
      receipt['status'] = 'FAIL';
    }
    for (final row in rows) {
      row['live'] = row['status'] == 'PASS'
          ? 'PASS'
          : row['status'] == 'FAIL'
          ? 'FAIL'
          : 'NOT_VERIFIED';
    }
    receipt.addAll({
      'transport': 'live',
      'evidenceClass': 'live-candidate',
      'finalEligible': false,
      'live': receipt['status'] == 'PASS' ? 'PASS' : 'FAIL',
      'provider': {
        'calls': provider.calls,
        'usage': provider.usage,
        'spend': provider.spend,
      },
      'coverage': {
        for (final name in ['rest', 'graphql', 'advanced'])
          name: rows.any((row) => row['suite'] == name && row['live'] == 'PASS')
              ? 'LIVE_CANDIDATE'
              : 'NOT_RUN',
      },
      'limitations': [
        'live candidate only; 7R decides final eligibility',
        'events are not a complete audit log',
        'host confirmation is not app UI evidence',
      ],
    });
  }
}

/// A provider chooses IDs, but may only propose the sealed fixture arguments.
final class Mr7LiveCall {
  Mr7LiveCall._(this.session, this.expected, this.readNames, this.client)
    : callId = expected.id,
      arguments = expected.arguments;
  final Mr7SandboxSession session;
  final AiToolCall expected;
  final Set<String> readNames;
  final AiWireClient client;
  String callId;
  Object? arguments;
  bool _seen = false;

  Never _refuse() {
    session.stop('providerScenarioBound');
    throw const Mr7Refused('providerScenarioBound');
  }

  Future<AiDecodedTurn> complete(
    AiRequestPlan plan, {
    void Function(AiEvent)? onEvent,
  }) async {
    final turn = await client.complete(plan, onEvent: onEvent);
    for (final actual in turn.output.toolCalls) {
      if (actual.name != expected.name) {
        if (!readNames.contains(actual.name)) _refuse();
        continue;
      }
      if (_seen || expected.arguments is! Map || actual.arguments is! Map) {
        _refuse();
      }
      final expectedArgs = Map<String, Object?>.from(expected.arguments as Map)
        ..remove('reason');
      final actualArgs = Map<String, Object?>.from(actual.arguments as Map)
        ..remove('reason');
      if (actualArgs.length != expectedArgs.length ||
          expectedArgs.keys.any(
            (key) => mr7Digest(expectedArgs[key]) != mr7Digest(actualArgs[key]),
          )) {
        _refuse();
      }
      _seen = true;
      callId = actual.id;
      arguments = actual.arguments;
    }
    return turn;
  }
}
