# Mergeline C3：離線保存儲存庫與離線唯讀模式　計畫 v2（2026-10-23）

- **性質**：獨立、完整的計畫，取代 `c3-plan-v1.md`、`cache-plan-v3.md` §5，以及 `plan-v2-addendum.md` 的 §2.8。
- **回應**：第 1 輪審查 `c3-review1-codex.md`、`c3-review1-opus.md`，兩份都是 REQUEST CHANGES。
- **依據**：
  - `cache-plan-v3.md`：D1–D5、§4、V10、V13、V14、V16、V17、V18、V20；
  - `survey.md`；
  - 先前的審查紀錄（R2-C3、I-6、I-7、N-1、N-2、m-10、m-11）。
- **程式版本**：
  - 一般程式：`gitlab/main` @ `e35db41`；
  - C1a 的 API：`feat/cache-c1a` @ `f7d6106`（MR !103），以 `C1a:` 前綴標示行號。
- **證據**：
  - 本計畫沒有執行任何測試、建置、模擬器或實機，一律 **NOT_RUN**。
  - §1 的外部事實來自 2026-10-23 讀取的官方文件，以及對 gitlab.com 公開專案 `gitlab-org/cli` 的匿名唯讀請求（tree、archive 開頭、blob raw 的標頭）。
- **全自動**：擁有者指示不要詢問。§0.2 的主導者決定是最終的；其餘的取捨都附上理由。

> **v2.1（第 2 輪的修正）**：第 2 輪審查 `c3-review2-opus.md` 的判定是 APPROVE WITH MINOR FIXES。本版只套用它第 4 節的 R1–R5，沒有改動其他內容，採納後不需要再審：
> - **R1**（§5.4）：AGENTS.md:9 的替換文字改成和 §5.2 的分類一致：
>   - 認證頁的情況限定為「成功但不是 GitLab JSON 的回應」；
>   - 不是 GitLab JSON 的 401／403 不算判定，不刪資料，也不進入離線模式；
>   - 刪除只限 GitLab 的 401 或 user id 不符；
>   - 網路請求與本機寫入，補上 OAuth 換證一次與保存換到的新憑證。
> - **R2**（§3.14、§5.2）：分類器要在 C1a 丟掉錯誤 body 之前，有界地讀最多 4 KiB；401 沿用 C1a 的終局條件；`identityCheck()` 自己讀 body。
> - **R3**（§3.9、§8.1）：granted 為 0 的 lease 立刻 release 再等待。
> - **R4**（§3.9、§8.1）：「unknown」改成 `limitingBucket == null`。
> - **R5**（§1.1、E1、E13、E18、§3.3、§3.17、§9 Q19）：寫入私有專案的 Q19 實測；撤回修改 V16 的預先決定；E18 保留為執行時的守衛，並附 UI 文字。
> - 第 2 輪第 6 節的 Minor 列在文末的 §11 Follow-up。

---

## A. 審查意見對照

### A.1 Critical 與 Important

| 編號 | 解決的章節 | 怎麼解決 |
|---|---|---|
| Codex C1 | §5.2、§5.4、§5.5、§5.6 | `/user` 回 403 時，持久寫入拒絕標記 `offline_refused.v1.*`，寫入失敗就依 V13 清除；401 與 user id 不符時，同步柵欄後清除。驗證作業的 ticket 與生命週期寫明；AGENTS.md:9 的文字依實際流程重寫 |
| Codex C2 | §3.14、§4.4 | 權限失效由協調器處理，不依賴 UI：事件帶完整 account、generation、數字專案 id 與端點分類，同步提高專案 epoch，等 worker 停止後才刪除。清除順序改回 m-10 的「先柵欄、後標記」 |
| Codex C3 | §4.4、§4.6 | GC 的根包含 saving／paused／failed 快照 tree 裡所有可能的 blob；GC 只在帳號沒有 worker 時、持有維護鎖時執行。取消與刪除一律先讓 job 失效、等 worker 回應，之後才改索引 |
| Codex C4 | §5.8、§6.6 | 新增 `NetworkBoundary`：offline 時阻擋外連、分享與附件下載，外部媒體走一個會直接失敗的 transport。快照媒體的來源政策要求完整身分相符；`markdown_view.dart` 列入所有權。AI 的 `offline` 旗標不動 |
| Codex C5 | §0.2 L1、§4.1、§4.9 B3 | 「清除快取」照原契約 crypto-shred，連離線專案一起刪，確認框寫出數量與大小。C3 改用自己的根金鑰 |
| Codex C6 | §3.8、§4.3 | tree 與 index 有寫入端與讀取端共用的位元組預算，並預留最終欄位的空間。在下載 archive 之前就檢查；提交前用正式讀取器讀回一次 |
| Codex I1 | §3.4 | 不再宣稱「自動降級」。續頁只取 `page_token`，由 client 自己重建 URL（實測 Link 帶有 `id=`，會被 `_validateContinuation` 拒絕）。offset 只在伺服器回應明確給出時使用。每筆 tree 項目都完整驗證 |
| Codex I2 | §3.6、§3.7 | 完整的 tar 解析契約：pax／GNU 狀態只套用到下一筆、pax `size` 決定 framing、結尾、截斷、gzip trailer。pax comment 只在是 40／64 位 hex 時才驗證。UI 不推斷 `export-*` 是原因 |
| Codex I3 | §3.5 | 通訊契約：socket 留在 main isolate、以 `StreamIterator` 拉取、64 KiB 的 `TransferableTypedData`、credit 視窗、各層的記憶體上限、stop／ack／kill、自己實作 idle watchdog |
| Codex I4 | §3.7、§3.12 | 每次保存都依新的 tree 與目前的政策重新分類，不沿用舊分類。既有的 blob 解密並驗證 id 後才沿用，損壞的就原子替換 |
| Codex I5 | §3.8、§3.10、§4.6、§4.7 | 容量依峰值計算；更新屬於替換，滿 30 個也允許。持久狀態加上 `failed`，24 小時清理涵蓋它。未知 schema 或金鑰 unavailable 時，明確的清除仍然會刪。`offlineReadOnly` 只允許受柵欄保護的明確刪除。沿用安全目錄鏈 |
| Codex I6 | §5.9、§5.10、§6.3 | `OfflineApp` 接到既有的 lock controller，設定未載入或讀取失敗時不顯示內容。威脅表照實寫出新增的曝露。第一次保存時有知情說明。30 天在前景也會重新檢查 |
| Codex I7 | §4.9 | C2 的契約修正重寫成 B1–B12，涵蓋安全事件、GC 根、清除優先於未知 schema、命名空間互斥。no-store 照 V16：會落盤的回應若帶 `no-store` 就中止 |
| Codex I8 | §7 | `markdown_view.dart`、`external_link.dart`、`resource_share.dart`、`app_lock.dart`、`login_screen.dart` 列入所有權。前置條件改成 MR6b-2 最終合併的 commit。`ResumeTarget` 只承諾回到專案根目錄。離開確認併入既有的 `_leave` |
| Codex I9 | §8 | 補 C1–C6 的競態、真實 widget 的零外連、長 tree 讀回、損壞 blob 修復、拒絕封鎖、鎖定設定失敗等測試，以及 AI 的行為測試。模擬器驗收重寫，不可行的步驟標 NOT_RUN 並寫明原因 |
| Opus C-1 | §5.2 | 同 Codex C1：403 持久封鎖離線模式，直到同一個 user id 的 `/user` 回 200 |
| Opus C-2 | §5.4 | AGENTS.md:9 的替換文字逐句對照實際流程：提早進入、`/user` 探查、本機刪除、30 天只是衛生措施、先柵欄、App 鎖定 |
| Opus C-3 | §4.9 B8–B12、§5.5 | 前置清單統一為 B1–B12。重試同一帳號不走登出序列；任何 `_activate(target)` 都清除其他帳號；新增命名空間柵欄；`closed` 狀態允許唯讀的資格檢查 |
| Opus I-1 | §3.6 | 路徑正規化接受真實的 archive：前綴根目錄略過、目錄去掉一個結尾 `/`、submodule 對應到 `commit`。fixture 用真正的 `git archive` 產生 |
| Opus I-2 | §3.7 | 嘗試可逆的正規化（CRLF→LF、`$Id$` 還原），再用 blob id 驗證。`.gitattributes` 有相關設定時提示。不做 raw 補抓，理由是 raw 回應帶 `no-store` |
| Opus I-3 | §5.5 | 提早進入時沿用 `initialize` 的 ticket，清掉 `initializing`／`resuming`，`main.dart` 先判斷 `offline`。200、401、403 的背景結果各自定義 |
| Opus I-4 | §5.1、§5.2 | `redirectBlocked`／`invalidResponse`（Wi-Fi 認證頁）可以進入離線模式，橫幅有對應的文字。其他未知的失敗不行（L4） |
| Opus I-5 | §4.1 | C3 使用自己的根金鑰。帳號層級的清除與「清除快取」shred 兩把金鑰；「全部刪除離線專案」只 shred C3 的 |
| Opus I-6 | §3.2 | 不改 V10。tag 先解析出 commit，再經由 C1a 既有的 `commits/:sha` 確認路徑 |
| Opus I-7 | §3.5、§4.4 | ack 回壓、讓出控制權、5 秒後以 `Isolate.kill` 備援、worker 只拿到 HKDF 子金鑰；Dio 的 `receiveTimeout` 改由自己的 watchdog 處理 |
| Opus I-8 | §4.8 | `offline_repo/`（以及建議的 `read_cache/`）設定 `isExcludedFromBackup`，由 `tool/bootstrap.py` 產生的 iOS runner 實作 |
| Opus I-9 | §8.5 | 單一身分做得到的 D1 路徑（`endSession`、移除帳號）保留；`select(B)` 標 NOT_RUN。加上沒有明文的檢查與量測。`export-*` 只在先確認到含這些屬性的公開專案時才跑 |

### A.2 Minor
- **已併入**：
  - Codex：m1（envelope 是 29 位元組）、m2（SHA-256 向量的產生方式）、m3（清單編號）、m4（進度語意與完成的定義）。
  - Opus：1、2、4、5、6、7、8、9、11、12、13、14、15（實測 Link）、16、17、18、19、20（HKDF 參數，C3 部分）、21、22。
- **延後或不採用**：
  - Opus 3（`ResumeTarget` 回到原本的資料夾）：v1 只回到專案的檔案分頁根目錄，資料夾恢復另開 issue。
  - Opus 10（加密效能）：寫法要求併入 §4.1；吞吐量的量測放在 §8.5，數值等實作後才知道。
  - Opus 20 的 C2 部分（C2 的資料金鑰改用 HKDF 導出）：轉給 C2 當建議（B12），不是 C3 的前置條件。
  - Codex C5 建議的「只清除暫存項目」選項：v1 不提供（L1 只要求一種清除）。

---

## 0. 決定

### 0.1 擁有者決定（不重議）
1. **範圍**：記憶體快取、限流感知、加密磁碟快取、離線瀏覽儲存庫（超越 GitHub Mobile；社群討論 #7365 仍是未實作的請求）。
2. **登出就清除**：
   - D1：凡是離開 session 都算登出，包括 `select`、`endSession`、`remove`。終局 401 也清除。
   - 只有正在使用的帳號有磁碟資料，離線專案也一樣。
3. **D2**：冷啟動時離線，等 C3。
4. **分工**：沒有 UI 的實作交給 Codex，UI/UX 由 Claude 做。
5. **全自動**：不詢問，選保守的做法並寫下理由。

### 0.2 主導者決定（L1–L8，最終）
| 編號 | 決定 | 落在哪裡 |
|---|---|---|
| L1 | 設定頁的「清除快取」照擁有者與 v3 的 crypto-shred 契約，**連離線專案一起刪除**，確認框寫出專案數與空間。離開 session 照樣全部刪除 | §4.1、§4.9 B3、§6.9 |
| L2 | `/user` 回 401、403，或 user id 不符：在之後某次線上驗證成功之前，永久不得進入離線模式，而且跨重啟仍然有效 | §5.2 |
| L3 | 離線模式要有明確的網路邊界，涵蓋 Markdown 的圖片與連結 | §5.8 |
| L4 | Wi-Fi 認證頁的情況（`redirectBlocked`／`invalidResponse`）可以進入離線模式；其他未知的失敗不行 | §5.1 |
| L5 | 不把 tag 的 `commit.id` 加進 V10 的確認集合；ref 經由既有的確認路徑解析 | §3.2 |
| L6 | 保留 archive 的前提，是五項規格都寫完整：tar 解析、轉換與 `export-*`、tree 驗證、isolate 回壓與柵欄、GC。否則改用 tree 加 raw | §3.3–§3.7、§4.6 |
| L7 | iOS 要把目錄排除在備份之外 | §4.8 |
| L8 | 模擬器驗收只保留做得到、而且能證明事情的步驟，其餘標 NOT_RUN 並寫明原因 | §8.5 |

### 0.3 C3 的自動決定
| 編號 | 決定 | 理由摘要 |
|---|---|---|
| E1 | **維持 archive**：tree 列表當清單，加上一次 `archive.tar.gz`。L6 要求的五項規格都在本文件寫完整 | 請求數比 tree 加 raw 少兩個數量級（§3.3）。另外 raw 的回應帶 `no-store`（實測），依 V16 不得落盤；登入讀取私有專案時，archive 的回應是 `max-age=60, private, must-revalidate, …`，tree 是 `max-age=0, private, must-revalidate`，兩者都沒有 `no-store`（§1.1，R5） |
| E2 | 每個存入的檔案都用 tree 的 blob id 驗證；不符時先試可逆的正規化 | 驗證保證正確；正規化救回 eol／ident 這類常見的轉換 |
| E3 | 自寫串流 tar 解析，用 `dart:io` 的 gzip，在 isolate 內執行，不新增相依 | 明文不寫暫存檔，lockfile 不變；規格與測試在 §3.6、§8.1 |
| E4 | C3 使用自己的根金鑰 `offline_repo_key.v1.*` 與目錄 `offline_repo/<hash>/`，和 C2 分開 | 兩個生命週期各自可以 crypto-shred；帳號層級的清除兩把都 shred |
| E5 | 「清除快取」等於帳號層級的完整清除（L1） | 擁有者與 v3 的契約 |
| E6 | 只存文字檔（≤ 2 MiB、≤ 20,000 行）與圖片（≤ 10 MiB） | 和線上的文字預覽、Markdown 圖片上限一致（Opus m8） |
| E7 | 權限失效由協調器的專案柵欄處理，不依賴 UI | Codex C2 |
| E8 | 離線模式的進入、拒絕標記、30 天上限、鎖定的前提 | L2、L4 |
| E9 | 離線模式沒有 `GitLabApi`。另建 `OfflineApp`（自己的 `MaterialApp`，以 generation 為 key），並包一層 `NetworkBoundary` | L3；離開時不會殘留頁面 |
| E10 | 背景探查成功只改橫幅；401、user id 不符立即處理；403 寫入拒絕標記 | 不打斷閱讀；安全相關的結果不等使用者 |
| E11 | 新增 `RepositoryReader`：介面放在 `lib/core/repository_reader.dart`，快照實作放在 `lib/core/offline/`。reader 攜帶完整的擁有者身分 | Opus m6、Codex I8 |
| E12 | 離線模式只開放已保存的專案；C2 的快取列表留到 C3d | 每個列表畫面都假設有活的 `GitLabApi` |
| E13 | **更新一律重新下載 archive**。不做 raw 補抓，也不做 raw 增量更新 | raw 帶 `no-store`：匿名讀公開專案的 `blobs/:sha/raw`，以及登入讀私有專案的 `files/<path>/raw` 都有（§1.1）；只有一條取得路徑，驗證範圍小 |
| E14 | 每個帳號同時只有一個保存工作；兩次 archive 開始至少隔 15 秒；請求額度從 C1a 的 `RunBudgetAllocator` 取得 lease | 和 AI 共用帳號的額度 |
| E15 | 只能保存分支與 tag；tag 經由 `commits/:sha` 確認 | L5 |
| E16 | 不做背景下載服務 | 沒有對應的 plugin |
| E17 | iOS 排除備份 | L7 |
| E18 | 會落盤的回應（tree、archive）若帶 `no-store`，就中止保存。這是**執行時的守衛**：gitlab.com 實測沒有（§1.1），但自架 instance 的標頭可能不同 | V16，Codex I7 |
| E19 | 帳號第一次保存時，跳出知情說明對話框 | Codex I6 |

---

## 1. 事實（2026-10-23 查證）

