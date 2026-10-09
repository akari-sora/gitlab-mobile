# Project: GitLab Mobile v0.4.0

## Architecture
- **Tech Stack**: Flutter 3.47.2 (via FVM), Dart 3.7.0, Riverpod, Material 3 (Material You adaptive).
- **Core Architecture**:
  - `lib/core/`: 底層 API 客戶端（`GitLabApi`）、Session 狀態管理（`SessionController`）、OAuth PKCE 與實例連線（`GitLabInstance`）。
  - `lib/features/shell/`: 應用程式外殼（`AuthenticatedApp`、`_MobileShell`）、路由導航與底部導航分頁（Projects, Activity, CI, Settings）。
  - `lib/features/workspace/`: 業務功能頁面（`ProjectsPage`, `ProjectPage`, `WorkItemPage`, `DiscussionsTab`, `CiPage`, `JobLogPage`, `RecordsFeed` 及新增的 `CiOverviewPage`）。
  - `lib/shared/`: 共用組件與語意裝飾（`FailureNotice`, `ResumeTarget`, `AdaptiveDualPane`, `AttachmentImage`, `AttachmentViewer`, `MarkdownView`, `SemanticButton`）。
- **Data Flow & Lifecycle**:
  - 帳號與會話綁定 `session.generation`。切換帳號或登出時 `generation++`，徹底重建 Widget 樹以杜絕過期資料或跨帳號污染。
  - 404/403 錯誤統一由 `FailureNotice` 捕捉，支援攜帶 `ResumeTarget`（專案路徑、資源類型、IID）。切換帳號後以 Path-first 機制向 API 解析新帳號下的專案 ID，並依 `generation` 重導至目標資源。

## Android development signing

- 本機 debug、profile 與 release APK 共用固定開發簽章，以支援跨 build mode 的覆蓋安裝。完整契約與操作方式見 [`docs/ANDROID_SIGNING.md`](docs/ANDROID_SIGNING.md)。
- 主機上的固定目錄是 `~/.config/gitlab-mobile/android-signing`；私鑰與密碼不屬於 Git、建置產物或驗收台帳。證據只記錄公開憑證 SHA-256。
- CI 目前仍使用 `ANDROID_DEBUG_KEYSTORE_B64` 或既有臨時 debug key fallback；本機固定簽章不代表 CI、Play 或正式發布簽章已完成。
- Android 能否覆蓋安裝同時取決於 application ID、相容簽章與非降版 `versionCode`。不得為了通過安裝而自動移除 App 或清除帳號／草稿。

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | R1.1 換帳號續接原資源 | `FailureNotice.onSwitchAccount` 提供 `ResumeTarget`；`SessionController` 託管；Shell 依 `generation` 重導；Path-first 解析專案 ID；覆蓋 3 大邊界測試情境 | M1 | ORIGINAL_REQUEST §R1.1 |
| 2 | R1.2 穩定簽章驗證 | 驗證 `ANDROID_DEBUG_KEYSTORE_B64` 簽章指紋一致性與 `adb install -r` 覆蓋安裝；未設定時明確標註客觀 `NOT_RUN` | M1 | ORIGINAL_REQUEST §R1.2 |
| 3 | R1.3 CI Smoke 完整驗收 | 修正 `tool/live_smoke.dart`， runner tag 處理或捕捉 `ci_quota_exceeded` 標記 `NOT_RUN(quota)` 且不中斷，確保檢查 34 執行，達成 34/34 PASS/NOT_RUN | M1 | ORIGINAL_REQUEST §R1.3 |
| 4 | R2.1 跨專案 CI 總覽 | 新增 `CiOverviewPage` 替換現有 CI 選擇器；`GET /projects?membership=true` + 最新 pipeline；並發限制 4；逐專案錯誤隔離；綁定 `session.generation` | M2 | ORIGINAL_REQUEST §R2.1 |
| 5 | R2.2 摺疊機／平板雙欄佈局 | 實作 `AdaptiveDualPane`；412/840/1200 dp 斷點；專案列表+首頁、議題列表+詳情；動態切換時保持返回堆疊（Back Stack Preservation） | M3 | ORIGINAL_REQUEST §R2.2 |
| 6 | R2.3 Job Log 增量串流 | `GitLabApi` 支援 `Range: bytes=<offset>-` 與 `?offset=`；支援 HTTP 206/416；穩定 section key 標籤保持折疊狀態，避免全量重複拉取 | M2 | ORIGINAL_REQUEST §R2.3 |
| 7 | R2.4 附件 App 內下載與分享 | `MarkdownView` 攔截 `/uploads/<secret>/<file>` 專案附件；複用產物下載 sink、4 MiB budget 與清理機制；圖片檢視器補充系統分享功能 | M4 | ORIGINAL_REQUEST §R2.4 |
| 8 | R2.5 OAuth 實測 | 驗證 PKCE 授權流程單元測試（11/11 PASS）；未配置 Application ID 時維持客觀 `NOT_RUN` 宣告 | M4 | ORIGINAL_REQUEST §R2.5 |
| 9 | R3.1 TalkBack 無障礙走查 | 修復 `attachment_image.dart` 48 dp 觸控熱區、`Monogram` 排除語意、議題標頭 `MergeSemantics`、討論串摺疊標頭與產物 Sheet 無障礙缺陷 | M5 | ORIGINAL_REQUEST §R3.1 |
| 10 | R3.2 效能度量與優化 | `RecordsFeed` 升級為虛擬化 builder 模式；建立 `test/performance_benchmark_test.dart` 量測 200 則長討論與 20,000 行 Log 解析耗時 | M5 | ORIGINAL_REQUEST §R3.2 |
| 11 | R3.3 推播架構 RFC | 於 `docs/ROADMAP.md` 撰寫 Webhook → FCM Relay 架構設計、零 PAT 轉發安全防線與 Cloudflare Workers / GCP 成本分析 | M5 | ORIGINAL_REQUEST §R3.3 |
| 12 | R4 驗證基線與發版台帳 | 建立 `docs/V0_4_VERIFICATION.md`；維持 `flutter analyze` 0 error/0 warning/0 info；全量 561+ Flutter 測試與 32+ Python 測試通過 | M6 | ORIGINAL_REQUEST §AC |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | P0 Reliability & Shell Core | R1.1 換帳號續接原資源、R1.2 穩定簽章檢查、R1.3 CI Smoke 驗收 (34/34) | none | DONE |
| M2 | P1 CI Overview & Log Streaming | R2.1 跨專案 CI 總覽分頁、R2.3 Job log 增量串流與折疊保持 | none | IN_PROGRESS |
| M3 | P1 Responsive Dual-Pane Layout | R2.2 平板/摺疊機 412/840/1200 dp 雙欄 Master-Detail 與返回堆疊保持 | M1 | PLANNED |
| M4 | P1 In-app Attachments & OAuth | R2.4 附件 App 內下載與圖片分享、R2.5 OAuth 契約驗收 | none | PLANNED |
| M5 | P2 Quality, A11y & Performance | R3.1 TalkBack 48dp 與語意修復、R3.2 RecordsFeed 虛擬化與效能基準、R3.3 推播 RFC | M1, M2, M3, M4 | PLANNED |
| M6 | E2E Verification & Release Gate | 建立 `docs/V0_4_VERIFICATION.md`、全量靜態分析與回歸驗收 | M1, M2, M3, M4, M5 | PLANNED |

