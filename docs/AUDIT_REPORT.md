# GitLab Mobile (Flutter) 全域架構、功能落差、UI/UX 與代碼品質審查總報告

- **報告版本**：v1.0 (Official Global Audit)
- **審查日期**：2026-09-21
- **審查負責人**：全域審查報告撰寫專家 (`teamwork_preview_worker_report_1`)
- **審查目標儲存庫**：`gitlab-mobile`
- **運行環境規格**：Flutter 3.47.2 / Dart 3.13.2 / FVM / macOS
- **權威依據文件**：
  - `ORIGINAL_REQUEST.md`（原始需求與驗收標準）
  - `AGENTS.md`（專案核心開發合約與驗收邊界）
  - `README.md`（專案定位與建置手冊）
  - `docs/ROADMAP.md`（G0 至 G5 產品路線圖與驗收標準）
  - `docs/UI_REDESIGN.md`（v0.2 移動端 UX 規範與佈局原則）
  - `docs/V0_2_VERIFICATION.md`（v0.2 驗證帳本與測試邊界記錄）
- **輸入報告來源**：
  1. UI/UX 與人機互動專案勘測報告 (`teamwork_preview_explorer_ui_1`)
  2. 核心工作流與 G0-G5 落差勘測報告 (`teamwork_preview_explorer_workflow_1`)
  3. 代碼品質、靜態分析與自動化測試盲點報告 (`teamwork_preview_explorer_quality_1`)

## 狀態更新 2026-09-22

本段註記下方 2026-09-21 正文，不改寫正文，也不改編號。正文仍描述審查當時的代碼。證據邊界見 `docs/V0_3_VERIFICATION.md`。!3、!7、!6、!5、!4、!8 已併入 `main`（`9183f19`）。pipeline `2869335026` 的 JUnit 報告讀到 `509` 項測試；這是該次觀察值。!3 之後的 v0.3 功能沒有實機走查（手機已改派）。

條文對過之後：H02 是 Diff 熱區、M02 是檔案橫向同步捲動、M04 是登入頁移除失效帳號、M10 是 `go_router` 與舊畫面，都落在已合併的 !2，不是 !3–!8。H04 的條文是 OAuth 登入；PKCE 在 !2，登入仍 NOT_RUN，不計閉合。

### 已修

| 項目 | 現況 | 合併請求 |
|---|---|---|
| ISSUE-H01 | 404 畫面補上帳號、實例、資源、重試與切換帳號。實機尚未走過模糊 404 畫面 | !2（已合併，`9ae6780`） |
| ISSUE-H02 | Diff 行觸控熱區放大 | !2（已合併，`f2d84b2`） |
| ISSUE-H04 | OAuth PKCE 已接上。`oauthApplicationIdFor` 仍是空對照表，登入 NOT_RUN，不計閉合 | !2（已合併，`62b81fd`） |
| ISSUE-H05 | App 內下載 Job 工件（已驗證第一跳、恰一次 https `Location`、無憑證第二跳、256 MiB、節流進度、開啟／分享）。模擬器 `9789033`／`e9e1965` 下完 83.4 MB。實機 `db12b41` 仍是瀏覽器選單 | !5（已合併，`fd14809`） |
| ISSUE-H06 | 附件上傳（`POST /projects/:id/uploads`，multipart，25 MiB）。live 上傳 NOT_RUN | !7（已合併，`3891577`） |
| ISSUE-H08 | Diff 內既有討論，僅在 SHA、路徑與正整數座標都吻合時錨定。模擬器 `fa529a2` 在 `lib/core/workspace_api.dart` 第 41 行下看到討論。實機 NOT_RUN | !4（已合併，`9183f19`，head `92f8c9f`） |
| ISSUE-H09 | 已加入 Inbox 與 Diff 測試（`test/inbox_page_test.dart`、`test/diff_page_test.dart`）。覆蓋率從 CI 報告讀取。收件匣分頁實機 NOT_RUN | !2（已合併，`af23c5f`） |
| ISSUE-M02 | 檔案檢視共用水平捲動 | !2（已合併，`9dd99e9`） |
| ISSUE-M04 | 登入頁可移除已存帳號 | !2（已合併，`0b6ae18`） |
| ISSUE-M05 | MR 總覽審查卡片。實機看過卡片；未從卡片完成核准或合併 | !3（已合併，覆核 head `646dce9`，`339320a`） |
| ISSUE-M06 | 合併對話框的 Squash 與刪除來源分支。實機打開後取消，沒有合併 | !3（已合併，`339320a`） |
| ISSUE-M07 | 已解決討論折疊、篩選與摘要。實機看過 | !3（已合併，`dd686f2`，覆核 `646dce9`） |
| ISSUE-M08 | 標籤、指派、審查者、分支選擇器。!7 有模擬器截圖；`c90ca15` 走過標籤選擇器（搜尋與空狀態）。live 指派與實機 NOT_RUN | !7（已合併，`3891577`） |
| ISSUE-M10 | 移除 `go_router` 與未使用的 G0 畫面 | !2（已合併，`ed4f3d3`） |
| ISSUE-M13 | `SecureAccountStore` 與外部連結測試已加入。通過與否從 CI 報告讀取 | !2（已合併，`af23c5f`） |
| ISSUE-M14 | Markdown 工具列與編輯／預覽。!7 有工具列截圖；`c90ca15` 走過 8 個動作與編輯／預覽。實機 NOT_RUN（`db12b41` 的議題是用三星鍵盤輸入） | !7（已合併，`3891577`） |

!6（已合併，`cbe589a`，head `b3e05e9`）與 !8（已合併，`0c2522b`，head `c90ca15`）沒有對上既有編號。!8 寬螢幕的 feed gutter 不是 ISSUE-H03 的雙欄。

### 仍開放

- **ISSUE-H03**：840 dp 雙欄尚未做。
- **ISSUE-H07**：Push 尚未做。
- **ISSUE-H10**：工作區仍以未型別 `Json` 為主。
- **ISSUE-H12**：裝置矩陣仍是一隻實機（Samsung SM-S9280，Android 16；`db12b41` 與 !3 建置）加一台 Pixel 9 模擬器（`emulator-5554`，Android 16）。!4–!8 沒有實機走查。live smoke 合併後沒有重跑。不把 G0 標成 ACCEPTED。
- **ISSUE-M01、ISSUE-M03、ISSUE-M09、ISSUE-M11、ISSUE-M12**：仍開放。!5 的日誌區段折疊不是 M03（ANSI 著色）或 M09（增量串流）的修復。
- OAuth 登入、iOS、商店簽章、TalkBack、跨專案 CI 總覽、帳號切換後的失敗目標重試：NOT_RUN。見 v0.3 帳本。

### ISSUE-H11 `encryptedSharedPreferences`

本分支已處理。`pubspec.yaml` 的 `flutter_secure_storage` 是 11.2.0，預設 RSA-OAEP + AES-GCM。`encryptedSharedPreferences` 旗標已棄用。`account_store.dart`、`editor.dart`、`appearance.dart` 的初始化是 `AndroidOptions()`，沒有再傳該旗標。正文「未設定該旗標就會回退弱加密」不適用於這個版本。裝置備份、還原與遷移測試仍是 NOT_RUN。

---

## 目錄 (Table of Contents)

