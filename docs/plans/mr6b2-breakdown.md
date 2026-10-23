基準是 worktree `the repository`，分支 `feat/ai-mr6b1-rb`。下面的檔名、函式與行號都以 HEAD `13b504f` 加上已暫存、尚未提交的 MR6b-1 變更（127 個檔案）為準。MR6b-2 要等 MR6b-1 提交並合併之後才開分支；合併後行號若有移動，以函式名稱為準。計畫正文是 §0–§15，§16–§23 只是變更紀錄。

# MR6b-2 實作封包

MR6b-2 交付下列內容：

- T3、T4 與硬底線的 REST 工具，以及所需的新包裝；
- 把畫面改接到具名方法，包括 `MetadataPage` 的分支、tag 與 Release；
- `edit_file`，以及片段的全部寫入；
- 合併與核准的 sha 規則，以及合併前的既有變更檢查；
- Pipeline 與 Job 的操作（重跑與播放只需確認）；
- 排程參數的 HMAC；
- `cancelAutoMerge` 的結果分類；
- 參數升級；
- `aiToolCatalogueVersion` 由 2 改為 3。

GraphQL 寫入、`beforeMutation`／`mayStart` 掛鉤、前景服務與通知都不在這一批。

共十八個封包交給程式代理人。卡片、預覽、警示與文案由主導者做，見「主導者要設計的畫面」。

## 共同約定

- **l10n 只有一個寫入者：主導者的 UI 提交。** MR6b-2 沒有新的 T1 operation，所以不必加意圖詞。封包不得改 `lib/l10n/arb/*.arb` 與 `lib/l10n/strings*.g.dart`。`tool/tests/test_l10n.py` 會擋下 `lib/l10n/` 以外的中文。
- **封包只回傳 reason code**（英文 camelCase），不寫使用者文案。每個封包把自己新增的 code 列在 PR 說明，由主導者一次翻譯。卡片要顯示的結構化資料放在 `AiWritePreview`（封包 1），不放句子。
- **寫入 port 只呼叫具名方法。**
  - port 的任何檔案都不得出現 `writeRecord`、`removeRecord`、`writeEmpty`、`graphMutation`、`_send`。
  - path 一律固定。模型給的字串只能當作已驗證的 path segment（分支名、檔案路徑、tag 名），由 `GitLabInstance.api` 的 `pathSegments` 編碼。
  - 前置讀取只能用白名單裡的成員：`currentUser`、`record`、`records`、`fileMetadata`、`textFile`、`snippetText`、`projectSnippetSnapshot`、`snippetBlob`、`effectiveProjectAccess`。
- **port 改成「一個 library 加 part 檔」（封包 1）。**
  - part 檔一律用 `_api` 當接收者，不得把 `_api` 當參數傳出，也不得宣告 `GitLabApi` 型別的變數或參數。
  - part 檔的任何地方（含註解與 doc）都不得出現 `gitlab_api.dart` 字樣。importer 測試是對整個檔案做子字串比對。
  - 守衛（`tool/tests/test_ai_boundaries.py`）把成員白名單套到每一個 part 檔。
- **一個具名方法對應一列 ledger。** `write_call_site_ledger_test.dart` 用 `{row.namedMethod: row.operationId}` 分類呼叫點，所以畫面呼叫的每個包裝都要有自己的列。不要用一個 operation 加參數去分流兩個方法。
- **確認名稱（`confirmName`）與解除名稱（`releaseName`）分開**，兩者都只能來自前置讀取（§3「確認名稱來源」「解除狀態未知的鎖」）。MR6b-1 把兩者混成一個 `releaseName`：`write_coordinator.dart` 的 `_tier` 把 `releaseName` 傳給 `typedName`。MR6b-2 的列不能沿用這種做法。
- **新列在封包 17 之前一律 `modelVisible: false`。** 家族封包做協調器層測試時，用注入的 ledger（`PolicyAiWriteCoordinator(ledger:)` 已支援）把自己的列設成可見。
- **合併檢查摘要可以進日誌（§8）。排程 HMAC 與參數值只能存在記憶體中的 `AiWritePrepared.bindingDigest`**，不進日誌、預覽、稽核列、工具結果與 provider request（§3）。HMAC 金鑰由協調器從 `journal.scheduleHmacKey` 讀出，經 `AiWriteRequest.scheduleHmacKey` 交給 port。port 不直接碰 `AiWriteJournal.instance`，這樣測試才能注入日誌。
- **HTTP 上限寫在 ledger 列（`AiCapability.httpCap`）。**
  - 算法沿用 MR6b-1：提議與 dispatch 兩次前置讀取，加上 mutation 與 readback；每個邏輯 GET 保留 2 次，給 OAuth 重放用。
  - 每個家族封包都用 FakeAdapter 斷言：最壞情況的實際請求數 ≤ `httpCap`。
  - 分頁一律設頁數上限。超過上限就算「不完整」，不產生提議。
- **共用檔在每個波次只有一個擁有者：**

| 檔案 | 波次 A | 波次 B | 波次 C |
|---|---|---|---|
| `lib/core/ai/tools/gitlab_write_port.dart`（主檔） | 封包 1 | 無 | 無 |
| `lib/core/ai/tools/write_ledger.dart`、`write_tier.dart`、`target_binding.dart` | 封包 1 | 無 | 無 |
| `lib/core/ai/tools/ledger/rows_*.dart` | 封包 1 建立 | 各家族封包只改自己的檔 | 封包 17（只改 `modelVisible`） |
| `lib/core/ai/tools/write_coordinator.dart` | 封包 2 | 無 | 無 |
| `lib/features/ai/ai_chat_controller.dart` | 封包 2 | 無 | 封包 17 |
| `lib/core/workspace_api.dart` | 封包 3 | 無 | 封包 17（只刪 `saveFile`） |
| `tool/tests/test_ai_boundaries.py` | 封包 1 | 無 | 無 |
| `test/ai/write_call_site_ledger_test.dart` | 封包 3 | 無 | 封包 17 |
| `test/ai/write_tier_test.dart` | 封包 1 | 無 | 封包 17 |
| `lib/features/ai/ai_write_journal.dart` | 封包 5（只加 HMAC 金鑰） | 無 | 無 |

---

## 波次 A

### 封包 1 — 能力表資料化、port 拆檔、守衛與目錄版本

這個封包做三件事：

- 把 MR6b-1 分散在 port 與協調器裡的參數表搬到 ledger 列；
- 把 port 拆成主檔加家族 part 檔，讓波次 B 的七個家族可以並行；
- 實作 §3 的 ledger 欄位、§9 的版本，並延伸 §15 第 13 列的守衛。

完成後 MR6b-1 的行為不變。

**擁有的檔案**

- 改 `lib/core/ai/tools/write_ledger.dart`：
  - `AiCapability` 加欄位（見下）；
  - `ProductionAiLedger.rows` 改成 `[...aiT12Rows, ...aiFileRows, ...]` 的 const 展開；
  - `AiScopeClass` 加 `accountGlobalOnly`（給 `markAllTodosDone`）與 `personalNamespace`（給 `createProject`、`forkProject`），`_grantOffers` 的規則依未解問題 11、12。
- 改 `lib/core/ai/tools/target_binding.dart`：`_grantAdmits`（第 220–258 行）是窮舉的 switch，`scopeAdmits` 也比對 `AiScopeClass`。加了新值之後，這兩處都要補上。
- 新 `lib/core/ai/tools/ledger/rows_t12.dart`：把 MR6b-1 的 31 列原樣搬進來。參數表由 `write_coordinator.dart` 的 `_allowedArguments` 與 port 的 `_arguments`／`_fieldKeys` 合併而成。
- 新建空的 `rows_files.dart`、`rows_refs.dart`、`rows_merge.dart`、`rows_ci.dart`、`rows_snippets.dart`、`rows_deletes.dart`、`rows_project.dart`。
- 改 `lib/core/ai/tools/gitlab_write_port.dart`：
  - 擴充 `AiWritePrepared` 與 `AiWriteRequest`；
  - `prepare` 先依序問各 part 檔（`_prepareFiles` … `_prepareProject`，stub 都回 `null`），之後才進 MR6b-1 的 `switch`；
  - `_settle` 接受選填的 `AiResultClassifier`；
  - `_arguments`／`_fieldKeys` 改讀 ledger。
- 新建 part stub：`gitlab_write_port_files.dart`、`gitlab_write_port_refs.dart`、`gitlab_write_port_merge.dart`、`gitlab_write_port_ci.dart`、`gitlab_write_port_snippets.dart`、`gitlab_write_port_deletes.dart`、`gitlab_write_port_project.dart`。每個檔的內容是 `part of 'gitlab_write_port.dart'`，加一個 `extension _XxxPrepare on GitLabAiWritePort`。
- 新 `lib/core/ai/tools/write_preview.dart`：純資料，第一個提交，封包 4、5 以它為準。
- 改 `lib/core/ai/tools/write_tier.dart`：`_protectedBranchOperations` 改為 `edit_file`、`createFile`、`applySuggestion`、`batchApplySuggestions`、`mergeRequest`，拿掉現在的 `saveFile`。
- 改 `lib/core/ai/tools/tool_catalogue_version.dart`：`2` 改為 `3`，維持零 import。
- 改 `tool/tests/test_ai_boundaries.py`：
  - 版本 regex 改為 `3`；
  - `test_row13_write_port_calls_only_whitelisted_members` 改成掃主檔與全部 `part of 'gitlab_write_port.dart'` 檔；
  - 新增四條斷言：part 檔沒有 `GitLabApi` 型別宣告；`_api` 不當參數；port 檔沒有通用通道名稱；part 檔不含 `gitlab_api.dart` 字樣；
  - 白名單一次列出本文件定下的全部成員，之後波次 B 不再改這個檔。
