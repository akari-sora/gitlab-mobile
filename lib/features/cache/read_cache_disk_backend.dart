import '../../core/read_cache_disk_contract.dart';
import 'read_cache_disk_coordinator.dart';

/// Per-client adapter. Readiness is evaluated by the coordinator on every call,
/// including clients attached while startup or user controls are still closed.
final class CoordinatedReadCacheDiskBackend implements ReadCacheDiskBackend {
  const CoordinatedReadCacheDiskBackend({
    required this.coordinator,
    required this.binding,
  });

  final ReadCacheDiskCoordinator coordinator;
  final DiskBinding binding;

  @override
  Future<ProjectedDiskEntry?> lookup(DiskLookup lookup) =>
      lookup.binding == binding ? coordinator.lookup(lookup) : Future.value();

  @override
  void accept(DiskWriteCandidate candidate, ProjectedDiskEntry entry) {
    if (candidate.binding == binding) coordinator.accept(candidate, entry);
  }

  @override
  DiskInvalidationFence invalidate(DiskInvalidation invalidation) =>
      coordinator.invalidate(invalidation);

  @override
  void revoke(DiskBinding binding) => coordinator.revoke(binding);

  @override
  Future<DiskClearResult> clear(
    DiskBinding binding,
    ReadCacheCleanupOperation operation,
  ) => coordinator.clear(binding, operation);

  @override
  void reportCleanup(ReadCacheCleanupState state) =>
      coordinator.reportCleanup(binding, state);
}
