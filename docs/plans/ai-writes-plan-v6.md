# Mergeline AI 助理：設計補充 v6.9（寫入與操控、可選自主等級、背景執行）

> Repository note: this is v6.10. §24 (v6.10) records amendments made after review round 9, such as 405/406 counting as certain non-execution and snippets confirmed by `#id`. Where §24 and the body (§0–§15) differ, §24 wins.

狀態：已通過計畫審查第 9 輪（Codex、Opus、cursor-agent 皆為 APPROVE WITH CHANGES；要求的修改已併入 v6.9，逐項處理見 §23），作為 MR6a–MR7 的實作依據。以 v5（`ai-assistant-plan-v5.md`）為基礎；與 v5 衝突時以本文件為準。§16–§23 是變更紀錄，只記錄當時的處理；與正文（§0–§15）衝突時以正文為準。

## 0. 擁有者決定（2026-10-21，不重議）

1. AI 要能新增、修改、刪除與操控 GitLab：「能做的都要」（app 已支援的寫入全部納入）。
2. 自主等級可選，包含 bypass；硬底線在任何等級都需輸入名稱確認：T5（建立／編輯／刪除專案），以及 CI 設定檔變更、帶變數執行 Pipeline、降低機密性或提高可見度、Fork。
3. 預設（起始）等級：低風險自動。
4. 寫入與對話頁同一階段交付（MR6 系列），合併後才進 MR7。
5. app 在背景時，進行中的 AI 執行要能繼續（Android）。
6. 通知用成熟外掛。
7. 寫入執行日誌：做，與聊天紀錄開關無關（新的本機持久化，需更新 AGENTS.md 與 CLAUDE.md）。
8. 「由 AI 助手撰寫」標註：預設不加，使用者可開啟。
9. 寫入預算：v6 草稿的數字交由審查調整（v6.1 依審查改為 §4.4 的數字）。
10. 既有決定仍有效：只上 Google Play（US$3.99），上架圖主打 AI；UI/UX 由 Claude 親自做。
11. 附檔上傳：做，只限使用者在對話中附的檔（§3.1）。狀態未知的鎖可由使用者在前景輸入名稱後手動解除（§7.6）。移除工作當下不保證跳中斷通知，下次啟動時一定呈現（§12）。
12. 重跑 Pipeline、重跑 Job、播放手動 Job（擁有者 2026-10-21 決定）：歸 T4，一般等級需確認（不必輸入名稱），bypass 可自動執行；接受「重跑可能沿用 GitLab 上已存的原變數」的風險。帶**新**變數執行 Pipeline 仍是硬底線（第 2 點）。
13. 議題與 MR 對話的附檔上傳（擁有者 2026-10-23 決定）：從議題或 MR 開啟的對話（含從群組頁開啟的專案議題）可以把使用者附的檔上傳到該議題／MR 所屬的專案，只限那個專案；這是 `upload_attachment` 專用的範圍類別 `projectUpload`，不授權該專案的其他資源（建立標籤、加星號等仍要專案範圍）。§2「從群組頁開啟的專案 Work Item 只授權該 Work Item」與 §3.1「對話沒有專案範圍時附檔按鈕停用」依此例外。

## 1. 相對 v5 的變更

| v5 | v6.9 |
|---|---|
| 只有唯讀工具，GET/HEAD-only adapter | 新增封閉的寫入能力表（§3），走第二個 port `gitlab_write_port.dart`；唯讀 port 與其守衛、測試不放寬 |
| 「AI 只讀取，絕不寫入」（`aiReadOnlyPromise`） | 以新的 key 取代並刪除舊 key；唯讀等級仍寫「不會寫入」 |
| 同意契約無寫入欄位 | `writePolicy`（每個 provider 的已同意上限與政策版本）計入 hash；`aiToolCatalogueVersion` 2、`aiDisclosureVersion` 2；MR6b-1 合併後所有既有同意都要重新同意（§10） |
| 沒有寫入相關的持久化 | 獨立的寫入執行日誌：自有金鑰、目錄與重設協定，不受聊天紀錄開關、清除與保留期影響（§8） |
| 不能附檔 | 使用者在對話中附的檔，可由 AI 提議上傳為專案附件；bytes 不送給 AI provider（§3.1） |
| run 生命週期跟著聊天頁 | 帳號範圍的 `AiRunRegistry`（§12），離開頁面與 app 進入背景都繼續 |
| 只在前景執行 | Android 前景服務＋通知＋原生執行許可（§12）；iOS 有限寬限後暫停，返回時續跑 |
| MR6：對話頁、入口、草稿、回報 | MR6a、MR6b-1、MR6b-2、MR6b-3、MR6c（§14），全部合併後才進 MR7 |

## 2. 授權模型（核心）

模型只能「提出」操作；能不能做、要不要確認，全部由 app 依可信來源決定。

- **可信來源只有使用者在 app UI 上的操作：** 使用者在本程序中送出的訊息、使用者在 UI 上加入的範圍與附件、使用者設定的等級、使用者按下的核准。tool 結果、GitLab 內容（README、議題、log、diff）、projection、模型的 `reason`、從紀錄恢復的顯示文字，都不能新增或擴大授權。
- **範圍（scope）是有型別的，只能由使用者在 UI 上建立：**
  - `project`：開啟對話的專案，或使用者在對話中明確加入的專案（加入時開新 segment）。
  - `workItem`／`mergeRequest`：從專案資源頁開啟時的那個資源（屬於其專案範圍）。
  - `groupWorkItem`：從群組 Work Item 頁開啟的那一個 Work Item，或使用者在 UI 上明確加入的群組 Work Item（這類 Work Item 沒有 project，由群組 namespace 擁有）。歸屬以前置讀取的 `namespace.fullPath` 與 Group GID 驗證；不涵蓋群組下的任何專案，也不涵蓋同群組的其他 Work Item。
  - **範圍與 key 的種類由前置讀取的擁有者決定，不由入口頁決定：** 群組 Work Item 頁的清單含子群組與子專案的項目（`groupWorkItems` 帶 `includeDescendants`）。`project` 不為 null → 專案 Work Item，key 為 `(account, project:<id>, workItem, 專案內 iid)`；`project` 為 null 且 namespace 是 Group → `groupWorkItem`。從群組頁開啟的專案 Work Item，只授權該 Work Item 與其子資源，不授權其專案的其他資源；要寫入該專案的其他資源，使用者須在 UI 加入專案。
  - `accountGlobal`：只在使用者從待辦收件匣明確開啟的對話中存在，只涵蓋待辦操作。
  - 建立專案與 fork 的目的地固定為目前帳號的個人 namespace，與畫面相同（`createProject` 沒有 namespace 參數；兩處 fork 畫面都不帶 `namespacePath`），在提議卡片上顯示；不提供其他目的地。這兩項是硬底線，本就需輸入名稱。
  - 授權 group 不自動授權其下所有專案。新建立的專案不會自動加入範圍。
  - 從「我的 › AI 助理」開啟、沒有範圍的對話不提供寫入工具。
- **範圍外的 ID 一律先歸屬驗證：** `suggestionId`、todo id、GraphQL GID 等全域 ID，工具參數改用範圍內座標（例如 MR iid＋note id＋suggestion id），由 app 前置讀取確認歸屬後才進入提議；歸屬不符直接拒絕。
- **自動執行還需要「目標綁定」：** 在任何自動等級（低風險自動、本次對話授權、bypass）下，自動執行只限以下目標：
  1. 對話的目前資源；
  2. 使用者在本程序中親自送出的訊息原文（不含 context、`<gitlab_data>`、tool 結果、projection，也不含從紀錄恢復的舊訊息）中，以下列明確語法出現、由 app 解析並驗證的目標：
     - `#iid`、`!iid`、`group/project#iid`、`group/project!iid`；
     - 反引號包住的分支名、tag 名或路徑（含 `refs/heads/…`、`refs/tags/…`）；
     - 同一 instance、經 `GitLabInstance` 驗證的資源 URL；
  3. 使用者在 UI 上點選加入的資源；
  4. 本段對話中由已執行寫入新建的資源。

  解析規則：一般字詞不構成綁定（例如說明句裡的 main、README），分支名與路徑不做子字串比對。範圍內有兩個以上專案時，`#iid`／`!iid` 必須帶專案路徑才算綁定。群組 Work Item 只能以經驗證的 URL 或 UI 加入綁定，不從文字參照推導。解析結果必須唯一，不由模型在多個候選中選擇。複合目標的**每個**元件都要各自綁定：檔案是專案＋ref＋正規化路徑；合併是 MR＋來源與目標分支；`createBranch` 是新名稱＋來源 ref。Pipeline 與 Job 的綁定：使用者訊息中經驗證的 Pipeline 或 Job URL、UI 加入，或本段對話中以 `createPipeline` 建立的 Pipeline（第 4 類）；Job 另可經由已綁定的 Pipeline 綁定，但前置讀取必須確認該 Job 屬於這個 Pipeline；模型從讀取工具結果取得的 Pipeline 或 Job ID 不構成綁定。其他目標改為逐一確認（不升高等級，只降為確認）。
- **低風險自動的額外條件（T1）：**
  - T1 自動授權綁定：本次送出的使用者訊息（entry ID）、operation、有效參數（星號與訂閱的目標狀態、表情名稱、延後時間）與完整 typed target。`setStar`、`setSubscribed` 這類一個方法承載相反動作的操作，方向也要對上。
  - 意圖詞是 app 維護的封閉表，只涵蓋會自動執行的 T1 operation：每個方向（標星／取消標星、訂閱／取消訂閱、加／移除表情、Work Item 活動留言表情、Work Item 通知開／關、完成單一待辦、延後／取消延後）在每個語系各一組，放在 l10n 目錄，與其他翻譯一起檢查。「好」「完成」「OK」這類泛用單詞不算。
  - 比對語系：以目前介面語言，加上裝置語言清單中有翻譯的語系。只要任一適用語系命中否定詞或條件詞，就改為確認。
  - 下列情況一律改為確認：訊息同時含相反方向的詞；含適用語系封閉否定詞表或條件詞表中的詞；意圖詞只出現在引用區塊、程式碼區塊或貼上的長段文字中；方向不明或無法唯一解析。詞彙匹配只產生候選，不讓模型選擇方向。
- **提議卡片顯示：**「你的要求」欄由 app 顯示使用者本段對話的最後一則原文；模型的 `reason` 以純文字（不渲染 Markdown、不可點連結、先遮蔽）顯示並標示「AI 的說明」。

**殘餘風險（如實寫進同意框與 bypass 說明）：** 在使用者已廣泛授權（本次對話授權、bypass）的範圍與目標內，被注入的模型仍可能做出使用者沒想要的寫入。上述規則限制的是「範圍、目標、硬底線與預算」，不能消除這類錯誤。

## 3. 寫入能力表（封閉目錄 v2）

原則：
- MR6b 以逐項 capability ledger 實作。每一列：operation ID；實作來源（「現有方法」或「MR6b 新增包裝」）；既有畫面呼叫點（可以是「無，僅 API 方法」，這類列必須自行寫出欄位白名單、前置讀取與拒絕規則，不得寫「沿用畫面」）；允許欄位白名單；typed scope；基礎層級；參數升級規則；預覽；前置讀取；確認名稱來源與手動解鎖名稱；方法內部的 HTTP 次數上限；readback 方式；寫入與依賴的 conflict keys（§7.6）；測試。
- 寫入 port 只呼叫具名方法；**禁止**直接取得通用 `writeRecord`／`removeRecord`／`writeEmpty`／`graphMutation`／`_send`，禁止模型提供 URL、HTTP 方法或任意路徑。具名方法內部可以沿用通用通道，但 path 與欄位固定，不把模型給的字串拼進 path（例如 `createNote` 的 `resource` 只允許 `issues`、`merge_requests` 兩個列舉值）。
- **新增包裝：** 目前畫面直接呼叫通用通道、又沒有具名方法的寫入，由 MR6b 在 `lib/core` 新增具名、欄位固定的包裝，只包住今天畫面上那一個呼叫。至少包括：`unapproveMergeRequest`、`createTodo`、`createDiscussion`（含行內 position）、`createDiscussionNote`、`updateDiscussionNote`、`setDiscussionResolved`、`createDraftNote`（含行內 position）／`updateDraftNote`／`deleteDraftNote`／`publishDraftNotes`、`createLabel`／`updateLabel`／`deleteLabel`、`createMilestone`／`updateMilestone`／`setMilestoneState`／`deleteMilestone`、`createBoard`／`renameBoard`／`setBoardSystemListHidden`／`deleteBoard`、`createBoardList`／`moveBoardList`／`deleteBoardList`、`moveBoardCard`、`createSnippet`／`updateSnippet`／`updateSnippetMetadata`／`updateSnippetFiles`（新增、更新、改名）／`deleteSnippetFile`／`deleteSnippet`、`deletePackage`／`deletePackageFile`／`deleteContainerRepository`／`deleteContainerTag`。名稱在實作時可調整，但每個 ledger 列都寫出最終方法名，`tool/tests/test_ai_boundaries.py` 的 write-port 白名單逐一列出。
- **畫面改用：** 對應畫面在交付該列的同一個 MR 改用同一方法，讓 AI 與畫面走同一條路徑與欄位：
  - `work_item_page.dart` 對 `ownerPath` 的寫入（欄位編輯、`state_event`、指派、標籤增減、標題與草稿切換、刪除）改用 `updateIssue`／`updateMergeRequest`／`deleteIssue`／`deleteMergeRequest`；建立待辦、取消核准改用新包裝。
  - `discussions_tab.dart` 的根留言新增、編輯、刪除改用 `createNote`／`updateNote`／`deleteNote`；討論回覆、resolve 改用新包裝。
  - `project_more_page.dart` 的 `MetadataPage`：分支、tag、Release 的建立、編輯、刪除改用 `createBranch`／`deleteBranch`／`createTag`／`deleteTag`／`createRelease`／`updateRelease`／`deleteRelease`；標籤、里程碑改用新包裝。
  - `boards_page.dart`、`draft_review_page.dart`、`diff_page.dart`、`snippets_page.dart`、`registries_page.dart` 改用新包裝。
- **僅 API 方法：** `batchApplySuggestions`（畫面只用 `applySuggestion`）。白名單：suggestion id 清單（≤ 20）與選填 commit message（(B) 類）；每個 suggestion 都以 MR 座標個別做歸屬驗證。
- **欄位白名單（與畫面相同）：**
  - 議題、MR、事件單：title、description、labels、assignee_ids、milestone_id；議題另有 confidential，事件單另有 severity，MR 另有 reviewer_ids，建立 MR 另有 source_branch／target_branch。`createIssue` 另接受 `issue_type` ∈ {issue, task, incident}（畫面建立時會送）；更新時不送 `issue_type`。議題日期不走 REST，走 `updateWorkItemDates`（MR6b-3）。MR 的草稿切換沿用畫面，以更新標題實作。`createMergeRequest` 不暴露 `target_project_id`。
  - `createProject`：只接受 name、path、description；`visibility` 固定 private，`initialize_with_readme` 固定 true。`forkProject`：不帶 `namespacePath`。
  - 分支建立：`branch`、`ref`。tag 建立：`tag_name`、`ref`、`message`（(B) 類）。
  - Release：建立只接受 `tag_name`（必須是前置讀取確認已存在的 tag）、`name`、`description`；編輯只接受 `name`、`description`。不接受 `ref`、`assets.links`、`milestones`、`released_at`，所以建立 Release 不會順便建立 tag。
- **GraphQL 寫入方法**（Work Item、事件單、待辦延後）在方法內部依序做前置讀取、唯一一次 mutation 與獨立 readback。MR6b-3 為每個方法加上 awaited 的 `beforeMutation` 掛鉤，日誌與結果分類依 §7.4、§7.5；Work Item 狀態、日期、健康度的寫入登記到畫面既有的寫入登錄（§7.3）。
- **實際層級 = max(基礎層級, 參數與前置讀取觸發的升級)**，由 app 計算，模型無法降級；複合效果取最高層級。分支是否為預設或受保護分支，由 app 前置讀取（專案 `default_branch`、分支物件的 `protected`／`default`）判定，不採用模型參數。
- 未列在表中的寫入一律不可呼叫；每個 MR6b 合併前以覆蓋測試證明 ledger 涵蓋已交付的寫入呼叫點（§15 第 21 列）。

| 層級 | operation（具名方法；未註明者為現有方法） | 升級規則與限制 |
|---|---|---|
| T1 互動 | 表情回應增刪（`addAwardEmoji`/`removeAwardEmoji`）、星號（`setStar`）、訂閱（`setSubscribed`）、單一待辦完成（`markTodoDone`，歸屬驗證）；GraphQL（MR6b-3）：待辦延後／取消延後（`snoozeTodo`/`unsnoozeTodo`，參數是全域 todo id，歸屬見下方「待辦延後的歸屬」）、Work Item 活動留言表情（`setWorkItemActivityNoteReaction`）、Work Item 通知設定（`setWorkItemNotifications`） | 他人可見的表情回應也屬 T1，但受目標綁定與意圖詞限制 |
| T2 內容 | 留言（`createNote`）、編輯自己的留言（`updateNote`，前置讀取確認作者是目前帳號）、新討論與行內討論、討論回覆與編輯、resolve／unresolve（新增包裝）、建立議題（`createIssue`）、編輯議題欄位與關閉／重開、事件單嚴重度（`updateIssue`，欄位白名單）、建立 MR（`createMergeRequest`）、編輯 MR 欄位與草稿切換（`updateMergeRequest`，欄位白名單）、MR 取消核准（新增 `unapproveMergeRequest`）、對議題／MR 建立待辦（新增 `createTodo`）、草稿審查留言新增與編輯（新增包裝）、看板卡片移動（新增 `moveBoardCard`，預覽寫出標籤／狀態差異）、看板建立與重新命名、系統欄隱藏／顯示、清單新增與排序（新增包裝）、標籤與里程碑建立、編輯、關閉／重新開啟（新增包裝）、片段建立、內容編輯、中繼資料（標題、描述）編輯、片段內檔案新增與改名（新增包裝；既有內容走 §6 精確片段）、使用者附檔上傳（`upload_attachment`，§3.1）；GraphQL（MR6b-3）：`updateWorkItemContent`、`updateWorkItemState`、`updateWorkItemStatus`、`updateWorkItemAssignees`、`updateWorkItemLabels`、`updateWorkItemMilestone`、`updateWorkItemWeight`、`updateWorkItemHealthStatus`、`updateWorkItemDates`、活動留言建立／回覆／編輯（`createWorkItemActivityComment`/`createWorkItemActivityReply`/`editWorkItemActivityNote`）、事件單 escalation 狀態（`setIncidentStatus`） | 既有資源的 `confidential` 由 true 改為 false、提高可見度 → 硬底線（新建議題預設非機密，不算降低）；新建片段的可見度不是 private 即算提高可見度；文字欄位一律經 §5 處理；看板卡片移動與議題標籤更新共用該議題的 conflict key |
| T3 操作 | 檔案修改（`edit_file`，§6，底層 `saveFile` 帶 `last_commit_id`）、新增檔案（`saveFile` 不帶 `lastCommit`，即 POST，已存在即失敗）、套用建議（`applySuggestion`）與批次套用（`batchApplySuggestions`，僅 API 方法），預覽列出 commit 與影響檔案、建立分支（`createBranch`）、合併到非預設、非受保護分支（`mergeRequest` 帶 sha；`squash` 留在本層級，預覽顯示是否 squash）、設定自動合併（`mergeRequest(autoMerge: true)` 帶 sha）與取消（`cancelAutoMerge`）、rebase（`rebaseMergeRequest`，不暴露 `skipCi`）、Pipeline 取消（`pipelineAction(cancel)`）、Job 取消（`jobAction(cancel)`）、草稿審查整批送出（新增 `publishDraftNotes`，見下方）、建立／編輯 Release（`createRelease`/`updateRelease`，只能指向已存在的 tag） | 目標分支為預設或受保護分支時：`edit_file`、新增檔案、套用建議與批次套用、合併、設定自動合併 → T4；`removeSourceBranch: true` → T4（或拆成 T3 合併＋T4 刪除）；修改 CI 設定檔（含合併或套用建議帶入的既有變更，見下方）、帶變數的 Pipeline → 硬底線；建立類（分支、tag、Release 等）的隔離未解除前，同名建立也被擋（§7.6），這是刻意的 |
| T4 破壞性 | 核准 MR（`approveMergeRequest` 帶 sha）、合併到預設或受保護分支、直接 commit 到預設或受保護分支（上列升級）、建立 tag（`createTag`，一律 T4：tag pipeline 常用於發版或部署）、執行 Pipeline（`createPipeline`，不帶變數）與排程播放（`playPipelineSchedule`，參數明確為空時）一律 T4、重跑 Pipeline（`pipelineAction(retry)`）、重跑 Job 與播放 Job（`jobAction(retry|play)`，不依 Job 目前狀態分流）為 T4（§0 第 12 點：一般等級只需確認、不必輸入名稱，bypass 可自動；見下方）、刪除留言（`deleteNote`）、議題（`deleteIssue`）、MR（`deleteMergeRequest`）、分支（`deleteBranch`，write port 前置讀取分支的 `default`／`protected`，命中即拒絕，與畫面相同）、tag（`deleteTag`）、Release（`deleteRelease`）、Pipeline（`deletePipeline`）、檔案（`deleteFile` 帶 `last_commit_id`）、草稿審查留言刪除、標籤／里程碑刪除、片段刪除、片段內單一檔案刪除、看板與清單刪除、套件、套件檔、容器庫與容器 tag 刪除（新增包裝，沿用 `canDelete`、archived 判斷）、Work Item 活動留言刪除（`deleteWorkItemActivityNote`，GraphQL，MR6b-3）、全部待辦標為完成（`markAllTodosDone`，`accountGlobal` 範圍，任何等級含 bypass 都要確認） | 確認名稱一律來自 app 前置讀取，不取自模型參數（`confirmAction(requiredText:)`，來源見下方） |
| 硬底線 | 建立／編輯／刪除專案（`createProject`/`editProject`/`deleteProject`；`editProject` 只改名稱與描述）、Fork（`forkProject`，目的地固定為個人 namespace）、CI 設定檔的新增、修改與刪除（`.gitlab-ci.yml`、專案 `ci_config_path`、`.gitlab/**`、`CODEOWNERS`；包括合併、設定自動合併與套用建議帶入的既有變更）、帶變數執行 Pipeline（模型提供的變數：拒絕 `CI_*`、`GITLAB_*`、`*_DEBUG_*`，變數值經秘密檢查）、播放帶有 variables 或 inputs 的排程，或無法讀取這兩欄的排程（見下方）、降低機密性或提高可見度（議題、MR、片段、專案） | 任何等級都需輸入名稱確認，bypass 也一樣 |

個別規則：
- **CI 設定檔判定：** 每次判定前重新讀取專案 JSON 的 `ci_config_path`（目前 `Project` 模型沒有這個欄位，由 write port 的前置讀取取得原始值），把它與 `.gitlab-ci.yml`、`.gitlab/**`、`CODEOWNERS` 同等看待；讀不到就把受影響的路徑都當成 CI 設定檔處理。
- **合併前的既有變更檢查：** `mergeRequest` 的 payload 只有 sha 與合併選項，看不到 MR 已帶的變更，所以合併與設定自動合併在提議時與 dispatch 前都要：
  - 針對綁定的 head sha，讀取完整變更清單：`GET …/merge_requests/:iid/diffs` 的全部分頁，每筆取 `old_path`、`new_path`、`new_file`、`deleted_file`、`renamed_file`；以 MR 的 `changes_count` 核對筆數，值帶 `+` 或筆數不符即視為不完整。
  - 讀取 MR 描述、MR 內各 commit 的完整 message（`…/commits`），以及伺服器列出的合併後將關閉的議題（`…/closes_issues`）。
  - 任一路徑（含改名的舊路徑與刪除）命中 CI 設定檔 → 硬底線。將關閉的議題、描述或 commit message 中有範圍外的議題或跨專案參照 → 固定確認清單（§4.1）。
  - 清單不完整、分頁失敗、權限不足或版本不支援，不得視為空集合：變更路徑不完整時不產生提議；關閉效果無法完整判定時不得自動執行。
  - head sha、路徑集合 digest 與將關閉議題集合綁入提議（§7.1），dispatch 前重驗；所需 HTTP 計入 §4.4 的保留，保留不到就不產生提議。
  - 套用建議與批次套用依每個 suggestion 所在的實際檔案路徑判定 CI 硬底線，不依 commit message。
- **直接執行 Pipeline 或 Job 的操作至少 T4（只限這四個方法）：** `createPipeline`、`pipelineAction(retry)`、`jobAction(retry|play)`、`playPipelineSchedule` 不分 ref、不做部署判定，至少 T4；重跑 Pipeline、重跑 Job、播放 Job 依 §0 第 12 點為 T4（下一點），排程播放依參數可能升為硬底線。commit（`edit_file`、新增檔案、套用建議）、建立分支、合併、rebase 由 GitLab 依推送事件觸發的 pipeline 不在此列，維持各自的層級，其 CI 副作用屬殘餘風險，寫進同意框（§10）。理由：沒有資料來源能證明「不會部署」：REST Job 物件沒有 environment 欄位；GraphQL `CiJob.expandedEnvironmentName` 為 null 時也可能只是沒有記錄名稱；deployments 只涵蓋會建立 deployment 的 Job，`environment:action: stop` 這類停止環境的 Job 不在其中；尚未建立的 pipeline（`createPipeline`、排程播放）更沒有 Job 可讀，排程的 `last_pipeline` 也不能證明下一次不部署。CI 執行本身的副作用（部署、停止環境、下游 pipeline、腳本對外的動作）不是 app 能判定的範圍，這一點寫進同意框與 bypass 說明；bypass 依 §4.2 仍可自動執行 T4。取消（`pipelineAction(cancel)`、`jobAction(cancel)`）不建立新的 Pipeline 或 Job，v2 維持 T3；但取消執行中的 Job 可能讓它的 `after_script` 開始執行（GitLab CI 文件），所以不保證停止所有 CI 指令或外部副作用，預覽與同意框寫明這一點。預覽列出 ref、Pipeline 或 Job ID、stage 與可讀到的 environment，只作參考，不用來降級。
- **重跑 Pipeline、重跑 Job、播放 Job：T4，一般等級只需確認（擁有者 2026-10-21 決定，§0 第 12 點）。** 這些操作只帶 ID，app 不送任何變數；但 GitLab 執行時會使用已存、而且分散在多處的值：pipeline 變數、排程上**當下**的變數，以及 Job 層的參數。GitLab 原始碼 `Gitlab::Ci::Variables::Builder#user_defined_variables` 依序合併 pipeline 變數、`pipeline_schedule_variables` 與 Job 變數；`Ci::Build.clone_accessors` 含 `job_variables_attributes` 與 `inputs_attributes`，所以重跑（含重跑 Pipeline 時被重跑的每個 Job）會複製上一次的 Job 變數與 Job inputs；官方文件也寫明重跑手動 Job 可沿用前次的變數。擁有者接受「重跑可能沿用 GitLab 上已存的原變數」：
  - 層級為 T4。在逐一確認、低風險自動與本次對話授權等級，卡片只需按確認，**不必輸入名稱**（這是 §4.1 表中 T4「輸入名稱」的唯一例外）；bypass 在 §2 目標綁定成立時可自動執行，不成立時改為確認（同樣不必輸入名稱）；固定確認清單與其他規則照常。
  - v2 不讀取、不綁定這些既有參數（不讀 pipeline 變數、`source` 或 `manualJob`）。三個工具的 schema 沒有變數或 inputs 參數，ledger 列的允許欄位為空，請求 body 是空的 JSON 物件 `{}`（現有 `pipelineAction`／`jobAction` 即如此）。卡片與稽核列都寫明「重跑或播放可能沿用 GitLab 上已存的原變數與 inputs（前次的 Pipeline 與 Job 變數），排程建立的 Pipeline 還會使用排程**目前**的變數；app 讀不到也無法核對」。Pipeline 重跑列出 ref 與 Pipeline ID；Job 重跑與播放另列 Job ID、Job 名稱與 stage。
  - 帶**新**變數執行 Pipeline（模型提供 variables 的 `createPipeline`）仍是硬底線（§0 第 2 點）；排程播放仍依下一點的參數規則。
- **排程播放的參數：** `playPipelineSchedule` 只送空 POST，實際有效參數是排程上存的 `ref`、`variables` 與 `inputs`（GitLab Pipeline Schedules API；這兩欄只對 Maintainer、Owner 與排程擁有者回傳）。write port 以固定的前置讀取取得排程，算出一個 HMAC 綁入提議，dispatch 前重讀比對：
  - HMAC 是 HMAC-SHA-256，金鑰在本程序內只產生一次、放在 `AiWriteJournal.instance`，不寫入磁碟、日誌、稽核列或預覽。輸入是以長度前綴或鍵已排序的 JSON（UTF-8、保留型別）正規化的完整參數集：每個參數的名稱、值與型別（變數含 API 回傳的型別欄位；inputs 保留 JSON 型別，字串、數字、布林不混同；集合穩定排序、陣列保留順序），以及 `ref`。值只進 HMAC，不送給模型、不進預覽、稽核列或日誌；預覽只列名稱。HMAC 只存在記憶體中的提議裡，不出現在工具結果、送 provider 的內容或日誌（待確認的提議在程序死亡時作廢，所以不需要跨程序比對）。
  - 讀取有下一頁、筆數對不上或被截斷時，整筆是「無法讀取」，不得用部分結果計算 HMAC，也不得當成明確為空。
  - 「明確為空」只限 `variables` 是空陣列，且 `inputs` 是空陣列或空物件。明確為空時維持 T4。非空，或欄位缺席、null、因權限省略、型別異常、讀取失敗（「無法讀取」，不當成空集合），一律按硬底線「帶變數執行 Pipeline」，任何等級都輸入 ref；無法讀取時卡片寫「無法核對參數；執行時會使用 GitLab 上當下的參數，無法確認自提議後未變」。
  - §7.1 綁定這個 HMAC；dispatch 前（§7.2）以同一把金鑰重算，名稱、值、型別、ref 或可讀性任一改變，或金鑰已不在，舊核准作廢。
  - 這些參數由維護者設定、不由模型提供，所以不套用模型變數的名稱禁止與秘密檢查。
  - 簡化取捨：排程 `inputs` 在較舊版本不存在時也算「無法讀取」，該版本上播放排程一律要輸入 ref；不依版本放寬。
- **取消自動合併（簡化，不依版本選端點）：** 現有 `cancelAutoMerge` 呼叫 `cancel_merge_when_pipeline_succeeds`。GitLab 官方文件標示它在 19.5 起 deprecated（新端點 `cancel_auto_merge` 同版引入），但尚未移除，所有支援的版本都有。因此 v2 只用舊端點，不讀 instance 版本、不探測、不在失敗後改送另一端點，每個執行只送一次 mutation。規則：
  - 自動合併是否開啟，與畫面相同用 `isAutoMergeEnabled`（`work_item_page.dart`：MR 未合併未關閉，且 `merge_when_pipeline_succeeds` 或 `auto_merge_enabled` 任一為 true）。兩種旗標都送同一個舊端點：GitLab 原始碼中，這個端點呼叫 `AutoMergeService#cancel`，它只在 `auto_merge_enabled?` 為 false 時回錯誤，否則清除目前啟用的自動合併策略，所以不需要依旗標改送新端點。
  - 前置讀取 MR：必須 `isAutoMergeEnabled`，否則不產生提議並說明原因。`user.can_merge` 不作閘門：GitLab 原始碼的 `can_cancel_auto_merge?` 是「可合併**或**是 MR 作者」。`user.can_merge` 為 false 且作者不是目前帳號時，卡片提示「你可能沒有取消權限」，仍可提議。
  - 結果分類（覆寫 §7.5 的 REST 一般規則）：
    - 201 且 `status == "success"`，且 readback 顯示 `isAutoMergeEnabled` 為 false → 成功；readback 仍為 true 或 readback 失敗 → 狀態未知。
    - 201 且 `status == "error"` → 確定未執行，不上鎖（原始碼：自動合併未開啟，或清除失敗已回滾），顯示伺服器的 `message` 與 readback 讀到的目前狀態。
    - 201 但 `status` 為其他值或無法解析 → 狀態未知。
    - 這次取消 POST 本身的 HTTP 401 → 依 §7.5 為確定未執行；POST 已回 201 之後 readback 的 401 仍為狀態未知；PAT 或 refresh 失敗時顯示「可能沒有取消權限，或登入已失效」，OAuth refresh 成功後未重放時顯示「登入已更新，這次取消沒有送出，可再提議一次」。
    - 剛讀過 MR 卻收到 404 → 確定未執行，文案「取消端點不可用或無法存取，自動合併可能仍在」，不用資源不存在的文案。
  - MR 已合併時顯示「已合併，無法取消」。GitLab 公告移除舊端點時，再以新的 ledger 列改用新端點。
