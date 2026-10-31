import 'dart:convert';
import 'dart:io'
    show HandshakeException, HttpClient, SecurityContext, TlsException;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'failure.dart';
import '../l10n/l10n.dart';

/// A CA certificate the user chose to trust for one GitLab instance.
///
/// Only the GitLab client of that instance's accounts uses it (see
/// CLAUDE.md, Persistence): other instances, external images, AI providers
/// and the update check keep the platform's default roots.
final class InstanceCaCertificate {
  const InstanceCaCertificate._(this.pem, this.fingerprints);

  /// Normalised PEM: `CERTIFICATE` blocks only, 64-column base64.
  final String pem;

  /// SHA-256 of each certificate's DER, upper-case hex pairs joined by `:`.
  final List<String> fingerprints;

  String get fingerprint => fingerprints.first;

  /// A new context per client: the default roots plus this certificate.
  /// A client keeps the context it was built with; a changed CA needs a new
  /// client.
  SecurityContext securityContext() =>
      SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificatesBytes(utf8.encode(pem));

  /// Secure-storage value, `instance_ca.v1.<base64url(instance.key)>`.
  String encode() =>
      jsonEncode({'version': 1, 'pem': pem, 'fingerprints': fingerprints});

  /// Null for anything that is not a stored value this build wrote: the PEM
  /// is parsed and checked again, and the recorded fingerprints must match.
  static InstanceCaCertificate? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> ||
          value['version'] != 1 ||
          value['pem'] is! String ||
          value['fingerprints'] is! List<dynamic>) {
        return null;
      }
      final parsed = parseCaCertificate(utf8.encode(value['pem'] as String));
      final recorded = (value['fingerprints'] as List<dynamic>).toList();
      if (recorded.length != parsed.fingerprints.length) return null;
      for (var i = 0; i < recorded.length; i++) {
        if (recorded[i] != parsed.fingerprints[i]) return null;
      }
      return parsed;
    } on Object {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is InstanceCaCertificate && other.pem == pem;

  @override
  int get hashCode => pem.hashCode;
}

enum CaCertificateProblem {
  tooLarge,
  notCertificate,
  privateKey,
  tooMany,
  rejected,
  saveFailed,
  removeFailed,
}

/// Why a picked file was not accepted, or why storing it failed.
final class CaCertificateFailure implements Exception, UserFacingFailure {
  const CaCertificateFailure(this.problem);
  final CaCertificateProblem problem;

  @override
  String get title => switch (problem) {
    CaCertificateProblem.saveFailed => l10n.caCertificateSaveFailedTitle,
    CaCertificateProblem.removeFailed => l10n.caCertificateRemoveFailedTitle,
    _ => l10n.caCertificateImportFailedTitle,
  };

  @override
  String get detail => switch (problem) {
    CaCertificateProblem.tooLarge => l10n.caCertificateTooLarge,
    CaCertificateProblem.notCertificate => l10n.caCertificateNotCertificate,
    CaCertificateProblem.privateKey => l10n.caCertificateHasPrivateKey,
    CaCertificateProblem.tooMany => l10n.caCertificateTooMany(
      '$maxCaCertificates',
    ),
    CaCertificateProblem.rejected => l10n.caCertificateRejected,
    CaCertificateProblem.saveFailed => l10n.caCertificateSaveFailedDetail,
    CaCertificateProblem.removeFailed => l10n.caCertificateRemoveFailedDetail,
  };

  @override
  String toString() => 'CaCertificateFailure(${problem.name})';
}

/// A certificate the platform refused: Dio's own certificate rejection, or a
/// handshake that failed certificate verification. Other TLS and socket
/// failures are not. The handshake ends before any HTTP byte is written.
bool isRefusedCertificate(DioException error) {
  final cause = error.error;
  return error.type == DioExceptionType.badCertificate ||
      cause is HandshakeException &&
          cause.toString().contains('CERTIFICATE_VERIFY_FAILED');
}

/// A Dio adapter whose client trusts [context] (null: the default roots),
/// with the idle timeout Dio's own default client uses.
IOHttpClientAdapter instanceHttpAdapter(
  SecurityContext? context, {
  void Function(HttpClient client)? configure,
}) => IOHttpClientAdapter(
  createHttpClient: () {
    final client = HttpClient(context: context)
      ..idleTimeout = const Duration(seconds: 3);
    configure?.call(client);
    return client;
  },
);

