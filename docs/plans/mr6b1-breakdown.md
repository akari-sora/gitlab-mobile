本機 `main`（`66f529c2`）比 `origin/main`（`4b8c0aec`）落後 120 個提交，`lib/core/ai/` 與 `lib/features/ai/` 只存在於遠端。下面的檔案與類別都以 `origin/main` 為準。計畫正文是 §0–§15；§16–§23 只是變更紀錄。

# MR6b-1 實作封包

MR6b-1 交付寫入的安全骨架，以及 T1／T2 的 REST 工具（含 `upload_attachment`）。T3／T4／硬底線的真實工具、`edit_file`、片段、合併前檢查、排程 HMAC、GraphQL 掛鉤、前景服務與通知都不在這一批。分級引擎仍要用**只存在測試裡的假列**證明 T3 以上的矩陣（§14）。模型看得到的工具清單只含已實作的 T1／T2。

九個封包給程式代理人。提議卡片、附檔按鈕、設定頁「寫入方式」、bypass、稽核列、「中斷的寫入」與手動解除的畫面由主導者做，見最後一節。

## 共同約定

- 邏輯封包回傳 reason code，不在 `lib/` 寫中文句子。`tool/tests/test_l10n.py` 會擋 `lib/l10n/` 以外的中文。
- `lib/l10n/arb/*.arb` 與 `lib/l10n/strings*.g.dart` 只有兩個寫入者：封包 3（意圖詞、否定詞、條件詞）與主導者的 UI 提交（其餘使用者可見文字，含刪除 `aiReadOnlyPromise`）。§10 要求設定、system prompt、同意摘要與 24 個語系在**同一個整合提交**裡換掉唯讀承諾。
- 唯讀 port 的成員白名單與 GET/HEAD 測試維持現狀（§15 第 13 列）。`lib/core/ai/` 裡除了 `gitlab_read_port.dart`，只有新的 `gitlab_write_port.dart` 可以 import `gitlab_api.dart`（現況由 `tool/tests/test_ai_boundaries.py` 鎖成只有 read port）。
- 寫入 port 只呼叫具名方法。禁止呼叫 `writeRecord`、`removeRecord`、`writeEmpty`、`graphMutation`、`_send`，也禁止把模型給的字串拼進 path。
- `AiResourceScope`（`lib/core/ai/tools/tool_scope.dart`）維持單專案，給現有的 `GitLabAiReadPort` 與 `AiToolCatalogue` 用。寫入範圍用新的型別，不改這個類別的欄位。
- GraphQL 的 `beforeMutation`／`mayStart` 留到 MR6b-3。MR6b-1 不改 Work Item、事件單、待辦延後方法的簽章。
- 日誌 envelope 現在就留 §8 的綁定欄位（`last_commit_id`、head sha、`updated_at`、合併前檢查摘要、policy revision、解除名稱）。排程 HMAC 只活在記憶體裡的提議，不進日誌（§3）。

---

## 封包 1 — 同意契約與自主等級資料

實作 §4.1、§4.3 第 10 點的資料面、§9 的版本常數、§10。每個帳號有上限與起始等級；每個 provider 的 `AiConsentRecord` 有已同意上限。`aiToolCatalogueVersion` 與 `aiDisclosureVersion` 改為 2，既有同意的 hash 全部失效。`AiAccountRecord` 由 v1 升到 v2：舊同意的已同意上限是唯讀，`historyEnabled`、保留天數、對話 token 上限與其他 provider 的同意保留。調低上限只增加 `writePolicyRevision`，不使 `AiSettingsController.isValid` 失敗。

**擁有的檔案**

- 改 `lib/core/ai/ai_provider.dart`（`AiConsentContract`、`aiConsentContractFor`）
- 改 `lib/core/ai/tools/tool_catalogue_version.dart`（常數改為 2；此檔維持零 import）
- 改 `lib/features/ai/ai_stores.dart` 的 `AiConsentRecord`、`AiAccountRecord`、`AiSettingsController`（`isValid`、`_grantConsent`、decode）
- 改 `tool/tests/test_ai_boundaries.py` 裡「版本必須是 1」那一條斷言

**不要碰**

`runner.dart`、`tool_catalogue.dart`、`redaction.dart`、`gitlab_api.dart`、`ai_chat_page.dart`、`ai_consent_dialog.dart`、`ai_settings_page.dart`、ARB、日誌檔、畫面。

**公開 API**

```dart
enum AiAutonomyLevel { readOnly, confirmEach, lowRiskAuto, conversationGrant, bypass }

enum AiWriteTier { t1, t2, t3, t4, hardLine }

final class AiWritePolicy {
  const AiWritePolicy({
    required this.policyVersion,
    required this.agreedCeiling,
    required this.catalogueVersion,
    required this.operationIds,
    required this.hardLineOperationIds,
    required this.fixedConfirmOperationIds,
    required this.resetConfirmWindow,
  });
  final int policyVersion;
  final AiAutonomyLevel agreedCeiling;
  final int catalogueVersion;
  final Set<String> operationIds;
  final Set<String> hardLineOperationIds;
  final Set<String> fixedConfirmOperationIds;
  final Duration resetConfirmWindow; // 24h，§8
  Map<String, Object?> toCanonicalJson();
}

AiAutonomyLevel effectiveCeiling({
  required AiAutonomyLevel ceiling,
  required AiAutonomyLevel agreedCeiling,
});

AiConsentContract aiConsentContractFor(
  AiProviderConfig provider, {
  int toolCatalogueVersion = aiToolCatalogueVersion,
  int disclosureVersion = aiDisclosureVersion,
  Set<String>? dataCategories,
  AiWritePolicy? writePolicy,
});

final class AiAccountRecord {
  // version 欄位成為 2
  final AiAutonomyLevel ceiling;       // 預設 lowRiskAuto
  final AiAutonomyLevel startingLevel; // 必須 ≤ ceiling，不進 hash
  final int writePolicyRevision;
  final bool aiAttribution;            // 預設 false，不進 hash
  static AiAccountRecord decode(String raw); // 接受 v1，寫出 v2
}
```