- 改 `test/ai/write_tier_test.dart` 約第 737–748 行：原本斷言「`find('edit_file')` 是 null」與「可見列都是 T1／T2」，改成「MR6b-1 的 31 列仍可見，其餘列的 `modelVisible` 是 false」。
- 改 `test/ai/ai_write_consent_test.dart` 第 240 行：`expect(aiToolCatalogueVersion, 2)` 改成 3。另外檢查 `test/ai/fix2_logic_test.dart` 第 118 行，那裡指定 `toolCatalogueVersion: 2` 的預期是否要跟著改。

**不要碰**

`write_coordinator.dart`、`ai_chat_controller.dart`、`workspace_api.dart`、`gitlab_api.dart`、畫面、ARB、日誌。

**公開 API**

```dart
enum AiArgType { integer, string, boolean, object, integerList, edits, variables, suggestionList, snippetActions }
enum AiTextRole { none, quickActionMarkdown, plainContent, renderedMarkdown, commitMessage, fragmentEdits, fullNewContent, pathOrRef }

final class AiArgSpec {
  const AiArgSpec(this.type, {this.required = false, this.text = AiTextRole.none, this.writableField});
  final AiArgType type;
  final bool required;
  final AiTextRole text;
  final String? writableField; // AiWritableField.*，給 §3.1 同欄位還原
}

final class AiCapability {
  // 既有：operationId、baseTier、scopeClass、modelVisible、namedMethod
  final Map<String, AiArgSpec> arguments; // 不含 reason；未列出的鍵一律拒絕
  final int httpCap;                      // 預設 39
  final bool readback;
  final String? editableField;            // 卡片可改的單一文字欄；null 表示不可改
}

final class AiWriteRequest {
  // 既有欄位之外
  final Set<AiCreatedRef> segmentCreated; // 協調器提供，§2 第 4 類
  final List<int>? scheduleHmacKey;       // 協調器提供；不進 payload digest
}

final class AiWritePrepared {
  // 既有：request、releaseName、writeKeys、dependencyKeys
  final String? confirmName;
  final AiTierFacts facts;
  final List<AiTargetRef> bindingTargets;
  final String bindingDigest;          // 只在記憶體；dispatch 前比對
  final AiJournalBindings journal;     // headSha、lastCommitId、updatedAt、mergeCheckSummary
  final AiWritePreview preview;
  final AiTextScan? textScan;
  final AiCreatedRef? createdOnSuccess;
  final AiResultClassifier? classify;
}
```

`write_preview.dart` 定義以下型別：

- `sealed class AiWritePreview`，子型別：
  - `AiFieldsPreview`：MR6b-1 的預設；
  - `AiDiffPreview`：path、ref、`List<AiDiffLine>`、`newFile`、`preexistingSecretHits`、`ciPath`；
  - `AiMergePreview`：來源與目標分支、短 sha、squash、removeSourceBranch、autoMerge、路徑數、`ciPaths`、將關閉的議題與它們是否在範圍外、`headMovedCommits`；
  - `AiPipelinePreview`：ref、Pipeline ID、Job 的 ID／名稱／stage、讀得到時的 environment、`scheduleVariableNames`、`scheduleParamsUnreadable`、`newVariableNames`；
  - `AiDraftPublishPreview`、`AiDeletePreview`、`AiCancelAutoMergePreview`。
- 其他：`AiDiffLine`、`AiTextScan`（`newTexts`、每個變動區塊的前後文窗、`original`、`markdown`、`serverClassA`）、`AiCreatedRef`、`AiJournalBindings`。

**依賴：** 無。最先開工；`write_preview.dart` 是第一個提交。

**測試**

- §15 第 13 列：part 檔也受成員白名單約束。比照現有的 tear-off 測試，在字串層級驗證四種逃逸都會被擋：alias、把 `_api` 當參數、通用通道、`gitlab_api.dart` 字樣。
- 第 21 列的一部分：每個 ledger 列的 `namedMethod` 都在白名單裡。
- MR6b-1 的 `test/ai/` 全部維持綠燈；`ai_write_port_test.dart` 裡 31 列的行為不變。

**UI／邏輯：** 純邏輯。主導者畫卡片時，`AiWritePreview` 是唯一的資料來源。

---

### 封包 2 — 協調器接縫

讓 `PolicyAiWriteCoordinator` 使用封包 1 新增的欄位。實作範圍：§2 複合目標與第 4 類綁定的接線、§3 確認名稱、§5 對 (B) 欄位與精確片段的處理、§7.1 綁定、§7.2 dispatch 前重驗。

**擁有的檔案**

- 改 `lib/core/ai/tools/write_coordinator.dart`
- 改 `lib/features/ai/ai_chat_controller.dart` 的 `_freshWrite`（第 1042 行起）、`_writeSnapshot`、`_createRunner`
- 新 `test/ai/mr6b2_coordinator_seam_test.dart`

**不要碰**

port 與它的 part 檔、ledger、`write_tier.dart`、`target_binding.dart`、`ai_write_journal.dart`、畫面、ARB，以及 `aiMr6b1WritePolicy`（封包 17 的範圍）。

**要改的地方**

- **參數表改讀 ledger。** `_allowedArguments`、`_schema`、`_requestAllowance`、`_readbackOperations`、`_hiddenFields` 都改讀 `AiCapability`。
  - `_schema` 的 required 改由 `AiArgSpec.required` 決定。現在寫死為 `todoId` 或 `projectId`，`markAllTodosDone` 與 `createProject` 會出錯。
  - 巢狀型別（`edits`、`variables`、`suggestionList`、`snippetActions`）要給完整的 JSON schema，並設 `additionalProperties: false`。
- **`_target()`。** 它的 switch 是窮舉的（第 1355–1365 行），要接上封包 1 新增的 `AiScopeClass` 值。
- **`_tier`。**
  - `typedName` 改用 `prepared.confirmName`；
  - `facts` 由 `fresh.facts` 與 `prepared.facts` 合併，布林取 or，reasons 取聯集；
  - `bindTargets` 改用 `prepared.bindingTargets`，空的時候才退回 `_target()`。
- **`_dispatch`。**
  - 除了現有的 `updatedAt`、`headSha`、`lastCommitId`，再比對 `bindingDigest`；不同就回 `targetChanged`；
  - `AiJournalDraft` 的 `headSha`、`lastCommitId`、`updatedAt`、`mergeCheckSummary` 改取 `prepared.journal`。
- **`_prepareText` 改由 `AiArgSpec.text` 決定文字類別。**
  - `renderedMarkdown`（Release 說明、片段描述）與 `commitMessage` 屬 (B)，`commitMessage` 另做 §5 第 9 點；
  - `pathOrRef` 只掃秘密與遮蔽標記；
  - `fullNewContent` 全文掃描；
  - `fragmentEdits` 交給封包 4 的 `checkFragments`；
  - `textScan.serverClassA`（整批送出時伺服器上的草稿）只判定、不改寫；需要中和的就 `policyBlocked`。
  - 要修的錯：現在的判斷式是「`field == 'body'`，或欄位是 description 且不是 Label／Milestone」，會把 Release 說明當成 (A) 中和。
- **`_edit`** 改用 `editableField`；值為 `null` 時回 `noEditableText`。
- **`AiWriteProposal`** 加 `preview` 欄位（型別 `AiWritePreview`）。
- **本段對話建立的資源。** 每個協調器持有本段對話的 `Set<AiCreatedRef>`。寫入成功時記下 `createdOnSuccess`；每個 `AiWriteRequest` 都帶它的快照，並帶上 `journal.scheduleHmacKey`。
- **`AiWritePolicySnapshot`** 加 `currentJobId`。從 `AiJobOrigin` 開啟的對話，那個 Job 的綁定來源是 `currentResource`。
- **`_freshWrite`。** ledger 列不在 `rows_t12.dart` 的 operation，不再綁專案 JSON 的 `updated_at`：專案任何變動都會改它，造成假的 `targetChanged`。改由 `bindingDigest` 負責。可見度與污染判定照舊。

**依賴：** 封包 1 的型別（兩者同時開發，合併排在封包 1 之後）、封包 4 的 `checkFragments` 簽章。

**測試**

- §15 第 7 列：等待確認期間 `bindingDigest` 改變，提議即作廢；`confirmName` 不符回 `typedNameMismatch`；`confirmName` 與 `releaseName` 不同時，以 `confirmName` 為準。
- 第 19 列：`httpCap` 來自 ledger；保留不到額度就不產生提議；涵蓋 39、40、41 三個邊界。
- 第 14 列：Release 說明不經 quick action 中和，行首的 `/` 保留。
- 第 18、29 列：用 T3 假列重跑，結果與 MR6b-1 相同。

**UI／邏輯：** 邏輯。主導者讀 `AiWriteProposal.preview` 與 `tier`。

---

### 封包 3 — 具名包裝與畫面共用的判斷

在 `lib/core` 補齊 §3 列出的新包裝，收緊既有方法的欄位，並把畫面裡的判斷搬到 core。實作 §3「新增包裝」與 §6「缺 `last_commit_id` 時不得退回 POST」。

**擁有的檔案**

- 改 `lib/core/workspace_api.dart`
- 新 `lib/core/merge_request_state.dart`：`isAutoMergeEnabled` 與 `canAutoMerge` 由 `work_item_page.dart` 第 2260 行起搬過來。只用 Map 存取，不 import `lib/shared/workspace_ui.dart`。
- 改 `test/ai/write_call_site_ledger_test.dart`（規則見下）
- 新 `test/ai/mr6b2_wrappers_test.dart`