### 1.1 GitLab
- **archive**：`GET /projects/:id/repository/archive[.format]`（docs.gitlab.com/api/repositories）。
  - 參數：`sha`、`path`、`include_lfs_blobs`、`exclude_paths`、`ref_type`。
  - GitLab.com 限流每分鐘 5 次；文件只對 GitLab.com 這樣寫，不外推到自架。
  - 實測（`gitlab-org/cli`，以 40 位 SHA 指定）：
    - `200`、`application/octet-stream`；沒有 `Content-Length`；沒有轉址；
    - `cache-control: max-age=3600, public, must-revalidate, …`；帶有 `RateLimit-*`；
    - 第一個項目是 pax global（`g`），內容 `comment=<SHA>`；
    - 頂層目錄 `<name>-<sha>-<sha>/`；長路徑用 ustar 的 `prefix` 欄位；
    - 帶 `path=docs` 時，頂層是 `…-docs/`，項目依序是 `…-docs/`、`…-docs/docs/`，再下面是完整的儲存庫路徑。
- **tree**：`GET /projects/:id/repository/tree`。
  - 參數：`recursive`、`pagination=keyset`、`page_token`、`per_page`、`ref`、`path`。
  - 每筆只有 `id`、`name`、`type`、`path`、`mode`，沒有 size。
  - 17.7 起，路徑不存在時回 404。
  - 實測：
    - `cache-control: max-age=0, private, must-revalidate`（沒有 `no-store`）；
    - keyset 的 `Link` 是 `…/repository/tree?id=34675721&page=1&page_token=…&pagination=keyset&per_page=100&recursive=true&ref=<sha>&with_last_commit=false`。它多了 `id`、`page`、`with_last_commit`，現有的 `_validateContinuation`（`gitlab_api.dart:732-749`）會因為「新增非分頁參數」而丟 `unsupported`。
    - `gitlab-org/cli` 的 recursive tree 有 2,227 項。這是觀測值，不是驗收條件。
- **blob raw**：`GET /projects/:id/repository/blobs/:sha/raw`。
  - 實測 200 回應：`cache-control: max-age=0, private, must-revalidate, no-store, no-cache`。
  - 超過 10 MB 的 blob 限每分鐘 5 次。
- **GitLab.com 限流**（docs.gitlab.com/user/gitlab_com/rate_limits）：
  - 現行：API 每分鐘 2,000 次；raw 端點每個專案、commit 或路徑每分鐘 300 次；files API 每個 IP 加路徑每分鐘 500 次。
  - 提議中、尚未生效：Free 每小時 5,000 次，每分鐘 burst 100 次。
- **未證實**：
  - GitLab 與 Gitaly 產生的 archive，是否與 `git archive` 一樣套用 `convert_to_working_tree`（eol、`ident`、`working-tree-encoding`、`filter`）以及 `export-ignore`／`export-subst`。文件沒寫。
  - 設計不依賴這一點（E2）。實測的觀察不推斷原因（§8.5）。
- **已查證：私有專案在登入狀態下的 `cache-control`**（gitlab.com、單一私有專案、2026-10-23，由主導者量測；v2.1，R5）：

  | 端點 | `cache-control` | 有沒有 `no-store` |
  |---|---|---|
  | `repository/tree` | `max-age=0, private, must-revalidate` | 沒有 |
  | `repository/archive.tar.gz` | `max-age=60, private, must-revalidate, stale-while-revalidate=60, stale-if-error=300, s-maxage=60` | 沒有 |
  | `repository/files/<path>/raw` | `max-age=0, private, must-revalidate, no-store, no-cache` | **有** |

  - 結論：在 gitlab.com 上，E18 不會讓私有專案的保存失敗，E1 的前提成立。自架 instance 未查證，E18 仍然是執行時的守衛。

### 1.2 程式
- **C1a**（`f7d6106`）：
  - `CachedRead<T>`：C1a: `cached_read_api.dart:6-40`；
  - `bindReadCache`：C1a: `cached_read_api.dart:60-61`，在 `_activate` 中呼叫（C1a: `session_controller.dart:501`）；
  - 確認過的 SHA 集合 `_ReadCache.confirmed`：C1a: `cached_read_api.dart:233`；`isConfirmed`、`confirm`：C1a: `:359-377`。
    - 只有 `cachedRecord` 的讀取會經過 `observe`（C1a: `:379-397`）並確認，來源是 `branches/*` 的 `commit.id`、`commits/:sha` 的 `id`、MR 的 `sha` 與 `diff_refs`。
    - tag 被刻意排除：`cache_limits_test` 有 "tag exclusion"。
  - `GitLabApi.rateBudget`：C1a: `gitlab_api.dart:190`。相關方法：
    - `mayStart`：C1a: `rate_budget.dart:142`；
    - `retryAtFor`：C1a: `:131`；
    - `snapshot().level`：C1a: `:101`；
    - `RateRequestClass.archive`：C1a: `:10`；archive 路徑在 C1a: `gitlab_api.dart:243` 歸入這一類。
  - `RunBudgetAllocator.acquire(max)`：同時最多 3 個 lease，每個最多 40（C1a: `rate_budget.dart:359-397`）；`RunBudgetLease.consume`／`release`：C1a: `:400-425`。
  - `RequestMeter`：Zone 值，每次真正送出都遞增（C1a: `request_meter.dart`；`gitlab_api.dart:325-326`）。
  - `_cacheTtl` 遇到 `no-store` 就不存：C1a: `gitlab_api.dart:231-235`。
  - 逾時設定：connect 15 秒、receive 25 秒（C1a: `gitlab_api.dart:178-179`；`e35db41` 是 `:171-172`）。
- **`e35db41`**：
  - **文字上限**：`maxTextBytes` 2 MiB、`maxTextLines` 20,000（`gitlab_api.dart:193-194`）。README 超過 256 KiB 不渲染（`repository_page.dart:233`）。
  - **Markdown 的儲存庫圖片**：上限 10 MiB（`markdown_media_source.dart:51`），經 `api.rawFileBytes` 讀取（`:486-503`）；外部媒體走獨立的 Dio（`:434-454`）。
  - **`MarkdownView` 現有的 `offline` 旗標**（`markdown_view.dart:296-299`）是給 AI 文字用的：
    - 媒體一律只顯示占位（`:506-511`）；
    - 連結經確認後**仍然會呼叫** `openExternal`（`:404-450`）。
    - 它不能當成快照的網路邊界，C3 也不改它的行為。
  - **App 鎖定**：
    - 讀取設定失敗時，`enabled = false`（`app_lock.dart:108-121`）；
    - Gate 只是畫面遮罩（`:267-278`）；
    - 離開 app 1 分鐘後重新上鎖（`:76`）。
  - **`ResumeTarget`** 沒有 ref、SHA 或快照身分（`resume_target.dart:1-14`）。`'repository'` 這個 case 已經存在，但忽略 `path`（`authenticated_app.dart:767-773`）。
  - **離開帳號的確認 `_leave`**：`authenticated_app.dart:875-919`。
  - **`select` 一開頭就呼叫 `_commitSignOut`**（`session_controller.dart:263`），它會寫入登出標記並刪除 last-active（`:556-599`、`:605-624`）。`connect`／`connectOAuth` 則直接 `_activate`（`:233`、`:349`）。
  - **user id 不符**目前丟出合成的 `unauthenticated`（`:150-151`、`:274-275`）。
  - **更新檢查**以匿名方式讀取 app 自己的 release（`update_controller.dart:83`），不使用帳號憑證。
  - **沒有網路狀態 plugin**。
  - **加密 envelope** 是 `version(1) || nonce(12) || ct || tag(16)`，額外 29 位元組（`ai_history_codec.dart:497-512`）。

---

## 2. 目標、非目標、超越 GitHub Mobile

### 2.1 目標
1. 在線上把任一分支或 tag 的整個儲存庫或其中一個資料夾，以**確認過的 commit SHA** 加密保存在裝置上。
2. 在線上或離線，都能瀏覽目錄、開檔案（語法上色、搜尋、換行、行號），看 README 與 Markdown（含快照內的圖片）。
3. 冷啟動沒有網路時，以上次驗證過、而且沒有被拒絕的帳號進入離線唯讀模式。網路恢復後重新驗證身分，再回到線上。
4. 保存過程對限流友善：請求數有上限、和 AI 共用額度、看得到進度。

### 2.2 非目標（v1）
- commit 歷史、blame、diff、議題、MR、CI。
- 離線編輯，或排隊等連線後寫入。
- 背景自動更新、背景下載服務、全文搜尋（只做檔名篩選）。
- LFS 物件本體（只存 pointer）、submodule 內容、symlink 的目標。
- raw 補抓與增量更新（E13）。
- 離線模式中的 C2 快取列表（C3d）。

### 2.3 超越 GitHub Mobile
| GitHub Mobile | Mergeline C3 |
|---|---|
| 沒有離線瀏覽儲存庫（#7365） | 可以保存整個儲存庫或資料夾，離線瀏覽 |
| 沒網路就開不了內容 | 冷啟動離線也能進唯讀模式 |
| — | 每個檔案都用提交的 blob id 驗證；畫面標明 SHA 與保存時間 |
| — | 未保存的檔案逐項寫明原因；在線時可以開線上版本 |
| — | 加密存放；離開帳號、清除快取、權限失效、身分被拒時刪除或封鎖 |
| — | 請求數有上限，和 AI 共用帳號的限流額度 |

---

## 3. 離線保存

### 3.1 保存的內容（E6）
- **快照**：一個專案、一個 ref（分支或 tag）、一個確認過的 SHA，加上一個子路徑（空字串代表整個儲存庫）。
- **檔案內容**：
  - **文字**：合法的 UTF-8、沒有 NUL、≤ 2 MiB、≤ 20,000 行。LFS pointer 照文字存，標記為 pointer。
  - **圖片**：副檔名 `png`、`jpg`、`jpeg`、`gif`、`webp`、`bmp`、`ico`（不分大小寫），≤ 10 MiB。SVG 屬於文字。
- **其他資料**：索引（tree 每一項的路徑、型別、mode、blob id、狀態）、專案投影（數字 id、name、path_with_namespace、default_branch）、ref 資訊（種類、名稱、SHA、物件格式、commit title、committed_date）。
- **未保存，記錄原因**：
  - `tooLarge`：超過上限；
  - `binary`：其他二進位檔；
  - `missing`：tree 有、archive 沒有；
  - `mismatch`：正規化後仍和 blob id 不符；
  - `symlink`、`submodule`；
  - `unsupportedType`：archive 中不支援的項目類型。
- **永不保存**：議題、MR、留言、pipeline、job log、GitLab uploads、外部圖片、LFS 物件本體、token、URL 參數。

### 3.2 ref 解析成確認過的 SHA（L5、E15）
- **分支**：`cachedRecord(['projects', '$id', 'repository', 'branches', name], fresh: true)`。
  - C1a 的 `observe` 會確認回應的 `commit.id`（C1a: `cached_read_api.dart:390-393`）。
- **tag**：
  1. `record(['projects', '$id', 'repository', 'tags', name])` 取得 `commit.id`。這一步**不**被確認，符合 C1a 的 tag 排除規則。
  2. `cachedRecord(['projects', '$id', 'repository', 'commits', sha], fresh: true)`。C1a 會確認回應的 `id`（C1a: `:394`）。
  3. 要求回應的 `id` 等於第 1 步取得的 SHA。
  - 代價是 tag 多一次請求，V10 與 C1a 的測試都不必改。
- **前提**：
  - 轉成小寫後，必須恰好是 40 或 64 位十六進位（40 位是 SHA-1 儲存庫，64 位是 SHA-256），而且 `_cache.isConfirmed(sha)` 為真。
  - C3 的 API part 檔與 `gitlab_api.dart` 屬於同一個 library，可以直接呼叫這個私有方法。
  - `superseded` 時重讀一次；仍不一致就以 `resolveFailed` 結束。
- **之後**：tree 與 archive 都以這個 SHA 指定，分支在保存期間移動也不影響。

### 3.3 取得方式（E1、L6）
以 `gitlab-org/cli` 的規模（2,227 項）估算：

| 項目 | A：tree + 一次 archive（採用） | B：tree + 每個檔案一次 raw |
|---|---|---|
| 請求數 | ref 1（tag 2）＋ tree 23 ＋ archive 1 ≈ 25 | ref 1 ＋ tree 23 ＋ 約 1,900 ≈ 1,925 |
| 對提議中 Free 每分鐘 100、每小時 5,000 | 約一分鐘 burst 的四分之一 | 至少 19 分鐘，佔一小時額度的 38% |
| V16 的 `no-store` | archive 與 tree 都沒有 `no-store`，可以落盤 | blob raw 帶 `no-store`（實測），依 V16 **不得落盤** |
| 一致性 | 單一 SHA，逐檔用 blob id 驗證 | 逐檔用 blob id，同樣一致 |
| 中斷後續傳 | 不支援 Range，只能重來，但已存的 blob 驗證後沿用 | 天然逐檔續傳 |
| 轉換與 `export-*` | 可能有，以驗證加正規化處理（§3.7） | 沒有 |
| 規格量 | tar 解析、回壓、柵欄（§3.5、§3.6） | lease 與節奏 |

- **選 A**：B 違反 V16，請求數也不可行；A 的五項規格都在本文件寫完整（L6）。
- **已查證（v2.1，R5）**：A 在 gitlab.com 上符合 V16，私有專案在登入狀態下的 archive 與 tree 回應都沒有 `no-store`（§1.1、§9 Q19）。B 仍然不是 V16 的出路：私有專案的 `files/<path>/raw` 實測帶 `no-store`。
- **只用 archive、不列 tree**：拿不到權威的 blob id 與 mode，無法驗證，所以不採用。

### 3.4 列出 tree 與驗證（Codex I1）
- **第一頁**：`GET projects/:id/repository/tree?ref=<sha>&path=<sub>&recursive=true&per_page=100&pagination=keyset`。走新的 typed 方法 `repositoryTreePage`（§7.2），同源、不轉址、計入 meter、遵守 `rateBudget`。
- **續頁（由 client 自己建立 URL）**：
  - 從 `Link` 的 `rel="next"` 中，**只取出 `page_token`**；
  - 同時檢查：同源、路徑相同、`ref` 等於 SHA、`recursive=true`、`id` 等於專案的數字 id（若有）；
  - 下一頁 = 第一頁的 query 加上這個 `page_token`。
  - 這樣避開實測中 `id`、`page`、`with_last_commit` 造成的拒絕（§1.1），又不信任伺服器給的其他參數。
- **offset 分頁**：只有伺服器的回應**沒有 `page_token`**、但明確給了 offset 的 `Link`（`page=N`）或 `X-Next-Page` 時才使用，同樣由 client 自己建立 URL（第一頁的 query 去掉 `pagination`、`page_token`，加上 `page=N`）。
  - 401、403、404、429 或任何 400 都**不**算「不支援 keyset」，一律當成失敗處理。
- **前進檢查**：同一個 `page_token` 或頁碼重複、空頁卻還有下一頁、項目重複 → 以 `invalidTree` 中止。
- **上限**：最多 50 頁、5,000 項，tree 的位元組預算見 §3.8。超過就中止（`tooManyEntries`／`treeTooLarge`），建議改選子資料夾。
- **每筆項目都要驗證**（一般的 `TreeEntry.fromJson`，`models.dart:225-235`，不提供這些保證）：
  - **path**：UTF-8 字串；沒有 NUL；開頭不是 `/`；沒有空段、`.` 段、`..` 段；≤ 4,096 位元組；有子路徑時要在 `<sub>/` 之下；
  - **唯一**：路徑不重複；
  - **type 與 mode 的組合**：
    - `blob`：`100644`、`100755`、`120000`；
    - `tree`：`040000`；
    - `commit`：`160000`；
    - 其他組合 → `invalidTree`。
  - **id**：依物件格式，是 40 或 64 位小寫十六進位；
  - **父目錄**：除了子路徑的根，每一筆的父目錄都要以 `tree` 項目出現。
- **寫入**：列完後，立刻以 `pending` 狀態寫入 `t_<id>.v1.bin`（§4.5）。這是正式檔，可以跨重啟續傳。

### 3.5 下載與跨 isolate 管線（Codex I3、Opus I-7）
- **請求**：
  - `GET projects/:id/repository/archive.tar.gz?sha=<sha>&include_lfs_blobs=false[&path=<sub>]`；
  - 走新方法 `repositoryArchive`：`allowsApi` 同源、`followRedirects: false`（3xx 就是 `redirectBlocked`）；
  - 遵守 `_checkRate` 與 `RateRequestClass.archive` 的冷卻，計入 `RequestMeter`，經 `_noteRateLimit` 記錄標頭；
  - 第一跳收到 401 時，可以 OAuth 換證後重送一次（GET）；
  - 回應帶 `no-store` 就中止（E18）。
- **誰持有什麼**：
  - socket 與 Dio 留在 main isolate；
  - 解壓、解析、驗證、加密、blob 寫入在 worker isolate；
  - tree 檔與索引的提交在 main isolate，經協調器的維護鎖（§4.4）。
