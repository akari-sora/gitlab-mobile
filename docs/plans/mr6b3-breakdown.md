# MR6b-3 breakdown v4（規劃，唯讀調查）

基準：`./repo` 的 `main`，HEAD `f9a275912401afafe981bfaa721026e3d7a1136e`；已含 MR6b-2、C1a 與本次所需快取前置合併。本文原始碼路徑均相對於 `./repo`，行號以此 HEAD 重核。父計畫 `docs/plans/ai-writes-plan-v6.md` 以其 §24 v6.10 為準；本文 §8 是待採用的修正案，未修改父計畫。拘束來源為 `refs/mr6b3-decisions.md` D1–D23，後決定優先，尤其 D18–D23 覆寫 v3 與 review 的相異建議。

本次只產出計畫與查核報告；未修改 `./repo`、git 狀態或產品，未讀 secrets／keys／private data，未執行 live API、Flutter 測試或建置。下述驗收均是未來各實作封包的要求，不能當作本次 PASS 證據。

## 本 breakdown 交付下列內容

- **15 個 operation／公開方法、14 個實體 mutation 送出位置、11 個家族封包**。兩個活動建立入口共用一個送出位置。逐方法清單見 §2.3；逐列分類、引數與固定 cap 見 §3、§4。
- 專案 WI 屬性、活動建立／回覆／刪除、表情、通知、事件單與待辦延後。**沒有任何整欄文字覆寫列**；移出部分只在 §7t 列範圍。群組工作全部留給 §7 的 MR6b-3g。
- D2 的 ledger boundary 分流、awaited `beforeMutation`、同步 `mayStart`、獨立 graph settle 與五態日誌契約，完整寫在 §2.2；不借 REST 的失敗分類。
- 同分支 **S0a → S0b → S0c**，逐段可分析／測試，最後合成一個 seams MR。其後各家族一小 MR；UI／l10n 完成後才由 P14 翻可見度；P15 做跨家族測試。
- catalogue 3→4、policy 2→3 在 P14 與可見度一起交付。REST 工具、前景服務與通知投遞不在本批。

v3 已確認正確的定址、grant→Project 選項 A、port revision 重讀、T1 意圖鍵、只刪自己留言、既有 preview、群組 deny 與小 MR 決定均保留。以下只修決定／審查要求及其必要相依。

## §0 Changes from v3

| 決定／finding | v4 變更 | 解決位置 |
|---|---|---|
| D18；Codex R3-C1 | 整欄文字族移出；現批只保留建立與自己的留言刪除，不把 port 讀取誤當 controller 文字安全接線 | §3、§5、§7t |
| D19；Codex R3-I3、Opus R3-I2(c) | 標籤族移出；不再宣稱現有 API 有免搜尋候選清單 | §7t、附錄 A |
| D20；Codex R3-I1、Opus R3-I2(a/b/d) | 15 列重算每個輸入與 L；表情獨立 readback 納入；指派固定 37 並限制新候選 ≤4、總數 ≤5；每家族先獨立計數，P15 再交叉核對 | §4、§5、§6 |
| D21；Opus R3-I1、Codex M1 | 寫出五態、noop 的合法 prepared→notExecuted、第五態任何結果、mayStart false 的 try 外拋錯契約、每個保留方法的 noop／hook／送出錨點 | §2.2、§2.3、§8 |
| D22；Codex R3-I2、Opus R3-I3 | S0a 建立全部空 part／rows／registry 介面；S0c 只做 adapter／注入／guard；實列由家族填入，三段沒有向後 import 或 part | §2.1、§6 |
| D15–D17、D23；Codex M2/M3、Opus M1/M2/M13 | 唯一 allowlist、兩個具名 snooze 查詢、15／14 inventory、opening 與 readback 同 maxPages、兩 hook 成對 | §2、附錄 A |
| D11、D23；Codex M4/M5、Opus M3–M6/M12 | stringList 三個分支、port 複合驗證；reopen 映射、Project.name、非動態 milestone enum、日期／權重清除、事件單原 revision、刪除空 expectedTarget | §2.1、§3.2、§4 |
| D6/D23；Codex M6、Opus M8/M14 | 上游查證 snooze filter；不使用未證明等價的 REST 後備；定位器連巢狀頁與 schema fallback 都計入；確定快取前置→S0c 順序 | §2.1、§4、§9 |
| D7/D23；Opus M7/M9–M11 | P14 擁有預算可見集合測試；UI 先合；保守 uncertain 寫入父計畫修正案；版本逐處判斷；harness 指派 S0a | §2.1、§6、§8 |

## §1 D1–D23 落實狀態

| 決定 | 本版約束 |
|---|---|
| D1、D16 | 群組、群組頁 origin、最小群組讀工具全部 3g；snooze 的 group／無 project target 在 port 拒絕，包含 accountGlobal；namespaceWorkItem 不開放（附錄 B）。 |
| D2、D21 | §2.2 全文＋§2.3 15 個入口；accepted 只由 mayStart true 產生；五態與合法日誌 API 分開寫。 |
| D3 | 接受點後所有 payload errors、401、取消、格式錯誤、未證實 readback 一律 writeUncertain，不放寬 failedCertain。 |
| D4 | 13 個 core 檔由 S0b 一次處理。沿用 v3 已揭露偏離：core 用兩個結構型別 callback，避免依賴 ai/tools；AiWritePrepared.graph 仍收 GraphHooks。 |
| D5、D12、D20 | §4 每列靜態 httpCap，最大 37；截斷拒絕；Project 取 grant、不額外 GET；指派總數 ≤5、新候選 ≤4；移出族不占本批 cap。 |
| D6 | 原已接受的 Q3/Q4/Q7/Q8/Q9/Q11/Q12 不變；Q1 由 D2/D4、Q2/Q6 由 D3、Q5 由固定 cap 落實；Q10 的公開語意證據見 §9。 |
| D7、D13、D22 | 順序單一 seams MR；一檔在同一階段只有一 owner；空檔、型別與測試相依先存在。版本升級由 P14 做，保留 v3 的 D7 偏離。 |
| D8 | 保留的留言刪除也採 REST _ownNote 的自己作者限制，prepare／dispatch 各驗；管理者刪別人留言也拒絕。 |
| D9 | T1 用 add／enabled；snooze 與 unsnooze 的方向由 operation 表達。 |
| D10 | §5 11 個家族小 MR，P8 與 P11 各含兩個密切相關列；沒有跨族共用檔改動。 |
| D11 | projectId＋iid、數字 noteId；GID／revision 留在 port，confirmName 留卡片；有 projectId 都讀可見度，僅 P13 F=0。 |
| D14 | locator／resolver S0a；core hooks／maxPages／snooze 查詢 S0b；registry adapter S0c。 |
| D15 | 附錄 A 全集合由 S0c 一次放行；家族不改 guard。 |
| D17、D23 | 一行小修已折入；非必要延伸列 §9 follow-ups，不作阻擋。 |
| D18、D19 | §7t 短範圍說明；不在本批設計被移出的能力。 |

## §2 波次 A：單一 seams MR

### §2.1 S0a → S0b → S0c：所有權、可建置性與驗收

三段同分支順序執行，**不並行**；每段 analyze／自己的測試綠才續下段，三段全部完成才合 seams MR。現有快取前置已在本次 HEAD；確定順序是「此 main → S0a → S0b → S0c adapter → 家族」。後續另有快取變更時，該變更 rebase 到 S0c，再重跑 adapter／競態測試，不能兩方同時改 registry。

**S0a：dispatch、純型別、分類表、主 port、共用 resolver／locator、所有空檔。**

| 唯一 owner S0a 的檔案 | 本段交付與相依封閉方式 |
|---|---|
| `lib/core/ai/tools/write_coordinator.dart` | boundary graph 路由與 §2.2 狀態機；_validArg、_argSchema 加 stringList，_prepareText.visit 加 scalar stringList 分支（現 `lib/core/ai/tools/write_coordinator.dart:2204`、`lib/core/ai/tools/write_coordinator.dart:2400`、`lib/core/ai/tools/write_coordinator.dart:1611`）。 |
| `lib/core/ai/tools/write_ledger.dart` | AiCapability.boundary，預設 REST；stringList enum；13 個 rows part 指示與空清單聚合一起建立（現 `lib/core/ai/tools/write_ledger.dart:186`、`lib/core/ai/tools/write_ledger.dart:240`、`lib/core/ai/tools/write_ledger.dart:284`）。 |
| `lib/core/ai/tools/gitlab_write_port.dart` | AiWritePrepared.graph 的 `Future<Object?> Function(GraphHooks hooks)`、graph dispatcher、獨立 _settleGraph；一次加全部已存在的 model imports、locator＋11 家族 part 指示。原 REST commit 與 _settle 維持（`lib/core/ai/tools/gitlab_write_port.dart:749`、`lib/core/ai/tools/gitlab_write_port.dart:764`）。 |
| `lib/core/ai/tools/graphql_write_hooks.dart`、`lib/core/ai/tools/graphql_write_classify.dart`（新） | 純 span／GraphHooks 與 §3.1 分類表；沒有 API import 或 client 參數。S0a 的 AI port／coordinator 明確 import 同提交已建立的純型別／分類檔；S0b 的13個 core API 檔不 import 它們，只收結構型別 callback。 |
| `lib/core/ai/ai_work_item_write_registry.dart`（新） | 純介面只由 S0a 定義：isActive(gid)、tryStart(gid, kind)→lease、settle(lease, result, revision)；result 區分未送／已確認／uncertain。port 建構子從本段就有可空注入槽；無 adapter 的相關 graph 路徑回 registryUnavailable，REST 不依賴它。 |
| `lib/core/ai/tools/gitlab_write_port_graphql_locator.dart`（新 part） | 共用 grant→Project→驗證 detail resolver，及數字 noteId→discussion／note 定位器；供 P9 回覆、P10 刪除、P11 表情使用，P13 不用 locator。詳見下文讀取注入。 |
| 11 個家族 port part、13 個 rows part（新，完整檔名見 §5 表） | **S0a 同一提交建立所有被引用檔案**。port stub 回 null；每個 rows stub 只有 part of 與 const 空 List<AiCapability>，聚合可編譯；此時沒有 namedMethod／schema／cap 實列。S0c 不碰這些檔；seams 合併後才交各家族填入。 |
| `test/ai/mr6b3_support.dart`、`test/ai/mr6b3_dispatch_test.dart`（新） | 共用 fake／HTTP 計數 harness 與五態／日誌測試；家族對 harness 只讀。 |