`dataCategories` 在 `toolsEnabled` 為 true 時加入 `write_results` 與 `attachment_metadata`；為 false 時連 `tool_reads` 一起拿掉（沿用現有 `aiConsentContractFor` 的做法）。對話中的「本次對話授權」不進 `AiAccountRecord`，由封包 7 放在控制器記憶體。

**依賴：** 無。可與封包 2、3、4 並行。`ai_stores.dart` 只有本封包能改帳號紀錄；封包 2 若要加日誌金鑰方法，等本封包合併後再改同一個檔，或把金鑰存取放在新檔。

**測試：** §15 第 11 列（v1 fixture → v2 → 往返、兩個 provider、不同已同意上限、非預設紀錄設定；替 B 調高不影響 A；舊唯讀同意不授權寫入；調低上限不需重新同意；調高超過已同意上限需要新 hash；`toolsEnabled == false` 沒有寫入類別；換 catalogue 版本使 hash 改變）。第 12 列的「上限為唯讀則契約不含寫入工具」用這個資料模型斷言，segment 本體在封包 7。第 11 列裡 MR6b-2／MR6b-3 再升版，用「傳入不同的 `toolCatalogueVersion`」證明，本封包只把常數設成 2。

**UI／邏輯：** 純邏輯。同意框「寫入」段落、類別標籤、設定頁上限控制是主導者的畫面；它們讀這裡的 `AiWritePolicy` 與 `effectiveCeiling`。

---

## 封包 2 — 寫入日誌、隔離表與移除保留

實作 §8 與 §7.6 的耐久狀態、§4.4 的對話計數與 60 分鐘視窗。`AiWriteJournal.instance` 是程序級單例，不跟著 `SessionController.generation`、`AccountAiRunRegistry` 或聊天頁釋放。狀態轉移只在帳號級短臨界區內發生。`AiRemovalHold` 是這個單例上的程序級作業，不是 `AiAccountMutationCoordinator.beginCleaning`。

**擁有的檔案**

- 新 `lib/features/ai/ai_write_journal.dart`
- 新 `lib/features/ai/ai_journal_key_store.dart`（介面 + `MemoryAiJournalKeyStore`）
- 加密沿用 `AiHistoryCipher`（`lib/features/ai/ai_history_codec.dart`）的 AES-256-GCM、12-byte nonce、AAD 綁定版本／account／檔名；檔案寫入沿用 `AiHistoryFileStore` 的獨占暫存檔、`flushSync`、`renameSync`。目錄是 `<application-support>/ai_write_journal/<sha256(account.key) 前 32 hex>/`，金鑰是 `ai_write_journal_key.v1.<base64url(account.key)>`，重設標記是 `ai_write_journal_reset_pending.v1.<…>`
- 本封包合併時補上 `SecureAiStore`／`AiSecureInventory` 的金鑰與標記（在封包 1 之後改 `ai_stores.dart`），以及 AGENTS.md 持久化清單與 CLAUDE.md Persistence

**不要碰**

`ai_history.dart` 的清除、保留期與 `files.deleteAccount`、`gitlab_api.dart`、`runner.dart`、聊天頁、設定頁、`authenticated_app.dart`、`login_screen.dart`。保持隔離的讀取走日誌，不呼叫 `beginCleaning`。

**公開 API**

```dart
enum AiJournalState { prepared, dispatching, succeeded, failedCertain, writeUncertain, notExecuted, resolvedByUser }

enum AiJournalKeyStatus { found, uninitialized, keyMissing, removed, unavailable, unknownFormat, overSize }

final class AiConflictKey {
  const AiConflictKey(this.parts); // 已正規化、與 operation 名稱無關
  final List<String> parts;
  bool intersects(AiConflictKey other);
}

final class AiJournalEntry {
  final String executionId;
  final String processId;
  final String accountKey;
  final String operationId;
  final Set<AiConflictKey> writeKeys;
  final Set<AiConflictKey> dependencyKeys;
  final String payloadSha256;
  final String releaseName; // prepared 時寫入
  final AiJournalState state;
  final int sequence;
}

final class AiJournalMutation {
  final AiJournalEntry entry;
  final bool budgetRefunded;
  final bool confirmMarkRestored;
}

final class AiWriteJournal {
  static final AiWriteJournal instance = AiWriteJournal._();
  String get processId;
  DateTime Function()? now; // 測試注入

  int proposalEpoch(String accountKey);
  void bumpProposalEpoch(String accountKey);
  bool tombstoneFlag(String accountKey);
  void noteTombstoneSet(String accountKey);
  void noteTombstoneCleared(String accountKey);

  Future<AiJournalKeyStatus> keyStatus(String accountKey);
  Future<void> ensureInitialized(String accountKey); // 只在 uninitialized

  Future<AiJournalMutation> prepare({required AiJournalDraft draft});
  Future<AiJournalMutation> markDispatching({required String executionId});
  Future<AiJournalMutation> finish({required String executionId, required AiJournalState terminal});
  Future<AiJournalMutation> revertDispatchingToNotExecuted({required String executionId});

  bool isolated(String accountKey, Set<AiConflictKey> keys);
  Future<void> recordObservation({required String executionId, required String summary});
  Future<void> releaseByUser({required String executionId, required String typedName});

  Future<AiBudgetHold?> tryReserve(AiBudgetRequest request); // null = 拒絕
  Future<void> refund(AiBudgetHold hold);

  Future<void> recoverAfterAccountsLoaded(Iterable<String> accountKeys);
  Future<AiJournalReset> beginReset(String accountKey);
  Future<void> completeReset(AiJournalReset reset, {required String typedUsername});

  AiRemovalJob beginRemoval(String accountKey);
}

final class AiRemovalJob {
  final String token;
  void requestCancel();
  bool get cancelRequestedBeforeFinalConfirm;
  bool holds(String token);
  void release(String token);
}
```

`dispatching → notExecuted` 只有 `revertDispatchingToNotExecuted` 做得到，而且與退回預算、恢復待確認標記同一次原子更新（§7.3 第 4.4 步）。重啟時，`processId` 不同的 `prepared` 改 `notExecuted`，`dispatching` 改 `writeUncertain`；本程序的明細不改。恢復完成前 `prepare` 拒絕。

