import 'dart:io';

import 'ai_failure.dart';

/// A provider base URL whose raw spelling has passed the AI egress policy.
final class AiEndpoint {
  AiEndpoint._({
    required this.base,
    required this.cleartext,
    required this.displayHost,
    required this.modelsOverride,
    required this.allowKeyEndpoint,
  });

  final Uri base;
  final bool cleartext;
  final String displayHost;
  final Uri? modelsOverride;
  final bool allowKeyEndpoint;

  static final RegExp _absolute = RegExp(
    r'^(https?)://(\[[^\]]+\]|[^/:?#]+)(?::([0-9]+))?(/[^?#]*)?$',
    caseSensitive: false,
  );
  static final RegExp _strictIpv4 = RegExp(
    r'^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$',
  );
  static final RegExp _dnsHost = RegExp(
    r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$',
  );

  factory AiEndpoint.parse(
    String input, {
    required bool allowLanCleartext,
    String? modelsUrlOverride,
    bool allowKeyEndpoint = false,
  }) {
    final parsed = _parseRaw(input, allowLanCleartext: allowLanCleartext);
    Uri? models;
    if (modelsUrlOverride != null && modelsUrlOverride.trim().isNotEmpty) {
      final override = _parseRaw(
        modelsUrlOverride,
        allowLanCleartext: allowLanCleartext,
      );
      if (!_sameOrigin(parsed.uri, override.uri)) {
        throw const AiFailure(AiFailureKind.policyBlocked);
      }
      models = override.uri;
    }
    return AiEndpoint._(
      base: parsed.uri,
      cleartext: parsed.uri.scheme == 'http',
      displayHost: parsed.displayHost,
      modelsOverride: models,
      allowKeyEndpoint: allowKeyEndpoint,
    );
  }

  String get key => base.toString().replaceFirst(RegExp(r'/$'), '');

  Uri resolve(List<String> suffix, [Map<String, String>? query]) => Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    pathSegments: [..._basePath, ...suffix],
    queryParameters: query,
  );

  bool allows(Uri uri, {String method = 'GET'}) {
    final verb = method.toUpperCase();
    if (verb != 'GET' && verb != 'POST') return false;
    if (!_safeOutgoingSpelling(uri) ||
        !_sameOrigin(base, uri) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return false;
    }
    if (uri.queryParameters.keys.any(
      (key) => key != 'after_id' && key != 'limit',
    )) {
      return false;
    }
    final override = modelsOverride;
    if (override != null && verb == 'GET' && _samePath(override, uri)) {
      return true;
    }
    final path = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    final prefix = _basePath;
    if (path.length <= prefix.length || !_startsWith(path, prefix)) {
      return false;
    }
    final suffix = path.sublist(prefix.length).join('/');
    return switch (suffix) {
      'chat/completions' || 'responses' || 'messages' => verb == 'POST',
      'models' => verb == 'GET',
      'key' => allowKeyEndpoint && verb == 'GET',
      _ => false,
    };
  }

  List<String> get _basePath =>
      base.pathSegments.where((segment) => segment.isNotEmpty).toList();

  static bool _sameOrigin(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  static bool _safeOutgoingSpelling(Uri uri) {
    final text = uri.toString();
    if (text.contains('\\') ||
        RegExp(r'%(?:2f|5c|2e)', caseSensitive: false).hasMatch(text) ||
        uri.path.contains('//')) {
      return false;
    }
    return !uri.path
        .split('/')
        .any((segment) => segment == '.' || segment == '..');
  }

  static bool _samePath(Uri left, Uri right) {
    final a = left.pathSegments.where((segment) => segment.isNotEmpty).toList();
    final b = right.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    return a.length == b.length && _startsWith(a, b);
  }

  static bool _startsWith(List<String> value, List<String> prefix) {
    if (value.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (value[i] != prefix[i]) return false;
    }
    return true;
  }

  static ({Uri uri, String displayHost}) _parseRaw(
    String input, {
    required bool allowLanCleartext,
  }) {
    final text = input.trim();
    if (text.contains('\\') ||
        RegExp(r'%(?:2f|5c|2e)', caseSensitive: false).hasMatch(text)) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final match = _absolute.firstMatch(text);
    if (match == null) throw const AiFailure(AiFailureKind.policyBlocked);
    final scheme = match.group(1)!.toLowerCase();
    final rawHost = match.group(2)!;
    final rawPort = match.group(3);
    final rawPath = match.group(4) ?? '';
    if (rawPath.contains('//') ||
        rawPath
            .split('/')
            .any((segment) => segment == '.' || segment == '..')) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final port = rawPort == null ? null : int.tryParse(rawPort);
    if (rawPort != null && (port == null || port < 1 || port > 65535)) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }

    final bracketed = rawHost.startsWith('[') && rawHost.endsWith(']');
    var host = bracketed
        ? rawHost.substring(1, rawHost.length - 1)
        : rawHost.toLowerCase();
    var displayHost = host;
    if (bracketed) {
      if (host.contains('%')) {
        throw const AiFailure(AiFailureKind.policyBlocked);
      }
      final address = InternetAddress.tryParse(host);
      if (address == null || address.type != InternetAddressType.IPv6) {
        throw const AiFailure(AiFailureKind.policyBlocked);
      }
    } else if (_strictIpv4.hasMatch(host)) {
      if (!_validIpv4(host)) throw const AiFailure(AiFailureKind.policyBlocked);
    } else if (host == 'localhost') {
      host = '127.0.0.1';
      displayHost = 'localhost (127.0.0.1)';
    } else if (host.endsWith('.') || !_dnsHost.hasMatch(host)) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }

    if (scheme == 'http') {
      if (!allowLanCleartext ||
          !_privateCleartextHost(host, bracketed: bracketed)) {
        throw const AiFailure(AiFailureKind.policyBlocked);
      }
    } else if (scheme != 'https') {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
    final defaultPort = scheme == 'https' ? 443 : 80;
    final normalizedPort = port == defaultPort ? null : port;
    final authorityHost = host.contains(':') ? '[$host]' : host;
    final normalizedPath = rawPath.length > 1 && rawPath.endsWith('/')
        ? rawPath.substring(0, rawPath.length - 1)
        : rawPath;
    final uri = Uri.parse(
      '$scheme://$authorityHost'
      '${normalizedPort == null ? '' : ':$normalizedPort'}$normalizedPath',
    );
    return (uri: uri, displayHost: displayHost);
  }

  static bool _validIpv4(String host) =>
      host.split('.').every((part) => int.parse(part) <= 255);

  static bool _privateCleartextHost(String host, {required bool bracketed}) {
    if (!bracketed && _strictIpv4.hasMatch(host) && _validIpv4(host)) {
      return _privateIpv4(InternetAddress(host).rawAddress);
    }
    if (!bracketed) return false;
    final bytes = InternetAddress(host).rawAddress;
    if (bytes.length != 16) return false;
    final loopback =
        bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
    final uniqueLocal = bytes[0] & 0xfe == 0xfc;
    final linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80;
    final mapped =
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff &&
        _privateIpv4(bytes.sublist(12));
    return loopback || uniqueLocal || linkLocal || mapped;
  }

  static bool _privateIpv4(List<int> bytes) {
    final first = bytes[0];
    final second = bytes[1];
    return first == 127 ||
        first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168) ||
        (first == 169 && second == 254) ||
        (first == 100 && second >= 64 && second <= 127);
  }
}