/// Larger files are refused before parsing; a CA bundle is a few KiB.
const maxCaCertificateBytes = 64 * 1024;

/// A root plus intermediates fits; a whole system bundle does not.
const maxCaCertificates = 8;

final _pemBlock = RegExp(
  r'-----BEGIN ([A-Z0-9 ]+)-----([\s\S]*?)-----END ([A-Z0-9 ]+)-----',
);

/// Accepts PEM (one or more `CERTIFICATE` blocks) or a single DER
/// certificate. Refuses files over [maxCaCertificateBytes], any PEM block
/// that is not a certificate (a private key is never stored), malformed
/// base64 or DER, and anything `SecurityContext.setTrustedCertificatesBytes`
/// refuses. Throws [CaCertificateFailure].
InstanceCaCertificate parseCaCertificate(List<int> bytes) {
  if (bytes.length > maxCaCertificateBytes) {
    throw const CaCertificateFailure(CaCertificateProblem.tooLarge);
  }
  final ders = _certificateDers(bytes);
  if (ders.length > maxCaCertificates) {
    throw const CaCertificateFailure(CaCertificateProblem.tooMany);
  }
  final pem = StringBuffer();
  for (final der in ders) {
    pem.writeln('-----BEGIN CERTIFICATE-----');
    final body = base64.encode(der);
    for (var i = 0; i < body.length; i += 64) {
      pem.writeln(
        body.substring(i, i + 64 < body.length ? i + 64 : body.length),
      );
    }
    pem.writeln('-----END CERTIFICATE-----');
  }
  final text = pem.toString();
  try {
    // A throwaway context: the platform parser is the final judge.
    SecurityContext(
      withTrustedRoots: false,
    ).setTrustedCertificatesBytes(utf8.encode(text));
  } on TlsException {
    throw const CaCertificateFailure(CaCertificateProblem.rejected);
  }
  return InstanceCaCertificate._(
    text,
    List.unmodifiable([for (final der in ders) certificateFingerprint(der)]),
  );
}

/// SHA-256 over the DER, formatted like `openssl x509 -fingerprint -sha256`.
String certificateFingerprint(List<int> der) => sha256
    .convert(der)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(':');

List<Uint8List> _certificateDers(List<int> bytes) {
  // latin1 never fails, so binary DER can be scanned for PEM markers too.
  final text = latin1.decode(bytes);
  if (text.contains('-----BEGIN ')) {
    final blocks = _pemBlock.allMatches(text).toList();
    if (blocks.isEmpty) {
      throw const CaCertificateFailure(CaCertificateProblem.notCertificate);
    }
    final ders = <Uint8List>[];
    for (final block in blocks) {
      final label = block.group(1)!;
      if (label != block.group(3)) {
        throw const CaCertificateFailure(CaCertificateProblem.notCertificate);
      }
      if (label.contains('PRIVATE KEY')) {
        throw const CaCertificateFailure(CaCertificateProblem.privateKey);
      }
      if (label != 'CERTIFICATE') {
        throw const CaCertificateFailure(CaCertificateProblem.notCertificate);
      }
      final Uint8List der;
      try {
        der = base64.decode(block.group(2)!.replaceAll(RegExp(r'\s'), ''));
      } on FormatException {
        throw const CaCertificateFailure(CaCertificateProblem.notCertificate);
      }
      if (!_singleDerSequence(der)) {
        throw const CaCertificateFailure(CaCertificateProblem.notCertificate);
      }
      ders.add(der);
    }
    // Text before, between or after blocks (openssl's "subject=" lines) is
    // ignored; a second BEGIN without its END is not.
    if ('-----BEGIN '.allMatches(text).length != blocks.length) {
      throw const CaCertificateFailure(CaCertificateProblem.notCertificate);
    }
    return ders;
  }
  final der = Uint8List.fromList(bytes);
  if (!_singleDerSequence(der)) {
    throw const CaCertificateFailure(CaCertificateProblem.notCertificate);
  }
  return [der];
}

/// One ASN.1 SEQUENCE whose definite length covers the input exactly.
bool _singleDerSequence(Uint8List der) {
  if (der.length < 4 || der[0] != 0x30) return false;
  final first = der[1];
  int header;
  int length;
  if (first < 0x80) {
    header = 2;
    length = first;
  } else {
    final count = first & 0x7f;
    if (count == 0 || count > 4 || der.length < 2 + count) return false;
    header = 2 + count;
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | der[2 + i];
    }
  }
  return header + length == der.length;
}