**依賴：** 與封包 1、3、4 並行開發（新檔 + 記憶體金鑰）。併入 `SecureAiStore` 時排在封包 1 之後。不依賴寫入 port。

**測試：** §15 第 3 列全文；第 19 列的計數、1 MiB、2,000 列、`prepared` 退回不消耗計數；第 31 列裡重設標記的步驟中斷與 24 小時標記（移除流程的 UI 等待在封包 9，這裡提供 token 與「移除開始」序號）。用可控時鐘，不睡 7 天。

**UI／邏輯：** 純邏輯。`releaseByUser` 與 `completeReset` 接收已經核對過的原始字串（不含 `isolated()` 的隔離字元）。設定頁按鈕與確認框由主導者呼叫這兩個方法。

---

## 封包 3 — 能力表、分級引擎、目標綁定與意圖詞

實作 §2 的範圍、目標綁定與 T1 意圖詞，§3 的 ledger 形狀與 T1／T2 列，§4.1 的五等級矩陣與固定確認清單，§4.4 的數字常數。T3、T4、硬底線以測試假列存在，不進模型的 tool spec。

**擁有的檔案**

- 新 `lib/core/ai/tools/write_ledger.dart`
- 新 `lib/core/ai/tools/write_tier.dart`
- 新 `lib/core/ai/tools/target_binding.dart`
- 新 `lib/core/ai/intent_lexicon.dart`（只讀 l10n 的封閉表）
- 24 語 ARB 裡的意圖詞、否定詞、條件詞，以及 `python3 tool/l10n.py` 產生的對應片段

**不要碰**

`tool_catalogue.dart`、`gitlab_read_port.dart`、`gitlab_api.dart`、`redaction.dart`、`runner.dart`、聊天頁、ARB 裡意圖詞以外的 key、`aiReadOnlyPromise`。

**公開 API**

```dart
enum AiScopeKind { project, workItem, mergeRequest, groupWorkItem, accountGlobal }

final class AiWriteScope {
  const AiWriteScope({required this.accountKey, required this.grants});
  final String accountKey;
  final List<AiScopeGrant> grants;
  bool get allowsWrites;
}

final class AiScopeGrant {
  final AiScopeKind kind;
  final int? projectId;
  final String? projectPath;
  final int? iid;
  final String? groupFullPath;
  final int? groupId;
}

enum AiFixedConfirmReason {
  markAllTodosDone,
  foreignDraftsInPublish,
  massMention,
  externalMediaInRenderedMarkdown,
  foreignClosingOrCrossProject,
  duplicateOfSettledWrite,
  wholeFieldDropsHiddenSpans,
  headMovedSincePreview,
  confirmMarkAfterManualRelease,
  journalResetWindow,
  confidentialOrVisibilityMix,
  targetUnbound,
  intentNotUnique,
}

final class AiTierDecision {
  final AiGateDecision decision; // deny | requireApproval | execute
  final AiWriteTier tier;
  final bool requiresTypedName;
  final String? typedName;       // 前置讀取提供；沒有則不可提議
  final List<AiFixedConfirmReason> reasons;
}

abstract interface class AiCapabilityLedger {
  AiCapability? find(String operationId);
  List<AiCapability> get modelVisible; // MR6b-1 只有已實作的 T1／T2
}

AiTierDecision decideTier(AiTierInput input);

AiBindingResult bindTargets({
  required String userMessage,      // 本程序送出的原文，不含 context／投影
  required bool restoredFromHistory,
  required AiWriteScope scope,
  required List<AiTargetRef> targets,
  required String interfaceLanguage,
  required List<String> deviceLanguages,
});
```

`groupWorkItem` 這個 kind 現在就放進 `AiWriteScope`，MR6b-1 沒有對應工具，閘門對它 `deny`。`accountGlobal` 給 `markTodoDone`。生產 ledger 的 operation id 與封包 5 的具名方法一一對應，另加 `upload_attachment`。假列只在 `test/` 建構。

固定確認清單的 id（含尚未實作的 `markAllTodosDone`）寫在 `AiWritePolicy.fixedConfirmOperationIds` 的來源常數裡，讓封包 1 的 hash 與這裡用同一份清單。這份常數放在 `write_ledger.dart`，封包 1 的 `aiConsentContractFor` 讀它。因此封包 1 的 hash 測試在封包 3 合併後補上「清單內容進 hash」；封包 1 先用注入的 `AiWritePolicy` 測 hash 穩定性。

**依賴：** 與封包 1、2、4 並行。ARB 只有本封包能在這一波改。封包 7 消費 `decideTier` 與 `bindTargets`。

**測試：** §15 第 8 列用假列跑完五等級 × 各層級，含重跑／播放「只確認、不輸入名稱」、bypass 未綁定改確認、固定確認清單在 bypass 下仍要確認。第 16 列的 T1 方向、否定詞、引用、條件句、多專案 `#iid`、從紀錄恢復的訊息不建立 T1 授權、一般字詞不綁定。第 10 列裡「無範圍對話不提供寫入工具」與「群組頁上的專案議題得到專案 key」的純函式部分。第 15 列的意圖詞 24 語齊全，以及其他 operation 沒有意圖詞。

**UI／邏輯：** 純邏輯。卡片上的「你的要求」與「AI 的說明」由主導者畫；這裡只提供使用者原文與已遮蔽的 `reason` 文字。

---

## 封包 4 — §5 文字處理與外送上傳路徑

實作 §5 全文，以及 §3.1 裡送給 provider 的遮蔽、可還原 `[[upload:u-<n>]]`、`[[attachment:att-<n>]]` 的位置規則。`parseProjectUpload`（`lib/shared/attachment_ref.dart`）維持只給畫面開啟附件，本封包不呼叫它。

**擁有的檔案**

- 新 `lib/core/ai/write_text.dart`
- 改 `lib/core/ai/redaction.dart` 的外送路徑（`Redactor`）
- 使用既有 `neutralizeForGitLabDraft`（`lib/core/ai/quick_actions.dart`），不放寬它的後置條件

**不要碰**