S0a 的 resolver／locator **不提前呼叫尚未放行的 `_api` 成員**。用現有 model 型別的窄 callback：`Future<WorkItemGraphDetail> Function(Project, int)`，以及回傳 WorkItemActivityPage／WorkItemDiscussionNotesPage 的 first／next／notesNext reader。stub 不提供 production reader，測試注入 fake；家族在 S0c 放行後才於自己的 port part 建 `_api.projectWorkItem` 等 closure。**不傳 API 物件、不傳泛用 request callback**；保留目前 guard 對 `_api` 逃逸的限制（`tool/tests/test_ai_boundaries.py:193`）。因此本段沒有等 S0c 才合法的新 API 呼叫。

resolver 以已授權 grant 的 projectId／projectPath 組 `Project(id: id, name: path, path: path)`；name 必填但不作授權（`lib/core/models.dart:187`）。`projectWorkItem` 在單次讀取驗 project(fullPath) 的 GID 數字 ID、path、唯一 iid 及 Work Item 歸屬（`lib/core/work_item_graphql_api.dart:797`、`lib/core/work_item_graphql_api.dart:822`、`lib/core/work_item_graphql_api.dart:1065`）。沒有額外 GET project。缺 path、ID 不符、過期 path、namespace 型別不符均拒絕。保留帳號／instance／generation 的 reader 綁定，不從模型收 GID。

S0a 驗收：所有 part／import 目標在本段已存在；空 rows 不觸發 named-method allowlist；stub 無可提議 graph 工具。`flutter analyze`、dispatch 測試、現有 ledger／boundary guard 應各自綠。五態測試用注入測試 ledger／fake closure，**不需 S0b 的 production hooks 或 S0c adapter**。允許必要的 model import 用現有 ignore: unused_import 模式（`lib/core/ai/tools/gitlab_write_port.dart:10`），不導入後段未建型別。

**S0b：13 個 core 檔的 15 入口 hooks、分頁上限與兩個 snooze 查詢。**

唯一擁有 §2.3 的 13 個 API 檔：state、status、dates、health、assignee、milestone、weight、activity、note_delete、note_reactions、notifications、incident、todo_snooze。各入口新增選填 `Future<void> Function()? beforeMutation`、`bool Function()? mayStart`；**兩者同給或同不給，runtime 驗證在任何讀取前完成**，不只靠 release 會移除的 assert。畫面不給兩者，沿既有路徑。

本段另擁有下列必要參數／固定查詢，家族不得補改 core：

| 項目 | 明確本段工作 |
|---|---|
| 指派 maxPages | workItemAssignees 的 opening 收上限並存 target；updateWorkItemAssignees 的 preflight、ack continuation、獨立 readback 全用同上限。AI 固定 1；畫面保留原 20。現 opening `lib/core/work_item_assignee_api.dart:189`、迴圈 `lib/core/work_item_assignee_api.dart:403`／`lib/core/work_item_assignee_api.dart:490`。 |
| 表情 maxPages | workItemActivityReactionAccess opening／target 與 setWorkItemActivityNoteReaction 的 preflight／readback 同上限，AI 固定 2；現三次讀取 `lib/core/work_item_note_reactions_api.dart:121`、`lib/core/work_item_note_reactions_api.dart:143`、`lib/core/work_item_note_reactions_api.dart:221`。 |
| 狀態／候選 | status 是不分頁的讀取（`lib/core/work_item_status_api.dart:148`），不虛構 maxPages。指派 autocomplete 只讀一頁；milestone choices 一次呼叫只讀一頁，port 不續頁。 |
| activity 隱藏重讀 | workItemActivity 與內部 reader 加 `allowLegacyFallback`，預設 true；AI 明傳 false，遇 controls schema 不支援即拒絕，禁止第一次讀取偷偷再讀 legacy query。現 `lib/core/work_item_activity_api.dart:1069`、`lib/core/work_item_activity_api.dart:1087` 是兩次實體讀取；continuation 已在 `lib/core/work_item_activity_api.dart:1078` 拒不支援。locator 每個 reader 限一次 logical read。 |
| snooze 歸屬查詢 | `pendingTodosForSnooze`、`snoozedTodosForUnsnooze`，兩個具名固定 GraphQL read，分別 `state: pending, isSnoozed: false/true`；支援 after、first:100、maxPages:4，最多 400 筆，必須看到完整終頁才可用（現限制 `lib/core/todo_snooze_api.dart:5`、舊 query `lib/core/todo_snooze_api.dart:32`）。 |

所有分頁在上限仍 hasNextPage、重複／缺 cursor、跨頁 actor／revision／owner 漂移均拒絕；接受前 notExecuted，接受後 uncertain。指派 ack 若第一頁未完整，maxPages:1 直接 uncertain，不另讀第 2 頁。新 snooze query 同一回應驗 currentUser.id、Todo GID、project{id fullPath}、targetType、targetEntity 的精確座標與 WI 自己的 project／namespace；不能只信外層 project，也不為補身份額外查一輪。使用既有 WI project／namespace 欄形（`lib/core/work_item_graphql_api.dart:12`）。伺服器 schema 缺欄即 unsupported／refuse。

S0b 新增 `test/ai/mr6b3_core_hooks_test.dart`、`test/ai/mr6b3_core_paging_test.dart`：15 入口、14 送出位置的 hook 順序、noop 不 hook、mayStart false 不送、預設畫面路徑、opening／ack／readback 分頁限制、activity fallback、兩個 snooze filter／after。驗收 `flutter analyze`、上述測試及現有 core 測試綠；AI rows 仍空，不依賴 S0c。

**S0c：registry adapter／注入、完整 guard、分階段 inventory。**

| 唯一 owner S0c 的檔案 | 本段交付 |
|---|---|
| `lib/features/workspace/work_item_status.dart` adapter 段 | 沿 WorkItemStatusWriteRegistry 的 isActive／terminal／start／settle（`lib/features/workspace/work_item_status.dart:48`、`lib/features/workspace/work_item_status.dart:64`）提供 S0a 介面轉接；不重定義介面。 |
| `lib/features/workspace/graph_work_items_page.dart` adapter 段 | 轉接 _DatesWriteRegistry（`lib/features/workspace/graph_work_items_page.dart:1858`）及 _HealthWriteRegistry（`lib/features/workspace/graph_work_items_page.dart:1972`）；保留 revision floor、未確認 terminal 與 health start 拒絕。 |
| `lib/features/ai/ai_chat_controller.dart` 綁定段 | 注入 account／instance／實際 API identity／generation 綁定的 adapter；維持有 projectId 的 _freshWrite 讀取。新列不在 legacy 目標讀取分支（`lib/features/ai/ai_chat_controller.dart:1162`），本批不能以此宣稱拿到整欄 currentFields／provenance。 |
| `tool/tests/test_ai_boundaries.py` read／guard 段 | 附錄 A 的完整集合一次加入；保持原集合與 generic-channel／import／API escape 防線；namespaceWorkItem 負面斷言。本段不改 catalogue regex。 |
| `test/ai/write_call_site_ledger_test.dart` inventory 段 | 把固定 universe 分成「本批 15 方法／14 sites」與「§7t 延後 3 方法／3 sites」。當前 pending＝本批集合減已交付 ledgerMethods；每個 graph site 以檔案＋所在方法映射到固定入口集合，兩個 create 入口全有 ledger 才算共用 site 已交付；未知 site 失敗。不能仍要求家族加入列後 pendingNamed 等於原 18 名稱。現問題錨點 `test/ai/write_call_site_ledger_test.dart:93`、`test/ai/write_call_site_ledger_test.dart:99`、`test/ai/write_call_site_ledger_test.dart:329`。 |
| `test/ai/mr6b3_seams_test.dart`（新） | adapter 在途／terminal、同 API 與異帳號隔離、F=1／F=0、allowlist 精確增量與 inventory 映射測試。 |

adapter 在 prepare 拒已存在的 UI 寫入；commit 以 tryStart 取得唯一 lease，方法前置讀取前讓畫面看見在途。settle 按未送／確認 revision／uncertain 傳回各原 registry，未確認不能偽裝 confirmed。lease 自己不與自己衝突，其他 UI 寫入仍被擋；取消／例外也以一次 settle 收尾。介面 key 的 GID 只在**已綁 API identity 的 adapter**內有效，不能建立跨 instance 全域 GID 表。S0a 可空注入在本段取得 production adapter，型別與建構子不回頭補。

S0c 驗收：`flutter analyze`、seams／ledger inventory／boundary guard 綠；production rows 仍空，adapter 測試注入 fake，驗收不依賴家族。S0a、S0b、S0c 檔案集合無交集；rows／family part 於 seams 合併後才交 §5 的 owner，後續 P14 再依 §6 接手可見度／版本段。**不碰 sealed preview 階層、日誌原始碼、target_binding／write_tier 的群組 deny、workspace_api 或讀工具。**

### §2.2 D2 完整送出邊界與合法日誌轉移（D21）

目前 coordinator 在 commit 前 markDispatching（`lib/core/ai/tools/write_coordinator.dart:1016`）；graph 列取消這個提前動作。由 `AiCapability.boundary = graph` 選 AiWritePrepared.graph，REST default 照舊。GraphHooks 由 S0a 建立並傳入 graph closure，core 入口只接兩個結構型別 callback。

一次 graph 方法呼叫的順序：

1. 方法完成所有輸入、owner／current、revision／permission 檢查與非 mutation 網路 preflight；**所有合法 noop 返回都在 hook 之前**。
2. awaited `beforeMutation` 在父計畫 §7.3 的 4.1–4.3：不連網的政策／epoch／隔離重驗 → 取得一次 send ticket → journal 臨界區重驗 → `markDispatching` 並等待 flush 成功。只有成功返回才進 hookReturned；graph 在此之前保持 prepared。
3. hook 返回後只准同步資料組裝、同步 owner/current 重驗與同步 onMutationSent。hook 插在既有最後同步檢查之後、onMutationSent 之前；若 callback 要再次驗 current，也只可同步。START callback 同步，沒有 await 空窗。
4. `mayStart()` 同步做父計畫 4.4 最終重驗，**只有 true 才設定 accepted=true**；之後緊接唯一 mutation 呼叫，不得 await、重試或改用另一傳送管道。把 mayStart 放在 mutation 的 try 外，其 false 必須在 try 外丟 cancelled 或該方法 `*Failure(mutationSent:false)`，不可被 catch 改包成已送失敗。false 後不得傳送、回報已送或再呼 callback。
5. span 的 accepted／呼叫順序是分類權威；方法回傳 mutationSent:false 不能推翻已 accepted。`_settleGraph(span, outcome)` 不進 REST _settle，不進 safeFailure。接受後即使 transport 自稱未送也保守 uncertain。