**不要碰**

畫面檔（舊的兩個函式由封包 13 刪除）、port、ledger、協調器、ARB。

**新包裝**

全部放在 `WorkspaceApi` extension 內，method 與 path 都固定。

- **檔案：** `createRepositoryFile(project, path, {branch, content, message})` 只送 POST；`updateRepositoryFile(project, path, {branch, content, message, required lastCommit})` 只送 PUT。`saveFile` 暫時改成轉呼叫這兩個，由封包 17 刪除。
- **審查與留言：** `deleteDiscussionNote(project, resource, iid, discussion, note)`、`deleteDraftNote(project, iid, note)`、`publishDraftNotes(project, iid)`。最後一個送 `POST …/draft_notes/bulk_publish`，接受 204。
- **中繼資料：** `deleteLabel`、`deleteMilestone`、`deleteBoard`、`deleteBoardList(project, board, list)`。
- **片段：**
  - `createSnippet(project, {title, description, visibility, files})`；
  - `updateSnippet(project, snippet, …)`：單檔舊格式，沿用 `updateSingleFileSnippetPayload`；
  - `updateSnippetMetadata(project, snippet, {title, description, visibility, currentPaths})`；
  - `updateSnippetFiles(project, snippet, {…, currentPaths, actions})`：只接受 create、update、move；
  - `deleteSnippetFile(project, snippet, {…, currentPaths, path})`；
  - `deleteSnippet(project, snippet)`。

  payload 一律經 `lib/core/snippet_models.dart` 的既有建構函式產生。
- **Registry：** `deletePackage(project, package)`、`deletePackageFile(project, package, file)`、`deleteContainerRepository(project, repository)`、`deleteContainerTag(project, repository, tag)`。
- **讀取：** `effectiveProjectAccess(project, userId)`，由 `registries_page.dart` 第 33 行的 `_effectiveAccess` 搬來。它必須是 extension 成員，不能是接受 `GitLabApi` 參數的頂層函式，否則守衛看不到它。

**收緊既有方法**

- `deleteNote`（第 220 行）的 `resource` 改走 `_issueOrMergeRequest`。
- `createRelease` 只接受 `tag_name`（必填）、`name`、`description`；`updateRelease` 只接受 `name`、`description`。
- `createPipeline` 的每個變數只接受 `key`、`value` 與 `variable_type`，後者只能是 `env_var` 或 `file`。
- `pipelineAction` 與 `jobAction` 維持送 `{}`。

**`write_call_site_ledger_test.dart` 的過渡規則**

- 新包裝的名稱加進 `_pendingImplementations` 與 `_pendingMr6b2Methods`。
- `_screenGenericCounts` 改成：每個檔的數量不得超過 MR6b-1 的值，也不得出現新檔。
- `_requiredPendingMr6b2` 暫時拿掉，因為畫面改接之後那些標籤會消失。

這樣波次 B 的畫面封包就不必改這個檔。封包 17 會換回精確斷言。

**依賴：** 無。

**測試**

- §15 第 21 列：每個新包裝的 method、path 與欄位白名單都固定，各有一條負向測試。
- 第 9 列的一部分：沒有 `lastCommit` 就送不出 PUT，也不會改送 POST。
- 第 10 列：Release 的欄位白名單；`deleteNote` 的 resource 只接受列舉值；`createProject` 固定 private 與 `initialize_with_readme`。

**UI／邏輯：** 純邏輯。

---

### 封包 4 — 精確片段引擎與 diff

`edit_file` 與片段內容共用這個引擎。實作：

- §6 的片段規則；
- §5 第 4、5 點對精確片段的掃描範圍；
- §5 第 2、3 點對 Markdown 變動區塊的判定；
- 預覽用的 diff。

**擁有的檔案**

- 新 `lib/core/ai/exact_edit.dart`
- 新 `test/ai/exact_edit_test.dart`

**不要碰**

`write_text.dart`（只呼叫 `prepareWriteText`）、`redaction.dart`（只建構 `Redactor`）、port、協調器。

**公開 API**

```dart
final class AiExactEdit { const AiExactEdit(this.oldText, this.newText); final String oldText; final String newText; }

sealed class AiExactEditResult {}
final class AiExactEditApplied extends AiExactEditResult {
  final String finalText;
  final List<AiDiffLine> diff; // 前後各 3 行
  final AiTextScan scan;
}
final class AiExactEditRejected extends AiExactEditResult {
  final String reasonCode; // fragmentNotFound | fragmentNotUnique | fragmentsOverlap | noEdits | tooManyEdits | noChange
  final int? editIndex;
}

AiExactEditResult applyExactEdits(String original, List<AiExactEdit> edits, {int maxEdits = 20});
List<AiDiffLine> unifiedDiff(String before, String after, {int context = 3});

final class AiFragmentCheck {
  final String? blockCode;               // redactionMarker | secret | null
  final List<AiFixedConfirmReason> confirmReasons;
  final int preexistingSecretHits;
}
AiFragmentCheck checkFragments(AiTextScan scan, {required Set<String> knownSecrets, required GitLabInstance instance, required AiVisibilityContext visibility});
bool isRenderedMarkdownPath(String path); // .md、.markdown
```

**規則**

- 每段 `old` 必須在原文中恰好出現一次，各段的範圍不得重疊，全部以原文的位置套用。
- 秘密與遮蔽標記用兩種檢查判定：
  - 每段 `new` 單獨掃描，擋下新加入的；
  - 比較每個變動窗在套用後與原文同一窗的命中數，命中數變多就擋，用來擋跨邊界拼出的。

  原文未變動處既有的命中不擋，只計入 `preexistingSecretHits`。
- Markdown 檔的提及與外部媒體只看變動窗，由 `prepareWriteText(textClass: plainContent, secretFragments: const [])` 取得確認理由。

**依賴：** 封包 1 的 `write_preview.dart`（`AiDiffLine`、`AiTextScan`）。

**測試**

- §15 第 9 列：
  - 片段含遮蔽標記時被擋；
  - 原檔已有 `[REDACTED…]` 時，附近的編輯照常進行；新片段帶進這種標記，或跨邊界拼出時被擋；
  - 片段範圍重疊被拒；
  - 原檔未變動處的假 token 只標示，不擋；
  - 新加入的已知秘密被拒。
- 第 14 列：
  - 片段的多行字串、以 `@` 開頭的原始碼與行首的 `/` 逐位元組保留；
  - Java 與 Python 的 `@param` 與 decorator 不算提及；
  - `.md` 變動區塊裡的大量提及要確認。

**UI／邏輯：** 純邏輯。主導者用 `AiDiffLine` 畫 diff。

---

### 封包 5 — CI 判定、合併前檢查模型、排程 HMAC、Pipeline 變數

四組純函式，給封包 6、8、9、10 用。實作：

- §3「CI 設定檔判定」；
- §3「合併前的既有變更檢查」的判定部分；
- §3「排程播放的參數」；
- 硬底線列的變數規則。

**擁有的檔案**

- 新 `lib/core/ai/tools/ci_rules.dart`
- 新 `lib/core/ai/tools/schedule_params.dart`
- 改 `lib/features/ai/ai_write_journal.dart`：只加 `List<int> get scheduleHmacKey`。本程序第一次讀取時用 `Random.secure()` 產生 32 byte，不寫入磁碟。只有協調器會讀它，port 不碰。
- 新 `test/ai/ci_rules_test.dart`、`test/ai/schedule_params_test.dart`

**不要碰**

日誌的其他部分、port、協調器、`write_text.dart`。

**公開 API**

```dart
sealed class AiCiConfig { factory AiCiConfig.fromProject(Object? ciConfigPath); } // local(path) | external | unreadable
bool isCiConfigPath(String path, AiCiConfig config);
// .gitlab-ci.yml、.gitlab/**、根目錄與 docs/ 的 CODEOWNERS、本地 ci_config_path；unreadable 時一律 true

final class AiMergeChanges { final List<AiChangedPath> paths; final bool complete; final String digest; }
AiMergeChanges collectMergeChanges(List<List<Map<String, dynamic>>> diffPages, {required Object? changesCount, required bool hasMorePages});

final class AiMergeCheck {
  final List<String> ciPaths;          // 含改名的舊路徑與刪除
  final bool closesOutOfScope;
  final bool crossProjectReference;
  final bool closingUnknown;            // 不完整：不得自動執行
  final String digest;                  // 進 bindingDigest
  final String journalSummary;          // 只有筆數與 digest，可進日誌
}
AiMergeCheck evaluateMergeCheck({required AiMergeChanges changes, required AiCiConfig ci, required List<Map<String, dynamic>>? closesIssues, required String description, required List<String> commitMessages, required AiWriteScope scope, required GitLabInstance instance});

enum AiScheduleParamsState { explicitEmpty, nonEmpty, unreadable }
final class AiScheduleParams { final AiScheduleParamsState state; final String ref; final List<String> variableNames; final List<String> inputNames; final Uint8List? hmac; }
AiScheduleParams evaluateScheduleParams(Map<String, dynamic> schedule, {required List<int> key});

sealed class AiPipelineVariables {} // accepted(list) | rejected(reasonCode)
AiPipelineVariables validatePipelineVariables(Object? raw, {required Set<String> knownSecrets});
```

**規則**

- 範圍外的議題與跨專案參照，沿用 `prepareWriteText(textClass: plainContent)` 回傳的 `closingOrCrossProject` 判定，不另寫一套。
- HMAC 是 HMAC-SHA-256。輸入是鍵已排序、保留型別的 JSON：變數含 API 回傳的型別欄位，inputs 保留 JSON 型別，最後再加上 `ref`。
- 「明確為空」只限 `variables == []`，且 `inputs` 為 `[]` 或 `{}`。欄位缺席、null 或型別異常，一律算 `unreadable`。
- 變數名稱拒絕 `CI_*`、`GITLAB_*`、`*_DEBUG_*`；變數值要經秘密掃描。

