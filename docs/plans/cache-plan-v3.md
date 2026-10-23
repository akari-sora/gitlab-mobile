# Mergeline 讀取快取、限流感知、加密磁碟快取與離線儲存庫計畫 v2（2026-10-23）

取代 v1 與 v2-addendum。依據：
- 第 1 輪計畫審查：`review-codex.md`（C1–C7、I1–I12）、`review-opus.md`（CR-1–CR-4、I-1–I-13）。
- 程式盤點：`survey.md`。

每一節標出它回應哪一項審查意見。

## 0. 擁有者決定（不重議）

1. **範圍**：記憶體快取、限流感知、加密磁碟快取。
2. **登出就清除**該帳號的磁碟快取。移除帳號與終局 401 也清除。
3. **超越 GitHub**：要做到離線瀏覽儲存庫。GitHub Mobile 沒有這個功能（社群討論 #7365 仍是未實作的請求）。
4. **分工**：沒有 UI/UX 的實作交給 Codex，UI/UX 由 Claude 做。
5. **全自動**：取捨時選保守的做法，並把理由寫進計畫。

### v2 的自動決定（依 §0.5）

- **D1「登出」的定義**（Opus I-1）：
  - app 沒有獨立的「登出」按鈕。凡是離開目前帳號的 session 都算登出，包括：
    - `select()` 切換帳號；
    - `endSession()`；
    - `remove()`。
  - 所以任何時候，只有正在使用的帳號有磁碟快取。
  - 理由：
    - 當機後的恢復可以用一條規則處理：啟動時保留「即將自動恢復的帳號」，其餘全部刪除；
    - 比「切換時保留」少一整套每帳號持久標記；
    - 多帳號使用者切換時會失去快取，是可接受的代價。
- **D2 離線冷啟動**（Opus I-9、Codex I8）：
  - C1、C2 只支援 session 期間斷線，以及「重開時先顯示上次的資料，同時重新驗證」。
  - 冷啟動時離線，要等 C3 的「離線唯讀模式」，並且另外審查（§6）。
- **D3 快取是「明確選用」**（Opus CR-2、Codex C4）：
  - `record`、`records`、`currentUser`、`textFile`（非 SHA）、所有 GraphQL 讀取維持**不快取**，也**不加入**快取讀取的進行中請求。
  - 只有畫面讀取路徑逐一改用 `cachedRecord`／`cachedRecords`。
  - 寫入 port、`_freshWrite`、`ai_write_reread`、編輯器的 `updated_at` 前置讀取、身分驗證完全不用改。
  - 漏改的後果只是「多一個請求」，不會發生 lost update。
- **D4 v1 不快取 GraphQL**（Opus CR-3 第 3 點、Codex C4）：GraphQL 讀取不進記憶體快取，也不落盤。這樣就沒有 graph key 失效的問題。
- **D5 待辦與 event 不落盤**（Opus CR-1 第 3、4 點）：只在記憶體保留 60 秒。

## 1. 事實（已查證）

- **GitLab.com 限流**（docs.gitlab.com/user/gitlab_com/rate_limits 與 administration/settings/user_and_ip_rate_limits，2026-10-23 讀取）：
  - 現行：登入使用者每分鐘 2,000 次。
  - 已公告、尚未生效：免費方案每分鐘 100 次、每小時 5,000 次。
  - 端點專屬限流：
    - `GET /groups` 每分鐘 50 次；
    - `GET /projects/:id` 每分鐘 400 次；
    - `GET /projects` 每 10 分鐘 2,000 次；
    - 搜尋每分鐘 100 次；
    - 留言建立每分鐘 60 次；
    - repository files 每個 IP 加檔案路徑每分鐘 500 次；
    - archive 每分鐘 5 次。
  - 標頭：
    - `RateLimit-Limit` 會被換算成每分鐘的值；
    - `RateLimit-Reset` 是伺服器的 Unix 秒；
    - 標頭只反映其中一個限制；
    - Projects、Groups、Users API 被限流時，429 回應不帶資訊標頭；
    - 建立類請求的 `Retry-After` 可長達 86,400 秒。
- **304 照樣計入限流**（實測）。v1 不做 ETag 重新驗證。這是取捨：304 仍然省頻寬與電量。
- **現有快取等於沒有作用**：GitLab 回 `max-age=0, private, must-revalidate`。現有快取的實際行為：
  - `_writesInFlight != 0` 時，對呼叫端直接丟 `cancelled`；
  - epoch 改變時重試一次；
  - 寫入的開頭與結尾都全清；
  - 401、403、404 時全清。

## 2. C1a：核心快取與限流（Codex；只動 `gitlab_api.dart` 與新檔）

為了避開 MR6b-2 波次 A 的封包 3（它擁有 `workspace_api.dart`），新增的讀取包裝寫在新的 part 檔 `lib/core/cached_read_api.dart`（`part of 'gitlab_api.dart'`），不改 `workspace_api.dart`。

### 2.1 快取 key（Codex I2、Opus M-1）

- **正規化 key**：
  - 帳號身分：scheme、host、port、subpath、數字 user id；
  - method（只有 GET；HEAD 永不快取）；
  - 已驗證的 endpoint path；
  - 依名稱排序的完整語意 query，包括 `per_page`、filter、`ref`、`path`。
- **分頁**：
  - 只快取有效的 `ApiPage(items, nextPageUri)`，`nextPageUri` 先經過 `_validateContinuation`；
  - 命中快取不得繞過驗證。
- **專案共用**：`projects/:id` 一律以 `license=true` 的超集合為底，`project()` 再從這份 JSON 投影出 `Project`。
- **別名**：`project(fullPath)` 解析後登記 path → id 的別名；依 id 失效時，別名一起清掉。
- **搜尋類**：帶 `search=` 參數的請求，以及 `/search` 端點（Opus M-4），只在記憶體保留 60 秒，永不落盤。

### 2.2 讀取類別與期限

| 類別 | 例子 | 新鮮期 | 記憶體最長保留 |
|---|---|---|---|
| projectMeta | `projects/:id?license=true` | 5 分 | 30 分 |
| ref | 分支、預設分支 | 60 秒 | 10 分 |
| pinned | 以完整 40 或 64 位十六進位 SHA 指定、且由 ref 解析確認過的 tree、檔案 | 不過期 | LRU 淘汰前一直保留 |
| list | 議題、MR、pipeline、星標、群組、專案列表（第一頁與後續頁） | 60 秒 | 10 分 |
| detail | 議題、MR、pipeline、job 單筆 | 30 秒 | 10 分 |
| thread | notes、discussions、award_emoji、approvals、related MRs、links | 30 秒 | 10 分 |
| volatile | 待辦、event、搜尋 | 60 秒 | 60 秒 |