## Interface Contracts

### M1: `ResumeTarget` & `SessionController` (COMPLETED)
```dart
final class ResumeTarget {
  const ResumeTarget({
    this.projectId,
    this.projectPath,
    required this.resource, // 'project', 'issues', 'merge_requests', 'pipelines', 'repository'
    this.iid,
    this.path,
  });
  final int? projectId;
  final String? projectPath;
  final String resource;
  final int? iid;
  final String? path;
}
```

### M2: `GitLabApi.jobTraceChunk` & CI Overview Page (ACTIVE)
```dart
abstract interface class GitLabApi {
  Future<({List<int> bytes, bool isEof, int? nextOffset})> jobTraceChunk(
    int project,
    int job, {
    int offset = 0,
    int? maxBytes,
  });
}
```

### M3: `AdaptiveDualPane` (PLANNED)
```dart
class AdaptiveDualPane extends StatelessWidget {
  const AdaptiveDualPane({
    super.key,
    required this.masterPane,
    required this.detailPane,
    this.breakpoint = 840.0,
    this.masterWidth = 380.0,
  });
  final Widget masterPane;
  final Widget? detailPane;
  final double breakpoint;
  final double masterWidth;
}
```

## Code Layout
- `lib/core/`
  - `gitlab_api.dart`: API 傳輸、Range 標頭、HTTP 206/416 處理
  - `workspace_api.dart`: CI 與 Job Trace 介面
  - `oauth.dart`: OAuth PKCE 配置
- `lib/features/auth/`
  - `session_controller.dart`: 帳號會話管理與 `ResumeTarget` 暫存
- `lib/features/shell/`
  - `authenticated_app.dart`: 外殼路由、Generation 重建、CI 分頁入口
- `lib/features/workspace/`
  - `ci_overview_page.dart` (新增): 跨專案 CI 總覽
  - `ci_page.dart`: Pipeline 與 Job log 增量展示
  - `projects_page.dart`: 專案清單與雙欄適配
  - `work_item_page.dart`: 議題/MR 頁面與雙欄適配
  - `discussions_tab.dart`: 討論串無障礙
  - `records_feed.dart`: 虛擬化 builder 改造
- `lib/shared/`
  - `resume_target.dart`: `ResumeTarget` 模型
  - `workspace_ui.dart`: `FailureNotice` 與 `ResumeTarget` 匯出
  - `adaptive_dual_pane.dart` (新增): 響應式雙欄組件
  - `attachment_image.dart`: 附件 48 dp 熱區與系統分享
  - `markdown_view.dart`: Uploads 下載攔截
- `docs/`
  - `ROADMAP.md`: Webhook → FCM Relay 推播 RFC
  - `V0_4_VERIFICATION.md` (新增): v0.4 驗收台帳
- `tool/`
  - `live_smoke.dart`: CI smoke runner tag 與 quota 標記