五態及終結矩陣如下。所有「退款」指 journal 寫入次數／hold；**不是退還已耗或已開始保留的 HTTP allowance**，現 coordinator 在第一個 pre-read 可開始後就保持扣款（`lib/core/ai/tools/write_coordinator.dart:677`）。

| span 狀態 | 定義與方法結果 | journal API／合法轉移 | 對外結果與後續 |
|---|---|---|---|
| notHooked | beforeMutation 未呼；正常返回且符合該列 noop 契約 | `finish(terminal:notExecuted)`，prepared→notExecuted；不消耗／不恢復尚未消耗的確認 marker | 對外 succeeded＋noChange:true、mutationCount:0，寫入額度退回，同輪可繼續。不能呼 finish(prepared→succeeded)。 |
| notHooked | 送出前失敗，或無 hook 卻返回非 noop／假 success | 同上 prepared→notExecuted | notExecuted，mutationCount:0，fail-stop；後者屬契約異常，不能當成功。 |
| hookFailed | beforeMutation 內失敗、沒有成功返回；mayStart 絕不可呼 | 若失敗發生在 mark 嘗試前，prepared→notExecuted 用 finish；若 mark／flush 嘗試失敗且持久化狀態未確定，保留現有 prepared／可能 dispatching 隔離與 hold，fail-stop，不另造非法轉移或宣稱退款成功 | mutationCount:0；存儲不確定須如實報 journalUnavailable／未完成收尾，不能解鎖後重送。若已確認是 dispatching，僅現有 revert API 可退到 notExecuted，且須 flush 成功才算完成。 |
| hookReturned（第五態） | hook 已成功返回，**未呼 mayStart**；其後方法任何正常結果或例外都屬異常 | `revertDispatchingToNotExecuted`：dispatching→notExecuted，退寫入次數並恢復 consumedMarks | notExecuted、mutationCount:0、fail-stop。正常返回也不能當 noop。D2 修正父計畫 §8 的條件見 §8。 |
| mayStartFalse | hook 成功、mayStart 呼過但 false；方法依上述 try 外契約中止 | 同一 revert API：dispatching→notExecuted，退款＋marker 恢復 | notExecuted、mutationCount:0、fail-stop；即使方法錯誤地返回，也不能視成功。 |
| pastAcceptance | mayStart true；mutation 正常成功且符合該列成功條件 | `finish(terminal:succeeded)`：dispatching→succeeded | succeeded、mutationCount:1；需要獨立 readback 的列必須已通過。 |
| pastAcceptance | 其他任何返回／拋錯：payload errors、401／其他 HTTP、cancelled、notApplied、格式錯、readback 失敗等 | `finish(terminal:writeUncertain)`：dispatching→writeUncertain | writeUncertain、mutationCount:1、隔離／確認規則照父計畫；不重送。 |

「五態」是 notHooked、hookFailed、hookReturned、mayStartFalse、pastAcceptance；表中對同一態依結果展開，沒有第六態。beforeMutation／mayStart 最多各一次；重複呼叫、先後逆序屬契約失敗，接受後統一 uncertain，接受前按已確認 journal 階段合法回滾。

日誌合法性已逐項對現碼：mark 只接受 prepared（`lib/features/ai/ai_write_journal.dart:806`），移除 marker 並加次數後 flush（`lib/features/ai/ai_write_journal.dart:820`、`lib/features/ai/ai_write_journal.dart:833`）；finish 只允許 prepared→notExecuted，或 dispatching→succeeded／failedCertain／writeUncertain（`lib/features/ai/ai_write_journal.dart:865`）。**本批 graph 不使用其中的 failedCertain**。dispatching→notExecuted 必須走 revert（`lib/features/ai/ai_write_journal.dart:900`、`lib/features/ai/ai_write_journal.dart:908`、`lib/features/ai/ai_write_journal.dart:915`），不能用 finish。_save 於磁碟寫入成功後才換 owner.data（`lib/features/ai/ai_write_journal.dart:584`、`lib/features/ai/ai_write_journal.dart:592`），不可只看 span 猜 flush 成功。

終結／revert 的 flush 失敗不能回報成功或已退款；維持磁碟 dispatching（若先前已落盤）及記憶體 uncertain／隔離，與現 finish 防線一致（`lib/features/ai/ai_write_journal.dart:878`）；不新增 journal transition，也不編輯 journal。既有 coordinator fresh.noChange 已採 prepared→notExecuted、對外 succeeded/noChange（`lib/core/ai/tools/write_coordinator.dart:998`），graph method 內 noop 要走相同雙層表示。

### §2.3 15 個保留入口、14 個送出點：hook 必須在最後 noop 之後

以下原始碼路徑皆為 `lib/core/` 下完整檔名；每列指出簽名、noop／最後檢查與送出點。B 表示 awaited beforeMutation；A 表示同步 mayStart。通則為「最後 noop／同步檢查 → B → 同步 callback／必要同步重驗 → A（try 外）→ 傳送」，B 後除 B 本身外無 await。現有方法沒有 callback 時不新造畫面 callback。

| 列／方法 | 目前簽名 | noop／檢查 → B／A 的具體落點 | 現送出點 |
|---|---|---|---|
| P2 updateWorkItemState | `lib/core/work_item_state_api.dart:71` | revision 三方比對 `lib/core/work_item_state_api.dart:82`；noop `lib/core/work_item_state_api.dart:94`，最終 current `lib/core/work_item_state_api.dart:97` 之後 B，再 A | `lib/core/work_item_state_api.dart:100` |
| P3 updateWorkItemStatus | `lib/core/work_item_status_api.dart:182` | noop `lib/core/work_item_status_api.dart:223`；owner `lib/core/work_item_status_api.dart:234` 後 B，在 START onMutationSent(started) `lib/core/work_item_status_api.dart:250` 前；A 在 START 區塊 `lib/core/work_item_status_api.dart:259` 後、try `lib/core/work_item_status_api.dart:263` 外 | `lib/core/work_item_status_api.dart:264` |
| P4 updateWorkItemDates | `lib/core/work_item_dates_api.dart:244` | noop `lib/core/work_item_dates_api.dart:270`；preflight／permission `lib/core/work_item_dates_api.dart:280`、`lib/core/work_item_dates_api.dart:300`、同步 current `lib/core/work_item_dates_api.dart:307` 後 B；onMutationSent 必填 `lib/core/work_item_dates_api.dart:249`（AI 空 closure），回呼 `lib/core/work_item_dates_api.dart:321` 後 A，放 try 外 | `lib/core/work_item_dates_api.dart:324` |
| P5 updateWorkItemHealthStatus | `lib/core/work_item_health_api.dart:175` | noop `lib/core/work_item_health_api.dart:222`，final owner `lib/core/work_item_health_api.dart:243` 後 B、callback `lib/core/work_item_health_api.dart:248` 前；A 在 callback catch 外、send try 外 | `lib/core/work_item_health_api.dart:254` |
| P6 updateWorkItemAssignees | `lib/core/work_item_assignee_api.dart:286` | fence `lib/core/work_item_assignee_api.dart:311`；noop `lib/core/work_item_assignee_api.dart:319` 後 B、callback `lib/core/work_item_assignee_api.dart:324` 前；A 在 try 外 | `lib/core/work_item_assignee_api.dart:326` |
| P8a updateWorkItemMilestone | `lib/core/work_item_milestone_api.dart:413` | noop `lib/core/work_item_milestone_api.dart:455`；final current `lib/core/work_item_milestone_api.dart:459` 後 B、callback `lib/core/work_item_milestone_api.dart:461` 前，再 A | `lib/core/work_item_milestone_api.dart:463` |
| P8b updateWorkItemWeight | `lib/core/work_item_weight_api.dart:156` | epoch／current `lib/core/work_item_weight_api.dart:174`；noop `lib/core/work_item_weight_api.dart:184` 後 B、callback `lib/core/work_item_weight_api.dart:187` 前，再 A | `lib/core/work_item_weight_api.dart:189` |
| P9a createWorkItemActivityComment | `lib/core/work_item_activity_api.dart:664` | 無 noop；入口 preflight `lib/core/work_item_activity_api.dart:675`／permission `lib/core/work_item_activity_api.dart:679` 完成，hooks 透傳共用段；current／consume `lib/core/work_item_activity_api.dart:953`、`lib/core/work_item_activity_api.dart:954` 後 B，再 A，try `lib/core/work_item_activity_api.dart:957` 外 | `lib/core/work_item_activity_api.dart:958` |
| P9b createWorkItemActivityReply | `lib/core/work_item_activity_api.dart:710` | 無 noop；preflight `lib/core/work_item_activity_api.dart:721`、anchor tuple `lib/core/work_item_activity_api.dart:740` 完成，再透傳同一共用段 B／A | 同上 `lib/core/work_item_activity_api.dart:958` |
| P10 deleteWorkItemActivityNote | `lib/core/work_item_note_delete_api.dart:102` | 無 noop；preflight `lib/core/work_item_note_delete_api.dart:110`、actor／note／current `lib/core/work_item_note_delete_api.dart:124`、consume `lib/core/work_item_note_delete_api.dart:132` 後 B，再 A，try 外 | `lib/core/work_item_note_delete_api.dart:135` |
| P11a setWorkItemActivityNoteReaction | `lib/core/work_item_note_reactions_api.dart:132` | fence `lib/core/work_item_note_reactions_api.dart:171`；noop `lib/core/work_item_note_reactions_api.dart:183` 後 B，再 A，try `lib/core/work_item_note_reactions_api.dart:187` 外 | `lib/core/work_item_note_reactions_api.dart:188` |
| P11b setWorkItemNotifications | `lib/core/work_item_notifications_api.dart:94` | noop `lib/core/work_item_notifications_api.dart:123`、current `lib/core/work_item_notifications_api.dart:125` 後 B，再 A，try `lib/core/work_item_notifications_api.dart:127` 外 | `lib/core/work_item_notifications_api.dart:128` |
| P12 setIncidentStatus | `lib/core/incident_api.dart:135` | preflight `lib/core/incident_api.dart:148`、字串 revision `lib/core/incident_api.dart:152`、noop `lib/core/incident_api.dart:155` 後 B，再 A | `lib/core/incident_api.dart:156` |
| P13a snoozeTodo | `lib/core/todo_snooze_api.dart:63` | 無 noop；正數 id／未來 until 驗證 `lib/core/todo_snooze_api.dart:64` 後 B，再 A | `lib/core/todo_snooze_api.dart:65` |
| P13b unsnoozeTodo | `lib/core/todo_snooze_api.dart:76` | 無 noop；正數 id 驗證 `lib/core/todo_snooze_api.dart:77` 後 B，再 A | `lib/core/todo_snooze_api.dart:78` |

