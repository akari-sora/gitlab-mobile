/// Only the API-bound adapter interprets these GIDs. No global GID namespace.
enum AiWorkItemWriteKind { status, dates, health }

enum AiWorkItemWriteResult { notSent, confirmed, uncertain }

abstract interface class AiWorkItemWriteLease {
  String get gid;
  AiWorkItemWriteKind get kind;
}

abstract interface class AiWorkItemWriteRegistry {
  bool isActive(String gid);
  AiWorkItemWriteLease? tryStart(String gid, AiWorkItemWriteKind kind);
  void settle(
    AiWorkItemWriteLease lease,
    AiWorkItemWriteResult result,
    DateTime? revision,
  );
}