1. [第一章：執行摘要與總體評定](#第一章執行摘要與總體評定)
   - 1.1 專案當前版本定位 (v0.2 Collaboration Preview)
   - 1.2 整體健康度評估與亮點實踐
   - 1.3 核心架構風險與交付阻礙
2. [第二章：G0-G5 規格對齊與全功能落差矩陣 (R2)](#第二章g0-g5-規格對齊與全功能落差矩陣-r2)
   - 2.1 全功能落差矩陣表 (Roadmap & Workflow Matrix)
   - 2.2 重點工作流專題深入剖析
     - 專題一：OAuth 2.0 PKCE 認證機制缺失
     - 專題二：原生工件 (Artifacts) 下載 vs 系統瀏覽器 Fallback
     - 專題三：檔案與圖片附件上傳 (Uploads API) 缺失
     - 專題四：Push 推播通知與背景同步缺口
     - 專題五：MR 差異檢視與行內錨定評論缺口
     - 專題六：多帳號切換與世代快取隔離機制評估
3. [第三章：UI/UX 體驗與人機互動深度審查 (R1)](#第三章uiux-體驗與人機互動深度審查-r1)
   - 3.1 響應式佈局自適應 (320 / 412 / 840 dp) 審查
   - 3.2 淺色與深色主題色彩及文字階層對比度
   - 3.3 最小觸控目標 (48 dp Tap Target) 檢驗
   - 3.4 操作載入中與錯誤回饋（404 模糊狀態回饋退化分析）
   - 3.5 離線與中斷狀態下加密草稿保留機制評估
   - 3.6 破壞性操作防呆與二次確認體驗
4. [第四章：代碼品質、靜態分析與自動化測試盲點 (R3)](#第四章代碼品質靜態分析與自動化測試盲點-r3)
   - 4.1 靜態分析現況 (`flutter analyze`) 與規則配置漏洞
   - 4.2 自動化測試套件數據 (`flutter test` 219/219 與 76.88% 覆蓋率)
   - 4.3 重大測試盲區與零覆蓋率核心業務檔案
   - 4.4 歷史孤兒死代碼與幽靈依賴清理審查
   - 4.5 安全性與架構隱患（領域實體裸奔與 Android 安全儲存漏洞）
   - 4.6 實機與真實環境測試缺口（違背 `AGENTS.md` G0 驗收條款）
5. [第五章：結構化缺失清單與改善路線圖 (R3)](#第五章結構化缺失清單與改善路線圖-r3)
   - 5.1 結構化缺失清單 (High / Medium / Low 分級)
   - 5.2 階段演進改善路線圖 (Milestone Remediation Roadmap)

---

## 第一章：執行摘要與總體評定

### 1.1 專案當前版本定位 (v0.2 Collaboration Preview)

`gitlab-mobile` 專案經歷了重大演進，現已脫離 G0 初期的單一唯讀切片，進入 **v0.2 Collaboration Preview**（協作預覽版）。在當前版本中，專案重構了表現層架構，建立起以 `Inbox`（收件匣）、`Projects`（專案工作區）、`CI`（流水線）與 `Me`（個人設定）為核心的行動端四分頁 Shell (`AuthenticatedApp`)。

然而，比對專案規範 `docs/ROADMAP.md`，目前系統呈現出顯著的**「非對稱成熟度」**：
- **G0 / G1（身分驗證與完整唯讀）**：基礎設施完備。PAT 登入、顯式 `/user` 驗證、帳號世代快取隔離、防注入專案定位器、分支/標籤/提交唯讀瀏覽均已落地。
- **G2 / G3（協作與 MR 審查）**：功能廣度優秀，具備 Issue/MR CRUD、Unified Diff 解析、單行錨定評論、MR 批准/合併，但存在「Diff 畫面看不到既有討論」、「討論串無折疊」、「缺乏多行選取評論」等影響審查體驗之缺口。
- **G4 / G5（自動化與發布品質）**：核心進階基建發生斷層。OAuth 2.0 PKCE 認證完全未實作、工件下載依賴外部系統瀏覽器、附件上傳缺失、Push 推播通知為零，且 840 dp 大螢幕平板體驗未適配。

### 1.2 整體健康度評估與亮點實踐

本專案在**架構安全性**與**防呆邊界防護**上展現出極高的工業級水準，具有多項值得肯定的優秀實踐：
1. **嚴格的帳號世代快取隔離**：
   `SessionController` 在切換帳號時遞增 `generation`，配合 `main.dart` 中的 `ValueKey(session.generation)` 重建整棵 Widget 樹，並在切換前調用 `api.close()` 取消所有在途網路請求，徹底杜絕了新舊帳號資料交錯與陳舊回應滲透。
2. **本機加密草稿保留機制**：
   表單統一由 `ResourceEditor` 控管，透過 `FlutterSecureStorage` 以帳號與資源為鍵值加密暫存草稿。當發生網路逾時或驗證失敗時，表單內容絕不遺失；成功寫入或帳號移除時則精確清除。
3. **高防禦性破壞性操作防呆**：
   在刪除專案、檔案、MR、分支、標籤等危險操作中，透過 `confirmAction` 強制要求使用者鍵入確切的目標名稱（如專案路徑、`#iid`、分支名），防止手指誤觸造成災難性後果。
4. **測試套件穩定度**：
   既有單元與 Widget 測試共 **219 項全數通過**，未引入無效或隨意跳過的 assertion，核心解析模組（如分頁標頭容錯、Unified Diff 解析）具備扎實的邊界防護。

### 1.3 核心架構風險與交付阻礙

儘管基礎扎實，但從生產交付與合約合規性審視，專案存在四大核心致命風險：
1. **合約嚴重退化 (AGENTS.md Contract Violation)**：
   `AGENTS.md` 明確規定 404 模糊狀態必須顯示實例、帳號與目標，並提供重試與切換帳號選項。但在 v0.2 重構中，原有的 `ErrorPanel` 被簡化版 `FailureNotice` 取代，導致生產畫面丟失帳號資訊與換帳入口，多帳號使用者存取私有專案遇到 404 時將陷入死胡同。
2. **核心協作畫面自動化測試盲區**：
   自動化測試覆蓋率雖達 76.88%，但最核心的 `InboxPage`（收件匣）行覆蓋率為 **0.00%**；`ReviewDiffPage`（MR 差異與行內留言）行覆蓋率僅 **1.10%**；`SecureAccountStore` 為 **0.00%**。高頻日常協作流程幾乎裸奔運行。
3. **無障礙觸控與大螢幕體驗缺陷**：
   MR Diff 畫面的每一代碼行高度僅約 **31.5 dp**，遠低於 48 dp 最小觸控目標，極易誤觸鄰近代碼行；840 dp 平板環境下未適配側邊導航或雙欄佈局，介面呈現粗糙的全寬延展。
4. **驗收門禁未達標 (NOT_RUN)**：
   專案完全缺乏 `integration_test`，無真機（Android/iOS physical device）測試紀錄，亦未執行真實私有專案的 `live_smoke.dart`，依據 `AGENTS.md` 規範，目前**不可標記 G0 為 ACCEPTED**。

---

## 第二章：G0-G5 規格對齊與全功能落差矩陣 (R2)

### 2.1 全功能落差矩陣表 (Roadmap & Workflow Matrix)

以下矩陣嚴格對齊 `docs/ROADMAP.md`、`ORIGINAL_REQUEST.md` 與當前代碼實作：

| 階段 | 功能項目 | Roadmap 目標規範 | 當前狀態 | 具體代碼檔案路徑 | 嚴重度 | 落差分析與潛在影響 |
|---|---|---|---|---|---|---|
| **G0** | PAT 認證登入 | 支援 PAT、強制 HTTPS、顯式驗證 `/user` | **【已完整實作】** | `lib/core/instance.dart`<br>`lib/features/auth/session_controller.dart`<br>`lib/features/auth/login_screen.dart` | Low | 完整校驗 Host/Scheme/Port，防止 URL 注入與非 HTTPS 連線。 |
| **G0** | 帳號世代快取隔離 | 切換帳號時銷毀舊快取，禁止陳舊回應污染新會話 | **【已完整實作】** | `lib/features/auth/session_controller.dart`<br>`lib/main.dart` | Low | `generation` 遞增觸發 `ValueKey` 重建樹，`api.close()` 取消所有並發請求。 |
| **G0** | 404 模糊狀態防護 | 區分不可見與不存在，展示目前帳號/實例與切換帳號引導 | **【部分實作】** | `lib/core/failure.dart`<br>`lib/shared/error_panel.dart`<br>`lib/shared/workspace_ui.dart` | **High** | 內核支援 `invisible`，但 UI 改用 `FailureNotice` 後丟失切換帳號入口，違反合約。 |
| **G0** | 私有專案定位解析 | 支援 full path 或 numeric ID，過濾 query token，防注入 | **【已完整實作】** | `lib/core/project_locator.dart` | Low | 支援 `/-/` 分割解析，精準過濾 `private_token` 等敏感參數。 |
| **G0** | 安全分頁標頭解析 | 解析 Link 與 x-next-page，保留 caller query | **【已完整實作】** | `lib/core/pagination.dart`<br>`lib/features/workspace/record_controller.dart` | Low | 解決 GitLab expanded defaults 導致的死循環與查詢條件被覆寫問題。 |
| **G0** | 真機與私有專案驗收 | 必須具備 Android/iOS 真機與真實 GitLab 私有專案證據 | **【尚未實作】** | `tool/live_smoke.dart`<br>`docs/V0_2_VERIFICATION.md` | **High** | 官方文件標註為 NOT_RUN，缺乏實機與真實 PAT 驗收紀錄，違反 G0 通過門禁。 |
| **G1** | 專案搜尋與範圍篩選 | 支援 3 類 Scope（我的/星標/可存取）、防抖搜尋 | **【已完整實作】** | `lib/features/workspace/projects_page.dart` | Low | 內建 350ms 防抖，分頁增量載入，搜尋條件保留完好。 |
| **G1** | 倉庫分支/標籤/提交/發布 | 支援 Repository 元數據唯讀清單檢視 | **【已完整實作】** | `lib/features/workspace/project_more_page.dart` | Low | `MetadataPage` 支援 Commits, Releases, Tags, Branches, Labels, Milestones 列表。 |
| **G1** | 代碼檔案樹與 Raw 閱讀 | 固定 commit SHA 瀏覽、避免 stale overwrite、Markdown 預覽 | **【已完整實作】** | `lib/features/workspace/repository_page.dart` | Low | 樹狀目錄與 Blob 閱讀完整，支援 Markdown 原生渲染與 Raw 切換。 |
| **G1** | 個人收件匣 (Inbox / Todos) | 聚合待辦 (Todos)、指派給我、待我審查，一鍵完成 | **【已完整實作】** | `lib/features/workspace/inbox_page.dart` | Low | 業務邏輯完整，支援一鍵完成待辦，但缺乏測試保護（見第四章）。 |
| **G2** | Issue / MR 基礎 CRUD | 建立、編輯、關閉、重開、刪除，防衝突檢查 | **【已完整實作】** | `lib/features/workspace/work_item_page.dart`<br>`lib/core/workspace_api.dart` | Low | 具備 `updated_at` 樂觀鎖衝突檢測；刪除需鍵入 `#iid` 防呆。 |
| **G2** | 討論串 (Discussions) 協作 | 讀取討論串、回覆、編輯/刪除自己的 Note、Resolve 切換 | **【已完整實作】** | `lib/features/workspace/discussions_tab.dart` | Low | 支援討論串解決/重開，Markdown 留言預覽，作者權限防護。 |
| **G2** | 帳號隔離安全草稿 (Drafts) | 失敗或中斷時草稿暫存 Keyring，切換帳號精確清除 | **【已完整實作】** | `lib/features/workspace/editor.dart` | Low | 透過 `FlutterSecureStorage` 綁定帳號與資源路徑，機制健全。 |
| **G2** | 討論串長列表折疊收合 | 支援已解決討論串預設折疊、長討論串手動收合 | **【尚未實作】** | `lib/features/workspace/discussions_tab.dart` | **Medium** | 所有 Note 平鋪直敘展開，長串在手機端滑動極為耗時且耗費記憶體。 |
| **G2** | 標籤與協作者選取器 | 建立/編輯時從專案標籤庫與成員清單中搜尋選取 | **【尚未實作】** | `lib/features/workspace/work_item_page.dart` | **Medium** | 標籤僅為手動鍵入純文字框；協作者僅有單一「指派給我」按鈕。 |
| **G2** | 檔案與圖片附件上傳 | 支援在 Issue/MR/討論串中上傳截圖或檔案 | **【尚未實作】** | `lib/features/workspace/editor.dart`<br>`lib/core/workspace_api.dart` | **High** | 全專案無 Uploads API 串接與圖片選取器，無法在移動端附加錯誤截圖。 |
| **G3** | Unified Diff 差異解析 | 解析 Unified Diff hunk，精準計算 oldLine / newLine | **【已完整實作】** | `lib/core/unified_diff.dart`<br>`lib/features/workspace/diff_page.dart` | Low | 嚴格防範畸形 hunk，行號計算正確，但解析器對 CRLF 容錯不足。 |
| **G3** | 單行精確錨定評論 | 點擊代碼行提交帶有 position 的行內討論串 | **【已完整實作】** | `lib/features/workspace/diff_page.dart` | Low | 正確傳遞 `base_sha`, `start_sha`, `head_sha`, `old_line`, `new_line`。 |
| **G3** | Diff 視圖內嵌既有討論串 | 在差異檢視頁面直接呈現該行已存在的討論串 | **【尚未實作】** | `lib/features/workspace/diff_page.dart` | **High** | Diff 頁面完全未載入既有討論，審查者比對代碼時無法看見他人留下的意見。 |
| **G3** | 多行範圍錨定評論 | 支援多行選取與 `line_range` 參數提交 | **【尚未實作】** | `lib/features/workspace/diff_page.dart` | **Medium** | 目前僅能單選單一行，無法進行區塊代碼審查劃選。 |
| **G3** | MR 審查核准 (Approve) | 綁定 HEAD SHA 的核准與撤銷操作 | **【已完整實作】** | `lib/features/workspace/work_item_page.dart` | Low | 嚴格綁定 SHA，顯示已核准人員清單；但按鈕層級過深。 |
| **G3** | MR 合併執行 (Merge) | 綁定 SHA 之合併執行 | **【部分實作】** | `lib/features/workspace/work_item_page.dart`<br>`lib/core/workspace_api.dart` | **Medium** | 呼叫了 merge API，但缺少 Squash 與刪除來源分支之自選開關（被寫死）。 |
| **G3** | 原生工件 (Artifacts) 下載 | 在 App 內直接下載、預覽或儲存 Job 產物 | **【部分實作】** | `lib/features/workspace/ci_page.dart` | **High** | 僅調用 `openExternal` 跳轉外部瀏覽器，若外部未登入則遭遇 404 或跳登入。 |
| **G4** | CI Pipeline 控制與檢視 | 查看流水線、重試失敗作業、取消、刪除 | **【已完整實作】** | `lib/features/workspace/ci_page.dart` | Low | 支援篩選狀態、Pipeline 詳情卡片與操作選單。 |
| **G4** | CI Job 操作與路由繼承 | 重試 Job、觸發 manual 手動作業、取消 Job | **【已完整實作】** | `lib/features/workspace/ci_page.dart` | Low | 重試成功後自動更新 `_jobId` 保持當前頁面追蹤，體驗平滑。 |
| **G4** | Job 日誌串流 (Log Streaming) | 執行中 Job 之即時日誌檢視與滾動追蹤 | **【部分實作】** | `lib/features/workspace/ci_page.dart` | **Medium** | 採 10 秒前景全量拉取，非增量串流；超過 20,000 行會拋出 `tooLarge` 中斷。 |
| **G4** | OAuth 2.0 PKCE 認證流程 | 支援瀏覽器授權碼模式與 PKCE 安全登入 | **【尚未實作】** | `lib/features/auth/login_screen.dart` | **High** | 無任何 OAuth 依賴、無授權碼回調與 PKCE 密鑰交換實現。 |
| **G4** | Push 推播通知 | 支援 GitLab 事件 (MR 審查、CI 失敗、指派) 系統推播 | **【尚未實作】** | 全專案無依賴與實作 | **High** | 無 APNs/FCM 整合，亦無背景定期輪詢，使用者無法及時獲知協作動態。 |
| **G5** | 多實例多帳號無縫切換 | 支援同時登入多個帳號並安全切換 | **【已完整實作】** | `lib/features/auth/session_controller.dart`<br>`lib/features/shell/authenticated_app.dart` | Low | 切換時重新驗證 `/user`，generation token 隔離機制嚴謹。 |
| **G5** | 破壞性操作防呆機制 | 刪除專案、檔案、Pipeline、MR 需鍵入名稱確認 | **【已完整實作】** | `lib/shared/workspace_ui.dart` | Low | `confirmAction` 要求精確輸入指定文字，防護極為嚴密。 |
| **G5** | 大螢幕自適應 (840 dp) | 平板與折疊機雙欄佈局 (Master-Detail) 與側邊導航 | **【尚未實作】** | `lib/features/shell/authenticated_app.dart` | **High** | 840 dp 下全寬單欄拉伸，未啟用 `NavigationRail`，視覺比例失調。 |

---

### 2.2 重點工作流專題深入剖析

#### 專題一：OAuth 2.0 PKCE 認證機制缺失分析 (狀態：【尚未實作】)
- **代碼現況定位**：
  檢視 `lib/features/auth/login_screen.dart`，UI 僅有 `instanceField` 與 `tokenField`。`lib/features/auth/session_controller.dart:connect` 方法僅接收 `instanceText` 與 `rawToken` 字串。`pubspec.yaml` 中無 `flutter_appauth` 或任何 OAuth 依賴。
- **架構衝擊與影響**：
  使用者在手機上被迫使用瀏覽器登入 GitLab 網頁端、生成 PAT（需手動勾選 `api` scope 與期限）、複製貼回 App。此流程在行動端極為痛苦，且 Personal Access Token 權限過大且缺乏自動 Refresh 機制，Token 到期即引發中斷。
- **具體工程建議**：
  1. 引入 RFC 7636 規範之 PKCE 授權流程，動態生成 `code_verifier` 與 SHA-256 `code_challenge`。
  2. 在 `login_screen.dart` 增加「使用瀏覽器登入 GitLab」按鈕，呼叫系統瀏覽器開啟 `/oauth/authorize`。
  3. 配置 Deep Link（如 `gitlab-mobile://oauth/callback`）接收授權碼，向 `/oauth/token` 換取 `access_token` 與 `refresh_token`，存入 `SecureAccountStore`。

#### 專題二：原生工件 (Artifacts) 下載 vs 系統瀏覽器 Fallback (狀態：【部分實作】)
- **代碼現況定位**：
  在 `lib/features/workspace/ci_page.dart:235-238`：
  ```dart
  if (action == 'artifacts') {
    await openExternal(context, widget.account.instance.projectWeb(
      '${widget.project.path}/-/jobs/$_jobId/artifacts/browse'));
    return;
  }
  ```
- **架構衝擊與影響**：
  若該 Job 產出有工件，使用者點擊「在 GitLab 下載產物」時，App 直接跳出並在系統瀏覽器打開網頁。若使用者在系統瀏覽器中未登入該實例，會被攔截在登入畫面或直接收到 404，完全無法下載 APK、測試報告或建置產物，破壞了行動端閉環體驗。
- **具體工程建議**：
  1. 在 `WorkspaceApi` 新增 `downloadJobArtifacts(int projectId, int jobId, String savePath)`。
  2. 呼叫 GitLab API：`GET /projects/:id/jobs/:job_id/artifacts`，使用 Dio 進行串流下載並監聽進度。
  3. 搭配 `path_provider` 保存至 App 文檔或 Download 目錄，下載完成後調用系統檔案分享/開啟器（如 `open_file`）。

#### 專題三：檔案與圖片附件上傳 (Uploads API) 缺失分析 (狀態：【尚未實作】)
- **代碼現況定位**：
  `lib/features/workspace/editor.dart` 僅提供純文字 `TextFormField`。`lib/core/workspace_api.dart` 完全沒有上傳相關之 API 方法。
- **架構衝擊與影響**：
  在移動端協作中，「截圖回報 Bug」或「拍照反饋 UI」是最高頻的協作場景。目前使用者在撰寫 Issue 或發表評論時，完全無法上傳圖片或檔案，使行動客戶端的協作價值大幅下降。
- **具體工程建議**：
  1. 引入 `image_picker` 套件。
  2. 在 `editor.dart` 工具列增加「插入圖片/檔案」圖示按鈕。
  3. 實作 `uploadProjectFile(int projectId, File file)`：發送 `POST /projects/:id/uploads`（`multipart/form-data`），取得回傳之 `{"markdown": "![image](/uploads/...)"}`，並自動將 Markdown 標記插入文字輸入游標處。

#### 專題四：Push 推播通知與背景同步缺口分析 (狀態：【尚未實作】)
- **代碼現況定位**：
  `pubspec.yaml` 中無推播相關依賴，全專案無 APNs / FCM 憑證或處理常式。目前所有通知純粹依賴使用者主動切換至「收件匣 (`inbox_page.dart`)」手動下拉刷新。
- **架構衝擊與影響**：
  當使用者被指派為 MR 審查者、CI 流水線失敗或收到關鍵討論時，手機無法在鎖定畫面獲得任何即時通知，延誤團隊響應速度。
- **具體工程建議**：
  針對自託管與獨立客戶端架構，可採取**本地背景輪詢通知**策略：
  1. 引入 `workmanager`（Android）與 `background_fetch`（iOS），搭配 `flutter_local_notifications`。
  2. 設定每 15-30 分鐘於背景調用 `/todos?state=pending`。
  3. 比對本地上次已通知的待辦 ID 集合，若偵測到新項目即在手機端發出本地系統通知。

#### 專題五：MR 差異檢視與行內錨定評論缺口分析 (狀態：【部分實作】)
- **代碼現況定位**：
  `lib/features/workspace/diff_page.dart` 中，單行錨定評論邏輯已就緒（點擊代碼行生成包含 `base_sha`, `head_sha`, `old_line`, `new_line` 之 position 並呼叫 `createDiscussion`）。
- **核心嚴重缺口**：
  1. **Diff 畫面看不到既有討論**：`_DiffFileScreen` 只解析並渲染 `file['diff']`，完全沒有請求該 MR 的既有討論串！審查者在對照代碼時，無法得知該行是否已有其他同事提出異議或要求修改。
  2. **缺少多行評論選取**：不支援劃選多行程式碼提交 `line_range` 評論。
  3. **Diff 與 DiscussionsTab 彼此割裂**：在討論分頁看到行評論時，無法點擊跳轉回代碼差異檢視其上下文。
- **具體工程建議**：
  1. 進入 Diff 頁面時並行載入 MR 的 `discussions`。
  2. 依據 `position.new_path == file.new_path` 與 `position.new_line == line.newLine` 進行過濾匹配。
  3. 在有討論的代碼行下方插入討論卡片或未解決徽章，點擊可展開查看或回覆。

#### 專題六：多帳號切換與世代快取隔離機制評估 (狀態：【已完整實作】)
- **代碼現況定位**：
  `lib/features/auth/session_controller.dart:147-151`：
  ```dart
  void _activate(Account account, GitLabApi client) {
    api?.close();
    active = account; api = client; generation++;
  }
  ```
  `lib/main.dart:42-45`：
  ```dart
  if (session.active != null && session.api != null) {
    return AuthenticatedApp(key: ValueKey(session.generation), session: session);
  }
  ```
- **機制評估與肯定**：
  當使用者在多個帳號（如 GitLab.com 與自託管企業實例）之間切換時，系統會先呼叫 `api.close()` 中斷正在執行的舊連線，並向伺服器驗證 `/user`。一旦啟用新帳號，`generation` 遞增，Flutter 透過 `ValueKey(generation)` 強制銷毀整個舊的 `AuthenticatedApp` 及其內部所有 Controller、暫存狀態與 UI。此機制徹底滿足 `AGENTS.md`「Never activate or display a stale response after switching accounts」的合約要求。

---

## 第三章：UI/UX 體驗與人機互動深度審查 (R1)

### 3.1 響應式佈局自適應 (320 / 412 / 840 dp) 審查

本審查在 320 dp（小螢幕/多工分割）、412 dp（主流手機）與 840 dp（平板與折疊展開螢幕）三種典型寬度下進行了介面佈局審核：

```
+-------------------------------------------------------------------------+
| [840 dp 寬度下未適配問題 - 放大版手機]                                  |
|                                                                         |
|  [AppBar: 專案名稱                                    (全寬拉伸)]        |
|  +-------------------------------------------------------------------+  |
|  | 卡片與說明文字橫向拉伸至 800+ dp 寬度，每行文字長達 120+ 字元，閱讀疲勞 |  |
|  +-------------------------------------------------------------------+  |
|  | [巨型按鈕：批准目前版本 (寬度 800 dp)]                             |  |
|  +-------------------------------------------------------------------+  |
|                                                                         |
|  [底部 NavigationBar: 收件匣 | 專案 | CI | 我的 (過度橫向分散)]          |
+-------------------------------------------------------------------------+
```

1. **840 dp 平板與大螢幕未進行雙欄適配 (High)**：
   - **涉及檔案**：`lib/features/shell/authenticated_app.dart:57-96`、`lib/features/workspace/projects_page.dart:78-140`、`lib/features/workspace/work_item_page.dart:195-228`。
   - **現狀缺陷**：除了登入頁設定有 `maxWidth: 500` 之外，其餘所有工作區頁面皆為無約束的全寬 `ListView`。在 840 dp 平板上，卡片和按鈕（如「合併…」、「執行 Pipeline」）被極度橫向拉伸至 800+ dp，視覺極不協調；Markdown 說明的單行字元數遠超人類舒適閱讀區間（45-75 字元）。此外，大螢幕依然採用底部 `NavigationBar`，而未切換為 Material 3 規範之側邊導航欄 (`NavigationRail`)。
   - **修復方案**：在 `AuthenticatedApp` 加入 `LayoutBuilder`，在寬度 >= 720 dp 時改採左側 `NavigationRail`；頁面主體增加響應式寬度約束容器（`maxWidth: 720` 置中）；MR 與 Issue 頁面支援左側資訊、右側討論串的雙欄 Master-Detail 佈局。
2. **320 dp 極窄螢幕下代碼檢視嚴重折行 (Medium)**：
   - **涉及檔案**：`lib/features/workspace/diff_page.dart:140-150`、`lib/features/workspace/repository_page.dart:230-236`。
   - **現狀缺陷**：在 `diff_page.dart` 中，舊行號佔 30 dp、新行號佔 30 dp、變更標記佔 20 dp、左右內邊距共 16 dp，合計已耗去 96 dp，留給代碼的寬度僅剩 **224 dp**。單行僅能容納約 26 個等寬字元，長代碼被劇烈折行，且折行後缺少次行懸掛縮排（Hanging Indent）或折行箭頭標記，代碼排版碎裂混亂。
   - **修復方案**：在 320 dp 下支援單行號切換模式（僅顯示新行號），並增加橫向滾動開關與換行標記。

### 3.2 淺色與深色主題色彩及文字階層對比度

- **色盤設定審查**：
  `lib/shared/theme.dart` 基於 Material 3 建立，定義了安靜的灰白色表面、石墨深色底色與鈷藍色主色調 (`Color(0xFF1068EB)`)，卡片圓角統一為 16 像素。
- **對比度與無障礙表現**：
  1. 狀態標記（`StatusBadge`）：採用 `statusColor` 搭配文字標籤，如已合併為紫色、開啟中為綠色、已關閉為紅色，且強制搭配符號與文字，**完全未僅依賴顏色傳遞狀態**，符合 WCAG 無障礙準則。
  2. 灰色次要文字對比：深色模式下的 `onSurfaceVariant`（約 `0xFFC4C7C5`）在深色背景上的對比度達 5.8:1，超過 WCAG AA 級標準 (4.5:1)。
  3. 終端日誌顏色喪失：`JobLogPage`（`ci_page.dart:219`）將 ANSI 色彩代碼全數以正則抹除，雖然保證了白底或黑底上的文字可讀性，但使終端原本關鍵的錯誤（紅）、警告（黃）、成功（綠）層次全部退化為灰白純文字，嚴重削弱除錯效率。

### 3.3 最小觸控目標 (48 dp Tap Target) 檢驗

`docs/UI_REDESIGN.md` 明定「48-logical-pixel minimum principal actions」。主按鈕（`FilledButton`、`OutlinedButton`、`IconButton`）皆符合此規範。

然而，在 **MR Diff 行內留言** 上發現嚴重觸控缺陷：
- **涉及檔案**：`lib/features/workspace/diff_page.dart:138-151`
- **現狀量測**：每一代碼行由 `Material` 與 `InkWell` 包裹，內邊距為 `EdgeInsets.symmetric(horizontal: 8, vertical: 6)`，字型高度為 `13 * 1.5 = 19.5 dp`，整行點擊高度僅約 **31.5 dp**。
- **影響與危害**：雖然代碼列表難以將每行高度擴大至 48 dp（否則一屏僅能展示數行），但目前點擊任意行即直接觸發 `_comment(line)` 彈出編輯器。在手指觸控時，極易點到目標行的上一行或下一行（例如要評論第 42 行卻誤觸第 41 行），破壞代碼審查嚴謹性。
- **修復方案**：將行號區域設計為可擴展的獨立點擊熱區；或在使用者點擊某行時先提供高亮選取反饋，並在右側浮出「在此行留言」快捷氣泡供確認，防止誤點即刻彈出全螢幕編輯器。

### 3.4 操作載入中與錯誤回饋（404 模糊狀態回饋退化分析）

#### 【重大規範違背】404 模糊狀態回饋合約嚴重退化 (High)
- **涉及檔案**：
  - `lib/shared/workspace_ui.dart:93-114` (`FailureNotice`)
  - `lib/features/workspace/records_feed.dart:40-41`
  - `lib/shared/error_panel.dart:1-42` (被廢棄)
  - `lib/features/workspace/ci_page.dart:50, 143`
  - `lib/features/workspace/work_item_page.dart:68`
- **問題深度分析**：
  `AGENTS.md` 明文規定：
  > *「404 is ambiguous: inaccessible and nonexistent private resources cannot always be distinguished. Show the current account, instance and resource plus explicit retry/account-switch options. Do not silently rotate through accounts.」*
  在 G0 早期建立之 `lib/shared/error_panel.dart` 中，完整實作了展示目前實例 (`account.instance.key`)、當前帳號 (`@account.user.username`)、目標資源標籤 (`resourceLabel`)，並提供「重新檢查」、「切換帳號」、「瀏覽器開啟」三個明確按鈕。
  
  但在 v0.2 重構中，所有列表（`RecordsFeed`）與詳情畫面全面改用 `FailureNotice`。`FailureNotice` 僅具備 `onRetry` 按鈕，完全沒有 `onSwitchAccount` 與 `onOpenBrowser`！更嚴重的是，呼叫 `RecordsFeed` 之處**高達 90% 未傳入 `contextLabel`**。當發生 404 時，畫面僅顯示模糊提示「無法開啟此資源。目前帳號無法存取，或資源已移動／刪除。」，診斷資訊折疊且無帳號資訊，使用者無法辨別當前是哪一個帳號存取失敗，也無從原地切換帳號。

### 3.5 離線與中斷狀態下加密草稿保留機制評估

- **涉及檔案**：`lib/features/workspace/editor.dart:9-16, 50-70`
- **機制剖析**：
  1. 編輯器透過 `_draftStorage` 監聽輸入框變更，經過 400ms 防抖後將表單欄位以 JSON 寫入 Keyring。
  2. 鍵名結構為 `draft.v2.<base64Url(account.key)>.<resource>`，嚴格以帳號與資源路徑進行命名空間隔離。
  3. 當網路逾時（`FailureKind.timeout`）或中斷（`FailureKind.writeUncertain`）時，表單內容完整保留於本機；重新進入編輯器會自動還原草稿；唯有成功儲存或刪除帳號時才會執行清除。
- **評定結論**：此機制健全可靠，大幅提升了弱網環境下的內容安全性。惟一缺失為 Android 端未顯式配置硬體 Keystore（見第四章）。

### 3.6 破壞性操作防呆與二次確認體驗

- **涉及檔案**：`lib/shared/workspace_ui.dart:18-38` (`confirmAction`)
- **機制剖析**：
  在執行刪除操作（專案、檔案、MR、分支、標籤）時，`confirmAction` 對話框要求使用者必須在輸入框中**精確輸入目標名稱**（如專案全路徑 `group/project`、分支名稱 `main`、MR 編號 `#12`），方能啟用確定按鈕。
- **評定結論**：防呆體驗符合最高安全標準，有效阻斷了行動端常見的滑動誤觸或快點確認造成的意外刪除。

---

## 第四章：代碼品質、靜態分析與自動化測試盲點 (R3)

### 4.1 靜態分析現況 (`flutter analyze`) 與規則配置漏洞

- **分析執行指令**：`fvm flutter analyze --no-pub`
- **執行結果**：`No issues found! (ran in 4.1s)`
- **`analysis_options.yaml` 配置評估**：
  專案開啟了嚴格型別模式：
  ```yaml
  analyzer:
    language:
      strict-casts: true
      strict-inference: true
      strict-raw-types: true
  ```
  這成功阻絕了大部分隱式向下轉型問題。然而，Lint 配置存在嚴重防禦漏洞：
  1. **缺少 `avoid_dynamic_calls`**：全專案大量使用 `typedef Json = Map<String, dynamic>;`，未啟用此規則導致分析器對 `dynamic` 屬性或方法調用完全不報警，極易引發執行期 `NoSuchMethodError`。
  2. **缺少資源釋放規則**：缺少 `cancel_subscriptions` 與 `close_sinks`，無法在編譯期檢測 Timer、StreamSubscription 或 Sink 洩漏。
  3. **缺少 `discarded_futures`**：無法自動偵測遺漏 `await` 或 `unawaited` 的非同步操作。

### 4.2 自動化測試套件數據 (`flutter test` 219/219 與 76.88% 覆蓋率)

- **測試執行指令**：`fvm flutter test --coverage --no-pub`
- **執行結果**：**219 個測試全數通過**，0 個失敗，0 個跳過，耗時 19.2 秒。
- **總體行覆蓋率統計**：
  - 總有效行數 (Lines Found)：**1,998 行**
  - 命中行數 (Lines Hit)：**1,536 行**
  - **總覆蓋率 (Overall Coverage)**：**76.88%**

### 4.3 重大測試盲區與零覆蓋率核心業務檔案

經對 `coverage/lcov.info` 進行逐檔穿透性分析，發現以下關鍵檔案處於測試防護盲區：

| 檔案路徑 | 總行數 | 命中行數 | 覆蓋率 | 盲區性質與潛在風險 |
|---|---|---|---|---|
| `lib/features/workspace/inbox_page.dart` | 48 | 0 | **0.00%** | 🚨 **收件匣核心功能 0% 覆蓋**。待辦完成、指派與審查篩選完全未受測試保護。 |
| `lib/features/workspace/diff_page.dart` | 91 | 1 | **1.10%** | 🚨 **MR 差異檢視與行留言極低覆蓋**。代碼對照、行留言錨定完全未經自動化測試。 |
| `lib/features/auth/account_store.dart` | 12 | 0 | **0.00%** | 🚨 **核心憑證安全儲存 0% 覆蓋**。測試全用 MemoryAccountStore，繞過真實儲存邏輯。 |
| `lib/shared/external_link.dart` | 7 | 0 | **0.00%** | 🚨 **外部跳轉安全 0% 覆蓋**。Scheme 檢驗與 token 參數過濾未受測試檢驗。 |
| `lib/features/shell/authenticated_app.dart` | 53 | 20 | **37.74%** | ⚠️ **主導航架構低覆蓋**。分頁切換與外觀模式切換未充分測試。 |
| `lib/shared/markdown_view.dart` | 22 | 13 | **59.09%** | ⚠️ **Markdown 檢視部分覆蓋**。超長截斷 (>64Ki) 與敏感參數過濾未命中。 |

此外，在多尺寸佈局測試 `workspace_widget_test.dart` 中，雖然測試了 `320.0, 412.0, 840.0` 與 `scale: 1.0, 2.0`，但其斷言僅為 `expect(tester.takeException(), isNull)`，僅能防範 Crash，無法檢驗文字溢出、佈局拉伸或截斷等視覺瑕疵。

### 4.4 歷史孤兒死代碼與幽靈依賴清理審查

勘測發現代碼庫中殘留 5 個 G0 時期的歷史檔案，在 v0.2 的 `AuthenticatedApp` 導航架構中已**完全未被引用**：
- `lib/features/code/file_screen.dart` (覆蓋率 0.00%)
- `lib/features/code/file_args.dart` (覆蓋率 0.00%)
- `lib/features/projects/projects_screen.dart` (覆蓋率 0.00%)
- `lib/features/projects/project_detail_screen.dart` (覆蓋率 0.00%)
- `lib/shared/error_panel.dart` (覆蓋率 0.00%)

同時，`pubspec.yaml` 中宣告的 `go_router: 16.3.0` 僅在上述廢棄頁面中被 import。主程式已全面改用 Flutter 原生導航 (`Navigator.push`)，`go_router` 實際上已成為**幽靈依賴 (Ghost Dependency)**，應予清理。

### 4.5 安全性與架構隱患（領域實體裸奔與 Android 安全儲存漏洞）

1. **業務實體裸奔 `Map<String, dynamic>` (Domain Entity Gap)**：
   除 G0 的 `Account`、`GitLabUser`、`Project`、`TreeEntry` 具有強型別模型外，所有 v0.2 的核心實體（Issue, MR, Pipeline, Job, Note, Release, Label）全數使用 `typedef Json = Map<String, dynamic>;`。UI 層充斥著 `valueText(data, 'title')`、`valueInt(data, 'iid')` 這類動態提取邏輯，喪失了編譯期型別防護與 IDE 自動補全，拼寫錯誤只能在執行期暴露。
2. **Android 端安全儲存遺漏硬體 Keystore 配置 (Security Flaw)**：
   在 `lib/features/auth/account_store.dart:15` 與 `lib/features/workspace/editor.dart:9` 中，初始化 `FlutterSecureStorage` 時僅指定了 `IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device)`，**完全遺漏了 `AndroidOptions(encryptedSharedPreferences: true)`**。在部分 Android 設備上可能回退至弱加密或相容模式，存在憑證外洩風險。

### 4.6 實機與真實環境測試缺口（違背 `AGENTS.md` G0 驗收條款）

- `pubspec.yaml` 宣告了 `integration_test: sdk: flutter`，但專案中根本不存在 `integration_test/` 目錄。
- 專案所有 219 個測試皆使用記憶體 Mock (`FakeAdapter` 與 `WorkspaceFixture`)。
- 依據 `AGENTS.md` 核心合約：
  > *"Do not mark G0 accepted based only on compilation or mocked API tests. No G0 acceptance without real private-project integration and Android/iOS device evidence."*
- 雖然專案具備 `tool/live_smoke.dart`，但在 CI 與手動記錄中皆標註為 `NOT_RUN`。因此，專案在合約驗收準則意義上**尚未真正完成 G0 門禁驗收**。

---

## 第五章：結構化缺失清單與改善路線圖 (R3)

### 5.1 結構化缺失清單 (Defect Inventory by Severity)

本清單按照嚴重度（High / Medium / Low）嚴格分級，詳細列明每項缺失之描述、影響、精確代碼行號與具體工程修復方案。

---

#### 🔴 高嚴重度問題 (High Severity Issues)

##### 【ISSUE-H01】404 模糊狀態回饋合約退化，缺少切換帳號引導與上下文標籤
- **嚴重度**：`High`
- **影響範疇**：多帳號協作、私有專案存取、合約合規性
- **涉及檔案與行號**：
  - `lib/shared/workspace_ui.dart:93-114` (`FailureNotice`)
  - `lib/features/workspace/records_feed.dart:40-41`
  - `lib/shared/error_panel.dart:1-42` (被廢棄)
  - `lib/features/workspace/projects_page.dart:104-106`
  - `lib/features/workspace/ci_page.dart:50, 143`
  - `lib/features/workspace/work_item_page.dart:68`
- **問題描述**：
  專案合約 `AGENTS.md` 規定 404 狀態必須顯示目前實例、帳號與資源，並提供切換帳號選項。但在 v0.2 重構中，`ErrorPanel` 被替換為 `FailureNotice`。`FailureNotice` 僅具備重試按鈕，無帳號資訊與切換帳號動作，且呼叫方 90% 未傳遞 `contextLabel`。
- **具體工程修復建議**：
  1. 重構 `FailureNotice`，加入 `account`、`instance` 與 `onSwitchAccount` 參數。
  2. 當錯誤類型為 `FailureKind.invisible` (404) 或 `forbidden` (403) 時，強制在卡片中顯示目前帳號並提供「切換帳號」（彈出帳號選擇底欄）按鈕。
  3. 為所有 `RecordsFeed` 與詳情頁補齊明確的 `contextLabel`。

##### 【ISSUE-H02】MR Diff 程式碼行點擊熱區過小 (~31.5 dp)，違反 48 dp 觸控規範
- **嚴重度**：`High`
- **影響範疇**：MR 代碼審查、觸控無障礙 (Accessibility)
- **涉及檔案與行號**：
  - `lib/features/workspace/diff_page.dart:138-151`
- **問題描述**：
  Diff 頁面每一代碼行高僅約 31.5 dp，遠低於 48 dp 規範。使用者在手機上觸摸時極易誤觸相鄰行數，且點擊即刻彈出全螢幕留言編輯器，極易將審查意見錨定在錯誤的代碼行。
- **具體工程修復建議**：
  1. 將代碼行垂直內邊距擴展至適度高度（如 vertical 8 dp，行高 ~38 dp）。
  2. 點擊代碼行時先高亮選取該行，並在行號側邊浮出「留言」動作氣泡，經確認後再開啟編輯器，避免直接彈窗。

##### 【ISSUE-H03】840 dp 平板與大螢幕缺乏雙欄自適應，介面全寬拉伸
- **嚴重度**：`High`
- **影響範疇**：平板電腦、折疊螢幕展開態、大螢幕人機互動
- **涉及檔案與行號**：
  - `lib/features/shell/authenticated_app.dart:57-96`
  - `lib/features/workspace/projects_page.dart:78-140`
  - `lib/features/workspace/work_item_page.dart:195-228`
- **問題描述**：
  在 840 dp 下，列表、卡片與操作按鈕無約束拉伸至 800+ dp，視覺極其空曠比例失調，Markdown 行長嚴重超標，且未啟用 Material 3 `NavigationRail`。
- **具體工程修復建議**：
  1. 在 `AuthenticatedApp` 引入 `LayoutBuilder`，當 `maxWidth >= 720` 時切換為側邊 `NavigationRail` + 內容區。
  2. 工作區列表與詳情外層加入 `Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: 720)))`。
  3. MR 與 Issue 詳情頁在 840 dp 下改採雙欄 Master-Detail 佈局（左欄摘要與變更，右欄討論串）。

##### 【ISSUE-H04】OAuth 2.0 PKCE 網頁授權登入流程完全缺失
- **嚴重度**：`High`
- **影響範疇**：認證登入體驗、帳號安全性
- **涉及檔案與行號**：
  - `lib/features/auth/login_screen.dart`
  - `lib/features/auth/session_controller.dart`
  - `pubspec.yaml`
- **問題描述**：
  僅支援手動貼上 Personal Access Token (PAT)，行動端操作繁瑣且 Token 到期無法自動刷新。
- **具體工程修復建議**：
  1. 引入 `flutter_appauth` 套件。
  2. 實作 RFC 7636 PKCE 流程，在 `LoginScreen` 增加「透過 GitLab 授權登入」按鈕。
  3. 監聽 Deep Link 回調取得授權碼並換取 `access_token` 與 `refresh_token`。

##### 【ISSUE-H05】原生工件 (Artifacts) 無法在 App 內下載，僅以外部系統瀏覽器 Fallback 替代
- **嚴重度**：`High`
- **影響範疇**：CI/CD 產物檢驗、閉環體驗
- **涉及檔案與行號**：
  - `lib/features/workspace/ci_page.dart:235-238`
- **問題描述**：
  點擊「在 GitLab 下載產物」時直接調用 `openExternal` 跳轉外部瀏覽器。若使用者在瀏覽器未登入該實例，會遭阻攔在登入頁或收到 404。
- **具體工程修復建議**：
  1. 在 `WorkspaceApi` 實作 `downloadJobArtifacts(int projectId, int jobId, String savePath)`。
  2. 呼叫 `GET /projects/:id/jobs/:job_id/artifacts` 串流下載至本機儲存空間，下載完成後調用系統檔案分享/開啟器。

##### 【ISSUE-H06】檔案與圖片附件上傳 (Uploads API) 功能完全缺失
- **嚴重度**：`High`
- **影響範疇**：Issue 回報、MR 審查截圖協作
- **涉及檔案與行號**：
  - `lib/features/workspace/editor.dart`
  - `lib/core/workspace_api.dart`
- **問題描述**：
  全專案無任何圖片或附件選取與上傳功能，無法在 Issue、MR 或留言中附帶螢幕截圖。
- **具體工程修復建議**：
  1. 引入 `image_picker` 套件。
  2. 在 `editor.dart` 工具列提供插入圖片按鈕，呼叫 `POST /projects/:id/uploads` 上傳圖片，並將回傳的 Markdown 語法自動插入文字框。

##### 【ISSUE-H07】Push 推播通知與背景同步機制完全缺失
- **嚴重度**：`High`
- **影響範疇**：通知及時性、協作響應延遲
- **涉及檔案與行號**：
  - `pubspec.yaml`
  - `lib/features/workspace/inbox_page.dart`
- **問題描述**：
  無 APNs / FCM 整合，亦無背景輪詢服務，審查請求或 CI 失敗無法在裝置上發出系統通知。
- **具體工程修復建議**：
  1. 引入 `workmanager` 與 `flutter_local_notifications`。
  2. 設定背景週期任務，每 15-30 分鐘輪詢 `/todos?state=pending`，偵測新項目即發布本機推播通知。

##### 【ISSUE-H08】Diff 差異檢視頁面未呈現既有討論串 (Inline Discussions)
- **嚴重度**：`High`
- **影響範疇**：MR 代碼審查有效性
- **涉及檔案與行號**：
  - `lib/features/workspace/diff_page.dart`
- **問題描述**：
  Diff 頁面僅渲染 Unified Diff 代碼行，完全未拉取或標記既有討論串，審查者無法在代碼行旁看到他人的審查意見。
- **具體工程修復建議**：
  1. 載入 Diff 檔案時並行載入 MR 的 `discussions`。
  2. 依據檔案路徑與行號匹配討論，在代碼行下方嵌入可收合的討論卡片與回覆按鈕。

##### 【ISSUE-H09】核心協作畫面完全缺乏自動化測試（Inbox 0% 與 Diff 1.10%）
- **嚴重度**：`High`
- **影響範疇**：自動化回歸防護、CI 信心度
- **涉及檔案與行號**：
  - `lib/features/workspace/inbox_page.dart:1-83` (覆蓋率 0.00%)
  - `lib/features/workspace/diff_page.dart:1-156` (覆蓋率 1.10%)
- **問題描述**：
  收件匣待辦完成、MR 差異檢視與單行留言錨定在自動化測試套件中幾乎處於零覆蓋盲區。
- **具體工程修復建議**：
  1. 編寫 `test/inbox_page_test.dart`，驗證待辦切換、標記完成與刷新機制。
  2. 編寫 `test/diff_page_test.dart`，驗證 SHA 衝突校驗、點擊差異行留言與 position 參數結構。

##### 【ISSUE-H10】領域模型缺乏強型別封裝，大量依賴動態 `Map<String, dynamic>`
- **嚴重度**：`High`
- **影響範疇**：靜態型別安全、代碼維護性、執行期穩定性
- **涉及檔案與行號**：
  - `lib/core/workspace_api.dart`
  - `lib/features/workspace/work_item_page.dart`
  - `lib/features/workspace/ci_page.dart`
- **問題描述**：
  v0.2 核心實體（Issue, MR, Pipeline, Job, Note 等）全部使用裸奔的 `Json`，UI 層充滿手動提取函數，缺乏編譯期靜態檢查。
- **具體工程修復建議**：
  建立標準實體類別（如 `IssueRecord`、`MergeRequestRecord`、`PipelineRecord`），具備嚴格的 `fromJson` 解析與型別屬性。

##### 【ISSUE-H11】Android 端安全儲存遺漏硬體 Keystore 配置
- **嚴重度**：`High`
- **影響範疇**：憑證與草稿儲存安全性
- **涉及檔案與行號**：
  - `lib/features/auth/account_store.dart:13-16`
  - `lib/features/workspace/editor.dart:9`
- **問題描述**：
  `FlutterSecureStorage` 僅配置了 iOS Keychain，完全未指定 `AndroidOptions(encryptedSharedPreferences: true)`，部分設備存在回退至弱加密之風險。
- **具體工程修復建議**：
  統一 SecureStorage 初始化工廠，顯式加上 `aOptions: const AndroidOptions(encryptedSharedPreferences: true)`。

##### 【ISSUE-H12】缺乏 Android/iOS 真機與真實私有專案集成驗證 (NOT_RUN)
- **嚴重度**：`High`
- **影響範疇**：G0 驗收門禁合規性
- **涉及檔案與行號**：
  - `tool/live_smoke.dart`
  - `docs/V0_2_VERIFICATION.md`
  - `pubspec.yaml:22-23`
- **問題描述**：
  測試 100% 依賴記憶體 Mock，無 `integration_test/`，實機與真實 PAT 驗證標註為 NOT_RUN，違背 `AGENTS.md` G0 驗收條件。
- **具體工程修復建議**：
  1. 建立 `integration_test/app_test.dart` 執行端到端煙霧測試。
  2. 在安全受控環境下執行 `tool/live_smoke.dart` 並記錄真實驗證日誌。

---

#### 🟡 中嚴重度問題 (Medium Severity Issues)

##### 【ISSUE-M01】320 dp 極窄螢幕下代碼可用寬度僅 224 dp，折行排版破碎混亂
- **涉及檔案**：`lib/features/workspace/diff_page.dart:140-150`、`lib/features/workspace/repository_page.dart:230-236`
- **問題描述**：行號與標記佔用 96 dp，留給代碼僅 224 dp，單行僅容納 ~26 字元，頻繁折行且無懸掛縮排或箭頭。
- **修復建議**：支援單行號切換模式，並在折行處加入淡色折行符號（`↩`）與縮排保護。

##### 【ISSUE-M02】代碼檔案檢視在關閉換行模式下每行各自獨立捲動，代碼結構無法對齊
- **涉及檔案**：`lib/features/workspace/repository_page.dart:226-236`
- **問題描述**：`SingleChildScrollView(scrollDirection: Axis.horizontal)` 置於每一行內部，滑動某一行時其餘行不動，排版徹底錯位。
- **修復建議**：將水平滾動包裹在 `ListView` 外層，實現整份檔案同步水平捲動。

##### 【ISSUE-M03】CI 日誌 ANSI 顏色碼被正則強制剔除，且長行強制折行排版碎裂
- **涉及檔案**：`lib/features/workspace/ci_page.dart:219, 297-302`
- **問題描述**：正則刪除所有 ANSI 碼使報錯/警告高亮消失；日誌長行強行折行導致 Stack Trace 變形。
- **修復建議**：引入 ANSI 轉 `TextSpan` 解析器，並提供橫向滾動與自動換行開關。

##### 【ISSUE-M04】登入頁面缺少已儲存失效帳號之移除機制
- **涉及檔案**：`lib/features/auth/login_screen.dart:42-46`、`lib/features/auth/session_controller.dart:88-91`
- **問題描述**：登入頁面帳號卡片僅能點擊登入，若 Token 失效無法從裝置刪除，永久滯留於登入頁。
- **修復建議**：在卡片加入左滑刪除 (Dismissible) 或長按彈出「自此裝置移除」選項。

##### 【ISSUE-M05】MR 核准 (Approve) 與合併 (Merge) 操作按鈕置於第四個 Tab 底部，路徑過深
- **涉及檔案**：`lib/features/workspace/work_item_page.dart:206, 273-280`
- **問題描述**：核心操作埋在第四個「檢查」分頁的最下方，看完代碼變更後無法快速操作。
- **修復建議**：在 MR 頁面提供底部常駐操作欄 (Sticky Bottom Bar)，或在頂部 AppBar 選單提供快捷入口。

##### 【ISSUE-M06】MR 合併執行缺少 Squash Commits 與 刪除來源分支自選開關
- **涉及檔案**：`lib/core/workspace_api.dart:41-43`、`lib/features/workspace/work_item_page.dart:166`
- **問題描述**：API 中 `should_remove_source_branch` 硬編碼為 `false`，UI 確認對話框無選項可供勾選。
- **修復建議**：在合併確認對話框中提供「Squash commits」與「刪除來源分支」Checkbox。

##### 【ISSUE-M07】討論串列表缺乏長串與已解決 (Resolved) 折疊收合功能
- **涉及檔案**：`lib/features/workspace/discussions_tab.dart`
- **問題描述**：所有討論串平鋪展開，熱門 MR 的長討論串嚴重干擾滑動與閱讀。
- **修復建議**：若討論串 `resolved == true` 預設折疊，僅顯示解決者與最新一則摘要。

##### 【ISSUE-M08】缺少標籤 (Labels) 與協作者 (Assignees/Reviewers) 點選選擇器
- **涉及檔案**：`lib/features/workspace/work_item_page.dart:44, 125`
- **問題描述**：標籤僅能手動輸入字串，協作者無法搜尋指派他人，亦無法指派 Reviewer。
- **修復建議**：串接專案標籤與成員 API，提供點選式選擇彈窗。

##### 【ISSUE-M09】Job 日誌缺乏增量串流傳輸，依賴定時全量拉取且超長直接拋錯
- **涉及檔案**：`lib/features/workspace/ci_page.dart:217-223`
- **問題描述**：每 10 秒全量拉取一次 trace，超過 20,000 行拋錯拒絕顯示。
- **修復建議**：採用 HTTP Range 標頭進行增量拉取（`bytes=offset-`），降低頻寬消耗。

##### 【ISSUE-M10】孤兒死代碼未清理與幽靈依賴 `go_router` 殘留
- **涉及檔案**：`lib/features/projects/projects_screen.dart`、`lib/features/code/file_screen.dart`、`pubspec.yaml:18`
- **問題描述**：G0 遺留的 5 個舊畫面未被使用，`go_router` 為多餘依賴。
- **修復建議**：刪除未引用的舊檔案，從 `pubspec.yaml` 移除 `go_router`。

##### 【ISSUE-M11】狀態管理架構割裂：Riverpod 徒具虛名，實質為 5-6 層 Prop Drilling
- **涉及檔案**：`lib/core/providers.dart`、`lib/main.dart`、`lib/features/shell/authenticated_app.dart`
- **問題描述**：僅宣告一個 `sessionProvider`，底層組件全部透過 Widget 參數層層透傳。
- **修復建議**：擴充 Riverpod providers，底層 Widget 改為 `ConsumerWidget` 直接就近讀取。

##### 【ISSUE-M12】Unified Diff 解析器缺乏 CRLF 與 extended headers 容錯
- **涉及檔案**：`lib/core/unified_diff.dart:20, 38-44`
- **問題描述**：遇 Windows CRLF 或 hunk 前 extended headers 時會拋出 `FormatException`。
- **修復建議**：頂層統一將 `\r\n` 替換為 `\n`，並略過 hunk 前之 headers。

##### 【ISSUE-M13】`SecureAccountStore` 與 `external_link.dart` 缺乏單元測試
- **涉及檔案**：`lib/features/auth/account_store.dart`、`lib/shared/external_link.dart`
- **問題描述**：行覆蓋率 0.00%，未驗證真實安全儲存反序列化與外部連結 scheme 防護。
- **修復建議**：為其撰寫專屬單元測試。

##### 【ISSUE-M14】缺少富文本 Markdown 輔助工具列與即時編輯預覽
- **涉及檔案**：`lib/features/workspace/editor.dart`
- **問題描述**：編輯器僅為陽春純文字框，在手機上鍵入 Markdown 符號極為不便。
- **修復建議**：在鍵盤上方提供常用 Markdown 快捷按鈕，並支援分頁預覽。

---

#### 🟢 低嚴重度問題 (Low Severity Issues)

##### 【ISSUE-L01】代碼行號固定寬度與 2x 大字體缺乏縮放 clamp，存在文字溢出隱患
- **涉及檔案**：`lib/features/workspace/repository_page.dart:232`、`lib/features/workspace/diff_page.dart:142-144`
- **修復建議**：依據總行數動態計算寬度，並為行號文字加入 `textScaler` clamp。

##### 【ISSUE-L02】敏感 Token 在記憶體中以不可變 String 保存無法主動銷毀
- **涉及檔案**：`lib/core/models.dart`、`lib/core/gitlab_api.dart`
- **修復建議**：評估敏感憑證在記憶體中的生命週期與持有方式。

##### 【ISSUE-L03】MarkdownView 超長截斷 (>64Ki) 與敏感 URL 參數過濾缺乏測試覆蓋
- **涉及檔案**：`lib/shared/markdown_view.dart`
- **修復建議**：在單元測試中補充超長字串與帶 token 連結的測試案例。

##### 【ISSUE-L04】缺少倉庫二進位檔案（圖片、PDF）之行動端原生預覽支援
- **涉及檔案**：`lib/features/workspace/repository_page.dart:82`
- **修復建議**：常見圖片格式（PNG, JPG, SVG）透過 raw API 讀取並以 `Image.memory` 預覽。

---

### 5.2 階段演進改善路線圖 (Milestone Remediation Roadmap)

為使專案自當前 v0.2 Collaboration Preview 穩健邁向正式交付水準，建議採行四個階段循序推進：

```
+-------------------------------------------------------------------------+
| Milestone 1 (P0: 合約合規與安全性修復 - 預估 3 天)                       |
| - 修復 404 模糊狀態回饋 (FailureNotice 補齊帳號與切換入口) [ISSUE-H01]    |
| - Android SecureStorage 啟用 EncryptedSharedPreferences [ISSUE-H11]    |
| - 清理 G0 孤兒死代碼與幽靈依賴 go_router [ISSUE-M10]                    |
| - 修復 Diff 解析器 CRLF 容錯問題 [ISSUE-M12]                            |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
| Milestone 2 (P1: 核心體驗與測試覆蓋補全 - 預估 1 週)                     |
| - 擴大 Diff 行留言觸控熱區至無障礙標準 [ISSUE-H02]                      |
| - Diff 頁面內嵌呈現既有討論串 [ISSUE-H08]                               |
| - 補齊 Inbox (0%)、Diff (1.1%) 與 SecureStorage (0%) 自動化測試 [H09, M13] |
| - 修正代碼檢視非換行模式下同步水平捲動 [ISSUE-M02]                       |
| - 登入頁新增已存帳號刪除入口 [ISSUE-M04]                                |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
| Milestone 3 (P1/P2: 平台進階功能與大螢幕適配 - 預估 2 週)               |
| - 840 dp 平板大螢幕 NavigationRail 與雙欄 Master-Detail 適配 [ISSUE-H03] |
| - 原生工件 (Artifacts) 下載與檔案分享 [ISSUE-H05]                       |
| - 檔案與圖片附件上傳 (Uploads API) [ISSUE-H06]                          |
| - 討論串列表折疊與展開支援 [ISSUE-M07]                                  |
| - CI 日誌保留 ANSI 著色與橫向滾動 [ISSUE-M03]                           |
| - MR 合併選項增加 Squash 與刪除來源分支 [ISSUE-M06]                      |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
| Milestone 4 (P2/P3: 企業級認證、強型別與驗收閉環 - 預估 2 週)           |
| - OAuth 2.0 PKCE 網頁授權登入流程 [ISSUE-H04]                           |
| - Push 本機背景推播通知 (Workmanager / Background Fetch) [ISSUE-H07]    |
| - 領域模型強型別化 (封裝 Json) 與啟用 avoid_dynamic_calls [ISSUE-H10]    |
| - 建立真實環境 integration_test 與執行 live_smoke.dart 達成 G0 閉環 [H12]|
+-------------------------------------------------------------------------+
```

---

## 結論與總評

`gitlab-mobile` 在安全性架構（帳號世代快取隔離、本機草稿加密暫存、嚴格名稱鍵入防呆確認）上展現了極高的設計成熟度，核心功能廣度已顯著跨越 G0 邊界，形成了可用的協作原型。

然而，專案在人機互動合約（404 模糊狀態退化）、無障礙觸控（Diff 31.5 dp）、測試覆蓋盲區（Inbox 0%、Diff 1.1%）與進階基建（OAuth、工件下載、附件上傳、Push 通知、840 dp 平板適配）上存在顯著斷層。透過本報告提出的結構化缺失清單與四階段演進路線圖，工程團隊可精準修復關鍵缺陷，最終打造出兼具安全、專業與高互動水準的 GitLab 行動端客戶端。