`attachment_ref.dart`、`markdown_view.dart`、`gitlab_api.dart`、`runner.dart`、ARB、寫入 port。畫面顯示的 Markdown 維持原權限。

**公開 API**

```dart
enum AiTextClass { quickActionMarkdown, plainContent } // (A) / (B)

final class AiFieldProvenance {
  final AiConflictKey resourceKey;
  final String fieldName;
  final bool completeValue; // 截斷、excerpt、摘要、restoreFromDisplay 為 false
}

final class AiTextOutcome {
  final String? finalText; // null 表示 policyBlocked，mutation 次數必須為 0
  final bool policyBlocked;
  final List<AiFixedConfirmReason> confirmReasons;
  final int hiddenSpanCount; // 整欄寫回會刪掉的段數
  final String blockedReasonCode;
}

AiTextOutcome prepareWriteText({
  required AiTextClass textClass,
  required String modelText,
  required AiFieldProvenance? field,
  required UploadPlaceholderTable placeholders,
  required Set<String> knownSecrets,
  required bool aiAttribution,
  required AiVisibilityContext visibility,
});

final class UploadPlaceholderTable {
  static const maxEntries = 1000;
  String redactOutgoing(String text, {AiFieldProvenance? field});
  AiTextOutcome restoreIntoSameField(String text, AiFieldProvenance field);
}

final class AttachmentSubstitution {
  AiTextOutcome substitute(String text, {required bool sameProjectClassA});
}
```

處理順序依 §3.1：先 quick action 中和，再替換 `[[attachment:…]]` 與還原 `[[upload:…]]`，然後對最終文字重做 §5 第 1–6、9 點，只判定不改寫。秘密掃描看完整 payload。精確片段的「只掃 `new`」留介面，MR6b-2 的 `edit_file` 才傳片段；本封包的 MR6b-1 呼叫端都是整欄。

**依賴：** 與封包 1、2、3 並行。`AiFixedConfirmReason` 若尚未落地，本封包先用同名的本地 enum，合併時改 import 封包 3，避免兩份清單。reason code 字串（「請重新讀取這個欄位後再提議」「這個欄位太長，AI 無法完整編輯」「請在畫面上自行貼上」）由主導者寫進 l10n，本封包回傳 code。

**測試：** §15 第 14 列。第 23 列裡外送 secret、截斷、來源文字裡的佔位字串、`parseProjectUpload` 對其他專案仍為 null。第 32 列裡議題描述、MR 描述與留言的往返；Release、里程碑、片段描述的還原函式在這一層就接受對應的 `AiFieldProvenance`，測試標成 MR6b-2 才掛上真實工具（§14 把第 32 列的那三類劃給 MR6b-2）。第 32 列的跨欄位、他主機、1,000 筆上限、整欄刪除隱藏段，在本封包用字串 fixture 證明。

**UI／邏輯：** 純邏輯。預覽要顯示的是 `finalText`，由主導者畫在卡片上，且不得用會自己抓外部圖片的 `MarkdownView`（§11）。

---

## 封包 5 — T1／T2 寫入 port、具名包裝、401 與上傳逾時

實作 §3 的 T1／T2 REST 列、§3.1 的 `uploadProjectFile` 送出逾時、§7.4 的 REST 送出邊界形狀、§7.5 的 REST 結果分類與 mutation 401。port 做歸屬驗證、欄位白名單、前置讀取與一次 mutation；日誌與接受點由封包 7 包在外面。

**擁有的檔案**

- 新 `lib/core/ai/tools/gitlab_write_port.dart`
- 改 `lib/core/workspace_api.dart`（具名包裝與既有方法的欄位白名單）
- 改 `lib/core/gitlab_api.dart` 的 `_send`（約第 403–416 行那兩條 401 路徑）與 `uploadProjectFile` 的選填 `Duration? sendTimeout`
- 擴充 `tool/tests/test_ai_boundaries.py`：`gitlab_write_port.dart` 是第二個、也是最後一個 `gitlab_api.dart` importer；write-port 成員白名單逐一列出

**不要碰**

GraphQL 寫入方法的簽章、`runner.dart`、`redaction.dart`、聊天頁、`boards_page.dart` 以外的畫面（畫面改接是封包 6）、ARB、日誌。

**具名包裝（新的；既有的 `createNote`、`updateNote`、`createIssue`、`updateIssue`、`createMergeRequest`、`updateMergeRequest`、`addAwardEmoji`、`removeAwardEmoji`、`setStar`、`setSubscribed`、`markTodoDone`、`uploadProjectFile` 加上白名單或列舉檢查）**

`unapproveMergeRequest`、`createTodo`、`createDiscussion`、`createDiscussionNote`、`updateDiscussionNote`、`setDiscussionResolved`、`createDraftNote`、`updateDraftNote`、`createLabel`、`updateLabel`、`createMilestone`、`updateMilestone`、`setMilestoneState`、`createBoard`、`renameBoard`、`setBoardSystemListHidden`、`createBoardList`、`moveBoardList`、`moveBoardCard`。

`createNote` 的 `resource` 只接受 `issues` 與 `merge_requests`。`createIssue` 的 `issue_type` 只接受 `issue`、`task`、`incident`；`updateIssue` 不送 `issue_type`，也不送 `due_date`。刪除、`publishDraftNotes`、片段、registry、分支、tag、Release 的包裝不在本封包。

`uploadProjectFile` 新增 `sendTimeout`。畫面不傳，維持 dio 預設 15 秒。AI 使用 `max(15 秒, 檔案大小 ÷ 128 KiB/s)`，上限 4 分鐘，常數放在 write port。

`_send` 在 refresh 成功但不重放寫入時，維持 `FailureKind.writeUncertain` 並帶 `status: 401`。refresh 本身丟出例外時，保留這次 mutation 的 HTTP 401。PAT 或 refresh 回傳失敗仍走 `ApiFailure.fromStatus`，kind 維持 `unauthenticated`。畫面既有文案繼續看 kind。

**公開 API**