pinned SHA 只接受恰好 40 或 64 位、而且確認過的值（Codex M1）。

### 2.3 範圍版本與失效（Opus CR-3、I-4、I-5；Codex C5、C6、C7）

- **範圍**：
  - `project:<id>`（path 別名先解析成 id）；
  - `projectLists`：`projects?…`、`groups?…`、`groups/**/projects`、星標；
  - `userLists`：待辦、我的工作、event；
  - `global`。
  - 每個範圍有一個單調遞增的版本號。
- **讀取**：開始時記下所屬範圍的版本，存入前比對，不同就**不存**。不論存不存，值都照常回給呼叫端（取代現在丟 `cancelled` 的做法）。
- **寫入**：在 `_send` 依 method 與 path 推出受影響範圍，寫入開始與結束時，都把這些範圍的版本加一，並刪掉這些範圍的快取與進行中合併項。

  | 寫入 | 受影響範圍 |
  |---|---|
  | `projects/:id/**` 的一般寫入 | `project:<id>` |
  | 建立、修改、刪除專案（`POST projects`、`PUT`／`DELETE projects/:id`）、fork、`star`／`unstar` | `project:<id>`（fork 時另加來源）＋ `projectLists` |
  | 待辦 | `userLists` |
  | 合併 MR、內文有以 `/` 開頭的行（quick action）的 note 或 discussion、所有 GraphQL mutation、無法判斷的寫入 | `global` |

  寫入失敗或結果不明，也照樣失效。專案轉移與群組層級的議題寫入在這個 codebase 沒有對應的 API，標為 N/A。
- **錯誤時清除整個子樹**：

  | 回應 | 清除範圍 |
  |---|---|
  | 專案層級資源回 403 或 404 | 整個 `project:<id>` |
  | 議題或 MR 回 403 或 404 | 該 iid 的子樹 |
  | 終局 401（PAT 收到 401，或 OAuth 換證失敗） | 整個帳號 |

  可恢復的 OAuth 401 只清記憶體，不清磁碟（Opus I-2）。404 的畫面依 AGENTS.md 的「模糊 404」規則。
- **強制網路讀取**（下拉刷新、`fresh`）：永遠不加入進行中的請求，結果寫回快取（write-through）。

### 2.4 記憶體

- **容量**：LRU 上限 256 筆。成本以「原始回應位元組 × 4」估算，上限 16 MiB（Opus M-3、Codex I12）。
- **不可變**：交出去的值一律 deep-freeze，避免某個畫面改到共用的值（Opus M-2）。
- **並發**：背景重抓最多 4 個同時進行。
- **帳號隔離**：快取由該帳號的 `GitLabApi` 擁有，`close()` 時丟棄。

### 2.5 限流（Opus I-7、I-8；Codex I4）

- **解析範圍**：只解析 `instance.allowsApi` 同源回應的標頭。CDN 那一跳的 429 不設定 API 的冷卻時間。
- **記錄方式**：
  - 依 `RateLimit-Name` 分 bucket 記錄 limit、remaining、reset；
  - 同一個時間窗內，較舊的亂序回應不能把 remaining 調高；
  - 缺標頭時狀態是 unknown，不是 normal；
  - 標頭名稱不分大小寫，數值要驗證格式與範圍。
- **reset 時刻**：
  - 優先用 `Retry-After` 的相對秒數；
  - 其次用回應的 `Date` 換算 `RateLimit-Reset`；
  - 再其次用 `RateLimit-ResetTime`；
  - 都沒有時，從 60 秒開始指數退避加 jitter，上限 15 分鐘。
  - 用 timer 在 reset 時自動恢復，恢復時把延後的工作分批送出，不同時爆發。
- **等級**：用絕對的 remaining，加上距離 reset 的時間判斷，不用 remaining／limit 的比例。
  - critical：remaining ≤ 3，且距離 reset 超過 10 秒；
  - low：remaining ≤ 15，且距離 reset 超過 20 秒；
  - 小 limit 的自架 instance 不會因此一開始就是 critical。
- **冷卻時鐘依端點類別分開**：`create`（專案、群組建立，上限 24 小時）、`groupList`、`global`（上限 15 分鐘）。
  - 現在四條 429 路徑合併成一個 `_noteRateLimit(response, origin)`。
  - 冷卻期間，網路讀取直接丟 `rateLimited`。畫面若有快取（記憶體或磁碟）就顯示舊值，加上限流橫幅（C1b）。
- **介面**：core 用不可變的 snapshot 與 stream（`lib/core` 維持 plain Dart），Flutter 的 `ChangeNotifier` adapter 放在 UI 層。
- **AI 預算**：
  - 由 `GitLabRateBudget` 統一分配給最多 3 個同時進行的 run，在建立 `AiToolBudget(maxGitLabRequests:)` 時注入。catalogue 本體不改。
  - critical 時不送出新的 AI 訊息。
  - 已在進行中的寫入，其前置讀取、readback 與重新讀取**豁免**這項限制（Opus I-8），避免寫入停在 `writeUncertain`。

### 2.6 請求計量（Opus I-8、Codex I5）

- `_send` 接受一個可選的 `RequestMeter`，每次真正送出 HTTP（含 OAuth 重放、分頁、HEAD 加 GET）時遞增。
- 加入進行中的請求記 0；失敗或取消但已送出的請求照算。
- AI 讀取 port 為每個邏輯操作建立一個 meter，`requestCount` 回報 meter 的值。
- catalogue 照舊先保留 2 倍，再依回報值退還。C1b 時同步修改 `tool_catalogue.dart`，讓「回報值 ≤ 保留值」的檢查用 HTTP 單位，不重複乘二，並補正常、命中、重試、半途失敗與並發的測試。

## 3. C1b：SWR、熱點修正、AI 共用與 UI（邏輯 Codex、UI Claude）

需要 C1a 先合併。和 MR6b-2 的波次 B 協調（封包 16 也會改 catalogue）。

### 3.1 SWR 的傳遞（Opus I-6、Codex I1）

- SWR **只在 `RecordController` 實作**：
  1. `refresh()` 先套用快取頁（標記 stale 與 fetchedAt）；
  2. 發出 `revalidating`；
  3. 背景重抓完成後，用 epoch 套用新值。