START 未回報在 `lib/core/work_item_status_api.dart:255` 拋 mutationSent:false；因 B 已返回而 A 未呼，必是第五態回滾，不是 failedCertain。日期／健康／指派／milestone／weight callback 拋錯亦照 span 處理。S0b 不改共用活動建立段的既有 payload-errors uncertain 分類（`lib/core/work_item_activity_api.dart:991`）；只加 hooks 與上述讀取限制。

## §3 父計畫驗收矩陣列速查、分類與引數

### §3.0 共通定址與綁定

專案列 `scopeClass: workItem`、必填正整數 projectId＋iid；活動子資源再填正整數 noteId（回覆用 anchorNoteId）。coordinator 現已有 workItem→issue target 與 project/iid 定址（`lib/core/ai/tools/write_coordinator.dart:1906`）；scope 走 _coversIssue（`lib/core/ai/tools/target_binding.dart:238`），保留。同帳號 grant 與 projectWorkItem 共同證實目標，port 解析所有 GID；模型不收 workItemGid、targetGid、noteGid、expectedUpdatedAt 或 confirmName。

port prepare 取得 actor、身份、revision、permission／widget fence、最終 payload，產生 bindingDigest；dispatch 重跑 prepare，digest／writeKeys／releaseName 必須相同，否則 targetChanged（`lib/core/ai/tools/write_coordinator.dart:969`）。GID 僅作 server 別名；write key 用 `(account, project:<id>, workItem, iid)`，note 加數字 ID。所有現有 type／namespace／actor／readEpoch／一次性 target-consumption 防線保留。typed name 由卡片處理，T4 刪除輸入所屬 #iid；todo 的 releaseName 為 @username。

### §3.1 逐列過接受點分類表（S0a 擁有）

所有列：接受前確定拒絕→notExecuted；合法未 hook noop→journal notExecuted＋對外 succeeded/noChange；接受後只有下列成功條件可 succeeded，其餘全 writeUncertain。包括某些 API 把 errors 包成 validation、某些回傳 notApplied／mutationSent:false，都不能避過 span。現 REST 401→failedCertain 在 `lib/core/ai/tools/gitlab_write_port.dart:796`，graph 不使用。

| 列 | 合法 noop | 接受後 succeeded 的必要條件／證據 | 接受前主要拒絕 |
|---|---|---|---|
| P2 | state 已等於 event.result | 獨立 readback 同 id／state，`lib/core/work_item_state_api.dart:156` | revision／permission／state unsupported |
| P3 | noop＋mutationSent:false | success＋true，獨立 readback `lib/core/work_item_status_api.dart:332`，成功結果 `lib/core/work_item_status_api.dart:358` | stale fence／candidate 不在 allowedStatusIds；START 未回報走第五態 |
| P4 | applied＋false，請求級 noop | applied＋true，獨立 readback `lib/core/work_item_dates_api.dart:364` | validation、notApplied＋false、actor／permission |
| P5 | noop＋false | success＋true，獨立 readback `lib/core/work_item_health_api.dart:269` | WorkItemHealthEditFailure(false)、fence／owner |
| P6 | 同 assignee 集合 snapshot | 完整獨立 readback 集合與 multiplicity 相符，`lib/core/work_item_assignee_api.dart:372` | 選項／新候選／頁數不可驗、fence |
| P8a | 同 milestone 返回 before | 獨立 readback 同 desired、present，`lib/core/work_item_milestone_api.dart:518` | selection owner／binding／actor／permission |
| P8b | 同 own weight snapshot | 獨立 readback 同 own weight，`lib/core/work_item_weight_api.dart:234` | 非 int32、clear 衝突、epoch／fence |
| P9a | 無 | 新 note 的獨立 readback 同 body／作者／parent，`lib/core/work_item_activity_api.dart:1013` | locked、forbidden、body／身份無法驗證 |
| P9b | 無 | 同上且 replyId／anchor tuple 相符，同一 readback | anchorMismatch／權限／discussion 不完整 |
| P10 刪除 | 無；已不存在屬 noteMissing 拒絕 | 獨立 readback 驗 actor／parent，且明確 note:null，`lib/core/work_item_note_delete_api.dart:162`、`lib/core/work_item_note_delete_api.dart:188` | notOwnNote／noteChanged／noteMissing |
| P11a | hasReaction 已等於 add | **獨立分頁 readback** 的 hasReaction 相符，`lib/core/work_item_note_reactions_api.dart:221` | reaction forbidden／fence／頁數 |
| P11b | subscribed 已等於 enabled | 獨立 readback subscribed 相符，`lib/core/work_item_notifications_api.dart:179` | conflict／forbidden／invisible |
| P12 | escalationStatus 已相同 | 同 id／status 的獨立 readback，`lib/core/incident_api.dart:210` | 非可寫 status、incident revision 字串不符 |
| P13a | 無 | 同 Todo GID 的 ack、可解析且符合請求 until 的 snoozedUntil，現 ack `lib/core/todo_snooze_api.dart:69` | ownership 查無／截斷／group／無 project、until 非未來 |
| P13b | 無 | 同 Todo GID 的 ack、snoozedUntil:null，`lib/core/todo_snooze_api.dart:83` | 同上，或未處於 snoozed pending 集合 |

P13 的成功等級是「mutation 已回應確認」，**不是獨立 readback 已確認**；它沒有 Mrb，也不額外調 snoozedTodos。ack 缺失／錯誤仍 uncertain，不能宣稱已接受後再降級為成功。snooze 方法目前只回 DateTime，P13 graph closure 要把回傳 UTC instant 與已正規化請求比較。

### §3.2 逐列引數、清除與省略語意

下表「座標」＝必填 projectId:integer、iid:integer；所有 boolean 方向保留顯式值，不採 truthy 轉換。`_validArg` 只驗單值；欄位互斥、必有其一、長度與集合限制由家族 port **在候選搜尋／mutation 前**驗證，不能宣稱單值 validator 處理整個物件。

| 列 | 模型引數（除座標） | 明確語意 |
|---|---|---|
| P2 | stateEvent:string req，enum close／reopen | 映射 WorkItemStateEvent.close／reopen 的 CLOSE／REOPEN；不是不存在的 open event（`lib/core/work_item_state_models.dart:5`）。 |
| P3 | candidateId:string req | 必須在 opening.allowedStatusIds 內；不是任意 target GID（`lib/core/work_item_status_api.dart:213`）。 |
| P4 | mode:string req manual／inherited；startDate／dueDate:string opt；clearStart／clearDue:boolean opt | 日期嚴格 YYYY-MM-DD；日期與對應 clear:true 互斥。manual 下省略保留已讀 manual snapshot 值，clear:true→null；由 inherited 切 manual 時兩欄各須顯式 date 或 clear，避免把計算值誤當 own 值。inherited 不接受日期／clear 欄位，只傳 isFixed:false。 |
| P5 | healthStatus:string req，onTrack／needsAttention／atRisk／none | none→desired:null；其餘轉既有 enum，不寫 roll-up。 |
| P6 | assigneeUsernames:stringList req | 原始項數 ≤5、項目非空且不可重複；[] 清除；精確 username，總數／新候選限制見 §4。 |
| P8a | milestoneTitle:string opt；clearMilestone:boolean opt | 恰有 title 或 clear:true，兩者互斥；title 可真的叫 none，沒有動態 enum／none sentinel。一次 choices 完整頁精確名稱唯一比對，採既有 selection／clearSelection。 |
| P8b | weight:integer opt；clearWeight:boolean opt | 恰有 weight 或 clear:true；省略兩者拒絕，0 是合法設定，不是清除。0..2147483647；clear→null（`lib/core/work_item_weight_api.dart:311`）。 |
| P9a | body:string req | 新建文字走既有 (A) 九點／placeholder／upload provenance 驗證，不覆寫欄位。 |
| P9b | anchorNoteId:integer req；body:string req | 以數字 note 定位，再驗 WI／discussion／note／createdAt tuple；不是模型填 discussion GID。 |
| P10 刪除 | noteId:integer req | 無 body 引數，prepare／dispatch 皆驗自己作者，無整欄寫入。 |
| P11a | noteId:integer req；name:string req；add:boolean req | add 轉 awarded，沿 intent_lexicon（`lib/core/ai/intent_lexicon.dart:108`）；emoji 名只作既有驗證。 |
| P11b | enabled:boolean req | 轉 subscribed，與意圖詞鍵一致（`lib/core/ai/intent_lexicon.dart:120`）。 |
| P12 | status:string req，TRIGGERED／ACKNOWLEDGED／RESOLVED | IGNORED 不可寫（`lib/core/incident_api.dart:24`）；port 必傳 incidentStatus 回應原始 updatedAt 字串，不能格式化 projectWorkItem 的 DateTime。 |
| P13a | **無座標**；todoId:integer req；until:string req | scopeClass:accountTodo；未來 UTC instant，歸屬從 currentUser 固定 query 驗證；沒有 expectedTarget 物件。 |
| P13b | **無座標**；todoId:integer req | accountTodo；不收 until；方向由 operation（`lib/core/ai/intent_lexicon.dart:126`）。 |

日期 API 的兩個 nullable 參數其實必填（`lib/core/work_item_dates_api.dart:247`）；manual payload 一次寫 startDate 與 dueDate（`lib/core/work_item_dates_api.dart:603`），因此 port 必先以 snapshot 補齊省略值並把**兩欄最終 payload**放入 preview／digest；dispatch 重新比對，不可把省略直接當 null。inherited payload 僅 isFixed:false（`lib/core/work_item_dates_api.dart:598`），不悄悄忽略使用者傳入日期。