```dart
final class AiWriteRequest {
  final String operationId;
  final String executionId;
  final AiWriteScope scope;
  final Map<String, Object?> arguments; // 已由 port 拒絕未知鍵
  final List<int>? uploadBytes;         // 只給 upload_attachment；呼叫端已解析附件 ID
  final Duration? sendTimeout;
}

sealed class AiWriteOutcome {
  final int mutationCount; // 0 或 1
}

final class AiWriteNotSent extends AiWriteOutcome {}
final class AiWriteSettled extends AiWriteOutcome {
  final AiJournalState state; // succeeded | failedCertain | writeUncertain
  final int? httpStatus;
  final String resultCode;    // refreshSucceeded | sessionExpired | …
  final String releaseName;
  final Set<AiConflictKey> writeKeys;
  final Set<AiConflictKey> dependencyKeys;
  final Map<String, Object?> projection; // 欄位白名單，不含上傳 url／markdown
}

abstract interface class AiGitLabWritePort {
  Future<AiWritePrepared> prepare(AiWriteRequest request);
  Future<AiWriteOutcome> commit(
    AiWritePrepared prepared, {
    required bool Function() mayStart,
  });
}
```

`commit` 在 `mayStart()` 回 true 之後，下一個動作就是具名方法呼叫，中間沒有 `await`。`mayStart` 回 false 時 `mutationCount == 0`，結果是 `AiWriteNotSent`。401 的 `httpStatus` 在這裡轉成 `failedCertain`，不上鎖。

**依賴：** 封包 3 的 operation id 與 `AiConflictKey`。可與封包 4、封包 8 的記憶體附件並行。`test_ai_boundaries.py` 的版本斷言若封包 1 已改過，本封包只加 importer 與白名單。

**測試：** §15 第 5 列的 REST 分類與真實 `_send` 401 三條路徑（PAT／refresh 失敗、refresh 成功不重放、refresh 丟例外；mutation 201 之後 readback 401 仍為狀態未知）。第 10 列的白名單負向測試。第 13 列的「write port 是唯一新增 importer、只呼叫白名單」。第 21 列的新包裝固定 path。第 23 列的慢速上行：1 MiB/s 送 20 MiB 在新逾時內成功。第 29 列裡「`mayStart` 與 mutation 之間沒有 await」用替身斷言呼叫順序。

**UI／邏輯：** 純邏輯。`editor.dart` 現有的使用者上傳繼續呼叫 `uploadProjectFile` 且不傳 `sendTimeout`。

---

## 封包 6 — 既有畫面改接 T1／T2 具名方法

實作 §3「畫面改用」裡屬於 T1／T2 的呼叫點。行為與欄位維持現狀，只是不再直接呼叫通用通道。這不是視覺改版。

**擁有的檔案**

- `lib/features/workspace/comment_editor.dart`（`createNote`）
- `lib/features/workspace/discussions_tab.dart`（新增、編輯、討論回覆、resolve；刪除留在 `removeRecord`）
- `lib/features/workspace/diff_page.dart`（行內 `createDiscussion`、`createDraftNote`、回覆、resolve）
- `lib/features/workspace/draft_review_page.dart`（草稿新增與編輯；刪除與 `bulk_publish` 留著）
- `lib/features/workspace/work_item_page.dart`（`updateIssue`／`updateMergeRequest`、`createTodo`、`unapproveMergeRequest`；刪除留著）
- `lib/features/workspace/boards_page.dart`（建立、改名、系統欄隱藏、清單新增與排序、卡片移動；刪除留著）
- `lib/features/workspace/project_more_page.dart` 的標籤與里程碑建立、編輯、關閉／重新開啟

`reactions.dart`、`setStar`、`setSubscribed` 已經走具名方法，本封包只在 ledger 測試裡把它們標成已對應。

**不要碰**

`snippets_page.dart`、`registries_page.dart`、分支／tag／Release 的 `writeRecord`、任何刪除、`publishDraftNotes`、`gitlab_write_port.dart`、AI 聊天頁、方法簽章（封包 5 擁有）。

**公開 API：** 無新的公開型別。畫面呼叫封包 5 的具名方法。

**依賴：** 封包 5 合併之後。可與封包 7、8 並行。

**測試：** §15 第 21 列。每個 `lib/` 寫入呼叫點要嘛對上 ledger 列，要嘛列在測試裡的「待 MR6b-2」或「待 MR6b-3」清單。待 MR6b-2 至少包括：片段全部、registry 刪除、分支／tag／Release、檔案 `saveFile`／`deleteFile`、合併／核准／rebase、Pipeline 與 Job、草稿刪除與 `bulk_publish`、留言／議題／MR／看板／標籤／里程碑的刪除。待 MR6b-3 是 GraphQL 寫入。清單以外不得再有 `writeRecord`／`removeRecord`／`writeEmpty`／`graphMutation: true`。

**UI／邏輯：** 呼叫點替換，版面不動。確認框仍用現有的 `confirmAction`。

---

## 封包 7 — 政策閘門、提議、協調、awaitingApproval 與續跑

把封包 1–5 接上 `AiRunner` 與 `AiChatController`。實作 §7.1–§7.3、§7.5 的同輪 fail-stop、§7.7、§9，以及 §4.4 在送出前的原子保留。§7.8 的「head 已變更」狀態機留欄位，合併工具在 MR6b-2 才會寫入它。

**擁有的檔案**

- 新 `lib/core/ai/tools/write_coordinator.dart`
- 改 `lib/core/ai/runner.dart`（`_pendingRead` 擴成 `_pendingGitLab`；`runDeadline` 改為只計主動時間；等待確認時暫停）
- 改 `lib/core/ai/ai_display.dart` 的 `AiToolRunStatus`
- 改 `lib/features/ai/ai_history_codec.dart` 的紀錄格式版本（現在是 1，加 1）；不要動 `AiHistoryCipher` 的 envelope 版本
- 改 `lib/features/ai/ai_chat_session.dart` 的 `AiChatPhase` 與 `AiChatSession`
- 改 `lib/features/ai/ai_chat_controller.dart`、`ai_run_registry.dart`、`ai_runner_binding.dart`
- 改 `lib/core/ai/prompts.dart` 裡與寫入揭露有關、且 §10 允許先接上的 system 片段；`aiReadOnlyPromise` 的刪除留在主導者的整合提交