- **分頁**：
  - 第 1 頁是舊值時，`more()` 要等第 1 頁重抓完才能續抓，而且不使用舊頁的 `next`；
  - 已載入多頁時，重抓用既有的 `reconcileLoadedWindow()` 一致更新。
- **重抓失敗**：
  - 401、403、404：撤回舊值，顯示 `FailureNotice`；
  - network、429：保留舊值，顯示離線或限流狀態。
- **詳細頁**：先只做議題、MR、pipeline、專案總覽的 SWR。其他頁面用「新鮮期內命中，否則走網路」。
- **不在畫面上的分頁**（`TickerMode(false)`）不做背景重抓。
- `RecordsFeed` 的下拉刷新把 `fresh: true` 一路傳到 loader。

### 3.2 熱點修正（Codex I9、I10）

- **CI 總覽**：
  - 每一列有 unknown、loading、known、error 四種狀態，以有界佇列載入（先 8 列，之後再補）；
  - 篩選模式下，逐批補查狀態未知的專案，不把未知當成不符合；
  - 首屏先顯示已知的結果，其餘陸續補上。
- **專案總覽與檔案分頁**：共用同一把 canonical key 與進行中的請求，不靠傳 `initialRef` 共用。要另外處理：
  - 預設分支改變；
  - 快速切換分頁；
  - 使用者自己選的 ref 不被覆寫。
- **MR approvals**：同一把 key，只讀一次。
- **Threads 分頁**：走 thread 類別。
- **Job log 輪詢**：
  - 預算改變時重排 timer：normal 10 秒，low 30 秒；
  - critical 時，使用者正在看的 log 改成 60 秒一次，不在畫面上就暫停（Opus M-8）。

### 3.3 AI 共用（Codex I3、Opus I-8）

- `get_issue`、`get_merge_request`、MR versions 與頁面 context，用 `cachedRecord(maxAge: 60s, allowDisk: false)`。
- 從磁碟載入的值帶有 `lineage: disk`。就算之後已經進了記憶體，AI 也拒絕使用。
- 超過時限就走網路；網路失敗就回報「無法取得」，**不先送舊值**給模型。
- 頁面 context 在每次 send 前檢查時效，超過 60 秒就重抓。
- 遮罩、投影、機密標記照常在每次產生工具結果時套用。

### 3.4 請求數驗收（Codex I10、Opus §4）

- 每個目標都寫成測試，名稱裡寫明：
  - fixture（有沒有 README、starrers 幾頁、notes 幾則）；
  - 快取初始狀態；
  - viewport；
  - 時鐘；
  - 完成條件（等背景工作做完）。
- 依端點斷言請求數，不只比總數。
- **新鮮期內再開同一頁：0 次網路請求**（議題與 MR 的新鮮期是 30 秒）。
- **專案總覽**：不設 ≤ 4 的目標。要求兩件事：
  - 第二次開不會重複讀分支、tree、README；
  - 檔案分頁接在總覽之後，不會重複請求。
- **AI**：在「metadata 已暖、notes 單頁」的 fixture 下，從議題頁開對話，額外請求 ≤ 2；多頁 notes 另外測上限。

### 3.5 UI（Claude）

- **「最後更新：N 分鐘前」**：
  - 沿用 `minutesAgo`；
  - 放在 `leading`，跟著捲動；
  - 語意標籤包含資料的時間；
  - 時間只在資料真的刷新後才更新。
- **狀態區分**：離線、限流、權限錯誤與暫時失敗各自顯示，離線橫幅不能蓋掉 404 的 `FailureNotice`。
- **限流橫幅**：只有 reset 時刻已知時，才寫出「約 N 分鐘後恢復」。
- **版面測試**：320 dp、2×、de、ar、鍵盤升起；檢查換行、語意與可操作的重試。

## 4. C2：加密磁碟快取（核心 Codex、UI Claude）

需要 C1a 合併，並在 C1b 之後開分支。

### 4.1 落盤分類：只存白名單投影，判斷不確定就不存（Opus CR-1、Codex C1、C2）

- **每種可落盤的資料，都有一個寫在程式裡的欄位白名單投影**，只留 UI 需要的欄位。其他一律不存，包括：
  - token 類欄位、`runners_token`；
  - `import_url`，以及任何帶 userinfo 或敏感 query 的 URL；
  - 授權 header、簽名下載 URL；
  - request options。
- **專案**：id、name、path_with_namespace、description、visibility、default_branch、star_count、forks_count、open_issues_count、last_activity_at、license（name、key）、web_url、avatar_url、archived、namespace（id、name、full_path、kind）。
- **議題**：
  - 列表列與單筆，只有 `confidential == false`（明確的布林值）才存；
  - 讀到 `confidential: true` 時，同一批動作刪掉：
    - 該 iid 的單筆與整個子樹；
    - 該專案所有議題列表的磁碟項目。
- **議題的子資源**（notes、discussions、award_emoji、related MRs、links）：只有在**同一個 client 的記憶體裡，已有該 iid 新鮮且 `confidential == false` 的單筆**時才落盤，不確定就只放記憶體。
- **留言**：
  - 每則都要 `internal == false`；舊版 instance 沒有 `internal` 時，改看 `confidential == false`；
  - discussions 逐一檢查每一則 `notes[]`，只要有一則不合格，就整串不落盤。
- **MR**：列表、單筆、approvals 落盤；MR 的 notes／discussions 套用上面的留言規則。
- **pipeline 與 job 單筆**：只存中繼資料投影。
- **待辦、event、搜尋、GraphQL 一律不落盤。**
- **殘留風險**：公開的 MR 或議題內文、系統留言，可能引用機密議題的編號或片段。依 §0 這些照存，屬於已接受的殘留，要寫進 AGENTS.md 與 CLAUDE.md。
- **驗收**：解密後逐筆檢查，投影以外的欄位一律不存在；不能只用「搜尋 ciphertext 找不到明文」來驗收。

### 4.2 格式（Opus I-11、I-13、M-5；Codex I6）

- **目錄**：`getApplicationSupportDirectory()/read_cache/<sha256(account.key) 前 32 個十六進位字元>/`。
- **項目檔名**：`e_<HMAC-SHA256(命名子金鑰, canonicalKey) 前 32 個十六進位字元>.v1.bin`。命名子金鑰用 HKDF-SHA256 從快取金鑰導出，info 為 `"read-cache-names"`。
- **項目明文**：canonicalKey、類別、`fetchedAt`（網路取得的時間）、範圍版本與標籤、帳號、schema 版本、投影後的 body。讀取時驗證「解出來的 key 等於要找的 key」。
- **加密**：AES-256-GCM，每次新的 nonce。AAD 是 `jsonEncode(["read_cache", version, account, fileName])`。
- **索引** `index.v1.bin`（加密）：hash、大小、fetchedAt、最近使用時間、範圍標籤。
  - 可以從項目重建；
  - 先寫項目再寫索引；淘汰時先刪項目再改索引；
  - 索引寫入每 2 秒或每 N 筆批次一次，在同一個 isolate 裡完成。
