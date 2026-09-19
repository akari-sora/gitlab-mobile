enum FailureKind {
  unauthenticated, forbidden, invisible, rateLimited, network,
  server, tooLarge, unsupported, redirectBlocked, invalidResponse, cancelled,
}

/// Only allowlisted information reaches the UI. Never stringify DioException,
/// requestOptions, response bodies, credentials, or tokens in diagnostics.
final class ApiFailure implements Exception {
  const ApiFailure(this.kind, {this.status, this.retryAt});
  final FailureKind kind;
  final int? status;
  final DateTime? retryAt;

  static ApiFailure fromStatus(int status, {DateTime? retryAt}) => switch (status) {
    401 => const ApiFailure(FailureKind.unauthenticated, status: 401),
    403 => const ApiFailure(FailureKind.forbidden, status: 403),
    404 => const ApiFailure(FailureKind.invisible, status: 404),
    429 => ApiFailure(FailureKind.rateLimited, status: 429, retryAt: retryAt),
    >= 500 => ApiFailure(FailureKind.server, status: status),
    >= 300 && < 400 => ApiFailure(FailureKind.redirectBlocked, status: status),
    _ => ApiFailure(FailureKind.invalidResponse, status: status),
  };

  String get title => switch (kind) {
    FailureKind.unauthenticated => '無法驗證此憑證，請檢查登入',
    FailureKind.forbidden => '此操作未獲授權',
    FailureKind.invisible => '無法開啟此資源',
    FailureKind.rateLimited => '請求太頻繁，請稍後重試',
    FailureKind.network => '目前無法連接 GitLab',
    FailureKind.server => 'GitLab 暫時無法回應',
    FailureKind.tooLarge => '內容超出預覽上限',
    FailureKind.unsupported => '此內容或請求目前不支援',
    FailureKind.redirectBlocked => '已停止 API 重新導向',
    FailureKind.invalidResponse => '無法讀取 GitLab 回應',
    FailureKind.cancelled => '請求已取消',
  };

  String get detail => switch (kind) {
    FailureKind.invisible => '此帳號無法存取這個資源，或連結／資源已變更。',
    FailureKind.forbidden => '可能受角色、Token scope 或實例政策限制；不會自動更換帳號。',
    FailureKind.unauthenticated => 'App 憑證與瀏覽器登入狀態分開；請確認目前帳號。',
    FailureKind.network => '請檢查連線、實例網址與 TLS 憑證。已顯示的資料不會被清空。',
    FailureKind.tooLarge => '此版本最多預覽 2 MiB／20,000 行；不會自動下載整份大型內容。',
    FailureKind.rateLimited => '已停止自動請求。伺服器指定等待時間時，重試需等到期限後。',
    FailureKind.server => '保留已載入內容；稍後再試。',
    FailureKind.unsupported => '可能是非文字內容或不支援的資源請求；不會把缺少的內容當成空白檔案。',
    FailureKind.redirectBlocked => '為避免憑證外洩，不自動跟隨 API 重新導向。',
    FailureKind.invalidResponse => '回應格式與預期不符；沒有把缺少的資料當成空列表。',
    FailureKind.cancelled => '切換帳號或離開頁面後，舊請求不再影響目前畫面。',
  };

  @override
  String toString() => 'ApiFailure(${kind.name}, status: $status)';
}

ApiFailure safeFailure(Object error) => error is ApiFailure
    ? error : const ApiFailure(FailureKind.invalidResponse);