- **待辦延後的歸屬：** `snoozeTodo`／`unsnoozeTodo` 先以目前帳號（`currentUser`）的固定唯讀查詢找到 exact Todo GID 與其 target。延後與取消延後各用一條查詢：延後查**未延後**的 pending 待辦，取消延後才查已延後的待辦；禁止只用現有 `_snoozedTodosQuery`（`isSnoozed: true`）驗證延後，因為即將延後的那一筆不在其中。兩條都逐頁比對到該 GID 為止（頁數受 §4.4 的 HTTP 預算限制）；頁面截斷或預算用完仍未見到時為「無法驗證」，不送 mutation，也不說成沒有這筆待辦。`accountGlobal` 只授權目前帳號自己的待辦；資源範圍的對話另驗 target 與該範圍相符。target 的 `project` 不為 null 時驗 numeric project；`project` 為 null 且 target 為 Work Item 時，查詢必須讀出並驗證該 Work Item 的 namespace、Group GID 與 Work Item GID（現有 query 對 Work Item 只讀 `iid`、`title`，MR6b-3 新增），不從 URL 推導專案。不支援或無法驗證的 target 型別明確拒絕，不當成查無待辦。成功的證據是 mutation 回應中的 `snoozedUntil`（已接受）；之後 `snoozedTodos` 查不到或 truncated，只是不升為「已 readback 確認」，不改為狀態未知。
- **草稿審查整批送出：** GitLab 的 `bulk_publish` 會送出目前帳號在該 MR 上的**全部**草稿。預覽列出伺服器上的全部草稿，標示哪些是本段對話建立的；全部草稿都經 §5（A）類檢查；含非本段對話建立的草稿時，任何等級（含 bypass）都改為確認。執行前沿用畫面的快照比對（`draft_review_page.dart`）與 head sha 重驗。「受影響資源數 ≤ 20」以草稿數計算。
- **片段內容：** 新片段只接受一份初始正文，依 §5 全文掃描後由 app 送出。既有片段的內容只接受精確片段（§6）：app 讀取片段最新的完整內容、在本機套用，再以 `updateSnippet` 或 `updateSnippetFiles` 送出 GitLab 需要的整份檔案，執行前沿用畫面的新鮮內容比對，不符即作廢提議。
- **確認名稱來源（`requiredText`，一律來自前置讀取）：**
  - 硬底線：專案建立、編輯、刪除為 `path_with_namespace`（建立時為個人 namespace 下的完整路徑）；fork 為目的地完整路徑；CI 設定檔為倉庫內完整路徑（合併時為命中的第一個 CI 路徑，卡片列出全部）；帶變數的 Pipeline 為 ref；降低機密性或提高可見度為議題／MR 的 `#iid`／`!iid`、片段標題或專案 `path_with_namespace`。
  - T4：刪除分支、tag、Release 為其名稱；建立 tag 為新 tag 名；刪除檔案、片段內單一檔案為完整路徑或檔名；刪除議題、MR 為 `#iid`／`!iid`；刪除留言為所屬資源的 `#iid`／`!iid`；刪除 Pipeline 為其 ID；刪除套件為名稱與版本；刪除容器為路徑與 tag；刪除標籤、里程碑、看板、清單、片段為其名稱或標題；核准為 `!iid`；合併與直接 commit 到預設或受保護分支為目標分支名；執行 Pipeline 與播放排程為 ref，重跑 Pipeline、重跑 Job、播放 Job 不需輸入名稱（§0 第 12 點，只需確認）；`markAllTodosDone` 為目前帳號的 `@username`。
  - **解除狀態未知的鎖**（§7.6），依 conflict key 的種類決定，不依層級，涵蓋 T1 到硬底線的每個 operation：
    - 專案議題、task、事件單、MR 與其子資源（留言、討論、草稿、表情、訂閱、待辦、看板卡片）：所屬資源的 `#iid`／`!iid`；
    - 群組 Work Item 與其子資源：`<群組完整路徑>#<iid>`；
    - `(ref, path)`：完整路徑；`(ref)`：ref 名稱；
    - Pipeline、Job：其 ID；
    - 專案層級集合（建立 Pipeline、播放排程、標籤、里程碑、片段、看板、Release、套件、容器）：專案 `path_with_namespace`；
    - 使用者附檔上傳：檔名（日誌保存，§3.1）；
    - `(account, todos)` 與單一待辦：目前帳號的 `@username`；
    - 專案本身與 fork：專案或目的地的完整路徑。

    以明細為單位解除：一筆寫入可能有多把 key（例如合併寫入 MR 與目標 ref），使用者輸入該筆主要 key 的名稱（合併為 `!iid`）即解除該筆的全部 key，並對全部 key 寫入待確認標記。解除名稱在 `prepared` 時由前置讀取決定並寫進日誌（§8），所以資源刪除、權限改變或重啟後仍可使用；比對用原始字串，不含 `isolated()` 加入的方向隔離字元。名稱不由模型提供；前置讀取取不到解除名稱時不產生提議。

**v2 不提供：** 通用 HTTP 寫入；成員與權限變更、Wiki 寫入（app 本身沒有這些寫入）；v5 §4.2.3 的敏感路徑一律禁止寫入；把二進位檔寫進倉庫（`saveFile`／`edit_file` 只處理文字）。使用者在對話中附檔、由 AI 上傳為專案附件，見 §3.1。GraphQL Work Item（含群組 Work Item）、事件單與待辦延後的寫入不再排除，列入上表，於 MR6b-3 交付。

### 3.1 使用者附檔上傳（擁有者 2026-10-21 決定納入）

- **來源只有使用者附的檔：** 對話頁輸入列有附檔按鈕（相片、檔案），沿用 `AttachmentPicker`、`readLimitedAttachment` 與 `discardPickedCopy`，單檔上限 `GitLabApi.maxUploadBytes`（25 MiB）。每段對話最多 10 個附件、附件 bytes 合計不超過 50 MiB；整個程序所有對話合計不超過 100 MiB。選檔前先原子保留容量，串流讀取上限為 min(25 MiB, 對話剩餘容量, 程序剩餘容量)，超過即停止讀取並丟棄 picker 的暫存副本；讀取失敗或移除附件時釋放保留，上傳中的附件仍計入。這些上限指附件 bytes，不宣稱整個 Dart heap 的大小。達上限時附檔按鈕停用並說明原因。附檔按鈕、附件列與記憶體中的附件保存，都隨 `upload_attachment` 與 `attachment_metadata` 在 MR6b-1 交付；MR6a 沒有附檔 UI（不顯示、不讀 bytes；模型看不到檔案，也不會收到檔名）。MR6b-1 起，只要 segment 不含 `upload_attachment`（實際上限為唯讀、`toolsEnabled` 為 false、對話沒有專案範圍），附檔按鈕就停用並說明原因。模型無法產生、下載或轉送 bytes；`upload_attachment` 只接受本段對話中使用者附加的附件 ID（例如 `att-1`），其他字串一律拒絕。
- **bytes 不送給 AI provider：** 送給模型的只有附件 ID、經遮蔽的檔名、大小與裝置回報的類型（檔名顯示時另經 `isolated()`）。附件內容不進 prompt、聊天紀錄或寫入日誌。這些中繼資料屬於新的同意資料類別 `attachment_metadata`（§10；現有 `dataCategories` 只有 `job_log`、`diff`、`source`、`issue_text`、`comments`、`tool_reads`，沒有可沿用的類別），MR6b-1 隨揭露 v2 加入。檔名來自裝置，可能是別人取的，所以附件中繼資料以 nonce 標記的 untrusted-data 區塊交給模型，檔名不參與 §2 的目標綁定與意圖詞比對。讓模型「看」圖片是另一個功能，不在 v2 範圍。
- **生命週期：** 附件只存在於本程序記憶體，綁定帳號與對話。對話結束、切帳號、程序死亡，或使用者在輸入列移除時丟棄。從紀錄恢復的對話中附件已不存在，工具回 `attachmentExpired`，模型要請使用者重新附檔。使用者在提議等待確認或尚未 dispatch 時移除附件，該提議作廢，記 `notExecuted`。
- **層級與範圍：** `upload_attachment(attachmentId, project)` 為 T2，目標專案必須在對話的 typed scope 內（§2）。預覽顯示檔名、大小、類型、目標專案完整路徑與可見度；圖片顯示本機縮圖（不連網）。目標專案為 public 或 internal 時，確認等級的卡片另外標示「引用到這個專案的內容後，能看到內容的人都能透過連結取得檔案」；本次對話授權與 bypass 不先顯示卡片，這段說明改顯示在稽核列，並寫進同意框（使用者附檔並選擇自動等級的結果）。
- **上傳逾時：** `uploadProjectFile` 走共用的送出流程，dio 5.11.1 把整個 multipart body 的送出包在 `sendTimeout`（預設 15 秒）內，25 MiB 要約 14 Mbit/s 上行才送得完，逾時會成為 `writeUncertain` 並上鎖。MR6b-1 為 `uploadProjectFile` 加上選填的每次請求送出逾時（dio 的 `Options.sendTimeout`），畫面沿用預設；AI 上傳使用 max(15 秒, 檔案大小 ÷ 128 KiB/s)，上限 4 分鐘，寫成常數，卡片顯示上傳中。§7.4 的寫入逾時與 §12.1「等待在途寫入」的上限，對上傳改用這個值。
- **結果不含秘密網址，後續讀取也不回流：** 上傳回應的 `url` 與 `markdown` 含 GitLab 的 secret 路徑，不回給模型；模型收到的是佔位字串 `[[attachment:att-1]]`。這個保證也涵蓋之後的讀取，規則刻意簡單、寧可多遮：
  - provider 外送層（`lib/core/ai/redaction.dart`）依序處理所有送給 provider 的內容（讀取工具的 projection、context、寫入結果投影、Job log、原始碼、diff、使用者訊息，也涵蓋既有的上傳連結與重啟後的讀取）。畫面顯示不受影響，仍依原權限顯示與開啟。
    1. 來源文字中原本就有的 `[[upload:` 與 `[[attachment:` 字樣，先換成一般遮蔽標記，所以模型看到的這類佔位字串一定是 app 產生的。
    2. 任何文字中的 `uploads/<32 個十六進位字元>`（不分大小寫），後面接 `/檔名`、分隔字元或字串結尾，都要遮蔽，不論前綴（相對路徑、`/-/project/<id>/`、群組上傳、安裝子路徑）或主機，也不判斷是不是同一 instance。任何截斷字串的地方（紀錄 codec、excerpt、diff 片段）比照已知秘密，在截斷端修掉尾端的 `uploads/` 加 1–32 個十六進位字元。這不重用 `lib/shared/attachment_ref.dart` 的 `parseProjectUpload`：那是只認得目前頁面專案的下載允許清單，維持原樣，只供畫面開啟附件。
    3. 預設換成一般遮蔽標記（不可還原；模型抄進寫入時依 §5 第 5 點擋下）。只有下一點的命中換成可還原的佔位字串。
- **可還原的佔位字串 `[[upload:u-<n>]]`（只為了讓 AI 能編輯含附件的同一個欄位）：**
  - 只有同時符合三個條件的命中可以還原，其餘都是一般遮蔽標記：
    - 讀自一個可寫回的資源欄位的**完整、未截斷值**：議題或 MR 的描述、一則留言或討論回覆、專案或群組 Work Item 的描述或活動留言、Release 說明、里程碑描述、片段描述。讀取 port 在工具結果的 provenance 上逐值標記「正規化資源 key＋欄位名」（資源 key 沿用 §7.6：議題的 REST 與 GraphQL Work Item 描述共用；留言以 note 的數字 ID 為準，GraphQL note GID 為別名）。外送層只對帶這個標記、而且是該欄位完整值的字串發可還原編號。Job log、原始碼、diff、使用者訊息、context 摘要、`markdownSummary`、被截斷或被 clip 的值、`restoreFromDisplay` 的文字與其他來源一律不可還原。欄位值在投影中被截斷時，這個欄位不提供整欄寫回，回「這個欄位太長，AI 無法完整編輯」。
    - 是本 instance 自己的上傳路徑：連結目標的邊界由 app 的 Markdown 與 HTML tokenizer 決定，不以正規表示式猜測；無法唯一判定時一律一般遮蔽。**標準形式**：沒有 scheme、沒有 host、正好是 `/uploads/<32 hex>/<檔名>` 的目標，是 GitLab 儲存的寫法；依 GitLab 語意（`UploadLinkFilter` 以安裝子路徑加 `-/project/<id>` 或 `-/group/<id>` 為前綴渲染）視為來源資源所屬專案或群組的上傳，不對主機根解析，也不套用安裝子路徑檢查（與 `parseProjectUpload` 相同）。**其他相對目標**（`./`、`../`、不以 `/` 開頭）才以已驗證的來源資源 web URL 為基準解析並做 dot-segment 正規化，結果必須是 `<instance base>/<專案完整路徑>/uploads/…`、`<instance base>/-/project/<該專案 id>/uploads/…` 或該群組的上傳前綴。**絕對 URL 與 `//host/…`**：驗證 scheme、host、port、userInfo 為空，並要求同樣的上傳前綴（同 origin 但不同安裝前綴、或其他專案 id 都不算）。**三種形式共同的條件**：secret 與檔名通過 `projectUploadNamesOk`；檔名在第一個空白、`?`、`#`、引號、括號、`<`、`>` 或控制字元處結束。不符合即一般遮蔽、不可還原。
    - 外送時換掉的是**整段連結目標**，不是只有尾段，所以模型看不到、也改不了前綴。
  - 對照表只存在本程序記憶體，以「account、對話、來源資源與欄位、原始連結目標」為一筆；同一欄位的相同字串沿用同一個編號，不同資源或欄位用不同編號，既有的筆不改寫。對照表不進聊天紀錄與日誌，也不送給 provider。每段對話最多 1,000 筆，超過後新出現的改用一般遮蔽標記，工具結果寫明「這個欄位的附件連結過多，AI 無法編輯」。
  - **只還原回原處：** `[[upload:u-<n>]]` 只在記錄它的同一個資源的同一個欄位中還原（例如同一張議題的描述、同一則留言、同一個 Release 的說明），而且位置由 tokenizer 判定，只能是以下其中之一：Markdown 連結或圖片的目標（`](` 之後只有它，之後可接空白加標題，再接 `)`）；`<img>`、`<a>`、`<video>`、`<audio>`、`<source>` 的 `src`／`href` 屬性值，引號內只有它；原文就是 autolink 時的 `<它>`；以空白分隔的獨立 token。其他位置一律 `policyBlocked`；前後緊鄰 `/`、`?`、`=`、`#`、`:`、`%` 或英數字元時也一樣。
  - 其他資源或欄位（含同一專案的另一張議題、新留言）、`edit_file`、對照表中沒有的編號（從紀錄恢復後、模型偽造）→ `policyBlocked`，回「請重新讀取這個欄位後再提議」。使用者訊息中的上傳連結一律一般遮蔽，回「AI 不能把你訊息裡的上傳連結寫進 GitLab，請在畫面上自行貼上」。
  - **還原不放寬 §5：** 還原出的是 app 驗證過、本來就在這個欄位裡的本 instance 上傳路徑，§5 第 3 點本就不擋這類連結；豁免只涵蓋第 4 點對這段路徑本身的秘密命中。第 1–6、9 點的其餘檢查照常對完整最終文字執行；外部圖片在 (A) 類仍一律 `policyBlocked`，任何等級、任何確認都不能放行。因為只回到原欄位，不會跨資源或跨可見度。
  - 一般遮蔽標記（`[REDACTED…]`）維持 §5 第 5 點的規則，不受影響。
  - **整欄寫回會刪掉看不到的內容：** 寫回同一欄位時，write port 在提議與 dispatch 前的前置讀取中，對目標欄位**目前的值**套用與外送層相同的遮蔽規則，計算最終文字保留不了的段數：不可還原的遮蔽（一般遮蔽標記、他主機上傳、未通過 `projectUploadNamesOk` 的上傳、秘密遮蔽），以及最終文字中沒有還原其 `[[upload:u-<n>]]` 的上傳連結。段數大於 0 時，這種提議在任何等級（含 bypass）都改為確認，預覽標示「這次編輯會移除 N 段 AI 看不到的內容（附件連結或疑似秘密）」，並列入 §4.1 的固定確認清單。不保存原文，也不依賴對話是否讀過這個欄位，所以沒讀過、只在別段對話讀過或程序重啟後的整欄寫回同樣適用。
  - **兩種佔位字串的適用範圍不同：** `[[attachment:att-<n>]]` 只替換進下一點所列的同一專案 (A) 類欄位；`[[upload:u-<n>]]` 只還原進上面所述的同一資源同一欄位（含 Release 說明、里程碑描述與片段描述），下一點的「其他欄位一律 `policyBlocked`」不適用於這項同欄位還原。
- **佔位字串的替換（在提議時）：**
  - 文字寫入只能引用本段對話中、日誌已是 `succeeded` 且結果可用的上傳；否則該工具呼叫回 `attachmentNotUploaded`，不產生提議。上傳與引用它的文字寫入不能在同一批工具呼叫中提議；模型要等上傳完成後再提議引用。
  - 可替換的目標：同一專案的 (A) 類欄位，即留言、討論、行內討論、議題與 MR 描述，以及專案 Work Item 的描述與活動留言（MR6b-3）。群組 Work Item（沒有專案，專案上傳路徑無法解析）、其他專案、檔案內容（`edit_file`）與其他欄位一律 `policyBlocked`。`[[attachment:att-n]]` 只能以空白或換行分隔、單獨出現（它會被換成完整的 `![…](…)`），不得放在連結目標、URL 或其他文字中間；前後緊鄰 `/`、`?`、`=`、`#`、`:`、`%`、`(`、`)` 或英數字元時整筆 `policyBlocked`。
  - 伺服器回傳的 `markdown` 以完整字串解析：只能是單一附件 token `!?[<名稱>](/uploads/<32 個十六進位字元>/<檔名>)`；檔名須通過 `projectUploadNamesOk`，名稱與檔名不得含 CR、LF、NUL、其他控制字元或 `[`、`]`、`(`、`)`；URL 由 app 以驗證過的 secret 與檔名重建。不符時上傳本身仍記為成功（伺服器已接受），但標示「回應格式不符，無法引用」，不替換、不把任何 URL 交給模型；同一附件再上傳依 §7.7 標示可能重複。
  - 處理順序：先對模型文字做 §5 第 1 點的 quick action 中和；替換 `[[attachment:…]]` 與還原 `[[upload:…]]` 之後，對完整的最終文字重驗第 1 點的後置條件（沒有任何一行第 0 欄是 `/`），並重做第 2–6、9 點的判定（只判定、不改寫）。重建的附件連結與還原的上傳連結都是 app 驗證過的本 instance 上傳路徑，第 3 點本就不擋；只有在它們位於上述允許位置時，第 4 點對這段路徑本身的秘密命中以「本執行 ID 的精確字串」豁免。包含它們的其他 URL、其他圖片與外部媒體仍照第 3、4 點。檔名造成的提及與跨專案參照照常判定。任一項不通過，整筆 `policyBlocked`，mutation 為 0。
  - payload digest、預覽與核准都以替換後的最終文字計算與顯示。
- **執行與狀態未知：** 上傳是 REST multipart POST，沿用 §7.4 的送出邊界，結果依 §7.5 分類。狀態未知時 conflict key 為 `(account, project:<id>, upload, 附件 SHA-256)`。這裡以內容雜湊作 key，與 §7.6「建立類不以 payload 分鎖」並不衝突：附件 bytes 只來自使用者，模型無法改動，SHA-256 不同就是不同的檔案，不是換個樣子重送。日誌在 `prepared` 時另存解除名稱：上傳時被接受的檔名原文（通過 `projectUploadNamesOk`，不做會改字的正規化；`requiredText` 就用這串），卡片同時顯示這串原文與 SHA-256 前 8 碼；它綁定 account、project、附件 ID 與 SHA-256（這是安全中繼資料，不是 bytes、`url` 或 `markdown`），所以程序死亡後仍能顯示並驗證解除動作。v2 沒有自動解除（§7.6）；非 maintainer 無法列出專案上傳，GitLab 未必有可核對的位置，所以解除動作的文案為「此上傳可能已存在，但 GitLab 未提供可核對的位置；輸入檔名表示你了解再次上傳可能重複」，日誌記為使用者承擔未知結果後解除，不宣稱已核實。不自動重送；手動解除只解鎖、不會重試，要再上傳必須重新提議（附件若已因程序結束或使用者移除而消失，需使用者重新附檔），且下一次相交上傳依待確認標記需要確認。
- **預算：** 每次上傳計入寫入預算與 HTTP 預算。
- **背景：** 前景服務期間可以上傳（bytes 在記憶體中），送出前同樣經過原生執行許可（§7.4、§12.2）。程序被系統終止時附件隨之消失；尚未送出的上傳（日誌為 `prepared`）在下次啟動記為 `notExecuted`。
- **重複上傳：** 對同一專案提議上傳的附件，若 SHA-256 與日誌中仍保留的成功上傳相同（不限本 run，含程序死亡後另開的 run），任何等級都改為確認並標示「可能重複」；狀態未知的同一 SHA-256 則依隔離被擋（§7.6）。
- **不提供：** 把二進位檔寫進倉庫；從 URL 抓檔再上傳；把 GitLab 上既有的上傳轉存到其他專案。

## 4. 自主等級

### 4.1 上限、起始等級與對話授權

- 每個 GitLab 帳號保存兩個值：
  - **上限（ceiling）：** 使用者設定值，預設「低風險自動」（不低於預設起始等級）。每個 provider 的同意紀錄另存「已同意上限」，該 provider 的契約 hash 綁定它（§10）。實際上限 = min(目前上限, 使用中 provider 的已同意上限)。調高到超過已同意上限，或開啟 bypass，需要重新同意。
  - **起始等級：** 新對話開始時的等級，必須 ≤ 上限，不計入 hash；預設「低風險自動」（擁有者決定）。
- **本次對話授權：** 只能在對話中以明確動作開啟（不得超過上限），對話結束、程序結束或從紀錄恢復時失效，不能設為起始等級。
- 對話內隨時可以調低；調高不得超過上限。
- 降低上限立即生效：只遞增 write-policy revision，不需要重新同意；綁定舊 revision 的提議與核准依 §7.1 作廢，政策閘門在下一次 dispatch 前重判。即使使用者尚未完成任何新同意，也不得沿用較高權限。

| 等級 | T1 | T2 | T3 | T4‡ | 硬底線 |
|---|---|---|---|---|---|
| 唯讀 | 不提供／拒絕† | 不提供／拒絕† | 不提供／拒絕† | 不提供／拒絕† | 不提供／拒絕† |
| 逐一確認 | 確認 | 確認 | 確認 | 輸入名稱 | 輸入名稱 |
| 低風險自動（預設起始） | 自動＊ | 確認 | 確認 | 輸入名稱 | 輸入名稱 |
| 本次對話授權 | 自動＊ | 自動＊ | 自動＊ | 輸入名稱 | 輸入名稱 |
| 完全放行（bypass） | 自動＊ | 自動＊ | 自動＊ | 自動＊ | 輸入名稱 |

＊自動仍需滿足 §2 的目標綁定（低風險自動另需意圖詞）、§5 的文字規則、預算與範圍，且不在下方固定確認清單內；不滿足就改為確認。

‡重跑 Pipeline、重跑 Job、播放 Job 是 T4 中的例外：在「輸入名稱」的等級只需按確認（§0 第 12 點）。

†實際上限為唯讀時 segment 不含寫入工具；只把目前等級調到唯讀時，工具仍在凍結的工具清單中，但政策閘門一律拒絕（§9）。

**固定確認清單（任何等級都要確認，含 bypass；列入 writePolicy）：** `markAllTodosDone`；含非本段對話建立草稿的整批送出（§3）；`@all`、`@here`、群組提及與超過 5 位使用者提及（§5）；(B) 類會被 GitLab 渲染的 Markdown 中出現外部圖片或媒體（§5；(A) 類一律 `policyBlocked`，確認也不能送出）；範圍外的自動關閉關鍵字與跨專案參照，包括合併前檢查發現的既有關閉效果（§3、§5）；續跑時與本 run 已成功或狀態未知寫入相同的提議（§7.7）；整欄寫回會移除 AI 看不到的內容（§3.1）。另有只在 bypass 以外需要確認的情況：機密性與可見度污染（§5）、head 變更後的合併或核准（§7.8）、使用者手動解除後的下一次相交寫入（§7.6 的待確認標記，耐久保存於 §8）、重設寫入日誌後 24 小時內的寫入（§8）。

### 4.2 開啟 bypass

- 只能在前景、可信的設定頁完成：顯示完整 instance、帳號、numeric user ID；輸入目前 `@username`；再做一次裝置驗證（沿用 app lock 的 `local_auth`）。裝置沒有生物辨識也沒有螢幕鎖時無法開啟，規則與 app lock 相同，設定頁顯示原因。
- 說明：T1–T4 會直接執行（含刪除、合併、CI；重跑 Pipeline、重跑 Job、播放 Job 在目標綁定成立時會自動執行，而且重跑或播放可能沿用 GitLab 上已存的原變數與 inputs（前次的 Pipeline 與 Job 變數），排程建立的 Pipeline 還會使用排程**目前**的變數；app 讀不到也無法核對，§0 第 12 點）、CI 本身的副作用不是 app 能判定的（與 §10 同意框同一句）、prompt injection 的殘餘風險、預算與停止的實際界線。
- 不得由 deep link、通知或模型呼叫開啟。
- bypass 或本次對話授權生效時，對話頁頂部常駐醒目標示，含「停止」。

### 4.3 bypass 也永遠不會做的事

1. 寫入範圍外的資源（含經由自動關閉關鍵字或跨專案參照、未經確認就影響範圍外資源），或使用未經歸屬驗證的全域 ID。CI 設定觸發的下游 pipeline 是 CI 的行為，不是 app 的寫入，依 §3 與 §10 揭露，不另列入固定確認清單。
2. 未經輸入名稱就執行硬底線操作；跳過固定確認清單（§4.1）。
3. 使用模型提供的 URL、HTTP 方法或任意 API 路徑。
4. 送出未經 §5 處理的文字（quick action、大量提及、外部圖片、已知秘密、遮蔽標記）。
5. 在相同 conflict key 為 `dispatching` 或狀態未知時，再對它寫入（§7.6）。
6. 在 generation、API、收件者 revision、同意、政策或原生執行許可任一失效後繼續寫入。
7. 超過寫入預算。
8. 由通知、連結或 app_links 核准、變更等級、開啟 bypass 或解除狀態未知的鎖。
9. 接受模型提供的既有檔案或既有片段的整份內容：既有檔案與既有片段只接受 §6 精確片段；新檔案與新片段只接受一份初始正文，依 §5 全文掃描後由 app 送出。
10. 修改等級、範圍、同意或任何防護設定。

### 4.4 寫入預算（每次 dispatch 都在送出前原子保留；成功、失敗、狀態未知都消耗；`notExecuted` 退回）

- 寫入計入 v5 的每輪 4 個、每次送出 12 個 tool call 上限。
- 40 次 GitLab HTTP 是唯讀與寫入 port 共用的每次送出預算，包含：前置讀取、核准後的新鮮讀取、合併前的既有變更檢查、排程參數讀取（§3）、mutation 本身、獨立 readback（含 GraphQL 方法內部的前置讀取與 readback，以 ledger 列的上限計）、分頁、固定 GraphQL query 與允許的 OAuth 讀取重放。產生提議時一併保留到 readback 為止所需的有界額度；保留不到就不產生提議，不在使用者核准後才因額度不足失敗。下列「每次送出寫入 ≤ 8」是名目上限，實際也受這個 HTTP 預算約束。
- 每次送出：寫入 ≤ 8，其中 T4 ≤ 3。本節所有「T4」上限都包含硬底線操作與 §0 第 12 點的三項 T4。
- 每段對話：寫入 ≤ 40，T4 ≤ 10；計數存在日誌的對話計數表（§8），第一次實際 dispatch 時才建立，與 7 天明細分離；換段、續跑、重啟都不歸零；計數無法讀取時拒絕寫入。紀錄關閉時對話不會跨程序保存，計數也只在本程序內有效（重啟後無法續聊該對話）。
- 每個帳號跨所有並行對話、滾動 60 分鐘：寫入 ≤ 60，T4 ≤ 10；以日誌中 60 分鐘內的 dispatch 紀錄計算。
- 批次操作（批次套用建議、整批送出審查草稿）另限受影響資源數（≤ 20），不能把大量變更當成一次寫入。
- 使用者觸發的「重新讀取以確認」（§7.6）用另計的有界預算（每次 ≤ 10 個 GitLab 請求），永遠不重送 mutation。
- 超過即停止該 run 並回報；這些上限與 v5 既有上限取較嚴者，不放寬既有上限。

## 5. 文字寫入的安全處理（任何等級都適用，包含 bypass）

適用範圍分兩類。使用者在卡片上修改後的文字也走同一流程。
- **(A) 會執行 quick action 的 Markdown 欄位：** 留言、討論與回覆、行內討論、草稿審查留言、議題與 MR 描述、Work Item 描述與活動留言。適用第 1–9 點。
- **(B) 內容欄位：** 標題、commit message、tag message、Release 說明、片段描述與內容、檔案內容（`edit_file` 的 `old`／`new` 與新檔案）、檔案路徑與其他非 Markdown metadata。**不做** quick action 中和，也**不改寫**內容；適用第 2–6、8、9 點中標明適用於 (B) 的部分。某段內容無法安全處理時，拒絕或要求重新提議，不悄悄改碼。

1. **quick action 中和（只限 A）：** 一律套用 `neutralizeForGitLabDraft`（`lib/core/ai/quick_actions.dart`），處理後任何一行的第 0 欄不得是 `/`；後置條件不成立回 `policyBlocked`。模型要達成 quick action 的效果，必須呼叫對應的具名工具，由該工具決定層級。
2. **提及：** (A) 沿用 v5 §6.6，預設改成 code span；(A) 中的 `@all`、`@here`、群組提及，以及超過 5 位使用者提及，在任何等級都需要確認。(B) 的提及判定只套用在 Markdown 檔（只看變動區塊）、Release 說明與片段描述，條件相同；只判定是否需要確認，不改寫。程式檔中的 `@param`、decorator 不算提及。
3. **外部圖片與媒體嵌入：** (A) 中指向非本 instance 的圖片或媒體嵌入一律 `policyBlocked`（GitLab 網頁在他人瀏覽時會自動載入，是外流通道），確認也不能送出。(B) 中會被 GitLab 渲染成 Markdown 的內容（Release 說明、`.md`／`.markdown` 檔案與片段）出現外部圖片或媒體時，任何等級都需確認，預覽列出網域。外部連結列在預覽與稽核列；自動等級下只放行使用者自己訊息中出現過的網域，其餘改為確認。
4. **秘密：** 以當下已知秘密的聯集（含 pattern 別名）與既有偵測器掃描**完整、正規化的最終 payload**（所有文字欄位、檔名、路徑、commit message、變數、metadata）；命中或掃描不可用即拒絕。不得只掃預覽或截斷結果，也不得先遮蔽再提交。例外只有既有檔案與既有片段的精確片段編輯：掃描單位是每段 `new`、套用後的每個變動區塊及其前後各 3 行、路徑與 commit message；原檔未變動區段中的既有命中不阻擋（它早已在 GitLab 上，這次寫入沒有讓它多外流），但預覽標示「檔案已含疑似秘密 N 處（未變動）」；已知秘密（GitLab 憑證、provider key 與其 pattern 別名）只要出現在變動區塊即拒絕。新檔案與新片段全文掃描。
5. **遮蔽與標記：** payload 含遮蔽標記（`[REDACTED…]`）、untrusted-data 標籤或私鑰保留標記即拒絕。精確片段編輯只檢查每段 `new` 文字，以及 `new` 與相鄰原文拼接後跨越邊界的命中；原檔已有的這類字樣不阻擋附近的編輯（秘密掃描仍依第 4 點）。上傳路徑的可還原佔位字串 `[[upload:u-<n>]]` 不是遮蔽標記，依 §3.1 還原或擋下。
6. **機密性與可見度污染：** 本段對話只要讀過可見度限制比寫入目標更嚴格的來源（例如私有專案、私有群組或機密議題的內容，寫進 internal／public 的專案、群組或非機密議題），之後寫到這類目標時，在 bypass 以外的等級都需要確認，並在卡片上標示來源。群組可見度與專案可見度同等比較；來源或目標的可見度讀不到時，視同污染，改為確認。
7. **AI 標註（擁有者決定：預設關閉）：** 設定開啟後，在 AI 撰寫的 (A) 類留言與描述末尾加一行「由 AI 助手撰寫」（在地化），計入 payload 後再做上述檢查。
8. **預覽：** 顯示經上述處理後實際會送出的文字（檔案與片段顯示 diff），並列出提及、跨資源參照與可見性影響。
9. **自動關閉與跨專案參照（A，以及 commit message）：** GitLab 會在 commit 推到預設分支、或 MR 合併到預設分支時，依 commit message 與 MR 描述中的 closing pattern 關閉議題，也支援 `group/project#123` 這類跨專案參照（GitLab 文件「Closing issues automatically」，2026-10-21 核對）。closing pattern 指向範圍外的議題，或任何跨專案參照（`group/project#n`、`group/project!n`、指向其他專案的完整 URL），在任何等級（含 bypass）都改為確認。範圍內的 closing pattern 照常，但預覽列出「合併或推送到預設分支後將關閉的議題」。合併既有 MR 時，關閉效果以 §3「合併前的既有變更檢查」取得的伺服器清單（`closes_issues`）為準，不只掃本機關鍵字。

