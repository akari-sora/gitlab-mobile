import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

void main() {
  test('capacity refusal has distinct retryable wording in every language', () {
    final arbFiles = Directory('lib/l10n/arb')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.arb'))
        .toList();

    expect(arbFiles, hasLength(24));
    for (final file in arbFiles) {
      final catalog =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final capacity = catalog['aiHistoryCapacityLimit'];
      expect(capacity, isA<String>(), reason: file.path);
      expect((capacity as String).trim(), isNotEmpty, reason: file.path);
      expect(
        capacity,
        isNot(catalog['aiHistoryStorageLimit']),
        reason: file.path,
      );
      expect(
        capacity,
        isNot(contains(RegExp(r'[\u202A-\u202E\u2066-\u2069]'))),
        reason: file.path,
      );
    }

    final notices = <String>{
      for (final language in appLanguages)
        AppStrings(language).aiHistoryCapacityLimit,
    };
    expect(notices, hasLength(24));
    for (final language in appLanguages) {
      final strings = AppStrings(language);
      expect(
        strings.aiHistoryCapacityLimit,
        isNot(strings.aiHistoryStorageLimit),
        reason: language.tag,
      );
    }
  });
}