**依賴：** 無。

**測試**

- §15 第 26 列的判定部分：改名的 CI 舊路徑、刪除、自訂 `ci_config_path`、`changes_count` 帶 `+` 或筆數不符、還有下一頁（算不完整）、`closes_issues` 指向範圍外、描述與 commit message 裡的跨專案參照。
- 第 30 列的排程部分：
  - 六種狀態各一案：`variables` 非空、只有 `inputs`、兩欄明確為空、因權限缺席、`inputs` 欄位不存在、被截斷；
  - 只改值、只改 input 的 JSON 型別、只改可讀性，都會改變 HMAC；
  - `A`＝`B=C` 與 `A=B`＝`C` 的 HMAC 不同。
- 第 8 列：變數拒絕規則。

**UI／邏輯：** 純邏輯。

---

## 波次 B

家族封包（6–12）各自只改一個 part 檔、一個 `rows_*.dart` 與自己的測試檔。

下面各表的欄位：

- 「確認名稱」是需要輸入名稱時的 `confirmName`；
- 「解除名稱」是 `releaseName`；
- key 都以 `(account, project:<id>, …)` 開頭，表中省略前兩段。

`AiConflictKey.intersects` 是前綴比對（`ai_write_journal.dart` 第 52 行），所以父 key 會擋住它底下所有的子 key。

### 封包 6 — 檔案與套用建議

**擁有的檔案：** `gitlab_write_port_files.dart`、`ledger/rows_files.dart`、`test/ai/mr6b2_files_port_test.dart`

| operation | 具名方法 | 基礎 | 升級 | 確認名稱 | 解除名稱 | 寫入 key／依賴 key |
|---|---|---|---|---|---|---|
| `edit_file` | `updateRepositoryFile` | T3 | 預設或受保護分支 → T4；CI → 硬底線 | T4：分支名；硬底線：完整路徑 | 完整路徑 | `ref, <branch>, <path>`／`ref, <branch>` |
| `createFile` | `createRepositoryFile` | T3 | 同上 | 同上 | 完整路徑 | 同上 |
| `deleteFile` | `deleteFile` | T4 | CI → 硬底線 | 完整路徑 | 完整路徑 | 同上 |
| `applySuggestion` | `applySuggestion` | T3 | 來源分支是預設或受保護 → T4；建議所在路徑是 CI → 硬底線 | T4：來源分支名；硬底線：路徑 | `!iid` | 每個路徑 `ref, <source>, <path>`／`mergeRequest, <iid>` |
| `batchApplySuggestions` | `batchApplySuggestions` | T3 | 同上，取最高 | 同上 | `!iid` | 同上 |

**前置讀取**

- 共同：`currentUser`；專案 JSON（`default_branch` 與原始的 `ci_config_path`）；`repository/branches/<branch>` 的 `protected` 與 `default`。
- `edit_file` 與 `deleteFile`：先用 `fileMetadata(project, path, branch)` 取得 L，再用 `textFile(project, L, path)` 讀內容（40–64 hex 的 ref 走不可變快取）。不得用兩次分支讀取拼接。
- `createFile`：`fileMetadata` 回 200 時拒絕（`fileExists`）。回 404 時繼續，但依 AGENTS.md，404 有歧義，不能說成「已確認不存在」。真正的保護是 POST 本身回的 4xx。
- 套用建議：讀 `merge_requests/<iid>/discussions/<discussionId>`，用 `lib/core/suggestion.dart` 的 `parseNoteSuggestions` 找到 note 與 `suggestions`，確認建議 `appliable`、尚未套用，並取得 note 的 `position.new_path`／`old_path`。
- `isSensitiveRepositoryPath` 或 `isValidRepositoryPath`（`sensitive_paths.dart`）不通過，就拒絕。

**規則**

- `bindingDigest` 含 L、原文 digest 與最終 diff digest。dispatch 前 L 改變就作廢提議，不悄悄沿用。
- `batchApplySuggestions` 的參數是 `[{discussionId, noteId, suggestionId}]`，最多 20 個，逐一驗證歸屬。

**reason code：** `fragmentNotFound`、`fragmentNotUnique`、`fragmentsOverlap`、`fileTooLarge`、`binaryFile`、`sensitivePath`、`invalidPath`、`fileExists`、`fileMissing`、`suggestionForeign`、`suggestionNotAppliable`、`batchTooLarge`。

**依賴：** 封包 1、2、3、4、5。

**測試**

- §15 第 9 列：
  - 在 metadata、內容讀取、核准、dispatch 之間逐一插入分支前進，都不會送出混合版本；
  - L 不符時回 409，記確定失敗；
  - 沒有 L 不會變成 POST；
  - 新檔已存在時失敗。
- 第 5 列：`edit_file` 狀態未知之後，同一路徑的 `deleteFile` 被擋。
- 第 8 列：分支與 CI 的升級，含自訂 `ci_config_path` 的新增、修改與刪除。
- 第 10 列：屬於其他專案的 suggestion 被拒；批次套用逐一驗證。
- 第 16 列：檔案要專案、ref、路徑三者都綁定；只綁到一個時改為確認。
- 第 26 列最後一點：依建議所在的路徑判定 CI，不看 commit message。

### 封包 7 — 分支、tag 與 Release

**擁有的檔案：** `gitlab_write_port_refs.dart`、`ledger/rows_refs.dart`、`test/ai/mr6b2_refs_port_test.dart`

| operation | 基礎 | 規則 | 確認名稱 | 解除名稱 | key |
|---|---|---|---|---|---|
| `createBranch` | T3 | 來源 ref 由前置讀取確認存在 | — | 新分支名 | `ref, <name>` |
| `deleteBranch` | T4 | 前置讀取命中 `default` 或 `protected` 就拒絕，與 `MetadataPage._canDelete` 相同 | 分支名 | 分支名 | `ref, <name>` |
| `createTag` | T4（一律） | `message` 屬 (B) | 新 tag 名 | tag 名 | `ref, <name>` |
| `deleteTag` | T4 | — | tag 名 | tag 名 | `ref, <name>` |
| `createRelease` | T3 | `tag_name` 必須是已存在的 tag；不接受 `ref`、`assets.links`、`milestones`、`released_at` | — | 專案 `path_with_namespace` | `release, <tag>`／`ref, <tag>` |
| `updateRelease` | T3 | 只改 `name` 與 `description`（後者是 `releaseDescription`，可還原） | — | 專案路徑 | `release, <tag>` |
| `deleteRelease` | T4 | — | Release 名稱 | 專案路徑 | `release, <tag>` |

分支與 tag 共用 `ref, <name>` 這把 key，所以狀態未知的同名建立會擋住之後的同名建立。§3 的 T3 列寫明「這是刻意的」。`createBranch` 的綁定目標是 `AiTargetKind.newBranch`（新名稱加來源 ref）。

**reason code：** `refMissing`、`tagMissing`、`protectedBranch`、`defaultBranch`、`releaseMissing`。

**依賴：** 封包 1、2、3。

**測試**

- §15 第 10 列：Release 只能指向已存在的 tag，上表四個欄位都被拒；`deleteBranch` 拒絕預設與受保護分支。
- 第 8 列：`createTag` 一律 T4；在本次對話授權下要輸入新 tag 名。
- 第 5 列：分支或 tag 同名重建只記觀察，不解除隔離。
- 第 14 列：Release 說明不中和；含外部圖片時要確認。
- 第 32 列：Release 說明的往返。provenance 先用注入的；封包 16 到位後，由封包 18 改用真實讀取。

### 封包 8 — 合併請求

**擁有的檔案：** `gitlab_write_port_merge.dart`、`ledger/rows_merge.dart`、`test/ai/mr6b2_merge_port_test.dart`

| operation | 基礎 | 升級與規則 | 確認名稱 | 解除名稱 | key |
|---|---|---|---|---|---|
| `mergeRequest`（含 `autoMerge`、`squash`、`removeSourceBranch`） | T3 | 目標分支是預設或受保護 → T4；`removeSourceBranch` → T4；既有變更含 CI → 硬底線；`squash` 不升級，只出現在預覽 | T4：目標分支名；硬底線：第一個 CI 路徑 | `!iid` | `mergeRequest, <iid>`、`ref, <target>`（刪來源分支時加 `ref, <source>`） |
| `approveMergeRequest` | T4 | 帶前置讀取的 `sha` | `!iid` | `!iid` | `mergeRequest, <iid>, approval` |
| `rebaseMergeRequest` | T3 | 不暴露 `skipCi` | — | `!iid` | `mergeRequest, <iid>`、`ref, <source>` |
| `cancelAutoMerge` | T3 | 見下 | — | `!iid` | `mergeRequest, <iid>` |
| `publishDraftNotes` | T3 | 伺服器上有非本段對話建立的草稿 → `foreignDraftsInPublish`；草稿超過 20 筆時拒絕 | — | `!iid` | `mergeRequest, <iid>, draftNotes` |
| `deleteDraftNote` | T4 | 前置讀取確認草稿存在、內容未變 | `!iid` | `!iid` | `mergeRequest, <iid>, draftNotes, <id>` |

**合併前的既有變更檢查**

提議時與 dispatch 前都要做。讀取：

- MR JSON：`sha`、`diff_refs`、`changes_count`、`description`、`source_branch`、`target_branch`、`state`；
- `merge_requests/<iid>/diffs`：`per_page=100`，最多 2 頁；
- `…/commits`：`per_page=100`，最多 1 頁；
- `…/closes_issues`：`per_page=100`，最多 1 頁；
- 專案的 `ci_config_path`，以及目標分支的保護狀態。