## 6. 檔案修改（`edit_file`）

- 只接受精確片段 `{path, branch, edits: [{old, new}], commitMessage}`；每段 `old` 必須在完整內容中恰好出現一次；各段 `old` 的範圍不得重疊，重疊即拒絕；所有片段都以原內容中的位置套用。不接受既有檔案的整份內容。
- app 在提議時：先以 `fileMetadata(project, path, branch)` 取得 `last_commit_id`（L），再以 `textFile(project, L, path)` 讀取 L 的**完整、未遮蔽**內容（40–64 hex 的 ref 走不可變快取）。內容與 L 來自同一個 commit，不以兩次 live 分支讀取拼接快照（`textFile` 傳分支名時會另做 HEAD 與 raw 兩次請求，中途有人 push 就可能得到「舊內容＋新 L」，送出後會靜默回退中間那次修改）。在本機套用片段，以 app 算出的 diff 作為預覽。完整內容不送給 provider；tool 結果只回傳遮蔽後的 diff 摘要。
- 提議綁定 L、原內容 digest 與最終 diff digest。核准後的新鮮讀取同樣先取 metadata；L 改變就作廢提議並重新提議，不重讀後悄悄沿用核准。
- 執行時帶 L 作為 `last_commit_id`，伺服器端不符即衝突失敗。缺 `last_commit_id` 時不得退回 POST。
- 以下任一情況 `policyBlocked`：片段含遮蔽標記、untrusted-data 標籤或私鑰保留標記（範圍依 §5 第 5 點）；目標是敏感路徑；檔案超過 `maxTextBytes` 或為二進位。目標是 CI 設定檔時走硬底線確認（不是阻擋）；目標分支為預設或受保護分支時升為 T4（§3）。
- 新檔案用 `saveFile` POST（已存在即失敗），接受一份初始正文並全文掃描；刪除用 `deleteFile` 帶 `last_commit_id`（T4）。
- 片段（snippet）的內容編輯使用同一套精確片段規則（§3「片段內容」）。

## 7. 執行模型

### 7.1 提議與綁定

- 模型呼叫寫入工具 → app 驗證並正規化參數、做歸屬驗證與前置讀取、計算實際層級、執行 §5／§6 處理、產生預覽 → `AiWriteProposal`。
- 政策閘門結果：`deny | requireApproval | execute`。模型即使呼叫未提供的工具，也完整驗證後拒絕。
- 提議與一次性核准綁定：account key（完整 instance＋numeric user ID）、session generation、API owner、conversation 與 run、operation、全部目標 ID 與 conflict keys、正規化最終 payload digest、預覽版本、前置 revision／SHA／`last_commit_id`、合併前檢查的摘要（head sha、路徑集合 digest、將關閉議題集合）、排程參數的 HMAC（§3）、帳號的「提議與核准 epoch」（§8 帳號移除）、scope revision、write-policy revision、consent hash、到期時間、執行 ID（nonce）。
- 使用者修改內容後重新做 §5、分級與預覽，舊核准立即失效。

### 7.2 等待確認（`awaitingApproval`）

- run 進入明確的暫停狀態：凍結前綴不動、沒有模型呼叫、v5 的 12 分鐘 run 時限暫停（只計主動執行時間，恢復後只用剩餘時間，不重新給 12 分鐘）；另以牆上時鐘計 30 分鐘到期。
- 待確認的提議不寫入日誌；程序死亡後全部作廢。
- 停止、到期或 guard 失效時，tool 結果是「未執行：已停止／未在時限內確認／設定已變更」；與「可能已執行」是不同的結果字串。到期不寫成「使用者拒絕」。
- 使用者在卡片上改過的內容，在拒絕、確定失敗、狀態未知或到期後保留在卡片上；只有成功並 readback 確認後才清除。
- 核准後在安全的續點重新取得 guard、等級、範圍、預算、帳號的「提議與核准 epoch」（§8）、新鮮度前置讀取（sha、`last_commit_id`、`updated_at`、合併前檢查、排程參數 HMAC 的重算），不恢復已死亡的 Future。

### 7.3 執行協調與衝突

- **擁有者：** `AiWriteJournal.instance`（§8）是程序級單例，同時持有隔離表，不隨 generation、`AiRunRegistry` 或聊天頁釋放。帳號範圍的 `AiWriteCoordinator` 依每個工具宣告的 conflict domain（帳號全域、專案、MR、Work Item、ref／path、Job 等）仲裁；判斷隔離一律以日誌為準，不只看自己記憶體中的鎖，所以切帳號、generation 改變或「立即切換」後再切回來，`dispatching` 中的寫入仍擋住相同 key。
- **每筆寫入的順序：**
  1. 核准（或政策自動執行）後，在帳號級短臨界區內：以日誌檢查隔離與待確認標記、確認帳號沒有移除 tombstone（§8；從 secure storage 讀取，`unavailable` 或讀取失敗視同存在）、保留預算、寫入 `prepared`。
  2. 取得 conflict-domain 鎖。
  3. 最終新鮮前置讀取（含合併前的既有變更檢查）。
  4. 送出邊界（REST 在呼叫具名方法之前；GraphQL 在 `beforeMutation` 掛鉤內，緊鄰唯一 mutation 之前，§7.4），固定順序：
     1. 不連網的預檢：client 未關閉、`Retry-After` 未到期；
     2. 綁有原生執行許可的 run 取得一次性的送出票（§12.2）；
     3. 在帳號級短臨界區內再次以日誌檢查隔離與待確認標記，並確認沒有移除保留與移除 tombstone（§8），才寫入 `dispatching` 並 flush；
     4. flush 的 await 返回後，**同步**重驗：停止旗標、帳號 generation、帳號沒有「移除中」保留（`AiRemovalHold`，§8；不是 cleaning 旗標）、帳號沒有移除 tombstone（`AiWriteJournal.instance` 在記憶體中的 tombstone 旗標，§8）、提議綁定的「提議與核准 epoch」仍等於帳號目前的值（記憶體值，可同步讀取）、API owner、scope／policy／consent revision、送出票尚未使用、client 未關閉、`Retry-After` 未到期（與 `_send` 的同步檢查相同；flush 期間其他對話的讀取可能剛收到 429），以及沒有許可的 run 時 app 仍在前景（iOS 同樣）。這個檢查到唯一 mutation 呼叫之間不得再 await。通過這一刻就是**接受點**。第 4.1 步保留，作為不進入 flush 的快速路徑。
  5. 送出 mutation；得到結果後在帳號級短臨界區內寫入終態。
  6. 終態寫入日誌之後才釋放 conflict-domain 鎖。
  第 2 步到第 4.3 步之間發現隔離、預算不足、前置讀取失敗、預檢不通過或拿不到送出票時，該筆 `prepared` 改為 `notExecuted` 並退回保留，不消耗 §4.4 的對話計數與 60 分鐘視窗，也不消耗待確認標記，不呼叫 mutation。第 4.4 步的同步重驗不通過時，mutation 確定尚未開始：這是唯一允許的 `dispatching` → `notExecuted` 轉移，與退回保留、恢復待確認標記在同一次原子更新中完成；這次落盤失敗則維持 `dispatching`，隔離持續。接受點之後的任何結果依 §7.5 分類。帳號級短臨界區只包住日誌讀寫與預算保留，不持有到 HTTP 結束。等待確認期間不持鎖。
  終態落盤失敗：mutation 已送出而終態寫不進日誌時，本程序記憶體中的隔離表把該筆視為 `writeUncertain`，隔離維持，手動解除立刻可用；但解除本身也要寫進日誌才生效，日誌仍寫不進去時鎖不解除。磁碟上維持 `dispatching`，重啟後轉為 `writeUncertain`。
- 每段對話同時最多一個進行中的 GitLab 請求（讀或寫）：`_pendingRead` 擴充為 `_pendingGitLab`；soft-timeout 後仍在跑的讀取會擋住寫入，其相依提議作廢。
- 沿用 Work Item 與草稿審查既有的單次 target、獨立 readback、revision／actor 檢查，不因重用底層 HTTP 方法而繞過。AI 對 Work Item 狀態、日期、健康度的寫入，登記到畫面既有的程序級寫入登錄（`WorkItemStatusWriteRegistry`；`graph_work_items_page.dart` 內 private 的日期與健康度登錄移到可共用的位置）；登錄顯示該 Work Item 有寫入進行中時，AI 不 dispatch，AI 進行中時畫面也看得到。

### 7.4 dispatch

- **REST 具名方法**（含 `uploadProjectFile`）：在呼叫方法之前走完 §7.3 第 4 步的送出邊界；flush 失敗或同步重驗不通過就不送。
- **GraphQL 寫入方法**（Work Item、事件單、待辦延後）：方法內部有前置讀取，不能在呼叫前就寫 `dispatching`，否則前置讀取的失敗會被當成寫入失敗上鎖，而且前置讀取期間（可達連線 15 秒加接收閒置 25 秒）許可可能失效。MR6b-3 為每個方法加上：
  - awaited 的 `beforeMutation`（`Future<void> Function()`），在方法內部前置讀取之後、唯一 mutation 之前呼叫；write port 在裡面做 §7.3 第 4.1–4.3 步，失敗就丟出，不送 mutation。
  - 同步的 `mayStart`（`bool Function()`），方法在 `beforeMutation` 返回後、緊接 mutation 之前呼叫，中間沒有 await；write port 在裡面做第 4.4 步的同步重驗並使用送出票，回 false 時方法不送 mutation、直接返回「未送出」。
  - 狀態方法現有的 `onMutationSent(started)` 是同步回呼，必須在其中呼叫 `started`，否則方法會以 `mutationSent: false` 丟出 `cancelled`。新掛鉤放在 `onMutationSent(started)` 之前；AI 傳入的 `onMutationSent` 只呼叫 `started`。其他方法的 `onMutationSent`（同步的 `void Function()`，只有指派、日期、健康度、標籤、里程碑、權重有）只供畫面顯示進度，不寫日誌。掛鉤為 null 時，畫面的行為維持現況。
  - write port 自己記錄這次執行走到哪一步（未呼叫掛鉤、掛鉤失敗、`mayStart` 回 false、已過接受點），分類以這個紀錄為準（§7.5），不靠方法的返回形狀推斷。
  - ledger 每列寫明方法內部的 HTTP 次數上限（前置讀取＋mutation＋readback），計入 §4.4 的保留；方法內已有獨立 readback 的，不再另做第二次。
  - `setIncidentStatus` 一律帶前置讀取的 `expectedUpdatedAt`（目前是選填）。
  - 待辦延後與取消延後的歸屬與成功證據見 §3「待辦延後的歸屬」。
- 寫入**不套用** 20 秒 soft deadline，也不合成可重試的 `timeout`；上限由 `GitLabApi` 自身的連線（15 秒）、送出（15 秒；AI 附檔上傳依 §3.1 另訂）、接收閒置（25 秒）與 byte 預算控制。讀取的 20 秒 soft deadline 保留。
- 沿用既有不變式：寫入不自動重試；非 GET/HEAD 的傳輸錯誤為 `writeUncertain`；OAuth 401 refresh 只重放 GET/HEAD 與固定 GraphQL query；寫入沿用既有 `GitLabApi`，不另開會跟隨重新導向的 client。
- 合併、核准帶預覽時的 head sha；檔案更新、刪除帶 `last_commit_id`。沒有伺服器端 compare-and-swap 的操作，明示殘餘競態，不宣稱原子衝突保護。

### 7.5 結果分類、停止、逾時與帳號變更

- dispatch 前停止：`notExecuted`。
- REST 方法在 dispatch 後依 `ApiFailure.kind`（`lib/core/failure.dart`）分類：
  - **成功**（`succeeded`）：2xx 且回應可解析（`writeEmpty` 的 204 亦是）；readback 後顯示為已確認。mutation 得到 2xx 之後，readback 的任何失敗（含 401）只影響是否顯示「已確認」，不會把它改回未執行；取消自動合併等以 readback 定義成功的操作，readback 失敗記狀態未知（§3）。
  - **確定未執行**（`failedCertain`，不上鎖）：`validation`（400／422）、`forbidden`（403）、`invisible`（404；顯示時依 AGENTS.md 的 404 歧義規則，不說成「已刪除」）、`conflict`（409／412）、`rateLimited`（429，含本機 `Retry-After` 快速失敗）、**mutation 請求本身**的 HTTP 401 回應（PAT 的 401；OAuth refresh 失敗的 401；`_send` 在 refresh 成功後不重放寫入時丟出的那一個 401，以及已收到 401、但 refresh 本身丟出例外的情況。401 表示伺服器在執行前就拒絕了這個請求；不重放只是不重試，不是狀態不明。MR6b-1 讓 `_send` 在這兩條路徑丟出的失敗帶 `status: 401`，kind 維持 `writeUncertain`，畫面依 kind 的既有文案不變；分類由 write port 依 status 做：refresh 成功時顯示「登入已更新，這次寫入沒有送出，可再提議一次」，PAT 或 refresh 失敗時顯示「登入已失效」。只適用 REST 具名方法，因為它們都只發這一個請求。mutation 已得到 2xx 之後的 readback、分頁或新鮮度讀取即使收到 401，仍依下方為狀態未知；GraphQL 方法無法分辨 401 來自 mutation 還是方法內的 readback，依下方 GraphQL 規則處理（`mutationSent` 為 true 即狀態未知；OAuth token 到期，或 PAT 在接受點與 mutation 之間被撤銷，會讓 GraphQL 寫入上鎖，列為已知限制）。沒有 HTTP status 的本機 `unauthenticated`（例如 `currentUser` 為 null）不適用這一條）、送出前的本機拒絕（`unsupported`、`attachmentTooLarge` 等）。
  - **狀態未知**（`writeUncertain`，上鎖）：`writeUncertain`（傳輸錯誤、回應超出 byte 預算）、`cancelled`、`server`（5xx）、`redirectBlocked`、2xx 但 body 為空或無法解析，以及任何未列出的種類。
- **GraphQL 方法的結果**先看 write port 記錄的送出邊界（§7.4），再看方法的結果；不以「方法正常返回」或外層例外類型推斷，也不經 `safeFailure`（它會把非 `ApiFailure` 壓成 `invalidResponse`，吃掉 `mutationSent`）：
  - **還沒過接受點**（掛鉤未呼叫、掛鉤失敗、`mayStart` 回 false）：不論方法正常返回或丟出例外（含種類為 `writeUncertain`、`cancelled` 的例外），一律 mutation 為 0，記 `notExecuted`：不上鎖、退回預算、不消耗待確認標記。其中，方法在掛鉤之前返回、且回傳值顯示目標已等於要求值（`noop` 狀態，或與要求值相同的原快照）時，記為「無變更」，同一輪後續工具照常執行；ledger 每列寫出這個判定（例如日期 `applied` 且 `mutationSent` 為 false、健康度與狀態與標籤的 `noop`，以及指派、里程碑、權重、通知、狀態、內容、事件單、活動留言編輯返回的相同快照）；其餘（例如日期 `notApplied` 且 `mutationSent` 為 false 的驗證或權限失敗）仍適用同輪 fail-stop。
  - **過了接受點：** 日期只有 `applied` 且 `mutationSent` 為 true 是成功，`notApplied` 或 `writeUncertain` 為狀態未知；健康度只有成功且 `mutationSent` 為 true 是成功，其餘為狀態未知；狀態（`WorkItemStatusSaveResult`）只有 `success` 且 `mutationSent` 為 true 是成功，`notApplied` 且 `mutationSent` 為 true 為狀態未知（這是正常返回，不在失敗型別裡）；`WorkItemLabelWriteFailure`、`WorkItemStatusWriteFailure`、`WorkItemHealthEditFailure` 只有在 `mutationSent` 為 false 且內層 `ApiFailure` 屬上列「確定未執行」時是 `failedCertain`，其餘為狀態未知。
  - mutation 已回應成功、但其後的 readback 遇到 `cancelled` 或失敗：狀態未知，不記成功。
  - 每個 GraphQL ledger 列寫明上述對應；新方法沒有寫明之前不得交付。
- 寫入過了接受點之後，`GitLabApi` 回傳的 `cancelled` 一律記為 `writeUncertain`，不得記為 `notExecuted`：`GitLabApi.close()` 之後，即使伺服器已回 2xx，呼叫端也只會收到 `cancelled`。接受點之前（含已 flush 但同步重驗不通過、`mayStart` 回 false）仍是 `notExecuted`。
- **晚到的結果只在兩種情況存在：** runner 的停止與 run 逾時不關閉 GitLab client，這時稽核列持有該 Future，晚到的確定結果由 `AiWriteJournal.instance` 收尾，不顯示到新帳號。切換帳號、登出、client close 與程序死亡不存在晚到結果，在途寫入一律 `writeUncertain`（切帳號與移除帳號的等待規則見 §12.1）。
- 同一輪中，只要有一個寫入以非成功結束（拒絕、確定失敗、狀態未知、未執行；「無變更」除外），其後的寫入一律不執行，回「前一個寫入未完成，未執行」。

### 7.6 狀態未知的隔離

- **conflict keys：** 每個 ledger 列宣告 app 正規化、與 operation 名稱無關的 key，分別列出寫入的 key 與依賴的 key：
  - 專案議題、task、事件單：`(account, project:<id>, workItem, iid)`；MR：`(account, project:<id>, mergeRequest, iid)`。REST 列與 GraphQL 列共用同一把 key，GraphQL GID 只作別名，由前置讀取解析。
  - 群組 Work Item：`(account, group:<Group GID 的數字 ID>, workItem, iid)`，Work Item GID 為別名；它的留言、表情與通知，ledger 寫明依賴這把 key。專案 Work Item 不論從哪個頁面開啟，都用專案 key（§2）。
  - 檔案：寫入 `(account, project:<id>, ref, 正規化路徑)`，依賴 `(account, project:<id>, ref)`；合併寫入 MR 與目標 ref。
  - 其他專案資源：`(account, project:<id>, 資源種類, 資源 ID 或唯一名稱)`；帳號全域操作用 `(account, todos)` 這類集合 key；附件上傳見 §3.1。
  - 父子相交：刪除議題、MR 或 Work Item 與其所有子資源相交；看板卡片移動與議題標籤更新共用該議題的 key；Job 的寫入依賴其所屬 Pipeline 的 key，Pipeline 的 retry、cancel、delete 與其所有 Job 的 key 相交（避免狀態未知的 Job 重跑與 Pipeline 重跑重複執行同一個 Job）。
  - 建立 Pipeline 與播放排程以建立類 key `(account, project:<id>, pipeline)` 鎖定。
  - key 以數字 ID 或 GID 為準，改名或路徑字串改變不會解除鎖。
- **建立類操作**在還沒有結果 ID 時，鎖定 `(account, 父資源, 建立的資源種類)`，例如狀態未知的 `createNote` on !12 會擋住之後在 !12 上的所有新留言。payload、nonce 或尚未取得的 ID 都不能用來繞過鎖（附件上傳的例外與理由見 §3.1）。
- **隔離：** 明細處於 `dispatching` 或 `writeUncertain` 時，寫入或依賴其 key 的提議，在任何等級、任何對話、任何 generation 都不會產生或 dispatch。換 nonce、換 tool-call ID、追問、換段、續跑、從紀錄恢復都不能解除。
- **重新讀取以確認（只產生觀察，不解除）：** 原請求的 Future 已結束或程序已重啟後，使用者可以按「重新讀取以確認」。這只代表可以開始讀取，不代表伺服器已停止處理原 mutation：客戶端拿不到伺服器取消或交易完成的證明，原請求可能在讀取之後才落地，晚到的請求也可能作用在解鎖之後的內容上。因此讀取結果只是**觀察**，例如「目前已是訂閱狀態」「目標仍存在」「找不到符合的新留言」「找到名稱相同的分支」「找不到或無權限檢視」。觀察顯示在卡片與「中斷的寫入」區塊、存進日誌，但**不**解除隔離，也不寫成已執行或未執行。建立類的觀察以前置讀取回應的 `Date` 標頭推算伺服器時間，前後各放寬 5 分鐘，再以名稱或 payload digest 比對；觀察相符也不代表那就是原請求建立的。v2 沒有自動解除。
- **手動解除（擁有者 2026-10-21 決定）：** 提供到 GitLab 查看的連結（由已驗證的 instance／ID 組成），以及可信的 UI 動作「我已在 GitLab 核對，解除鎖定」：只能在前景的對話頁或 AI 設定頁執行，經 `confirmAction(requiredText:)` 輸入該筆明細的確認名稱（§3「解除狀態未知的鎖」，以明細為單位）；日誌記為 `resolvedByUser`；只解除鎖，不自動再 dispatch。通知、連結與模型都不能觸發這個動作。解除時同時在日誌耐久寫入這些 key 的「待確認標記」（§8）：之後第一次相交寫入在 bypass 以外的等級一律需要確認。
- **全部的解除路徑都要輸入名稱：** 單筆手動解除（本節）、重設寫入日誌（§8，輸入 `@username`）、移除仍有隔離的帳號（§8、§12.1，輸入 `@username`）。沒有其他會解除隔離的使用者動作。系統路徑只有 orphan cleanup：`accountsLoaded` 證明帳號已不存在時清除日誌（例如 iOS 完整還原後帳號清單為空）；之後重新加入同一帳號時不保留舊的隔離，列為殘餘風險。
- **跨裝置的殘餘風險：** 隔離只存在於本裝置的日誌；同一帳號在另一台裝置、網頁或其他工具上的寫入不受這把鎖約束。這一點寫進同意框「狀態未知」的說明。
- 讀取使用 §4.4 另計的有界預算。§7.5 的「確定未執行」不上鎖。

### 7.7 回給模型、顯示與續跑

- 寫入結果經欄位白名單投影與遮蔽後回給模型（GitLab 回應常含整個物件與 token 形狀的字串，例如上傳回應的秘密 URL）。
- projection 與 `restoreFromDisplay` 以一行帶結果的摘要呈現每個寫入，例如「寫入 留言 on !12：成功 #note_123」「寫入 合併 !12：狀態未知，勿重試」，確保續跑後不會重做已完成的寫入；從紀錄續聊永遠不恢復可執行的提議或舊核准。
- **續跑不重複：** 續跑（Android 回到前景後的使用者續跑、iOS 回前景、`fgsTimeout` 之後）重送的是模型請求。本 run 中已進入 `dispatching` 或任何終態的執行不再呼叫 mutation，只把一行摘要放進投影。續跑產生的新提議若與本 run 已成功或狀態未知的寫入有相同 operation 與 conflict keys，任何等級都改為確認，卡片標示「可能重複」。
- 顯示狀態區分：未執行、成功（已接受）、已 readback 確認、確定失敗、狀態未知（附最新觀察）、使用者已核對。自動合併「已排程」不等於「已合併」。
- `AiToolRunStatus` 與紀錄 codec 擴充上述狀態；紀錄格式版本 +1（舊版 app 視為 unsupported 並保留）。
- 稽核列：時間、對象、結果、由已驗證的 instance／ID 組成的 GitLab 連結（不使用模型提供的 URL）。「不可編輯」指 UI 上不能改，不是防竄改的伺服器稽核。

### 7.8 同一 MR 的 head 變更

合併或核准因 sha 不符而失敗後，本段對話中對該 MR 的後續合併或核准，在 bypass 以外的等級一律需要確認，卡片顯示「自上次預覽後 head 已變更：+N commits」。

## 8. 寫入執行日誌（新的本機持久化，擁有者已同意）

- **目的：** 讓「每個操作最多 dispatch 一次」與「狀態未知」在停止、逾時、切帳號、程序死亡後仍成立。它是寫入安全狀態，與聊天紀錄的開關、清除、保留期與容量都無關。
- **擁有者：** 程序級單例 `AiWriteJournal.instance`，不隨 generation、`AiRunRegistry` 或聊天頁釋放；同時持有隔離表與待確認標記。與 `AiHistoryCoordinator` 分開；參與同一個 `AiAccountMutationCoordinator` 的帳號 mutation／cleanup fence。所有狀態轉移在帳號級短臨界區內完成（§7.3）。
- **內容**（只存必要中繼資料）：執行 ID、程序 ID（`processId`，每次程序啟動隨機產生）、conversation ID、run ID、account key、instance、session generation、operation、寫入與依賴的 conflict keys、正規化目標、payload SHA-256、綁定的 revision 值（`last_commit_id`、head sha、前置讀取的 `updated_at`、合併前檢查摘要）、policy revision、預算保留、時間、遮蔽後的一行摘要、手動解除名稱（`prepared` 時由前置讀取決定，§3；上傳為驗證過的檔名，§3.1）；狀態未知時另存最新的觀察摘要（§7.6）。不存內文、檔案內容、附件 bytes、上傳的 `url` 或 `markdown`、憑證或 provider replay。
- **狀態：** `prepared` → `dispatching` → `succeeded | failedCertain | writeUncertain | notExecuted`；`writeUncertain` → `resolvedByUser`（v2 只有手動解除）。`prepared` 在進入 conflict-domain 鎖之前、帳號級短臨界區內寫入；之後發現隔離、預算不足或前置讀取失敗時改 `notExecuted` 並退回保留。`dispatching` 與 `writeUncertain` 都是隔離狀態。`dispatching` → `notExecuted` 只允許在 §7.3 第 4.4 步的同步重驗不通過時（mutation 確定尚未開始）；其他情況下 `dispatching` 只能進入終態或在重啟時轉為 `writeUncertain`。
- **待確認標記：** 手動解除時，對該筆的 conflict keys 耐久寫入「下一次需確認」標記。標記不隨明細淘汰，不受清除聊天紀錄或換段影響。只在相交寫入進入 `dispatching` 時，與狀態轉移及預算保留在同一次原子更新中消耗（bypass 下也消耗並記錄）；拒絕、到期、停止、前置檢查失敗都不消耗。
- **對話計數表：** 第一次實際 dispatch 時才建立該對話的計數項（沒有 dispatch 的對話不建立）；記錄寫入數、T4 數與最後使用時間。與明細分離，不隨 7 天或 200 筆淘汰；清除聊天紀錄也不刪除。對話每次以可寫 segment 送出時更新最後使用時間（每日至多一次）；90 天未使用的計數項才回收（聊天紀錄最長保留 90 天，超過即不可能續聊）。已知的寬鬆邊界：若實際上限被調到唯讀超過 90 天、期間仍以唯讀繼續聊天，之後再調回可寫時該對話的計數從零開始；預算是防濫用上限，不是授權，這不構成安全缺口。
- **帳號滾動 60 分鐘視窗**以日誌中 60 分鐘內的 dispatch 紀錄計算。
- **儲存：** 每帳號一份，目錄 `<application-support>/ai_write_journal/<sha256(account.key) 前 32 hex>/`，與 `ai_history/` 分開，不得放在其下。AES-256-GCM，每次寫入用新的 12-byte nonce，AAD 綁定 envelope 版本、account 與檔名；路徑與連結檢查、隨機獨占暫存檔、原子改名與 flush 沿用 history 檔案的做法。日誌不計入 history 的帳號或裝置容量，不參與 history 的 eviction、retention、`files.deleteAccount` 與 history-only clear。
- **大小上限：** ciphertext 1 MiB，在解密前檢查，超過視同格式未知；計數項最多 2,000 列。寫入後會超過上限時回 `storageLimit` 並拒絕新的寫入（唯讀仍可用，設定頁說明），不淘汰有效計數、未解決的隔離、待確認標記或 60 分鐘內的 dispatch 紀錄。
- **容量與保留：** 明細每帳號最多 200 筆、保留 7 天；只淘汰已終結、未隔離且超過 60 分鐘的明細；`dispatching` 與 `writeUncertain` 不因容量或保留期淘汰。可淘汰空間不足時拒絕新的寫入。
- **耐久性：** `dispatching` 必須在 mutation 送出前 flush 成功；送出前寫入失敗時 GitLab mutation 次數為零。mutation 已送出後若終態保存失敗，保留 `dispatching`（重啟即轉為 `writeUncertain`）並阻擋新的寫入，不退回 `notExecuted`。殘餘風險：原子改名沿用 history 的 `flushSync`＋`renameSync`，Dart 無法對目錄 fsync。程序死亡不受影響；只有斷電或核心當機時，最後一次改名（例如 `prepared → dispatching`）可能遺失，恢復時可能把已送出的寫入記成 `notExecuted`。這是已知殘餘風險，如實記載，不另宣稱。
- **金鑰：** 獨立的 `ai_write_journal_key.v1.<base64url(account.key)>`（32 byte；iOS 用 `ThisDeviceOnly`）。讀取結果分五種：
  - `found`：沒有日誌檔時視為空日誌。
  - 未初始化：`absent`，日誌目錄沒有日誌檔，沒有帳號移除 tombstone（`ai_history_tombstone.v1.*`），也沒有日誌重設標記。
  - `keyMissing`：`absent` 但有日誌檔。
  - 已由移除刪除：`absent`、日誌目錄沒有日誌檔、有帳號移除 tombstone。拒絕新寫入（「帳號移除」第 6 步）；移除第 3 步視為沒有隔離（先前的移除已就當時的隔離要求過名稱）；第 4 步不寫標記、不建立日誌。
  - `unavailable`。

  未初始化時，在第一筆 `prepared` 寫入之前、於帳號 fence 內建立：先寫金鑰並讀回確認，再寫第一個日誌檔。同意流程可以預先建立，但建立失敗不影響同意，下一次寫入再試。其餘狀態一律不建立、不換鑰。history 的清除中標記（`ai_history_clear_pending.v1.*`），以及 history 的啟用、關閉、清除與 provider reset，都不讀寫日誌金鑰與日誌目錄。
- **讀取失敗：**
  - `unavailable`：不刪檔、不換鑰，沿用 history 的 1／5／30 秒與之後回到前景時重試；期間拒絕新的寫入（唯讀仍可用）。
  - `keyMissing`：拒絕新的寫入，不自動刪檔、不自動補建金鑰；設定頁提供「重設寫入日誌」。
  - 格式未知、驗證失敗或超過大小上限：保留資料、拒絕新寫入，提供同一個重設動作；不以「一般損壞的紀錄檔」清除。
