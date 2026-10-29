import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';

import 'sandbox_contract.dart';
import 'live_provider.dart';

/// Read only the two paths delivered by credential_files(), never keychain or
/// ambient token variables. No secret is retained in a receipt or confirmation.
final class Mr7LiveHost implements KnownSecretsSource {
  Mr7LiveHost._(this.pat, this.providerKey, this.request, this.response);

  factory Mr7LiveHost.fromWrapper(Map<String, String> environment) {
    String secret(String name) {
      final path = environment[name];
      if (path == null ||
          FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const Mr7Refused('credentialFileRequired');
      }
      final file = File(path);
      final info = file.statSync();
      if ((info.mode & 0x1ff) != 0x180 || info.size > 8192) {
        throw const Mr7Refused('credentialFileInvalid');
      }
      final value = file.readAsStringSync();
      if (value.isEmpty || RegExp(r'\s').hasMatch(value)) {
        throw const Mr7Refused('credentialInvalid');
      }
      return value;
    }

    final pat = secret('MR7_GITLAB_PAT_FILE');
    final key = secret('MR7_PROVIDER_KEY_FILE');
    if (key.contains(pat) || pat.contains(key)) {
      throw const Mr7Refused('credentialOverlap');
    }
    final request = environment['MR7_CONFIRM_REQUEST_FILE'];
    final response = environment['MR7_CONFIRM_RESPONSE_FILE'];
    if (request == null || response == null || request == response) {
      throw const Mr7Refused('confirmationChannelRequired');
    }
    return Mr7LiveHost._(pat, key, File(request), File(response));
  }

  final String pat;
  final String providerKey;
  final File request;
  final File response;
  String? typedName;
  @override
  Iterable<String> get current => [pat, providerKey];

  Mr7LiveProvider createProvider(
    Map<String, dynamic> config, {
    HttpClientAdapter? adapter,
  }) => Mr7LiveProvider(config, providerKey, adapter: adapter);

  String preview(String operation, int projectId) {
    // The registered live fixture validates these exact arguments before tools.
    if (operation != 'setStar') {
      throw const Mr7Refused('livePreviewUnavailable');
    }
    return 'Private run-owned sandbox $projectId: starred = true';
  }

  Future<bool> confirm(Map<String, Object?> proposal) async {
    typedName = null;
    final encoded = jsonEncode(proposal);
    if (current.any(encoded.contains) ||
        request.existsSync() ||
        response.existsSync()) {
      throw const Mr7Refused('confirmationUnverified');
    }
    // Rename a complete request so the polling parent cannot read partial JSON.
    final staging = File('${request.path}.new');
    await staging.writeAsString(encoded, flush: true);
    await staging.rename(request.path);
    try {
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (!response.existsSync()) {
        if (DateTime.now().isAfter(deadline)) {
          throw const Mr7Refused('confirmationTimeout');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (response.lengthSync() > 4096) {
        throw const Mr7Refused('confirmationUnverified');
      }
      final result = jsonDecode(await response.readAsString());
      if (result is! Map ||
          result['approved'] is! bool ||
          result.keys.any((k) => k != 'approved' && k != 'typedName') ||
          (result['typedName'] != null && result['typedName'] is! String)) {
        throw const Mr7Refused('confirmationUnverified');
      }
      typedName = result['typedName'] as String?;
      return result['approved'] as bool;
    } finally {
      if (request.existsSync()) await request.delete();
      if (response.existsSync()) await response.delete();
    }
  }
}