- **讀取前檢查**：
  - 是一般檔案，拒絕 symlink；
  - ciphertext 大小在上限內；
  - 有界解密與解析。
- **清理**：
  - 超過 1 小時的 `.tmp` 刪除；
  - 無法解密或 schema 不明的項目直接刪除；
  - 每次查詢都檢查 7 天期限；未來時間戳視同過期；
  - 金鑰不可用時，用檔案的 mtime 做後備過期清理。
- **上限**：
  - 每筆明文 1 MiB；
  - 每帳號 32 MiB；
  - 每裝置 96 MiB；
  - 容量計入 ciphertext、索引與暫存檔。
- **背景 I/O**：`flushSync`、`renameSync` 在背景 isolate 執行。

### 4.3 金鑰（Opus I-10）

- **secure storage key**：`read_cache_key.v1.<base64url(account.key)>`，選項與 AI 的金鑰相同。
- **三態讀取**：
  - **found**：照常使用。
  - **unavailable**：完全跳過磁碟，不刪、不建。依 1、5、30 秒與下一次 resume 重試。
  - **absent**：
    - 有檔案時，先刪目錄，再建立新金鑰並讀回；
    - 沒有檔案時，直接建立新金鑰並讀回。
- **建立金鑰**：每個帳號只能有一個進行中（single-flight），由 coordinator 負責。

### 4.4 生命週期與柵欄（Opus CR-4、I-1；Codex C3）

- **協調器**：`ReadCacheDiskCoordinator.instance`。每個帳號有四種狀態：`ready`、`cleaning`、`disabled`、`unavailable`。
- **進入 `cleaning`（同步）**：
  - 拒絕新的寫入與建立金鑰；
  - 丟掉排隊中的去抖動寫入；
  - 等待進行中的 isolate 寫入結束；
  - 依序**先刪金鑰（crypto-shred），再刪目錄**。
- **柵欄的持續期間**：一直到外層的 session 邊界結束為止。
  - 每次回到主 isolate、每次寫入與 rename 之前，都重新驗證帳號、generation 與柵欄。
  - 刪除**不阻擋** `generation++` 與 UI 離開。做法是先同步進入柵欄，再在背景刪除。
- **觸發點**（D1）：
  - `_commitSignOut`，涵蓋 `select`、`endSession`、`remove`；
  - 終局 401；
  - 設定頁的「清除」，以及關閉「離線快取」；
  - `SessionController.remove` 的 commit 柵欄內再清一次，和 `clearAccountArtifacts` 相同。
- **移除帳號的順序**：`ai_account_removal` 的步驟中加 `clearReadCacheDisk`，放在 `clearRecentProject` 之後。
- **當機恢復**：啟動時在 `accountsLoaded` 之後，與 `main.dart` 的孤兒掃描串行執行：
  - 刪除「即將自動恢復的帳號」以外的所有 `read_cache/<hash>` 目錄與 `read_cache_key.v1.*` 金鑰；
  - 有登出標記（`gitlab_mobile_sign_out_pending_v1`）時，全部刪除。
  - 這條規則同時涵蓋孤兒清理與當機恢復。
- **AI 寫入日誌**：讀取快取的清除絕不碰 AI 寫入日誌與它的金鑰。

### 4.5 平台（Codex I7、Opus I-11）

- **Android**：備份與裝置轉移已排除（`bootstrap.py:200-206`）。
- **iOS**：
  - 不宣稱已排除備份；
  - 保護靠金鑰：`ThisDeviceOnly` 讓還原後無法解密，再由啟動掃描刪除；
  - `isExcludedFromBackup` 列為後續項目；
  - iOS 實機驗證是 NOT_RUN。
- **app 進入背景**：暫停磁碟寫入，排隊中的寫入直接丟棄（這只是快取）；回到前景後重新驗證 generation。

### 4.6 讀取規則（Opus CR-3 第 4 點）

- 只在記憶體沒有、而且帳號與 generation 都相符時才讀磁碟。磁碟值一律視為舊值，網路與額度允許時就立刻重抓。
- **剛被寫入失效的範圍，第一次讀取不用磁碟的舊值。**
- **磁碟只存第一頁。**

### 4.7 新增的磁碟內容（擁有者決定 3：超越 GitHub）

以下內容都以 SHA 或版本固定，屬於 pinned：
- 看過的檔案與 tree：以完整 SHA 固定，每筆上限 1 MiB；
- README；
- MR diff 的 version：version 不會變；
- 已結束 job 的 log：上限 2 MiB，超過時只留最後 2 MiB，並標示「前段已截掉」。

### 4.8 設定與文件（Opus M-6）

- **「離線快取」開關**：
  - 裝置層級，存在 `gitlab_mobile_read_cache_v1`，值為 `1` 或 `0`，預設開；
  - 關閉時走 §4.4 的柵欄刪除流程。
- **要更新的文件**：
  - `AGENTS.md:15` 的允許清單、殘留風險與移除順序；
  - `CLAUDE.md` 的 Persistence 段與 secure inventory。
- **Play 資料安全表**：不變。資料只存在裝置上，不算收集。

### 4.9 UI（Claude）

- **設定頁**：我的 › 儲存與快取，包含開關、大小、清除。
- **離線橫幅**。
- **磁碟舊值的「最後更新」**。

## 5. C3：離線保存儲存庫與離線唯讀模式（另外審查）

v2-addendum 的「離線保存」照舊，再加上兩點修正：
- 依 D1，切換帳號也會刪除離線保存的專案。設定頁與保存時的說明都要寫清楚。
- 冷啟動離線靠「離線唯讀模式」。做法如下：
  - 自動恢復時 `currentUser` 因網路錯誤失敗（不是 401），就以上次的帳號進入受限模式；
  - 只能瀏覽快取與離線保存的內容，不能寫入、不能用 AI、不需要新鮮讀取；
  - 恢復連線後重新驗證身分；驗證失敗（401 或帳號不符），就離開這個模式並清除快取。

  這會動到 AGENTS.md:9 的身分規則，所以 C3 開工前要另外寫計畫並送審。