- **重設寫入日誌：**
  - 使用獨立的耐久標記 `ai_write_journal_reset_pending.v1.<base64url(account.key)>`，納入 secure inventory 與同一帳號 fence；標記寫入成功前不刪任何資料。
  - 這是批次解除隔離，依 §0 第 11 點同樣要輸入名稱：只能從前景、已驗證目前帳號的 AI 設定頁開始；確認框顯示完整 instance、`@username` 與 numeric user ID，以 `confirmAction(requiredText: 目前帳號的 @username)` 確認；讀得到時列出將釋放的筆數（`dispatching` 與 `writeUncertain` 都算），讀不到時寫「無法讀取，可能有狀態未知的寫入」，並說明確認不代表原寫入未執行。名稱無法驗證、確認期間 generation 改變、輸入不符或 secure storage `unavailable` 時不得提交。模型、通知、連結都不能觸發重設。token 已撤銷而無法驗證目前帳號時，出口是移除帳號：移除以本機保存的 `Account.user` username 比對，不需連網（見下方「帳號移除」）。
  - 重設完成時，在新日誌中耐久寫入帳號級的「重設後需確認」標記：之後 24 小時內，該帳號的所有寫入在 bypass 以外的等級都需要確認，bypass 下卡片與稽核列標示「寫入日誌已重設」。這對應單筆手動解除後的待確認標記；因為被釋放的 key 已無法讀取，只能以帳號為單位。24 小時寫成常數並列入 writePolicy。
  - 開始重設時：拒絕新的寫入；使該帳號所有既有提議、核准與日誌 owner epoch 失效。在途的 mutation 仍是狀態未知，不視為已取消；舊 owner 晚到的收尾不得寫回新日誌。
  - 標記存在時依固定順序：刪日誌檔 → 刪舊金鑰 → 建立新金鑰並讀回 → 原子耐久寫入初始日誌（含「重設後需確認」標記與截止時間，不是不含標記的空日誌）→ 刪 `reset_pending` 標記。任一步失敗保留標記，下次啟動續做；初始日誌尚未落盤前不得宣告完成；重設中斷不走一般「未初始化」的首次建立。
  - 重設完成後不自動續跑或重送；使用者設定的上限保留，舊的本次對話授權與核准不沿用。
- **啟動順序與恢復：** 不受 AI gate 影響，在 `SessionController.accountsLoaded` 之後對所有已儲存帳號依序：先處理帳號移除 tombstone，再處理日誌重設標記，最後做一般恢復。一般恢復只轉換 `processId` 不等於本程序的明細：`prepared` → `notExecuted`（可淘汰）；`dispatching` → `writeUncertain`，不自動重送。某帳號的恢復在本程序完成之前，政策閘門對該帳號的寫入一律 `deny`（唯讀照常）；`accountsLoaded` 在 `initialize` 時會先重設再設回，恢復因此可能晚於使用者開始對話，這條規則讓兩者不交錯。恢復結果列在 AI 設定頁「中斷的寫入」區塊，若有對話紀錄也顯示在該對話。日誌金鑰 `unavailable`、`keyMissing` 或格式未知而無法恢復時，啟動時同樣在這個區塊顯示「寫入日誌無法讀取，可能有中斷的寫入」，並提供重試與重設；這是 §0 第 11 點「下次啟動時呈現」在日誌無法讀取時的呈現方式。
- **inventory 與 orphan cleanup：** 金鑰前綴、重設標記前綴與目錄納入 secure inventory；只在 `accountsLoaded` 證明帳號已不存在後清除。
- **帳號移除：** 移除會刪掉該帳號的整份日誌，等於批次解除它的全部隔離，所以依 §0 第 11 點也要輸入名稱。兩個移除入口（`authenticated_app.dart` 的 `_remove` 與 `login_screen.dart` 的移除按鈕）都改用同一個流程，順序固定：
  0. **移除作業與保留的擁有者：** 每次移除是 `AiWriteJournal.instance` 登記的一個**程序級移除作業**，以 token 識別；「移除中」保留（`AiRemovalHold`）屬於這個作業，不屬於任何頁面或 widget。頁面卸載、widget dispose 或路由彈出只對作業**提出取消要求**，本身不釋放保留。取消要求只在最後一個確認框確認**之前**生效：這段期間的頁面卸載、停止框取消，以及等待在途寫入或重讀日誌時收到的取消，都在目前這個 await 結束後停止作業（已過接受點的寫入仍寫完終態），不進入清理、不呼叫 `session.remove`。最後確認之後忽略取消要求；清理的每個 await 返回後只核對 token 是否仍屬於本作業。只有作業確定停止之後，才在 `finally` 以自己的 token 冪等釋放保留。舊 token 的回呼不得繼續清理，也不能釋放或影響新作業的保留。同一帳號只在已有作業持有有效 token 時拒絕第二個入口；作業結束後可以重新開始一次新的移除。
     - **確認框的等待：** 作業顯示的每一個確認框，都與作業自己的取消信號一起等待（例如 `Future.any`），不單獨 `await` 對話框：Flutter 在 Navigator 被釋放時不會完成 `showDialog` 的 future（登入頁與已登入殼層各有自己的 `MaterialApp`，登入或切換帳號會整棵替換）。頁面 dispose 時完成這個取消信號；Navigator 仍在時另以 route 收掉對話框（沿用 `work_item_page.dart` 收掉自有 route 的做法）。
     - **作業期間停用的按鈕：** 作業持有有效 token 期間，兩個入口都停用帳號切換、移除與「新增或重新連線帳號」（`endSession`）。殼層的 `_removing` 改在取得保留時設定（目前在第一個確認框之後才設），登入頁新增同等的旗標。
  1. 使用者按下移除，**在顯示任何確認框之前**，在同一段同步程式裡建立移除作業並取得保留（本程序記憶體）。保留是獨立的狀態，**不是** `AiAccountMutationCoordinator` 的 cleaning：不呼叫 `beginCleaning`、不發出帳號紀錄通知；`AiHistoryCoordinator` 的帳號生命週期監聽器（它會在 history 為 `disabled` 且 session 不忙時自動 `reopen` cleaning）不讀它，也不能解除它。保留存在期間，政策閘門、提議核准、`prepared` 與 §7.3 第 4.1、4.3、4.4 步一律拒絕，等待確認的卡片停用核准按鈕並顯示「帳號移除中」；已過接受點的寫入仍可寫入終態。取得保留時**不**遞增 epoch。
  2. 仍有 run 或待確認的提議時，先顯示「將停止 N 個 AI 工作並移除這個帳號」。在這個框按取消，或在這個框顯示時頁面卸載：作業停止並釋放保留，**不**遞增 epoch，run、既有提議與核准照常繼續。按確認：遞增該帳號的「提議與核准 epoch」（只讓提議與核准失效；與 §8 重設日誌的「日誌 owner epoch」不同，不阻擋已過接受點的寫入寫入終態），停止該帳號的所有 run，等待在途寫入結束並寫入終態（上限同 §12.1），畫面顯示等待中。保留期間被政策閘門或第 4.4 步擋下的寫入記為未執行，同一輪的 fail-stop（§7.5）照常適用，模型需要重新提議。
  3. 由日誌 owner（不是會被 cleaning 擋下的帳號紀錄讀取）重讀日誌，決定最後一個確認框的種類：有 `dispatching` 或 `writeUncertain` 明細、未消耗的 key 級待確認標記、尚未到期的「重設後需確認」標記，或日誌無法讀取（含讀取丟錯、逾時、回不到結果）時，要輸入該帳號的 `@username`（以本機保存的 `Account.user` 比對，不需連網），並寫明「這個帳號有 N 筆狀態未知的 AI 寫入（或：無法讀取）；移除後這些寫入不再受保護，重新加入此帳號時不會恢復」；其他情況維持現在的確認框（目前兩處的 `confirmAction` 都沒有 `requiredText`）。終態寫不進日誌而維持 `dispatching` 的寫入，同樣要求輸入名稱。
  4. 最後一個確認框：
     - **取消**，或確認框顯示時頁面卸載：作業停止，在同一段同步程式裡遞增「提議與核准 epoch」並釋放保留，中間沒有 await；舊提議與核准不恢復，要重新提議。
     - **確認**：遞增「提議與核准 epoch」（若第 2 步沒有遞增過），之後作業**跑到結束**，頁面卸載不再中止它，只是沒有畫面可以回報結果（下次開啟帳號列表或 AI 設定時呈現）。依既有順序 `clearSecureDrafts → clearAccountArtifacts → clearRecentProject → clearAiAccountData → session.remove`，每一步前後都核對 token；進入 `clearAiAccountData` 之前，作業在日誌寫入一筆「移除開始」標記（日誌為每筆明細指派單調遞增的序號，不依牆上時鐘；標記記錄寫入當下的最大序號。這是帳號級標記，不是寫入明細，重試時以新序號覆寫。日誌未初始化、`keyMissing`、格式未知或「已由移除刪除」時不寫、也不建立日誌，這些狀態本來就拒絕新寫入；日誌金鑰 `unavailable`，或可讀的日誌寫不進標記時，視同清理失敗、不進入 `clearAiAccountData`，帳號保留，畫面顯示「請稍後重試移除」）；`clearAiAccountData` 照現況在內部自己 `beginCleaning`，既有的 tombstone 契約不變。
  5. **作業結束時一律釋放自己的保留**（`finally`，以 token），包括：成功；任一清理步驟失敗（含 `clearAiAccountData` 本身丟出 `aiHistoryCleanup`，帳號保留，畫面顯示既有的「請重試移除」）；`session.remove` 返回後帳號仍在。`SessionController.remove` 不會丟錯：在 `busy`、`initializing`、`resuming` 時直接返回，儲存失敗時還原帳號清單並設訊息後正常返回，所以作業在它返回後以 `SessionController.accounts` 是否仍含該帳號判定結果，不把正常返回當成移除成功。帳號仍在時分三種：
     - `clearAiAccountData` 之前的步驟失敗：本次作業還沒開始 AI 的 tombstone 清理，既有 AI 資料與日誌不因本次作業改變；釋放保留後只沿用原有的 fence，沒有既有 fence 時可以重新提議寫入。
     - `clearAiAccountData` 本身失敗：帳號保留，清理可能已部分完成，不宣稱 AI 資料或日誌都還在。已寫入的 tombstone 依第 6 步持續拒絕新寫入，由重試或啟動恢復續做；不得為補回已刪資料而重建日誌。初始 tombstone 沒寫成時，不宣稱已有耐久標記，沿用既有的失敗與重試契約。
     - `clearAiAccountData` 已完成，但 `session.remove` 直接返回或還原了帳號清單：帳號留下，但 AI 同意、聊天紀錄與寫入日誌都已清除；重新同意之前沒有 AI 寫入，舊的隔離不會恢復，等同重新加入帳號的殘餘（§7.6）。

     三種情況都顯示「帳號未移除」並說明差別；頁面已卸載時，在下次開啟帳號列表或 AI 設定時呈現（只存在程序記憶體）。釋放只解除這張保留，**不**碰 cleaning、tombstone、`reset_pending` 或日誌裡的隔離；使用者按「重試移除」會建立新的作業、取得新的保留，並重新讀取日誌（第 3 步）。
  6. **tombstone 是持久的拒絕條件：** 只要該帳號的移除 tombstone 仍在，政策閘門、提議、核准、`prepared` 與 §7.3 第 4.1、4.3、4.4 步都拒絕新的寫入，也不得把既有明細改寫成 `dispatching` 或追加新明細（已存在明細的終態更新照常）。這與移除保留是兩件事：保留釋放不會解除它。`AiWriteJournal.instance` 在記憶體中維護每個帳號的 tombstone 旗標：啟動讀到 tombstone 時設定；`_clearAccount` 在呼叫 `setTombstone` **之前**同步通知 `AiWriteJournal.instance` 設定旗標（例如經 `AiAccountMutationCoordinator` 的清理開始回呼），寫入失敗也不清除（`setTombstone` 可能丟錯但已落盤）；只有 `clearTombstone` 成功、`_clearAccount` 正常返回之後才清除。§7.3 第 4.4 步同步檢查這個旗標；§7.3 第 1 步與 `prepared` 另從 secure storage 讀取，`unavailable` 或讀取失敗視同存在。第 4.4 步仍然不把 cleaning 當成移除保留。日誌檔被刪除之後，晚到的終態收尾不得重建日誌或建立新日誌（同重設時舊 owner 的規則），只更新記憶體中的稽核列。

  在 `clearAiAccountData` 的 tombstone 流程內，先做日誌前置檢查，再刪日誌檔、日誌金鑰與重設標記，之後才是既有的 history 步驟；任何一步失敗都保留 tombstone 與帳號，沿用既有契約。**日誌前置檢查放在 tombstone 流程本身**，所有入口都經過：本節的移除作業、啟動時的 `_recoverAccounts`（對 tombstone inventory 的每個帳號直接清理，不依帳號清單過濾，也不要求名稱），以及 AI 設定頁 cleaning 狀態的「重試清除」（`retryCleanup`，直接呼叫 `clearAccount`）。檢查內容：讀取日誌，若有序號大於「移除開始」標記所記序號（或沒有標記、無法判定）的 `dispatching`／`writeUncertain` 明細，就不刪日誌、保留 tombstone，並丟出可辨識的失敗：
     - 帳號仍在已成功載入的帳號清單中：AI 設定頁不再提供「重試清除」，改為「請從帳號列表重試移除」，走第 1–4 步；第 3 步重新讀取日誌，有這類明細時再次輸入 `@username`。
     - 帳號已不在清單中：依上方「inventory 與 orphan cleanup」照常刪除；帳號不存在，沒有寫入能使用這些鎖。

  沒有這類明細時，「重試清除」與啟動恢復是延續先前已輸入名稱的移除，照常刪除；帳號仍在時，結果等同第 5 步「`clearAiAccountData` 已完成、帳號留下」的終態。日誌讀不到時：`unavailable` 不刪、延後重試；`keyMissing` 或格式未知時這段期間本來就拒絕新寫入（上方「讀取失敗」），照常刪除；「已由移除刪除」沒有日誌可查，照常續做。依第 6 步，這類明細正常情況下不會出現；這是防禦性檢查。
- **文件：** AGENTS.md 的持久化清單與 CLAUDE.md Persistence 一節列出新的 secure-storage key、重設標記與目錄、上述生命週期與失敗行為。

## 9. 工具清單與 segment

- 工具清單在 segment 建立時，依「實際上限（§4.1 的 min(目前上限, 使用中 provider 的已同意上限)）、provider 是否啟用工具與對話範圍」固定：實際上限為唯讀、provider 的 `toolsEnabled` 為 false，或對話沒有寫入範圍時，segment 完全不含寫入工具，也不建構寫入 port；否則含該上限可達的全部候選寫入工具。目前等級（包括被調到唯讀）只在執行時由政策閘門強制，不允許時回「目前的寫入方式不允許此操作」。凍結前綴（含 `tools`）逐位元組不變。
- 上限、範圍、目錄版本或政策語意變更後，下一次送出以重新遮蔽的 projection 開新 segment，固定 tool-spec digest；從不含寫入工具的 segment 變為可寫時同樣開新 segment。對話內在可寫等級之間調整，不改變凍結前綴。

## 10. 同意與揭露

- `writePolicy` 是有版本的正規化物件：已同意上限、各層級的 deny／confirm／automatic、允許的 operation 集合與目錄版本、硬底線清單、固定確認清單（§4.1）。計入 hash 與可讀摘要。
- **已同意上限存在每個 provider 的 `AiConsentRecord`**（計入該筆 hash 與摘要），不放在帳號層級：`AiAccountRecord.consents` 是每個 provider 一筆，若做成帳號欄位，替 provider B 同意 bypass 會讓 provider A 的 hash 不符，連 A 的唯讀聊天也失效。帳號設定另存目前上限（預設「低風險自動」）與起始等級。契約 hash 綁定已同意上限，不綁目前上限：現有 `AiSettingsController.isValid` 是 hash 精確比對，若綁目前上限，調低上限也會讓同意失效。調低目前上限只遞增 write-policy revision（§4.1）；調高超過已同意上限或開啟 bypass 才需要重新同意。
- AI 標註設定不計入 hash，只列在可讀摘要與帳號設定；切換它不使同意失效，也不開新 segment，但會改變之後提議的 payload digest，舊核准依 §7.1 失效。
- 實際契約由「provider＋目前帳號的 writePolicy」統一推導；同意框、grant、`isValid`、runner 使用同一推導來源。grant 同時核對 captured policy revision、recipient revision 與帳號 generation。
- **版本：** MR6b-1 把 `aiToolCatalogueVersion` 由 1 改為 2、`aiDisclosureVersion` 由 1 改為 2。兩者都在 hash 內（`aiConsentContractFor` 已預設引用 catalogue 常數），所以 MR6b-1 合併後**所有**既有同意（含唯讀）都要以新版揭露重新同意。MR6b-2、MR6b-3 擴大 operation 集合時，`aiToolCatalogueVersion` 各再加 1，既有同意再次失效。gate 在 MR7 之前都關閉，沒有實際使用者受影響。
- **遷移：** `AiAccountRecord` 由 v1 升為 v2：每筆舊同意的已同意上限設為唯讀；保留 `historyEnabled`、保留天數、對話 token 上限與其他 provider 的同意，不以新預設覆蓋。以原始 v1 fixture → v2 → 往返測試（兩個 provider、不同的已同意上限、非預設的紀錄設定），不以聊天紀錄 codec 的往返代替。provider 的 `toolsEnabled` 為 false 時不提供任何寫入工具。
- `dataCategories` 新增 `write_results` 與 `attachment_metadata`（附件經遮蔽的檔名、大小與裝置回報的類型；§3.1）。同意框「會傳送的資料」列出附件中繼資料，並說明檔案內容不會傳送。兩者都在 MR6b-1 隨揭露 v2 加入；MR6a 不把附件中繼資料送給模型（MR6a 沒有附檔 UI，§3.1）。兩者與現有的 `tool_reads` 相同，只在 provider 的 `toolsEnabled` 為 true 時列入契約（`aiConsentContractFor` 在 false 時移除 `tool_reads`）。同意框的類別標籤（`ai_consent_dialog.dart` 的 `_categoryLabel` 目前把未知類別顯示為「其他」）在 MR6b-1 為這兩個類別新增 l10n 文字。
- 同意框新增「寫入」段落，分開說明：哪些內容送到哪個 AI 服務；AI 會以哪個 GitLab 帳號寫入哪些地方；目前上限下哪些會自動執行、哪些永遠要確認（硬底線與固定確認清單）；重跑 Pipeline、重跑 Job、播放 Job 在一般等級只需按確認、不必輸入名稱，bypass 下會自動執行，而且**重跑或播放可能沿用 GitLab 上已存的原變數與 inputs**（前次的 Pipeline 與 Job 變數），排程建立的 Pipeline 還會使用排程**目前**的變數；app 讀不到也無法核對；執行、重跑、取消 Pipeline 或 Job，以及 commit、建立分支、合併、rebase 觸發的 pipeline，都可能產生 CI 本身的副作用（部署、停止環境、下游 pipeline、取消時的 `after_script`），這些不是 app 能判定的；背景是否繼續、通知可見性；已執行的寫入無法撤回；「狀態未知」的意思、手動解除，以及隔離只在本裝置有效；在自動等級上傳附檔到 public 或 internal 專案不會先顯示預覽；AI 讀到的內容可能夾帶指令；寫入以你的名義出現（AI 標註預設關閉）。
- `aiReadOnlyPromise` 以新 key 取代並刪除舊 key；設定、system prompt、同意摘要與 24 個語系在 MR6b-1 同一個整合提交中替換。

## 11. 回答與預覽的顯示安全（MR6a）

AI 回答、提議預覽、`reason`、稽核列一律使用「不自動連網」的顯示方式：不載入外部圖片、SVG、媒體或連結預覽（`MarkdownView(api: null)` 仍會載入外部圖片，不能直接沿用）；外部連結只在使用者點擊確認後開啟。

## 12. 背景執行

### 12.1 執行登錄

- 帳號範圍的 `AiRunRegistry` 放在 `AuthenticatedApp` 內、`MaterialApp` 之上，與 `AiScope` 同層，生命週期跟著 generation；run 不隨聊天頁 route 結束。日誌與隔離表不在 registry 內，屬程序級單例（§8）。
- 最多 3 段對話同時執行；第 4 段送出時直接拒絕並說明原因。
- 切換帳號或登出前，若仍有 run 或待確認的提議，先以 `confirmAction` 提示「將停止 N 個 AI 工作；進行中的寫入可能狀態未知」（移除帳號不用這個框，見下方）。使用者確認後停止所有 run，等待在途寫入結束（上限依 `GitLabApi` 的連線 15 秒、送出 15 秒、接收閒置 25 秒；附檔上傳依 §3.1 的送出逾時；畫面顯示等待中），全部結束後才 `_activate`／`endSession`。使用者選「立即切換」時，在途寫入一律記為狀態未知（§7.5），其 key 在日誌中維持隔離。移除帳號（兩個入口）一律走 §8「帳號移除」的固定流程：先取得「移除中」保留（`AiRemovalHold`），有 run 時才顯示已在保留之下的「將停止 N 個 AI 工作並移除這個帳號」，再停止、等待、重讀日誌，最後顯示 §8 決定的確認框；這一點不論有沒有進行中的 run 都適用。這條規則從 MR6b-1 起生效（寫入從這時開始存在）。

### 12.2 Android 前景服務

套件研究（2026-10-21，32 個附日期來源，報告存在本機 scratch，不入版控）、第 1 到第 3 輪審查，以及對 AOSP 原始碼與外掛 README 的核對結論：

- **服務：** 由 `tool/bootstrap.py` 產生約 50 行的原生服務 `AgentRunService`（兩個 flavor），不 exported，類型 `dataSync`；`onStartCommand` 回 `START_NOT_STICKY`（系統不重建服務，避開外掛 `START_STICKY` 的重建崩潰，上游 #2298）；Dart 端以 MethodChannel 啟停。服務不建第二個 Flutter 引擎、不跑 Dart，runner 留在主 isolate。不用外掛內建的前景服務（沒有 `onTimeout`，#2673）。
- **原生執行許可：** 「盡力通知 Dart」不是可靠的授權閘門：回呼可能遺失，而 app 在背景、engine 仍活著時，Dart 仍會走到下一個續點。因此：
  - 原生服務維護一個執行許可（隨機 ID 與狀態），只在服務處於已啟動的前景狀態時有效。每次啟動服務產生新許可，經 MethodChannel 回給 Dart，`AiRunRegistry` 把它綁到當時進行中的 run；服務已在執行時新開始的 run 綁到目前仍有效的同一張許可。
  - `onTimeout`、「全部停止」、`MainActivity.onDestroy`，以及服務因任何原因走到 `Service.onDestroy`，都先把許可標為失效，再立即停止服務，不等待 Dart。被失效的許可不再核發任何送出票；綁在它上面的所有 run 都要由使用者在前景明確續跑（前景中按通知的「全部停止」也一樣）。
  - **一次性送出票：** 綁有許可的 run，每次新的模型呼叫與每次 mutation 送出前，經 MethodChannel 呼叫原生端的 `acquireContinuation(permitId, kind, nonce)`。原生端以同步狀態機決定：許可有效才核發一張只能用一次的票。逾時 1 秒、channel 不可用、許可不符或已失效 → 在該續點暫停，不送出新呼叫。
  - **接受點的定義：** 「失效之後零新呼叫」指：原生端失效先於核發的請求，一律不會送出；失效前已核發、並通過 §7.3 第 4.4 步同步重驗的那一次呼叫，視為在途，照常由日誌收尾。不宣稱「失效後連已核發的票也絕不會開始 HTTP」；單次 MethodChannel 查詢無法撤回已開始的送出。
  - 正常停止服務（只剩等待確認或全部結束）時許可標為已釋放；之後由使用者在前景的操作（核准、續跑）重新啟動服務並綁定新許可。
  - 沒有許可的 run（前景服務啟動被拒）只在前景執行，進入背景就依下方規則暫停。
- **前景通知的擁有者：** 由原生服務以 `startForeground` 建立並擁有前景通知（固定 id、獨立 channel，與外掛通知的 id 範圍分開）。Dart 端只經 MethodChannel 傳送進度文字，由原生端更新同一張通知。「全部停止」是指向服務的 immutable PendingIntent：服務先使許可失效、停止前景服務，再經 `MainActivity` 註冊的 MethodChannel 通知 `AiRunRegistry.stopAll`。不用外掛的通知動作做「全部停止」：外掛 README（22.3.2）寫明，不顯示 UI 的通知動作會啟動另一個 Flutter engine，在另一個 isolate 執行 `onDidReceiveBackgroundNotificationResponse`，那裡拿不到主 isolate 的 runner。
- **其他通知：** 用 `flutter_local_notifications`，只負責「需要確認／完成／失敗／中斷」通知，只用點擊開啟 app，不放不開啟 UI 的動作。鎖定穩定版（研究當日 pub.dev 為 22.3.2；上游 master 已是 23.0.0-dev，不採用 dev 版），MR6c 導入時查最新穩定版並鎖版。
- **啟動時機：** 只在使用者於可見畫面送出或明確續跑時啟動並及時升為前景；捕捉 `ForegroundServiceStartNotAllowedException`，被拒時 run 只在前景繼續並顯示說明，不循環重試。不從背景、timer、程序恢復或開機啟動。
- **停止時機：** 依實際進行中的 run 計數；最後一個 run 結束、停止，或所有 run 都只剩等待確認時停止服務（等待確認不佔用 dataSync 額度），只留一般通知；使用者回到前景核准後再由使用者操作重新啟動。
- **`onTimeout(int, int)`：** AOSP `Service` 說明這個回呼只給「數秒」寬限，未及時停止 app 會 crash。因此原生端在回呼中先使許可失效，立即 `stopForeground`＋`stopSelf()`，不等待 Dart 或加密日誌 I/O；之後盡力經 MethodChannel 送 `fgsTimeout` 給 `AiRunRegistry`。即使這個回呼遺失，Dart 在下一個續點確認許可時也會暫停。Dart 不在時，依啟動恢復把殘留的 `dispatching` 轉為 `writeUncertain`。不宣稱原生端已更新 Dart 日誌。
- **沒有前景服務時**（啟動被拒、`onTimeout` 之後、服務被停止）：app 進入背景後不再開始新的模型呼叫與寫入，在下一個安全續點暫停；在途寫入照常等待結束並記入日誌；回到前景後由使用者操作續跑，續跑依 §7.7 不重複已執行的寫入。
- **服務與 runner 的一致性：** `MainActivity.onDestroy`（Activity 結束、engine detach）時使許可失效、停止服務並清掉 active-run 狀態，不留下只有通知、runner 已消失的服務。
- **額度：** Android 15 起 dataSync 每 24 小時背景合計 6 小時，由同 app 同類型服務共用，使用者開啟 app 即重置；不以「每次只有 12 分鐘」推論永遠足夠，`onTimeout` 時在途寫入由日誌收尾。
- **程序生命週期：** Flutter 的 `FlutterFragment.withNewEngine()` 在 Activity 銷毀時會銷毀 engine。本期採「移除工作即停止所有 AI 工作」：manifest `stopWithTask="true"`。依 AOSP `Service.onTaskRemoved` 的說明，設了 `FLAG_STOP_WITH_TASK` 就不會收到 `onTaskRemoved`，服務直接被停止；因此不實作、不依賴 `onTaskRemoved`，也不承諾移除工作當下發出中斷通知（擁有者 2026-10-21 確認）。在途寫入由下次啟動的日誌恢復標為狀態未知，在 app 內與中斷通知中呈現；日誌無法讀取時，改為呈現「寫入日誌無法讀取，可能有中斷的寫入」並提供重試或重設（§8）。不採用 cached engine 方案（會連動 bootstrap、local_auth、app_links 與 app lock，風險大）。
- **根頁返回：** 目前首頁的 `PopScope.canPop` 為 true，返回會結束 Activity；而非首頁的 `onPopInvokedWithResult` 只把分頁改回首頁，不會把工作移到背景。改為：有進行中的 run 時 `canPop` 為 false；在現有 `onPopInvokedWithResult` 裡，detail 返回與「非首頁改回首頁」都處理完之後，若 run 仍在進行，呼叫 `moveTaskToBack`。沒有 run 時維持現在的行為。避免 Android 7–11 結束 Activity。
- **權限與 manifest：** `FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC`、`POST_NOTIFICATIONS`（Android 13+ 在第一次背景執行前請求）；`startForeground` 帶符合 Android 14 規定的 type；compileSdk ≥ 35（外掛要求，`onTimeout(int, int)` 也是 API 35）。Gradle 開 core library desugaring 與 Java 17（外掛 README 要求，即使不排程通知）；不另開 multidex（minSdk ≥ 21 時由平台原生支援，README 範例雖有設定，MR6c 以實際 minSdk 確認）。不加開機接收器與 `RECEIVE_BOOT_COMPLETED`：外掛自身的 manifest 只宣告 `VIBRATE` 與 `POST_NOTIFICATIONS`，開機接收器只有 app 為排程通知自行加入時才存在，本 app 不排程；MR6c 檢查合併後的 manifest 沒有 `BOOT_COMPLETED` receiver。不要求電池最佳化豁免。MR6c 鎖版前重讀 Android 16 行為變更頁。

### 12.3 通知

- 前景服務通知（原生擁有）：「AI 助手正在處理 N 個工作」＋目前步驟，附「全部停止」動作（停止是安全的）；Android 14 起使用者可滑掉，不寫成「常駐」。
- 需要確認：高優先，可見度 `VISIBILITY_PRIVATE`，提供不含專案或 MR 名稱的公開版本；點擊開啟該對話的提議卡片（冷啟動以 `getNotificationAppLaunchDetails` 取得 payload）。通知上永遠沒有「核准」。
- 完成、失敗、被中斷：摘要通知，同樣的隱私設定。
- 點擊：PendingIntent 為 immutable，只帶對話 ID 與 generation；先通過 `AppLockGate`，generation 或帳號不符時只開啟首頁，不靜默切帳號。
- 連結與通知永遠不能核准寫入、變更等級或解除狀態未知的鎖（擴充 `IncomingLinks` 的不變式）。
- 啟動時，依「需要確認」通知的 id 範圍精確取消上次程序遺留的通知（提議已在程序死亡時作廢），不使用 `cancelAll`。
- `POST_NOTIFICATIONS` 被拒：前景服務仍可執行；一般通知（需要確認、完成）不會出現。app 內顯示「通知已關閉；背景中需要確認時你不會收到提醒，提議會在 30 分鐘後作廢」。
- 使用者在 Android 13+ 的工作管理員按停止，整個 app 會被終止且不呼叫收尾；下次啟動依日誌呈現，不承諾當下發出通知。

### 12.4 Play Console

App 內容 → 前景服務權限：提交功能說明、被延後或中斷時的影響、使用者啟動、通知與停止的示範影片，並從清單選用途（dataSync「網路傳輸：使用者發起的伺服器端處理」）。說明這是需要中途核准的互動式 agent 迴圈，不是檔案傳輸。若 dataSync 不被接受，改 `specialUse` 並寫明理由；使用者發起的資料傳輸工作（UIDT）列為備案評估。另列為送審 gate「G6 前景服務申報」。

### 12.5 需實機驗證（MR6c）

本專案專用模擬器上 API 34、35、36：螢幕關閉與 Doze 下 12 分鐘串流與 GitLab 請求是否持續；三段並行；通知權限拒絕；移除工作後冷啟動（`dispatching` 轉為狀態未知）；工作管理員停止與冷啟動；「全部停止」通知動作；`fgsTimeout` 之後零新的模型呼叫與 mutation；MethodChannel 不可用時服務仍及時停止；engine detach 時服務一併停止；根頁返回在 run 進行中改為 `moveTaskToBack`；合併後的 manifest 沒有開機接收器。另有一個合併情境必須單獨證明：app 在背景、Dart 與 engine 仍存活、原生服務已停止且停止回呼被丟棄（或 channel 不可用），讓 runner 走到下一個模型呼叫與 mutation 續點，兩者的新呼叫都必須為零，且原生停止不等待 Dart；分開測「回呼正常時零 dispatch」與「channel 壞掉仍停服務」不足以證明這個交集。送出票的交錯也要分開測：失效先於 `acquireContinuation`（零送出）；許可有效的回覆已排入 channel 之後才失效（該票視為在途，不再核發新票）；GraphQL 方法內前置讀取進行中失效（掛鉤拿不到票，mutation 為 0、不上鎖）。以合成方式觸發回呼的測試，與系統真正因額度觸發的 `onTimeout` 分開列證據；後者未執行即標 `NOT_RUN`。未執行者一律標 `NOT_RUN`。

### 12.6 iOS（目前不上架）

嘗試取得有限、不保證長度的 background task（`beginBackgroundTask`，實務上常約 30 秒，可能更短；讀 `backgroundTimeRemaining`，處理 invalid token 與到期回呼並配對 `endBackgroundTask`，到期回呼必須立即返回）。進入背景後不再開始新的寫入；到期時在途寫入依日誌記為狀態未知；回前景從安全續點續跑（可能重送被中斷的那次模型呼叫，可能重複計費），不假設連線或舊核准存活。續跑依 §7.7 不重複已進入 `dispatching` 或終態的寫入。