下列情況一律不產生提議（`mergeCheckIncomplete` 或 `mergeCheckUnsupported`）：超過頁數上限、`changes_count` 帶 `+`、筆數不符、403、404、版本不支援。

head sha、路徑 digest 與將關閉的議題集合放進 `bindingDigest`；`journalSummary` 寫進日誌。`httpCap` 的算法見未解問題 2。

**`cancelAutoMerge`**

- 前置讀取 MR：
  - `isAutoMergeEnabled`（封包 3 搬到 core 的那一個）為 false 時不產生提議（`autoMergeNotEnabled`）；
  - 已合併時回 `alreadyMerged`；
  - `user.can_merge` 為 false 且作者不是目前帳號時，只在預覽標示 `mayLackPermission`。
- 結果用 `AiResultClassifier` 分類：
  - 201、`status == "success"`，且 readback 的 `isAutoMergeEnabled == false` → 成功；
  - readback 仍為 true 或 readback 失敗 → 狀態未知；
  - 201 且 `status == "error"` → 確定未執行，不上鎖（`autoMergeCancelError`）；伺服器的 `message` 經 `draftSafe` 後放進預覽，不送給模型；
  - 其他 `status` → 狀態未知；
  - 這次 POST 收到 404 → 確定未執行（`cancelEndpointUnavailable`）。
- 全程最多一個 POST；不讀版本，也不探測端點。

**§7.8 head 變更**

port 實例是每段對話一個（協調器的 `_port ??= createPort()`）。在 part 檔內記下「合併或核准因 409 失敗的 MR」。之後同一 MR 的合併或核准加上 `headMovedSincePreview`，並用 `repository/compare?from=<舊 sha>&to=<新 sha>` 算出 `headMovedCommits`。compare 端點的回應格式待核對 GitLab 官方文件。

**合併結果**

三種都算成功，但 `resultCode` 不同：

- 2xx 且 `state == merged` → 已合併（`merged`）；
- 帶 `autoMerge` 時，2xx 且自動合併已開啟 → 已排程（`autoMergeScheduled`）；
- 其他 2xx → 已接受（`mergeAccepted`）。

**`publishDraftNotes`**

沿用 `draft_review_page.dart` 的做法：

1. 先驗 head；
2. 讀全部草稿，取快照；快照 digest 放進 `bindingDigest`；
3. 草稿內文放進 `textScan.serverClassA`；
4. 用 `AiWriteRequest.segmentCreated` 判定哪些草稿是本段對話建立的。

**reason code：** `mergeCheckIncomplete`、`mergeCheckUnsupported`、`autoMergeNotEnabled`、`alreadyMerged`、`autoMergeCancelError`、`cancelEndpointUnavailable`、`mayLackPermission`、`headMoved`、`draftsChanged`、`batchTooLarge`、`merged`、`autoMergeScheduled`、`mergeAccepted`。

**依賴：** 封包 1、2、3、5。

**測試**

- §15 第 26 列全文：
  - 模型沒有給任何 CI 文字，但既有 MR 含 CI diff → 硬底線，bypass 也一樣；
  - 自訂 `ci_config_path` 的改名與刪除；
  - 變更清單不完整時不產生提議；
  - `closes_issues` 指向範圍外時改為確認；關閉效果無法判定時不自動執行；
  - 核准之後 head、路徑集合或將關閉的議題改變，提議作廢。
- 第 30 列：取消自動合併的部分，全文。
- 第 20 列。
- 第 8 列：`squash` 只出現在預覽；`removeSourceBranch` → T4；設定自動合併到預設分支 → T4。
- 第 16 列：合併要 MR、來源分支、目標分支三者都綁定。
- 第 5 列：合併狀態未知時，同一 MR 的其他寫入被擋；輸入 `!iid` 一次解除 MR 與目標 ref。
- 第 7 列：等待確認期間 head 改變。

### 封包 9 — Pipeline、Job 與排程

**擁有的檔案：** `gitlab_write_port_ci.dart`、`ledger/rows_ci.dart`、`test/ai/mr6b2_ci_port_test.dart`

| operation | 基礎 | 規則 | 確認名稱 | 解除名稱 | key |
|---|---|---|---|---|---|
| `createPipeline` | T4（一律） | 帶變數 → 硬底線（`validatePipelineVariables`） | ref（由前置讀取確認存在） | 專案路徑 | `pipeline` |
| `pipelineAction`（`cancel`） | T3 | 預覽標示 `cancelMayRunAfterScript` | — | Pipeline ID | `pipeline, <pid>` |
| `pipelineAction`（`retry`） | T4，只需確認 | body 是 `{}`；不讀變數、`source`、`manualJob` | 無 | Pipeline ID | `pipeline, <pid>` |
| `jobAction`（`cancel`） | T3 | 同 Pipeline 取消 | — | Job ID | `pipeline, <pid>, job, <jid>` |
| `jobAction`（`retry`／`play`） | T4，只需確認 | 不依 Job 狀態分流；body 是 `{}` | 無 | Job ID | `pipeline, <pid>, job, <jid>` |
| `playPipelineSchedule` | T4 | `evaluateScheduleParams` 的結果不是 `explicitEmpty` → 硬底線 | ref | 專案路徑 | `pipeline` |
| `deletePipeline` | T4 | — | Pipeline ID | Pipeline ID | `pipeline, <pid>` |

Job 的 key 掛在所屬 Pipeline 底下（Pipeline ID 由前置讀取 `jobs/<id>` 的 `pipeline.id` 取得）。因此 Job 與 Pipeline 的重跑會互相擋住（§7.6、§15 第 5 列），同一 Pipeline 底下的不同 Job 則不會互擋。代價是：狀態未知的 `createPipeline` 或排程播放，會擋住該專案所有的 Pipeline 寫入，直到使用者手動解除（未解問題 13）。

**前置讀取**

- Pipeline：`ref`、`id`、`status`。
- Job：`name`、`stage`、`ref`、`pipeline.id`。
- 排程：`ref`、`variables`、`inputs`。HMAC 用 `AiWriteRequest.scheduleHmacKey` 計算，只放進 `bindingDigest`；預覽只列名稱。

**綁定**

- Pipeline 由 URL、UI 加入或 `segmentCreated` 綁定。
- Job 另外可以經由已綁定的 Pipeline 綁定；只有在前置讀取的 `pipeline.id` 相符時，`jobBelongsToBoundPipeline` 才是 true。
- 模型從工具結果拿到的 ID 不構成綁定。`target_binding.dart` 的 `_jobBound` 已經實作這套規則，這裡只負責填好 `AiTargetRef`。
- `createPipeline` 成功時回傳 `createdOnSuccess`。

**reason code：** `pipelineVariableForbidden`、`pipelineVariableSecret`、`refMissing`、`jobNotInPipeline`、`scheduleParamsUnreadable`、`scheduleMissing`。

**依賴：** 封包 1、2、3、5。

**測試**

- §15 第 30 列，排程與重跑播放的部分全文：
  - 三種情境在一般等級都顯示確認卡，不要求輸入名稱；確認前 POST 次數為 0；
  - body 是 `{}`；
  - schema 沒有變數參數，模型多給時整筆拒絕；
  - HTTP 計數只含取得卡片資訊的前置讀取；
  - 帶新變數的 `createPipeline` 在任何等級都要輸入 ref。
- 第 8 列：
  - `createPipeline`（含功能分支）與 `playPipelineSchedule` 在本次對話授權下要輸入名稱；
  - 取消維持 T3；
  - bypass 下未綁定，或命中固定確認清單時，改為確認卡，且不要求名稱；
  - 從工具結果取得的 Job ID 顯示確認卡；使用者貼了 Pipeline URL 時，同一 Pipeline 底下的 Job 可以自動執行。
- 第 5 列：`jobAction(retry|play)` 與 `pipelineAction(retry)` 互擋；只按確認或輸錯 ID 都不能解除隔離。

### 封包 10 — 片段

**擁有的檔案：** `gitlab_write_port_snippets.dart`、`ledger/rows_snippets.dart`、`test/ai/mr6b2_snippets_port_test.dart`

| operation | 基礎 | 規則 | 確認名稱 | 解除名稱 | key |
|---|---|---|---|---|---|
| `createSnippet` | T2 | 可見度不是 private → 硬底線；初始正文全文掃描 | 硬底線：片段標題 | 專案路徑 | `snippet` |
| `updateSnippetMetadata` | T2 | 改標題與描述（描述是 `snippetDescription`，可還原）；提高可見度 → 硬底線 | 硬底線：片段標題 | 專案路徑 | `snippet, <id>` |
| `updateSnippet` | T2 | 單檔舊格式的內容，只接受精確片段 | — | 專案路徑 | `snippet, <id>` |
| `updateSnippetFiles` | T2 | 新增檔案（初始正文全文掃描）、改名、編輯既有檔的內容（精確片段） | — | 專案路徑 | `snippet, <id>` |
| `deleteSnippetFile` | T4 | 最後一個檔案不可刪 | 完整路徑 | 專案路徑 | `snippet, <id>` |
| `deleteSnippet` | T4 | — | 片段標題（見未解問題 14） | 專案路徑 | `snippet, <id>` |

前置讀取沿用畫面的新鮮度比對：

- REST `snippets/<id>`（`ProjectSnippet`）；
- `projectSnippetSnapshot`（固定的 GraphQL query）；
- 內容用 `snippetText` 或 `snippetBlob` 讀取。