**不要碰**

`ai_chat_page.dart` 的版面、`ai_settings_page.dart`、`ai_consent_dialog.dart`、`gitlab_api.dart`、Android／iOS 原生、`tool/bootstrap.py`。前景檢查用注入的 `bool Function() appInForeground`，MR6c 再接原生許可。

**公開 API**

```dart
enum AiGateDecision { deny, requireApproval, execute }

enum AiChatPhase { idle, preparing, running, awaitingApproval, stopping }

final class AiWriteProposal {
  final String executionId;
  final String operationId;
  final AiTierDecision tier;
  final String payloadDigest;
  final String previewText;
  final String userUtterance;
  final String modelReason;
  final DateTime expiresAt;          // 牆上時鐘 + 30 分鐘
  final int proposalEpoch;
  final int writePolicyRevision;
  final String consentHash;
  final int scopeRevision;
  final String releaseName;
  void invalidate();
}

abstract interface class AiWriteCoordinator {
  Future<AiWriteProposal?> propose(AiToolCall call);
  Future<AiWriteOutcome> approve(AiWriteProposal proposal, {String? typedName, String? editedText});
  Future<void> reject(AiWriteProposal proposal);
  Future<void> onAppBackground(); // 沒有許可的 run：停在接受點之前則 notExecuted
}

extension on AiChatSession {
  List<AiWriteProposal> get proposals;
  AiAutonomyLevel get autonomyLevel;
  Future<void> setAutonomyLevel(AiAutonomyLevel level); // 對話內，不得超過上限
}
```

`AccountAiRunRegistry.runningCount` 的計算要明確規定 `awaitingApproval` 算不算「執行中」。見文末未解問題。`release` 在有提議時保留 session（現在只看 `running`／`stopping` 與 `items`）。

同一輪只要有一筆寫入不是成功也不是「無變更」，後面的寫入 GitLab 次數為 0，reason code 是 `previousWriteIncomplete`。續跑時已進入 `dispatching` 或終態的執行不再呼叫 mutation，投影只有一行摘要（§7.7、§15 第 28 列）。

**依賴：** 封包 1、2、3、4、5。與封包 6 並行。附件 ID 的解析依賴封包 8 的 `AiAttachmentSession`；若封包 8 未到，`upload_attachment` 先回 `attachmentExpired` 的 code，合併後接上。

**測試：** §15 第 1 列（注入語料；T3 以上用假列）。第 4 列的停止、run 逾時、撤銷同意、client close、晚到結果的字串；切帳號的等待本體在封包 9，這裡提供「在途寫入的 Future 與終態寫入」。第 6 列。第 7 列（可控時鐘：29／31 分鐘、調低等級後重判、拒絕後保留使用者改過的文字在 proposal 物件上）。第 12 列。第 17 列（讀取 20 秒 soft timeout 仍在；寫入第 21 秒回真實結果；11:59 主動 + 29 分鐘等待後只剩 1 秒）。第 18 列。第 19 列裡「提議時保留不到 HTTP 額度就不產生提議」。第 28 列用合成續跑，不啟動前景服務。第 29 列的 flush barrier。

**UI／邏輯：** 邏輯。`AiChatPage` 目前用 `phase == idle／running／stopping` 判斷，新的 `awaitingApproval` 不會讓它編譯失敗，但也不會畫出卡片。`canSend` 在此階段必須為 false。卡片、常駐「停止」、稽核列由主導者讀 `proposals` 來畫。

---

## 封包 8 — 附件工作階段與 upload_attachment

實作 §3.1 的記憶體生命週期、容量、附件 ID，以及「模型只能提交本段對話的附件 ID」。bytes 不進 prompt、聊天紀錄與日誌。上傳的 HTTP 呼叫走封包 5 的 port。

**擁有的檔案**

- 新 `lib/features/ai/ai_attachment_session.dart`
- 新 `lib/core/ai/tools/attachment_budget.dart`（純容量帳）

**不要碰**

`ai_chat_page.dart`（按鈕與附件列是主導者的）、`attachment_picker.dart` 的讀取契約（沿用 `AttachmentPicker`、`readLimitedAttachment`、`discardPickedCopy`）、`redaction.dart`（呼叫封包 4）、`gitlab_api.dart`。

**公開 API**

```dart
final class AiStoredAttachment {
  final String id;          // att-1
  final String filename;    // 通過 projectUploadNamesOk 的原文
  final int size;
  final String? mediaType;
  final String sha256;
  List<int> get bytes;      // 只給 write port
}

final class AiAttachmentSession {
  static const maxCountPerConversation = 10;
  static const maxBytesPerConversation = 50 * 1024 * 1024;
  static const maxBytesPerProcess = 100 * 1024 * 1024;

  Future<AiAttachResult> reserveAndRead({required AttachmentPicker picker, required bool uploadToolInSegment});
  void remove(String id);             // 釋放保留，並使尚未 dispatch 的提議作廢
  void discardAll();                  // 對話結束、切帳號、程序語意上的丟棄
  AiStoredAttachment? lookup(String id);
  Map<String, Object?> metadataForModel(); // untrusted-data 區塊；不含 bytes
}
```

選檔前先原子保留。讀取上限是 `min(GitLabApi.maxUploadBytes, 對話剩餘, 程序剩餘)`。`uploadToolInSegment == false` 時 `reserveAndRead` 回 `disabled`。檔名裡的 `#iid` 與意圖詞不進封包 3 的 `bindTargets` 輸入。

**依賴：** 封包 4 的中繼資料區塊格式、封包 5 的 `uploadProjectFile` 逾時與結果分類、封包 2 的 conflict key `(account, project:<id>, upload, sha256)` 與解除名稱（檔名原文）。可與封包 6 並行。封包 7 在 `propose` 時呼叫 `lookup`。封包 9 在切帳號時呼叫 `discardAll`。