### 12.7 尚未驗證（NOT_VERIFIED，MR6c 必須查核）

- `onTimeout(int, int)` 在 AOSP main 上標為 `@FlaggedApi`；在已發布的 Android 15／16 上是否確實送達本服務，以 API 35、36 模擬器驗證。
- app 在背景（Activity 仍在、engine 存活）時，Dart 經 MethodChannel 呼叫 `acquireContinuation` 的往返是否穩定、延遲是否在 1 秒逾時內，以 API 34–36 驗證；不穩定時以「拿不到票即暫停」為準，不放寬。
- 移除工作時，`stopWithTask="true"` 的服務是否走 `onDestroy`、能否在那裡安全發出原生中斷通知；本版不承諾。若擁有者日後要求移除工作當下就有通知，需另評估 `stopWithTask="false"`＋`onTaskRemoved`，並驗證各廠牌是否確實送達該回呼。
- 原生服務以 `NotificationManager` 更新前景通知時，Android 14 以上可被滑掉後的行為與 id 衝突，以實機確認。

## 13. 商店與資料安全

- Play 資料安全依實際的 provider、離機資料類別、用途、保留期、可選性與傳輸加密逐項填寫；寫入是使用者以自己的 GitLab 憑證在自己的 instance 上操作，屬既有行為；provider 端沿用 v5 G3。支援 LAN HTTP 時不得宣稱所有傳輸都加密。
- 附檔上傳（§3.1）只在使用者附檔並經 AI 提議後送到使用者自己的 GitLab，與畫面上既有的附件上傳同一路徑；附件內容不送給 AI provider，但附件經遮蔽的檔名、大小與類型會送到使用者設定的 AI 服務（`attachment_metadata`，§10）。資料安全表單的「相片與影片」「檔案與文件」依此填寫，並另列這項中繼資料。
- 前景服務申報（§12.4）。
- 上架截圖主打：AI 讀 Job log 後提議修正、建立 MR、在確認卡片上核准合併。

## 14. 交付與完成條件

| MR | 內容 | 必須證明 |
|---|---|---|
| MR6a | **交付（唯讀助理，沒有任何寫入）：** 對話頁（v5 §6.2、§6.3：訊息分段渲染、串流重建每 100 ms 至多一次、複製全文、chips 與 tool 列狀態、中斷與結束列）；各頁入口（v5 §6.1：`JobLogPage`、`WorkItemPage` 的 Issue 與 MR、`RepositoryFilePage`；沒有 provider 時導向設定頁）；帳號範圍的 `AiRunRegistry`（§12.1：放在 `AuthenticatedApp` 內、`MaterialApp` 之上，run 不隨聊天頁結束，最多 3 段同時執行；MR6a 沒有寫入，切換帳號或登出時 run 隨 generation 改變停止，不顯示提示，§12.1 的提示與等待從 MR6b-1 起生效）；唯讀工具接線（既有的 `AiRunner`、`AiRunnerBinding` 與 `gitlab_read_port.dart` 接到對話頁，segment 只有唯讀工具）；三種格式的串流與「停止」（v5 §2.4、§2.5）；插入為留言草稿（v5 §6.6：抽出 `openNewComment`、editor 的 `appendDraft`、討論分頁刷新、提及消毒與預覽，`markdown` 升為直接依賴）；回報此回應（v5 §6.7：`mailto:` 優先、分享面板備援、`aiReportEmail` 常數）；不自動連網的顯示（§11）與明文介面檢查的 UI。**不含：** 附檔按鈕、附件列與附件讀取（隨 `upload_attachment` 在 MR6b-1 交付，§3.1）；寫入 port 與任何寫入工具、提議卡片、寫入日誌、等級設定、同意契約 v2（`write_results`、`attachment_metadata`）、`upload_attachment`；前景服務、通知與任何背景執行機制（app 進入背景後沿用 v5 §2.5：不保證繼續，串流中斷時回前景顯示「已中斷」並提示可能已計費）。 | 注入式 `AuthenticatedApp` 真實接線（gate 關閉的 CI 上直接注入 AI 控制器）；三種格式串流與停止；離開對話頁後 run 繼續、切換帳號或登出時停止；唯讀 adapter 只見 GET/HEAD，segment 沒有寫入工具；外部載入次數為零；草稿在討論分頁未建立時也能附加、與既有草稿合併、提及消毒與中和；回報 payload 預設不含回應內容，`mailto:` 失敗或過長時改用分享面板；沒有附檔 UI、沒有附件讀取，送往 AI provider adapter 的 request 沒有附件資料；320 dp 窄螢幕、2× 字體、RTL（ar）的 widget test；新 l10n key 的 24 語翻譯；gate 仍關閉 |
| MR6b-1 | 寫入 port 與守衛、能力表與分級引擎、政策閘門、提議卡片、`awaitingApproval`、執行協調、寫入日誌（獨立金鑰與目錄、程序 ID、重設協定、待確認標記、大小上限）、送出邊界（同步重驗、唯一的 `dispatching` → `notExecuted` 轉移）、狀態未知的隔離與手動解除（解除名稱存日誌、以明細為單位）、重設日誌與移除帳號的輸入名稱、T1／T2 的 REST 工具與所需的新包裝（含畫面改用；片段除外，全部在 MR6b-2）、`upload_attachment` 與附檔 UI（附檔按鈕、附件列、記憶體中的附件保存與容量上限、附件 ID 與中繼資料交給模型、送出逾時、佔位字串替換、`attachment_metadata` 類別）、provider 外送的上傳路徑規則與可還原的 `[[upload:…]]`、§5 文字處理、稽核、等級設定、同意契約與遷移、取代唯讀文案、切換／登出前的等待與兩個入口的帳號移除流程（獨立的 `AiRemovalHold`）、續跑不重複、REST mutation 回應的 401 確定未執行 | §15 第 1–8、10–19 列中屬於閘門、日誌、隔離與 T1／T2 REST 的部分；第 21、23、28、29、31 列；第 32 列以議題、MR 描述與留言證明；第 4 列含帳號切換與移除的等待；第 1、8 列中 T3 以上與硬底線的情境，以 ledger 測試用的假列證明分級與閘門（未知 operation 在閘門層拒絕）；第 17 列以可控時鐘證明 |
| MR6b-2 | T3／T4／硬底線的 REST 工具與新包裝（含畫面改用，包括 `MetadataPage` 的分支、tag、Release）、`edit_file`、片段的全部寫入（含建立、精確片段編輯、中繼資料與檔案動作）、合併與核准的 sha 規則、合併前的既有變更檢查、直接執行 Pipeline 或 Job 的操作至少 T4、排程參數 HMAC、重跑 Pipeline、重跑 Job、播放 Job 為 T4 且一般等級只需確認（§0 第 12 點）、取消自動合併的舊端點與結果分類、參數升級規則 | 以真實工具重跑 §15 第 1、5–11、13、14、16、19–21、26、29、30 列；第 32 列中 Release 說明、里程碑描述與片段描述的還原案例；第 6 列「最多一次 dispatch」；第 16 列至少含檔案的專案＋ref＋路徑，以及合併的 MR＋來源與目標分支 |
| MR6b-3 | 全部 GraphQL 寫入：Work Item（含群組 Work Item、`groupWorkItem` 範圍與「依擁有者決定 key」）、事件單、待辦延後（含群組 Work Item target 的歸屬）；`beforeMutation`／`mayStart` 掛鉤、依送出邊界與 `mutationSent` 的結果分類、共用的寫入登錄，沿用各 API 既有的 revision、actor 與獨立 readback | §15 第 1、5–8、10、11、13–16、21、24、25、29 列的對應工具；第 15、16 列含 Work Item 表情、通知、延後與取消延後的意圖方向；第 23 列中屬於 Work Item 描述與活動留言的替換斷言，以及第 32 列中 Work Item 描述與活動留言的還原案例；第 21 列「待交付」清單為空 |
| MR6c | 前景服務（bootstrap 產生、原生擁有前景通知、原生執行許可與一次性送出票、`onTimeout` 與停止協定、沒有前景服務時的暫停規則）、通知外掛鎖版、通知隱私、app lock、移除工作、根頁返回、啟動被拒降級 | §12.5 的模擬器證據；§15 第 22、27 列；以實際服務重跑第 28 列；iOS 標 `NOT_RUN` |
| MR7 | 開 gate；交付 commit 上重跑完整 analyze、tests、Python、CI 並連結 pipeline／job；沙箱實際寫入；Play 前景服務申報、資料安全、上架 | 不以合成測試或編譯通過代替；任何未通過的能力不因其他工具通過而一併開放 |

§15 第 21 列（ledger 覆蓋）是每個 MR6b 的合併關卡：該 MR 新增或改用的寫入呼叫點必須已對應 ledger 列；尚未交付的呼叫點列在一份明確的「待 MR6b-x 交付」清單中，不能有未列入任何一邊的呼叫點；MR6b-3 合併時這份清單必須為空。

UI（提議卡片、各層級預覽元件、附檔按鈕與附件列、上傳預覽、設定頁「寫入方式」區段、bypass 開啟流程、常駐標示、稽核列、「中斷的寫入」、觀察結果與手動解除鎖定、重設寫入日誌、通知文案）由 Claude 親自設計與實作；邏輯、測試、翻譯與審查分給其他 worker。

沙箱實際寫入：只在擁有者帳號下的隔離沙箱專案，內容全為合成資料；測試前核對 numeric project ID 與完整路徑；每項操作走「API → 確認 → 寫入 → 獨立 readback」；結束時以 `GET /users/:id/events`（限定時間窗）證明沒有其他專案出現事件；清理只刪沙箱。中途出現 `writeUncertain` 就停止該場景，後續步驟標 `NOT_RUN`。權限、配額或版本造成未執行的項目標 `NOT_RUN`，不外推為全部可用。

## 15. 測試（MR6b／6c 必須涵蓋）

1. **注入語料：** 合成 README、議題、Job log、MR diff、projection 中放入寫入指令（含「完成所有待辦」「合併」、quick action、範圍擴張、偽造 reason、範圍外的 closing pattern、跨專案參照）。斷言：預設等級下沒有任何未經確認的 T2 以上寫入，也沒有未綁定目標的 T1；bypass 下範圍外、硬底線、固定確認清單、quick action、外部圖片、秘密一律被擋或改為確認。
2. **顯示：** 回答與提議含 Markdown／HTML 圖片、SVG、媒體、外部 URL 時，未點擊前外部請求數為零。
3. **日誌與程序死亡：** dispatch 前死亡；dispatch 後伺服器成功但本機尚未記錄即死亡；聊天紀錄從未啟用時寫入可用；啟用後清除紀錄（含清除中標記卡住）、關閉後重開、provider reset 之後，未解決的隔離、待確認標記與對話計數都還在；日誌金鑰 `unavailable`／`keyMissing`／格式未知／超過大小上限時 GitLab 寫入次數為零；同意時金鑰寫入失敗，之後第一次寫入成功建立金鑰；有日誌檔但金鑰 `absent` 時不建立；送出前落盤失敗（mutation 為 0）與 mutation 已送出後終態落盤失敗（mutation 可能為 1，保持 `dispatching`）分開斷言；啟動時只轉換其他程序的 `prepared`／`dispatching`，本程序先建立的明細不被改寫，恢復完成前寫入被拒，非目前帳號也恢復；重設寫入日誌在每個步驟程序死亡、標記寫入失敗、重設與帳號移除競爭、舊 mutation 在重設後返回、非目前帳號有重設標記，恢復完成前 mutation 為 0 且舊回呼不重建舊資料；手動解除後重啟、超過 7 天、產生超過 200 筆可淘汰明細，再從另一段對話對相交 key 寫入仍需確認，確認後但 dispatch 前失敗不消耗標記；明細超過 7 天或 200 筆淘汰後，恢復舊對話仍沿用計數；解除名稱寫進日誌，資源刪除或重啟後仍能解除；日誌無法讀取時啟動仍顯示「寫入日誌無法讀取，可能有中斷的寫入」；帳號移除依 tombstone 順序清除。
4. **停止時機與帳號變更：** 等待確認時、HTTP 寫入途中、run 逾時當下、切帳號、移除目前帳號、撤銷同意、client close、晚到的成功；切帳號時在途寫入的 `cancelled` 記為狀態未知；切帳號與移除帳號會等待在途寫入，「立即切換」記為狀態未知；A→B→A（立即切換）後對同一 key 不會 dispatch；結果字串各自正確，舊帳號內容不出現在新帳號。
5. **狀態未知的隔離與結果分類：** 停止後原寫入仍在途（`dispatching`）時，另一段對話對同一 MR 的提議被擋；換 nonce、換 tool-call ID、換段、從紀錄恢復後重提都被擋；`edit_file` 狀態未知後改提同一路徑的 `deleteFile` 被擋；合併狀態未知後對同一 MR 的其他寫入被擋；兩種 scope 或 REST 與 GraphQL 兩種入口指向同一資源被擋；建立類換 payload 或 nonce 重送被擋；Future 已以狀態未知結束、GET 暫時仍是原狀態、伺服器稍後才執行（含重啟後的同一情境）：「重新讀取」只產生觀察，隔離維持，沒有第二次相交 dispatch；DELETE 讀取到目標仍存在或 404、同帳號另一筆相同建立、分支或 tag 同名重建，都只記觀察不解除；原請求在途時不提供讀取；`cancelled`、5xx、空或無法解析的 2xx body 記為狀態未知；400／403／404／409／429 記為確定未執行且不上鎖；REST mutation 請求本身的 401 記為確定未執行且不上鎖，以真實 `_send` 路徑分開斷言 kind：PAT 或 refresh 回傳失敗時沿用 `unauthenticated` 且 `status: 401`（`ApiFailure.fromStatus`，畫面錯誤種類不變）；refresh 成功但不重放時沿用 `writeUncertain` 並補 `status: 401`；refresh 本身丟出例外時保留原 mutation 的 401 與 §7.5 指定的種類；同一筆在 mutation 回 201 之後的 readback 得到 401 時仍為狀態未知且上鎖，第二次 mutation 次數為 0；狀態未知的 `jobAction(retry)` 擋住同一 Pipeline 的 `pipelineAction(retry)`，反之亦然；狀態未知的 `jobAction(play)` 擋住同一 Pipeline 的 retry 與相交的 Job 寫入，反之亦然；手動解除需要輸入依 key 種類決定的確認名稱（含 T1 待辦、建立留言的 `!iid`、群組 Work Item），以明細為單位一次解除多把 key（合併輸入 `!iid` 即解除 MR 與目標 ref），之後的下一次相交寫入在 bypass 以外需確認；比對不受 `isolated()` 方向隔離字元影響；重跑與播放免輸入名稱不適用於手動解除：只按確認、或輸入錯誤的 Pipeline／Job ID，都不能解除隔離；前置讀取取不到解除名稱時不產生提議；通知、連結、模型無法觸發解除。
6. **競爭：** 卡片雙擊、兩個對話同時對同一資源、soft-timeout 讀取後立刻要求寫入、修改內容後按舊核准、兩段對話同時核准而改寫同一份日誌；最多一次 dispatch，日誌只有單一寫入者。
7. **等待與到期：** 29／31 分鐘、等待期間 head／revision／權限／等級／範圍變更、輸入名稱不符、重啟後過期卡片、逾時後的通知點擊；零未授權寫入；等級被調低時執行前重判；拒絕、失敗、狀態未知後卡片保留使用者改過的內容。
8. **分級矩陣：** 五等級 × 各層級；參數升級（受保護分支、預設分支上的直接 commit 與套用建議、設定自動合併到預設分支、`removeSourceBranch`、`confidential` 由 true 改 false、可見度、新建非 private 片段、`.gitlab-ci.yml` 與自訂 `ci_config_path` 的新增／修改／刪除、變數）；`createPipeline`（含一般功能分支）與 `playPipelineSchedule` 在「本次對話授權」下都需要輸入名稱，取消維持 T3 且預覽寫明 `after_script` 仍可能執行；`pipelineAction(retry)`、`jobAction(retry|play)`（含 `environment:action: stop` 的 Job）在逐一確認、低風險自動與本次對話授權只需按確認、不要求輸入名稱，bypass 下自動執行，並計入 T4 預算（§4.4）；bypass 下未滿足 §2 目標綁定，或命中 §4.1 固定確認清單（含同 run 已成功或狀態未知的相同提議）時改為確認卡、不自動送出，確認卡仍不要求輸入名稱並含沿用原變數的文案；模型自行從工具結果取得的 Job ID 重跑時顯示確認卡，使用者貼了 Pipeline URL 時，前置讀取確認屬於該 Pipeline 的 Job 可以自動執行；`edit_file`、建立分支、合併、rebase 不因觸發 pipeline 而升為 T4；建立 tag 一律 T4；`squash` 不升級但出現在預覽；複合效果取最高；固定確認清單在 bypass 下仍需確認。
9. **檔案與片段：** `edit_file` 片段含遮蔽標記被擋；原檔已有 `[REDACTED…]` 字樣時，附近的編輯不被擋，新片段含此字樣或跨越邊界拼出此字樣時被擋；在 metadata、內容讀取、核准與 dispatch 之間逐一插入分支前進，不會送出混合版本；`last_commit_id` 不符衝突失敗；缺 `last_commit_id` 不會變成 POST；新檔案已存在即失敗；新檔案與新片段接受初始正文並全文掃描；片段重疊被拒；原檔未變動區段含假 token 時編輯仍可進行並在預覽標示，新加入的已知秘密被拒；片段內容以精確片段編輯，新鮮內容比對不符即作廢；片段中繼資料編輯、檔案新增與改名為 T2，刪除片段內單一檔案為 T4 並輸入檔名。
10. **全域 ID、範圍與白名單：** suggestion、todo、GID 指向其他專案時被拒；批次套用逐一驗證每個 suggestion；無範圍的對話不提供寫入工具；`createNote` 的 resource 只接受列舉值；`createMergeRequest` 不接受 `target_project_id`；`createIssue` 接受 `issue_type` 的三個值，更新時不送；議題 REST 白名單沒有 `due_date`；`createProject` 只接受 name、path、description 且為 private；fork 不帶 `namespacePath`；Release 只能指向已存在的 tag，不接受 `ref`、`assets.links`、`milestones`、`released_at`；`deleteBranch` 對預設或受保護分支拒絕；從群組 Work Item 頁開啟的專案議題得到專案 key、只授權該議題與其子資源。
11. **同意：** MR6b-1 合併後所有既有同意（含唯讀）需重新同意；MR6b-2、MR6b-3 各自升版後再次失效；原始 v1 fixture → v2 → 往返（兩個 provider、不同的已同意上限、非預設的紀錄設定），舊同意的已同意上限為唯讀；替 provider B 調高已同意上限不影響 provider A 的同意；舊唯讀同意不授權寫入；同意儲存中政策變更；調低上限立即生效且不需要重新同意；調高超過已同意上限或開 bypass 需要重新同意；切換 AI 標註不使同意失效、但使舊核准失效；`toolsEnabled` 為 false 時沒有寫入工具；只換 key 維持既有重新分段規則。
12. **segment：** 上限為唯讀時沒有寫入工具；只把目前等級調到唯讀時凍結前綴不變、閘門拒絕；從不含寫入工具的 segment 變為可寫時開新 segment；每種格式 tool 呼叫與結果配對。
13. **守衛：** 唯讀 port 的既有 GET/HEAD 測試與成員白名單不變，不為寫入流程放寬。`gitlab_write_port.dart` 是唯一另外允許的 importer，只能呼叫具名寫入方法與前置讀取方法的白名單（含本計畫新增的固定讀取，例如排程詳情、合併前的 `diffs`／`commits`／`closes_issues`，以及待辦歸屬查詢；每個 helper 在 ledger 列出名稱）；前置讀取與 readback 需要的 GraphQL query 必須是 app 內固定、已審核的唯讀文件（`graphQuery`），不接受模型提供的 query、operationName 或任意 variables。任何等級下，每個有副作用的 REST mutation 與 `graphMutation` 都恰好對應一筆已核准或依政策自動執行的提議（一對一、帶相同執行 ID）；固定 GraphQL query 的 POST 計入 HTTP 預算，但不算 mutation，也不能取得 mutation 權限；OAuth token refresh 與資源 mutation 分開計。例：一次延後待辦可有必要的 `snoozedTodos` query POST，但恰好一筆授權過的 mutation；模型注入 GraphQL mutation 或替換 query 文件被拒。

   **G14 修正記錄：** 依父 breakdown §7.6，僅群組 concrete read class `GitLabAiGroupReadPort` 新增固定 `namespaceWorkItem` GraphQL query POST 例外；專案 `GitLabAiReadPort` 的 11 個既有成員與 GET/HEAD-only 測試和限制不變。禁止任意 query、mutation 或全域 HTTP 豁免；固定 query 只使用受驗證範圍的 path 與 iid，不接受模型自訂文件或 variables。
14. **文字：** (A) 類欄位餵入 `a\n/merge`、`a\r\n/approve`、`a\n\r/move x/y`，送往 adapter 的 body 沒有任何一行以第 0 欄的 `/` 開頭；(B) 類的片段多行字串、含 `@` 的原始碼、行首 `/` 的合法內容保持原值，相同字串進入留言時符合中和後置條件；Java／Python 檔中的 `@param`、decorator 不觸發提及確認，Markdown 檔變動區塊中的大量提及要確認；`@all` 與大量提及需確認；(A) 的外部圖片即使經確認也被擋，(B) Markdown 的外部圖片需確認；範圍外的 closing pattern 與跨專案參照需確認；把私有群組或私有專案的內容寫進 public 專案時標示污染，可見度讀不到時改為確認；AI 標註開關。
15. **翻譯與紀錄格式：** 新 key 在 24 語齊全；T1 自動 operation 的意圖詞表（每個方向）、否定詞表與條件詞表在 24 語齊全，其他 operation 不需要意圖詞；`aiReadOnlyPromise` 已移除；紀錄格式版本 +1 的往返測試。
16. **目標綁定與意圖詞：** 一般字詞（main、README）不綁定；複合目標只綁一個元件時改為確認；多專案範圍下不帶專案路徑的 `#iid` 改為確認；同 iid 不同專案、同路徑不同 ref；群組 Work Item 只能以 URL 或 UI 綁定；否定句、引用、條件句、方向相反（標星對取消標星、訂閱對取消訂閱、通知開對關、延後對取消延後）只產生確認卡；介面語言與裝置語言中任一語系的否定詞都使其改為確認；從紀錄恢復的訊息不建立 T1 授權；各語系意圖詞的命中與誤判。
17. **計時（可控時鐘）：** 讀取的 20 秒 soft timeout 保留；寫入在第 21 秒成功仍回真實結果；`awaitingApproval` 暫停主動時間，恢復只用剩餘時間（例：11:59 主動執行＋29 分鐘等待後只剩 1 秒）；30 分鐘到期以牆上時鐘計；停止後每個 tool call 與結果仍配對，晚到的結果不改寫凍結前綴。
18. **同輪 fail-stop：** 同一輪中前一個寫入為拒絕、確定失敗或狀態未知時，之後寫入的 GitLab 次數為 0，結果字串是「前一個寫入未完成，未執行」；前一個寫入為「無變更」時後續照常執行。
19. **預算：** mutation 加 readback 在 39／40／41 次 HTTP 的邊界；核准後的新鮮讀取與合併前檢查在提議時已保留，保留不到就不產生提議；三段對話共用帳號 60 分鐘上限；對話計數跨換段與重啟；大量零寫入的對話不建立計數項；計數項 2,000 列與 ciphertext 1 MiB 的邊界，飽和時 mutation 為 0；`prepared` 因隔離或預算不足改 `notExecuted` 時不消耗計數；紀錄關閉時計數只在本程序內有效；批次上限。
20. **草稿整批送出：** 伺服器上有非本段對話建立的草稿時，任何等級都改為確認；全部草稿都經 (A) 類檢查；快照不符即取消；草稿數超過 20 被拒。
21. **ledger 覆蓋：** 測試列舉 `lib/` 中每個寫入呼叫點（畫面上的通用通道呼叫、具名寫入方法、`graphMutation: true` 呼叫），每一個都必須對應一列 ledger、「v2 不提供」中的一項，或「待 MR6b-x 交付」清單；§3「畫面改用」所列畫面不再直接呼叫通用通道；每個新包裝的固定 path 與欄位白名單有負向測試。
22. **bootstrap 與原生服務（MR6c）：** 擴充 `tool/tests/test_bootstrap.py`，驗證乾淨生成與管理函式重跑後的 manifest、Kotlin 與 Gradle：兩個 flavor、不 exported 的服務、`stopWithTask="true"`、FGS type 與權限、MethodChannel 註冊、原生執行許可、`MainActivity.onDestroy` 使許可失效並停止服務、desugaring、沒有開機接收器，以及既有的 backup／cleartext／signing 限制；未知或半套模板繼續 fail closed（管理函式冪等不等於重跑會拒絕既有 native 目錄的 CLI）。生成物反讀核對後，再做實際 Android 編譯與 §12.5 的模擬器測試。
23. **附檔上傳（§3.1）：** MR6a：沒有附檔 UI，沒有附件讀取，送往 AI provider adapter 的 request 沒有附件資料。MR6b-1 起：選檔後 bytes 只在本程序記憶體，受上限與生命週期約束，達上限時按鈕停用；移除附件、結束對話、切換帳號後 bytes 被丟棄，picker 暫存副本被刪除；模型給出非本段對話的附件 ID、任意字串或 URL 時被拒；segment 不含 `upload_attachment` 時附檔按鈕停用；附件 bytes 不出現在送往 AI provider adapter 的任何 request、聊天紀錄與日誌（以合成檔案的獨特位元組序列搜尋；bytes 只可出現在已授權目標 GitLab 的 multipart 請求）；附件中繼資料以 untrusted-data 區塊出現，檔名裡的 `#iid`、意圖詞不建立目標綁定或 T1 授權；以帶唯一 ID、檔名、大小與類型的 fixture 走過送出、紀錄存取與重載、`restoreFromDisplay` 與強制 projection，送 provider 的 request 只含允許的中繼資料；上傳成功並寫入留言或描述後，經 issue／MR／discussion 讀取工具、context 與寫入結果再讀，送 provider 的 request 不含任何 32 位十六進位的上傳 secret（含既有上傳、重啟後讀取、安裝子路徑、另一專案的 `/-/project/<id>/uploads/…`、群組上傳、他 instance 的絕對 URL、Job log 與原始碼中的路徑），且 `parseProjectUpload` 對其他專案仍回 null；截斷落在 secret 中間或檔名之前的 fixture 也不外送 secret 的任何部分；來源文字中原本就寫著 `[[upload:u-1]]` 或 `[[attachment:att-1]]` 時，送 provider 的是一般遮蔽標記；同一批先提議上傳再引用時引用被拒（`attachmentNotUploaded`）；佔位字串只在同專案的 (A) 類欄位替換，群組 Work Item、跨專案、`edit_file` 與其他欄位被拒；`markdown` 含 CR／LF／控制字元、`[ ] ( )`、尾隨第二個 token 時不替換，上傳仍記成功但標示不可引用；檔名含 `@all` 或跨專案參照時替換後改為確認；digest 與預覽是替換後的文字；替換後行首出現 `/` 時整筆 mutation 為 0；移除附件使尚未 dispatch 的上傳與引用提議作廢；切帳號、重啟後 `attachmentExpired`；以 FakeAdapter 模擬慢速上行（例如 1 MiB/s 送 20 MiB）在新的送出逾時內成功、不產生狀態未知，超過上限才記為狀態未知；上傳結果依 §7.5 分類，狀態未知時以 `(project, SHA-256)` 隔離且不重送，程序死亡重開後仍能以日誌中的檔名原文解除（含長檔名、emoji、RTL 檔名，比對不受方向隔離字元影響），不需附件 bytes，重新附同一檔仍命中原 key 與待確認標記；同一 SHA-256 已有成功上傳時，不論是否同一 run（含程序死亡後另開的 run），再次提議都改為確認並標示「可能重複」；附件數量、對話 50 MiB、程序 100 MiB 的上限與選檔前保留（40＋25 MiB、未知長度、快速重複選檔、讀取失敗釋放保留）；public／internal 專案的警示在確認等級顯示於卡片、在自動等級顯示於稽核列。
24. **群組 Work Item 與 key 別名：** 沒有 project 的群組 Work Item 可建立正確提議；`groupWorkItem` 範圍不授權群組下的專案或其他 Work Item；foreign Group GID 被拒；同一議題經 REST 列、GraphQL 列與看板卡片移動命中同一把 key；改名不解除鎖；群組 Work Item 的手動解除名稱為 `<群組路徑>#<iid>`；從群組頁（含子孫）開啟的專案議題得到專案 key，與 REST 列及看板卡片移動相交；`project` 為 null 的群組 Work Item 待辦可延後，它不在已延後清單裡時不得因此被拒成「查無」；頁面截斷仍未見到該 GID 時為「無法驗證」、不送 mutation；foreign account 或 foreign Group 的 target 與不支援的 target 型別被拒。
25. **GraphQL 接縫：** 方法內前置讀取回 5xx 或傳輸錯誤時不上鎖、mutation 次數為 0、日誌為 `notExecuted`；`beforeMutation` flush 失敗或 `mayStart` 回 false 時不送 mutation；日期 `applied`＋`mutationSent: false`、健康度、狀態與標籤的 `noop`，以及指派、里程碑、權重、通知、內容、事件單、活動留言編輯在送出前返回的相同快照，逐一記「無變更」且同輪繼續；日期 `notApplied`＋`mutationSent: false`（驗證或權限失敗）記 `notExecuted` 並適用 fail-stop；以上都不上鎖、不消耗預算與待確認標記；過了接受點之後，日期返回 `writeUncertain` 或 `notApplied` 且 `mutationSent` 為 true、健康度 `notApplied`、狀態 `notApplied` 且 `mutationSent` 為 true 時，日誌不得是 `succeeded`，同輪後續寫入次數為 0；三個失敗型別依 `mutationSent` 分類，不經 `safeFailure`；狀態方法的 `onMutationSent(started)` 由 AI 傳入時只呼叫 `started`，新掛鉤在它之前；429 之後的本機快速失敗在預檢被攔下，不上鎖；以 FakeAdapter 斷言每個 `graphMutation` 請求抵達 adapter 時，日誌已是 `dispatching`；mutation 成功後 readback `cancelled` 或 401 記為狀態未知；畫面正在寫同一 Work Item 的狀態、日期或健康度時 AI 不 dispatch；`setIncidentStatus` 一律帶 `expectedUpdatedAt`；待辦延後以 mutation 回應的 `snoozedUntil` 記成功，`snoozedTodos` 查不到或 truncated 只是不升為「已 readback 確認」；方法內 HTTP 次數以 ledger 上限計入預算。
26. **合併前的既有變更檢查：** 模型沒有提供任何 CI 文字，但既有 MR 含 CI 設定檔 diff 時合併升為硬底線（bypass 也一樣）；自訂 `ci_config_path` 的改名與刪除；`changes_count` 帶 `+` 或筆數不符、分頁失敗、權限不足時不產生提議；既有描述、commit message 或 `closes_issues` 指向範圍外專案時改為確認，關閉效果無法判定時不自動執行；核准後 head、路徑集合或將關閉議題集合改變時作廢；套用建議依 suggestion 所在路徑判定 CI。
27. **原生執行許可（MR6c）：** 背景＋Dart 與 engine 存活＋原生停止服務＋丟棄停止回呼或 channel 不可用，runner 到下一個模型呼叫與 mutation 續點時新呼叫都為零；`onTimeout`、「全部停止」、`MainActivity.onDestroy` 與 `Service.onDestroy` 先使許可失效再停服務；失效先於 `acquireContinuation` 時零送出；有效回覆排入 channel 後才失效時，該張票視為在途、不再核發新票；送出票不能重用；`acquireContinuation` 超過 1 秒視同失效；服務已在跑時新 run 綁同一張許可；被失效的 run 只能由使用者在前景續跑；沒有許可的 run 進入背景即暫停。
28. **續跑不重複：** Android 使用者續跑、`fgsTimeout` 之後與 iOS 回前景時，本 run 中已進入 `dispatching` 或任何終態的執行不再呼叫 mutation，投影只有一行摘要；續跑產生的相同 operation 與 conflict keys 的提議在任何等級都改為確認並標示「可能重複」。
29. **送出邊界（§7.3 第 4 步）：** 用 barrier 卡住 flush，期間分別撤銷 policy 或 consent、停止 run、切換 generation，恢復後 mutation 為 0；分開斷言「掛鉤未落盤」（`prepared` → `notExecuted`）、「已落盤但同步重驗不通過」（`dispatching` → `notExecuted`，退回預算、恢復待確認標記，這次落盤失敗則維持 `dispatching`）與「已送出但終態落盤失敗」（記憶體中為狀態未知、隔離維持、重啟後為 `writeUncertain`）；送出票不能重用；同步重驗與 mutation 呼叫之間沒有 await（以測試替身斷言呼叫順序）；flush 期間另一段對話的讀取收到 429、client 被關閉、帳號進入「移除中」、沒有許可的 run 被切到背景時，同步重驗不通過，記 `notExecuted` 而不是狀態未知。以 barrier 卡住 `dispatching` 的 flush，移除流程等待達上限後顯示最後確認、使用者取消，epoch 遞增並釋放保留；flush 恢復後舊綁定因 epoch 不符不能送出，mutation 為 0，`notExecuted` 與退回預算、恢復待確認標記在同一次原子更新完成；停在 §7.3 第 2–4.3 步的寫入同樣在第 4.4 步轉為 `notExecuted`；帳號有移除 tombstone 而保留已釋放時，同步重驗同樣不通過。
30. **取消自動合併與既有參數（MR6b-2）：** 取消：只有 `merge_when_pipeline_succeeds`、只有 `auto_merge_enabled`、兩者都有，三種都送同一個舊端點；201＋`status: success` 且 readback `isAutoMergeEnabled` 為 false 記成功，readback 仍為 true 或失敗記狀態未知；201＋`status: error` 記確定未執行、不上鎖並顯示 `message` 與目前狀態；201 但 `status` 無法解析記狀態未知；這次 POST 本身的 401 記確定未執行並依 PAT／refresh 成功顯示不同文案，POST 回 201 之後 readback 的 401 記狀態未知；剛讀過 MR 卻收到 404 記確定未執行、文案為「取消端點不可用或無法存取」；`isAutoMergeEnabled` 為 false 時不產生提議；`user.can_merge` 為 false 的 MR 作者可以提議，非作者只顯示提示；全程最多一個 POST，沒有版本讀取或端點探測。排程參數：`variables` 非空、只有 `inputs`、兩欄明確為空、因權限缺席、`inputs` 欄位不存在（較舊版本）、讀取有下一頁或被截斷、讀取失敗各一案；非空或無法讀取時都要輸入 ref（bypass 也一樣），明確為空時為 T4；名稱不變、只改變數值、input 值、input 的 JSON 型別或可讀性時，舊核准作廢且 POST 次數為 0；HMAC 以長度前綴或排序 JSON 正規化，`A`＝`B=C` 與 `A=B`＝`C` 得到不同 HMAC；HMAC 金鑰只在記憶體，預覽、稽核列、日誌與 provider request 裡沒有參數值，也沒有 HMAC；無法讀取時卡片顯示「無法核對參數」文案。重跑與播放（§0 第 12 點）：push 來源、沒有變數的 Pipeline 重跑，非手動 Job 重跑，手動 Job 播放，三種在逐一確認、低風險自動與本次對話授權都顯示確認卡、不要求輸入名稱，確認前 POST 次數為 0；Pipeline 重跑的卡片列出 ref 與 Pipeline ID，Job 重跑與播放另列 Job ID、Job 名稱與 stage；一般等級確認後與 bypass 自動執行後，稽核列都含沿用已存變數與 inputs 的揭露（含排程目前的變數）；三項的請求 body 是 `{}`，不含 `variables`、`job_variables_attributes` 或 `inputs`，工具 schema 沒有這類參數，模型多給時整筆以未知參數拒絕、mutation 為 0；write port 不發 pipeline variables、`source`、`manualJob` 的讀取，HTTP 計數只含取得卡片資訊的前置讀取；帶新變數的 `createPipeline` 在任何等級（含 bypass）仍要輸入 ref。
31. **解除路徑都要輸入名稱：** 重設寫入日誌只按確認、輸入錯誤名稱、確認期間切換帳號，都不改動重設標記、金鑰或日誌；模型、通知與連結不能觸發重設；在新金鑰建立、初始日誌落盤、刪除 `reset_pending` 之間逐一中斷，重設完成後仍有 24 小時的「重設後需確認」；重設後 24 小時內的寫入在 bypass 以外需確認、bypass 下卡片標示「寫入日誌已重設」；token 已撤銷時可經移除帳號、以本機保存的 username 確認。帳號移除：兩個入口都先建立程序級移除作業並取得 `AiRemovalHold`，再顯示確認框；作業持有有效 token 時，從另一個入口移除同一帳號被拒；最後確認之後，在每個清理 await 期間卸載頁面，作業繼續、保留仍在、新的 mutation 為 0，直到作業結束才釋放；確認之前卸載頁面，作業停止、釋放後舊作業的後續清理與 `session.remove` 次數為 0；分別注入 `clearAiAccountData` 的標記寫入、日誌刪除與 history 清理失敗：帳號保留、作業結束並釋放自己的保留、cleaning／tombstone／`reset_pending`／隔離都不被解除、按「重試移除」可以建立新作業取得新保留，舊 token 不影響新作業；`session.remove` 因 `busy` 直接返回，以及儲存失敗而還原帳號清單時，保留都被釋放、帳號仍在，作業依 `accounts` 判定為「帳號未移除」，同意已失效、日誌為未初始化；分別在第 2 步停止框與第 4 步最後確認框顯示期間釋放整個 Navigator（登入、切換帳號）：兩者都由取消信號結束等待、釋放保留，之後的清理與 `session.remove` 次數為 0，之後可以再次移除；停止框的情況不改 epoch，run 與核准繼續；最後確認框的情況 epoch 遞增，舊提議與核准作廢；作業持有 token 期間，帳號切換、移除與 `endSession` 的按鈕停用；最後確認之後在清理 await 期間送出取消要求，作業不停止；`clearAiAccountData` 在 tombstone 已寫入、日誌尚未刪除時失敗，保留釋放之後、重試之前，同一帳號的新 mutation 為 0、日誌沒有新明細；以測試替身在「移除開始」標記之後放入一筆 `writeUncertain` 明細再重啟，啟動清理不刪日誌、保留 tombstone，重試要求 `@username`；可讀的日誌寫不進「移除開始」標記、或日誌金鑰 `unavailable` 時，不進入 `clearAiAccountData`、帳號保留、顯示「請稍後重試移除」，日誌為 `keyMissing` 時移除照常完成；日誌已刪、後續 history 清理失敗時，tombstone 仍擋下新 mutation，日誌不被重建；tombstone 已在、保留已釋放時，停在 `prepared` 的寫入不得進入 `dispatching`，mutation 為 0；`setTombstone` 丟錯但已落盤時記憶體旗標仍為設定，第 4.4 步拒絕；secure storage 讀 tombstone 為 `unavailable` 時，§7.3 第 1 步與 `prepared` 拒絕；在「移除開始」標記之後放入一筆 `writeUncertain`，按 AI 設定頁的「重試清除」：日誌、tombstone 與帳號都保留，畫面改為「請從帳號列表重試移除」，重試要求 `@username`；沒有這類明細時「重試清除」完成清理並重新開啟 fence，同意已失效、日誌為未初始化；帳號不在清單中的 tombstone 在啟動時照常清除，不顯示重試提示；系統時間往回調整後，標記之後的明細仍以序號判定，不被刪除；日誌金鑰與日誌檔已刪、tombstone 仍在時重試移除：第 3 步不因日誌要求 `@username`、不寫標記、不建立日誌；停止框取消時不遞增 epoch，run 與既有核准繼續；在等待在途寫入期間取消，那筆寫入的終態照常寫入日誌，不留下 `dispatching`；帳號的聊天紀錄關閉（history 為 `disabled`）時，在確認框顯示期間與前三項清理的每個 await 都觸發一次 `SessionController` 通知（`busy` 為 false），保留仍然有效、mutation 為 0；取消後 `isValid` 與同意顯示不需手動重讀，history 與設定都不在 cleaning；`clearAccountArtifacts` 失敗時保留被釋放、帳號保留、重新提議後可寫入；先前已有 tombstone、`reset_pending` 或 cleanup fence 時取消移除，不解除那些 fence；`clearAiAccountData` 的 `beginCleaning` 不會與保留死結；日誌重讀丟錯、逾時或回不到結果時要求 `@username`，且日誌與 session 都還在；在確認框顯示期間與前三項清理的 await 各放 barrier，嘗試開始新的 run、接受既有核准、讓在途請求收尾為狀態未知，都不能在沒有名稱確認的情況下刪除新的隔離、日誌、金鑰或 session；有隔離、key 級待確認標記、未到期的「重設後需確認」或日誌無法讀取時要輸入 `@username` 並顯示筆數或「無法讀取」；停止等待後才出現的狀態未知也算進去；取消移除後舊核准不恢復；沒有這類狀態時維持原確認框。
32. **既有上傳連結的還原（MR6b-1）：** 議題描述含既有截圖（相對路徑或本 instance 的絕對 URL）時，模型編輯同一議題的描述可以送出，送往 GitLab 的 body 逐位元組保留原始連結目標，送往 provider 的 request 不含主機與 secret；Release 說明含附件連結時，編輯同一 Release 的說明也可以送出；同一個 `u-<n>` 寫到同專案另一張議題、新留言、另一個資源、`edit_file` 時被擋；他主機的 `https://x.example/uploads/<32 hex>/a.png` 送 provider 時是一般遮蔽標記，模型無法把它還原成圖片，原文在程式碼區塊中時也一樣；`https://x.example/[[upload:u-1]]`、`?d=[[upload:u-1]]`、`[[upload:u-1]]` 緊鄰英數字元都被擋（bypass 與手動確認都一樣），mutation 為 0；`[[attachment:att-1]]` 放在連結目標或 URL 中間時被擋；Job log、原始碼、使用者訊息裡的上傳連結不可還原，使用者訊息的情況回「請在畫面上自行貼上」；同一連結出現在兩個資源時各自得到不同編號、各自只能原地還原，讀取順序（P→Q、Q→P）不改變已發出編號的資格；從紀錄恢復後或模型偽造的 `u-<n>` 被擋並回「請重新讀取」；對照表超過 1,000 筆時新路徑改為一般遮蔽標記並回原因；還原後仍對完整最終文字做秘密、提及與跨專案檢查；對照表不出現在聊天紀錄、日誌與 provider request；REST 讀取、GraphQL 寫回同一個描述可以還原；excerpt、摘要或截斷值中的上傳路徑不可還原，截斷的欄位回「這個欄位太長」；標準形式 `/uploads/<32 hex>/a.png`（含安裝在子路徑的 instance）可以取得原欄位專用編號並原地往返；`../` 逃出安裝子路徑、`//x.example/uploads/<32 hex>/a.png`、同 origin 不同安裝前綴、其他專案 id、檔名後緊接 `](https://x.example/...)` 只做一般遮蔽、不可還原；提交未知、跨欄位或位置不合法的佔位字串，或最終文字仍含禁止內容時 `policyBlocked`，mutation 為 0；`<img src="…" width="300">`、帶標題的 `![a](… "說明")`、autolink 三種寫法可以原地往返；來源欄位含他主機的截圖、模型刪掉它的整欄編輯在 bypass 下仍需確認並顯示被移除的段數；本段對話沒讀過、只在另一段對話讀過，或程序重啟後才整欄寫回時一樣，確認前 mutation 為 0。