REST 的 `updated_at`、GraphQL 的 `updatedAt`、路徑清單，以及受影響檔案內容的 digest，都放進 `bindingDigest`。更新 metadata 時一律帶前置讀取到的可見度，除非模型明確要求改變。

**reason code：** `snippetChanged`、`snippetLastFile`、`snippetBinary`、`snippetTooLarge`、`snippetPathInvalid`，以及封包 4 的片段 code。

**依賴：** 封包 1、2、3、4。

**測試**

- §15 第 9 列，片段的部分：新鮮內容不符時提議作廢；中繼資料編輯、新增檔案與改名為 T2；刪除片段內單一檔案為 T4，並要輸入檔名。
- 第 14 列：片段的多行字串原樣保留。
- 第 8 列：新建非 private 的片段，以及提高可見度，都是硬底線。
- 第 32 列：片段描述的往返。provenance 先用注入的，同封包 7。

### 封包 11 — 內容刪除與全部待辦

**擁有的檔案：** `gitlab_write_port_deletes.dart`、`ledger/rows_deletes.dart`、`test/ai/mr6b2_deletes_port_test.dart`

| operation | 具名方法 | 確認名稱 | 解除名稱 | key |
|---|---|---|---|---|
| `deleteNote`（根留言） | `deleteNote` | 所屬資源的 `#iid`／`!iid` | 同左 | `workItem\|mergeRequest, <iid>, notes, <id>` |
| `deleteDiscussionNote`（討論回覆） | `deleteDiscussionNote` | 所屬資源的 `#iid`／`!iid` | 同左 | 同上 |
| `deleteIssue` | `deleteIssue` | `#iid` | `#iid` | `workItem, <iid>` |
| `deleteMergeRequest` | `deleteMergeRequest` | `!iid` | `!iid` | `mergeRequest, <iid>` |
| `deleteLabel` | `deleteLabel` | 標籤名 | 專案路徑 | `labels, <id>` |
| `deleteMilestone` | `deleteMilestone` | 里程碑標題 | 專案路徑 | `milestones, <id>` |
| `deleteBoard` | `deleteBoard` | 看板名 | 專案路徑 | `boards, <id>` |
| `deleteBoardList` | `deleteBoardList` | 清單的標籤名 | 專案路徑 | `boards, <boardId>`（與 MR6b-1 的 `moveBoardList` 相同） |
| `markAllTodosDone` | `markAllTodosDone` | 目前帳號的 `@username` | `@username` | `(account, todos)`（擋住所有單筆待辦） |

**規則**

- 全部是 T4。
- 前置讀取確認資源屬於該專案與該 iid（比照 MR6b-1 的 `_verifyId`）；名稱取自讀取結果。
- `markAllTodosDone` 的範圍類別是 `accountGlobalOnly`，固定確認理由 `markAllTodosDone` 已經存在。預覽列出第一頁的待辦數，並標示是否還有更多。

**依賴：** 封包 1、2、3。

**測試**

- §15 第 5 列：狀態未知的 `deleteIssue` 擋住該議題的留言寫入，反之亦然；看板卡片移動與議題共用同一把 key。
- 第 8 列：各種刪除的確認名稱；`markAllTodosDone` 在 bypass 下也要確認。
- 第 10 列：`deleteNote` 的 resource 只接受兩個列舉值。

### 封包 12 — Registry 與專案硬底線

**擁有的檔案：** `gitlab_write_port_project.dart`、`ledger/rows_project.dart`、`test/ai/mr6b2_project_port_test.dart`

| operation | 層級 | 規則 | 確認名稱 | 解除名稱 | key |
|---|---|---|---|---|---|
| `deletePackage` | T4 | `canDelete` 為 false 或專案已封存就拒絕 | 名稱與版本（`identity`） | 專案路徑 | `packages, <id>` |
| `deletePackageFile` | T4 | 同上 | 檔名 | 專案路徑 | `packages, <id>, files, <fid>` |
| `deleteContainerRepository` | T4 | `effectiveProjectAccess` ≥ Maintainer，且專案未封存 | 路徑 | 專案路徑 | `registry, <rid>` |
| `deleteContainerTag` | T4 | 同上 | `路徑:tag` | 專案路徑 | `registry, <rid>, <tag>` |
| `createProject` | 硬底線 | 只接受 name、path、description；private 與 `initialize_with_readme` 固定 | 個人 namespace 下的完整路徑 | 同左 | `(account, namespace:<userId>, projects)` |
| `editProject` | 硬底線 | 只改名稱與描述 | `path_with_namespace` | 同左 | `settings` |
| `deleteProject` | 硬底線 | — | `path_with_namespace` | 同左 | `(account, project:<id>)`（擋住全部子資源） |
| `forkProject` | 硬底線 | 不帶 `namespacePath` | 目的地完整路徑（`@username/<來源 path>`） | 同左 | `(account, namespace:<userId>, projects)` |

`editProject` 用 `settings` 子 key，避免狀態未知的改名把整個專案鎖住。

**reason code：** `packageNotDeletable`、`projectArchived`、`maintainerRequired`、`containerMissing`、`personalNamespaceUnknown`。

**依賴：** 封包 1、2、3。

**測試**

- §15 第 10 列：`createProject` 只接受三個欄位，且一定是 private；fork 不帶 `namespacePath`。
- 第 8 列：四個專案操作在 bypass 下也要輸入名稱。
- 第 5 列：`deleteProject` 狀態未知時，擋住該專案的所有寫入。

### 封包 13 — 畫面改接（一）：議題與 MR、討論、草稿、看板

**擁有的檔案**

- `lib/features/workspace/work_item_page.dart`：
  - 第 977 行的 `removeRecord(ownerPath)` 依 `owner.resource` 改呼叫 `deleteIssue` 或 `deleteMergeRequest`；
  - 刪除本地的 `isAutoMergeEnabled` 與 `canAutoMerge`（第 2260 行起），改 import `lib/core/merge_request_state.dart`；
  - `test/mr_auto_merge_test.dart` 是從這個檔 import `canAutoMerge` 的。為了不改那個測試，本檔要 `export '../../core/merge_request_state.dart' show isAutoMergeEnabled, canAutoMerge;`。
- `lib/features/workspace/discussions_tab.dart`：第 186 行，根留言改呼叫 `deleteNote`，討論回覆改呼叫 `deleteDiscussionNote`，path 與現在相同。
- `lib/features/workspace/draft_review_page.dart`：第 485 行改呼叫 `deleteDraftNote`，第 557 行改呼叫 `publishDraftNotes`。
- `lib/features/workspace/boards_page.dart`：第 662 行改呼叫 `deleteBoardList`，第 730 行改呼叫 `deleteBoard`。

**不要碰**

`write_call_site_ledger_test.dart`（封包 3 已改成只允許遞減）、port、ledger、`workspace_api.dart`、版面。

**依賴：** 封包 3。

**測試**

- 用 FakeAdapter 證明改接前後送出的 method 與 path 逐位元組相同；既有的 widget 測試全部維持綠燈。
- 確認框繼續用 `confirmAction`，`requiredText` 不改。
- §15 第 21 列由封包 17 收尾。

### 封包 14 — 畫面改接（二）：`MetadataPage` 與倉庫檔案

**擁有的檔案**

- `lib/features/workspace/project_more_page.dart` 的 `MetadataPage`：
  - 第 808–809 行依 kind 改呼叫 `createBranch`、`createTag`、`createRelease`、`updateRelease`；
  - 第 819 行依 kind 改呼叫 `deleteBranch`、`deleteTag`、`deleteRelease`、`deleteLabel`、`deleteMilestone`。
- `lib/features/workspace/repository_page.dart`：
  - 第 278 行改呼叫 `createRepositoryFile`；
  - 第 1412 行改呼叫 `updateRepositoryFile`。`_lastCommit` 為 null 時不送出，改顯示衝突，不再退回 POST。

**不要碰：** 同封包 13。`project_more_page.dart` 裡的 fork、編輯專案、刪除專案已經是具名方法，不必動。

**依賴：** 封包 3。

**測試：** 同封包 13；另外證明 `_lastCommit` 為 null 時 HTTP 次數為 0。

### 封包 15 — 畫面改接（三）：片段與 Registry

**擁有的檔案**

- `lib/features/workspace/snippets_page.dart`：第 161、612、703、797、993、1069 行，依序改呼叫 `createSnippet`、`updateSnippet`、`updateSnippetMetadata`、`updateSnippetFiles`、`deleteSnippetFile`、`deleteSnippet`。新鮮度比對與 readback 原樣保留。
- `lib/features/workspace/registries_page.dart`：第 660、709、1223、1512 行改呼叫四個 registry 刪除包裝；`_effectiveAccess` 改用 `effectiveProjectAccess`。

**不要碰：** 同封包 13。

**依賴：** 封包 3。

**測試：** 同封包 13；另外證明片段的 payload 逐位元組相同。

### 封包 16 — Release、里程碑、片段的讀取工具（條件封包，見未解問題 10）

讓模型讀得到這三種欄位。有了讀取來源，§3.1 的可還原佔位字串才有來源，模型也才寫得出片段精確片段的 `old`。

**擁有的檔案：** `lib/core/ai/tools/tool_catalogue.dart`、`lib/core/ai/tools/gitlab_read_port.dart`、新 `lib/core/ai/tools/field_provenance.dart`、新 `test/ai/mr6b2_read_tools_test.dart`

**內容**