**測試：** §15 第 23 列除「外送 secret」已由封包 4 覆蓋的部分：容量、選檔前保留、讀取失敗釋放、切帳號與移除後 bytes 消失、picker 暫存副本刪除、非法附件 ID、同一 SHA-256 成功上傳改為確認、狀態未知以 SHA-256 隔離、重開後用日誌檔名解除、長檔名／emoji／RTL 不受方向隔離字元影響、public／internal 的警示 reason code（確認等級給卡片，自動等級給稽核列）。

**UI／邏輯：** 容量、ID 與丟棄是邏輯。附檔按鈕、附件列、本機縮圖、達上限時的停用說明是主導者的畫面，呼叫 `reserveAndRead` 與 `remove`。

---

## 封包 9 — 切帳號、登出與兩個移除入口

實作 §12.1 從 MR6b-1 起生效的等待，以及 §8「帳號移除」的固定順序。兩個入口今天都是 `confirmAction` 之後才 `clearSecureDrafts → clearAccountArtifacts → clearRecentProject → clearAiAccountData → session.remove`：`AuthenticatedApp._remove`（`lib/features/shell/authenticated_app.dart`）與 `login_screen.dart` 的移除按鈕。`_removing` 現在在第一個確認框之後才設。

**擁有的檔案**

- 新 `lib/features/ai/ai_account_removal.dart`（兩個入口共用的作業）
- 改 `lib/features/shell/authenticated_app.dart` 的 `_remove`、切換帳號與 `endSession` 按鈕
- 改 `lib/features/auth/login_screen.dart` 的移除與 `session.select`
- 在 `clearAiAccountData` 的 tombstone 流程裡加上日誌前置檢查（`lib/features/ai/ai_history.dart` 的 `_clearAccount` 與 `lib/features/ai/ai_account_cleanup.dart`）。只插入日誌步驟，不改 history 既有的 tombstone 契約

**不要碰**

寫入 port、分級引擎、聊天頁版面、前景服務。切換用的「立即切換」沿用 `confirmAction`，不另做新元件。

**公開 API**

```dart
final class AiAccountRemoval {
  static Future<AiRemovalResult> run({
    required Account account,
    required AiRemovalJob job,          // 封包 2，在任何對話框之前取得
    required Future<bool> Function(AiRemovalPrompt prompt) confirm,
    required Future<void> Function() waitForInFlightWrites,
    required void Function() requestCancelOnDispose,
  });
}

enum AiRemovalPromptKind { stopRuns, typeUsername, plainConfirm }

final class AiSwitchGuard {
  static Future<AiSwitchChoice> confirmSwitch({required int runningOrPending});
  // proceedAndWait | switchNow | cancel
}
```

順序依 §8：先取得 `AiRemovalJob`，再顯示停止框；停止框取消不增加 `proposalEpoch`；最後確認之前的頁面卸載會釋放保留；最後確認之後跑完清理，每個 await 只核對 token。`SessionController.remove` 返回後以 `accounts` 是否仍含該帳號判定結果。tombstone 旗標在 `setTombstone` 之前經 `AiWriteJournal.noteTombstoneSet` 設上。

切換與登出走 `AiSwitchGuard`，不走移除作業。使用者選「立即切換」時，在途寫入記 `writeUncertain`。A→B→A 之後，同一把 key 仍被日誌隔離擋住。

**依賴：** 封包 2 的 `AiRemovalJob` 與 tombstone 旗標、封包 7 的在途寫入等待、封包 8 的 `discardAll`。最後一個波次。

**測試：** §15 第 4 列的切帳號、移除、立即切換、A→B→A。第 29 列裡「flush 卡住時移除等待達上限、取消、epoch 遞增、恢復後 mutation 為 0」。第 31 列全文（兩個入口、token、Navigator 被釋放、`busy` 的 `session.remove`、history 為 `disabled` 時的 `SessionController` 通知、`clearAccountArtifacts` 失敗、重試清除改提示從帳號列表移除）。

**UI／邏輯：** 流程是邏輯，元件用現有的 `confirmAction(requiredText:)`。文案 key 由主導者的 l10n 提交提供；測試在 zh-TW 找那些句子。作業持有 token 期間停用切換、移除與 `endSession`，這是按鈕的 `onPressed: null`，不是新版面。

---

## 建議順序

```text
波次 A（並行）
  封包 1  同意與帳號紀錄 v2
  封包 2  日誌（新檔；併入 SecureAiStore 時排在封包 1 之後）
  封包 3  能力表、分級、意圖詞（這一波唯一能改 ARB 的封包）
  封包 4  §5 與上傳路徑遮蔽

波次 B（A 完成後，並行）
  封包 5  具名包裝、write port、401、送出逾時
  封包 8  附件工作階段（HTTP 部分等封包 5 的 uploadProjectFile）

波次 C（B 完成後，並行）
  封包 6  畫面改接具名方法
  封包 7  閘門、協調、runner、awaitingApproval、續跑

波次 D
  封包 9  切帳號、登出、兩個移除入口

波次 E（主導者，與 C、D 重疊但獨佔畫面檔）
  提議卡片、附檔列、設定頁、同意框、稽核列、中斷的寫入、手動解除
  以及刪除 aiReadOnlyPromise 的那一個整合提交
```

MR 合併條件：波次 A–E 都在同一條分支上，§14 為 MR6b-1 點名的 §15 列是綠的，gate 仍關閉。沙箱實寫與前景服務不在這次。

## 主導者要設計的畫面

這些檔案程式封包不要改版面：`ai_chat_page.dart`、`ai_consent_dialog.dart`、`ai_settings_page.dart`，以及新的卡片與稽核元件。

| 畫面 | 讀取的 API | 計畫 |
|---|---|---|
| 提議卡片、各層級預覽、輸入名稱 | `AiWriteProposal`、`prepareWriteText` 的 `finalText` | §2、§5 第 8 點、§7.2 |
| 附檔按鈕、附件列、本機縮圖 | `AiAttachmentSession` | §3.1 |
| 設定頁上限、起始等級、AI 標註 | `AiAccountRecord`、`effectiveCeiling` | §4.1、§5 第 7 點 |
| bypass：前景、完整帳號、輸入 `@username`、`local_auth` | 封包 1 的等級；裝置檢查沿用 app lock | §4.2 |
| 可寫等級的常駐標示與「停止」 | `AiChatSession.autonomyLevel`、既有 `stop()` | §4.2 |
| 稽核列 | 日誌一行摘要 + 由 instance／ID 組成的連結 | §7.7 |
| 「中斷的寫入」、觀察、手動解除 | `AiWriteJournal.releaseByUser`、`recordObservation` | §7.6、§8 |
| 重設寫入日誌 | `beginReset`／`completeReset` | §8 |
| 同意框寫入段落與兩個新類別標籤 | `AiWritePolicy`、`dataCategories` | §10 |

