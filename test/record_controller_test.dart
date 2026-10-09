import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/record_controller.dart';

void main() {
  final page2 = Uri.parse('https://example.com/api/v4/issues?page=2');
  test('refresh failure retains records and retries first page, not page two', () async {
    var fail = false; final requests = <Uri?>[];
    final controller = RecordController((next) async {
      requests.add(next);
      if (fail) { throw const ApiFailure(FailureKind.network); }
      return ApiPage<Json>([{'id': 1, 'title': 'existing'}], next: page2);
    });
    addTearDown(controller.dispose);
    await controller.refresh(); fail = true; await controller.refresh();
    expect(controller.items.single['id'], 1); expect(controller.next, page2);
    fail = false; await controller.retry();
    expect(requests, [null, null, null]); expect(controller.error, isNull);
  });
  test('page failure keeps first page and retries the failed cursor with deduplication', () async {
    var fail = true;
    final controller = RecordController((next) async {
      if (next == null) { return ApiPage<Json>([{'id': 1}], next: page2); }
      if (fail) { throw const ApiFailure(FailureKind.network); }
      return const ApiPage<Json>([{'id': 1}, {'id': 2}]);
    });
    addTearDown(controller.dispose);
    await controller.refresh(); await controller.more();
    expect(controller.items, hasLength(1)); expect(controller.failedMore, isTrue);
    fail = false; await controller.retry();
    expect(controller.items.map((v) => v['id']), [1, 2]); expect(controller.next, isNull);
  });
  test('late page response cannot append into a refreshed resource', () async {
    final pending = Completer<ApiPage<Json>>();
    final controller = RecordController((next) async => next == null
      ? ApiPage<Json>([{'id': 1}], next: page2) : pending.future);
    addTearDown(controller.dispose);
    await controller.refresh(); final more = controller.more();
    controller.loader = (_) async => const ApiPage<Json>([{'id': 99}]);
    await controller.refresh(); pending.complete(const ApiPage<Json>([{'id': 2}])); await more;
    expect(controller.items.single['id'], 99);
  });
  test('repeated server cursor is stopped rather than looped', () async {
    final controller = RecordController((_) async => ApiPage<Json>([{'id': 1}], next: page2));
    addTearDown(controller.dispose); await controller.refresh(); await controller.more();
    expect(controller.next, isNull); expect(controller.error?.kind, FailureKind.invalidResponse);
  });
  test('reconcile reloads the loaded window with refreshed cursors and ordering', () async {
    final oldPage2 = Uri.parse('https://example.com/api/v4/issues?page=2&snapshot=old');
    final oldPage3 = Uri.parse('https://example.com/api/v4/issues?page=3&snapshot=old');
    final newPage2 = Uri.parse('https://example.com/api/v4/issues?page=2&snapshot=new');
    final newPage3 = Uri.parse('https://example.com/api/v4/issues?page=3&snapshot=new');
    var reconciled = false;
    final requests = <Uri?>[];
    final controller = RecordController((next) async {
      requests.add(next);
      if (!reconciled) {
        if (next == null) return ApiPage<Json>([{'id': 1}, {'id': 2}], next: oldPage2);
        if (next == oldPage2) return ApiPage<Json>([{'id': 3}, {'id': 4}], next: oldPage3);
      } else {
        if (next == null) return ApiPage<Json>([{'id': 4}, {'id': 1}], next: newPage2);
        if (next == newPage2) return ApiPage<Json>([{'id': 2}, {'id': 3}], next: newPage3);
      }
      throw const ApiFailure(FailureKind.invalidResponse);
    });
    addTearDown(controller.dispose);

    await controller.refresh();
    await controller.more();
    reconciled = true;
    await controller.reconcileLoadedWindow();

    expect(requests, [null, oldPage2, null, newPage2]);
    expect(controller.items.map((item) => item['id']), [4, 1, 2, 3]);
    expect(controller.next, newPage3);
    expect(controller.error, isNull);
  });
  test('failed loaded-window reconciliation keeps prior items and cursor atomically', () async {
    final refreshedPage2 = Uri.parse('https://example.com/api/v4/issues?page=2&snapshot=new');
    var reconciling = false;
    final controller = RecordController((next) async {
      if (!reconciling) {
        if (next == null) return ApiPage<Json>([{'id': 1}], next: page2);
        return const ApiPage<Json>([{'id': 2}]);
      }
      if (next == null) return ApiPage<Json>([{'id': 9}], next: refreshedPage2);
      throw const ApiFailure(FailureKind.network);
    });
    addTearDown(controller.dispose);

    await controller.refresh();
    await controller.more();
    reconciling = true;
    await controller.reconcileLoadedWindow();

    expect(controller.items.map((item) => item['id']), [1, 2]);
    expect(controller.next, isNull);
    expect(controller.error?.kind, FailureKind.network);
  });
  test('reconciliation rejects a repeated refreshed cursor without replacing the old window', () async {
    final repeated = Uri.parse('https://example.com/api/v4/issues?page=2&snapshot=loop');
    var reconciling = false;
    final controller = RecordController((next) async {
      if (!reconciling) {
        if (next == null) return ApiPage<Json>([{'id': 1}], next: page2);
        return const ApiPage<Json>([{'id': 2}]);
      }
      if (next == null) return ApiPage<Json>([{'id': 9}], next: repeated);
      return ApiPage<Json>([{'id': 10}], next: repeated);
    });
    addTearDown(controller.dispose);

    await controller.refresh();
    await controller.more();
    reconciling = true;
    await controller.reconcileLoadedWindow();

    expect(controller.items.map((item) => item['id']), [1, 2]);
    expect(controller.next, isNull);
    expect(controller.error?.kind, FailureKind.invalidResponse);
  });
  test('late reconciliation cannot replace a newer refresh', () async {
    final pending = Completer<ApiPage<Json>>();
    var reconciling = false;
    final controller = RecordController((next) async {
      if (!reconciling) {
        if (next == null) return ApiPage<Json>([{'id': 1}], next: page2);
        return const ApiPage<Json>([{'id': 2}]);
      }
      return pending.future;
    });
    addTearDown(controller.dispose);
    await controller.refresh();
    await controller.more();

    reconciling = true;
    final reconcile = controller.reconcileLoadedWindow();
    controller.loader = (_) async => const ApiPage<Json>([{'id': 99}]);
    await controller.refresh();
    pending.complete(const ApiPage<Json>([{'id': 9}]));
    await reconcile;

    expect(controller.items.single['id'], 99);
  });
  test('disposed controller ignores pending successful results', () async {
    final pending = Completer<ApiPage<Json>>(); final controller = RecordController((_) => pending.future);
    final refresh = controller.refresh(); controller.dispose();
    pending.complete(const ApiPage<Json>([{'id': 1}])); await refresh;
    expect(controller.items, isEmpty);
  });
}