## 16. v6.2 變更紀錄

> **歷史紀錄，不是現行規範。** 本節記錄 v6.2 當時的處理。其中 Opus N-I8 列的「每列宣告判定方式」，以及 cursor I2 列的「判定時目標 404 記為 `resolvedExecuted`」，已由 v6.3 §7.6 與 §17 取代：重新讀取只產生觀察，不解除隔離。實作一律以 §0–§15 為準。

第 2 輪三份報告的 Critical、Important 與 Minor 逐項處理如下。重複項合併說明，合併時在每個來源列標示對應章節。程式碼引用以目前 MR5 分支頭核對。

### 16.1 逐項處理

| 來源 | 處理 |
|---|---|
| Codex C2／Opus N-C1／cursor C1 | §8 重寫：日誌改用獨立金鑰 `ai_write_journal_key.v1.*` 與獨立目錄 `ai_write_journal/`，不受 history 啟用、關閉、清除、保留期、容量與 provider reset 影響；寫明建立時機、`unavailable`／`keyMissing`／格式未知的處理、耐久性與帳號移除順序。已核對 `ai_history.dart`：history 金鑰只在啟用紀錄時建立，history-only clear 會刪除它。 |
| Codex C1 | §7.6 重寫：conflict keys 與 operation 名稱無關，建立類鎖父資源與資源種類；原請求在途時不能判定；§15 第 5 列加測。 |
| Codex I1 | §2：T1 綁定 entry、operation、方向與參數，封閉意圖詞表、否定詞與條件詞表，從紀錄恢復的訊息不授權；§15 第 16 列。已核對 `setStar`／`setSubscribed` 以布林值承載相反動作。 |
| Codex I2 | §12.2：維持 `stopWithTask="true"`，刪除依賴 `onTaskRemoved` 的承諾；`onTimeout` 先停服務、再盡力通知 Dart；`MainActivity.onDestroy` 停服務；§12.5、§15 第 22 列加測。已核對 AOSP `Service.java`。 |
| Codex I3 | §4.4、§8：對話計數表與明細分離，40 次 HTTP 為讀寫共用並包含 mutation、readback、分頁與重放；判定讀取另計預算；§15 第 19 列。 |
| Codex I4 | §6：先取 metadata 的 L，再讀 L 的內容，提議綁定 L 與兩個 digest；§15 第 9 列。採用 Opus N-I4(a) 的讀取順序（同一 commit、走不可變快取），效果等同 Codex 建議的單一快照。 |
| Codex I5 | §3：補入看板建立、重新命名、系統欄隱藏、清單新增與排序（已核對 `boards_page.dart` 這些呼叫）；ledger 標示現有方法或新增包裝；GraphQL 排除項改為納入（MR6b-3）；§15 第 21 列覆蓋檢查。 |
| Codex I6 | §15 第 13 列重寫：一對一只針對 REST mutation 與 `graphMutation`；固定 `graphQuery` POST 是讀取。已核對 `gitlab_api.dart` 以 `!graphQuery` 判定寫入，`snoozedTodos` 走 `graphQuery`。 |
| Codex I7 | §15 第 17、22 列；§14 分派到各 MR。已核對 runner 的 `toolDeadline` 與 run `Timer`。 |
| Codex I8 | §5 分為 (A)／(B)，(B) 不做中和也不改寫；§15 第 14 列。與 Opus N-I5(b) 合併。 |
| Codex M1 | §10：AI 標註移出 hash，切換時以 payload digest 使舊核准失效。與 Opus N-I10、cursor Minor 2 合併。 |
| Codex M2 | 部分採納。§9 寫明優先順序，但依據是上限：上限為唯讀時不含寫入工具；只把目前等級調到唯讀時工具留在凍結前綴、由閘門拒絕。不採用「依目前等級決定」，因為那會讓每次在唯讀與可寫之間切換都破壞凍結前綴，與 §9 的固定前綴原則及 Opus m2、cursor Minor 1 不一致；安全性由閘門拒絕保證，唯讀等級仍「不會寫入」。 |
| Opus N-I1 | §3：列出需新增的具名包裝，畫面同一 MR 改用。已核對 `work_item_page.dart`、`discussions_tab.dart`、`diff_page.dart`、`draft_review_page.dart`、`project_more_page.dart`、`boards_page.dart`、`snippets_page.dart`、`registries_page.dart` 直接呼叫通用通道。 |
| Opus N-I2 | §3：GraphQL Work Item 13 個具名方法與 `setIncidentStatus` 改為納入 ledger，於 MR6b-3 交付（§0 第 1 點已定「全部納入」，不需另行確認延後）。二進位上傳仍排除，列為待擁有者決定（§16.2）。 |
| Opus N-I3 | §3：直接 commit、套用建議、設定自動合併到預設或受保護分支升為 T4；保護狀態由前置讀取判定。屬收緊，未動硬底線。 |
| Opus N-I4 | (a) 見 Codex I4；(b) §5 第 4 點：精確片段編輯的秘密掃描以變動區塊為單位，既有命中只標示；§15 第 9 列。與 cursor Minor 3 合併。 |
| Opus N-I5 | (a) §5 第 9 點：範圍外 closing pattern 與跨專案參照在任何等級改為確認，列入固定確認清單（已查 GitLab 文件「Closing issues automatically」，2026-10-21）；(b) 見 Codex I8。 |
| Opus N-I6 | §2：明確語法、一般字詞不綁定、複合目標每個元件綁定、多專案需帶專案路徑。與 Codex I1、cursor I1 合併。 |
| Opus N-I7 | §7.5：dispatch 後的 `cancelled` 記為狀態未知，晚到結果只在停止與 run 逾時；§12.1：切帳號等待在途寫入或「立即切換」。已核對 `GitLabApi.close()` 與各檢查點丟 `cancelled`。 |
| Opus N-I8 | §7.6：每列宣告判定方式，無法判定時提供前景、需輸入確認名稱的「我已在 GitLab 核對，解除鎖定」。 |
| Opus N-I9 | §8：狀態機補 `prepared` 時機與 `resolved*` 終態、對話計數表、只淘汰超過 60 分鐘的終態明細、啟動恢復涵蓋所有帳號；§7.3：帳號級短臨界區。 |
| Opus N-I10 | §4.1、§10：hash 綁定已同意上限，調低只遞增 revision、不需重新同意。已核對 `AiSettingsController.isValid` 為 hash 精確比對。 |
| Opus N-I11 | §12.2：前景通知改由原生擁有，「全部停止」走服務與 MethodChannel；補「沒有前景服務時」的規則；`onTimeout` 先停服務。移除工作採 Codex I2 的 `stopWithTask="true"`，不採用 Opus 的 `stopWithTask="false"`＋`onTaskRemoved`：前者在回呼不送達時也不會留下殭屍服務，後者依賴各廠牌送達回呼；差異列入 §12.7。外掛背景 isolate 一項已由 README 確認，不再是 NOT_VERIFIED。 |
| Opus N-I12 | §3「草稿審查整批送出」：預覽全部草稿、全部經 (A) 檢查、含他人草稿任何等級確認、沿用快照比對；§15 第 20 列。已核對 `draft_review_page.dart` 的快照比對。 |
| Opus m1 | §3 T4 列與 §4.1 固定確認清單：`markAllTodosDone` 含 bypass 都要確認。 |
| Opus m2 | §9，見 Codex M2。 |
| Opus m3 | §10：兩個版本都改為 2，MR6b-1 合併後所有既有同意需重新同意；`toolsEnabled` 為 false 時沒有寫入工具。已核對 `aiConsentContractFor` 預設引用 `aiToolCatalogueVersion`（目前為 1）。 |
| Opus m4 | §7.5：OAuth refresh 成功後的 401 為狀態未知，PAT 的 401 為確定未執行；§15 第 5 列。已核對 `gitlab_api.dart` 的 refresh 分支與 `_refreshOAuth` 對 PAT 回 false。 |
| Opus m5 | §3 T1 列：延後／取消延後為具名 GraphQL 方法，以待辦所屬專案驗證歸屬。 |
| Opus m6 | §3 原則與 T2 列：不暴露 `target_project_id`；降低機密性只指既有資源由 true 改 false；新建非 private 片段算提高可見度。 |
| Opus m7 | §4.4：提議時保留核准後新鮮讀取與 readback 所需額度。 |
| Opus m8 | §12.3：啟動時依 id 範圍精確取消遺留的「需要確認」通知。 |
| Opus m9 | §4.2：沒有生物辨識也沒有螢幕鎖時無法開啟 bypass，顯示原因。 |
| Opus m10 | §14：MR6b-1 以假 ledger 列證明 T3 以上的分級與閘門，MR6b-2 以真實工具重跑。與 cursor I4 合併。 |
| Opus m11 | §15 第 3、4、5、8、9、11、14、16、19、20、22 列補入所列測試。 |
| Opus m12 | §12.2：不另開 multidex（條件寫明為 minSdk ≥ 21），保留 desugaring；MR6c 以實際 minSdk 確認。 |
| Opus m13 | §7.2：拒絕、失敗、狀態未知、到期後保留卡片上的修改。 |
| Opus m14 | §5 第 6 點：讀過可見度較高限制的來源後寫到更公開的目標，同樣視為污染。 |
| cursor C2 | §3：每列標示現有方法或新增包裝；`createNote` 的 resource 改列舉；設定自動合併用 `mergeRequest(autoMerge: true)`，取消才用 `cancelAutoMerge`；MR 白名單含 `reviewer_ids`；`ci_config_path` 由前置讀取取得（已核對 `Project` 模型沒有此欄位）；片段改用精確片段（已核對 `updateSnippetPayload` 送整份內容）；GraphQL 具名方法納入。欄位白名單不採用 cursor 列的 8 個固定欄位，改為「與畫面編輯器的 `EditField` 集合相同」：已核對畫面另有 `due_date`、`severity`、`reviewer_ids`，並在 PUT 前移除 `issue_type`。 |
| cursor I1 | §2 目標語法與意圖詞封閉表；§3 新增「確認名稱來源」逐列規定 `requiredText`。 |
| cursor I2 | §7.5 依 `ApiFailure.kind` 分類（5xx、`cancelled`、空或無法解析的 body 為狀態未知）；§7.6 手動核對解鎖；§15 第 5 列。兩點不採用：（1）「DELETE 的 404 記為成功」不採用，AGENTS.md 規定 404 有歧義（無權限與不存在無法區分），首次 DELETE 得到 404 代表這次請求沒有造成刪除，記為確定未執行並以歧義文案顯示；判定時目標 404 才記為 `resolvedExecuted` 並標明「可能已刪除或無權限檢視」。（2）建立類 key 含 payload digest 不採用，依 Codex C1，稍改 payload 就能繞過鎖重送，改為鎖父資源與資源種類，以手動解鎖避免永久鎖住。`redirectBlocked` 也從確定未執行改列狀態未知（保守）。 |
| cursor I3 | §12.2：`onTimeout` 先停服務再通知 Dart，不採用「先經 MethodChannel 落盤再 `stopSelf()`」：AOSP 文件寫明只有數秒寬限，未及時停止 app 會 crash，不能等 Dart。第一張前景通知的擁有者改為原生（見 Opus N-I11）。根頁 run 進行中改 `canPop: false`＋`moveTaskToBack`（已核對首頁 `canPop` 為 true）。「外掛會帶入開機接收器」不採用：已核對外掛 manifest（上游 master）只宣告 `VIBRATE` 與 `POST_NOTIFICATIONS`，README（22.3.2）要求 app 自行加入開機接收器；改為 MR6c 檢查合併後 manifest 沒有該接收器。 |
| cursor I4 | §14 分派；§15 新增第 18 列同輪 fail-stop。 |
| cursor Minor 1 | §9，見 Codex M2（採用上限為準）。 |
| cursor Minor 2 | §10，見 Codex M1。 |
| cursor Minor 3 | §5 第 4 點，見 Opus N-I4(b)。 |
| cursor Minor 4 | §8：啟動時 `prepared` → `notExecuted` 並可淘汰。 |
| cursor Minor 5 | §3 T3 列：`squash` 留在合併的層級，預覽顯示是否 squash；§15 第 8 列。 |

### 16.2 擁有者確認（2026-10-21 已回覆）

1. **二進位上傳（`uploadProjectFile`）：** 擁有者 2026-10-21 決定納入，只限使用者在對話中附的檔，見 §3.1（MR6a 附檔、MR6b-1 上傳，§15 第 23 列）。
2. **手動解除狀態未知的鎖（`resolvedByUser`）：** 擁有者 2026-10-21 確認採用此預設：提供（§7.6），需前景、輸入確認名稱，解除後下一次寫入在 bypass 以外需確認。若不要這個動作，無法判定的寫入會一直鎖住該目標，直到帳號移除。
3. **移除工作當下的中斷通知：** 擁有者 2026-10-21 確認採用此預設：不承諾（`stopWithTask="true"`，下次啟動時呈現）。若要當下通知，需改採 `stopWithTask="false"`＋`onTaskRemoved` 並做各廠牌驗證（§12.7）。

另外兩項屬計畫內的調整，不需擁有者決定，在此告知：直接 commit 到預設或受保護分支升為 T4（收緊，未動硬底線）；GraphQL Work Item 與事件單寫入依 §0 第 1 點納入，另開 MR6b-3 交付，仍在 MR6 系列內、MR7 之前。

## 17. v6.3 變更紀錄

**兩輪之間加入、第 3 輪審查者沒有看過的內容：** §0 第 11 點與 §3.1「使用者附檔上傳」，以及 §13、§14、§15 第 23 列的對應改動，是第 2、3 輪之間依擁有者 2026-10-21 對 §16.2 的回覆加入的。第 4 輪請全文審查這幾處；本版已讓 §3.1 與本輪修改的日誌、隔離、分類與續跑規則一致。

第 3 輪三份報告的 Critical、Important 與 Minor 逐項處理如下（合併的重複項在每個來源列標示對應章節）。三份報告都確認 §16 的拒絕理由成立。程式碼以 MR5 分支目前的頭核對（審查者看的是較早的 commit，行號可能不同，本文盡量不引用行號）。

### 17.1 逐項處理

| 來源 | 處理 |
|---|---|
| Codex C1 | §7.6 重寫：「重新讀取以確認」只產生觀察（狀態已相符、目標仍存在、找不到、404、名稱相符都只是觀察），不解除隔離；v2 沒有自動解除，只有 §0 第 11 點的手動解除。日誌另存綁定的 revision 值與觀察摘要（§8）；§15 第 5 列加入晚到落地、重啟、DELETE 404、同名重建等情境。與 Opus N3-I3(a)、cursor I1 合併為同一條規則。 |
| Codex I1 | §2 新增 `groupWorkItem` 範圍（從群組 Work Item 頁開啟或 UI 加入，以 `namespace.fullPath` 與 Group GID 驗證，不授權群組下的專案）；§7.6 群組 key `(account, group:<id>, workItem, iid)`；§3 手動解鎖名稱；§5 第 6 點群組可見度；§15 第 24 列。已核對 `WorkItemGraphSummary.project` 可為 null、另有 `namespace`。與 Opus N3-I5、cursor I3 合併。 |
| Codex I2 | §3 新增「合併前的既有變更檢查」：全部分頁的 `…/diffs`（含改名舊路徑與刪除）以 `changes_count` 核對完整性、MR 描述與 commit message、`…/closes_issues`；命中 CI 即硬底線，範圍外關閉進固定確認清單，不完整不產生提議；套用建議依實際路徑判定；§7.1 綁定摘要；§15 第 26 列。已核對 GitLab 官方 API 文件確有 `diffs`（分頁，含 `old_path`／`new_path`／`deleted_file`／`new_file`）與 `closes_issues`。 |
| Codex I3 | §12.2 新增「原生執行許可」：`onTimeout`、全部停止、`onDestroy` 先使許可失效再停服務；綁有許可的 run 每次模型呼叫與 mutation dispatch 前向原生端確認，失敗即暫停；§7.4、§12.5 合併情境、§15 第 27 列；MethodChannel 往返列為 NOT_VERIFIED（§12.7）。 |
| Codex I4 | §7.6、§8 新增耐久的「待確認標記」：不隨明細淘汰，只在下一次相交寫入進入 `dispatching` 時原子消耗；§15 第 3 列。 |
| Codex I5 | §8 新增「重設寫入日誌」協定：獨立標記 `ai_write_journal_reset_pending.v1.*`、owner epoch 失效、固定刪除與重建順序、啟動時 tombstone → 重設 → 一般恢復，重設中斷不走首次建立；§15 第 3 列。 |
| Codex M1 | §3、§7.4、§14：待辦延後歸 MR6b-3；每個 GraphQL 方法列明 fence 與 HTTP 上限；`setIncidentStatus` 一律帶 `expectedUpdatedAt`（已核對目前為選填）；`snoozedTodos` truncated 不當成功證明。與 Opus m2(a) 合併。 |
| Codex M2 | §10：已同意上限存在每個 provider 的 `AiConsentRecord`；v1 → v2 遷移保留既有設定，舊同意的已同意上限為唯讀；原始 v1 fixture 往返測試（§15 第 11 列）。已核對 `AiAccountRecord.consents` 是每個 provider 一筆、decoder 只接受 version 1。與 Opus m3 合併。 |
| Codex M3 | §8：計數項在第一次實際 dispatch 時才建立；計數項 2,000 列、ciphertext 1 MiB 上限；到上限回 `storageLimit` 拒絕寫入，不淘汰有效狀態；§15 第 19 列。與 Opus m4 合併（見該列的不採用部分）。 |
| Codex M4 | §3「解除狀態未知的鎖」依 conflict key 種類列出確認名稱，涵蓋 T1 到硬底線；無法取得可驗證名稱時不顯示解鎖動作。與 Opus N3-I3(b) 合併。 |
| Opus N3-I1 | §7.3、§7.6、§8：`dispatching` 與 `writeUncertain` 同為隔離狀態；conflict-domain 鎖持有到終態落盤；`AiWriteJournal.instance` 為程序級單例並由 coordinator 以日誌為準判斷隔離；每筆明細記 `processId`，啟動恢復只轉換其他程序的明細，恢復完成前該帳號寫入一律 deny。已核對 `accountsLoaded` 在 `initialize` 時先重設再設回。 |
| Opus N3-I2 | §8 金鑰改為四種讀取狀態，「未初始化」時在第一筆 `prepared` 前於帳號 fence 內建立並讀回；同意可預先建立但失敗不影響同意。 |
| Opus N3-I3 | (a) 不照原文採用：被 Codex C1 更嚴的規則取代，v2 不做自動判定，因此「revision 條件讓已執行無法判定」的問題不再存在。(b) 採用，見 Codex M4。 |
| Opus N3-I4 | §7.4：MR6b-3 為每個 GraphQL 寫入方法加 awaited `beforeMutation` 掛鉤，掛鉤前的失敗為 `notExecuted`；§7.5 依 `mutationSent` 分類；§7.3 共用畫面的寫入登錄（日期與健康度的 private 登錄移到可共用的位置）；ledger 寫方法內 HTTP 上限；§15 第 25 列。已核對 `onMutationSent` 是同步 `void Function()`（狀態方法另一型別），只在指派、日期、健康度、標籤、里程碑、權重、狀態上存在；`WorkItemStatusWriteRegistry`、`_DatesWriteRegistry`、`_HealthWriteRegistry` 都存在。 |
| Opus N3-I5 | 見 Codex I1。 |
| Opus N3-I6 | 部分不採用。「`createBranch`、`deleteBranch`、`createTag`、`deleteTag`、`createRelease`、`updateRelease`、`deleteRelease` 沒有任何畫面」不成立：`project_more_page.dart` 的 `MetadataPage`（`MetadataKind` 含 branches、tags、releases）以通用通道建立與刪除分支、tag，建立、編輯、刪除 Release，並拒絕刪除預設或受保護分支；只是沒有呼叫具名方法。因此不需要擁有者確認，改列入 §3「畫面改用」（MR6b-2）。真正只有 API 的是 `batchApplySuggestions`（畫面只用 `applySuggestion`），保留並自訂白名單與逐一歸屬驗證。其餘採用：`work_item_page.dart`、`discussions_tab.dart` 改用現有具名方法；片段中繼資料、檔案新增與改名（T2）、單一檔案刪除（T4）；議題白名單移除 `due_date`、`createIssue` 接受 `issue_type`（已核對畫面建立時送 `ownerType.apiValue`，編輯器沒有 `due_date`，這是 v6.2 的錯誤）；`createDraftNote` 的 position；`deleteBranch` 前置讀取保護狀態；Release 白名單與畫面相同（`tag_name` 必須是已存在的 tag、`name`、`description`）。 |
| Opus N3-I7 | §3：`createPipeline`、`pipelineAction(retry)`、`jobAction(retry|play)`、`playPipelineSchedule` 在預設、受保護分支或 tag 上，或對象含 environment Job → T4；`createTag` 一律 T4；environment 資料來源由 MR6b-2 寫入 ledger 並驗證（NOT_VERIFIED），讀不到視同部署；§15 第 8 列。已核對 app 目前沒有讀取 Job 的 environment。「會建立新 tag 的 `createRelease` 升 T4」不需要：Release 白名單與畫面相同，不接受 `ref`，建立 Release 不會建立 tag。 |
| Opus m1 | §5 第 6 點改正方向：來源的可見度限制比目標嚴格時才算污染。 |
| Opus m2 | (a) 見 Codex M1；(b) §14：第 20 列與第 10 列的 suggestion 歸屬改由 MR6b-2 證明；(c) 切換、登出、移除帳號的等待移到 MR6b-1（§12.1、§14）。與 cursor I5 合併。 |
| Opus m3 | 見 Codex M2；目前上限預設「低風險自動」（§4.1）。 |
| Opus m4 | 採用大小上限，見 Codex M3；「超過時回收最久未使用的計數項」不採用，依 Codex M3 改為拒絕寫入、不淘汰有效計數（較嚴）。 |
| Opus m5 | §8「耐久性」如實寫出殘餘風險：Dart 無法對目錄 fsync，斷電或核心當機時最後一次改名可能遺失。已核對 history 檔案寫入是 `flushSync`＋`renameSync`。 |
| Opus m6 | §5 第 5 點：遮蔽標記只檢查 `new` 與跨越邊界的命中；§15 第 9 列。 |
| Opus m7 | §7.6：建立類觀察以 `Date` 標頭推算伺服器時間、前後放寬 5 分鐘；只作觀察，不解除。 |
| Opus m8 | 部分採用。建立專案固定個人 namespace、private、`initialize_with_readme`（§2、§3）。fork 不採用「目的地可在卡片上選」：兩處 fork 畫面都不帶 `namespacePath`，與畫面相同只到個人 namespace。 |
| Opus m9 | §12.1：移除帳號（含目前帳號）前套用同樣的確認與等待；§8 帳號移除引用；§15 第 4 列。已核對 `_remove` 的呼叫順序。 |
| Opus m10 | §5 第 2 點：(B) 的提及只看 Markdown 檔變動區塊、Release 說明、片段描述；§15 第 14 列。 |
| Opus m11 | §2：以介面語言與裝置語言清單比對，任一適用語系命中否定或條件詞即改為確認；§15 第 16 列。 |
| cursor C1 | §7.4、§7.5：GraphQL 方法不以正常返回或外層例外分類，依 `mutationSent` 分類，不經 `safeFailure`；已核對日期方法以 `notApplied`／`writeUncertain` 正常返回、健康度方法在 mutation 已送出後可能返回 `notApplied`、`safeFailure` 把非 `ApiFailure` 壓成 `invalidResponse`。「在 `onMutationSent` 回呼裡 flush」不採用：它是同步 `void Function()`，無法等待 flush，改用 Opus N3-I4 的 awaited `beforeMutation`。 |
| cursor I1 | 見 Codex C1：刪除讀到目標仍存在不再解除，隔離維持。 |
| cursor I2 | §7.3、§8：`prepared` 與每次狀態轉移都在帳號級短臨界區內；進鎖後發現隔離或預算不足改 `notExecuted`、不消耗計數；日誌金鑰只受帳號移除 tombstone 與日誌重設標記阻擋，`ai_history_clear_pending.v1.*` 不碰日誌（已核對兩個標記前綴）。 |
| cursor I3 | 見 Codex I1；另採用 REST 與 GraphQL 共用 key、GID 只作別名、看板卡片移動共用議題的 key（§7.6）。群組 key 用 Group GID 的數字 ID 加 iid、Work Item GID 為別名，與專案層級的形式一致。 |
| cursor I4 | §4.3 第 9 點：既有檔案與既有片段只接受精確片段，新檔案與新片段接受一份初始正文並全文掃描（§3、§6）；§4.1 固定確認清單改為只含 (B) 類 Markdown 的外部圖片，(A) 類一律 `policyBlocked`、確認也不能送出。 |
| cursor I5 | §14：第 16、20 列分派到 MR6b-2，第 16 列的 Work Item 表情與通知方向分派到 MR6b-3。 |
| cursor I6 | §7.7 新增「續跑不重複」：已進入 `dispatching` 或終態的執行不再呼叫 mutation，相同 operation 與 key 的新提議改為確認並標示「可能重複」；§12.2、§12.6、§3.1 引用；§4.1 固定確認清單；§15 第 28 列。 |
| cursor M1 | 見 Opus N3-I6：議題白名單不含 `due_date`；`createProject` 只接受 name、path、description；`MetadataPage` 的分支、tag、Release 改接既有具名方法（MR6b-2）。 |
| cursor M2 | §12.2「根頁返回」：`canPop` 為 false 之後，在現有 `onPopInvokedWithResult` 處理完 detail 與分頁返回後才 `moveTaskToBack`。已核對該回呼目前只改回首頁。 |
| cursor M3 | §10：MR6b-2、MR6b-3 擴大 operation 集合時 `aiToolCatalogueVersion` 各再加 1；§2、§15 第 15 列：意圖詞表只涵蓋會自動執行的 T1 operation。 |
| 自行發現 | §3「取消自動合併的端點」：現有 `cancelAutoMerge` 呼叫的 `cancel_merge_when_pipeline_succeeds`，GitLab 官方 API 文件標示在 19.5 起 deprecated、改用 `cancel_auto_merge`；MR6b-2 依 instance 版本選用。 |

