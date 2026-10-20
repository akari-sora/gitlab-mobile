enum FailureKind {
  unauthenticated, forbidden, invisible, rateLimited, network,
  server, tooLarge, attachmentTooLarge, unsupported, redirectBlocked, invalidResponse, cancelled,
  validation, conflict, writeUncertain,
}

/// Diagnostics contain only allowlisted status information, never request data.
final class ApiFailure implements Exception {
  const ApiFailure(this.kind, {this.status, this.retryAt, String? title, String? detail})
      : _title = title,
        _detail = detail;
  final FailureKind kind;
  final int? status;
  final DateTime? retryAt;
  final String? _title;
  final String? _detail;

  /// Archive downloads are not text previews. The 2 MiB / 20,000-line copy does
  /// not describe the 256 MiB archive cap.
  static ApiFailure get artifactTooLarge => ApiFailure(
    FailureKind.tooLarge,
    title: '產物超過下載上限',
    detail: '單次下載上限為 256 MiB。',
  );

  static ApiFailure get artifactStorage => ApiFailure(
    FailureKind.network,
    title: '無法儲存產物',
    detail: '無法寫入下載檔案。請釋放空間後重試。',
  );

  /// Cache removal failed. The account must stay until a later attempt succeeds.
  static ApiFailure get artifactCleanup => ApiFailure(
    FailureKind.network,
    title: '無法清除產物',
    detail: '帳號仍保留在此裝置。請重試移除。',
  );
  static ApiFailure fromStatus(int status, {DateTime? retryAt}) => switch (status) {
    400 || 422 => ApiFailure(FailureKind.validation, status: status),
    401 => const ApiFailure(FailureKind.unauthenticated, status: 401),
    403 => const ApiFailure(FailureKind.forbidden, status: 403),
    404 => const ApiFailure(FailureKind.invisible, status: 404),
    409 || 412 => ApiFailure(FailureKind.conflict, status: status),
    429 => ApiFailure(FailureKind.rateLimited, status: 429, retryAt: retryAt),
    >= 500 => ApiFailure(FailureKind.server, status: status),
    >= 300 && < 400 => ApiFailure(FailureKind.redirectBlocked, status: status),
    _ => ApiFailure(FailureKind.invalidResponse, status: status),
  };
  String get title => _title ?? switch (kind) {
    FailureKind.unauthenticated => '登入已失效',
    FailureKind.forbidden => '沒有操作權限',
    FailureKind.invisible => '無法開啟此資源',
    FailureKind.rateLimited => '稍後再試',
    FailureKind.network => '無法連線',
    FailureKind.server => 'GitLab 暫時無法回應',
    FailureKind.tooLarge => '內容超出預覽上限',
    FailureKind.attachmentTooLarge => '附件超過 25 MiB 上限',
    FailureKind.unsupported => '目前無法預覽此內容',
    FailureKind.redirectBlocked => '資源網址已變更',
    FailureKind.invalidResponse => '無法讀取回應',
    FailureKind.cancelled => '請求已取消',
    FailureKind.validation => '請檢查輸入內容',
    FailureKind.conflict => '內容已經變更',
    FailureKind.writeUncertain => '尚未確認操作結果',
  };
  String get detail => _detail ?? switch (kind) {
    FailureKind.invisible => '目前帳號無法存取，或資源已移動／刪除。',
    FailureKind.forbidden => '請確認帳號角色、Token 的 api 權限與專案政策。',
    FailureKind.unauthenticated => '請重新連接這個帳號。',
    FailureKind.network => '請檢查網路與實例網址，再重新整理。',
    FailureKind.tooLarge => '文字預覽上限為 2 MiB／20,000 行。',
    FailureKind.attachmentTooLarge => '請選擇 25 MiB 以內的檔案再上傳。',
    FailureKind.rateLimited => 'GitLab 正在限制請求。請等待指定時間後重試。',
    FailureKind.server => '內容已保留。寫入操作請先重新讀取確認結果。',
    FailureKind.unsupported => '可能是二進位檔案，或實例不支援這個功能。',
    FailureKind.redirectBlocked => '請重新搜尋專案或使用瀏覽器開啟。',
    FailureKind.invalidResponse => '伺服器資料無法解析。請重新整理或查看診斷。',
    FailureKind.cancelled => '此請求已停止，不影響新的帳號或頁面。',
    FailureKind.validation => '名稱可能重複、分支受保護，或欄位不符合專案規則。草稿已保留。',
    FailureKind.conflict => '請重新讀取最新版本，再檢查並送出。草稿已保留。',
    FailureKind.writeUncertain => '連線在寫入時中斷。請先回到列表確認，避免重複送出；草稿已保留。',
  };
  @override
  String toString() => 'ApiFailure(${kind.name}, status: $status)';
}
ApiFailure safeFailure(Object error) => error is ApiFailure
    ? error : const ApiFailure(FailureKind.invalidResponse);