- **回壓**：
  - main 用 `StreamIterator` 讀 `ResponseBody.stream`，**有 credit 時才拉下一塊**。不拉就不讀 socket，交給 TCP 流量控制。
  - 每一塊切成 ≤ 64 KiB，以 `TransferableTypedData` 加上序號送出。
  - worker 一開始給 16 個 credit（在途 ≤ 1 MiB），每處理完一塊就回一個 credit。
- **逾時**：
  - archive 請求關閉 Dio 的 `receiveTimeout`。實作時用 Dio 5.11.1 的實際語意設定，並以測試確認。
  - 改由 main 的 idle watchdog 負責：在**有 credit、正在等資料**的狀態下，連續 60 秒沒有收到位元組，就取消並記為 `network`。因回壓而暫停讀取的時間不計入。
  - connect 逾時沿用 15 秒。
- **worker 內的記憶體上限**：
  - 解壓的輸入每次 ≤ 16 KiB，交給 `ZLibDecoder(gzip)` 的 chunked conversion；
  - 輸出 sink 每收到一段就累計，超過 1 GiB 立刻丟 `archiveTooLarge`。不會先配置巨大的輸出；
  - 單一項目的緩衝 ≤ 10 MiB（圖片上限），正規化另外最多再用 2 MiB；
  - 超過分類上限的項目不緩衝，直接讀過串流；
  - 目標是 worker 峰值記憶體 ≤ 32 MiB，在 §8.5 量測。
- **讓出控制權**：每處理一則訊息、每完成一個項目、每讀過 1 MiB 要略過的資料之後，worker 都 `await Future<void>.delayed(Duration.zero)`，讓停止訊息有機會被處理。
- **停止協定**：
  - main 送出 `stop(jobEpoch)`。worker 在下一個讓出點：
    1. 刪掉進行中的暫存檔；
    2. 不再開始任何新的暫存檔或 rename；
    3. 回覆 `stopped(jobEpoch)`；
    4. 呼叫 `Isolate.exit()`。
  - 送出 `stopped` 之後，worker **不再做任何檔案系統操作**。
  - main 5 秒內沒收到 `stopped`，就 `Isolate.kill(priority: Isolate.immediate)`，並等 exit port。
  - 因為寫入一律是「暫存檔再 rename」，kill 之後只可能留下暫存檔，或已 rename、但沒被任何已提交的 tree 引用的 blob。前者由 main 刪除 `tmp/<jobId>/`，後者由 GC 回收（§4.6）。
- **金鑰**：worker 只拿到 HKDF 導出的資料子金鑰與命名子金鑰，**拿不到根金鑰**（§4.1）。
- **錯誤**：任何一層的錯誤都會取消整條管線：取消 HTTP、停止 worker、job 失敗。worker 的錯誤以 `failed(kind)` 回報，不帶路徑與內容。

### 3.6 tar 解析契約（Codex I2、Opus I-1；`lib/core/offline/tar_stream.dart`，純 Dart）
- **標頭**：
  - 每個 512 位元組。checksum 依 POSIX 計算：把 chksum 欄位當成 8 個空白，算無號位元組的總和；也接受有號的總和，因為有些舊實作用有號。
  - 數字欄位只接受 octal（可以有前後空白與 NUL）。第一個位元組的高位元是 1（base-256）→ `corruptArchive`。
  - `size` ≤ 2^40。
- **typeflag**：

  | 值 | 處理 |
  |---|---|
  | `0`、`\0` | 一般檔案 |
  | `5` | 目錄 |
  | `2` | symlink，只記錄，不存內容與目標 |
  | `x` | pax 單項，只套用到**下一個**非 metadata 項目 |
  | `g` | pax global，只使用 `comment`，其他鍵解析但忽略 |
  | `L` | GNU longname，只套用到下一個項目。配置緩衝前，先確認 size ≤ 4,097 |
  | `K` | GNU longlink，同上限，解析後忽略 |
  | 其他（`1`、`3`、`4`、`6`、`7` 等） | `unsupportedType`：用實際的 size 跳過內容，跳過的量計入 1 GiB 的解壓上限 |

- **metadata 的狀態**：`x`、`L`、`K` 的狀態在套用到下一個項目之後清除。metadata 項目本身**永遠不**拿去做 tree 路徑檢查。連續出現兩個相同種類的 metadata，以後者為準。
- **pax 記錄**：
  - 每個 pax 標頭 ≤ 64 KiB；
  - 逐條解析 `"<len> <key>=<value>\n"`，長度必須完全一致，`<len>` 是十進位；
  - 採用的鍵：`path`、`linkpath`（只記錄）、`size`。
  - **`size` 會改變 framing**：存在時取代標頭的 size，必須是 ≤ 2^40 的十進位，否則 `corruptArchive`。其他鍵忽略。
- **pax global 的 `comment`**：
  - 只有在它是 40 或 64 位十六進位時，才當成 commit 身分：不等於要求的 SHA → `shaMismatch`；
  - 不存在、或不是這個格式 → 忽略。GitLab 的 API 契約沒有承諾 comment 的內容，所以不強制。
- **路徑怎麼組成**：pax 的 `path` 優先，其次 GNU `L`，最後是 ustar 的 `prefix + '/' + name`（`prefix` 不為空時）。
- **正規化**（接受真實的 archive）：
  1. 第一個非 metadata 項目的第一段就是 wrapper。之後所有非 metadata 項目都必須以 `wrapper/` 開頭，否則 `corruptArchive`。
  2. 路徑剛好是 `wrapper/` 的項目（wrapper 目錄本身）略過。
  3. 目錄項目（`5`）只去掉**一個**結尾的 `/`。
  4. 去掉 `wrapper/` 之後，就是儲存庫的完整路徑。
  5. **結構性錯誤 → `corruptArchive`**：
     - 有空段（在去掉目錄的那一個結尾 `/` 之後）、`.` 段、`..` 段；
     - 開頭是 `/`；
     - 有 NUL；
     - 同一路徑出現兩次。
  6. **反斜線是合法字元**，路徑也永遠不會變成檔案系統的路徑。
- **和 tree 的對應**：
  - **子路徑的祖先目錄**（帶 `path=docs` 時的 `docs/`）略過。
  - **目錄項目**對應 tree 的 `tree`，或 `commit`（git archive 把 submodule 輸出成目錄）。tree 裡沒有的目錄項目，計入 `unmatched` 並略過。
  - **一般檔案**用 UTF-8 位元組完全比對 tree 的 `blob` 項目，而且必須在子路徑之內：
    - tree 沒有的路徑，或位元組不是合法 UTF-8 → 計入 `unmatched` 並略過，**不中止**；
    - 對應到的 mode 是 `120000`，但 archive 給的是一般檔案 → `mismatch`。
  - **symlink 項目**必須對應到 mode `120000`，否則計入 `unmatched`。
  - `unmatched` 只在診斷紀錄中留下計數，不寫路徑。
- **結尾**：
  - 必須出現兩個全零的區塊，之後只允許全零的填充，直到串流結束；有非零的位元組就是 `corruptArchive`。
  - 還沒到結尾區塊串流就結束 → `corruptArchive`（截斷）。
  - gzip：依賴 zlib 對 trailer（CRC32、ISIZE）的檢查。實作時用「trailer 被竄改」與「截斷」的 fixture 證明會丟錯；如果 `dart:io` 沒有檢查，就自己計算 CRC32（純 Dart，表驅動）。
  - gzip member 結束之後還有資料 → `corruptArchive`。
  - **只有完整、合法地讀到結尾，才可以進入提交。**
- **fixture**（Opus I-1）：
  - 一律用真正的 `git archive --format=tar.gz` 產生，再當成測試資源提交：本機一個合成的小 repository，含長路徑、submodule、symlink、子路徑、`.gitattributes` 中的 `eol=crlf`、`ident`、`export-subst`、`export-ignore`。
  - 另外加上手工構造的惡意與損壞 fixture。產生腳本與 commit 一起放進 `tool/fixtures/`。

### 3.7 驗證、正規化與分類（Opus I-2、Codex I4）
- **git blob id**：`H("blob " + size + "\0" + content)`，SHA-1 儲存庫用 SHA-1，SHA-256 儲存庫用 SHA-256。
- **每個一般檔案的處理順序**：
  1. 依路徑與 mode 先判斷候選類別：
     - 圖片副檔名 → 候選圖片；
     - mode `120000` → `symlink`；
     - 其他 → 候選文字。
  2. 超過該類別的上限 → `tooLarge`，直接讀過串流，不計算 hash。
  3. 計算 blob id，和 tree 比對。
  4. **不符時**，依序試下列可逆的正規化，每一種都重新計算 blob id（只對文字候選、≤ 2 MiB 的檔案）：
     - (a) 把所有 `\r\n` 換成 `\n`；
     - (b) 把 `$Id: <40 或 64 位 hex> $` 還原成 `$Id$`；
     - (c) (a) 與 (b) 都做。
     - 相符就接受，存入的是正規化後的內容，也就是提交裡的原始內容。這是密碼學驗證，所以安全。
  5. 仍然不符 → `mismatch`。
  6. **相符時**：
     - 文字候選：合法的 UTF-8、沒有 NUL、≤ 20,000 行 → 存成 `text`（以 LFS pointer 開頭的，標記為 `lfsPointer`）；否則 → `binary`。
     - 圖片候選 → 存成 `image`。
- **tree 有、archive 沒有的 blob** → `missing`。
- **不推斷原因**：UI 只寫「封存檔中沒有這個檔案」或「封存檔的內容與提交不符」，**不寫** `export-ignore`／`export-subst`，因為其他轉換或傳輸差異也會造成相同的結果。
- **`.gitattributes` 的提示**：保存完成後，若 `missing + mismatch > 0`，而且快照根目錄的 `.gitattributes`（已存的文字）提到 `export-ignore`、`export-subst`、`ident`、`eol`、`text`、`working-tree-encoding`、`filter` 其中之一，就在快照頁顯示「部分檔案可能受 .gitattributes 設定影響而未保存」。
- **沿用已存的內容**：
  - 目標的 blob 檔已存在時，worker 會先解密（AEAD），再重新計算 blob id：
    - 相符就沿用；
    - 解不開或不符，就把新內容寫成暫存檔，原子地 rename 覆蓋過去（修復）。
  - 分類**一律**依這次的 tree 與目前的政策重新判定，不沿用舊快照的分類。
- **沒有補抓**（E13）：`missing` 與 `mismatch` 維持未保存。在線時，可以開線上檔案頁。

### 3.8 上限與位元組預算（Codex C6、I5）
| 項目 | 上限 | 超過時 |
|---|---|---|
| tree | 50 頁、5,000 項 | `tooManyEntries`（在 archive 之前） |
| tree 檔明文（含最終欄位的預留） | 4 MiB | `treeTooLarge`（在 archive 之前） |
| 單一路徑 | 4,096 位元組 | `invalidTree` |
| index 明文 | 1 MiB | `indexTooLarge`（在提交之前） |
| archive 壓縮後 | 300 MiB | `archiveTooLarge` |
| 解壓後處理量（含略過的部分） | 1 GiB | `archiveTooLarge` |
| pax 標頭；GNU `L`／`K` | 64 KiB；4,097 位元組 | `corruptArchive` |
| 文字；圖片 | 2 MiB 與 20,000 行；10 MiB | 標 `tooLarge` |
| 單一快照存入的明文（含共用的 blob） | 150 MiB | `storageFull` |
| 每個帳號的總量（ciphertext、tree、index、暫存） | 600 MiB | `storageFull` |
| 快照數 | 新增最多 30 個；更新屬於替換，不受這個限制 | 擋住新增 |

- **envelope 的常數** `envelopeOverhead = 29`，寫入端與讀取端共用。讀取前檢查 ciphertext 的大小：
  - index ≤ 1 MiB + 29；
  - tree ≤ 4 MiB + 29；
  - blob ≤ 10 MiB + 29。
- **tree 的預算**：
  - 列 tree 時逐筆累加「這一筆最終的 JSON 編碼長度」：實際的跳脫後路徑，加上 id，再加上最長的 `state`、`kind`、`size`（10 位數）、`lines`（5 位數），使用 §4.3 的短鍵名。
  - 累計超過 4 MiB 就在下載 archive **之前**中止。
- **index 的欄位上限**：
  - projectName ≤ 255 個 code point；
  - projectPath、refName ≤ 1,024 位元組；
  - subPath ≤ 4,096 位元組；
  - commitTitle 截成 ≤ 200 個 code point，不切斷 surrogate pair。
  - 提交前計算序列化的長度。
- **讀回**：tree 檔與 index 寫入後、提交點之前，用**正式的讀取器**讀回並解析一次；失敗就不提交，job 以 `storageError` 結束。
- **容量的峰值**：
  - 開始前要求：`目前用量 + 預估 ≤ 600 MiB`。新增時預估是 0；更新時預估是舊快照的 `storedBytes`。
  - 寫入中，每次 rename 之前檢查：`目前用量 + 這次新增的位元組 ≤ 600 MiB`，超過就 `storageFull`。舊快照完整保留。
- **裝置空間**：沒有查詢剩餘空間的 API，以 ENOSPC（errno 28）為準，結果是 `deviceFull`，舊快照完整保留。

### 3.9 限流與 lease（E14）
- **一次一個**：每個帳號同時只有一個保存或更新工作，排隊上限 5 個。兩次 archive 開始之間至少隔 15 秒。這只是保守的節奏，不保證不會被限流，以 429 與標頭為準。
- **lease**：
  - 使用帳號層級的 `RunBudgetAllocator`，和 AI 共用。
  - 每個階段開始前，`acquire(min(本階段剩下的請求數, 40))`：
    - 回傳 null → 進入 `waitingBudget`，等 `rateBudget.stream` 有變化或 30 秒後再試。
    - granted 為 0 → **立刻 `release()`**，再進入 `waitingBudget`。理由：C1a 的 `acquire` 在額度算出 0 時，照樣把 lease 加進 `_leases`（C1a: `rate_budget.dart:377-391`），等待中若握著它，會佔掉 3 個名額之一（v2.1，R3）。
  - 每次真正送出請求（以 `RequestMeter` 計數，含 OAuth 重送）就 `consume(1)`；lease 用完就 release，再 acquire 新的。
  - 結束、失敗、停止時，在 `finally` 中 release。
  - **誰擁有 allocator**：C1b-2 建立每個帳號一個的 allocator。若它不在 `GitLabApi` 上，C3a 把它移成 `GitLabApi.runBudget`（每個 client 一個，也就是每個帳號 session 一個），C1b-2 的 AI 呼叫點改用這個實例（§7.2）。
- **開始條件**：
  - tree 列表前：`rateBudget.mayStart(RateRequestClass.global)` 為真，而且 `snapshot().level == normal`；
  - archive 前：`mayStart(RateRequestClass.archive)` 為真。
- **列 tree 時的節奏**：
  - normal：連續；
  - low 或 critical：等到 `limitingBucket.resetAt`；
  - 還沒收到任何 `RateLimit-*` 標頭（`snapshot().limitingBucket == null`）：每 200 ms 一頁。C1a 的 `RateLevel` 只有 `normal`、`low`、`critical`（C1a: `rate_budget.dart:14`），沒有 bucket 時 level 是 `normal`，所以要用 `limitingBucket` 判斷（v2.1，R4）。
- **429 或冷卻**：進入 `waitingRateLimit`。只有 `retryAtFor` 已知時，才顯示「約 N 分鐘後自動繼續」。

### 3.10 工作狀態、進度、暫停、取消
- **執行中的狀態**：
  - `queued`：排隊中；
  - `resolving`：解析版本；
  - `listing(page)`：讀取目錄；
  - `waitingBudget`：等待額度；
  - `waitingRateLimit(eta?)`：等待限流解除；
  - `downloading(receivedBytes, processedPaths, totalBlobPaths)`：下載與驗證；
  - `finalizing`：寫入。
- **持久的狀態**（index 的 `status`）：`saving | paused | failed | complete | superseded`，另外記錄 `failure` 與 `interrupted`。
- **進度**：`processedPaths ÷ totalBlobPaths`，以路徑計算，不以去重後的 blob 計算。另外顯示已下載的 MB 數。
- **完成的語意**（Codex m4）：
  - 「保存完成」指提交成功；
  - 若有未保存的檔案，UI 一律顯示數量與原因；
  - 只有未保存的數量為 0 時，才顯示單純的成功勾號。
- **暫停**：讓 job 失效 → 取消 HTTP → 送 stop 並等 ack（或 kill）→ status 改成 `paused`。已存的 blob 與 `pending` 狀態的 tree 檔都保留。**不承諾位元組層級的續傳。**
- **繼續**：
  - 重新下載 archive，已存的 blob 驗證後沿用（§3.7）；
  - 24 小時內不必重新列 tree；
  - 網路流量會重新花一次。