## 6. MR 拆分與順序（Opus I-12、Codex I11）

1. **C1a**：
   - 改 `gitlab_api.dart`，新增 `cached_read_api.dart`、`rate_budget.dart`，加上測試；
   - 不碰 `workspace_api.dart`、寫入 port、協調器、AI。
2. **C1b**：
   - 改 `RecordController`、熱點頁面、`gitlab_read_port.dart`、`tool_catalogue.dart`、`ai_chat_context.dart`，加上 UI；
   - 等 MR6b-2 波次 A 合併後再 rebase，並重跑交界測試。
3. **C2**：磁碟快取。
4. **C3**：先送審，再實作。

每個 MR 都走：開 MR → 模擬器自測 → 審查（第一輪完整；之後只核對 Critical／Important。若新增 mutation、儲存或分類路徑，就重新檢查該差異的完整安全邊界）→ 合併 → 同步 GitHub 鏡像。

## 7. 最低驗收矩陣

採用 Codex 報告「修訂後最低驗收矩陣」的 12 列，以及 Opus §4 的四類測試，原文納入，不另外改寫。重點：

- **帳號與 generation**：A→B、A→B→A、同一帳號的新 session；網路、磁碟讀取、isolate、rename 在切換後才完成時，都不得發布或落盤。
- **寫入競態**：用 Completer 控制讀取在寫入的前、中、後完成；寫入成功、確定失敗、狀態未知都要測；無依賴的專案保留。
- **新鮮讀取**：
  - 下列讀取一定發出網路請求：
    - 六處 `updated_at` 前置讀取；
    - `currentUser()`；
    - AI 寫入 port；
    - `ai_write_reread`；
    - `_freshWrite`；
    - 其他人工寫入的前置讀取與 readback。
  - 它們不加入進行中的讀取，也不讀磁碟。
- **機密**（4.1 的每一條路徑）：
  - 父議題還沒讀就先讀 notes；
  - 巢狀的 discussion notes；
  - 議題從公開變成機密；
  - 解密後逐筆檢查欄位。
- **錯誤**：
  - 401、403、404 時撤回舊值並清除子樹；
  - OAuth 換證成功後，磁碟還在。
- **密碼學與金鑰**：
  - 錯的金鑰、帳號或檔名；
  - ciphertext 被竄改或截短；
  - 版本或 schema 不符；
  - 檔案過大；
  - 三種金鑰狀態，以及並行的第一次寫入只產生一把金鑰。
- **當機與清理**：
  - 在暫存檔、項目 rename、索引、淘汰、清除各階段注入終止；
  - 啟動掃描能恢復；
  - 清除後不會再長出檔案或新金鑰；
  - AI 寫入日誌完好。
- **限流**：
  - 大小寫；
  - 缺少或格式錯誤的標頭；
  - 多個 bucket；
  - 亂序回應；
  - reset 到期自動恢復；
  - 小 limit；
  - 時鐘偏差；
  - `Retry-After`、`Reset`、`ResetTime` 三者都缺；
  - 連續 429；
  - `Retry-After: 86400` 只封鎖建立類；
  - CDN 的 429 不影響 API；
  - 三個並行 AI run 的預算分配。
- **計量**：快取命中、合併的進行中請求、SWR、HEAD 加 GET、多頁、OAuth 重放、失敗與取消、UI 與多個 AI 並發。
- **時間**：用固定時鐘測 29、30、59、60 秒、保留期與 7 天的邊界。
- **平台**：
  - Android 實際檢查目錄清除（debug build 用 `run-as`）；
  - iOS 標為 NOT_RUN。

---

# v3 修訂（2026-10-23，回應第 2 輪審查：`review2-codex.md`、`review2-opus.md`）

本節的規則**優先於** v2 正文；兩者衝突時以本節為準。

## V1. 寫入進行中的讀取（Codex R2-C1）
- 每個範圍有兩個值：
  - **版本號**：寫入開始與結束時各加一；
  - **進行中寫入數**：寫入開始時加一，結束時減一。
- **`cachedRecord`／`cachedRecords` 遇到受影響範圍有寫入進行中**：
  - 先等那筆寫入結束，最多 30 秒，再發出網路請求；
  - 讀取完成時，若版本與開始時不同，或期間有新的寫入開始，就**自動重讀一次**；
  - 第二次仍不一致，就回傳 `superseded`，不存、不當作有效結果。呼叫端（controller 或詳細頁）丟棄它，排一次 fresh 重抓。
- **不相關範圍的讀取**：不受影響，照常完成。
- **`record`／`records` 等非快取讀取**：行為不變（D3）。
- **測試**：用 Completer 控制讀取在寫入前、中、後完成，以及「patch 之後才完成的舊 refresh」不會覆蓋新狀態。

## V2. 範圍與失效（Codex R2-C2；Opus I-1、C1a 決定 3、4、8）
- **範圍**：
  - `project:<id>`；
  - `projectLists`：`projects?…`、`groups?…`、`groups/:id`、`group-path:`、`groups/**/projects`、星標；
  - `userLists`：`issues?…`、`merge_requests?…`、待辦、event、`users/:id/events`；
  - `groupWorkItems`：`groups/:id/issues`、`groups/:id/merge_requests`；
  - `default`：分類表以外的所有讀取；
  - `global`。
- **寫入影響哪些範圍**：

  | 寫入 | 影響範圍 |
  |---|---|
  | `projects/:id/(issues\|merge_requests)/**` | `project:<id>`、`userLists`、`groupWorkItems`、`default` |
  | `projects/:id/**`（其他） | `project:<id>`、`default` |
  | 建立／改名／刪除專案、fork、星標 | `project:<id>`（fork 時另加來源）、`projectLists`、`default` |
  | 待辦 | `userLists`、`default` |
  | 合併 MR | `global` |
  | 任何寫入的 `body`、`description`、`note`、`title` 欄位含有以 `/` 開頭的行（quick action） | `global` |
  | 寫入 path 用的是還沒解析成 id 的 full path | `global` |
  | 所有 GraphQL mutation、無法判斷的寫入 | `global` |

- **`global` 的語意**：所有範圍的版本都加一，清掉全部記憶體項目與進行中的合併項。C2 起磁碟也一併清掉。
- **403／404**：
  - 只有 `GET projects/:id`（含 `?license=true`）的 403／404 會清掉整個 `project:<id>`；
  - 議題或 MR 的單筆會清掉該 iid 的子樹；
  - 其他子資源只清該 key 與它的路徑子樹（空專案的 `branches/main` 404、Guest 讀 pipelines 的 403 都屬此類）。
