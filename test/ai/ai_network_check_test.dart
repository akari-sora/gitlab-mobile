import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_network_check.dart';

void main() {
  AiEndpoint endpoint(String host) =>
      AiEndpoint.parse('http://$host/v1', allowLanCleartext: true);

  test(
    'enumerates link-local interfaces and accepts the same coarse block',
    () async {
      bool? capturedIncludeLinkLocal;
      final needsConfirmation = await cleartextLanNeedsConfirmation(
        endpoint('169.254.8.9'),
        listAddresses: ({required includeLinkLocal}) async {
          capturedIncludeLinkLocal = includeLinkLocal;
          return <InternetAddress>[InternetAddress('169.254.2.3')];
        },
      );

      expect(capturedIncludeLinkLocal, isTrue);
      expect(needsConfirmation, isFalse);
    },
  );

  test('requires confirmation for a different private block', () async {
    expect(
      await cleartextLanNeedsConfirmation(
        endpoint('10.0.2.2'),
        listAddresses: ({required includeLinkLocal}) async => <InternetAddress>[
          InternetAddress('192.168.1.20'),
        ],
      ),
      isTrue,
    );
  });

  test(
    'requires confirmation when interface enumeration is unavailable',
    () async {
      expect(
        await cleartextLanNeedsConfirmation(
          endpoint('100.64.1.2'),
          listAddresses: ({required includeLinkLocal}) async =>
              throw const SocketException('synthetic unavailable'),
        ),
        isTrue,
      );
    },
  );

  test('loopback and HTTPS endpoints do not enumerate interfaces', () async {
    var calls = 0;
    Future<List<InternetAddress>> unexpected({
      required bool includeLinkLocal,
    }) async {
      calls += 1;
      return const <InternetAddress>[];
    }

    expect(
      await cleartextLanNeedsConfirmation(
        endpoint('127.0.0.2'),
        listAddresses: unexpected,
      ),
      isFalse,
    );
    expect(
      await cleartextLanNeedsConfirmation(
        AiEndpoint.parse(
          'https://api.example.test/v1',
          allowLanCleartext: false,
        ),
        listAddresses: unexpected,
      ),
      isFalse,
    );
    expect(calls, 0);
  });

  test('IPv6 uses the same unique-local and link-local blocks', () async {
    expect(
      await cleartextLanNeedsConfirmation(
        endpoint('[fd12::1]'),
        listAddresses: ({required includeLinkLocal}) async => <InternetAddress>[
          InternetAddress('fc34::2'),
        ],
      ),
      isFalse,
    );
    expect(
      await cleartextLanNeedsConfirmation(
        endpoint('[fe80::1]'),
        listAddresses: ({required includeLinkLocal}) async => <InternetAddress>[
          InternetAddress('fd12::2'),
        ],
      ),
      isTrue,
    );
  });
}