### 17.2 本輪新增的尚未驗證項目

- 部署判定的 environment 資料來源（§3，MR6b-2 必須在實際 instance 驗證；驗證前一律視同部署）。
- 背景中 Dart 經 MethodChannel 向原生服務確認許可的往返（§12.7，MR6c）。

本輪沒有需要擁有者另行決定的事項：附檔、手動解除與移除工作通知三項已在 §0 第 11 點定案；其餘修改都是在既有決定內收緊或補齊規則。

## 18. v6.4 變更紀錄

第 4 輪三份報告都沒有新的 Critical，並確認 §17 的拒絕理由成立。以下逐項處理 22 個 Important 與 14 個 Minor（合併的重複項在每個來源列標示對應章節）。程式碼以 MR5 分支目前的頭核對；GitLab 平台事實以官方文件原文（master，2026-10-21 取得）核對。§17.2 的「部署判定的 environment 資料來源」一項已不需要：本版改為會執行 Pipeline 或 Job 的操作一律 T4。

### 18.1 逐項處理

| 來源 | 處理 |
|---|---|
| Codex I1 | §7.3 第 4 步定義送出邊界：不連網預檢 → 原生送出票 → flush `dispatching` → 同步重驗（停止、generation、API owner、scope／policy／consent revision、票未使用），重驗到 mutation 之間不再 await，通過即「接受點」。同步重驗不通過是唯一允許的 `dispatching` → `notExecuted`，原子退回預算與待確認標記（§8）。§12.2 原生端改為一次性 `acquireContinuation`，明確定義「失效先於核發 → 零送出；已核發的票視為在途」，不宣稱更強的撤回能力。§15 第 29 列。與 Opus N-I4、cursor I4 合併。 |
| Codex I2 | §7.5 GraphQL 分類先看接受點：之前的任何返回或例外都是 `notExecuted`；日期 `applied`＋false、健康度與狀態 `noop` 記「無變更」、同輪繼續；`notApplied`＋false 仍適用 fail-stop。已核對日期方法與健康度方法確有這些 `mutationSent: false` 的正常返回。§15 第 25 列。與 cursor I1、Opus m1 合併。 |
| Codex I3 | §8「重設寫入日誌」改為輸入目前帳號的 `@username`（前景、已驗證帳號的設定頁，顯示 instance 與 numeric user ID），名稱無法驗證或期間切帳號不得提交。已核對 `confirmAction` 的 `requiredText` 是選填。與 Opus N-I6 合併。 |
| Codex I4 | §3.1、§8：日誌在 `prepared` 時保存驗證過的檔名（不是 bytes、`url` 或 `markdown`），重啟後仍可解除；上傳的解除文案如實說明 GitLab 可能沒有可核對的位置。§15 第 23 列。與 cursor I2、Opus m2 合併。 |
| Codex I5 | §3.1：provider 外送層新增 GitLab 上傳路徑遮蔽規則，涵蓋讀取工具、context 與寫入結果投影，也涵蓋既有上傳；辨識沿用 `lib/shared/attachment_ref.dart` 的規則。已核對 `redaction.dart` 沒有上傳路徑規則、`_projectDiscussion` 保留描述與留言內文。§15 第 23 列。 |
| Codex I6 | 不採用「依版本選端點」，改採 Opus N-I2 提出的簡化：只用舊端點 `cancel_merge_when_pipeline_succeeds`（19.5 起 deprecated，尚未移除），不讀版本、不探測、不改送另一端點，所以沒有「版本讀不到」的分支。舊端點 201＋`status` 的分類、前置讀取與 readback 已補（§3）。已核對官方文件：201＋`success` 才是取消、201＋`error` 是沒有設定自動合併、401 表示沒有權限、不回傳 MR。§15 第 30 列。與 Opus N-I2、cursor I6 合併。 |
| Codex I7 | §3「排程播放的參數」：以前置讀取取得排程的 `variables` 與 `inputs`，非空即按「帶變數執行 Pipeline」硬底線；`last_pipeline` 不作為不部署的證據（排程播放一律 T4）。部分不採用：欄位缺席或不可讀時不採「不 dispatch」，而是同樣按硬底線、要求輸入 ref。理由：官方文件寫明這兩欄只對 Maintainer／Owner 回傳，拒絕會讓其他角色完全不能用 AI 播放排程；硬底線已把決定交還使用者。這些變數由維護者設定、不由模型提供，所以不套用變數名稱禁止與秘密檢查；值不送模型、不寫日誌。§15 第 30 列。 |
| Codex I8 | §3「待辦延後的歸屬」：以 `currentUser` 的固定 query 驗證 Todo GID 與 target；`project` 為 null 的 Work Item target 另以固定 query 驗證 namespace、Group GID 與 Work Item GID（MR6b-3 擴充 query）；不支援的 target 明確拒絕。已核對現有 query 對 Work Item 只讀 `iid`、`title`，parser 容許 `project` 為 null。§15 第 24 列。 |
| Codex M1 | §3.1：`markdown` 以完整字串解析、禁止控制字元與括號、由 app 重建 URL；替換後重驗 quick action 後置條件與 §5 判定。與 Opus N-I7、cursor I3 合併。 |
| Codex M2 | §3.1：選檔前原子保留容量，串流上限取 min(單檔、對話剩餘、程序剩餘)，讀取失敗或移除即釋放。與 Opus m3 合併。 |
| Codex M3 | (1) §15 第 23 列改為「送往 AI provider adapter」，並註明 bytes 可出現在授權目標 GitLab 的 multipart；(2) §14 的 MR6b-1、MR6b-2 證明欄列入第 21 列；(3) §16 開頭加註「歷史紀錄，不是現行規範」，指明被取代的兩列。與 Opus m6 合併。 |
| Opus N-I1 | §3.1「上傳逾時」：AI 上傳以每次請求的 `Options.sendTimeout` 改用 max(15 秒, 大小 ÷ 128 KiB/s)，上限 4 分鐘；畫面沿用預設；§7.4、§12.1 的等待上限對上傳改用這個值。已核對 dio 5.11.1 的 `IOHttpClientAdapter` 把整個 request stream 包在 `sendTimeout` 內，且 `_send` 對寫入的 `DioException` 一律丟 `writeUncertain`。§15 第 23 列。 |
| Opus N-I2 | 見 Codex I6（採用其中的簡化方案）。OAuth 帳號的假鎖已關閉：只對這個端點，401（含 refresh 成功後不重放）記為確定未執行、不上鎖，MR6b-2 讓 `_send` 的該失敗帶 `status: 401` 以便辨認；§7.5 的一般規則不變。前置讀取的 `user.can_merge` 用來提早說明原因，其是否等同取消權限列 NOT_VERIFIED，不影響上述分類。 |
| Opus N-I3 | 簡化為「會讓 Pipeline 或 Job 執行的操作一律 T4」（`createPipeline` 含功能分支、`pipelineAction(retry)`、`jobAction(retry|play)`、`playPipelineSchedule`），不再需要資料來源，也消除 `createPipeline` 的自相矛盾；`stop` 環境 Job 隨之涵蓋。已核對官方文件：REST Job 沒有 environment 欄位、`expandedEnvironmentName` 為 null 不構成證明。部分不採用：含 trigger Job 的 pipeline 不另列入固定確認清單。理由：§4.2 的 bypass 說明本就包含 CI；觸發後的下游 pipeline 是 CI 設定的行為，不是 app 對範圍外資源的寫入；偵測端點又依版本改名（`bridges` 與 `trigger_jobs`）。這一點改寫進同意框與 bypass 說明（§3、§10）。與 cursor I5 合併。 |
| Opus N-I4 | 見 Codex I1：送出票在 flush 之前取得；GraphQL 在方法內前置讀取之後的掛鉤中取得；`Service.onDestroy` 也使許可失效；「已核發的票視為在途」取代原本的殘餘風險句。§12.5、§15 第 27 列。 |
| Opus N-I5 | §2：範圍與 key 由前置讀取的擁有者決定，不由入口頁決定；從群組頁開啟的專案 Work Item 只授權該 Work Item 與其子資源。已核對 `groupWorkItems` 帶 `includeDescendants`。§7.6、§15 第 10、24 列。 |
| Opus N-I6 | 見 Codex I3；另採用 Opus 的「重設後 24 小時內，bypass 以外的寫入需確認」，作為被釋放 key 無法讀取時的帳號級待確認標記。帳號移除在有隔離、待確認標記或日誌無法讀取時改為輸入 `@username`，並寫明使用者看到的文字（§8、§12.1）。已核對 `_remove` 目前只呼叫沒有 `requiredText` 的 `confirmAction`。這樣所有解除路徑都要輸入名稱（§7.6），與 §0 第 11 點一致，不需擁有者另行決定。§15 第 31 列。 |
| Opus N-I7 | §3.1「佔位字串的替換」：替換在提議時進行，只能引用日誌已成功的上傳，上傳與引用不能同批；可替換目標含專案 Work Item 描述與活動留言，群組 Work Item 被擋；替換後重做 §5 判定；digest 與預覽以替換後文字為準。見 Codex M1。 |
| Opus N-I8 | §3.1、§10、§13：新增同意資料類別 `attachment_metadata`，MR6b-1 隨揭露 v2 加入；MR6a 不把附件中繼資料送給模型；資料安全表單另列。已核對 `aiConsentContractFor` 的預設類別只有 `job_log`、`diff`、`source`、`issue_text`、`comments`、`tool_reads`，沒有「你的訊息」類別（v6.3 這句是錯的）。 |
| Opus m1 | 見 Codex I2；另在送出邊界加入不連網預檢（client 已關閉、`Retry-After` 未到期），429 之後的本機快速失敗不再被包成狀態未知。§15 第 25 列。 |
| Opus m2 | 解除名稱在 `prepared` 時寫進日誌；以明細為單位解除（合併輸入 `!iid` 解除 MR 與目標 ref）；比對不含方向隔離字元（§3、§8）。部分不採用：上傳的解除名稱維持檔名，不改專案路徑。§3.1 由擁有者回覆時定為檔名，日誌保存原檔名後已能在重啟後使用；卡片另顯示 SHA-256 前段供辨識。 |
| Opus m3 | 程序級 100 MiB 上限與移除附件使提議作廢已補（§3.1）；刪除上傳「計入受影響資源數」這句（§4.4 只對批次定義上限）。見 Codex M2。 |
| Opus m4 | §3「待辦延後的歸屬」：mutation 回應的 `snoozedUntil` 即為成功；`snoozedTodos` 查不到或 truncated 只是不升為已 readback 確認。已核對 `snoozeTodo` 以回應中的 `snoozedUntil` 確認。 |
| Opus m5 | §14：第 15 列加入 MR6b-3；第 16 列補延後與取消延後；MR6c 以實際服務重跑第 28 列；第 23 列附件不送 provider 的部分在 MR6a 證明；片段全部寫入（含建立）移到 MR6b-2。不採用「把新增包裝拆成前置 MR」：屬可選，維持現有分批，實作時若拆出也不違反本計畫。 |
| Opus m6 | 見 Codex M3(3)。 |
| Opus m7 | §8、§12.2：日誌無法讀取時，啟動時呈現「寫入日誌無法讀取，可能有中斷的寫入」並提供重試或重設。這是 §0 第 11 點「下次啟動時呈現」在日誌損毀時的呈現方式，沒有改變該承諾。§7.6、§10：寫明隔離只在本裝置有效。 |
| cursor I1 | 見 Codex I2。狀態方法的既有 `onMutationSent(started)` 已核對為同步、必須呼叫 `started`；做法與 cursor 的簽名不同：另加 awaited `beforeMutation` 與同步 `mayStart`，放在 `onMutationSent(started)` 之前，AI 傳入的 `onMutationSent` 只呼叫 `started`。`WorkItemStatusSaveResult` 的 `notApplied`＋`mutationSent: true` 已列為狀態未知。 |
| cursor I2 | 見 Codex I4。 |
| cursor I3 | 見 Codex M1、Opus N-I7。部分不採用：伺服器回 2xx 且 JSON 可解析、但 `markdown` 不符格式時，不記 `writeUncertain`，而是記成功（伺服器已接受）並標示「不可引用」。理由：2xx 已證明上傳被接受，記成狀態未知反而會鎖住同一檔案並要求使用者手動解除；不替換、不把 URL 交給模型已達到安全目的，再上傳同一附件會標示可能重複。 |
| cursor I4 | 見 Codex I1：許可在 flush 之前確認，失敗為 `prepared` → `notExecuted`；GraphQL 的確認在前置讀取之後的掛鉤裡。終態落盤失敗時，記憶體中視為狀態未知、手動解除立刻可用，但解除本身要寫進日誌才生效（§7.3）。部分不採用「禁止 `dispatching` → `notExecuted`」：依 Codex I1，同步重驗不通過時 mutation 確定尚未開始，允許這一個轉移並在原子更新中退回；落盤失敗則維持 `dispatching`。 |
| cursor I5 | 見 Opus N-I3：`createPipeline` 不分 ref 一律 T4，不再有「功能分支仍為 T3」的例外。 |
| cursor I6 | 見 Codex I6：只用舊端點，沒有版本讀取，自然沒有「版本讀不到」的分支，也不以 404 探測。 |
| cursor M1 | §14 MR6b-3 的第 16 列加入延後與取消延後的方向；§15 第 16 列。 |
| cursor M2 | §5 第 6 點：可見度讀不到時改為確認；§7.6：群組 Work Item 的留言、表情與通知依賴群組 key。 |
| cursor M3 | §12.2：`acquireContinuation` 逾時 1 秒視同失效；服務已在跑時新 run 綁同一張許可，失效時這些 run 都要在前景續跑。 |
| cursor M4 | §3.1：採用「事後說明」：確認等級在卡片上警示，自動等級改在稽核列顯示，並寫進同意框。理由：上傳本身只建立 secret 連結，引用到公開內容的是後續文字寫入；使用者自己附檔並選擇了自動等級。 |

### 18.2 本輪的尚未驗證項目

- `user.can_merge` 是否完全等同「可取消自動合併」的權限（§3，MR6b-2 查核；不等同時，伺服器回的 401 依 §3 這個端點的規則記為確定未執行，不上鎖）。
- 背景中 `acquireContinuation` 的 MethodChannel 往返是否穩定在 1 秒內（§12.7，MR6c）。

### 18.3 擁有者

本輪沒有需要擁有者另行決定的事項。重設日誌與移除帳號都改為輸入 `@username`，所有解除路徑都要輸入名稱，符合 §0 第 11 點；日誌損毀時的「無法讀取」呈現方式寫在 §8，沒有改變 §0 的承諾。

## 19. v6.5 變更紀錄

第 5 輪三份報告都沒有新的 Critical，並確認 §18 的拒絕理由成立。本輪依「收斂時選最簡單、明顯安全的規則」處理 8 個 Important 與 19 個 Minor（重複項合併）。程式碼以 MR5 分支目前的頭核對；GitLab 平台事實以官方文件與 master 原始碼（2026-10-21 取得）核對。§18.2 的「`user.can_merge` 是否等同取消權限」已由原始碼結案：不等同（見 Opus m1 列）。

### 19.1 逐項處理

| 來源 | 處理 |
|---|---|
| Codex I1 | §3「執行時採用的既有參數」：digest 改為涵蓋完整參數集（名稱、值、型別；inputs 保留 JSON 型別），值只進 digest、不進預覽、日誌或 provider；「無法讀取」是獨立狀態，卡片寫明無法核對；名稱、值、型別、ref 或可讀性任一改變即作廢。§15 第 30 列。與 cursor I3 合併。這是比「只綁名稱」更簡單也更嚴的規則：整個參數集一個 digest。 |
| Codex I2 | §8「帳號移除」改為固定流程：兩個入口（`authenticated_app.dart` 的 `_remove`、`login_screen.dart` 的移除按鈕）在顯示任何確認框之前，先以 `AiAccountMutationCoordinator` 的既有 cleaning 狀態進入「移除中」，拒絕新的 run、核准、`prepared` 與接受點；停止並等待後重讀日誌，才決定是否要輸入 `@username`；「移除中」維持到 `session.remove` 完成，取消時 epoch 加 1、舊核准不恢復。§7.3 第 4.4 步重驗這個狀態；§12.1、§15 第 31 列。已核對兩個入口都在普通確認後先 await 三項清理才進 `clearAiAccountData`，且 coordinator 已有 `beginCleaning`／`reopen`。 |
| Codex M1 | §8 重設順序改為「建立新金鑰並讀回 → 原子寫入含 24 小時標記與截止時間的初始日誌 → 刪 `reset_pending`」；§15 第 31 列逐步中斷。 |
| Codex M2 | 見 Opus N5-I1。 |
| Codex M3 | MR6a 的附檔 UI 改為關閉（見 Opus m9），MR6a 只證明沒有附件讀取；紀錄存取、重載、`restoreFromDisplay` 與強制 projection 的中繼資料測試移到 MR6b-1（§15 第 23 列）。 |
| Codex M4 | §3：取消仍為 T3，但寫明取消執行中的 Job 可能讓 `after_script` 執行，不保證停止所有 CI 副作用；§10 同意框同一句。與 Opus m3、cursor M4 合併。 |
| Codex M5 | 見 Opus m1：`user.can_merge` 不再作閘門。 |
| Opus N5-I1 | §3.1：外送遮蔽改為一條不需要專案或頁面上下文的文字規則，任何 `uploads/<32 hex>/<檔名>` 不論前綴與主機都換掉，不判斷是否同一 instance（寧可多遮）；明寫不重用 `parseProjectUpload`（它是只認目前頁面專案的下載允許清單，維持原樣）。已核對 `parseProjectUpload` 在 `projectId` 為 null 時回 null、`/-/project/<id>/` 只接受本頁專案。§15 第 23 列加入其他專案、群組、他 instance、Job log 與原始碼的案例。與 cursor I1、Codex M2 合併。 |
| Opus N5-I2 | 採方案 A，不需擁有者決定：外送層換成可還原的 `[[upload:u-<n>]]`，對照表只在本程序記憶體、綁定來源資源的容器；寫入時只在容器相同的 (A) 類欄位還原，其他情況擋下並請模型重新讀取。這讓含既有附件的描述與留言仍可由 AI 編輯，維持 §0 第 1 點；方案 B 會縮小 §0 第 1 點，不採用。還原只把原本就在這個容器內容中的連結寫回同一容器，不新增外流。§3.1、§5 第 5 點、§15 第 32 列。 |
| Opus m1 | §3「取消自動合併」：已核對 GitLab master 原始碼 `can_cancel_auto_merge?` 為 `can_be_merged_by?(current_user) || author == current_user`，所以 `user.can_merge` 不作閘門；false 且非作者時只提示。 |
| Opus m2 | §7.5：任何 HTTP 401 回應都記為確定未執行（含 OAuth refresh 成功但依不變式不重放的寫入），MR6b-1 讓 `_send` 在該路徑帶 `status: 401`。理由：401 是伺服器在執行前的拒絕，不重放只是不重試；沿用舊分類會讓 OAuth token 到期（目前沒有提前 refresh）後的第一次寫入系統性上鎖。§3 取消端點不再需要特例；§15 第 5、30 列。這與 cursor I2「只對取消端點例外」的建議衝突，取較簡單的一般規則（見 cursor I2 列）。 |
| Opus m3 | §3 規則改名為「直接執行 Pipeline 或 Job 的操作一律 T4（只限這四個方法）」，並寫明 commit、建立分支、合併、rebase 觸發的 pipeline 維持各自層級、屬殘餘風險；§10、§4.2 使用同一句揭露。 |
| Opus m4 | 不採用。改採較嚴也較簡單的規則：排程 `inputs` 欄位不存在時也算「無法讀取」，該版本上播放排程一律輸入 ref，不依版本或「`variables` 有回傳」放寬（§3）。理由：依欄位是否出現推斷 instance 能力，是另一條會產生邊界案例的規則；寧可在舊版本多要求一次輸入名稱。 |
| Opus m5 | 部分採用、改得更嚴：重跑 Pipeline、重跑或播放 Job 時，以固定讀取取得所屬 Pipeline 的 pipeline 變數（`GET /projects/:id/pipelines/:pipeline_id/variables`，已核對官方文件），非空或讀不到即按 §0 第 2 點的「帶變數執行 Pipeline」硬底線；重跑手動 Job 一律視為讀不到（可能沿用第一次播放時的變數，是否沿用為 NOT_VERIFIED，但規則不依賴它）。不採用「重跑不算帶變數執行」：那會讓 bypass 下自動執行帶變數的 pipeline，與排程規則和 §0 第 2 點不一致。 |
| Opus m6 | §7.5「無變更」改為通則（掛鉤前返回且結果等於要求值），ledger 逐列寫判定；§15 第 25 列逐一列出指派、里程碑、權重、通知、標籤。 |
| Opus m7 | §7.3 第 4.4 步重驗加入 client 未關閉、`Retry-After` 未到期、沒有許可的 run 仍在前景；§7.5 的本機拒絕列出 `attachmentTooLarge`；§15 第 29 列。 |
| Opus m8 | §3 確認名稱：重跑與播放為 Pipeline 或 Job 的 ID；播放排程的解除名稱與建立 Pipeline 相同；§7.6：建立 Pipeline 與播放排程以 `(account, project:<id>, pipeline)` 鎖定，Job 依賴所屬 Pipeline 的 key、Pipeline 的 retry／cancel／delete 與其所有 Job 相交。§15 第 5 列。 |
| Opus m9 | §3.1、§14：MR6a 以常數關閉附檔 UI（不顯示、不讀 bytes），MR6b-1 隨 `upload_attachment` 開啟；segment 不含該工具時附檔按鈕停用；附件中繼資料以 untrusted-data 區塊送出，檔名不參與目標綁定與意圖詞；§10：兩個新類別只在 `toolsEnabled` 時列入契約，並為 `_categoryLabel` 新增 l10n（已核對它目前把未知類別顯示為「其他」）。 |
| Opus m10 | §7.6 寫明系統路徑只有 orphan cleanup，完整還原後重新加入不保留隔離為殘餘風險；§8 寫明 token 已撤銷時的出口是以本機 username 確認的移除帳號。部分不採用：移除帳號仍計入 key 級待確認標記（不排除）。理由：維持一條規則（日誌中有任何安全狀態就輸入 `@username`）；移除帳號很少，多輸入一次名稱的成本低。 |
| cursor I1 | 見 Opus N5-I1。 |
| cursor I2 | 部分採用：自動合併是否開啟改用畫面的 `isAutoMergeEnabled`（兩個旗標任一，已核對 `work_item_page.dart`）；成功須 readback 顯示兩個旗標都已關閉；剛讀過 MR 卻 404 的文案。三點不採用：(1)「`auto_merge_enabled` 時改送 `cancel_auto_merge`」：已核對 GitLab master 原始碼，`AutoMergeService#cancel` 只在 `auto_merge_enabled?` 為 false 時回錯誤，否則清除目前啟用的策略，舊端點即涵蓋兩種旗標；維持單一端點也與畫面一致，且新端點只存在於 19.5 以上。(2)「201＋error 但旗標仍在時記狀態未知」：同一份原始碼顯示 error 只在未開啟或清除失敗回滾時回傳，所以記確定未執行，並顯示 readback 讀到的目前狀態。(3)「401 只對這個 operation 不上鎖」：改採 Opus m2 的一般規則。 |
| cursor I3 | 見 Codex I1；「明確為空」只限空陣列或空物件，缺席、null、權限省略都是「無法讀取」。 |
| cursor I4 | §3「待辦延後的歸屬」：延後與取消延後各用一條查詢，延後查未延後的待辦，禁止只用 `isSnoozed: true` 的清單；逐頁比對到 GID，截斷或預算用完為「無法驗證」、不送 mutation。已核對現有 `_snoozedTodosQuery` 只含已延後的待辦。§15 第 24 列。 |
| cursor M1 | §7.5：「進入 `dispatching` 後的 `cancelled` 一律狀態未知」改為只適用接受點之後。 |
| cursor M2 | §3.1：解除名稱是上傳時接受的檔名原文，不做會改字的正規化，卡片顯示原文與 SHA-256 前 8 碼；重建與還原的連結視為本 instance 媒體、不觸發 §5 第 3 點；同一 SHA-256 的重複上傳提示不限本 run。 |
| cursor M3 | §8：重設列出的筆數含 `dispatching` 與 `writeUncertain`；移除帳號時尚未到期的「重設後需確認」也要輸入 `@username`。 |
| cursor M4 | §14 MR6a 寫明模型看不到檔案也收不到檔名；§4.3 第 1 點寫明下游 pipeline 依 §3、§10 揭露、不列入固定確認；§10 的 CI 副作用句補上合併、rebase 與推送檔案。 |

### 19.2 本輪的尚未驗證項目

- 重跑手動 Job 是否沿用第一次播放時提供的變數（Opus m5）。規則已把它一律視為「無法讀取」而走硬底線，所以結果不影響安全，只影響是否能在日後放寬。
- 背景中 `acquireContinuation` 的 MethodChannel 往返（§12.7，沿用）。

### 19.3 擁有者

本輪沒有需要擁有者決定的事項。Opus N5-I2 的兩個方案中，選了不縮小 §0 第 1 點的方案 A。

## 20. v6.6 變更紀錄

第 6 輪三份報告都沒有新的 Critical，並確認 §19 的拒絕理由成立。其中三個 Important 來自 v6.5 的簡化；本輪修正時保持「簡單規則」，但讓它不再放寬任何安全規則。程式碼以 MR5 分支目前的頭核對；GitLab 平台事實以 master 原始碼與官方文件（2026-10-21 取得）核對。

### 20.1 逐項處理