- **取消**：讓 job 失效 → 停止 → 等 ack → 在維護鎖內移除索引項與 tree 檔 → 設 `gcPending`。遲到的 callback 因為 epoch 不符被丟棄，不會把它加回索引。
- **進入背景**：
  - 工作盡力繼續，不保證系統會給執行時間（B9）。
  - 連線中斷就記為 `paused`，並標 `interrupted`。回到前景、而且距離中斷至少 30 秒時，自動重試一次；之後要手動。
  - 每次提交前仍會檢查帳號、專案與 job 的柵欄。
- **24 小時的清理**：`paused`、`failed` 以及沒有工作在跑的 `saving`，超過 24 小時就清掉（§4.6）。

### 3.11 失敗
- **`SnapshotFailure`**（core 只有 enum，沒有字串）：
  - 上限：`tooManyEntries`、`treeTooLarge`、`indexTooLarge`、`archiveTooLarge`、`storageFull`；
  - 裝置與儲存：`deviceFull`、`storageError`、`keyUnavailable`、`offlineCacheDisabled`；
  - 資料：`invalidTree`、`corruptArchive`、`shaMismatch`、`resolveFailed`、`serverForbidsStorage`（E18）；
  - 權限與版本：`accessLost`、`versionGone`；
  - 其他：`rateLimited`、`network`、`sessionEnded`。
- **自動重試**：只有 `network` 與 `interrupted` 會自動重試一次。
- **更新失敗**：舊快照完整保留。

### 3.12 更新到較新的 SHA（E13）
- **只在線上，由使用者觸發**。「有新版本」來自 §3.14 的探查，探查時順便取得分支的最新 SHA。
- **流程**：
  1. 依 §3.2 解析；和快照的 SHA 相同時，顯示「已是最新」。
  2. 依 §3.4–§3.7 完整重做一次，新快照帶 `replaces: <舊 id>`。
  3. 已存的 blob 驗證後沿用，分類全部重新判定。
  4. 提交時，同一次 index 寫入把舊快照改成 `superseded`；之後刪舊的 tree 檔，並設 `gcPending`。
- **失敗時**：舊快照完整保留。
- **不做自動更新。**

### 3.13 刪除
- **單一快照**：
  - 確認後，在維護鎖內依序：
    1. 讓該快照的 job 失效並停止；
    2. **先刪 tree 檔**；
    3. 再寫 index，移除該項（Opus m9：磁碟已滿時，index 寫不進去也能先釋放 tree 的空間）；
    4. 設 `gcPending`。
  - 當機時，§4.6 第 4 步會收拾。
  - index 仍然寫不進去：提示改用「全部刪除」。
- **全部刪除離線專案**：只限 C3 的命名空間，走 §4.4 的命名空間清除（shred C3 的金鑰、刪目錄）。C2 不受影響。
- **離線模式中**：允許上述兩種刪除，但不做 GC（§5.7）。

### 3.14 權限失效與專案柵欄（E7、Codex C2）
- **事件從哪裡來**：
  - `GitLabApi` 在 `_send`、`_rawFileBytes` 與 C3 的新方法收到錯誤時（就在 C1a 呼叫 `_cache.revoke` 的旁邊），依解析過的路徑段分類，不用字串猜：

    | 分類 | 條件 | 動作 |
    |---|---|---|
    | 專案 | `GET projects/:id`（`:id` 是數字，或能用 C1a 的別名表解析成數字）回 403 或 404 | 刪除該專案的所有快照 |
    | 儲存庫 | GET 下列端點回 403：`projects/:id/repository/{tree, archive*, blobs/**, files/**, branches/**, tags/**}` | 刪除該專案的所有快照 |
    | 帳號 | `/user` 的回應，以及終局 401 | `/user` 依 §5.2 的判定表處理（403 保留資料、寫拒絕標記）；終局 401 依 V13 清除整個帳號 |

  - **只在回應是 GitLab 的 JSON 錯誤時才動作**（Opus m11）：`content-type` 是 `application/json`，最多讀 4 KiB 的 body，必須是含有 `message` 或 `error` 鍵的物件。代理伺服器的 HTML 403／404 不觸發刪除。
  - **插入點（v2.1，R2）**：C1a 在 `_cache.revoke` 之後立刻丟掉錯誤的 body（C1a: `gitlab_api.dart:366-368` 的 `body.stream.listen((_) {}).cancel()`；`_rawFileBytes` 在 `:840-842` 呼叫 `_releaseBody`）。所以：
    - GET 的 403／404，要在 `:368` 的 cancel 與 `_releaseBody` **之前**，有界地讀最多 4 KiB，交給分類器，然後才丟掉其餘的 body；
    - 401 的終局條件沿用 C1a 的 `_credential is! OAuthCredential || retried`（C1a: `:367`、`:841`），不另寫一套；
    - `identityCheck()`（§5.2）是新的請求路徑，要自己做同樣的有界讀取，**不呼叫**會丟掉 body 的 `_send`。
  - 別名解析不了 → 不動作，交給探查處理。
- **事件交給誰**：
  - 事件是 `AccessLoss(accountKey, generation, projectId, scope, status)`，交給 `OfflineRepositoryCoordinator.instance`。
  - `_activate` 在 `bindReadCache` 之後，把協調器的 sink 綁到 client 上（C1a: `session_controller.dart:501` 的旁邊）。
  - **不經過任何 UI 訂閱。**
- **協調器同步做的事**（在交出控制權之前）：
  1. 確認 `(accountKey, generation)` 等於目前開放的帳號，否則忽略；
  2. 提高 `projectEpoch[projectId]`；
  3. 把該專案加入 `revoked` 集合：快照的讀取、排隊中的 job、新的保存與提交一律拒絕，reader 回傳 `accessLost`。
- **之後非同步做的事**：
  1. 取消該專案的 job；
  2. 送 stop 並等 ack，或 kill；
  3. 在維護鎖內，刪除該專案所有快照的 tree 檔與 index 項；
  4. 設 `gcPending`，寫入 `removedNotice`。
- **提交時的檢查**：每次 rename、tree 或 index 的提交、把結果交給 UI 之前，都比對 job 的 `projectEpoch`。所以舊工作不可能在刪除之後復活。帳號的 generation 不足以取代這個檢查。
- **OAuth**：可恢復的 401（換證成功）不觸發任何清除。終局的帳號 401 與專案層級的拒絕，清除範圍不同。
- **模糊的 404**（分支被刪、路徑不存在、SHA 被 gc）：
  1. fresh 讀 `GET projects/:id`：GitLab JSON 的 403 或 404 → 刪除；
  2. 回 200 → 讀 `GET projects/:id/repository/tree?ref=<快照 SHA>&per_page=1`：
     - 403 → 刪除；
     - 200 → 保留；
     - 404 → 保留，標「保存的提交已不在 GitLab 上」。
- **探查**：
  - **時機**：在線時打開該專案、快照或保存列表時；以及每次 `_activate` 之後，距離上次全面探查超過 24 小時時。
  - **方式**：每個快照讀一次分支或 tag（tag 用 `tags/:name`），順便得到 `headSha`：
    - 200 → 保留，更新 `headSha`；
    - 403 → 刪除；
    - 404 → 進入上面的模糊 404 流程。
  - **節奏**：每 2 秒一個，只在等級 normal 時執行，用 lease 計量。
- **說明文字**：刪除後的說明寫「目前帳號無法讀取這些專案（可能已無權限、已刪除、已移動，或目前的網路位置不被允許）」（Opus m11）。

### 3.15 D1 與生命週期
- **帳號層級的清除**：快照屬於帳號，在以下情況全部刪除（shred C2 與 C3 兩把金鑰，刪兩個目錄）：
  - D1 的任何離開方式；
  - 終局 401；
  - user id 不符；
  - 設定頁的「清除快取」（L1）；
  - 關閉「離線快取」開關；
  - 啟動掃描（只保留即將自動恢復的帳號）；
  - 任何 `_activate(target)` 對 target 以外帳號的清除（B11）。
- **保存前一定先告知**（§6.3）。
- **離開前一定先確認**（§6.7）。
- **工作中切換帳號**：
  1. 帳號的柵欄同步進入 `cleaning`；
  2. job 失效 → 取消 HTTP → stop／ack／kill；
  3. 之後才 shred 金鑰、刪目錄；
  4. 結果在 generation 改變後一律丟棄。

### 3.16 AI
- AI 的讀取 port、`ai_chat_context`、工具 catalogue **拿不到** `SnapshotRepositoryReader` 或快照的儲存層。
- **兩層保證**：
  - 靜態：`tool/tests/test_offline_boundaries.py`，`lib/core/ai/**` 與 `lib/features/ai/**` 不得 import `lib/core/offline/**`。
  - 行為：§8.3 的測試證明，有快照時，AI 讀檔照樣送出網路請求；`OfflineApp` 裡沒有 AI 的 controller。

### 3.17 `no-store`（E18、Codex I7）
- V16「伺服器回 `no-store` 一律不快取」對 C3 照樣適用。C3 只把 tree 與 archive 的回應落盤；兩者實測都沒有 `no-store`（§1.1）。
- tree 的任一頁，或 archive 的回應帶 `no-store` → job 以 `serverForbidsStorage` 結束，不提交任何東西。
- blob raw 帶 `no-store`，所以 C3 不使用 raw（E13）。
- **執行時的守衛**（R5）：gitlab.com 的私有專案實測沒有 `no-store`（§1.1）；自架 instance 若有，結果是 `serverForbidsStorage`。UI 的說明文字：「這個 GitLab 伺服器要求不要保存它的回應，所以無法離線保存這個專案。」

---

## 4. 資料模型與檔案配置

### 4.1 金鑰與加密（E4、L1）
- **C3 的根金鑰**：`offline_repo_key.v1.<base64url(account.key)>`。
  - 32 位元組，選項和 C2 與 AI 的金鑰相同（ThisDeviceOnly）。
  - 三態讀取、single-flight 建立、讀回確認，照 v3 §4.3 與 V14。
  - 格式錯誤的金鑰視同 absent。
- **子金鑰**（HKDF-SHA256，Opus m20）：
  - salt：UTF-8 的 `"mergeline-offline-repo"`；
  - 長度 L = 32；
  - `info`：`"offline-repo-data-v1"`（AES-256-GCM 的資料金鑰）、`"offline-repo-names-v1"`（HMAC 命名金鑰）；
  - 不提供任意 `info` 的公開介面。
- **envelope**：`version(1) || nonce(12) || ct || tag(16)`，額外 29 位元組，每次寫入用新的 nonce。
  - 寫入時用 `BytesBuilder` 一次組好，**不用** `Uint8List.fromList([version, ...])` 那種會把每個位元組裝箱的寫法（Opus m10）。
- **AAD**：`jsonEncode(["offline_repo", 1, account.key, <offline_repo/<hash>/ 之下的相對檔名>])`。
- **哪個動作 shred 哪把金鑰**：

  | 動作 | C2 金鑰 | C3 金鑰 |
  |---|---|---|
  | 帳號層級的清除：D1、終局 401、user id 不符、移除帳號、「清除快取」、關閉開關 | shred | shred |
  | 全部刪除離線專案 | 不動 | shred |
  | 刪除單一快照 | 不動 | 不動（殘留的 ciphertext 在 C3 金鑰仍在時可以解密，揭露在 §9） |

### 4.2 目錄與安全的目錄鏈
```
<ApplicationSupport>/offline_repo/<sha256(account.key) 前 32 個十六進位字元>/
  index.v1.bin              快照清單與帳號中繼資料（加密）
  t_<snapshotId>.v1.bin     每個快照的 tree（加密）
  b/<name>.v1.bin           blob 內容（加密，依 blob id 去重，所有快照共用）
  tmp/<jobId>/…             進行中的暫存檔
```
- **和 C2 的 `read_cache/<hash>/` 是兄弟目錄**，C2 的維護不會碰到它。
- **命名**：
  - `snapshotId`、`jobId`：32 位小寫十六進位亂數；拼路徑前先驗證格式。
  - `name`：`HMAC-SHA256(namesKey, objectFormat + ":" + blobId)` 的前 32 個十六進位字元。
- **安全的目錄鏈**：
  - 建立與開啟時，從 `offline_repo/` 開始逐層用 `FileSystemEntity.typeSync(path, followLinks: false)` 檢查，每一層都必須是目錄，不是 symlink。比照 `ai_history_files.dart` 的 `_entityType` 用法（例如 `:216`、`:288`）。
  - 列目錄一律用 `listSync(followLinks: false)`。
  - 讀檔前確認是一般檔案，再檢查大小（§3.8）。

### 4.3 schema
- **`index.v1.bin` 的明文**：
```
{ "schema": 1, "account": "<account.key>", "lastValidatedAt": "<UTC>", "lastProbeAt": "<UTC>|null",
  "consentAt": "<UTC>", "gcPending": false, "removedNotice": {"count": n, "at": "<UTC>"}|null,
  "snapshots": [ { "id", "projectId", "projectPath", "projectName", "defaultBranch",
    "refKind": "branch|tag", "refName", "sha", "objectFormat": "sha1|sha256", "subPath",
    "commitTitle", "committedAt", "status": "saving|paused|failed|complete|superseded",
    "failure": "<SnapshotFailure>|null", "interrupted": false, "replaces": "<id>|null",
    "createdAt", "savedAt", "entryCount", "savedCount",
    "notSaved": {"tooLarge","binary","missing","mismatch","symlink","submodule","unsupportedType"},
    "storedBytes", "headSha": "<sha>|null", "probe": "ok|refGone|commitGone|null", "probedAt" } ] }
```
- **`t_<id>.v1.bin` 的明文**：
  - `{"schema":1, "snapshotId", "sha", "subPath", "e": [...]}`；
  - 每一項使用短鍵名：`{"p": path, "t": type, "m": mode, "i": id, "s": state, "k"?: kind, "z"?: size, "l"?: lines}`；
  - `s` 是 `pending|saved|tooLarge|binary|missing|mismatch|symlink|submodule|unsupportedType`；
  - `k` 是 `text|image|lfsPointer`。
  - `complete` 的快照不得有 `pending`。解密後必須確認 `sha` 與 `snapshotId` 和 index 一致。
- **`lastValidatedAt`**：
  - 建立 index 時寫入；之後每次 `_activate` 都更新；
  - 在線上 session 中，任何**經過驗證的 2xx 回應**也會更新，每天去抖動一次（Opus m5）。`GitLabApi` 在每天第一次 2xx 時呼叫協調器的 hook。
  - 離線模式中不更新。
- **`consentAt`**：第一次保存的知情說明（§6.3）被確認的時間。

### 4.4 柵欄、維護鎖與命名空間清除（Codex C2、C3，Opus C-3 第 4 點、I-7）
- **`OfflineRepositoryCoordinator.instance`**：程序層級，每個帳號一份狀態：
  - **帳號狀態**：`closed`、`offlineReadOnly`、`ready`、`cleaning`、`unavailable`、`needsNewerApp`；
  - **三種 epoch**：帳號 epoch（每次狀態轉換時 +1）、`projectEpoch[projectId]`、`jobEpoch`；
  - **維護鎖**：一個帳號只有一把 mutex，由 index 寫入、tree 提交、GC、命名空間清除與恢復持有；
  - **worker 登記表**：每個 worker 的 job、epoch 與停止用的 port。
- **提交前的檢查**：派送 isolate 工作之前、每次 rename 之前、每次 tree 或 index 提交之前、把結果交給 UI 之前，都比對帳號 epoch、`projectEpoch`、`jobEpoch` 與 `revoked` 集合。index 的寫入另外比對 index 的 revision（compare-and-set）。
- **帳號層級的清除**（V13 加上 V20 m-10，由 C2 的 `ReadCacheDiskCoordinator` 主導，C3 以命名空間的身分參與，B4）：
  1. **同步**：C2 與 C3 的帳號狀態都進入 `cleaning`，帳號 epoch +1；讀取、排隊、新的寫入、建立金鑰一律拒絕；
  2. 寫入標記 `read_cache_clear_pending.v1.*`。寫入失敗照樣繼續刪除，並在記憶體保留 pending、維持關閉；
  3. 取消所有 job，送 stop 並等 ack（5 秒，否則 kill），也等 C2 在途的 isolate 寫入；
  4. 刪除 C2 金鑰與 C3 金鑰。任何一把刪除失敗，目錄照樣刪；
  5. 刪除 `read_cache/<hash>/` 與 `offline_repo/<hash>/`。不解析內容，所以未知 schema、金鑰 unavailable 時也照樣刪（m-11）；
  6. 刪除 `offline_refused.v1.*` 與 `offline_repo_clear_pending.v1.*`；
  7. 兩把金鑰、兩個目錄都確認不存在之後，才移除 V13 的標記 → `closed`。
  - **失敗**：維持 `cleaning`，不建立金鑰，下次 resume 或啟動時重試。
  - **重新開放**：只在 `_activate` 綁定時，或「清除快取」完成後同一個 session 重新開放（m-10）。