事件單額外把 `incidentStatus(projectId,iid)['updatedAt']` 原字串加入 bindingDigest 並每輪重讀，對上方法直接字串比較（`lib/core/incident_api.dart:148`、`lib/core/incident_api.dart:152`）。這不是模型可覆寫欄位。T1 自動需本次訊息唯一 entry＋operation＋有效參數＋完整 typed target；否定／條件／引用／程式碼／相反方向轉確認，保留父計畫意圖測試。

## §4 HTTP 固定上限：每列公式、全部輸入、L 與來源（D20）

沿 MR6b-2 的獨立計數模式（`test/ai/mr6b2_budget_test.dart:15`、`test/ai/mr6b2_budget_test.dart:27`）：

`L = 2 × (F + P) + Mpre + Mrb`；`M = 1`；**固定 `httpCap = 2 × L + 1`**；PAT 實體上限 `L + 1`。F 是 controller 每輪 freshness 的 logical read；P 是 port 每輪 prepare 的全部 logical reads；兩倍涵蓋 proposal＋dispatch。Mpre／Mrb 是只執行一次的 mutation 方法內 preflight／獨立 readback。OAuth 每個 logical read 最多兩次（含一次刷新後重播），mutation 不重播。下表所有 L ≤18 ≤40，且更強的實體 httpCap ≤37 <40。

AiCapability.httpCap 是靜態整數（`lib/core/ai/tools/write_ledger.dart:269`），coordinator 在任何 freshness 前保留它（`lib/core/ai/tools/write_coordinator.dart:636`、`lib/core/ai/tools/write_coordinator.dart:657`）；PAT allowance 的換算在 `lib/core/ai/tools/write_coordinator.dart:2169`。不依本提案人數降低 ledger 數字，也不把最後拒絕當成較小 cap 的理由。beforeMutation 的 preflight／ticket／flush 不連網，沒有漏算其中的 API 呼叫。

### §4.1 全部 15 列的靜態表

F=1 的來源是 `_freshWrite` 專案 record（`lib/features/ai/ai_chat_controller.dart:1155`）；不是額外 target GET。P 的 `user` 是 currentUser 1 次（`lib/core/gitlab_api.dart:616`），`WI` 是 projectWorkItem 1 次（`lib/core/work_item_graphql_api.dart:805`）；`open`／`access` 各有下表來源。沒有任何未列的 record／搜尋／觀察呼叫。

| 列／operation | F | P：每輪所有輸入 | Mpre | Mrb | L 計算 | 固定 httpCap | PAT 上限 |
|---|---:|---|---:|---:|---|---:|---:|
| P2 updateWorkItemState | 1 | user1＋WI1＋state open1＝3 | 1 | 1 | 2×(1+3)+1+1＝10 | 21 | 11 |
| P3 updateWorkItemStatus | 1 | user1＋WI1＋status open1＝3 | 1 | 1 | 2×(1+3)+1+1＝10 | 21 | 11 |
| P4 updateWorkItemDates | 1 | user1＋WI1＋dates base1＋edition probe1＝4 | 2 | 2 | 2×(1+4)+2+2＝14 | 29 | 15 |
| P5 updateWorkItemHealthStatus | 1 | user1＋WI1＋health open1＝3 | 1 | 1 | 2×(1+3)+1+1＝10 | 21 | 11 |
| P6 updateWorkItemAssignees | 1 | user1＋WI1＋open1＋新 username 搜尋4＝7 | 1 | 1 | 2×(1+7)+1+1＝18 | 37 | 19 |
| P8a updateWorkItemMilestone | 1 | user1＋WI1＋open1＋choices1＝4 | 1 | 1 | 2×(1+4)+1+1＝12 | 25 | 13 |
| P8b updateWorkItemWeight | 1 | user1＋WI1＋weight open1＝3 | 1 | 1 | 2×(1+3)+1+1＝10 | 21 | 11 |
| P9a createWorkItemActivityComment | 1 | user1＋WI1＋writeAccess1＝3 | 1 | 1 | 2×(1+3)+1+1＝10 | 21 | 11 |
| P9b createWorkItemActivityReply | 1 | user1＋WI1＋locator2＋writeAccess1＝5 | 1 | 1 | 2×(1+5)+1+1＝14 | 29 | 15 |
| P10 deleteWorkItemActivityNote | 1 | user1＋WI1＋locator2＋deleteAccess1＝5 | 1 | 1 | 2×(1+5)+1+1＝14 | 29 | 15 |
| P11a setWorkItemActivityNoteReaction | 1 | user1＋WI1＋locator2＋reactionAccess2＝6 | 2 | 2 | 2×(1+6)+2+2＝18 | 37 | 19 |
| P11b setWorkItemNotifications | 1 | user1＋WI1＋notifications open1＝3 | 1 | 1 | 2×(1+3)+1+1＝10 | 21 | 11 |
| P12 setIncidentStatus | 1 | user1＋WI1＋incidentStatus1＝3 | 1 | 1 | 2×(1+3)+1+1＝10 | 21 | 11 |
| P13a snoozeTodo | 0 | user1＋pending ownership 最多4頁＝5 | 0 | 0 | 2×(0+5)+0+0＝10 | 21 | 11 |
| P13b unsnoozeTodo | 0 | user1＋snoozed ownership 最多4頁＝5 | 0 | 0 | 2×(0+5)+0+0＝10 | 21 | 11 |

P12 保留 WI 身份驗證，不能因已有 incidentStatus 就漏掉 WI1。P9a 沒有 locator；P9b 沒有額外 activity-list／獨立 anchor GET，locator 已含它；兩者不能照抄 v3 的 P=4／6。表情的 opening、方法 preflight、**獨立** readback 是三次各最多 2 頁，Mrb 絕不是 0。各列 clear／noop 路徑可較少讀，但保留同一固定 cap。

### §4.2 每個輸入的程式碼依據與 AI 限制

| 列／輸入 | 現碼 opening／preflight／獨立 readback 與大小 | 本計畫固定限制 |
|---|---|---|
| P2 | workItemState `lib/core/work_item_state_api.dart:38`，單 _read `lib/core/work_item_state_api.dart:44`；方法再讀 `lib/core/work_item_state_api.dart:79`，readback `lib/core/work_item_state_api.dart:156` | 各 1；無分頁 |
| P3 | workItemStatus `lib/core/work_item_status_api.dart:149`，方法前置 `lib/core/work_item_status_api.dart:205`、readback `lib/core/work_item_status_api.dart:332`；底層單讀 `lib/core/work_item_status_api.dart:397` | 各 1；候選在同回應 allowedStatusIds，不另搜 |
| P4 | workItemDates `lib/core/work_item_dates_api.dart:208`、方法讀 `lib/core/work_item_dates_api.dart:280`、readback `lib/core/work_item_dates_api.dart:364`；同 reader 的 base `lib/core/work_item_dates_api.dart:413`＋probe `lib/core/work_item_dates_api.dart:453` | 每次 reader worst case 2，不把 probe cache 當必然命中 |
| P5 | workItemHealthEdit `lib/core/work_item_health_api.dart:157`、方法前置 `lib/core/work_item_health_api.dart:197`、readback `lib/core/work_item_health_api.dart:269` | 各 1 |
| P6 | opening `lib/core/work_item_assignee_api.dart:189`、方法前置 `lib/core/work_item_assignee_api.dart:299`、readback `lib/core/work_item_assignee_api.dart:372`；頁大小100／原上限20／autocomplete20 筆在 `lib/core/work_item_assignee_api.dart:3`、`lib/core/work_item_assignee_api.dart:4`、`lib/core/work_item_assignee_api.dart:5`；候選單讀 `lib/core/work_item_assignee_api.dart:222`，ack 續頁 `lib/core/work_item_assignee_api.dart:490` | opening／preflight／ack／readback maxPages:1；最多4次候選搜尋／輪，非4頁搜尋；ack 第1頁不完整就 uncertain，不產生額外 read |
| P8a | opening `lib/core/work_item_milestone_api.dart:253`；choices `lib/core/work_item_milestone_api.dart:268` 單讀 `lib/core/work_item_milestone_api.dart:308`，pageSize50／總上限200 `lib/core/work_item_milestone_api.dart:118`；方法前置 `lib/core/work_item_milestone_api.dart:436`、readback `lib/core/work_item_milestone_api.dart:518` | choices 僅一頁50筆；hasNextPage 就拒，不呼 continuation；前置／readback 各1 |
| P8b | opening `lib/core/work_item_weight_api.dart:137`、方法前置 `lib/core/work_item_weight_api.dart:165`、readback `lib/core/work_item_weight_api.dart:234`，單 reader `lib/core/work_item_weight_api.dart:249` | 各 1；rolled-up value 不可寫 |
| P9a/b | writeAccess `lib/core/work_item_activity_api.dart:639`，內部前置 `lib/core/work_item_activity_api.dart:646`；方法前置 `lib/core/work_item_activity_api.dart:675`／`lib/core/work_item_activity_api.dart:721`；建立後獨立讀 `lib/core/work_item_activity_api.dart:1013` | 各1；回覆多的兩次讀取**只在 locator**；原 errors 分類不動 |
| P10 刪除 | deleteAccess `lib/core/work_item_note_delete_api.dart:62`→前置 `lib/core/work_item_note_delete_api.dart:76`；方法前置 `lib/core/work_item_note_delete_api.dart:110`；readback `lib/core/work_item_note_delete_api.dart:162` | access／preflight／readback 各1，另 locator≤2 |
| P11a | reactionAccess `lib/core/work_item_note_reactions_api.dart:107`→前置 `lib/core/work_item_note_reactions_api.dart:121`；方法前置 `lib/core/work_item_note_reactions_api.dart:143`；readback `lib/core/work_item_note_reactions_api.dart:221`；迴圈實讀 `lib/core/work_item_note_reactions_api.dart:265`、`lib/core/work_item_note_reactions_api.dart:267`；每頁50 `lib/core/work_item_note_reactions_api.dart:3` | 三階段各 maxPages:2；不是只限制更新方法 |
| P11b | workItemNotifications `lib/core/work_item_notifications_api.dart:77`，方法前置 `lib/core/work_item_notifications_api.dart:107`，readback `lib/core/work_item_notifications_api.dart:179`；單 reader `lib/core/work_item_notifications_api.dart:195` | 各 1 |
| P12 | incidentStatus `lib/core/incident_api.dart:94` 單讀 `lib/core/incident_api.dart:98`；方法前置 `lib/core/incident_api.dart:148`，readback `lib/core/incident_api.dart:210` | 各 1；Project 同 grant，不再查 project |
| P13a/b | 既有頁大小100 `lib/core/todo_snooze_api.dart:5`，現 query `lib/core/todo_snooze_api.dart:32` 尚無 after；既有方法只有 mutation ack `lib/core/todo_snooze_api.dart:69`、`lib/core/todo_snooze_api.dart:82` | S0b 新固定查詢每輪完整≤4頁；當前舊方法無歸屬查詢的能力不冒充現成；不呼觀察查詢／REST fallback／額外 target GET |

