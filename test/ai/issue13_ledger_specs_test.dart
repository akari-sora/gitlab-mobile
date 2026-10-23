import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';

void main() {
  test('non-project numeric identities use dedicated ledger specs', () {
    final sources = <String, String>{
      for (final path in <String>[
        'lib/core/ai/tools/ledger/rows_files.dart',
        'lib/core/ai/tools/ledger/rows_project.dart',
        'lib/core/ai/tools/ledger/rows_snippets.dart',
      ])
        path: File(path).readAsStringSync(),
    };

    const expectedSpecs = <String, String>{
      'noteId': '_noteId',
      'suggestionId': '_suggestionId',
      'packageId': '_packageId',
      'fileId': '_packageFileId',
      'repositoryId': '_containerRepositoryId',
      'snippetId': '_snippetId',
    };

    for (final entry in expectedSpecs.entries) {
      final matchingLines = sources.entries
          .expand(
            (source) => source.value
                .split('\n')
                .where((line) => line.contains("'${entry.key}':"))
                .map((line) => '${source.key}: $line'),
          )
          .toList();
      expect(matchingLines, isNotEmpty, reason: entry.key);
      expect(
        matchingLines,
        everyElement(contains("'${entry.key}': ${entry.value}")),
        reason: '${entry.key} must not borrow a different identity spec',
      );
    }
  });

  test('dedicated identity specs retain required integer validation', () {
    const expectedArguments = <String, Set<String>>{
      'applySuggestion': {'noteId', 'suggestionId'},
      'batchApplySuggestions': {'noteId', 'suggestionId'},
      'deletePackage': {'packageId'},
      'deletePackageFile': {'packageId', 'fileId'},
      'deleteContainerRepository': {'repositoryId'},
      'deleteContainerTag': {'repositoryId'},
      'updateSnippetMetadata': {'snippetId'},
      'updateSnippet': {'snippetId'},
      'updateSnippetFiles': {'snippetId'},
      'deleteSnippetFile': {'snippetId'},
      'deleteSnippet': {'snippetId'},
    };

    for (final operation in expectedArguments.entries) {
      final capability = productionAiLedger.find(operation.key);
      expect(capability, isNotNull, reason: operation.key);
      for (final argument in operation.value) {
        final spec = argument == 'noteId' || argument == 'suggestionId'
            ? _suggestionSpec(capability!, operation.key, argument)
            : capability!.arguments[argument];
        expect(spec, isNotNull, reason: '${operation.key}.$argument');
        expect(
          spec!.type,
          AiArgType.integer,
          reason: '${operation.key}.$argument',
        );
        expect(spec.required, isTrue, reason: '${operation.key}.$argument');
      }
    }
  });
}

AiArgSpec? _suggestionSpec(
  AiCapability capability,
  String operation,
  String argument,
) {
  if (operation == 'batchApplySuggestions') {
    return capability.arguments['suggestions']?.properties[argument];
  }
  return capability.arguments[argument];
}