- **C3 命名空間的清除**（全部刪除離線專案，Opus C-3 第 4 點）：
  1. 同步讓 C3 進入 `cleaning`（帳號的 C2 部分維持 `ready`）；
  2. 寫入 `offline_repo_clear_pending.v1.<base64url(account.key)>`；
  3. 停止 worker；
  4. 刪除 C3 金鑰；
  5. 刪除 `offline_repo/<hash>/`；
  6. 移除標記 → C3 回到 `ready`。下次保存時建立新的金鑰。
  - 失敗規則與帳號層級的清除相同。
- **啟動時的處理**：V13 的第 2 步同時處理兩種標記。

### 4.5 提交順序
1. **在維護鎖內**，index 新增一項，`status: saving`（更新時另帶 `replaces`）。
2. tree 列完：`t_<id>.v1.bin`（全部 `pending`）先寫暫存檔，再 rename。
3. **worker 寫 blob**：寫暫存檔、`flush`，然後 rename 到 `b/<name>.v1.bin`。已存在的檔案依 §3.7 驗證後沿用，或原子替換。
4. **在維護鎖內**，把 tree 檔改寫成最終狀態（沒有 `pending`），用正式讀取器讀回。
5. **在維護鎖內**，index 改成 `status: complete`，寫入 `savedAt`。更新時，舊快照在同一次寫入中改成 `superseded`。寫完讀回。**這一步是提交點。**
6. 刪除 `superseded` 的 tree 檔與 index 項，設 `gcPending`，等帳號沒有 worker 時 GC。
- **承諾的程度**（Codex C3）：孤兒 blob 可能因為 index 損毀、kill 或清理中當機而出現。系統保證它們**可以辨識、會被回收**，而不是「不可能出現」。

### 4.6 啟動恢復與 GC（Codex C3、I5，Opus m16）
- **何時執行**：只在 `ready`、而且帳號的 worker 登記表是空的時候，在維護鎖內執行。`offlineReadOnly` 與 `closed` 不做任何背景維護。
- **恢復的步驟**：
  1. 刪除 `tmp/`（登記表是空的，所以不會刪到進行中的檔案）。
  2. 沒有工作在跑的 `saving` 改成 `paused`，並標 `interrupted`。`paused`、`failed` 超過 24 小時，或 tree 檔不在 → 移除 index 項與 tree 檔，設 `gcPending`。
  3. `superseded` → 完成 §4.5 第 6 步。
  4. `complete` 的 tree 檔遺失或解不開 → 移除 index 項，記到 `removedNotice`。
  5. `gcPending` 為真時執行 GC。
- **GC 的根**：
  - `complete` 的快照：tree 中 `saved` 的項目；
  - `saving`、`paused`、`failed`（還在 24 小時內）的快照：tree 中**所有** `blob` 項目，不論是 `pending` 或 `saved`；
  - 名稱用 `HMAC(namesKey, objectFormat:blobId)` 計算。
  - GC 全程持有維護鎖，job 不能開始，也不能提交；有 job 在跑時，GC 延後，`gcPending` 保留。
- **index 解不開**（AEAD 失敗或 schema 損壞，而且金鑰是 found）→ 走 §4.4 的 C3 命名空間清除。金鑰 unavailable → 什麼都不做（V14）。
- **讀取時 blob 解不開** → 畫面顯示「離線內容已損壞」；在線時提供「重新保存」，會原子替換那個 blob。

### 4.7 schema 版本與遷移
- **版本出現在**：檔名的 `.v1`、明文的 `schema` 欄位；blob 有自己的版本。
- **讀到較新的 schema**（例如 app 降版）：
  - 狀態是 `needsNewerApp`：一般讀取、恢復、GC、新保存一律不做，**但不刪除**；
  - 帳號層級的清除與 C3 命名空間的清除，**照樣刪除整個目錄**，不解析內容（Codex I5）。
- **v1 → v2**：在 `ready`、恢復之前，在 isolate 內重寫 index 與 tree，blob 不動；先寫新檔再刪舊檔；失敗就保留 v1、維持 `needsNewerApp`，下次啟動再試。

### 4.8 iOS 備份排除（L7、Opus I-8）
- **原生端**：`tool/bootstrap.py` 在產生的 iOS runner 中加入一個 method channel `mergeline/backup`。它的 `excludeFromBackup(path)` 對目錄執行 `URL.setResourceValues(isExcludedFromBackup = true)`；排除一個目錄，就排除它底下的內容。
- **呼叫時機**：
  - C3 每次建立或開啟 `offline_repo/` 與 `offline_repo/<hash>/` 時都呼叫一次；冪等，失敗只記錄、不阻擋。
  - 建議 C2 對 `read_cache/` 做同樣的事（B12）。
- **Android**：已經排除備份（`bootstrap.py:200-206`）。
- **測試**：`tool/tests` 新增一個測試，確認產生的 AppDelegate 含有這個 channel 與呼叫。iOS 的實際效果標 NOT_RUN。

### 4.9 C2 的契約修正（B1–B12；C2 開工前併入 plan-v3 的 C2 章節，是 C3a 的硬性前置條件）
| 編號 | 修正 | 取代 v1 的 |
|---|---|---|
| B1 | C2 的 D1 啟動掃描與孤兒清理，擴大到 `offline_repo/<hash>/`、`offline_repo_key.v1.*`、`offline_repo_clear_pending.v1.*`、`offline_refused.v1.*`。保留的帳號是「即將自動恢復的帳號」與 B10 的 `diskRetainedAccountKey` | A1 |
| B2 | C2 的 32／96 MiB 上限與 C3 的 600 MiB 分開計算。兩者都不保證裝置真的有空間，一律以 ENOSPC 為準 | A2 |
| B3 | 設定頁的「清除快取」與關閉開關，都是 §4.4 的帳號層級清除，**含離線專案**。確認框寫出快照數與大小（L1） | A3、A4 |
| B4 | `ReadCacheDiskCoordinator` 提供命名空間介面：`register(namespace)`，namespace 實作 `fence`、`stopAndWait`、`deleteKey`、`deleteDirectory`、`open(mode)`、`hasMarker`。帳號層級的清除依 §4.4 的順序（先柵欄、後標記）呼叫所有命名空間 | A4、A6 |
| B5 | C2 的「index 不可用 → 刪除 C2 的磁碟快取」只限 C2 的命名空間 | A5 |
| B6 | 安全事件（終局 401、`/user` 的判定、權限失效）由協調器處理，不依賴任何 UI 訂閱；完整清除優先於未知 schema 與金鑰 unavailable（m-11） | — |
| B7 | 帳號狀態新增 `offlineReadOnly`：`closed → offlineReadOnly`（只能由 `_enterOffline` 觸發）、`offlineReadOnly → ready`（`_activate` 綁定時）、`offlineReadOnly → cleaning`、`offlineReadOnly → closed`。`closed` 允許**唯讀的資格檢查**：讀金鑰、解密 C3 的 index；金鑰 absent 時只回「不合格」，不刪目錄、不建立金鑰 | A7 |
| B8 | 重試同一個帳號：`select(target)` 在 `active == null`、而且 `target.key == diskRetainedAccountKey` 時，**不執行**登出序列：不寫登出標記、保留 last-active、不清除 | A10 |
| B9 | C2 §4.5「背景暫停寫入」不適用於 C3 的 worker。C3 在背景盡力繼續，但每次提交仍要通過柵欄 | A9 |
| B10 | `diskRetainedAccountKey`：由 V13 第 3 步設定，在 `_activate(target)` 時改成 target。只有目前 ticket 的 `SessionController` 路徑可以改它；已 dispose 的 callback 不得改寫 | A10 |
| B11 | **任何** `_activate(target)`（包括 `connect`、`connectOAuth`）都要在綁定之前，對 target 以外、仍有磁碟資料的帳號**同步柵欄**（立刻讀不到），再依 §4.4 **在背景刪除**。刪除不阻擋 `_activate` 與 UI，和 v3 §4.4 一致 | Opus C-3 第 3 點 |
| B12 | 建議（不是 C3 的前置條件）：C2 的資料金鑰改用 HKDF 導出；`read_cache/` 排除 iOS 備份；終局 401 也要求是 GitLab JSON 的回應 | — |

- **V17**：pinned 是 C2 的機會快取政策。C3 的快照是明確保存，不適用 V17，但同樣受帳號層級的清除與 §3.14 約束。

---

## 5. 離線唯讀模式

### 5.1 進入條件（全部都要成立；L2、L4）
1. `initialize` 決定了要自動恢復的帳號 A：沒有登出標記，`lastActive` 對應到已存的帳號（`session_controller.dart:119-142`）。
2. V13 的第 2、3 步已經對 A 完成：A 沒有未完成的清除標記，標記也讀得到。
3. **資格**（`OfflineGate.check(A)`，在 `closed` 狀態下唯讀執行，和 `/user` 平行，B7）：
   - 讀得到 `offline_refused.v1.<A>`，而且**不存在**。讀取失敗視同存在（fail closed）；
   - C3 金鑰是 found；index 解得開、帳號相符、schema 認得；
   - 至少有一個 `complete` 的快照；
   - `now − lastValidatedAt ≤ 30 天`。時間在未來超過 5 分鐘，視同過期；
   - App 鎖定的設定已經成功載入（§5.9）。
4. **`/user` 沒有身分判定**，種類是下列之一：
   - `network`、`server`（5xx）、`rateLimited`（429）；
   - `redirectBlocked`（3xx）、`invalidResponse`（不是 GitLab 的 JSON），例如 Wi-Fi 認證頁（L4）。
   - **不進入**的情況：其他種類（`unsupported`、`cancelled`、`validation`、非 `ApiFailure` 的例外等），以及不是 GitLab JSON 的 401 或 403。這些都顯示登入畫面，**不刪資料，也不寫拒絕標記**。
   - **為了讓「不刪資料」跨重啟也成立**：判定是 `unknown` 時，**保留 last-active**。這改變了 `session_controller.dart:164-168` 的現有行為：它目前對任何 `unauthenticated`（包括不是 GitLab JSON 的 401）都刪除 last-active，下次啟動時沒有要恢復的帳號，V13 的掃描就會刪掉全部資料。只有 `refused401` 與 user id 不符才刪除 last-active。
- **提早進入**：條件 1–3 成立時，`_ResumeScreen` 在驗證期間多顯示「離線瀏覽」按鈕。按下後立刻進入，`/user` 驗證照樣在背景繼續（§5.5）。
- **金鑰 unavailable、標記讀不到、index 解不開、App 鎖定設定讀取失敗**：沒有離線模式，顯示現有的恢復失敗畫面與重試。

### 5.2 身分判定與拒絕標記（L2、Codex C1、Opus C-1）
- **`identityCheck()`**：C3c 新增於 `lib/core/offline_repository_api.dart`（`part of 'gitlab_api.dart'`），取代 `initialize` 與探查中的 `currentUser()`。
  - 送 `GET /user`，同源、不轉址、計入 meter、遵守 `rateBudget`。自己有界地讀取錯誤的 body（最多 4 KiB）來判斷是不是 GitLab JSON，不經過會丟掉 body 的 `_send`（§3.14，R2）。
  - 401 時嘗試 OAuth 換證一次：
    - 換證請求本身是網路錯誤 → 沒有判定；
    - 換證被拒（`invalid_grant`）→ 401 判定。
  - 回傳 sealed 的 `IdentityVerdict`：

  | 結果 | 條件 |
  |---|---|
  | `ok(user)` | 200，GitLab JSON，有整數 `id` |
  | `refused401` | 401，而且是 GitLab JSON 的錯誤 |
  | `refused403` | 403，而且是 GitLab JSON 的錯誤 |
  | `noVerdict(kind)` | `network`、5xx、429、3xx、2xx 但不是 GitLab JSON |
  | `unknown(kind)` | 其他（含不是 GitLab JSON 的 401／403） |

- **判定的處理**（不論發生在 `initialize`、`select`、探查，或提早進入後的背景驗證）：

  | 判定 | 處理 |
  |---|---|
  | `ok`，user id 相符 | 刪除 `offline_refused.v1.<A>`（如果存在）；由呼叫端決定是否 `_activate` |
  | `ok`，user id 不符 | 視同身分拒絕：同步柵欄 A，執行帳號層級的清除，刪除 last-active（取代目前合成的 `unauthenticated`，Opus m17） |
  | `refused401` | 同步柵欄 A，執行帳號層級的清除，刪除 last-active |
  | `refused403` | 先寫入 `offline_refused.v1.<base64url(A.key)>`（值是 UTC 時間），寫入成功才離開，資料保留。**寫入失敗**時，改執行帳號層級的清除（fail closed，L2） |
  | `noVerdict`、`unknown` | 不寫入，也不清除 |

- **401 與 user id 不符**：資料被刪除，自然不可能再進入。清除還沒完成時，帳號已經處於 `cleaning`，同樣無法進入。
- **拒絕標記的生命週期**：
  - 只會被**同一個數字 user id 的 `ok` 判定**刪除。B8 的同帳號重試**不會**刪除它，除非重試本身得到 `ok`。
  - 帳號層級的清除也會刪除它。
  - 列入 secure inventory 與 B1 的掃描。

### 5.3 信任的身分與理由（Codex I6，照實寫出）
- **信任的對象**：「這台裝置上一次成功驗證過、之後沒有被拒絕的帳號 A」。**不代表** A 目前仍然有效。
- **可以接受的理由**：
  1. 離線模式不送出任何內容讀取，只有隔離的 `/user` 探查（§5.6）。
  2. 顯示的都是 A 在已驗證的 session 中下載的資料，以 A 的 ThisDeviceOnly 金鑰加密，AAD 綁定 `A.key`。
  3. 伺服器明確拒絕過的身分（401、403、user id 不符）會被封鎖或刪除（§5.2）。
- **新增的曝露**（沒有 C3 時不存在的）：
  - token 被撤銷、帳號被停用、被移出專案時，只要裝置一直不連 GitLab，就能讀到已保存的快照。
  - 30 天上限以裝置時鐘計算，持有者可以把時鐘調回去。它是衛生措施，**不是**安全邊界。
- **這個殘留**寫進 AGENTS.md、CLAUDE.md 與保存前的知情說明（§6.3）。

### 5.4 AGENTS.md:9 的替換文字（C3c 一併提交；逐句對照 Opus C-2 與 Codex C1 第 3 點）
- **原文**：
> An instance includes scheme, host, port and installation subpath. Account identity is instance plus numeric user ID. Project identity also includes numeric project ID. Bind caches and responses to the account generation. Never activate or display a stale response after switching accounts.

- **替換為**：
> An instance includes scheme, host, port and installation subpath. Account identity is instance plus numeric user ID. Project identity also includes numeric project ID. Bind caches and responses to the account generation. Never activate or display a stale response after switching accounts. An account becomes active, with an API client, only after a fresh `/user` returns its numeric user ID. The one exception is the offline read-only mode, in which the last account validated on this device opens its own encrypted offline repository snapshots without that check. The mode may start only during or after auto-resume, while `/user` has given no identity verdict: a transport error, a 5xx or 429, a redirect, or a successful response that is not GitLab JSON (as from a Wi-Fi sign-in page). A 401 or 403 that is not GitLab JSON is no verdict for deletion and does not start the mode. It also requires that the account has no recorded identity refusal and was validated within 30 days by the device clock; the 30 days are a hygiene limit, not a security boundary. The mode runs under a new generation, behind the app lock, with no account API client, no repository or account reads, no writes to GitLab and no AI. Its only network requests are an isolated `/user` check for that account and, for OAuth, at most one token refresh whose rotated credential is saved (anonymous app-update checks are separate). Its only local writes are deleting snapshots, recording that check's verdict and saving that rotated credential. A GitLab 401 or a different user ID ends the mode, makes the account's read cache and snapshots unreadable at once, and deletes them through the read-cache clear sequence. A 403 ends the mode and keeps the data, but records a refusal that blocks the mode until a later successful `/user` for that user ID. Returning online for that account always validates `/user` first; switching to another account is a sign-out and needs no network.