### §4.3 名稱與 locator 的 worst case（不是動態 cap）

**指派固定 37。** port 在任何網路前檢查原始陣列 ≤5、非空字串／長度符合既有搜尋驗證／不重複；opening 完整一頁後，精確對上目前 username 的使用者直接用 current IDs（既有說明 `lib/core/work_item_assignee_api.dart:206`）。其餘計 N；**N>4 在第一次搜尋之前拒絕**，N≤4 各呼一次 searchWorkItemAssigneeCandidates（必填 search，`lib/core/work_item_assignee_api.dart:209`）。只接受回應內精確且唯一 username；查無／不明確拒絕，不逐字重搜、不續頁、不猜 ID。五人提案只有至少一位已在目前集合才可進入，故總數5與新候選4同時成立。每輪 P=1+1+1+4=7；L=18、cap=37。空清除、單人、四個新名、五人含一舊名都用同一 ledger cap。五個新名不是以拒絕掩飾33，而是用37涵蓋所有被接受路徑，另在搜尋前拒絕超界路徑。

**locator 固定最多 2 次 logical read，三個 reader 共用同一計數器。** workItemActivity `lib/core/work_item_activity_api.dart:765`／workItemActivityNext `lib/core/work_item_activity_api.dart:780` 與巢狀 workItemDiscussionNotesNext `lib/core/work_item_activity_api.dart:796` **合計**≤2，不是外層兩頁再加內層兩頁。活動頁大小20（`lib/core/work_item_activity_api.dart:3`）；每次 reader 前先扣同一剩餘額度；AI disable legacy fallback，保證一次呼叫只一次讀取。要求完整可證的目標 discussion／note／parent tuple，遇剩餘分頁無法完整證明、找不到、重複、actor／revision 漂移或兩次已用完皆 activityUnverifiable／noteMissing，不以部分頁證不存在，也不走未計數的 anchor 補查。P9b、P10、P11a 都用這個限制。

未來若某列在必要 maxPages:1 後仍超40，整列不提議，不靠每提案拒絕縮小靜態 httpCap；本版15列無此情況。測試必包含 cap−1 拒絕、cap 可用、整段預算40邊界、OAuth 每讀401刷新重播與 mutation 不重播；所有拒絕仍按已開始的保留額度計帳。

## §5 波次 B：11 個家族封包（seams 合併後可並行）

每包只填自己的 port part／rows 與測試，**不得改 core、主 port、coordinator、registry、共用 harness、guard 或他族檔案**。所有實列 `boundary:graph`、`modelVisible:false`，P14 才開放。欄位與固定 cap 逐列依 §3／§4，不拿家族最大值代替較小列的獨立 cap。preview 只用既有 AiFieldsPreview／AiDeletePreview；reason codes 作結構資料，主導者統一翻譯。

下表 port 路徑前綴為 `lib/core/ai/tools/gitlab_write_port_graphql_`；rows 前綴為 `lib/core/ai/tools/ledger/rows_graphql_`；測試前綴為 `test/ai/`。表內每個尾名都是一個確切檔案；兩個 rows 尾名表示兩檔。

| 包 | port 尾名 | rows 尾名 | 測試檔 | 列／Tier／固定 cap |
|---|---|---|---|---|---|
| P2 | state.dart | state.dart | mr6b3_state_port_test.dart | 狀態 T2，21 |
| P3 | status.dart | status.dart | mr6b3_status_port_test.dart | 自訂狀態 T2，21 |
| P4 | dates.dart | dates.dart | mr6b3_dates_port_test.dart | 日期 T2，29 |
| P5 | health.dart | health.dart | mr6b3_health_port_test.dart | 健康度 T2，21 |
| P6 | assignees.dart | assignees.dart | mr6b3_assignees_port_test.dart | 指派 T2，37 |
| P8 | milestone_weight.dart | milestone.dart、weight.dart | mr6b3_milestone_weight_port_test.dart | 里程碑 T2，25；權重 T2，21 |
| P9 | activity_create.dart | activity_create.dart | mr6b3_activity_create_port_test.dart | 建立 T2，21；回覆 T2，29 |
| P10 | activity_delete.dart | activity_delete.dart | mr6b3_activity_delete_port_test.dart | 刪除 T4，29 |
| P11 | reactions_notifications.dart | reaction.dart、notifications.dart | mr6b3_t1_port_test.dart | 表情 T1，37；通知 T1，21 |
| P12 | incident.dart | incident.dart | mr6b3_incident_port_test.dart | 事件單 T2，21 |
| P13 | snooze.dart | snooze.dart | mr6b3_snooze_port_test.dart | 延後 T1，21；取消延後 T1，21 |

這正是 S0a 建立的11個家族 part＋13個空 rows part；兩個 create 共用 rows 檔、兩個 snooze 共用 rows 檔，P8／P11 各拆兩個 rows 檔，**15 operations 不等於15檔案**。S0a 在 seams 期間唯一擁有空檔，seams 合併後依本表一次交接，不經 S0c 填一半再交家族。

### P2 — Work Item 狀態

只寫 stateEvent，close／reopen 明確映射；保留三方 revision 檢查，不與自訂 STATUS 混同。codes：stateConflict、stateForbidden、stateNotApplied。測試 open→close、closed→reopen、noop、stale revision、foreign project／actor、accepted errors uncertain；獨立計數21。

### P3 — 自訂狀態與登錄

candidateId 必在 fresh allowedStatusIds；保留 START token 與 registry lease，與 UI 在途狀態互斥。codes：statusStaleFence、statusInvalidCandidate、statusNotStarted。測試 START 未回報觸發第五態並恢復 marker、candidate 漂移、notApplied＋true uncertain、獨立 readback；固定21。

### P4 — 日期

preview 顯示最終兩欄及 manual／inherited；省略與 clear 完全依 §3.2，保留 CE／EE 與 inherited 計算來源、actor、permission fence。codes：datesConflict、datesForbidden、datesNotApplied。測試兩次 edition probe worst case、切 manual 缺欄拒絕、clear、無效日期／次序、request noop 不 hook；固定29。

### P5 — 健康度

只更新 own health，none 是顯式清除，不更改 roll-up；health registry start 拒絕必須 notExecuted，不能吞掉。codes：healthConflict、healthForbidden、healthUnsupported。測試 nullable、noop、callback 拋錯第五態、UI／AI 互斥、已接受回應錯誤 uncertain；固定21。

### P6 — 指派

使用 opening 的 owner-bound target＋精確候選解析，保留 allowsMultiple、已知 ID／actor／widget／revision fence。codes：assigneeConflict、assigneeForbidden、assigneeInvalidSelection、assigneeRejected。測試 [] 清除、4個新名、5人含1舊名、5新名在搜尋前拒絕、超5在讀取前拒絕、opening／ack／readback 截斷；**靜態37**，不可再寫33。

### P8 — 里程碑＋權重

里程碑用一頁完整 choices 與 existing selection，名稱相同多筆拒絕；字面 none 名稱不等於清除。權重只寫 own value，保留 int32、null 清除與 readEpoch；不寫 rolled-up total。codes：milestoneConflict／milestoneForbidden／milestoneRejected，weightConflict／weightForbidden／weightRejected。測試兩列各自25／21、clear／省略互斥、hasNextPage、selection stale。

### P9 — 活動留言建立／回覆

保留建立用文字 (A) 全九點、跨帳號／欄位 placeholder 拒絕與 upload provenance，不更動既有共用建立函式的結果分類。回覆在 locator≤2 完整驗證 anchor tuple 後取 writeAccess，非模型填 GID；codes：activityForbidden、activityLocked、anchorMismatch、activityUnverifiable。測試 reply 到巢狀續頁、總2次上限、fallback 被拒、鎖定討論串、fake creator、readback body／author／parent；建立21／回覆29各自計數。

### P10 — 活動留言刪除

prepare／dispatch 皆把 GraphQL User GID 轉數字與 currentUser.id 精確比較，不能只信管理者 deleteNote permission。REST 參照 `_ownNote` 在 `lib/core/ai/tools/gitlab_write_port.dart:1086`，id／author 不符即 forbidden；port 用 notOwnNote 呈現保守限制。codes：notOwnNote、noteChanged、noteMissing。locator≤2、deleteAccess1、方法前置1、獨立 note:null readback1；測試 Maintainer 刪別人留言也拒、作者／parent 漂移、already-missing 拒絕；T4 typed name，固定29。

### P11 — T1 pair：表情＋通知

add／enabled 完全對應意圖鍵；表情用 opening／preflight／readback 各 maxPages2，沿用具名方法內的獨立 readback，不另外觀察一次；通知只寫自己的訂閱。codes：reactionConflict、reactionForbidden、notificationConflict、notificationForbidden、intentUnclear。測試方向相反／否定／引用／條件詞改確認、24語意圖詞、兩帳號隔離、三階段截斷與 readback401；表情37、通知21各自計數。

### P12 — 事件單

除 WI 身份之外，以 incidentStatus 的原始 updatedAt 取 fence；僅可寫三個 status，保留 escalation policy／actor／目標檢查。codes：incidentConflict、incidentInvalidStatus、incidentRejected。測試原字串與重新格式化字串差異、dispatch 前變更、noop、errors uncertainty；固定21。

### P13 — 待辦延後（accountTodo）

proposal／dispatch 各跑 currentUser＋完整 ownership≤4頁；snooze 在 pendingTodosForSnooze、unsnooze 在 snoozedTodosForUnsnooze 找**精確 Todo GID**。核對 currentUser、project、targetType、targetEntity 與 scope；WI 自己的 project 也須與外層 project 一致，不能拿 group namespace 當 project。group／無 project／不支援的 target 一律 todoUnsupportedTarget，accountGlobal 也拒；無法證明則 todoUnverifiable，不送 mutation。