- 新增 `get_release`、`get_milestone`、`get_snippet`。`get_snippet` 回傳 metadata、檔案清單，以及一個檔案的內容。
- 全部走 REST，只用 GET，path 從 `['projects', '$projectId', …]` 開始，因此 `test_generic_reads_start_at_the_bound_project` 照樣成立。
- 欄位的完整值用 `UploadPlaceholderTable.redactOutgoing(field:)` 標記為 `releaseDescription`、`milestoneDescription` 或 `snippetDescription`。
- `get_snippet` 讀內容要用 `snippetText`，這需要擁有者同意擴充唯讀白名單。不同意時，`get_snippet` 只回 metadata，片段內容的精確片段編輯不開放。

**不要碰：** 寫入 port、協調器、`ai_chat_controller.dart`（`_freshWrite` 的 provenance 接線由封包 17 做）。

**依賴：** MR6b-1 的 provenance 接線（未解問題 10）、封包 1。

**測試**

- §15 第 32 列：Release 說明、里程碑描述、片段描述的往返。
- 第 13 列：唯讀守衛不變。
- 第 23 列：外送內容不含上傳 secret。

---

## 波次 C

### 封包 17 — 整合：開放工具、政策 v2、收尾

**擁有的檔案**

- `ledger/rows_*.dart`：MR6b-2 各列的 `modelVisible` 改為 true（每列改一行）。
- `lib/core/ai/ai_provider.dart`：`AiWritePolicy` 的正規 JSON 加 `escalationRuleIds`，涵蓋：受保護分支、`removeSourceBranch`、CI 硬底線、帶變數、排程參數、可見度、機密性、重跑與播放只需確認。
- `lib/features/ai/ai_chat_controller.dart`：
  - `aiMr6b1WritePolicy`（第 2065 行）改名為 `aiProductionWritePolicy`，並設 `policyVersion: 2`；
  - `_freshWrite` 帶入封包 16 的 provenance；
  - 若未解問題 11 採用，`_writeScope` 對 `AiInboxOrigin` 給 `accountGlobal` grant。
- `lib/features/ai/ai_chat_session.dart`：新增 `AiInboxOrigin`（若採用）。
- `lib/core/ai/prompts.dart`：`aiWriteSystemPrompt` 補三點：`edit_file` 只接受精確片段；合併前會先檢查既有變更；CI 的副作用不是 app 能判定的。
- `lib/core/workspace_api.dart`：刪除 `saveFile`。
- `test/ai/write_call_site_ledger_test.dart`：
  - 換回精確斷言；
  - MR6b-2 的待交付清單要為空，只剩 MR6b-3 的 GraphQL；
  - `_rewiredNamedCalls` 加上封包 13–15 的呼叫。
- `test/ai/write_tier_test.dart`：可見列等於 MR6b-1 與 MR6b-2 的聯集；`toolsForScope` 的長度斷言依新的範圍類別調整。

**依賴：** 封包 1–16。

**測試**

- §15 第 11 列：MR6b-2 升版後既有同意再次失效；換 `toolCatalogueVersion` 會改變 hash；政策 v2 的升級規則進入 hash。
- 第 21 列收尾：每個寫入呼叫點都對應到 ledger 列或 MR6b-3 清單，沒有其他。
- 第 15 列：新文案 key 由主導者的提交提供，這裡只跑「24 語齊全」的檢查。

### 封包 18 — 跨家族的 §15 重跑

只新增測試檔，不改 `lib/`。發現缺陷時，以 reason code 與重現步驟回報給對應的封包。

**擁有的檔案：** `test/ai/mr6b2_injection_test.dart`、`mr6b2_isolation_test.dart`、`mr6b2_races_test.dart`、`mr6b2_matrix_test.dart`、`mr6b2_guard_test.dart`、`mr6b2_binding_test.dart`、`mr6b2_budget_test.dart`、`mr6b2_boundary_test.dart`

**依賴：** 封包 17。波次 B 期間可以先用注入的可見 ledger 把測試寫好。

**測試**

- §15 第 1 列：用真實工具跑注入語料。README、Job log、MR diff 裡的「合併」「刪分支」「重跑」不得產生未經確認的 T2 以上寫入；bypass 下，範圍外、硬底線與固定確認清單一律被擋或改為確認。
- 第 5 列，跨家族：REST 刪除與合併、Job 與 Pipeline、檔案與套用建議。
- 第 6 列：用真實工具做卡片雙擊、兩段對話同時核准同一個合併，最多一次 dispatch。
- 第 7 列：29 分鐘與 31 分鐘；等待期間調低等級。
- 第 8 列：真實列的五個等級 × 各層級。
- 第 13 列：每個 mutation 恰好對應一筆核准，帶相同的執行 ID。
- 第 16 列。
- 第 19 列：合併的保留；三段對話共用帳號的上限。
- 第 29 列：在 flush barrier 下跑合併、`edit_file` 與重跑。

---

## 建議順序

```text
波次 A（並行）
  封包 1  能力表、port 拆檔、守衛、版本 3（write_preview.dart 最先提交）
  封包 2  協調器接縫（與 1 同時寫，合併排在 1 之後）
  封包 3  具名包裝、merge_request_state、呼叫點測試的過渡規則
  封包 4  精確片段引擎
  封包 5  CI 判定、合併檢查模型、排程 HMAC、變數

波次 B（A 完成後，全部並行；各自只改自己的 part、rows 與測試檔）
  封包 6  檔案與套用建議        封包 7  分支、tag、Release
  封包 8  合併請求              封包 9  Pipeline、Job、排程
  封包 10 片段                  封包 11 內容刪除、全部待辦
  封包 12 Registry、專案硬底線
  封包 13、14、15 畫面改接（只依賴封包 3，封包 3 合併後即可開始）
  封包 16 讀取工具（條件）

波次 C
  封包 17 開放工具、政策 v2、收尾
  封包 18 跨家族 §15 重跑

波次 D（主導者，與 B、C 重疊，獨佔 UI 檔與 l10n）
  卡片與預覽、警示、文案；一次 l10n 提交
```

MR 的合併條件：

- §14 為 MR6b-2 點名的 §15 列全部綠燈；
- `write_call_site_ledger_test.dart` 的 MR6b-2 待交付清單為空；
- gate 仍然關閉。

## 主導者要設計的畫面

程式封包不改下列檔案的版面：`ai_write_ui.dart`、`ai_chat_page.dart`、`ai_consent_dialog.dart`、`ai_settings_page.dart`、`ai_write_log_page.dart`，以及新的預覽元件。

| 畫面 | 讀取的 API | 計畫 |
|---|---|---|
| 輸入名稱確認 | `AiTierDecision.requiresTypedName`、`typedName`（來自 `confirmName`）、`AiWritePreview` | §3「確認名稱來源」、§4.1 |
| T4 卡片：合併、核准、刪除、建立 tag、執行 Pipeline、播放排程、全部待辦完成 | 各 `AiWritePreview` 子型別 | §3 T4 列、§4.1、§7.7 |
| 重跑與播放的確認卡（不要求名稱） | `reusesStoredVariables`、`AiPipelinePreview` | §0 第 12 點、§3 |
| 警示：squash、CI 硬底線、沿用已存變數、排程目前的變數、無法核對參數、取消後仍可能跑 `after_script`、head 已變更 +N、將關閉的議題、檔案已含疑似秘密 N 處 | `showSquash`、`cancelMayRunAfterScript`、`AiMergePreview`、`AiPipelinePreview`、`AiDiffPreview` | §3、§5 第 4 點、§7.8 |
| `edit_file` 與片段的 diff 預覽 | `AiDiffPreview`（`AiDiffLine`） | §5 第 8 點、§6 |
| 合併前檢查摘要 | `AiMergePreview` | §3「合併前的既有變更檢查」 |
| 草稿整批送出清單（標示本段對話建立的） | `AiDraftPublishPreview` | §3「草稿審查整批送出」 |
| 取消自動合併的結果文案 | `resultCode` | §3「取消自動合併」 |
| 操作與欄位標籤、所有新的 reason code | `aiOperationLabel`、`aiFieldLabel` 的新 key | §7.7 |
| 中斷的寫入與手動解除：新的 key 種類（ref／路徑、Pipeline／Job ID、專案路徑） | 日誌的 `releaseName` | §3「解除狀態未知的鎖」、§7.6 |
| 同意框：目錄 3 的重新同意 | `aiProductionWritePolicy` | §10 |
| 收件匣的 AI 入口（若採用未解問題 11） | `AiInboxOrigin` | §2 |

設計要點：

- **輸入名稱。** 卡片寫明要輸入什麼、名稱從哪裡來，例如「目標分支 `main`」「Pipeline 的 ref」「新 tag 名」「CI 路徑 `.gitlab-ci.yml`」。合併命中多個 CI 路徑時列出全部，但只要求輸入第一個。比對時不含 `isolated()` 加入的方向隔離字元。
- **重跑與播放。** 只有確認鈕。文案沿用 §3 那一句：重跑或播放可能沿用 GitLab 上已存的原變數與 inputs；排程建立的 Pipeline 還會使用排程**目前**的變數；app 讀不到也無法核對。Pipeline 列出 ref 與 ID；Job 另列 ID、名稱與 stage。自動執行時，同一句放在稽核列。
- **合併。** 顯示短 sha、來源 → 目標、squash、是否刪除來源分支、是否自動合併。結果分成「已合併」「已排程自動合併」「GitLab 已接受」三種，不可混用。
- **diff 預覽。**
  - 只在本機計算，不連網；
  - 等寬字型、顯示行號；變動區塊前後各 3 行；新檔整份顯示；
  - 文字一律經 `draftSafe`；
  - 在 320 dp、2× 字體與 RTL 下都要能讀；
  - `edit_file` 與片段的卡片沒有「編輯內容」（`editableField == null`）。使用者想改時，拒絕這次提議，請模型重新提議。
