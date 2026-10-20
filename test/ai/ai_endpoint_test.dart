import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';

void main() {
  group('AiEndpoint.parse', () {
    test('accepts HTTPS and normalizes its origin', () {
      final endpoint = AiEndpoint.parse(
        'https://EXAMPLE.com:443/v1/',
        allowLanCleartext: false,
      );

      expect(endpoint.base, Uri.parse('https://example.com/v1'));
      expect(endpoint.cleartext, isFalse);
      expect(
        endpoint.allows(
          Uri.parse('https://example.com/v1/responses'),
          method: 'POST',
        ),
        isTrue,
      );
    });

    const allowed = [
      '127.0.0.1',
      '10.0.0.1',
      '172.16.0.1',
      '172.31.255.255',
      '192.168.1.1',
      '169.254.2.3',
      '100.64.0.0',
      '100.127.255.255',
      '[::1]',
      '[fc00::1]',
      '[fdff::1]',
      '[fe80::1]',
      '[::ffff:192.168.1.1]',
      '[::ffff:c0a8:101]',
    ];
    for (final host in allowed) {
      test('allows cleartext $host', () {
        final endpoint = AiEndpoint.parse(
          'http://$host/v1',
          allowLanCleartext: true,
        );
        expect(endpoint.cleartext, isTrue);
      });
    }

    const denied = [
      '0.0.0.0',
      '8.8.8.8',
      '100.63.255.255',
      '100.128.0.0',
      '172.15.255.255',
      '172.32.0.0',
      '192.168.001.1',
      '198.18.0.1',
      '224.0.0.1',
      'example.com',
      'printer.local',
      '[64:ff9b::c0a8:101]',
    ];
    for (final host in denied) {
      test('rejects cleartext $host', () {
        expect(
          () => AiEndpoint.parse('http://$host/v1', allowLanCleartext: true),
          throwsA(_policyBlocked),
        );
      });
    }

    test('normalizes literal localhost without DNS', () {
      final endpoint = AiEndpoint.parse(
        'http://LOCALHOST:11434/v1',
        allowLanCleartext: true,
      );
      expect(endpoint.base.host, '127.0.0.1');
      expect(endpoint.displayHost, 'localhost (127.0.0.1)');
    });

    test('requires the explicit cleartext setting', () {
      expect(
        () => AiEndpoint.parse('http://127.0.0.1/v1', allowLanCleartext: false),
        throwsA(_policyBlocked),
      );
    });

    const invalid = [
      'https://user@example.com/v1',
      'https://example.com/v1?x=1',
      'https://example.com/v1#x',
      r'https://example.com\v1',
      'https://example.com/v1%2fmodels',
      'https://example.com/v1%5cmodels',
      'https://example.com/v1%2emodels',
      'https://example.com/v1/./models',
      'https://example.com/v1/../models',
      'https://example.com/v1//models',
      'https://example.com.:443/v1',
      'https://例子.测试/v1',
      'https://example.com:0/v1',
      'https://example.com:65536/v1',
      'http://[fe80::1%25wlan0]/v1',
    ];
    for (final value in invalid) {
      test('rejects ambiguous raw spelling $value', () {
        expect(
          () => AiEndpoint.parse(value, allowLanCleartext: true),
          throwsA(_policyBlocked),
        );
      });
    }
  });

  group('AiEndpoint.allows', () {
    final endpoint = AiEndpoint.parse(
      'https://api.example.com/v1',
      allowLanCleartext: false,
      modelsUrlOverride: 'https://api.example.com/catalog/models',
      allowKeyEndpoint: true,
    );

    test('permits only exact provider suffixes', () {
      for (final suffix in [
        'chat/completions',
        'responses',
        'messages',
        'models',
      ]) {
        expect(
          endpoint.allows(
            Uri.parse('https://api.example.com/v1/$suffix'),
            method: suffix == 'models' ? 'GET' : 'POST',
          ),
          isTrue,
        );
      }
      expect(
        endpoint.allows(
          Uri.parse('https://api.example.com/v1/responses/x'),
          method: 'POST',
        ),
        isFalse,
      );
      expect(
        endpoint.allows(
          Uri.parse('https://api.example.com/v1//responses'),
          method: 'POST',
        ),
        isFalse,
      );
      expect(
        endpoint.allows(
          Uri.parse('https://api.example.com/v1/chat%2Fcompletions'),
          method: 'POST',
        ),
        isFalse,
      );
      expect(
        endpoint.allows(
          Uri.parse('https://api.example.com/other/responses'),
          method: 'POST',
        ),
        isFalse,
      );
    });

    test('compares effective ports and origin', () {
      expect(
        endpoint.allows(Uri.parse('https://api.example.com:443/v1/models')),
        isTrue,
      );
      expect(
        endpoint.allows(Uri.parse('https://other.example.com/v1/models')),
        isFalse,
      );
    });

    test('allows only pagination query keys', () {
      expect(
        endpoint.allows(
          Uri.parse('https://api.example.com/v1/models?after_id=x&limit=20'),
        ),
        isTrue,
      );
      expect(
        endpoint.allows(
          Uri.parse('https://api.example.com/v1/models?access_token=x'),
        ),
        isFalse,
      );
    });

    test('models override and key endpoint are GET-only', () {
      final models = Uri.parse('https://api.example.com/catalog/models');
      final key = Uri.parse('https://api.example.com/v1/key');
      expect(endpoint.allows(models), isTrue);
      expect(endpoint.allows(models, method: 'POST'), isFalse);
      expect(endpoint.allows(key), isTrue);
      expect(endpoint.allows(key, method: 'POST'), isFalse);
    });

    test('provider suffixes have fixed methods', () {
      expect(
        endpoint.allows(
          Uri.parse('https://api.example.com/v1/responses'),
          method: 'GET',
        ),
        isFalse,
      );
      expect(
        endpoint.allows(
          Uri.parse('https://api.example.com/v1/models'),
          method: 'POST',
        ),
        isFalse,
      );
      expect(
        endpoint.allows(
          Uri.parse('https://api.example.com/v1/models'),
          method: 'DELETE',
        ),
        isFalse,
      );
    });

    test('models override must pass syntax and same-origin policy', () {
      expect(
        () => AiEndpoint.parse(
          'https://api.example.com/v1',
          allowLanCleartext: false,
          modelsUrlOverride: 'https://other.example.com/models',
        ),
        throwsA(_policyBlocked),
      );
      expect(
        () => AiEndpoint.parse(
          'https://api.example.com/v1',
          allowLanCleartext: false,
          modelsUrlOverride: 'https://api.example.com/a/../models',
        ),
        throwsA(_policyBlocked),
      );
    });
  });
}

final _policyBlocked = isA<AiFailure>().having(
  (failure) => failure.kind,
  'kind',
  AiFailureKind.policyBlocked,
);