- **撤銷**：403／404、機密切換、終局 401 會撤銷相關的版本、進行中合併項、等待發布的結果與等待寫盤的工作。
- **既有的 `_cachedRead` 呼叫者**：
  - 簽章維持相容，因為 `groupByPath` 在封包 3 的檔案裡；
  - `group-path:` 歸 `projectLists`。
- **測試**：範圍表每一列一個測試，另加「議題寫入後，再開我的工作會重抓」。

## V3. 分頁（Opus I-2）
- **記憶體也只快取第 1 頁**（沒有 `page`、`page_token`、`cursor` 參數的請求）。後續頁一律走網路。
- `RecordController.more()` 在第 1 頁是舊值時，要等第 1 頁重抓完才續抓。
- **測試**：兩次抓取之間有新增的列時，不會漏列。

## V4. `cachedRecord` 的介面（Codex 交付條件 1、2；Opus C1a 決定 1、2）
```dart
final class CachedRead<T> {
  final T value;
  final DateTime fetchedAt;     // original network time; never refreshed by hydration
  final CacheLineage lineage;   // network | memory | disk (disk stays disk after hydration)
  final bool stale;             // older than the class freshness
  final bool superseded;        // V1: do not apply
}
Future<CachedRead<Json>> cachedRecord(List<String> path, {Map<String,String> query, bool fresh = false, Duration? maxAge, bool allowDisk = true, bool background = false});
Future<CachedRead<ApiPage<Json>>> cachedRecords(List<String> path, {Map<String,String> query, bool fresh = false, Duration? maxAge, bool allowDisk = true, bool background = false});
```
- **API 不在背景重抓**：它只回傳一個值，可能是快取值，也可能是網路值。`stale` 時由呼叫端再發一次 `fresh: true, background: true` 的讀取。背景讀取同時最多 4 個，排隊上限 32，超過就丟掉最舊的。
- **讀取類別**：由 C1a 內固定的路徑分類表決定。呼叫端的 `maxAge` 只能縮短期限，不能延長。分類表以外的路徑一律走網路，不快取。
- **帳號綁定**：`GitLabApi` 建構時由 `SessionController._client` 注入 `cacheAccountKey`（`account.key`）與 `cacheGeneration`。沒有注入時，快取一律關閉，所有讀取走網路。
- **詳細頁**：議題、MR、pipeline、總覽用同一個介面，自己管理 stale 時的 fresh 重抓與 epoch。

## V5. AI 永遠不用磁碟（Codex R2-I1；Opus I-3）
- C1a 在 `textFile`、`tree`，以及 AI port 會用到的其他 typed 讀取，加上 `allowDisk` 參數，預設 `true`。
- 值帶有 lineage。從磁碟補進記憶體的 pinned 值，lineage 仍是 `disk`。
- AI 讀取 port 與 `ai_chat_context` 的**每一個**讀取都傳 `allowDisk: false`，而且拒絕 lineage 為 `disk` 的值，改走網路。
- **測試**：pinned 檔案只存在磁碟時，AI 讀取會發出網路請求。

## V6. 限流的細節（Codex R2-I2、R2-I3；Opus C1a 決定 6）
- **可信來源**：`instance.allowsApi`（REST），以及 `instance.graphql` 的 GraphQL 端點，都視為可信，會解析標頭。CDN 與其他外部來源不解析，它們的 429 也不設定 API 的冷卻。
- **冷卻類別**：

  | 類別 | 範圍 | 上限 |
  |---|---|---|
  | `create` | `POST projects`、`projects/:id/fork`、`POST groups` | 24 小時 |
  | `groupList` | `GET /groups` | 15 分 |
  | `projectList` | `GET /projects` | 15 分 |
  | `search` | `/search`、帶 `search=` 參數 | 15 分 |
  | `archive` | `repository/archive*` | 15 分 |
  | `global` | 其他 REST 與 GraphQL | 15 分 |

  任何可信的 429 都會設定它所屬類別的冷卻；沒有 `RateLimit-Name` 的 429 照樣有效。
- **多個 bucket 合成一個等級**：取所有還沒到 reset 的 bucket 中最差的那個。
- **unknown**：
  - 不會清掉已經生效的 low、critical 或冷卻；
  - 沒有資訊時視為 normal，但不顯示 ETA；
  - 缺標頭的晚到回應，不會把生效中的 critical 覆蓋成 unknown。
- **新舊順序**：用送出序號判斷，不用 `Date` 標頭（只有秒級精度）。
- **等級函式**（L = limit、R = remaining、T = 距離 reset 的秒數）：
  - reserve = clamp(ceil(L × 0.05), 1, 3)；
  - critical：R < reserve，且 T > 10；
  - low：R < clamp(ceil(L × 0.15), 2, 15)，且 T > 20；
  - 其餘為 normal。
  - 剛 reset、還沒用過額度時（R = L）一定不是 critical。L = 1、2、3 的滿額與用掉一次後的邊界都要測。
- **AI 善後豁免**：只豁免 app 主動的節流，不能繞過伺服器 429 的冷卻。

## V7. 請求計量（Codex R2-I4；Opus C1a 決定 5）
- **傳遞方式**：`RequestMeter` 用 Zone 值。`_send`、`_rawFileBytes`、上傳與下載路徑，在每次真正送出 HTTP 前讀 `Zone.current[#gitlabRequestMeter]` 並遞增。
  - OAuth 重放照算；`/oauth/token` 換證請求不算，因為它不受 API 限流。
  - 加入進行中的請求不經過 `_send`，自然記 0。
- **擁有者**：catalogue 在呼叫 port 前建立 meter，用 `runZoned` 包住，在 `finally` 讀值。成功、失敗、取消都用 meter 的值扣帳，port 的 `requestCount` 只作參考。
- **單位**：HTTP 次數。這個改動歸 C1b-2，見 V9。

## V8. AI 預算分配（Codex R2-I5）
- C1a 只提供兩樣東西：
  - `GitLabRateBudget.snapshot()`；
  - `RunBudgetAllocator`：每個帳號一個，以 lease 的形式分配額度：acquire(max) → consume(n) → release()。
- **分配公式**：
  - 有效剩餘 = R − reserve − 已借出未歸還的總量；
  - 每個 run 拿到 min(40, floor(有效剩餘 ÷ 進行中的 run 數))；
  - remaining 不明時，每個 run 拿 40。
