import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';

void main() {
  final store = MemoryAiStore();
  final owner = AiAccountMutationCoordinator.forStore(store);

  // The process owner survives callers with separate event-loop zones.
  for (var turn = 1; turn <= 2; turn++) {
    testWidgets('completed account queue releases caller zone $turn', (
      tester,
    ) async {
      var completed = false;
      unawaited(
        owner
            .mutate(
              'account',
              (record) =>
                  record.copyWith(historyEnabled: !record.historyEnabled),
            )
            .then((_) => completed = true),
      );
      await tester.pump();
      expect(completed, isTrue);
      expect(
        (await store.loadAccount('account')).value!.historyEnabled,
        turn == 1,
      );
    });
  }
}
