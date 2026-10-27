import 'dart:async';

import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';

const c2d7Clear = DiskClearResult(
  keyGoneConfirmed: false,
  directoryGoneConfirmed: false,
  markerDurable: false,
  complete: false,
);

final class _Fence implements DiskInvalidationFence {
  _Fence(this.barrier);
  @override
  final Future<DiskClearResult> barrier;
  @override
  Future<void> get quiesced => barrier.then((_) {}, onError: (Object _) {});
  @override
  bool get isCurrent => true;
  @override
  void revoke() {}
}

final class C2d7Barrier implements ReadCacheDiskBackend {
  bool blocked = true;
  Future<DiskClearResult> Function()? onInvalidate;
  final Completer<void> entered = Completer<void>();
  @override
  DiskInvalidationFence invalidate(DiskInvalidation invalidation) {
    if (!entered.isCompleted) entered.complete();
    return _Fence(onInvalidate?.call() ?? (blocked
        ? Future.error(StateError('synthetic barrier failure'))
        : Future.value(c2d7Clear)));
  }
  @override
  Future<ProjectedDiskEntry?> lookup(DiskLookup lookup) async => null;
  @override
  void accept(DiskWriteCandidate candidate, ProjectedDiskEntry entry) {}
  @override
  void revoke(DiskBinding binding) {}
  @override
  Future<DiskClearResult> clear(DiskBinding binding, ReadCacheCleanupOperation operation) async => c2d7Clear;
  @override
  void reportCleanup(ReadCacheCleanupState state) {}
}