- lease 在 run 結束、停止、失敗或 dispose 時釋放，沒用完的額度歸還。
- AI 的實際接線歸 C1b-2。

## V9. MR 拆分（Opus I-4；Codex R2-I5）
- **C1a**：
  - 改 `gitlab_api.dart`；
  - 新增 `cached_read_api.dart`、`rate_budget.dart`、`request_meter.dart`；
  - 加上測試。
  - 不動 `workspace_api.dart`、寫入 port、協調器、AI 相關檔案，也不動 `test_ai_boundaries.py`。
- **C1b-1**：不碰 MR6b-2 擁有的檔案。C1a 合併後就能開始。
  - 程式：`record_controller.dart`、`records_feed.dart`、`ci_overview_page.dart`、`ci_page.dart` 的 log 輪詢、`project_overview.dart`；
  - 呼叫點：使用 `RecordsFeed` 的列表頁改用快取讀取；
  - UI：限流與「最後更新」。
- **C1b-2**：等 MR6b-2 波次 C（封包 17）合併後才做。
  - 範圍：`work_item_page.dart`、`discussions_tab.dart`、`repository_page.dart`、`gitlab_read_port.dart`、`tool_catalogue.dart`（計量與單位只在這裡改）、`test_ai_boundaries.py`（白名單加入 `cachedRecord`）、`ai_chat_controller.dart`（預算 lease 與 critical 擋送出）、`ai_chat_context.dart` 的 AI 部分。
  - 完成後重跑封包 18 的 `mr6b2_budget_test.dart` 與交界測試。
- v2 §2.5 寫「catalogue 本體不改」，以本節為準：catalogue 只在 C1b-2 改。

## V10. pinned 的判定（Opus C1a 決定 7）
- 「確認過的 SHA」是 client 內的一個集合，來源只有四種：
  - 分支與預設分支回應的 `commit.id`；
  - MR 的 `sha` 與 `diff_refs`；
  - commit 回應的 `id`；
  - tree 或檔案讀取時，以這些 SHA 為 ref 的請求。
- 只有恰好 40 或 64 位十六進位、而且在這個集合裡的 SHA，才算 pinned。
- `textFile`（`gitlab_api.dart:757`）與 `defaultBranchSha`（`:712`）的 `{40,64}` 改成 `^([0-9a-f]{40}|[0-9a-f]{64})$`。

## V11. 機密以議題物件為單位（Opus C-1）
- **任何端點、任何一層的議題物件**，都必須本身 `confidential == false`（明確的布林值）才能落盤。這包括 links 列、related MRs 內嵌的議題、列表列、單筆。
- 一份回應只要有一列不合格，**整份**只放記憶體，也不顯示「已移除幾列」，避免反推。
- **索引**為每筆項目記錄它包含的 `(project_id, iid)`。
  - 讀到某個議題 `confidential: true` 時，刪掉**所有範圍**內包含該議題的項目；
  - 索引不可用時，刪掉該帳號全部的議題相關項目。
- **§4.1 的「端點 → 投影」表**在 C2 開工前補完。表外的端點一律不落盤。
- **測試**：
  - 公開議題連到同專案與跨專案的機密議題時，不落盤；
  - 轉成機密後，「我的工作」與群組列表的磁碟項目被刪。

## V12. 磁碟失效與舊值（Opus I-6；Codex R2-C2，C2 gate）
- **寫入失效**：同步刪掉受影響範圍的磁碟項目，依索引的範圍標籤。索引不可用時，刪掉整個帳號的磁碟快取。
- **舊值可讀的條件**：取代 v2 §4.6 的「第一次讀取不用磁碟」。被失效的範圍，在取得合格的新網路結果之前，一律不讀它的磁碟舊值。這個狀態在記憶體裡以範圍版本記錄，重啟後由刪除保證。

## V13. 清除的持久標記與啟動順序（Codex R2-C3；Opus I-7，C2 gate）
- **D1 維持**。另外加上每個帳號的持久標記 `read_cache_clear_pending.v1.<base64url(account.key)>`，存在 secure storage。
- **清除的順序**：
  1. 寫入標記；
  2. 進入柵欄；
  3. 刪金鑰；
  4. 刪目錄；
  5. 確認兩者都已刪除後，移除標記。
- **刪除失敗**：維持柵欄，不建立新金鑰，也不回到 `ready`。下次 resume 或啟動時重試。
- **啟動順序**：
  1. `SessionController.initialize` 讀完帳號清單、登出標記與 `lastActive`，並決定要自動恢復哪個帳號；
  2. 依序處理所有 pending-clear 標記；
  3. 執行 D1 的掃描規則；
  4. 開放該帳號的磁碟快取（讀、寫、建金鑰）。

  在開放之前，所有磁碟路徑都視為關閉。
- **讀不到標記**時，同樣視為磁碟關閉。
- **協調器的狀態轉換**：
  - `closed` → `ready`：開放；
  - `ready` → `cleaning`：清除；
  - `cleaning` → `closed`：標記已移除；
  - `cleaning` 失敗時維持 `cleaning`；
  - 任何狀態 → `unavailable`：金鑰不可用。

## V14. 金鑰 unavailable 的唯一規則（Codex R2-I6）
- unavailable 時**暫停所有檔案變更**，包括過期清理，不讀、不寫、不刪。v2 §4.2 的「mtime 後備過期清理」**刪除**。
- 等金鑰恢復可用後，用解密驗證過的中繼資料做清理。
- 格式錯誤的金鑰視同 absent：先刪目錄，再建立新金鑰，與 absent 走同一條規則。

## V15. 請求數驗收（Codex R2-I7；Opus I-5）
- 「新鮮期內 0 次」只適用於明列的可快取 REST 路徑，依端點斷言。
- GraphQL 的請求（例如 `RestIssueGraphBridge` 的 `projectWorkItem`）另外記錄基線，不在零請求目標內。

## V16. 其他（兩份報告的 Minor）
- **每筆明文的上限**依類別：
  - JSON 1 MiB；
  - 檔案 1 MiB；
  - 已結束 job 的 log 2 MiB。
- **佇列上限**：
  - 前景同時進行的不同快取讀取：16；
  - 背景重抓：最多 4 個同時、排隊 32；
  - 等待寫盤的位元組：每帳號 2 MiB，超過就丟掉最舊的。