預覽與 `reason` 使用 MR6a 的不自動連網顯示。`MarkdownView(api: null)` 仍會載入外部圖片，不能直接拿來畫卡片（§11）。

通知文案、前景服務、原生許可是 MR6c，這一階段不要做。

## 未解問題與正文裡的衝突

1. **等待確認的提議要不要進日誌。** §7.2 寫待確認提議不進日誌，程序死亡後全部作廢。§3.1 又寫使用者在等待確認時移除附件，該提議作廢並記 `notExecuted`。§8 的 `notExecuted` 是 `prepared` 之後的轉移。建議：沒到 `prepared` 的作廢只成為 tool 結果「未執行」，不寫日誌；只有已 `prepared` 的上傳才在恢復時改 `notExecuted`。這需要擁有者拍板，否則封包 2 與封包 8 會各做一套。

2. **401 的 kind。** §7.5 說「這兩條路徑」的 kind 維持 `writeUncertain` 並補 `status: 401`。§15 第 5 列把路徑拆開：PAT 或 refresh 失敗沿用 `ApiFailure.fromStatus` 的 `unauthenticated`；refresh 成功但不重放才是 `writeUncertain` 加 `status: 401`；refresh 丟例外時保留原本的 401。現況在 `gitlab_api.dart` 約第 416 行：refresh 成功後對非 GET 丟出沒有 status 的 `writeUncertain`，失敗則落到 `fromStatus`。實作應照第 5 列，不要把 PAT 401 改成 `writeUncertain`，否則畫面既有文案會變。

3. **背景時是作廢還是暫停。** §7.3 第 4.4 步與 §15 第 29 列：沒有原生許可的 run 在同步重驗時已不在前景，記 `notExecuted`，不記狀態未知。§12.2（MR6c）說沒有前景服務時在下一個安全續點暫停，回前景由使用者續跑。兩者要這樣接：暫停發生在還沒進入送出邊界之前；已經卡在 flush 與同步重驗之間的那一次就是 `notExecuted`，續跑不得把同一張核准再送出去。封包 7 不要做成「背景之後自動重試同一筆」。

4. **`awaitingApproval` 算不算三個名額。** §12.1 最多 3 段同時執行。§12.2 說只剩等待確認時不佔 dataSync 額度。`AccountAiRunRegistry.runningCount` 現在把 `running` 與 `stopping` 算進去，`maxRunning` 是 3。計畫沒有寫等待確認的對話是否仍佔這 3 個名額。若不算，三個在等確認時第四段可以送出。封包 7 動手前要定這條。

5. **上限改變要不要開新 segment。** §9：上限、範圍、目錄版本或政策語意變更後，下一次送出開新 segment；可寫等級之間調整目前等級，不改變凍結前綴。上限從 bypass 降到低風險自動時，工具清單可能完全一樣（兩種上限都看得到 T1／T2），但政策語意變了。建議只要 `writePolicyRevision` 增加就開新 segment，即使 tool spec 位元組相同。凍結前綴的「逐位元組不變」指同一段 segment 的生命期，不是兩段之間。

6. **§3 的「畫面改用」與 §14 的 MR 切分。** §3 把 `MetadataPage` 的分支、tag、Release、`snippets_page`、`registries_page` 與刪除寫在同一段。§14 把片段全部與 T3／T4 劃給 MR6b-2。以「該列在哪個 MR 交付，畫面就在那個 MR 改接」為準。封包 6 若把刪除也改接，會提前依賴尚未存在的包裝。

7. **第 32 列的欄位範圍。** §3.1 的可還原欄位包含 Release 說明、里程碑描述、片段描述。§14 要求 MR6b-1 只用議題、MR 描述與留言證明第 32 列，其餘在 MR6b-2。封包 4 應讓 `AiFieldProvenance` 認得那些欄位，但不要在 MR6b-1 註冊對應的寫入工具。

8. **GraphQL 掛鉤的落點。** §7.4 把 `beforeMutation`／`mayStart` 寫進執行模型，§14 把它們劃給 MR6b-3，並寫明掛鉤為 null 時畫面行為不變。MR6b-1 不要為了「預留」去改那些方法的簽章。封包 5 的 `commit(mayStart:)` 就是 REST 的接縫，MR6b-3 再把同一個 `mayStart` 放進方法內部。

9. **日誌金鑰與 `AiStore` 的檔案衝突。** §8 要求金鑰與重設標記進入 secure inventory（`AiSecureInventory`、`SecureAiStore`，都在 `ai_stores.dart`）。封包 1 也要改這個檔的帳號紀錄。兩個人同時改會互相覆蓋。封包 2 先用獨立的 `AiJournalKeyStore`，inventory 接線排在封包 1 合併之後。

10. **移除保留與 cleaning。** §8 第 1 步寫明 `AiRemovalHold` 不是 `beginCleaning`，`AiHistoryCoordinator` 在 history 為 `disabled` 時會自動 reopen cleaning。封包 9 若誤呼叫 `beginCleaning`，會和「保留期間不發帳號紀錄通知」衝突。測試第 31 列已經覆蓋 history 為 `disabled` 時的通知，實作時保留與 cleaning 必須是兩套狀態。

11. **每次送出「寫入 ≤ 8」與每輪 4 個 tool call。** §4.4 說 8 是名目上限，實際取與 v5 較嚴者。`AiToolBudget.maxCallsPerTurn` 是 4、`maxCallsPerRun` 是 12。一個使用者送出可以跨多輪，所以 8 是整次送出的上限，不是單輪上限。封包 7 不要把 8 寫進 `maxCallsPerTurn`，也不要放寬 4 與 12。