只接受可完整綁定的 project Issue／MergeRequest／WorkItem；Commit 等無本批完整 typed target 的類型拒絕。不從可空 expectedTarget 猜座標。write key 至少含 `(account,todos,todoId)`；有 project/iid 時加對應資源 key，依實際 target kind 建 AiAppTarget，避免 coordinator 把無 target 的普通 todo 當成已驗證。現 _todoTarget 在 `lib/core/ai/tools/write_coordinator.dart:2019`，accountGlobal 可直接過 scope 的事實見附錄 B。

codes：todoNotFound、todoUnverifiable、todoForeign、todoUnsupportedTarget。測試 accountGlobal＋group／無 project 必拒、fake outer project、跨帳號、重複 Todo ID、400筆仍 hasNextPage、過期 snooze 的 false 集合、兩個方向與 ack 等級；兩列各固定21，沒有額外 snoozedTodos 或 REST 後備。

每家族驗收：自己的 targeted tests、獨立 adapter counter 逐列核對 §4、`flutter analyze`、Python boundary guard 與 ledger inventory 綠；固定 fake payload 驗只一個 mutation，accepted errors／401／readback 失敗均 uncertain。不能只以「analyze 可能通過」或父代理完成訊息接受。

## §6 波次 C、MR 分組與合併順序

### P14 — 整合、可見度、policy 2→3、catalogue 3→4

前置：seams、全部11家族、主導者 UI／操作標籤／l10n 已合併；先完成下文畫面波次，才翻 modelVisible。P14 不修家族功能缺陷，退回該 owner 的小 MR。

| P14 擁有檔案／段落 | 具體工作 |
|---|---|
| 13個 rows_graphql 檔的可見度段 | 15列 modelVisible→true；cap／schema／方法契約不另改。 |
| `lib/core/ai/ai_provider.dart`、`lib/core/ai/prompts.dart` | policy 正規 JSON／圖寫入 noChange 與 mutationSent 契約、同意升級；prompt 說明單目標、revision／actor fence、snooze 歸屬失敗不送。 |
| `lib/features/ai/ai_chat_controller.dart` 版本段 | S0c 之後 rebase 接手；aiProductionWritePolicy.policyVersion 2→3（`lib/features/ai/ai_chat_controller.dart:2370`），catalogueVersion 接線 `lib/features/ai/ai_chat_controller.dart:2372`。 |
| `lib/core/ai/tools/tool_catalogue_version.dart`；`tool/tests/test_ai_boundaries.py` 版本段 | 常數3→4（`lib/core/ai/tools/tool_catalogue_version.dart:1`），regex 的實際行是 `tool/tests/test_ai_boundaries.py:134`；不改 S0c 已定的讀取集合。 |
| `test/ai/ai_write_consent_test.dart`、`test/ai/fix2_logic_test.dart` | consent 的當前版本 expect3→4（`test/ai/ai_write_consent_test.dart:240`），保留 versions1/2/3/4 相異測試；`test/ai/ai_write_consent_test.dart:248` 是變數不是硬編碼。fix2 的 literal2（`test/ai/fix2_logic_test.dart:118`）是歷史合約 fixture，保留2，不機械加一。 |
| `test/ai/write_call_site_ledger_test.dart` 整合段 | 接手 S0c 分階段映射，要求**本批 pending 15／14 已空**、全部本批 sites 由 ledger 覆蓋；§7t 的3方法／3sites仍精確列為延後且不可見。未知／新增 site 仍失敗，不宣稱全 repo 的 graph pending 已空。 |
| `test/ai/write_tier_test.dart`、`test/ai/fx_coord_http_budget_test.dart` | 可見集合聯集與 snooze 斷言；後者 `test/ai/fx_coord_http_budget_test.dart:136` 現只允許 _counted／_mr6b2CountedCaps，P14 新增獨立核對的 _mr6b3CountedCaps，避免翻可見度後紅。群組 deny 與未交付列不可見斷言維持。 |

P14 驗收：15列完整 schema／cap／operation label／固定確認原因；新同意 hash、舊同意失效、graph不繞過 scope；budget 全可見列覆蓋；inventory 本批空而延後 manifest 精確；`flutter analyze`、整合 targeted tests、boundary／l10n guard 綠。沒有新 sealed preview subtype。

### P15 — 跨家族父計畫驗收矩陣（只新增測試）

只擁有 `test/ai/mr6b3_injection_test.dart`、`test/ai/mr6b3_isolation_test.dart`、`test/ai/mr6b3_races_test.dart`、`test/ai/mr6b3_matrix_test.dart`、`test/ai/mr6b3_guard_test.dart`、`test/ai/mr6b3_binding_test.dart`、`test/ai/mr6b3_budget_test.dart`、`test/ai/mr6b3_boundary_test.dart`，不改 lib。沿 MR6b-2 真實 fake-adapter counter 模式逐列重跑15個數字，不從 ledger.httpCap 推導 expected；覆核指派5人／4新名、表情三階段2頁、locator總2、snooze雙輪4頁、OAuth 重播／PAT、40次邊界、所有 noop／hook／journal flush失敗與五態。缺陷交回對應家族，不為保綠修改 shared cap 或放寬分類。

### MR 分組、先後與主導者畫面

`目前 main → [S0a → S0b → S0c] 一個 seams MR → 11家族小MR → UI／l10n → P14 → P15`。P15 測試草稿可以預先準備，但正式整合驗收在 P14 後；家族自身的 cap／邊界驗證不得等到 P15。家族檔案互不相交可並行；每 MR 綠即合。不要以單一 seams 最後會綠掩蓋中途缺檔。

主導者保留畫面與 ARB：T1 表情／通知／延後方向、T2 WI屬性／新建活動／事件單、T4自己的留言刪除＋#iid typed name、AiFieldsPreview／AiDeletePreview、snooze target＋until 與 ack 等級、無法驗證時未送提示、中斷／手動解除、todo @username、同意與所有 reason codes／欄位標籤。`lib/features/ai/ai_write_ui.dart:35` 的 aiOperationLabel 必須先覆蓋15列；`test/ai/ai_write_ui_test.dart:897` 會檢查每個可見操作非 unknown。此 UI 波次在 P14 前合併，遵守 l10n guard，不把中文放入非 l10n 產品檔案。

## §7 MR6b-3g（later）：群組工作範圍

MR6b-3 保持 groupWorkItem 拒絕，namespaceWorkItem 不進 AI read allowlist。以下僅列後續3g範圍，不在本批實作：

1. 群組 WI origin（數字 Group GID＋fullPath＋iid）及 projectIssueFromGroupPage origin；run registry 用不同 origin key，不能把群組頁開啟的專案 WI 偽裝普通來源。
2. _writeScope 群組分支；現 controller 只有 inbox/accountGlobal 與 project/workItem/MR（`lib/features/ai/ai_chat_controller.dart:1029`）；確定同檔順序 S0c 綁定→P14 版本→3g 群組段。
3. coordinator 的 _target／_scopeSummary／_schema／_arguments 四處與子資源 group side；本批不接 groupId+iid。
4. target_binding 的 _resourceBound／_grantAdmits／accountTodo 群組側、URL＋namespaceWorkItem 的雙段驗 Group 身份，統一 groupKeyNumericId helper；不能只比 URL path。
5. key 使用 `(account,group:<numeric Group ID>,workItem,iid)`，WI GID作別名；目前 scope key 的 fullPath 正規化留給3g改。
6. 最小固定 GraphQL WI 讀工具及其讀 port／guard；namespaceWorkItem 必須在這時才加入，不在本批先放寬。涉及整欄文字的能力另依 §7t，不以群組 scope 交付宣稱文字接線完成。
7. write_tier 的 group deny 才改成同源綁定，測試 foreign group拒絕；本批 deny 斷言維持。
8. 父計畫 §15 第10／24列的群組子項由3g驗收。群組／無 project snooze 在本批是 **port 的 todoUnsupportedTarget**，不是 binding 自然拒絕；accountGlobal 能通過 scope（附錄 B），所以3g須另接。
9. 群組頁在途 registry adapter 接上既有 account/API-bound GID 介面；本批只接專案畫面，介面可表示GID不等於已交付群組支援。

## §7t MR6b-3t（later）：移出範圍與原因（D18／D19）

**P1：Work Item title／description 整欄更新。** `updateWorkItemContent`（`lib/core/work_item_content_api.dart:127`，送出 `lib/core/work_item_content_api.dart:183`）整族移出。後續3t須設計 controller 在 proposal／dispatch 的 _prepareText **之前**取得正確帳號／專案／iid 的 currentFields＋provenance，才能在 bypass 也偵測 hidden-span removal；目前 controller 的 currentFields 集合與執行順序未接新 GraphQL 寫入，port 後讀不能補救（`lib/features/ai/ai_chat_controller.dart:1333`、`lib/features/ai/ai_chat_controller.dart:2284`；`lib/core/ai/tools/write_coordinator.dart:681`）。本批沒有 content part／row／hook 或可見工具。

**P10-edit：活動留言整欄 body 編輯。** `editWorkItemActivityNote`（`lib/core/work_item_activity_api.dart:470`，送出 `lib/core/work_item_activity_api.dart:507`）移到3t，以 note 身份與作者綁定設計相同的前置 currentFields／provenance 接線、隱藏內容刪除固定確認與跨 note placeholder 拒絕；不因保留建立或刪除就假定已安全支援覆寫。D8 的自己作者限制也隨編輯延後；本批刪除已獨立套用該限制。

**P7：Work Item labels。** `updateWorkItemLabels`（`lib/core/work_item_labels_api.dart:315`，送出 `lib/core/work_item_labels_api.dart:405`）整族移到3t。現 searchWorkItemLabelCandidates 強制非空 search（`lib/core/work_item_labels_api.dart:244`），現有 catalog 是已掛標籤，不能當專案候選全集；後續3t自己的 seams須擁有免搜尋候選讀取、known-candidate registration、allowlist及≤10名稱的誠實cap設計，不在本批虛構此能力。以上正好是原inventory留下的3個方法／3個實體site，維持不可見與精確延後manifest。

## §8 父計畫 §24 的擬議 v6.11 修正案（未編輯父計畫）