- **對照**：

  | 審查指出的問題 | 替換文字中的對應 |
  |---|---|
  | 提早進入（按鈕）在還沒有判定時就進入 | "during or after auto-resume, while `/user` has given no identity verdict" |
  | 403 之後再次進入 | "records a refusal that blocks the mode until a later successful `/user`" |
  | 30 天不是安全邊界 | "by the device clock … a hygiene limit, not a security boundary" |
  | 探查與更新檢查都會連網 | "Its only network requests are an isolated `/user` check … and, for OAuth, at most one token refresh whose rotated credential is saved (anonymous app-update checks are separate)" |
  | 不是 GitLab JSON 的 401／403（§5.2 歸為 `unknown`） | "A 401 or 403 that is not GitLab JSON is no verdict for deletion and does not start the mode"；刪除只限 "A GitLab 401 or a different user ID"（v2.1，R1） |
  | 「使用其他帳號」不需要驗證 | "switching to another account is a sign-out and needs no network" |
  | 清除不阻擋 UI | "unreadable at once … deletes them through the read-cache clear sequence" |
  | App 鎖定 | "behind the app lock" |
  | 本機的刪除 | "Its only local writes are deleting snapshots, recording that check's verdict and saving that rotated credential" |
  | Wi-Fi 認證頁（L4） | "a redirect, or a successful response that is not GitLab JSON" |

- **AGENTS.md:15 的補充**（C3b，列出所有刪除時機，Opus m19）：
> …and explicitly saved offline repository snapshots: text files up to 2 MiB and images up to 10 MiB at a confirmed commit SHA, encrypted per account with their own key under `offline_repo/`, excluded from backup. They are deleted with the account's read cache: on every session exit (switch, sign-out, removal), a final 401 or different user ID, "clear cache", or turning the offline cache off. A project's snapshots are deleted when GitLab refuses that project (403/404) or its repository (403). A `/user` 403 keeps them but blocks offline use until a later successful `/user`.

### 5.5 session 的機制（Opus I-3、Codex C1 第 2 點）
- **`initialize`（ticket T）的流程**：
  1. 決定 A 之後，同時開始 `identityCheck()` 與 `OfflineGate.check(A)`。
  2. **自動進入**：判定是 `noVerdict`、而且資格成立 → `_enterOffline(A, ticket: T)`。
  3. **提早進入**：使用者按「離線瀏覽」→ `_enterOffline(A, ticket: T, early: true)`，`identityCheck` 繼續跑。
- **`_enterOffline` 做的事**：
  - **不取新的 ticket**，把 T 交給 `offline.validationTicket`；
  - `initializing = false`、`resuming = false`、`resumingAccount = null`；
  - `diskRetainedAccountKey = A.key`；
  - generation++；
  - C3 協調器 `closed → offlineReadOnly`。
  - `initialize` 的 `finally` 在 `offline != null` 時不重設狀態；candidate 在判定處理完之後關閉。
- **`main.dart` 的 build**：先判斷 `session.offline != null`，再判斷 `resuming` 與 `initializing`（`main.dart:248`）。
- **背景判定的處理**：只有 `offline?.account.key == A.key`，而且 `offline.validationTicket` 仍是目前的 ticket 時才處理：
  - `ok` 且相符 → 只把橫幅改成「已恢復連線」；
  - `refused401`、user id 不符、`refused403` → 依 §5.2 處理，然後離開；
  - `noVerdict` → 排下一次退避。
- **切換之後的遲到結果**：使用者按「使用其他帳號」→ `endSession()` 會 `++_operation`，A 的遲到結果因 ticket 過期而丟棄，candidate 關閉。此時 A 的資料已經由 D1 清除，所以丟棄 401 或 403 不會留下漏洞；遲到的結果也不可能清除 B。
- **探查是 single-flight**：同一時間只有一個驗證在跑。手動重試時：
  - 有驗證在跑 → 加入它（按鈕顯示轉圈）；
  - 沒有 → `++_operation`，記成新的 `validationTicket`。
- **離線模式中的守衛**：`select`、`connect`、`connectOAuth`、`remove` 在 `offline != null` 時直接返回。離開的方式只有「使用其他帳號」、切換到線上，以及判定的結果。
- **限流**：每個離線 session 有一個 `GitLabRateBudget`，注入每一個 candidate（`GitLabApi` 的 `rateBudget` 參數，C1a: `gitlab_api.dart:159`）。探查在 `retryAtFor(global)` 之前不送出（Opus m13）。
- **30 天的前景重查**（Codex I6）：
  - app 回到前景時，以及在前景每一小時，重新計算 `now − lastValidatedAt`；
  - 超過 30 天就離開到登入畫面，資料保留。

### 5.6 離開離線模式
| 情況 | 動作 |
|---|---|
| 背景探查 `ok` 且相符 | 橫幅改成「已恢復連線 · 切換到線上」，關閉 candidate |
| 按「切換到線上」或「重試連線」 | 重新跑一次 `identityCheck()`，`ok` 且相符 → `offline = null`、`_activate(A, candidate)`（generation++、`bindReadCache`、更新 `lastValidatedAt`），再設 `ResumeTarget(projectId, resource: 'repository')`。只開到專案的檔案分頁根目錄，既有的 case 在 `authenticated_app.dart:767-773` |
| `refused401` 或 user id 不符 | **同步**：`offline = null`、generation++、A 的柵欄進入 `cleaning`（內容立刻讀不到）。之後依 §4.4 在背景清除，並刪除 last-active。訊息先顯示「登入已失效，正在刪除此帳號的離線資料」；清除完成才改成「已刪除」，失敗則顯示「將在下次啟動時重試」（Codex C1 第 4 點） |
| `refused403` | 依 §5.2 寫入拒絕標記，然後離開到登入畫面，資料保留 |
| `unknown` | 離開到登入畫面，保留資料，不寫標記 |
| `noVerdict` | 留在離線模式，排下一次退避 |
| 「使用其他帳號」 | 先跳 D1 確認框 → `endSession()`。`_commitSignOut` 的離開帳號是 `active?.key ?? offline?.account.key ?? resumingAccount?.key ?? diskRetainedAccountKey`，**必須在函式開頭、`resumingAccount = null`（`session_controller.dart:612`）與 `active = null` 之前讀取**。先柵欄、再寫標記，然後清除，全程不需要網路 |
| 30 天到期 | 離開到登入畫面，保留資料 |

- **探查的觸發**：手動（3 秒內重複按只算一次）、回到前景、退避（15 秒、30 秒、60 秒、2 分鐘，之後每 5 分鐘一次；只在前景）。

### 5.7 協調器在 `offlineReadOnly` 的權限（Codex I5）
- **允許**：
  - 讀取 C3 的 index、tree、blob；
  - 受柵欄保護的**明確**刪除：刪除單一快照（先刪 tree 檔、再寫 index、設 `gcPending`），以及全部刪除（C3 命名空間清除）。
- **不允許**：任何背景維護（恢復、GC、遷移、清 `tmp`）、寫 blob、寫 C2、建立金鑰、更新 `lastValidatedAt`。

### 5.8 網路邊界（L3、Codex C4）
- **`NetworkBoundary`**（`lib/shared/network_boundary.dart`）是一個 InheritedWidget，模式為 `online` 或 `offlineSnapshot`。`OfflineApp` 的根是 `offlineSnapshot`。
- **在 `offlineSnapshot` 模式下，下列入口一律拒絕**（不產生任何副作用，顯示「離線時無法開啟」；debug 時加 assert）：
  - `openExternal`（`lib/shared/external_link.dart`）；
  - `ResourceShareButton`，以及任何系統分享（`resource_share.dart:69-83`）；
  - `showAttachmentDownloadSheet`；
  - `InAppLinks` 中需要 API 的導覽；
  - `MarkdownMediaLoader` 的 upload、external 與儲存庫網路路徑。
- **快照用的媒體載入器 `MarkdownMediaLoader.snapshot(SnapshotMediaSource)`**：
  - 沒有 `GitLabApi`；
  - 它的外部 Dio 換成一個 **`_BlockedAdapter`：任何請求都丟錯並計數**，所以就算有遺漏的呼叫，也會失敗，不會連網；
  - 只提供通過來源政策的快照 blob。
- **快照媒體的來源政策**（`SnapshotMediaPolicy`，純 Dart，可測）：只有同時滿足下列條件，才讀快照裡已保存的 blob：
  - instance 與帳號等於快照的帳號；
  - 而且符合下列其中一種：
    - **相對參照**：以快照為 base 解析，`projectId` 等於快照的數字 id，ref 等於快照的 SHA；
    - **同 instance 的絕對網址**：專案路徑等於快照保存時的 `path_with_namespace`，ref 等於快照的 ref 名稱或 SHA；
  - 檔案路徑在 `subPath` 之內，狀態是 `saved`，種類是 `image`（SVG 則是 `text`）。
  - 跨專案、跨 ref、uploads、外部來源、未保存的內容 → 占位。**離線時一律不退回網路**；只有路徑相同不足以證明來源相同。
- **連結**：
  - 能解析到**同一個快照**、狀態是 `saved` 或 `tree` 的路徑 → 在本機導覽；
  - 頁內錨點 → 捲動；
  - 其他一律開一個 sheet，顯示完整的網址，只有「複製」，沒有開啟、也沒有分享。
- **`MarkdownView` 新增參數 `snapshot: SnapshotMarkdownContext?`**：攜帶 reader、政策、`NetworkBoundary` 的模式。**既有的 `offline` 旗標（AI 用）完全不動**，AI 的 Markdown 行為不變（§8.3 有回歸測試）。
- **在線上看快照**（使用者在線時開「離線版本」）：
  - 模式是 `online`；
  - 儲存庫圖片只從快照讀（依政策），其他媒體與連結照線上的既有行為；
  - 不呼叫 `api.rawFileBytes`。

### 5.9 App 鎖定的綁定（Codex I6、Opus m14）
- **`OfflineApp` 用同一個 `appLockProvider` 的 controller 包 `AppLockGate`。**
- **新增 `AppLockController.loadFailed`**：讀取設定時丟出例外就設為 true，而不是只把 `enabled` 設成 false（`app_lock.dart:108-121` 的現有行為保留給線上）。
- **離線模式的規則**：
  - **進入的前提**：`loaded` 為真，而且 `loadFailed` 為假（§5.1）；
  - **進入之後**：設定若變成讀取失敗，畫面改成「無法讀取 App 鎖定設定」加上重試，不顯示任何內容；
  - **重新驗證失敗**：維持鎖定的遮罩。
- **邊界照實寫明**：Gate 是畫面遮罩。已經解密的內容在遮罩下仍在記憶體裡；鎖定不會清除它，也不阻止解密（V16）。

### 5.10 威脅與殘留（照實寫出，Codex I6、Opus m18）
| 威脅 | 有離線模式時 | 對策與殘留 |
|---|---|---|
| 手機遺失、已解鎖、沒開 App 鎖定 | token 仍然有效時，原本就能在線上讀寫；token 被撤銷或帳號被停用後，**仍能**在 30 天內（或調時鐘後）離線讀取快照 | **新增的殘留**，寫進知情說明與文件；建議開啟 App 鎖定 |
| 手機遺失、已解鎖、開了 App 鎖定 | `OfflineApp` 在 Gate 之下；設定讀取失敗時不顯示內容；離開 1 分鐘後重新上鎖 | Gate 只是遮罩（§5.9） |
| 手機遺失、已上鎖，或被鑑識 | ciphertext 加上 ThisDeviceOnly 金鑰、iOS 檔案保護、Android FBE；排除備份 | 同 C2 |
| token 被撤銷 | 連線之後 401 → 清除；一直離線則見第一列 | 遺失手機請用裝置的遠端清除 |
| 帳號被封鎖或停用（403） | 拒絕標記封鎖離線模式，直到下一次成功驗證；資料保留 | 還沒連線、尚未收到判定之前，仍可讀取（同第一列） |
| 被移出專案、專案被刪除 | 連線後，下一次探查或 `AccessLoss` 事件刪除 | §3.14 |
| 惡意的 archive | 路徑不會變成檔案系統的路徑；有各種上限；解析有界 | §3.6、§8.1 |
| 原始碼含有機密或個資 | 快照裡也有；沒有「機密」欄位可以篩選 | 保存前的知情說明寫明 |
| force-push 移除了機密 | 舊快照仍留著 | 使用者當時有讀取權，和 git clone 相同；更新後舊內容會被 GC |
| 移除 app | Android 刪除檔案；iOS 的 keychain 項目可能留下 | 啟動掃描清除孤兒金鑰（B1） |

### 5.11 shell 的配套
- **`_syncShortcuts`**（`main.dart:215-221`）：離線模式 `bind(null)`，但 `_sessionWasActive` 視為 true，這樣離開時會清掉已發布的 shortcut。
- **`IncomingLinks`**：離線 shell 不取走連結，橫幅下方顯示「連線後會開啟 1 個連結」。
- **`_openResumeTarget`**：使用既有的 `'repository'` case，不新增。

---

## 6. UI 行為與狀態（Claude 實作，這裡只描述行為）

通則：
- 文字全部走 l10n；GitLab 的文字一律逐段 `isolated()`。
- 狀態一律是圖示加文字；刪除走 `confirmAction`；失敗用 `showFailure` 或 `FailureNotice`。
- 版面要通過 320 dp、2× 字級、de、ar、鍵盤升起。

### 6.1 `RepositoryReader` 與擁有者身分（E11）
- **介面**（`lib/core/repository_reader.dart`）：
  - `owner`：`ReaderOwner(accountKey, generation, instanceKey, projectId, sha, snapshotId?, subPath)`；
  - `tree(path, {next})`、`text(path)`、`bytes(path, {maxBytes})`、`entryState(path)`；
  - `capabilities`：`{edit, history, blame, refresh, ai, webFallback, share}`，由 reader 宣告，**不靠 widget 是否拿到某個 nullable 的 API 來判斷**。
- **線上實作**包裝現有的 `records`、`textFile`、`rawFileBytes`，行為與請求數不變（由測試證明）。
- **快照實作** `lib/core/offline/snapshot_reader.dart` 的 capabilities 全部是 false。每次回傳之前比對帳號 epoch、`projectEpoch` 與 generation。
- **改經過 reader 的畫面**：`RepositoryTab`、`RepositoryFilePage`、`RepositoryReadmeCard`、`MarkdownView`（§5.8）。
- **純呈現的元件**：`lib/shared/code_text_view.dart`，負責行號、搜尋、換行、上色。refresh、AI、歷史、blame、編輯、刪除、網頁 fallback、`ResourceShareButton`（`repository_page.dart:1508-1629`）一律依 capabilities 顯示，快照時全部不顯示。
- **「複製連結」**只用 Clipboard，不經過系統分享。
- **重構方式**：先補「線上 reader 在重構前後的畫面與請求數一致」的 widget 測試，再搬移程式碼。

### 6.2 保存的入口
- **專案頁右上角 ⋮**（`project_page.dart:516-540`）：「離線保存…」，或「離線版本…」。
- **檔案分頁的 ref 列**（`repository_page.dart:329-418`）：一個圖示按鈕，四種狀態：

  | 狀態 | 顯示 |
  |---|---|
  | 沒有快照 | 「離線保存」 |
  | 保存中 | 進度環「保存中 n%」 |
  | 已保存，SHA 相同 | 「已離線保存」；有未保存的檔案時，加上小數字 |
  | 已保存，SHA 不同 | 「有新版本」 |

  - 在子資料夾中按下時，sheet 預選「此資料夾」。
- **網路失敗時**：同一專案有完整的快照，`FailureNotice` 多一個動作「檢視離線版本（保存於 …）」。

### 6.3 保存的 sheet 與第一次的知情說明（E19、Codex I6）
- **第一次的知情說明**：帳號還沒有 index 時，先跳一個對話框，條列：
  - 這是存在本機的副本，以帳號的金鑰加密；
  - 只屬於 @user，切換帳號、登出、移除帳號、「清除快取」時都會刪除；
  - **離線時無法得知權限是否已被撤銷**，30 天的上限不是撤銷機制；
  - 上游的 force-push 或刪除，不會收回已保存的內容；
  - 原始碼可能含有機密，建議開啟 App 鎖定。
  - 按鈕是「保存」與「取消」。確認之後，把時間記到 index 的 `consentAt`。
- **之後的 sheet**：
  - 專案名；版本（圖示、名稱、`@ 短 SHA`，解析時轉圈）；
  - 範圍：「整個儲存庫」或「此資料夾」；
  - 內容說明：「文字檔（每檔 2 MiB 內）與圖片（10 MiB 內）；其他二進位檔、議題、MR、CI 不保存」；
  - 一行 D1 說明，加上「詳細說明」連結，重新打開上面的對話框；
  - 容量：「已使用 X / 600 MB」。
- **擋住保存的狀態**（主按鈕停用並寫出原因）：
  - 離線快取已關閉；
  - 安全儲存區暫時無法使用；
  - GitLab 限流中（只有 reset 時刻已知時，才寫「約 N 分鐘」）；
  - 等待額度；
  - 新增已達 30 個，或容量已滿；
  - 需要較新版本的 app。

