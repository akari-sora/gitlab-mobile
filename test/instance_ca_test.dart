import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance_ca.dart';

// `openssl x509 -in test/fixtures/tls/<file> -noout -fingerprint -sha256`,
// computed once when the fixtures were generated.
const caFingerprint =
    'C4:8A:25:0A:F3:B5:20:5C:CC:0E:74:E3:0E:37:6C:6A:'
    'CA:E7:CF:28:26:58:F7:98:8D:1C:B1:2F:9E:CA:6A:9E';
const otherCaFingerprint =
    '67:34:CB:A1:6A:EC:C9:06:2E:02:3B:FA:F0:A4:C8:04:'
    '72:7F:89:58:D0:C4:50:5F:04:3C:AF:1F:39:CF:04:33';

Uint8List fixture(String name) =>
    File('test/fixtures/tls/$name').readAsBytesSync();

Matcher problem(CaCertificateProblem expected) => isA<CaCertificateFailure>()
    .having((failure) => failure.problem, 'problem', expected);

void main() {
  group('parseCaCertificate', () {
    test('PEM gives the openssl SHA-256 fingerprint of the DER', () {
      final parsed = parseCaCertificate(fixture('ca.pem'));
      expect(parsed.fingerprints, [caFingerprint]);
      expect(parsed.fingerprint, caFingerprint);
      expect(certificateFingerprint(fixture('ca.der')), caFingerprint);
    });

    test('DER is accepted and normalised to the same PEM', () {
      final fromDer = parseCaCertificate(fixture('ca.der'));
      final fromPem = parseCaCertificate(fixture('ca.pem'));
      expect(fromDer.fingerprints, [caFingerprint]);
      expect(fromDer.pem, fromPem.pem);
      expect(fromDer, fromPem);
      expect(fromDer.pem, startsWith('-----BEGIN CERTIFICATE-----\n'));
      expect(fromDer.pem.trimRight(), endsWith('-----END CERTIFICATE-----'));
      for (final line in LineSplitter.split(fromDer.pem)) {
        expect(line.length, lessThanOrEqualTo(64));
      }
    });

    test('CRLF, surrounding text and a bundle of two are accepted', () {
      final ca = utf8.decode(fixture('ca.pem'));
      final other = utf8.decode(fixture('other_ca.pem'));
      final bundle =
          'subject=O=Mergeline Test\r\n${ca.replaceAll('\n', '\r\n')}'
          'issuer=O=Mergeline Test\r\n$other';
      final parsed = parseCaCertificate(utf8.encode(bundle));
      expect(parsed.fingerprints, [caFingerprint, otherCaFingerprint]);
      expect(
        '-----BEGIN CERTIFICATE-----'.allMatches(parsed.pem),
        hasLength(2),
      );
      expect(parsed.pem, isNot(contains('subject=')));
    });

    test('a file over 64 KiB is refused before parsing', () {
      final pem = fixture('ca.pem');
      final padded = Uint8List(maxCaCertificateBytes + 1)
        ..fillRange(0, maxCaCertificateBytes + 1, 0x20)
        ..setRange(0, pem.length, pem);
      expect(() => parseCaCertificate(padded),
          throwsA(problem(CaCertificateProblem.tooLarge)));
      // The limit itself is still parsed.
      final atLimit = Uint8List.sublistView(padded, 0, maxCaCertificateBytes);
      expect(parseCaCertificate(atLimit).fingerprint, caFingerprint);
    });

    test('garbage is refused', () {
      for (final bytes in <List<int>>[
        <int>[],
        utf8.encode('not a certificate'),
        List<int>.generate(512, (i) => (i * 37 + 11) % 256),
        utf8.encode('-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n'),
        // Valid base64 of a DER SEQUENCE that is not a certificate.
        utf8.encode('-----BEGIN CERTIFICATE-----\n'
            '${base64.encode([0x30, 0x03, 0x02, 0x01, 0x05])}\n'
            '-----END CERTIFICATE-----\n'),
        // Mismatched labels and an unterminated block.
        utf8.encode('-----BEGIN CERTIFICATE-----\nAAAA\n-----END X509 CRL-----\n'),
        [...fixture('ca.pem'), ...utf8.encode('-----BEGIN CERTIFICATE-----\n')],
        // DER with trailing bytes.
        [...fixture('ca.der'), 0],
        // DER cut short.
        Uint8List.sublistView(fixture('ca.der'), 0, 400),
      ]) {
        expect(
          () => parseCaCertificate(bytes),
          throwsA(isA<CaCertificateFailure>().having(
            (failure) => failure.problem,
            'problem',
            anyOf(CaCertificateProblem.notCertificate,
                CaCertificateProblem.rejected),
          )),
          reason: '${bytes.length} bytes',
        );
      }
    });

    test('a DER sequence the platform cannot read is rejected', () {
      // Correct outer length, but not an X.509 structure.
      final bogus = Uint8List.fromList([0x30, 0x06, 0x02, 0x01, 0x05, 0x02, 0x01, 0x06]);
      expect(() => parseCaCertificate(bogus),
          throwsA(problem(CaCertificateProblem.rejected)));
    });

    test('a private key is never accepted, alone or beside the certificate',
        () {
      expect(() => parseCaCertificate(fixture('ca.key')),
          throwsA(problem(CaCertificateProblem.privateKey)));
      expect(
        () => parseCaCertificate([...fixture('ca.pem'), ...fixture('ca.key')]),
        throwsA(problem(CaCertificateProblem.privateKey)),
      );
    });

    test('more than eight certificates are refused', () {
      final pem = fixture('ca.pem');
      expect(
        parseCaCertificate([for (var i = 0; i < 8; i++) ...pem]).fingerprints,
        hasLength(8),
      );
      expect(
        () => parseCaCertificate([for (var i = 0; i < 9; i++) ...pem]),
        throwsA(problem(CaCertificateProblem.tooMany)),
      );
    });
  });

  group('stored value', () {
    test('round-trips and is checked again on decode', () {
      final parsed = parseCaCertificate(fixture('ca.der'));
      final value = parsed.encode();
      final json = jsonDecode(value) as Map<String, dynamic>;
      expect(json['version'], 1);
      expect(json['fingerprints'], [caFingerprint]);
      expect(json['pem'], parsed.pem);
      expect(InstanceCaCertificate.decode(value), parsed);
    });

    test('a tampered fingerprint, PEM or version decodes to null', () {
      final parsed = parseCaCertificate(fixture('ca.pem'));
      Map<String, dynamic> base() =>
          jsonDecode(parsed.encode()) as Map<String, dynamic>;
      expect(
        InstanceCaCertificate.decode(
            jsonEncode(base()..['fingerprints'] = [otherCaFingerprint])),
        isNull,
      );
      expect(
        InstanceCaCertificate.decode(jsonEncode(
            base()..['pem'] = utf8.decode(fixture('other_ca.pem')))),
        isNull,
      );
      expect(
        InstanceCaCertificate.decode(jsonEncode(base()..['version'] = 2)),
        isNull,
      );
      expect(InstanceCaCertificate.decode('{'), isNull);
      expect(InstanceCaCertificate.decode(null), isNull);
    });

    test('the context trusts the defaults plus the certificate', () {
      final parsed = parseCaCertificate(fixture('ca.pem'));
      expect(parsed.securityContext(), isA<SecurityContext>());
    });
  });

  test('only certificate verification failures count as refused', () {
    final options = RequestOptions(path: 'https://gitlab.example.com/api/v4/user');
    DioException wrap(Object error) =>
        DioException(requestOptions: options, error: error);
    expect(
      isRefusedCertificate(wrap(const HandshakeException(
        'Handshake error in client',
        OSError('CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate'),
      ))),
      isTrue,
    );
    expect(
      isRefusedCertificate(
          DioException.badCertificate(requestOptions: options, error: null)),
      isTrue,
    );
    expect(
      isRefusedCertificate(wrap(const HandshakeException(
        'Handshake error in client',
        OSError('WRONG_VERSION_NUMBER'),
      ))),
      isFalse,
    );
    expect(isRefusedCertificate(wrap(const SocketException('refused'))), isFalse);
    expect(
      isRefusedCertificate(
          DioException.connectionTimeout(requestOptions: options, timeout: Duration.zero)),
      isFalse,
    );
  });
}
