/// Process-wide byte and count ledger for AI conversation attachments.
///
/// Accounting only: this type never sees file bytes, paths, or GitLab.
/// [tryReserve] updates the totals before it returns, so two overlapping
/// picks cannot share the same remaining capacity.
final class AiAttachmentBudget {
  AiAttachmentBudget({
    int? countLimit,
    int? conversationByteLimit,
    int? processByteLimit,
  }) : countLimit = countLimit ?? maxCountPerConversation,
       conversationByteLimit = conversationByteLimit ?? maxBytesPerConversation,
       processByteLimit = processByteLimit ?? maxBytesPerProcess {
    if (this.countLimit < 1 ||
        this.conversationByteLimit < 1 ||
        this.processByteLimit < 1) {
      throw ArgumentError('Attachment budget limits must be positive.');
    }
  }

  /// Production ledger shared by every conversation in this process.
  static final AiAttachmentBudget shared = AiAttachmentBudget();

  static const int maxCountPerConversation = 10;
  static const int maxBytesPerConversation = 50 * 1024 * 1024;
  static const int maxBytesPerProcess = 100 * 1024 * 1024;

  final int countLimit;
  final int conversationByteLimit;
  final int processByteLimit;

  final Map<Object, _Usage> _usage = <Object, _Usage>{};
  int _processBytes = 0;

  int conversationBytes(Object conversation) =>
      _usage[conversation]?.bytes ?? 0;

  int conversationCount(Object conversation) =>
      _usage[conversation]?.count ?? 0;

  int get processBytes => _processBytes;

  int conversationRemaining(Object conversation) {
    final int left = conversationByteLimit - conversationBytes(conversation);
    return left < 0 ? 0 : left;
  }

  int get processRemaining {
    final int left = processByteLimit - _processBytes;
    return left < 0 ? 0 : left;
  }

  /// Reserves one attachment slot and [bytes]. [bytes] may be zero for an
  /// empty file. Returns null without changing totals when the reservation
  /// does not fit.
  AiAttachmentReservation? tryReserve({
    required Object conversation,
    required int bytes,
  }) {
    if (bytes < 0) return null;
    final _Usage usage = _usage.putIfAbsent(conversation, _Usage.new);
    if (usage.count >= countLimit) return null;
    if (usage.bytes + bytes > conversationByteLimit) return null;
    if (_processBytes + bytes > processByteLimit) return null;
    usage.count += 1;
    usage.bytes += bytes;
    _processBytes += bytes;
    return AiAttachmentReservation._(conversation, bytes);
  }

  void release(AiAttachmentReservation reservation) {
    if (reservation._released) return;
    final _Usage? usage = _usage[reservation.conversation];
    reservation._released = true;
    if (usage == null) return;
    usage.bytes -= reservation.bytes;
    usage.count -= 1;
    _processBytes -= reservation.bytes;
    if (usage.bytes < 0) usage.bytes = 0;
    if (usage.count < 0) usage.count = 0;
    if (_processBytes < 0) _processBytes = 0;
    reservation.bytes = 0;
  }

  /// Returns unused reserved bytes to the conversation and the process.
  void shrink(AiAttachmentReservation reservation, int bytes) {
    if (reservation._released) return;
    if (bytes < 0 || bytes > reservation.bytes) {
      throw ArgumentError.value(bytes, 'bytes');
    }
    final _Usage? usage = _usage[reservation.conversation];
    if (usage == null) return;
    final int delta = reservation.bytes - bytes;
    usage.bytes -= delta;
    _processBytes -= delta;
    if (usage.bytes < 0) usage.bytes = 0;
    if (_processBytes < 0) _processBytes = 0;
    reservation.bytes = bytes;
  }
}

final class AiAttachmentReservation {
  AiAttachmentReservation._(this.conversation, this.bytes);

  final Object conversation;
  int bytes;
  bool _released = false;
}

final class _Usage {
  int bytes = 0;
  int count = 0;
}