### 6.4 保存列表（我的 › 儲存與快取 › 離線專案）
- **入口**：C2 的「儲存與快取」頁中的一列，「離線專案 · N 個 · X MB」。
- **頁首**：「N 個專案 · X / 600 MB」，加上 D1 說明。
- **一次性的說明**：有 `removedNotice` 時顯示（文字見 §3.14）。
- **每一列**：
  - 專案名、`path`；ref 的圖示與名稱、`@ 短 SHA`；子資料夾；「保存於 <相對時間>」、大小。
  - 狀態 chip（圖示加文字）：
    - 已保存；
    - 已保存 · k 個未保存；
    - 保存中 n%（另有一條線性進度，寫出階段）；
    - 排隊中；
    - 等待額度；
    - 等待限流解除；
    - 已暫停；
    - 已中斷；
    - 失敗：<原因>；
    - 有新版本；
    - 分支已不存在；
    - 保存的提交已不在 GitLab 上。
- **操作**：
  - 點一下：開快照；
  - ⋮：更新（只在線上）、暫停、繼續、取消、刪除、在線上開啟（只在線上）。
- **頁尾**：「全部刪除離線專案」（確認框寫出數量與大小），以及 App 鎖定的建議。
- **其他狀態**：空狀態、安全儲存區無法使用、需要較新版本。

### 6.5 快照瀏覽
- **頁首**：「離線版本 · <ref> @ <短 SHA> · 保存於 <日期>」，各段分別 isolate。
- **檔名篩選**：在本機的索引上篩選，不連網路。
- **目錄列**：
  - 未保存的檔案用較淡的顏色，尾端顯示原因：超過大小、二進位檔、封存檔中沒有、內容與提交不符、symlink 或 submodule、不支援的項目。
  - 點未保存的檔案：在線上 → 開該 SHA 的線上檔案頁；離線 → 用 sheet 說明原因。
- **README 卡片**：沿用 `findReadmePath`（`repository_page.dart:40`）與 256 KiB 的渲染上限。
- **`.gitattributes` 的提示**：依 §3.7。
- **檔案頁**：使用 `CodeTextView`，依 capabilities 顯示功能（§6.1）。

### 6.6 Markdown（快照）
- 圖片依 §5.8 的政策：符合的顯示快照內容；不符合的顯示占位：
  - uploads 與外部圖片：「離線時不載入」；
  - 未保存的：「此圖片未保存」。
- 連結依 §5.8：同一快照就在本機導覽，其他只能複製網址。

### 6.7 離開 session 前的確認（D1；Codex I8、Opus C-3）
- **併入既有的 `_leave`**（`authenticated_app.dart:875-919`）：
  - 新增參數 `LeaveIntent(kind, target?)`；
  - 在 `AiSwitchGuard` **之前**、任何停止、清除或修改 session 的動作之前，先跳 `confirmOfflineLoss`：「<動作> 會刪除 @current 的 N 個離線專案（X MB）」，按鈕是「取消」與「繼續並刪除」。
  - 取消就什麼都不做。這樣兩個確認框不會互相繞過。
- **所有入口**：
  - `_leave` 涵蓋的 `:1118`、`:1135`；
  - `account_sheet.dart:36`、`:45`；
  - `workspace_ui.dart` 的 `endSessionFrom`（`:16-25`）與 `FailureNotice` 的切換帳號（`:620`）；
  - `authenticated_app.dart:1363`、`:1386`；
  - 移除帳號；
  - 離線 shell 的「使用其他帳號」；
  - `_ResumeScreen` 的「使用其他帳號」（`main.dart:285`），離開的是 `resumingAccount`；
  - 登入畫面點選另一個帳號（`login_screen.dart:220`），離開的是 `diskRetainedAccountKey`；
  - 登入畫面用 PAT 或 OAuth 新增帳號（B11）：「若登入的是其他帳號，@A 的 N 個離線專案會被刪除」。
- **不跳確認框的情況**：
  - 重選目前的帳號（不可點，M-4）；
  - 在登入畫面點選 `diskRetainedAccountKey` 本身（B8 的重試）。

### 6.8 離線 shell 與橫幅
- **橫幅**（`cloud_off` 圖示加文字）的第一行依進入原因而不同：
  - `network`：「離線 · 只能瀏覽已保存的專案」；
  - `server`：「GitLab 暫時沒有回應 · 只能瀏覽已保存的專案」；
  - `rateLimited`：「GitLab 限流中 · 只能瀏覽已保存的專案」，reset 時刻已知時才加「約 N 分鐘」；
  - `redirectBlocked`／`invalidResponse`：「網路可能需要登入（例如 Wi-Fi 認證頁）· 只能瀏覽已保存的專案」。
- **橫幅的三種狀態**：
  - 上述文字，附「重試連線」；
  - 探查中：轉圈，按鈕停用；
  - 已恢復連線：附「切換到線上」。
- **帳號列**：「@user · host · 上次驗證：N 天前」。
- **主體**：§6.4 的列表，去掉線上專用的操作。
- **選單**：「管理離線專案」、「使用其他帳號」。
- **沒有**底部導覽、搜尋、AI。
- **`_ResumeScreen`**：資格成立時，加上「離線瀏覽」。

### 6.9 「清除快取」的確認框（L1）
- 內容：「會刪除自動快取與 N 個離線專案（共 X MB），這個動作無法復原。」
- 按鈕：「取消」與「清除」。
- 關閉「離線快取」開關時，用同樣的確認框。

### 6.10 RTL 與 320 dp
- **小於 360 dp**：狀態 chip 換到標題下一行；橫幅的按鈕換到文字下方；專案路徑最多 2 行。
- **麵包屑**：沿用 `repository_page.dart:420-487`。
- **ar**：短 SHA、路徑、`@user` 每段各自 isolate，數字與大小走 l10n 的參數。
- **進度的語意**：每跨過 25% 才以 liveRegion 宣告一次。

---

## 7. MR 拆分、檔案所有權與相依（Codex I8）

### 7.1 順序與前置條件
```
C1a（!103，f7d6106）→ C1b-1 → C1b-2 → C2（已併入 B1–B12）→ C3a → C3b → C3c → C3d（選用）
```
- **前置條件以「實際合併的 commit」為準，不以封包標籤為準**：
  - C3b 開工前，MR6b-2 必須已經合併進 `main`，記下那個 merge commit；
  - 用 `git diff <C3a 的基底>..<該 commit> -- lib/l10n lib/features/workspace/repository_page.dart` 審查後續的差異（Codex I8 指出 packet 14 之後，l10n 仍有變動）。
- **每次 rebase 之後**（C1b-2、C2、C3a 依序承接），重跑線上 reader 的一致性測試與 §8 的交界測試。
- **審查**：第一輪完整審查；之後只由 Opus 核對 Critical 與 Important 的修正；Minor 開 follow-up。C3c 動到 AGENTS.md:9，第一輪必須完整審查。

### 7.2 C3a：核心（Codex，沒有 UI）
- **相依**：C1a、C1b-2、C2 已合併，而且 C2 已採納 B1–B11。
- **擁有的檔案**：
  - 新增，`lib/core/offline/`（純 Dart）：
    - `tar_stream.dart`、`git_object_id.dart`、`snapshot_schema.dart`；
    - `snapshot_store.dart`：index、tree、blob、提交順序、恢復、GC、預算；
    - `snapshot_worker.dart`：isolate、回壓、停止協定；
    - `snapshot_save.dart`：job、佇列、lease、節奏；
    - `snapshot_probe.dart`；
    - `snapshot_reader.dart`；
    - `snapshot_media_policy.dart`；
    - `offline_repository_coordinator.dart`：狀態、epoch、維護鎖、命名空間。
  - 新增 `lib/core/repository_reader.dart`：只放介面與線上實作。
  - 新增 `lib/core/offline_repository_api.dart`（`part of 'gitlab_api.dart'`）：`repositoryTreePage`、`repositoryArchive`、`AccessLoss` 的分類與 sink、每天第一次 2xx 的 hook。`identityCheck()` 也放在這裡，但由 C3c 加入。
  - `lib/core/gitlab_api.dart`：
    - 一行 `part`；
    - `_send`、`_rawFileBytes` 錯誤分支中呼叫 `AccessLoss` 分類的幾行；
    - 若 C1b-2 沒有把 allocator 放在這裡，就加上 `runBudget`。
  - `lib/features/auth/session_controller.dart`：只有 `_activate` 中綁定 sink 的那一行，以及 `_client` 的 `rateBudget` 參數（`ApiFactory` 與測試替身配合）。
  - C2 協調器檔中，C3 命名空間的實作。C2 的介面（B4）由 C2 提供；C3a 只實作 namespace 這一側（Opus m21）。
  - `lib/shared/markdown_media_source.dart`：`MarkdownMediaLoader.snapshot` 與 `_BlockedAdapter`，只有邏輯。
  - `tool/bootstrap.py`：iOS 的 `mergeline/backup` channel（§4.8），以及它的 `tool/tests` 測試。
  - 新增 `lib/features/offline/offline_repositories.dart`：給 UI 用的 `ChangeNotifier` adapter，**不承擔任何安全事件**。
  - 測試：
    - `test/offline/*_test.dart`；
    - `test/fixtures/offline/*.tar.gz`（由 `tool/fixtures/make_offline_archives.sh` 用真正的 `git archive` 產生）；
    - `tool/tests/test_offline_boundaries.py`。
- **不碰**：`lib/core/workspace_api.dart`、`lib/core/ai/**`、`lib/features/ai/**`、widget、`lib/l10n/**`。

### 7.3 C3b：保存與瀏覽 UI（Claude）
- **相依**：C3a；C2 的「儲存與快取」頁；MR6b-2 的 merge commit（§7.1）。
- **擁有的檔案**：
  - 新增：
    - `lib/features/offline/save_sheet.dart`、`offline_consent_dialog.dart`、`offline_projects_page.dart`、`snapshot_browser_page.dart`、`offline_status.dart`；
    - `lib/shared/code_text_view.dart`；
    - `lib/shared/network_boundary.dart`。
  - 修改：
    - `lib/features/workspace/repository_page.dart`；
    - `project_page.dart`；
    - `lib/shared/markdown_view.dart`：新增 `snapshot` 參數，`offline` 不動；
    - `lib/shared/external_link.dart`、`lib/shared/resource_share.dart`：檢查 boundary；
    - `lib/features/shell/authenticated_app.dart`：`_leave` 的 `LeaveIntent`、儲存列；
    - `account_sheet.dart`、`lib/shared/workspace_ui.dart`；
    - C2 的設定頁：清除與開關的確認框（L1）；
    - `lib/l10n/arb/*` 與產生的檔案。
  - 文件：AGENTS.md:15、CLAUDE.md 的 Persistence 段（§10）。

### 7.4 C3c：離線唯讀模式（Codex 做 session，Claude 做 shell）
- **相依**：C3b。
- **Codex 擁有**：
  - `session_controller.dart`：
    - `offline` 狀態、`_enterOffline`；
    - 判定的處理、`identityCheck` 的接線；
    - B8 的同帳號重試、B10 的 `diskRetainedAccountKey`、B11 的 `_activate` 清除；
    - `_commitSignOut` 的離開帳號判定、離線模式中的守衛。
  - `lib/core/offline_repository_api.dart` 中的 `identityCheck()`。
  - 新增 `lib/features/offline/offline_gate.dart`：資格判定、single-flight 探查、退避、前景重查。
  - `lib/features/security/app_lock.dart`：`loadFailed`。
  - 協調器的 `offlineReadOnly` 轉換。
  - 拒絕標記的儲存。
  - 測試：`test/offline_session_test.dart`。
- **Claude 擁有**：
  - `lib/main.dart`：build 的分支、`_syncShortcuts`、`_ResumeScreen`；
  - 新增 `lib/features/offline/offline_app.dart`；
  - `lib/features/auth/login_screen.dart`：確認框；
  - l10n；
  - 文件：AGENTS.md:9，以及 CLAUDE.md 的 Session 段與 Persistence 段。

### 7.5 C3d（選用，以後再做）
- 在離線模式開放 C2 的快取列表與詳細頁（唯讀）。另寫計畫、另外審查。

---

## 8. 測試

### 8.1 單元測試（C3a）
- **tar**：
  - 用真正的 `git archive` 產生的 fixture：wrapper 目錄、目錄結尾的 `/`、子路徑的祖先目錄、submodule、symlink、長路徑（ustar `prefix` 與 pax `path`）、pax global 的 `comment`；
  - 手工構造的 fixture：
    - checksum：有號與無號；base-256；
    - pax `size` 改變 framing、pax 記錄長度不一致、pax 超過 64 KiB；
    - GNU `L`／`K` 超過上限，以及狀態只套用到下一筆；
    - 連續兩個 metadata；
    - typeflag `1`、`3`、`4`、`6`、`7` 依 size 跳過；
    - 結尾零區塊之後有非零資料、截斷、gzip trailer 被竄改、gzip member 之後還有資料；
    - `..`、絕對路徑、NUL、重複路徑；反斜線**合法**；
    - 非 UTF-8 的檔名（計入 `unmatched`，不中止）；
    - 處理量超過 1 GiB、壓縮後超過 300 MiB；
  - 任一錯誤都不提交任何東西。
- **驗證與正規化**：
  - SHA-1 的已知向量：空 blob `e69de29bb2d1d6434b8b29ae775ad8c2e48c5391`、`"hello\n"` → `ce013625030ba8dba906f756967f9e9ca394464a`；
  - SHA-256 的向量：在專案外的暫存目錄 `git init --object-format=sha256`，再用 `git hash-object` 產生，結果寫成常數（Codex m2；測試本身不呼叫 git）；
  - fixture 中的 `eol=crlf`、`ident` 經正規化後被接受；`export-subst` → `mismatch`；`export-ignore` → `missing`。
- **分類**：
  - 文字：2 MiB 與 2 MiB + 1、20,000 行與 20,001 行、NUL、不合法的 UTF-8、LFS pointer；
  - 圖片：10 MiB 與 10 MiB + 1；
  - 同一內容改副檔名、改 mode，會重新分類（Codex I4）。
- **tree**：
  - malformed、重複的路徑、type 與 mode 不一致、id 格式錯誤、父目錄缺少、不在子路徑之內；
  - 分頁不前進、重複的 token；
  - 錄下的真實 keyset `Link`（含 `id=`、`page=1`、`with_last_commit=false`）可以通過 client 自己的重建；
  - offset 只在伺服器回應明確給出時使用，401、403、404、429、400 不被當成降級的理由。
- **預算**（Codex C6）：大量長路徑、需要 JSON 跳脫的字元、SHA-256 的 id、最終欄位的增加；剛好在上限與上限加一。每個成功提交的快照，都立刻用正式讀取器讀回。
- **儲存層**：
  - 提交順序；去重；沿用時的驗證；損壞的 blob 在重新保存時被原子替換（Codex I4）；
  - AAD 錯、竄改、截斷、過大、symlink、目錄鏈中有一層是 symlink 都被拒絕；
  - envelope 剛好是上限加 29；
  - 解密後逐筆檢查欄位，只有 §4.3 列出的欄位。
- **GC 與競態**（Codex C3）：
  - 暫停在 blob rename 之後、tree 最終提交之前，刪除另一個快照並 GC → 暫停中快照的 blob 仍在；
  - GC 與新的提交交錯；
  - 取消與 finalizing 交錯；
  - 在 §4.5 每一步之後 kill process，重啟後確認可讀性與引用的完整性。
- **權限失效**（Codex C2）：
  - 從非快照的畫面收到 403；沒有任何列表訂閱者；
  - 403 和 blob rename、最終的 index 提交同時發生；
  - 最後確認被刪除的專案**不再出現**，而不只是 HTTP 被取消；
  - HTML 的 403／404 不觸發；
  - 可恢復的 OAuth 401 不觸發。
- **回壓與停止**（Codex I3）：
  - 假的串流以 credit 控制：在途不超過 1 MiB；
  - 回壓暫停 60 秒以上，watchdog 不觸發；沒有 credit 等待時 60 秒沒資料，就觸發；
  - stop 之後 ack；worker 卡住時 5 秒後 kill；kill 之後只剩暫存檔或孤兒 blob。
- **lease 與限流**：
  - 依端點斷言請求數（ref、tree 頁數、archive、tag 多出的 commit 讀取）；
  - `acquire` 回傳 null 時進入等待；granted 為 0 時立刻 release 再等待，等待期間 `activeLeases` 不增加（R3）；lease 用完換新的；結束時一定 release；
  - 沒有任何 `RateLimit-*` 標頭時（`limitingBucket == null`），列 tree 每 200 ms 一頁（R4）；
  - 429 之後依假時鐘自動繼續；`no-store` 的回應 → `serverForbidsStorage`。
