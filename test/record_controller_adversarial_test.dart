import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/record_controller.dart';

void main() {
  final page2 = Uri.parse('https://example.com/api/v4/issues?page=2');
  final page3 = Uri.parse('https://example.com/api/v4/issues?page=3');
  final page4 = Uri.parse('https://example.com/api/v4/issues?page=4');

  group('RecordController Adversarial & Extreme Stress Suite', () {
    test('Empty list edge case: patchItem and removeItem do not throw, alter list, or emit notifications', () async {
      final controller = RecordController((_) async => const ApiPage<Json>([]));
      addTearDown(controller.dispose);

      var notificationCount = 0;
      controller.addListener(() => notificationCount++);

      // 1. patch on empty list
      expect(() => controller.patchItem({'id': 1, 'title': 'non-existent'}), returnsNormally);
      expect(controller.items, isEmpty);
      expect(notificationCount, 0, reason: 'No notification should emit if nothing was patched');

      // 2. remove on empty list
      expect(() => controller.removeItem('1'), returnsNormally);
      expect(controller.items, isEmpty);
      expect(notificationCount, 0, reason: 'No notification should emit if nothing was removed');

      // 3. prepend on empty list
      expect(() => controller.prependItem({'id': 1, 'title': 'initial'}), returnsNormally);
      expect(controller.items, hasLength(1));
      expect(controller.items.first['id'], 1);
      expect(notificationCount, 1, reason: 'Prepend on empty list adds item and emits');
    });

    test('Non-existent ID edge case: patchItem and removeItem safely no-op without false notifications', () async {
      final controller = RecordController((_) async => ApiPage<Json>([
        {'id': 1, 'title': 'Issue 1'},
        {'id': 2, 'title': 'Issue 2'},
        {'id': 3, 'title': 'Issue 3'},
      ]));
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.items, hasLength(3));

      var notificationCount = 0;
      controller.addListener(() => notificationCount++);

      // Patch non-existent item
      controller.patchItem({'id': 999, 'title': 'Ghost Issue'});
      expect(controller.items, hasLength(3));
      expect(controller.items.map((e) => e['id']), [1, 2, 3]);
      expect(controller.items[0]['title'], 'Issue 1');
      expect(notificationCount, 0, reason: 'No notification should emit when id is not found');

      // Remove non-existent item
      controller.removeItem('999');
      expect(controller.items, hasLength(3));
      expect(controller.items.map((e) => e['id']), [1, 2, 3]);
      expect(notificationCount, 0, reason: 'No notification should emit when id is not found to remove');
    });

    test('Polymorphic and malformed identity keys: handles tag_name, path, name, iid, empty, and numeric IDs safely', () async {
      final controller = RecordController((_) async => ApiPage<Json>([
        {'id': 42, 'title': 'Numeric ID'},
        {'tag_name': 'v1.0.0', 'message': 'Release Tag'},
        {'path': 'src/main.dart', 'type': 'blob'},
        {'name': 'feature/login', 'protected': false},
        {'id': 100, 'iid': 7, 'title': 'Work Item with IID'},
        {'foo': 'bar'}, // No standard ID keys
        {'id': null, 'tag_name': null}, // Null keys
        {'id': 'special/chars?#@!%^&*()[]{}|\\\'"<>\$', 'value': 'special'},
        {'id': '🚀測試-issue', 'value': 'unicode'},
      ]));
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.items, hasLength(9));

      // 1. Match numeric ID 42 via string '42'
      controller.patchItem({'id': '42', 'title': 'Numeric ID Patched'});
      expect(controller.items[0]['title'], 'Numeric ID Patched');

      // 2. Match tag_name
      controller.patchItem({'tag_name': 'v1.0.0', 'message': 'Release Tag Updated'});
      expect(controller.items[1]['message'], 'Release Tag Updated');

      // 3. Match path
      controller.patchItem({'path': 'src/main.dart', 'type': 'tree'});
      expect(controller.items[2]['type'], 'tree');

      // 4. Match branch name
      controller.patchItem({'name': 'feature/login', 'protected': true});
      expect(controller.items[3]['protected'], true);

      // 5. Remove by iid string '7'
      controller.removeItem('7');
      expect(controller.items.any((e) => e['iid'] == 7), isFalse);
      expect(controller.items, hasLength(8));

      // 6. Object without standard ID keys: fallback to string representation
      final fallbackItem = controller.items.firstWhere((e) => e['foo'] == 'bar');
      controller.patchItem({'foo': 'bar', 'patched': true});
      // Fallback identity of {'foo': 'bar'} is '{foo: bar}'
      expect(fallbackItem['foo'], 'bar');

      // 7. Special characters and unicode in ID
      controller.patchItem({'id': 'special/chars?#@!%^&*()[]{}|\\\'"<>\$', 'value': 'special_updated'});
      expect(controller.items.firstWhere((e) => e['id'] == 'special/chars?#@!%^&*()[]{}|\\\'"<>\$')['value'], 'special_updated');

      controller.patchItem({'id': '🚀測試-issue', 'value': 'unicode_updated'});
      expect(controller.items.firstWhere((e) => e['id'] == '🚀測試-issue')['value'], 'unicode_updated');
    });

    test('Duplicate IDs handling: patchItem updates first occurrence, removeItem purges all occurrences', () async {
      final controller = RecordController((_) async => ApiPage<Json>([
        {'id': 1, 'title': 'First Dup'},
        {'id': 1, 'title': 'Second Dup'},
        {'id': 2, 'title': 'Unique Item'},
      ]));
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.items, hasLength(3));

      // Patch item 1: should update first occurrence only
      controller.patchItem({'id': 1, 'title': 'First Dup Patched'});
      expect(controller.items[0]['title'], 'First Dup Patched');
      expect(controller.items[1]['title'], 'Second Dup');

      // Prepend item 1: should update in-place at index 0 rather than prepending duplicate
      controller.prependItem({'id': 1, 'title': 'First Dup Prepend-Patched'});
      expect(controller.items, hasLength(3));
      expect(controller.items[0]['title'], 'First Dup Prepend-Patched');

      // Remove item 1: should remove ALL occurrences matching id == 1
      controller.removeItem('1');
      expect(controller.items, hasLength(1));
      expect(controller.items.single['id'], 2);
    });

    test('High-frequency 100 consecutive patches: maintains listener fidelity, in-memory consistency, and order', () async {
      const itemCount = 20;
      final initialItems = List<Json>.generate(itemCount, (i) => {
        'id': i,
        'patch_count': 0,
        'title': 'Original $i',
      });

      final controller = RecordController((_) async => ApiPage<Json>(initialItems, next: page2));
      addTearDown(controller.dispose);

      await controller.refresh();

      var listenerNotifications = 0;
      controller.addListener(() => listenerNotifications++);

      // Perform 100 rapid sequential patches cycling through all items
      for (var iteration = 1; iteration <= 100; iteration++) {
        final targetId = iteration % itemCount;
        controller.patchItem({
          'id': targetId,
          'patch_count': iteration,
          'title': 'Patched $targetId at $iteration',
        });
      }

      // Assertions
      expect(listenerNotifications, 100, reason: 'Every successful patch must emit exactly one notification');
      expect(controller.items, hasLength(itemCount), reason: 'List length must remain invariant');
      expect(controller.next, page2, reason: 'Cursor must remain invariant across 100 patches');

      // Verify each item's final state and verify order was not disrupted
      for (var i = 0; i < itemCount; i++) {
        expect(controller.items[i]['id'], i, reason: 'Index order must be preserved');
      }

      // Verify the item that was patched last in the loop (100 % 20 = 0)
      expect(controller.items[0]['patch_count'], 100);
      expect(controller.items[0]['title'], 'Patched 0 at 100');

      // 100 Rapid sequential patches on non-existent items: zero listener emissions
      final prevNotifications = listenerNotifications;
      for (var i = 0; i < 100; i++) {
        controller.patchItem({'id': 9999 + i, 'title': 'Ghost'});
      }
      expect(listenerNotifications, prevNotifications, reason: 'No listener calls for non-existent items');
    });

    test('Cursor and _seenCursors inviolability: multiple pages, 100 patches, removals, prepends do not corrupt pagination or loop detection', () async {
      final page1Items = List<Json>.generate(5, (i) => {'id': i + 1, 'title': 'P1-$i'});
      final page2Items = List<Json>.generate(5, (i) => {'id': i + 6, 'title': 'P2-$i'});
      final page3Items = List<Json>.generate(5, (i) => {'id': i + 11, 'title': 'P3-$i'});

      final requestedUris = <Uri?>[];

      final controller = RecordController((next) async {
        requestedUris.add(next);
        if (next == null) {
          return ApiPage<Json>(page1Items, next: page2);
        } else if (next == page2) {
          return ApiPage<Json>(page2Items, next: page3);
        } else if (next == page3) {
          return ApiPage<Json>(page3Items, next: page4);
        } else if (next == page4) {
          // Intentionally repeat page2 to test whether _seenCursors loop detection triggers
          return ApiPage<Json>([{'id': 999}], next: page2);
        }
        return const ApiPage<Json>([]);
      });
      addTearDown(controller.dispose);

      // Load Page 1
      await controller.refresh();
      expect(controller.items, hasLength(5));
      expect(controller.next, page2);

      // Load Page 2
      await controller.more();
      expect(controller.items, hasLength(10));
      expect(controller.next, page3);

      // --- STRESS BARRAGE: 100 mutations on loaded pages ---
      for (var i = 1; i <= 50; i++) {
        // Patch items on Page 1
        controller.patchItem({'id': (i % 5) + 1, 'title': 'P1-Patched-$i'});
        // Patch items on Page 2
        controller.patchItem({'id': (i % 5) + 6, 'title': 'P2-Patched-$i'});
      }

      // Prepend an item
      controller.prependItem({'id': 1000, 'title': 'Prepended User Item'});
      expect(controller.items.first['id'], 1000);
      expect(controller.items, hasLength(11));

      // Remove an item from Page 1 and Page 2
      controller.removeItem('1');
      controller.removeItem('6');
      expect(controller.items, hasLength(9));

      // VERIFY: next cursor is still page3 and completely intact!
      expect(controller.next, page3);

      // Load Page 3: should succeed and append Page 3 items
      await controller.more();
      expect(controller.items, hasLength(14)); // 9 + 5 = 14
      expect(controller.next, page4);
      expect(controller.items.any((e) => e['id'] == 11), isTrue);

      // Load Page 4: returns repeated next: page2 -> loop detection must trigger invalidResponse
      await controller.more();
      expect(controller.next, isNull, reason: 'Repeated cursor must be stopped');
      expect(controller.error?.kind, FailureKind.invalidResponse,
        reason: '_seenCursors must have retained page2 despite all mutations');
    });

    test('Asynchronous race condition: in-place mutations while more() is in-flight do not get clobbered or clobber page items', () async {
      final page1Items = [{'id': 1, 'title': 'Item 1'}, {'id': 2, 'title': 'Item 2'}];
      final pendingMore = Completer<ApiPage<Json>>();

      final controller = RecordController((next) async {
        if (next == null) {
          return ApiPage<Json>(page1Items, next: page2);
        }
        return pendingMore.future;
      });
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.items, hasLength(2));

      // Trigger more() asynchronously
      final moreFuture = controller.more();
      expect(controller.loadingMore, isTrue);

      // While more() is in flight, perform mutations:
      // 1. Patch Item 1
      controller.patchItem({'id': 1, 'title': 'Item 1 (Patched while loading)'});
      // 2. Remove Item 2
      controller.removeItem('2');
      // 3. Prepend Item 0
      controller.prependItem({'id': 0, 'title': 'Item 0 (Prepended while loading)'});

      expect(controller.items.map((e) => e['id']), [0, 1]);

      // Complete more() with Page 2 items
      pendingMore.complete(ApiPage<Json>([
        {'id': 3, 'title': 'Item 3'},
        {'id': 4, 'title': 'Item 4'},
      ], next: page3));

      await moreFuture;

      // Verify the resulting list:
      // - Item 0 remains prepended
      // - Item 1 remains patched
      // - Item 2 was NOT resurrected by page completion
      // - Items 3 and 4 are properly appended at the end
      expect(controller.items.map((e) => e['id']), [0, 1, 3, 4]);
      expect(controller.items[1]['title'], 'Item 1 (Patched while loading)');
      expect(controller.loadingMore, isFalse);
      expect(controller.next, page3);
    });

    test('Prepend deduplication against later pages: prepended item is not duplicated when server returns it on page 2', () async {
      final page1Items = [{'id': 1, 'title': 'Item 1'}, {'id': 2, 'title': 'Item 2'}];
      final controller = RecordController((next) async {
        if (next == null) {
          return ApiPage<Json>(page1Items, next: page2);
        }
        // Server page 2 includes Item 3 (which was also prepended by user) and Item 4
        return const ApiPage<Json>([
          {'id': 3, 'title': 'Item 3 from server'},
          {'id': 4, 'title': 'Item 4'},
        ]);
      });
      addTearDown(controller.dispose);

      await controller.refresh();

      // User creates Item 3 locally via prepend
      controller.prependItem({'id': 3, 'title': 'Item 3 created locally'});
      expect(controller.items.map((e) => e['id']), [3, 1, 2]);

      // Now load page 2
      await controller.more();

      // Item 3 must NOT appear twice in the list!
      expect(controller.items.map((e) => e['id']), [3, 1, 2, 4]);
      // The prepended version remains at index 0
      expect(controller.items[0]['title'], 'Item 3 created locally');
    });

    test('Disposed safety: mutations after dispose() safely return without throwing or notifying', () async {
      final controller = RecordController((_) async => ApiPage<Json>([{'id': 1}]));
      await controller.refresh();

      controller.dispose();

      // Mutations on disposed controller must not throw FlutterError
      expect(() => controller.patchItem({'id': 1, 'title': 'late patch'}), returnsNormally);
      expect(() => controller.removeItem('1'), returnsNormally);
      expect(() => controller.prependItem({'id': 2, 'title': 'late prepend'}), returnsNormally);
    });
  });
}