- **HTTP 指令**：app 自訂的快取政策不看伺服器的 `max-age`。伺服器回 `no-store` 時一律不快取。
- **`Accept` 不同**的回應形狀用不同的 key。
- **iOS**：檔案保護採預設的 `CompleteUntilFirstUserAuthentication`，app lock 期間照常解密（app lock 只遮畫面），寫進文件。實機驗證是 NOT_RUN。
- **D2 的「重開時先顯示上次的資料」**：重開時先完成 `currentUser` 網路驗證，通過後列表才先顯示磁碟的值，同時重抓。冷啟動離線沿用 D2，延到 C3。
- **§7 驗收矩陣**：「原始碼、diff、log 不落盤」的條目，改成「AI 永遠不讀這些資料的磁碟副本」，並新增 V5 的測試。
- **§5（C3）**：開工前另寫一份完整的獨立計畫，不再引用 addendum 的「照舊」。

---

# v3.1 補充（2026-10-23，回應第 3 輪 `review3-opus.md` 的 N-1、N-2，以及 C1a 會用到的 Minor）

## V17. pinned 不參與寫入失效（N-1，採用審查原文）
- **不參與失效**：pinned 項目（以確認過的 SHA 或 version 固定的檔案、tree、README、MR diff version、已結束 job 的 log）：
  - 不登記範圍版本；
  - 不受 V1 的等待影響；
  - 不被 `global` 或範圍失效清除。

  記憶體與磁碟都適用。
- **仍會被清除的情況**：
  - 401、403、404；
  - 帳號清除；
  - LRU、7 天期限、容量上限。
- **理由**：內容以 SHA 固定，寫入改不了它；權限的變化交給 403／404 處理。
- **測試**：
  - GraphQL mutation 與同專案留言之後，pinned 的記憶體與磁碟項目都還在；
  - 403 之後就被清除。

## V18. 快取在驗證後綁定（N-2，採用審查原文）
- **綁定方式**：
  - `GitLabApi` 提供一次性的 `bindReadCache(accountKey, generation)`；
  - `SessionController._activate` 在 `generation++` **之後**呼叫它，key 用驗證過的 `Account.key`。
- **綁定前**：快取關閉。
- **重複綁定或 key 不符**：關閉快取並丟棄內容。
- **測試替身**：`ApiFactory` 與測試用的 fake 也要能綁定；或者由 `_activate` 對任何 client 呼叫。
- **檔案分派**：`session_controller.dart` 的這幾行分給 C1a（V9 的 C1a 清單加入此檔），這個檔不屬於 MR6b-2 的任何封包。
- **測試**：PAT 新登入、OAuth 新登入、`select`、自動恢復四條路徑，啟用後快取都已綁定，而且 generation 等於 `session.generation`。

## V19. C1a 要一併採用的 Minor（m-1–m-16）
- **m-1：寫入進行中等滿 30 秒**時，照常送出請求。結果只回給呼叫端，標為 `stale`、不存。完成時若寫入仍在進行，視同「期間有寫入」。
- **m-1：`superseded` 之後的 fresh 重抓**最多 2 次，之後等寫入靜止（1 秒內沒有新的寫入開始）才再抓。
- **m-2：`maxAge` 是硬上限**，超過就走網路。`stale` 只對應類別的新鮮期。
- **m-3：背景佇列丟掉的請求**回傳 `dropped`。controller 收到後結束 `revalidating`，保留目前的值，`more()` 不再等待。
- **m-4：`allowDisk: false`** 由快取層直接略過 lineage 為 disk 的項目，包括已經補進記憶體的，typed 方法的回傳型別不變。
- **m-5：`mayStartRequest`** 只看 `global` 與該寫入所屬類別的冷卻，不看 `create`，除非這筆寫入本身就是建立類。
- **m-5：實際的介面名稱**是 `instance.graphQL` 與 `allowsGraphQL()`。
- **m-6：判斷是否為續頁**，直接引用 `pagination.dart` 的 `paginationKeys` 常數（`page`、`id_after`、`page_token`、`pagination`、`cursor`）。續頁一律走 `records(next:)`，不快取。
- **m-8：SHA 先轉小寫再比對**。確認過的 SHA 集合上限 4,096 個，以 LRU 淘汰。
- **m-9：議題的 403／404** 也套用 V11 的索引刪除，到 C2 才生效。
- **m-12：L = 1、R = 1 時**判為 low，寫進測試的預期值。
- **m-13：排隊的讀取**在呼叫端的 zone 裡送出：先 `await` 取得名額，再呼叫 `_send`。
- **m-14：「已借出未歸還」**指的是 lease 尚未消耗的部分。伺服器額度下降時，既有的 lease 不收回。
- **m-15：用 full path 讀取、別名還沒解析**的請求，開始時改用 `default` 的版本做快照。
- **m-16：前景第 17 個不同的讀取**排隊等名額，不直接拒絕。

## V20. C2 要採用的 Minor（m-7、m-10、m-11）
- **m-7（C1b-1 要改的頁面）**：
  - 要改：activity、ci_page、file_history、groups、inbox、my_work、project_extras、projects、search。
  - 留到 C1b-2：`boards_page`、`project_more_page`、`snippets_page`、`registries_page`。
- **m-10（V13 的清除流程）**：
  - **順序**：先同步進入柵欄，再寫標記。
  - **標記寫入失敗**：照樣刪除，並在記憶體保留 pending、維持 `closed`。
  - **金鑰刪除失敗**：目錄照樣刪。
  - **非啟動時**：`closed → ready` 只在 `_activate` 綁定時發生。設定頁按「清除」後，同一個 session 在刪除完成時重新開放。
  - **`remove()` 留下的標記**：由啟動掃描清除，因為掃描涵蓋清單外的帳號。
- **m-11（V14 的例外）**：
  - 金鑰 unavailable 時，清除路徑仍可以刪目錄，因為刪除只會減少資料。
  - absent 而且有檔案時，也走 V13 的標記流程。

## V21. Full-path sub-resource reads are not cached (C1a review round 3, N-2; lead decision 2026-10-23)
- **Only project detail goes through the alias.** `projects/<full path>` (project detail) is the only full-path read that is cached and resolved through an alias. Its key is re-decided from the response `id`, and a path mismatch drops the alias.
- **Full-path sub-resources go to the network.** `classify` returns `null` for `projects/<non-numeric>/…`, so these reads always hit the network.
- **Reasons:**
  - AGENTS.md addresses projects by numeric id after resolution;
  - C1b screens already hold the numeric id;
  - each alias-keyed sub-resource design so far introduced a revocation gap (N-1, N-2).
- m-15 is narrowed to project detail.