- **清除**（Codex I5）：
  - 「清除快取」會 shred 兩把金鑰並刪除兩個目錄；
  - 全部刪除只動 C3；
  - 未知 schema、金鑰 unavailable 時，明確的清除照樣刪除；
  - 標記寫入失敗、金鑰刪除失敗時的規則（m-10）；
  - 「先柵欄、後標記」的順序；
  - C2 的維護與 C3 的更新、GC 同時進行；同帳號重試；ENOSPC。
- **AI 邊界**：`test_offline_boundaries.py`。

### 8.2 session 測試（C3c）
- **進入的組合**：
  - 判定種類（network、server、rateLimited、redirectBlocked、invalidResponse、unsupported、cancelled、HTML 的 401／403、GitLab JSON 的 401／403、user id 不符、非 `ApiFailure`）；
  - 乘上資格條件（拒絕標記存在或讀不到、沒有快照、金鑰 unavailable、30 天、未來的時間、鎖定設定未載入或讀取失敗）；
  - 只有預期的組合會進入。
- **拒絕的持久性**（Codex C1、Opus C-1）：
  - 403 → 關閉 app → 斷網冷啟動 → **不會**進入；
  - 同帳號重試仍是 403 → 仍然封鎖；
  - 之後得到 `ok` → 解除封鎖；
  - 拒絕標記寫入失敗 → 執行帳號層級的清除。
- **提早進入的三種結果**（Opus I-3）：背景回 200 → 只改橫幅；回 401 → 清除；回 403 → 封鎖。
- **切換之後 A 的遲到回覆**：被丟棄，B 不受影響。
- **B8**：在登入畫面重試同一個帳號、再次失敗、冷啟動之後，C3 的目錄仍在。
- **B11**：用 `connect` 新增帳號 B，A 的資料被清除；確認框有出現。
- **其他**：`_commitSignOut` 從離線模式離開，會清除正確的帳號；30 天在前景重查；退避與 `retryAtFor`；generation 的遞增。

### 8.3 widget 測試（C3b、C3c）
- **零外連**（Codex C4）：
  - 實際建立快照的 README 與檔案預覽；
  - 注入會記錄呼叫的 `GitLabApi`、外部 transport、launcher 與 sharer；
  - 在 `offlineSnapshot` 模式下，這四者的呼叫數都是 0；
  - 同名、但跨專案或跨 ref 的圖片不會被誤讀；
  - 合法的快照圖片會顯示；
  - 帳號切換之後，遲到的媒體不會顯示。
- **AI 回歸**：`MarkdownView(offline: true)` 的行為和改動前相同。AI 讀檔在有快照時，照樣送出網路請求（行為測試）。
- **鎖定**：`AppLockGate` 覆蓋 `OfflineApp`；設定未載入、讀取失敗、重新驗證失敗時都不顯示內容。
- **確認框**：§6.7 列出的每一個入口都會出現，而且出現在 AI 的 guard 之前。
- **重構前後一致**：線上 reader 的畫面與請求數和重構前相同。
- **狀態**：sheet、chip、知情說明、橫幅的每一種狀態；`.gitattributes` 的提示。
- **版面**：320 dp、2× 字級、de、ar、鍵盤升起。

### 8.4 故障注入
| 情境 | 注入方式 | 預期 |
|---|---|---|
| 保存到一半 app 當掉 | §4.5 的每一步之後、GC 中、命名空間清除中終止 | 依 §4.6 恢復；引用完整；舊快照完整 |
| 金鑰 unavailable | 啟動、保存前、資格判定時 | 不讀不寫；沒有離線模式；**明確的清除仍然刪除** |
| 磁碟已滿 | blob、tree、index 寫入時 errno 28 | `deviceFull`；舊快照完整；單一刪除先刪 tree 檔 |
| SHA 移動 | 保存期間分支前進 | 快照是原本的 SHA；之後顯示「有新版本」 |
| SHA 被 gc | archive 404，專案 200 | `versionGone`；其他快照保留 |
| 中途 403／404 | tree 第 3 頁、archive | GitLab JSON 的 403 → 專案柵欄並刪除；404 → 先探查 |
| 中途切換帳號 | 下載到一半時 `endSession` | 柵欄 → 停止 → 清除；新帳號下沒有任何檔案 |
| 時鐘偏差 | `lastValidatedAt` 在未來、時鐘往回調 | 未來視同過期；只是衛生措施，不視為安全邊界 |
| 串流中斷 | 讀到 40% 時斷線 | `interrupted`，自動重試一次，已存的 blob 驗證後沿用 |
| 回壓逾時 | worker 很慢、超過 25 秒 | 不被誤判為 `network` |
| 封存檔損壞 | §8.1 的各種損壞 fixture | 沒有任何提交 |
| 被竄改 | 翻轉 blob、tree、index 的一個 bit | 解密失敗；依 §4.6 處理 |
| 退回舊版 app | 寫 schema 2 之後用 v1 讀 | `needsNewerApp`；明確的清除仍然刪除 |
| 鎖定設定讀取失敗 | 讓 secure storage 讀取丟錯 | 不進入離線模式；已在離線模式時，不顯示內容 |
| 拒絕標記寫入失敗 | 403 時寫入丟錯 | 改執行帳號層級的清除 |

### 8.5 模擬器驗收（L8；只用公開專案；使用專案自己的模擬器）
- **建置**：依 `docs/ANDROID_SIGNING.md`、release inventory 與專案專用模擬器的規定建置與安裝；在實際提交的版本上跑 analysis 與測試；記錄 build variant、QA flags、APK 的 signer 與 receipt。這是實作時的義務，本計畫沒有執行。

| # | 步驟 | 證明什麼 |
|---|---|---|
| 1 | 先用匿名 API 讀取並記錄 `gitlab-org/cli` 的數字 id、實際的 default branch 與 SHA；再用匿名的 tree 讀取記錄該 SHA 的項目數與頁數 | 驗收的基準值。不寫死 2,227／23 |
| 2 | 用 debug 的 meter 紀錄（依端點的計數，不印路徑），保存整個儲存庫 | 請求數等於 ref 1 ＋ ⌈N/100⌉ ＋ archive 1；快照完整；未保存的數量與原因**只當觀測值** |
| 3 | 先確認 `docs` 存在，再保存 `docs` 資料夾 | 子路徑的 archive 與 tree 範圍 |
| 4 | 先用匿名 `x-total` 確認某個專案（例如 `gitlab-org/gitlab`）的項目數超過 5,000，再保存整個儲存庫 | 在列 tree 時中止，沒有送出 archive |
| 5 | 下載中暫停再繼續 | archive 請求 2 次；已存的 blob 驗證後沿用（debug 計數） |
| 6 | 用 `run-as` 在 app 的檔案中搜尋 README 中一段獨特的字串 | 找不到，證明沒有明文 |
| 7 | 用 `adb` 關閉 Wi-Fi 與行動數據並開啟飛航模式，**讀回**狀態（`cmd wifi status`、`dumpsys connectivity`）；冷啟動，在恢復畫面按「離線瀏覽」 | 提早進入；瀏覽、README、快照圖片；外部圖片是占位；連結只能複製 |
| 8 | 同上，但等待失敗、不按按鈕 | 自動進入 |
| 9 | 開啟 App 鎖定後重複第 7 步；切到背景超過 1 分鐘 | 鎖定畫面有覆蓋；重新上鎖 |
| 10 | 開回網路，回到前景 | 橫幅變成「已恢復連線」；切換後開到檔案分頁 |
| 11 | 「使用其他帳號」與「移除帳號」 | 確認框寫出數量；`run-as` 確認 `offline_repo/<hash>/` 已不存在 |
| 12 | 「清除快取」 | 確認框寫出數量；兩個目錄都不存在 |
| 13 | 量測：保存的時間、`dumpsys meminfo` 取樣的峰值 PSS、AES-GCM 的吞吐量 | 資源使用量（數值在實作後記錄） |

- **NOT_RUN（附原因）**：

  | 項目 | 原因 | 替代的證據 |
  |---|---|---|
  | `select(B)` 的 D1 路徑 | 只有一個測試身分，同一個使用者的 `Account.key` 相同 | §8.2 的合成測試 |
  | 終局 401、user id 不符、`/user` 403 | 公開專案無法製造真實的撤銷或封鎖 | §8.2 |
  | 權限撤銷、專案被刪除 | 同上 | §8.1 |
  | GitLab archive 的 `export-*` 與轉換行為 | 還沒確認哪個公開專案的 `.gitattributes` 含這些屬性 | §8.1 的 `git archive` fixture；驗收時若用匿名 files API 確認到候選專案，再加跑一步 |
  | Wi-Fi 認證頁 | 模擬器上沒有可控的 captive portal | §8.2 的合成測試 |
  | secure-storage 金鑰真的被刪除、flash 上的 crypto-shred | `run-as` 只看得到目錄 | 合成測試 |
  | 耗電 | 模擬器沒有真實的電池 | — |
  | iOS 實機（含排除備份） | 這台主機沒有 iOS 實機驗收環境 | §4.8 的 bootstrap 測試 |

- **範圍**：公開專案的 smoke 不等於 G0 要求的私有專案驗收，也不等於 Android／iOS 實機的接受驗收。

---

## 9. 風險與開放問題（附建議答案）

| # | 問題 | 建議 | 理由 |
|---|---|---|---|
| Q1 | GitLab archive 會套用哪些轉換 | 設計不依賴；驗證加可逆正規化；只記錄觀測值 | 文件沒有寫；Codex I2、Opus I-2 |
| Q2 | 自架 instance 的分頁 | client 自己建立 keyset 的續頁；只有伺服器明確給出時才用 offset | Codex I1；實測的 Link 會被現有驗證拒絕 |
| Q3 | 自架的 archive 限流 | 以 429 與標頭為準 | 文件只對 GitLab.com 寫了 5 次 |
| Q4 | 各項上限的數值 | 照 §3.8，放在常數裡，依驗收數據調整 | 已補上位元組預算與峰值 |
| Q5 | 30 天 | 保留，標明只是衛生措施，並在前景重查 | Codex I6 |
| Q6 | 另設「允許離線模式」的開關 | 不設，改成第一次保存時的知情說明 | Codex Q6 可以接受 |
| Q7 | `/user` 403 | 保留資料，持久封鎖，直到同一個 user id 的 `ok` | L2 |
| Q8 | 探查成功時自動切到線上 | 不要，用橫幅；拒絕的結果立即處理 | 兩位審查都同意 |
| Q9 | 全文搜尋 | v1 只做檔名篩選 | 同意 |
| Q10 | iOS 背景中斷 | 接受，自動重試一次 | 同意 |
| Q11 | 刪除單一快照後，殘留的 ciphertext | 接受並揭露；帳號層級的清除與全部刪除會 shred 金鑰 | 只剩單一刪除這一種殘留 |
| Q12 | 多帳號使用者切換就失去快照 | 依 D1 接受；所有入口一致地確認 | 擁有者決定 |
| Q13 | 自寫 tar | 採用，契約見 §3.6 | L6 的條件已滿足 |
| Q14 | 未保存的二進位檔 | 在線時開線上檔案頁 | 同意 |
| Q15 | C2 的前置條件 | B1–B11 是硬性前置條件，B12 是建議 | Opus C-3 |
| Q16 | `RepositoryController` 的文件錯誤 | 另開 issue | 同意 |
| Q17 | `RunBudgetAllocator` 只有 3 個 lease，保存工作佔掉一個 | 接受，AI 最多剩 2 個並行 | 保存一次只有一個 |
| Q18 | 不做 raw 補抓，`.gitattributes` 中有 eol 以外轉換的儲存庫，會有較多未保存的檔案 | 接受；在線時可以開線上版本 | V16 的 `no-store` |
| Q19 | 私有專案在登入狀態下的 archive 或 tree 回應，會不會帶 `no-store` | **已查證、關閉**（v2.1，R5）：gitlab.com 的私有專案，tree 與 archive 都沒有 `no-store`，`files/raw` 有（§1.1）。**撤回** v2「若出現 `no-store` 就修改 V16 適用範圍」的預先決定：修改 V16 是擁有者層級的契約變更，C3a 不能自行核准。若日後自架 instance 需要，列為需要另外審查的備案。E18 保留為執行時的守衛 | gitlab.com 上不需要；契約變更不屬於 C3a 的權限 |

---

## 10. 文件更新清單
- **AGENTS.md:9**：§5.4 的替換文字（C3c）。
- **AGENTS.md:15**：§5.4 的補充（C3b）。
- **CLAUDE.md 的 Persistence 段**（C3b），補上：
  - `offline_repo/<hash>/` 的配置、`offline_repo_key.v1.*`、HKDF 參數、AAD、envelope（29 位元組）；
  - 各項上限、提交順序、恢復、GC 的根；
  - `offline_repo_clear_pending.v1.*`、`offline_refused.v1.*`（C3c）；
  - 「清除快取」會刪除離線專案；iOS 排除備份；`lastValidatedAt` 與 `consentAt` 放在加密的 index 裡。
- **CLAUDE.md 的 Session 段**（C3c）：`offline` 狀態、沒有 `GitLabApi`、ticket 的移交、`NetworkBoundary`、`OfflineApp` 以 generation 為 key、包在 `AppLockGate` 之下。
- **secure inventory**：新增上述三種 key。
- **證據帳本**：§8.5 的結果；沒有跑的項目標 `NOT_RUN`。
- **Play 資料安全表**：不變，資料只存在裝置上。

---

## 11. Follow-up（第 2 輪審查第 6 節的 Minor；開 follow-up issue，不擋 C3a）
1. **worker 的 rename 不能同步比對 epoch**（§3.14、§4.4）：blob 的 rename 在 worker 裡做，讀不到 main 的 epoch。
   - 實際的保證來自 stop／ack／kill 屏障，加上 tree 與 index 只在 main 提交，文字要照實寫。
   - worker 改用同步的檔案 API（`renameSync`、`writeFromSync`），這樣 kill 之後不會有已經交給 IO 執行緒、還沒完成的操作。
2. **帳號層級清除與 main 在途的寫入**（§4.4）：
   - 維護鎖的持有者要加上「帳號層級清除」：刪目錄之前，先取得 C3 的維護鎖，或等它釋放。
   - 這不是安全漏洞，因為金鑰已先 shred，只會讓刪除需要重試。
3. **CLAUDE.md 的 Persistence 段**：last-active 的清除條件改成「GitLab JSON 的 401 或 user id 不符」（§5.1），§10 的文件清單要列這一句。
4. **§3.2 的 `CachedRead.dropped`**：讀 `.value` 會丟 `StateError`（C1a: `cached_read_api.dart:26-29`），當成 `cancelled` 或 `resolveFailed` 處理。
5. **`lastValidatedAt` 的 hook**（§4.3）：要求成功解析成 GitLab JSON 的 2xx，避免認證頁的 200 HTML 延長 30 天。
6. **別名解析造成的刪除**（§3.14）：路徑型的 403／404 只觸發以數字 id 的探查，不直接刪除，避免別名表過時（路徑被其他專案重用）時誤刪。
7. **`revoked` 集合何時清空**：專案恢復存取後（例如 IP 限制造成的暫時 403），要能在同一個 session 內重新保存。
8. **§3.7 第 1 步的判斷順序**：先判斷 mode `120000`，再看副檔名。
9. **§3.6 的「子路徑的祖先目錄」**也包括子路徑本身（`docs/`），用詞要改。
10. **§5.1 的鎖定設定**：設定還在載入時，有上限地等待，不直接判定不合格。
11. **線上 session 中 `/user` 回 403**（§3.14 的「帳號」那一列）：寫明 session 要不要結束。
12. **知情說明**（§6.3）：刪除時機補上「權限失效」與「關閉離線快取」。
13. **確認框的數量**（§6.7）：D1 清除已經完成時，清空 `diskRetainedAccountKey`，或 N 為 0 時不跳確認框。
14. **§8.5 第 4 步**：GitLab 對超大的集合可能省略 `x-total`。改用其他方式先確認項目數，或直接以 app 在列 tree 時中止作為證據。
15. **lease 的計量**：
    - 確認 OAuth 換證請求是否經過 `RequestMeter`；
    - lease 用完時，重送會讓 `consume` 丟 `RangeError`（C1a: `rate_budget.dart:413-415`），要先 acquire 再重送。
16. **既有 runner 缺少 channel**：`tool/bootstrap.py` 不覆寫既有的原生目錄，既有開發機上的 runner 不會有 `mergeline/backup`。文件要註明需要重新 bootstrap；§4.8 已規定失敗只記錄。
17. **B12 與 §5.2 的不一致**：C2 的終局 401 若不要求 GitLab JSON，代理伺服器的 HTML 401 會在線上 session 中觸發清除。方向是多刪，不是漏洞，但兩邊應該一致。