- **刪除。** 顯示對象的完整識別（`#iid`、路徑、名稱與版本）。遇到 404 時，依 AGENTS.md 寫「找不到或無權限檢視」，不要寫「已刪除」。
- `aiTierLabel` 目前把 T4 與硬底線顯示成同一個標籤。硬底線要不要另一種樣式，由主導者決定。

## 未解問題與正文裡的衝突

1. **port 拆成 part 檔。**
   - 衝突：守衛只掃 `gitlab_write_port.dart`（`test_ai_boundaries.py` 的 `test_row13_write_port_calls_only_whitelisted_members`）。part 檔裡沒有 `gitlab_api.dart` 字樣，會同時逃過 importer 測試與成員白名單。
   - 建議：照封包 1 收緊守衛（掃全部 part 檔、禁止 `GitLabApi` 宣告、禁止把 `_api` 當參數、part 檔裡不得出現 `gitlab_api.dart` 字樣），換取七個家族並行。
   - 替代做法：port 只保留一個檔，家族封包依序實作，至少多出兩到三個波次。

2. **合併的 HTTP 預算放不下。**
   - 衝突：`AiToolBudget.maxGitLabRequests` 是 40，協調器的 `_requestAllowance` 預設 39，每個邏輯 GET 算 2 次。合併的兩次前置讀取各約 8 個邏輯 GET（diffs 2 頁、commits 1 頁），再加上 `_freshWrite` 的專案讀取、mutation 與 readback，會到 39 左右。只要模型先讀過 MR，就保留不到額度。
   - 建議三件事：
     - (a) 頁數上限照封包 8；
     - (b) MR6b-2 的列在 `_freshWrite` 不綁專案的 `updated_at`（封包 2）；
     - (c) dispatch 前，若 MR 的 `sha` 與 `diff_refs` 三個值都沒變，diffs 與 commits 不重新分頁（它們由這幾個 sha 決定）；`closes_issues`、`ci_config_path` 與目標分支的保護狀態照樣重讀。
   - (c) 偏離 §3「dispatch 前重驗」的字面，需要擁有者確認。採用後合併約 29 次；不採用時，一次送出只能有一筆合併。

3. **405 與 406 會被鎖成狀態未知。**
   - 衝突：`ApiFailure.fromStatus` 把 405、406 映射到 `invalidResponse`，而 §7.5 把未列出的種類算作狀態未知。據我所知，GitLab 合併端點在不可合併時回 405、有衝突時回 406，兩者都是執行前的拒絕。這一點待核對 GitLab 官方文件。
   - 建議：若核對屬實，修訂 §7.5，讓合併、核准、rebase、取消自動合併的 mutation 回 405 或 406 時記為確定未執行。不改的話，常見的「不能合併」會上鎖，並要求使用者手動解除。

4. **確認名稱與解除名稱混用。**
   - 衝突：`write_coordinator.dart` 的 `_tier` 把 `releaseName` 當 `typedName`。MR6b-1 的列兩者剛好相同；MR6b-2 有很多列不同。例如合併到受保護分支，確認名稱是分支名，解除名稱是 `!iid`；建立 Pipeline，確認名稱是 ref，解除名稱是專案路徑。
   - 處理：封包 1、2 已拆成 `confirmName` 與 `releaseName`。

5. **Release 說明會被當成 (A) 中和。**
   - 衝突：`_prepareText` 用「`field == 'body'`，或欄位是 description 且不是 Label／Milestone」判斷 (A)。`createRelease`、`updateRelease` 與片段描述都會被中和，違反 §5 的 (B) 規則。
   - 處理：封包 1、2 改由 ledger 宣告每個欄位的類別。

6. **前置讀取在守衛之外。**
   - 衝突：`ai_chat_controller.dart` 的 `_freshWrite` 直接呼叫 `_api.record`，不受 §15 第 13 列的白名單約束。
   - 處理：MR6b-2 決定層級的讀取（保護狀態、`ci_config_path`、合併檢查、排程參數）全部放在 port 裡，經 `AiWritePrepared.facts` 與 `bindingDigest` 交出；`_freshWrite` 只保留 MR6b-1 的可見度與污染判定。

7. **`saveFile` 會退回 POST。**
   - 衝突：`workspace_api.dart` 第 240 行在 `lastCommit == null` 時送 POST，違反 §6。`repository_page.dart` 第 1412 行傳入的 `_lastCommit` 可能是 null。
   - 處理：封包 3 拆成兩個包裝，封包 14 改接畫面，封包 17 刪除 `saveFile`。

8. **討論回覆的刪除 path 不同。**
   - 衝突：`discussions_tab.dart` 第 186 行刪討論回覆時用 `…/discussions/<d>/notes/<n>`，`deleteNote` 用的是 `…/notes/<n>`。
   - 建議：新增 `deleteDiscussionNote`，並在 ledger 上自成一列（一個方法一列），畫面送出的 path 不變。

9. **畫面裡的判斷要搬到 core。**
   - 衝突：`isAutoMergeEnabled` 在 `work_item_page.dart`，`_effectiveAccess` 是 `registries_page.dart` 的 private 函式；port 不能 import 畫面。
   - 處理：封包 3 搬到 core，封包 13、15 改 import；`work_item_page.dart` 保留 re-export，讓 `test/mr_auto_merge_test.dart` 不必改。

10. **第 32 列的 MR6b-2 欄位沒有讀取來源。**
    - 衝突一：唯讀目錄只有從 `read_file` 到 `search_project` 共十個工具，沒有 Release、里程碑與片段。
    - 衝突二：`UploadPlaceholderTable.redactOutgoing` 在 `lib/` 裡沒有正式的呼叫者，`_freshWrite` 也不填 `provenance`。所以在正式路徑上，連 MR6b-1 的議題描述、MR 描述與留言都拿不到 `[[upload:u-n]]`。
    - 建議：MR6b-1 合併前先確認並補上這條接線，因為它屬於 MR6b-1 的第 32 列。MR6b-2 由封包 16 加三個讀取工具。
    - 還要擁有者決定：`get_snippet` 讀內容要用 `snippetText`，但 §15 第 13 列寫明唯讀白名單不變。不同意擴充時，就不開放片段內容的精確片段編輯，只保留中繼資料與檔案動作。

11. **`markAllTodosDone` 沒有範圍可用。**
    - 衝突：`AiChatOrigin` 只有 General、Job、WorkItem、File 四種，`_writeScope` 從不產生 `accountGlobal` grant。
    - 建議：封包 17 加 `AiInboxOrigin`，主導者在收件匣加 AI 入口。不採用時，這一列維持不可見，移到 MR6b-3 的清單；MR6b-3 的待辦延後也需要同一個範圍。

12. **建立專案與 fork 的範圍沒有定義。**
    - 衝突：§2 定了目的地，沒有定哪一種對話可以提議這兩個操作。
    - 建議：`createProject` 只在對話至少有一個 `project` grant 時提供；`forkProject` 只在來源專案在範圍內時提供。兩者都是硬底線，要輸入目的地的完整路徑。

13. **前綴比對讓鎖的範圍變大。**
    - 衝突：`AiConflictKey.intersects` 是前綴比對，而 `_isolated` 會把對方明細的寫入 key 與依賴 key（`_allKeys`）都算進去。結果：
      - 檔案寫入依賴 `ref, <branch>`，一筆狀態未知的 `edit_file` 會擋住同一分支上所有的檔案寫入；
      - 建立類的 `pipeline` key 會擋住該專案所有的 Pipeline 寫入。
    - 建議：這是保守的方向，接受並寫進 ledger。若要縮小範圍，得改日誌的相交語意，不在 MR6b-2 做。

14. **畫面與計畫的確認名稱不一致。**
    - 衝突：
      - 畫面刪片段時要求 `#id`（`snippets_page.dart` 第 1049 行），§3 寫的是「片段標題」；
      - 刪容器 tag 時畫面只要 tag 名，§3 寫的是「路徑與 tag」；
      - 刪審查草稿時畫面要求 `#id`，§3 的留言刪除規則是 `!iid`。
    - 建議：AI 照 §3；畫面改接時不改確認名稱（只換呼叫，不換行為）。片段標題可能重複；若擁有者偏好唯一值，片段改用 `#id`，並修訂 §3。

15. **CI 路徑的邊界。**
    - `ci_config_path` 可能是 `x.yml@group/project` 或 URL。這時本專案沒有對應的檔案，但 `.gitlab-ci.yml` 仍照常判定。
    - `CODEOWNERS` 依 GitLab 的三個位置判定：根目錄、`docs/`、`.gitlab/`。
    - 這是封包 5 的解讀，請擁有者確認。

16. **§7.8 的狀態由誰持有。**
    - 衝突：計畫沒有寫持有者。
    - 建議：放在每段對話一個的 port 實例裡（封包 8）。協調器重建時（例如換 provider），狀態歸零，視為新的一段。

17. **第 4 類綁定只對整個目標成立。**
    - 衝突：`_bindOne` 對 `createdInSegment` 的判定是整個目標成立，不分元件。所以本段對話建立的分支，不能讓「那個分支上的某個路徑」自動綁定，使用者仍要寫出路徑。
    - 處理：MR6b-2 只在兩處使用這個登錄：Pipeline（給 Job 綁定）與審查草稿（給整批送出的判定）。

18. **`diffs` 與 `compare` 端點的版本。**
    - 衝突：`GET …/merge_requests/:iid/diffs` 的最低支援版本待核對 GitLab 官方文件。舊版沒有這個端點時會回 404，依 §3 屬於「版本不支援 → 不產生提議」，也就是舊版 instance 上 AI 無法合併。
    - `repository/compare` 用來算 head 變更的 +N，同樣待核對。
    - 請擁有者確認這樣可以接受。