| 來源 | 處理 |
|---|---|
| Codex I1 | §3.1 重寫可還原規則：只有「本 instance 自己的上傳路徑」（相對路徑，或 origin 與安裝子路徑通過 `GitLabInstance`；secret 與檔名通過 `projectUploadNamesOk`）才發可還原編號，其他主機一律一般遮蔽；外送時換掉**整段連結目標**，模型改不了前綴；佔位字串只能單獨構成連結或圖片的目標，緊鄰 `/`、`?`、`=`、`#`、`:`、`%` 或英數字元即擋；豁免只涵蓋第 4 點對這段路徑本身的秘密命中，§5 第 3 點對外部媒體的硬封鎖任何等級都不放寬。`[[attachment:…]]` 套用同樣的位置限制。§15 第 32 列。與 Opus N6-I3、cursor I1 合併。 |
| Codex M1 | 改得更嚴：對照表以「來源資源與欄位＋原始連結目標」為一筆，只還原回同一個資源的同一個欄位；同一連結出現在兩個資源就是兩筆，既有的筆不改寫。§15 第 32 列測兩種讀取順序。與 Opus m3(1) 合併（不採「記錄所有見過的容器」，見該列）。 |
| Codex M2 | 不需要 lease 交接：本輪改用獨立的 `AiRemovalHold`（見 Opus N6-I1），移除流程不在清理前呼叫 `beginCleaning`，`clearAiAccountData` 照現況自己取得 cleaning；日誌由日誌 owner 重讀，不經會被 cleaning 擋下的帳號紀錄讀取；已過接受點的寫入仍可寫終態；取消只釋放保留，不碰既有的 tombstone、`reset_pending` 或 cleanup fence（§8）。 |
| Codex M3 | 見 cursor I3。 |
| Opus N6-I1 | §8「帳號移除」改用獨立的「移除中」保留 `AiRemovalHold`（`AiWriteJournal.instance` 持有，本程序記憶體，以 token 識別），不再沿用 cleaning：不呼叫 `beginCleaning`、不發帳號紀錄通知，生命週期監聽器不讀也不能解除它；取得時遞增寫入 epoch；取消、`clearAiAccountData` 之前的失敗或頁面卸載時以 token 釋放並再遞增 epoch；維持到 `session.remove` 返回。§7.3 第 4.4 步改為檢查這張保留。已核對：`_trackAccountLifecycle` 在 history 為 `disabled`、帳號在 cleaning、session 不忙時會 `reopen`；`historyEnabled` 預設 false；`busy` 只在 connect／select／connectOAuth／remove 內設定；`read`／`mutate` 在 cleaning 時回 null；`_clearAccount` 自己 `beginCleaning`。§15 第 31 列。與 cursor I2 合併。 |
| Opus N6-I2 | §3「執行時採用的既有參數」：重跑與播放 Job 另讀所屬 Pipeline 的 `source`；`source` 為 `schedule`、`pipeline_execution_policy_schedule`、缺席或無法辨識時一律「無法讀取」，走硬底線（不另讀排程，較簡單也較嚴）；變數端點 404 也是「無法讀取」；`source` 進 digest。已核對 GitLab master `Gitlab::Ci::Variables::Builder` 依序合併 pipeline 變數、`pipeline_schedule_variables`（取排程上當下的 `job_variables`）與 Job 變數；單一 Pipeline 的 REST 回應含 `source`。§15 第 30 列。 |
| Opus N6-I3 | 見 Codex I1。 |
| Opus m1 | 見 cursor I3（GraphQL readback 的 401 依 `mutationSent` 規則為狀態未知；refresh 本身丟出例外時也帶 `status: 401`；§14 改為「REST mutation 回應的 401」）。 |
| Opus m2 | §3.1：`uploads/<32 hex>` 後面接 `/檔名`、分隔字元或字串結尾都遮蔽；任何截斷處修掉尾端的 `uploads/` 加 1–32 個十六進位字元。§15 第 23 列加截斷 fixture。 |
| Opus m3 | (1) 不採「每筆記錄所有見過的容器」：改用更嚴的「同一資源同一欄位」（Codex M1 列），同樣解決兩個資源各自能原地編輯的問題，且不需要跨資源比較可見度。(2) 使用者訊息中的上傳連結回「AI 不能把你訊息裡的上傳連結寫進 GitLab，請在畫面上自行貼上」。(3) 超過 1,000 筆時工具結果寫明原因。 |
| Opus m4 | 隨「只還原回原欄位」消失：不會把機密議題或內部留言的連結還原到其他資源；Job log 等來源不可還原。 |
| Opus m5 | 不需要擁有者決定：同一資源同一欄位的還原也涵蓋會被渲染的 (B) 類欄位（Release 說明、里程碑描述、片段描述），所以含附件的 Release 說明仍可由 AI 編輯，§0 第 1 點不縮小。§15 第 32 列。 |
| Opus m6 | §3.1 外送層第 1 步：來源文字中原本就有的 `[[upload:` 與 `[[attachment:` 先換成一般遮蔽標記。§15 第 23 列。 |
| Opus m7 | §3：是否為手動 Job 以固定 GraphQL 讀取 `CiJob.manualJob`（已核對官方 GraphQL reference 快照有此欄位），讀不到即視為手動，走硬底線。 |
| Opus m8 | §12.1：「將停止 N 個工作」的框只用於切換與登出；移除帳號在取得保留之後、有 run 時才顯示「將停止 N 個 AI 工作並移除這個帳號」（取消即釋放保留、run 不受影響），所以誤觸移除不會直接停掉工作。與 cursor M2 合併。 |
| Opus m9 | §3：digest 是以本程序隨機金鑰計算的 HMAC-SHA-256，不出現在工具結果或送 provider 的內容。與 cursor M1 合併。 |
| cursor I1 | 見 Codex I1、Codex M1。採用「只還原回讀到它的同一個資源」，並延伸到同一欄位、同一資源的 (B) 類 Markdown 欄位（Opus m5）。 |
| cursor I2 | 見 Opus N6-I1。部分不採用：不採「進入時呼叫一次 `beginCleaning`、把 lease 傳給 `_clearAccount`」。理由：協調者與 Opus 都指出 cleaning 是會被帳號生命週期監聽器解除的共用狀態；獨立保留不需要修改 `_clearAccount`，也沒有 lease 死結或 `reopen` 互拆的問題。cursor 指出的三個風險（重讀回 null、死結、取消拆掉另一個入口的 fence）都由本版處理：重讀丟錯或回不到結果即要求 `@username`；保留不經 coordinator 的 queue；第二個入口直接拒絕、釋放只以 token 為準。 |
| cursor I3 | §7.5：「401 為確定未執行」只指 **mutation 請求本身** 的 HTTP 回應，只適用只發一個請求的 REST 具名方法；mutation 得到 2xx 之後的 readback、分頁或新鮮度讀取的 401 仍為狀態未知；GraphQL 依 `mutationSent` 規則；沒有 HTTP status 的本機 `unauthenticated` 不適用。§15 第 5、25 列加對照案例。與 Codex M3、Opus m1 合併。 |
| cursor M1 | 見 Opus m9；讀取有下一頁、筆數不符或被截斷時整筆「無法讀取」，不用部分結果計算 HMAC（§3）。 |
| cursor M2 | 見 Opus m8。 |
| cursor M3 | §7.5：refresh 成功後不重放的那次失敗，kind 維持 `writeUncertain`，只補 `status: 401`，分類由 write port 做；畫面依 kind 的文案不變。 |

### 20.2 本輪的尚未驗證項目

- pipeline `inputs` 在重跑時是否不再帶入（Opus N6-I2 附註）。本版不依賴它：重跑的參數集只看 `source` 與 pipeline 變數，結果只影響日後是否放寬。
- 重跑手動 Job 是否沿用第一次播放時的變數（沿用 §19.2）。規則一律視為「無法讀取」。
- 背景中 `acquireContinuation` 的 MethodChannel 往返（§12.7，沿用）。

### 20.3 擁有者

本輪沒有需要擁有者決定的事項。Opus m5 的兩個選項中，同欄位還原已涵蓋 (B) 類 Markdown 欄位，不需要縮小 §0 第 1 點。

## 21. v6.7 變更紀錄

> **歷史紀錄，不是現行規範。** 本節裡重跑 Pipeline、重跑 Job、播放 Job 一律硬底線並輸入 ref 的說法，已由 §0 第 12 點與 §22.1 改為 T4。實作一律以 §0–§15 為準。

第 7 輪三份報告都沒有新的 Critical，並確認 §20 的拒絕理由成立。兩個 Important 主題（`AiRemovalHold` 的終止路徑、重跑與播放 Job 的 Job 層參數）都改用最簡單、明顯安全的規則。程式碼以 MR5 分支目前的頭核對；GitLab 平台事實以 master 原始碼與官方文件（2026-10-21 取得）核對。§20.2 中關於手動 Job 變數與 pipeline `inputs` 的兩項，已因本輪「重跑與播放 Job 一律硬底線」而不再影響任何規則。

### 21.1 逐項處理

| 來源 | 處理 |
|---|---|
| Codex N7-I1 | §8「帳號移除」新增第 0 步與第 5 步：保留屬於 `AiWriteJournal.instance` 登記的程序級移除作業，不屬於頁面；頁面卸載只提出取消要求；作業在開始與每個 await 返回後核對 token 與取消狀態，確定停止後才在 `finally` 以自己的 token 冪等釋放；最後確認之後作業跑到結束，不因卸載中止；任一清理失敗（含 `clearAiAccountData` 本身失敗）、`session.remove` 丟錯或因忙碌直接返回，都結束作業並釋放自己的保留，不碰 cleaning、tombstone、`reset_pending` 或日誌隔離；「重試移除」建立新作業、取得新保留。已核對兩個入口確認後依序 await 清理且中間沒有 token 檢查、`_clearAccount` 失敗會保留帳號並顯示「請重試移除」、`session.remove` 在 busy／initializing／resuming 時直接 return。§15 第 31 列。與 cursor I1、Opus M1 合併。 |
| Codex N7-M1 | §3.1：連結目標由 tokenizer 決定邊界；相對目標以已驗證的來源資源 web URL 解析，`//host` 視為帶主機，dot-segment 正規化後驗證 scheme、host、port、空 userInfo 與安裝子路徑；無法確認即一般遮蔽。§15 第 32 列。與 cursor M2、Opus M4(2) 合併。 |
| Codex N7-M2 | §15 第 5 列拆開斷言：PAT 或 refresh 回傳失敗沿用 `unauthenticated` 加 `status: 401`（`ApiFailure.fromStatus`，不改畫面錯誤種類）；refresh 成功不重放沿用 `writeUncertain` 補 `status: 401`；refresh 丟錯保留原 401。 |
| Codex N7-M3 | 採用：官方文件「Retry a manual job with updated variables」寫明前次的變數會預填（已核對）。本輪規則已把重跑與播放 Job 一律送硬底線，不依賴這項事實。 |
| Opus I1 | 採用更簡單也更嚴的規則（協調者建議）：重跑 Pipeline、重跑 Job、播放手動 Job 在任何等級（含 bypass）一律硬底線，輸入 ref（§3）。已核對 GitLab master：`Builder#user_defined_variables` 合併 pipeline、排程與 Job 變數；`Ci::Build.clone_accessors` 含 `job_variables_attributes` 與 `inputs_attributes`。不採用 Opus 提的「以 GraphQL 讀 `manualVariables` 與 `inputs`，或最多讀 5 個 Job」：Opus 自己指出 `CiJob.inputs` 每個請求只能解析一個 Job、需要額外權限，且欄位依版本存在與否不同，讀取無法有界又可靠。這也讓 v6.6 的 pipeline 變數讀取、`source` 讀取與 `manualJob` 讀取不再需要，已從 §3、§4.4、§15 第 13、30 列移除；排程播放的參數 HMAC 保留。 |
| Opus M1 | 見 Codex N7-I1。 |
| Opus M2 | §8：取得保留時**不**遞增 epoch（保留期間本來就擋住閘門、核准、`prepared` 與接受點）；只在停止框確認、或最後確認框確認／取消時，遞增新定義的「提議與核准 epoch」，它與重設日誌的「日誌 owner epoch」分開，不阻擋已過接受點的寫入寫入終態；停止框取消時 run 與既有核准繼續。§7.1 綁定這個 epoch。§15 第 31 列。與 cursor I1 的 epoch 部分合併。 |
| Opus M3 | §3.1：讀取 port 在 provenance 上逐值標記「正規化資源 key＋欄位名」，只有欄位的完整、未截斷值可得可還原編號；摘要、截斷值與 `restoreFromDisplay` 的文字一律一般遮蔽；截斷的欄位不提供整欄寫回。§15 第 32 列。 |
| Opus M4 | §3.1：允許位置改由 tokenizer 判定，新增帶標題的 Markdown 連結、`<img>`／`<a>`／`<video>`／`<audio>`／`<source>` 的 `src`／`href`、autolink；仍只能回到同一資源同一欄位，所以不增加外流。§15 第 32 列。 |
| Opus M5 | §3.1、§4.1：整欄寫回時，若欄位最近一次讀取含不可還原的遮蔽，任何等級（含 bypass）都改為確認並顯示將移除的段數，列入固定確認清單；app 只保存段數，不保存原文。§15 第 32 列。 |
| Opus M6 | §14：第 32 列 MR6b-1 以議題、MR 描述與留言證明；Release、里程碑、片段描述的還原移到 MR6b-2；Work Item 描述與活動留言移到 MR6b-3。 |
| Opus M7 | (1) §3：HMAC 輸入以長度前綴或排序 JSON 正規化，§15 第 30 列加邊界歧義案例。(2) §7.5：GraphQL 已知限制補上「PAT 在接受點與 mutation 之間被撤銷」。(3) §20.2 的兩項見本節開頭。 |
| cursor I1 | 見 Codex N7-I1 與 Opus M2。部分不採用「取得保留時遞增寫入 epoch」：依 Opus M2，保留本身已擋住所有新寫入，取得時遞增只會讓誤觸移除就作廢使用者的提議；改為在確認或取消最後確認框時遞增，並由 §7.1 綁定比較。 |
| cursor M1 | §3.1 新增「兩種佔位字串的適用範圍不同」：`[[attachment:…]]` 只進同一專案 (A) 類欄位；`[[upload:…]]` 只回同一資源同一欄位（含 Release 等 (B) 類 Markdown 欄位），「其他欄位一律 `policyBlocked`」不適用於同欄位還原。 |
| cursor M2 | 見 Codex N7-M1；檔名在第一個空白、`?`、`#`、引號、括號、`<`、`>` 或控制字元處結束。 |
| cursor M3 | §3：HMAC 金鑰在程序內只產生一次、放在 `AiWriteJournal.instance`，不寫入磁碟、日誌、稽核列或預覽；§7.1 綁定、§7.2 以同一把金鑰重算，金鑰不在即作廢。 |
| cursor M4 | 隨 Opus I1 消失：重跑一律硬底線，不再有「排程來源比對排程變數」的測試；§15 第 30 列改為斷言三種重跑情境都要輸入 ref。 |
| cursor M5 | §3 取消自動合併與 §15 第 30 列：確定未執行只指這次 POST 本身的 401；POST 回 201 之後 readback 的 401 為狀態未知。 |
| cursor M6 | §12.1 刪除「或才開始移除流程」，移除一律走 §8 的作業流程。 |

### 21.2 本輪的尚未驗證項目

- 背景中 `acquireContinuation` 的 MethodChannel 往返（§12.7，沿用）。
- Opus I1 附註「播放時以空陣列指派是否保留既有 Job 變數」：本輪規則已一律送硬底線，不依賴它。

### 21.3 擁有者

本輪沒有需要擁有者決定的事項。重跑與播放 Job 一律輸入 ref 比 §0 第 2 點要求的更嚴，沒有放寬任何決定。

## 22. v6.8 變更紀錄

第 8 輪三份報告都沒有新的 Critical。Codex 與 Opus 為 APPROVE WITH CHANGES，cursor 為 REQUEST CHANGES，有一個 Important（I1：清理失敗、釋放保留之後 tombstone 仍在，寫入閘門卻不看它，下次啟動可能刪掉失敗之後才產生的日誌明細）。三份都確認第 7 輪的 Important 已解決。本輪另併入擁有者 2026-10-21 的新決定（§0 第 12 點）。MR5 已合併到 main，程式碼與先前核對的相同；本輪重新核對 `session_controller.dart` 的 `remove`、`main.dart` 與 `authenticated_app.dart` 的 `MaterialApp`、`_removing`，以及 `work_item_page.dart` 以 `onRoute` 收掉自有 route 的做法；Flutter 行為以 3.47.2 SDK 原始碼核對。

### 22.1 擁有者決定：重跑與播放改為 T4（§0 第 12 點）

v6.7 把重跑 Pipeline、重跑 Job、播放手動 Job 一律送硬底線，§21.3 並寫「本輪沒有需要擁有者決定的事項」。**擁有者 2026-10-21 推翻了這條規則**：三項改為 T4，一般等級只需確認、不必輸入名稱，bypass 可自動執行，接受 GitLab 可能沿用已存的原變數。§21 保留原文作為紀錄，以 §0 第 12 點與本節為準；§21.1 的 Opus I1、cursor M4 與 Codex N7-M3 中「一律硬底線」的部分同樣被取代。帶**新**變數執行 Pipeline 仍是硬底線（§0 第 2 點），排程播放的參數規則不變。§20.2 的兩項平台事實（手動 Job 變數、pipeline `inputs`）仍不影響規則：app 不讀也不綁定這些參數。

| 位置 | 修改 |
|---|---|
| §3 能力表 | T4 列加入 `pipelineAction(retry)`、`jobAction(retry|play)`（不依 Job 目前狀態分流），並註明只需確認、bypass 可自動；硬底線列移除這三項。 |
| §3 規則 | 「至少 T4」一點改寫，三項依 §0 第 12 點為 T4；原「一律硬底線」一點改為「T4，一般等級只需確認」：保留 GitLab 會合併 pipeline、排程與 Job 層參數的原始碼依據；v2 不讀取、不綁定這些參數；卡片與稽核列寫明「重跑或播放會沿用 GitLab 上已存的原變數與 inputs（pipeline、排程與 Job 層），app 無法核對」，並列出 ref、ID、Job 名稱與 stage。 |
| §3 確認名稱 | 三項不需輸入名稱，只需確認。 |
| §4.1 | 表頭 T4 加註 ‡：三項是 T4「輸入名稱」的唯一例外。 |
| §4.2 | 開啟 bypass 的說明寫明三項會自動執行，且可能沿用原變數與 inputs。 |
| §4.4 | 所有 T4 上限都包含硬底線操作與這三項（同時處理 Opus M7(3)）。 |
| §10 | 同意框的「寫入」段落寫明：三項一般等級只需確認、bypass 自動執行，重跑或播放可能沿用 GitLab 上已存的原變數與 inputs，app 讀不到也無法核對。 |
| §14 MR6b-2 | 改為「至少 T4」與「重跑 Pipeline、重跑 Job、播放 Job 為 T4 且一般等級只需確認」。 |
| §15 第 8、30 列 | 改為斷言三項在一般等級顯示確認卡、不要求輸入名稱、卡片有沿用原變數的文案、確認前 POST 為 0；bypass 自動執行並計入 T4 預算；write port 不讀 pipeline variables、`source`、`manualJob`；帶新變數的 `createPipeline` 仍要輸入 ref。 |

§7.6 解除狀態未知的鎖仍以 Pipeline 或 Job ID 確認，不受影響。依 §0 第 12 點，T4 也包括部署與 `environment:action: stop` 的手動 Job；次數仍受 §4.4 的 T4 上限約束。

### 22.2 逐項處理

| 來源 | 處理 |
|---|---|
| cursor I1 | §8「帳號移除」新增第 6 步：移除 tombstone 是持久的拒絕條件，只要它還在，政策閘門、提議、核准、`prepared` 與 §7.3 第 4.4 步都拒絕新寫入，也不得在日誌建立或追加新明細（已存在明細的終態更新照常）；保留釋放不會解除它。`AiWriteJournal.instance` 在記憶體維護 tombstone 旗標供第 4.4 步同步檢查，§7.3 第 1 步與 `prepared` 另從 secure storage 確認（§7.3 第 1 步與第 4.4 步同步加入）。第 4 步：進入 `clearAiAccountData` 前先在日誌寫入帳號級「移除開始」標記；可讀的日誌寫不進就視同清理失敗，日誌未初始化或讀不到時不寫（那些狀態本來就拒絕新寫入，移除仍是 token 撤銷時的出口）。啟動處理 tombstone 前先讀日誌：有晚於標記（或沒有標記）的 `dispatching`／`writeUncertain` 明細時不刪日誌、保留 tombstone，要求重試移除；重試依第 3 步重讀日誌並再次輸入 `@username`。日誌刪除後晚到的終態不得重建日誌。已核對 `ai_history.dart` 的 `_recoverAccounts` 啟動時對每個 tombstone 直接清理、不要求名稱。§15 第 29、31 列。 |
| cursor M1 | §8 第 0 步：取消要求只在最後確認之前生效，含等待在途寫入與重讀日誌時的取消；最後確認之後忽略取消，只核對 token。第 4 步：最後確認框取消時，在同一段同步程式裡遞增 epoch 並釋放保留。§15 第 31 列。 |
| cursor M2 | 見 Codex N8-M1。 |
| cursor M3 | 失去前提：重跑與播放不再需要輸入名稱（§22.1）。`createPipeline` 與排程播放的 ref 原本就來自前置讀取。 |
| cursor M4 | 見 Opus M5。 |
| cursor M5 | 見 Opus M3。 |
| Codex N8-M1 | §7.3 第 4.4 步的同步重驗加入「提議綁定的提議與核准 epoch 仍等於帳號目前的值」；§7.2 續點重取清單加入同一個 epoch。§15 第 29 列加 barrier 案例：最後確認取消使 epoch 遞增後，flush 恢復的舊綁定不能送出，`notExecuted` 與退回預算、恢復待確認標記同一次原子更新。與 Opus M4、cursor M2 合併。 |
| Codex N8-M2 | §3.1 新增「標準形式」：沒有 scheme、沒有 host、正好是 `/uploads/<32 hex>/<檔名>` 的目標依 GitLab 語意（`UploadLinkFilter` 以安裝子路徑加 `-/project/<id>` 前綴渲染，已核對）視為來源資源所屬專案的上傳，與 `parseProjectUpload` 相同；其他相對目標才以來源資源 web URL 解析。§15 第 32 列改為：標準形式可原地往返；`../` 逃出、`//host`、不同安裝前綴與其他專案 id 只做一般遮蔽；零 mutation 只限非法佔位字串或仍含禁止內容。與 Opus M2 合併。 |
| Codex（§21 理由措辭） | 不改 §21（歷史紀錄）。該理由支持的「一律硬底線」已被 §0 第 12 點取代，見 §22.1。 |
| Opus M1 | 已核對 Flutter 3.47.2：`NavigatorState.dispose` 經 `_forcedDisposeAllRouteEntries` 只呼叫 `route.dispose()`，不呼叫 `didComplete`，所以 `showDialog` 的 future 不會完成；登入頁與已登入殼層各有自己的 `MaterialApp`。§8 第 0 步：每個確認框都與作業的取消信號一起等待，頁面 dispose 時完成該信號，Navigator 仍在時以 route 收掉對話框；作業持有 token 期間兩個入口都停用帳號切換、移除與 `endSession`，殼層的 `_removing` 改在取得保留時設定（目前在第一個確認框之後才設）。§15 第 31 列。 |
| Opus M2 | 見 Codex N8-M2。 |
| Opus M3 | 已核對 `SessionController.remove` 不會丟錯：忙碌時直接返回，儲存失敗時還原帳號清單並設訊息後正常返回。§8 第 5 步改為返回後以 `accounts` 判定，並寫出兩種「帳號未移除」的終態（`clearAiAccountData` 之前失敗；或它已完成但帳號留下，此時同意、紀錄與日誌已清除，等同 §7.6 重新加入帳號的殘餘）。§15 第 31 列。與 cursor M5 合併。 |
| Opus M4 | 見 Codex N8-M1。 |
| Opus M5 | §3.1：整欄寫回的段數改由 write port 在前置讀取時對目標欄位**目前的值**計算，不保存原文，不依賴對話是否讀過；沒讀過、只在別段對話讀過或程序重啟後同樣適用。§15 第 32 列。與 cursor M4 合併。 |
| Opus M6 | 失去前提：三項不再需要輸入名稱（§22.1）。卡片仍列出 Job 名稱與 stage，使用者在確認前可以看到是哪一個 Job。 |
| Opus M7 | (1) §14 改為「至少 T4」。(2) 確認名稱一行改為三項只需確認。(3) 見 §22.1 的 §4.4。(4) §3 寫明 `jobAction(play)` 不依 Job 目前狀態分流。(5) §15 第 30 列依新規則改寫，並斷言不讀 variables、`source`、`manualJob`。(6) §8 第 2 步補上：保留期間被擋下的寫入記為未執行，同一輪的 fail-stop（§7.5）照常適用。 |

### 22.3 本輪的尚未驗證項目

- 背景中 `acquireContinuation` 的 MethodChannel 往返（§12.7，沿用）。
- 各 GitLab 版本重跑時實際複製哪些 Job 參數（本輪以 master 原始碼為準）：依 §0 第 12 點，app 不讀也不綁定這些參數，風險已由擁有者接受，不影響規則。

### 22.4 擁有者

本輪沒有新的待決事項。§0 第 12 點已逐處落實，見 §22.1。

## 23. v6.9 變更紀錄

第 9 輪三份報告（Codex、Opus、cursor-agent）都是 APPROVE WITH CHANGES，沒有 Critical 或 Important，計畫通過審查。本版併入三份報告的 Minor（Codex 3 項、Opus 10 項、cursor 5 項，重複者合併），並依協調者要求把 §14 的 MR6a 列寫成可以直接開工的範圍。程式碼以 main（MR5 已合併）核對：`ai_history.dart` 的 `retryCleanup`、`_clearAccount`、`_recoverAccounts`，`ai_settings_page.dart` cleaning 狀態的「重試清除」，`workspace_api.dart` 的 `pipelineAction`／`jobAction`（送空的 `{}`，`gitlab_api.dart` 以 JSON content type 送出）。

### 23.1 逐項處理

| 來源 | 處理 |
|---|---|
| Codex N9-M1 | §8「帳號移除」第 5 步把「帳號未移除」分成三種：`clearAiAccountData` 之前的步驟失敗（AI 資料與日誌不因本次作業改變，沒有既有 fence 時可以重新提議）；`clearAiAccountData` 本身失敗（可能已部分刪除，不宣稱都還在；tombstone 持續擋寫入，不重建日誌）；清理完成但帳號留下。已核對 `_clearAccount` 逐步刪除，catch 只盡力重寫 tombstone。§15 第 31 列。 |
| Codex N9-M2 | §15 第 5 列：狀態未知的 `jobAction(play)` 擋住同一 Pipeline 的 retry 與相交 Job 寫入，反之亦然；三項免輸入名稱不適用於手動解除。第 30 列：一般等級確認後與 bypass 自動執行後，稽核列都含揭露。 |
| Codex N9-M3 | §15 第 31 列：分別在停止框與最後確認框顯示時釋放 Navigator，斷言停止框不改 epoch、最後確認框遞增 epoch。 |
| cursor M1 | §3.1 整欄寫回的觸發句改為對目標欄位目前的值計算段數，刪除「最近一次讀取」。與 Opus M8 合併。 |
| cursor M2 | §3 與 §15 第 30 列：Pipeline 重跑列出 ref 與 Pipeline ID；Job 重跑與播放另列 Job ID、Job 名稱與 stage。 |
| cursor M3 | §15 第 8 列：bypass 下未滿足 §2 目標綁定，或命中 §4.1 固定確認清單時，改為確認卡、不自動送出，仍不必輸入名稱。與 Opus M2 合併。 |
| cursor M4 | §21 標題下加「歷史紀錄，不是現行規範」；文件狀態列寫明 §16–§23 與正文衝突時以正文為準（也涵蓋 §19、§20 對舊重跑規則的描述）。與 Opus M10 合併。 |
| cursor M5 | §8 第 6 步：tombstone 的拒絕清單加入 §7.3 第 4.1、4.3 步，且不得把既有明細改寫成 `dispatching`；§7.3 第 4.3 步同步寫明；§15 第 31 列。 |
| Opus M1 | 已核對：`retryCleanup` 直接呼叫 `clearAccount`；`_recoverAccounts` 對 tombstone inventory 的每個帳號清理，不依帳號清單過濾。§8：日誌前置檢查移進 tombstone 流程本身，三個入口（移除作業、啟動恢復、「重試清除」）都經過；有新的狀態未知明細時，帳號仍在就改為「請從帳號列表重試移除」並在第 3 步要求 `@username`，帳號不在清單中依 orphan 規則刪除。§15 第 31 列。 |
| Opus M2 | §2 新增 Pipeline 與 Job 的綁定：經驗證的 URL、UI 加入、本段以 `createPipeline` 建立；Job 可經已綁定的 Pipeline 綁定，前置讀取須確認歸屬；工具結果裡的 ID 不算。§3 寫明 bypass 自動執行以目標綁定成立為前提，否則改為確認（仍不必輸入名稱），與 §4.1 表下「＊」對所有自動執行的條件相同；§0 第 12 點原文不動。§4.2、§15 第 8 列同步。 |
| Opus M3 | §3：三個工具的 schema 沒有變數或 inputs 參數，ledger 列的允許欄位為空，請求 body 為 `{}`（已核對現有方法）。§15 第 30 列加 body 內容與未知參數拒絕的斷言。 |
| Opus M4 | §3 卡片與稽核列、§4.2、§10 統一為「重跑或播放可能沿用 GitLab 上已存的原變數與 inputs（前次的 Pipeline 與 Job 變數），排程建立的 Pipeline 還會使用排程目前的變數；app 讀不到也無法核對」。 |
| Opus M5 | §8 第 6 步：`_clearAccount` 在 `setTombstone` 之前同步通知 `AiWriteJournal.instance` 設定旗標，寫入失敗也不清除，只有 `clearTombstone` 成功且正常返回後才清除；§7.3 第 1 步與 `prepared` 讀 tombstone 為 `unavailable` 或失敗時視同存在。已核對 `setTombstone` 只在 `_clearAccount` 內呼叫。§15 第 31 列。 |
| Opus M6 | §8 金鑰狀態新增「已由移除刪除」（`absent`、沒有日誌檔、有 tombstone）：拒絕寫入，移除第 3 步視為沒有隔離，第 4 步不寫標記、不建立日誌。日誌金鑰 `unavailable` 時，「移除開始」標記視同清理失敗、帳號保留、顯示「請稍後重試移除」。§15 第 31 列。 |
| Opus M7 | 日誌為每筆明細指派單調遞增的序號；「移除開始」標記記錄當下最大序號，前置檢查比較序號而不是時間，無法判定時視為「晚於」、不刪。§15 第 31 列。 |
| Opus M8 | 見 cursor M1。 |
| Opus M9 | §3.1：`projectUploadNamesOk` 與檔名結束規則改為三種形式（標準形式、其他相對目標、絕對 URL 與 `//host`）共同的條件。 |
| Opus M10 | 見 cursor M4。 |

### 23.2 MR6a 列（協調者要求）

§14 的 MR6a 列改寫為可以直接開工的範圍，分成「交付」「不含」與「必須證明」三部分：對話頁、各頁入口、`AiRunRegistry`、唯讀工具接線、插入為留言草稿、回報、三種格式的串流與停止、不自動連網的顯示、窄螢幕／大字／RTL；不含附檔 UI、任何寫入工具與背景服務。細節沿用 v5 §6.1–§6.3、§6.6、§6.7 與 v5 §2.4、§2.5，列中逐項標出出處。

已核對 repo：`AiRunner`、`AiRunnerBinding`、`gitlab_read_port.dart`、`AttachmentPicker`、`readLimitedAttachment`、`discardPickedCopy` 已存在；`AiRunRegistry`、`openNewComment`、`appendDraft`、`aiReportEmail` 尚未存在，由 MR6a 新增。

**附檔 UI 隨 `upload_attachment` 在 MR6b-1 交付：** 附檔按鈕、附件列、記憶體中的附件保存與相關測試都在 MR6b-1；MR6a 沒有附檔 UI。MR6a 沒有上傳工具，也不把附件資料送給模型，按鈕在 MR6a 不會有任何可見作用，所以不放進 MR6a（協調者更正了先前的指示）。§3.1、§10、§14 的 MR6a 與 MR6b-1 列、§15 第 23 列已依此寫明。

### 23.3 不採用

無。三份報告的 Minor 經核對都成立，全部採用。

### 23.4 本輪的尚未驗證項目

- 背景中 `acquireContinuation` 的 MethodChannel 往返（§12.7，沿用）。
- Opus M3 引用的「播放端點接受 `job_variables_attributes`」：沿用前輪引文，本輪未重抓 GitLab 原始碼；規則改為 body 固定為 `{}`、schema 沒有這類參數，不依賴這項事實。

### 23.5 擁有者

本輪沒有新的待決事項。

## 24. v6.10 變更紀錄（2026-10-23，擁有者授權全自動決定）

- §7.5：合併、核准、取消核准、rebase、取消自動合併這幾個 mutation 回 405、406、409、422 時，記為「確定未執行」，不再記為狀態未知。依據是 GitLab 官方文件：合併端點的 405 表示「無法合併」，409 表示 SHA 與來源分支 HEAD 不符，422 表示「Branch cannot be merged」。406 是舊版 GitLab 對衝突的回應。
- 取消自動合併的 409「Can't cancel the automatic merge」（MR 本來就沒設自動合併）記為 `noChange`。
- §3：片段的確認名稱改用 `#id`，因為標題可能重複。
- §3：合併在 dispatch 前，若 MR 的 `sha` 與 `diff_refs` 三個值都沒變，diffs 與 commits 不重新分頁（內容由這幾個 SHA 決定）。`closes_issues`、`ci_config_path` 與目標分支的保護狀態照樣重讀。
- §15 第 13 列：唯讀白名單只加入 `snippetText` 一項，供 `get_snippet` 使用，並以守衛測試鎖定。
- 其餘未解問題依 `mr6b2-decisions.md` 處理。