> - MR6b-3 本次範圍改為15個project／accountTodo操作、14個實體送出點；群組origin／grant／binding／讀工具與父計畫驗收矩陣群組子項移至MR6b-3g（§7），整欄文字與標籤族移至MR6b-3t（§7t）。保留活動建立／回覆及只刪自己的留言；本批沒有整欄文字寫入列。
> - groupWorkItem 的 scopeAdmits、_grantAdmits、decideTier、_grantOffers、toolsForScope deny維持；namespaceWorkItem不上AI白名單。snooze 的 group／無project target即使accountGlobal也由port拒絕，不能寫成scope必然擋住；對應子項記為拒絕／3g交付。
> - 定址一律 projectId＋iid、子資源數字note ID；GID與revision留port。Project由grant組成並由projectWorkItem核對id/path；有projectId照常freshness讀取，僅P13免讀。confirmName由卡片處理；stringList及每列清除／省略語意依§3。
> - D20固定cap以§4的15列為準：`L=2(F+P)+Mpre+Mrb`、`httpCap=2L+1`。指派總數≤5、新候選≤4、三階段maxPages1，cap37；表情三階段maxPages2且readback獨立計入，cap37；locator共用總2次上限、AI無legacy重讀；snooze每輪完整最多4頁且不加觀察／REST後備。
> - seams採S0a→S0b→S0c同分支一MR；S0a先建所有空引用檔與registry純介面，S0b擁有core hooks／分頁／查詢，S0c只adapter／注入／guard；各段可獨立analyze與測試。家族填實列後保持hidden，UI先完成、P14才policy2→3／catalogue3→4及可見度。
> - 父計畫§8的dispatching→notExecuted條件擴及hookReturned但尚未呼mayStart時的**任何方法結果／例外**，與mayStart false同走現有revert API，退款／恢復pending-confirmation marker必須flush成功。prepared noop僅finish到notExecuted，對外成功noChange；不新增prepared→succeeded轉移。
> - 父計畫§7.5本批graph採更保守規則：accepted後即使方法報mutationSent:false或傳輸前拒絕，也不使用failedCertain，統一writeUncertain；payload errors／401／取消／readback失敗同樣處理。graph settle不得落入REST _settle／safeFailure；terminal／rollback落盤失敗保留隔離，不宣稱成功或退款。

## §9 未解問題、證據限制與 follow-ups

**沒有剩餘規劃分支需要主導者裁決。** D18／D19以減範圍解決兩個能力缺口，D20採固定cap與保守拒絕，D21／D22已在本文寫出可實作的契約／所有權；不是已實作驗收結論。

Q10公開語意已查證：GraphQL CurrentUser.todos 提供state、isSnoozed、after等連線參數（[官方 schema](https://docs.gitlab.com/api/graphql/reference/objects/)、[官方 pagination](https://docs.gitlab.com/api/graphql/getting_started/)）；上游固定commit `9210fcac1ee7ae43b97db9526e9bf650c06987ea` 的 [resolver](https://gitlab.com/gitlab-org/gitlab/-/blob/9210fcac1ee7ae43b97db9526e9bf650c06987ea/app/graphql/resolvers/todos_resolver.rb#L49-70) 轉交filter，[finder](https://gitlab.com/gitlab-org/gitlab/-/blob/9210fcac1ee7ae43b97db9526e9bf650c06987ea/app/finders/todos_finder.rb#L234-245) 選scope；[model scopes](https://gitlab.com/gitlab-org/gitlab/-/blob/9210fcac1ee7ae43b97db9526e9bf650c06987ea/app/models/todo.rb#L100-102) 定義 true為snoozed_until>now，false為snoozed_until≤now或NULL。因此 pending＋false包含「從未延後」**及「已過期延後」**，不是NULL-only；[使用者文件](https://docs.gitlab.com/user/todos/#snooze-to-do-items) 亦說到期返回pending。

這關閉v3的公開語意疑問；**安裝中GitLab版本／feature flag／實際schema相容性仍NOT_RUN**，本次沒有讀私人實例。實作fixture須含從未延後、未來延後、已過期、已完成四種狀態與跨頁；部署實例缺參數／欄位或語意無法驗證即refuse，不自動改REST／排除法，避免額外請求與假等價。

非阻擋follow-ups：進一步擴大locator深度、指派新候選數、milestone多頁、snooze target種類、接受後failedCertain的逐mutation證據、群組／整欄文字能力，均留後續MR自行重算cap／更新契約，不在本批暗加。親自裝置／G0真實私有專案、Android／iOS、live API與發布證據均NOT_RUN；規劃／fake adapter成功不關閉這些關卡。

## 附錄 A：D15 唯一完整 allowlist（S0c 一次交付）

設 B 為目前 `tool/tests/test_ai_boundaries.py:23` 的完整 WRITE_PORT_MEMBERS，**原集合逐項保留**，只加下列精確增量；不是用下表取代既有REST集合。B中的instance／currentUser／record／records等沿用。本批新增集合R∪W，guard斷言等於B∪R∪W，沒有別名或未命名「兩個查詢」。

- **R（18個具名read）：** projectWorkItem、workItemState、workItemStatus、workItemDates、workItemHealthEdit、workItemAssignees、searchWorkItemAssigneeCandidates、workItemMilestone、workItemMilestoneChoices、workItemWeight、workItemActivityWriteAccess、workItemActivity、workItemActivityNext、workItemDiscussionNotesNext、workItemActivityDeleteAccess、workItemActivityReactionAccess、workItemNotifications、incidentStatus。
- **R再加S0b的2個固定read：** pendingTodosForSnooze、snoozedTodosForUnsnooze。R合計20個。不是舊的snoozedTodos；後者**不加入**，cap沒有它的觀察讀取。
- **W（15個具名write）：** updateWorkItemState、updateWorkItemStatus、updateWorkItemDates、updateWorkItemHealthStatus、updateWorkItemAssignees、updateWorkItemMilestone、updateWorkItemWeight、createWorkItemActivityComment、createWorkItemActivityReply、deleteWorkItemActivityNote、setWorkItemActivityNoteReaction、setWorkItemNotifications、setIncidentStatus、snoozeTodo、unsnoozeTodo。

不加入namespaceWorkItem；§7t列出的3個具名write與所需專屬opening／candidate read也不加入。R∪W共35個增量。方法內部的preflight／readback是具名方法自己的固定文件，不讓port直接取其private reader。家族不得補改此集合；確有新需求回seams owner重審cap與guard，不動態放行。

guard現碼會掃主port與所有part的 `_api.x`，比對子集合（`tool/tests/test_ai_boundaries.py:162`），且ledger.namedMethod也須放行（`tool/tests/test_ai_boundaries.py:176`）；字面generic channels連註解都禁（`tool/tests/test_ai_boundaries.py:113`、`tool/tests/test_ai_boundaries.py:213`）。未來port／part包括_settleGraph說明文字也避免禁詞 `_send`／`graphMutation`；本文的說明不寫入產品port註解。只有既有兩個port主檔可import API library（`tool/tests/test_ai_boundaries.py:140`），pure helper／interface不import、不傳出_api，不新增泛用傳送逃生口。

## 附錄 B：群組不可達與accountGlobal反例（D16）

1. 專案WI正常路徑：scopeAdmits group false（`lib/core/ai/tools/target_binding.dart:148`）、_grantAdmits group false（`lib/core/ai/tools/target_binding.dart:263`）、decideTier group deny（`lib/core/ai/tools/write_tier.dart:135`）、_grantOffers group false（`lib/core/ai/tools/write_ledger.dart:351`）都維持。workItem走_coversIssue且要求projectId（`lib/core/ai/tools/target_binding.dart:238`、`lib/core/ai/tools/target_binding.dart:283`）。
2. 唯一產生WI detail的允許reader是projectWorkItem，核對outer project id/path及item.project（`lib/core/work_item_graphql_api.dart:1065`、`lib/core/work_item_graphql_api.dart:1418`）。namespaceWorkItem雖存在於 `lib/core/work_item_graphql_api.dart:841`，不在allowlist；不能透過port產生group summary後走其他方法的group候選分支。
3. accountTodo **不能靠上述專案檢查證明封閉**：_grantAdmits 的accountGlobal直接true（`lib/core/ai/tools/target_binding.dart:250`），todo資源綁定可用app斷言（`lib/core/ai/tools/target_binding.dart:450`）；現_prepareTodo在global時跳過project/resource限制（`lib/core/ai/tools/gitlab_write_port.dart:916`）。所以新snooze port須在scope判定前／不受global豁免地拒group／無project，並用query真實project/targetEntity相互驗證。
4. 必做負面測試：accountGlobal＋群組WI todo；accountGlobal＋無project；偽outer project＋targetEntity.project:null；foreign project／帳號；namespaceWorkItem未放行。前四者mutationCount:0、todoUnsupportedTarget或todoForeign，最後guard失敗；不是用普通todo當作已綁WI放行。支援的專案WI即使namespace是所屬group，也以**自己非空且匹配的project**辨識，不把所有Group namespace誤判成群組WI。

## 附錄 C：父計畫 §15 驗收矩陣的封包對照

下列號碼是**父計畫**驗收列，並非本文缺少的章節；本批範圍以D18/D19收斂後為準。

| 包 | 父計畫驗收列與本批責任 |
|---|---|
| S0a | 13（每mutation日誌先dispatching、HTTP計數）、25（五態、noop、401、flush／rollback失敗；HTTP讀失敗不鎖已送mutation） |
| S0b | 25（15入口14sites、成對hooks、try外false、noawait、分頁／fallback／snooze固定查詢） |
| S0c | 13（完整白名單）、21（固定universe分階段inventory）、25（UI／AI登錄互斥與account/API隔離） |
| P2／P3／P4／P5／P6／P8 | 1、5、6、7、8、10、11、13、16、19、21、24專案子項、25、29；沒有整欄覆寫驗收冒充通過 |
| P9／P10 | 上列＋23、32中本批建立文字／upload provenance與自己的留言刪除子項；未交付部分見§7t |
| P11 | 1、5、8、13、15（24語方向）、16、19；表情獨立分頁readback計數 |
| P12 | 5、8、10、16、19、25；事件單原revision與三個可寫status |
| P13 | 1、5、8、10、13、15、16、19、24；group／無project明確拒絕，不記群組成功 |
| P14 | 11（同意／版本）、15（方向與label）、21（本批pending空、延後manifest仍精確）、全部可見列budget集合 |
| P15 | 1、5–8、10、11、13–16、19、21、24專案與群組拒絕子項、25、29；跨家族重跑不替代各家族先驗 |

本計畫的停止條件：D1–D23、兩份round-3的全部Critical／Important有明確落點；15列cap與15入口hook可逐項追源；S0三段無未來檔案依賴；本文引用與移出範圍self-check通過；repo保持原HEAD與乾淨。產品實作／analyze／tests／live相容性不在此次交付，不以計畫完成宣稱已驗收。
