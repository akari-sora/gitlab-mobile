import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';

AiProviderConfig _provider(
  AiPreset preset,
  AiFormat format,
  String url, {
  String model = 'synthetic-deployment',
}) => AiProviderConfig(
  id: 'synthetic-provider',
  name: 'Synthetic provider',
  presetId: preset.id,
  baseUrl: url,
  format: format,
  model: model,
  authStyle: preset.authStyle,
  caps: preset.caps[format] ?? preset.capsFor(preset.defaultFormat),
  allowLanCleartext: true,
  toolsEnabled: true,
  recipientRevision: 1,
);

void main() {
  for (final format in AiPresets.azure.formats) {
    for (final url in [
      'https://myres.openai.azure.com/openai/v1',
      'https://a.openai.azure.com/openai/v1',
      'https://my-resource.openai.azure.com:443/openai/v1',
    ]) {
      test('FIX3 Azure ${format.name} matches its template: $url', () {
        final contract = aiConsentContractFor(
          _provider(AiPresets.azure, format, url),
        );
        expect(
          contract.policyIdentity,
          jsonEncode({
            'preset': AiPresets.azure.id,
            'policyUrl': AiPresets.azure.policyUrl,
          }),
        );
        expect(contract.policyUrl, AiPresets.azure.policyUrl);
        expect(contract.routedModel, isNull);
        expect(contract.dataUse, AiDataUse.unknown);
      });
    }

    for (final url in [
      'https://evil.example/x.openai.azure.com/openai/v1',
      'https://a.b.openai.azure.com/openai/v1',
      'https://openai.azure.com.evil.example/openai/v1',
      'https://openai.azure.com/openai/v1',
      'https://myres.openai.azure.com/other/v1',
      'https://myres.openai.azure.com/openai/v1/extra',
      'https://myres.openai.azure.com:8443/openai/v1',
      'https://[::1]/openai/v1',
      'http://127.0.0.1/openai/v1',
    ]) {
      test('FIX3 Azure ${format.name} rejects template mismatch: $url', () {
        final contract = aiConsentContractFor(
          _provider(AiPresets.azure, format, url),
        );
        expect(contract.policyIdentity, 'custom');
        expect(contract.policyUrl, isNull);
        expect(contract.routedModel, 'synthetic-deployment');
        expect(contract.dataUse, AiDataUse.unknown);
      });
    }

    test('FIX3 Azure ${format.name} public HTTP remains policy blocked', () {
      expect(
        () => aiConsentContractFor(
          _provider(
            AiPresets.azure,
            format,
            'http://myres.openai.azure.com/openai/v1',
          ),
        ),
        throwsA(
          isA<AiFailure>().having(
            (error) => error.kind,
            'kind',
            AiFailureKind.policyBlocked,
          ),
        ),
      );
    });
  }

  test(
    'FIX3 every non-template preset and format keeps its prior identity',
    () {
      for (final preset in AiPresets.all) {
        if (preset.baseUrls.values.any((url) => url.contains('{'))) continue;
        for (final format in AiFormat.values) {
          final presetUrl = preset.baseUrls[format];
          final url = presetUrl == null || presetUrl.isEmpty
              ? 'https://synthetic.example/v1'
              : presetUrl;
          for (final model in {
            'synthetic-model',
            ...preset.modelPolicies.keys,
          }) {
            final candidate = preset.policyFor(model);
            final policy = candidate?.format == format ? candidate : null;
            final expected = preset == AiPresets.custom || presetUrl == null
                ? 'custom'
                : jsonEncode(<String, Object?>{
                    'preset': preset.id,
                    if (preset.modelSensitive) 'policy': policy?.identity,
                    if (!preset.modelSensitive) 'policyUrl': preset.policyUrl,
                  });
            expect(
              aiConsentContractFor(
                _provider(preset, format, url, model: model),
              ).policyIdentity,
              expected,
              reason: '${preset.id}/${format.name}/$model',
            );
            expect(
              aiConsentContractFor(
                _provider(
                  preset,
                  format,
                  'https://different-recipient.example/v1',
                  model: model,
                ),
              ).policyIdentity,
              'custom',
              reason: '${preset.id}/${format.name}/$model foreign recipient',
            );
          }
        }
      }
    },
  );
}
