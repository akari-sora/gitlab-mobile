# MR6b-3g breakdown v2（群組 Work Items；僅規劃）

## v2 修訂

| 審查項目 | 修訂與落點 |
|---|---|
| Codex I1 | G0b 先交付 AI 嚴格 namespace reader，保留 project 欄位存在性；G0c/G0d/G0e 再使用，同一 logical read，見 §2.2、§8。 |
| Codex I2 | 指定 core 主 library、read/write 主 port、binding/ledger 的 helper import owner 與實際引用時點，見 §2.2、§2.4、§2.5。 |
| Codex I3／Opus I2 | G0e 先遷移 inventory 與 gate 測試；U0 提前交付 labels/l10n；G14 明列舊版本、可見集合、todo/tier 測試交接，見 §2.5、§5、§6、§8、附錄 B。 |
| Opus I1 | todo owner 採增量：保留原 project record，另加 typed group 欄位與互斥驗證，見 §2.5、§5。 |
| Opus I3 | read guard 按 concrete class 分隔；新增 group 固定 GraphQL POST 的 HTTP 層斷言，見 §2.4、§6.2。 |
| Opus I4 | namespace write read 定點在主 port；locator 僅用 callback；G0d→G0e 順序交接 exact guard，掃主檔及所有 part，見 §2.4、§2.5。 |
| Opus Minor 1–8、10–11；GLM Minor 1–4 | 校正候選證據、freshness/source visibility、origin grant、UI-added owner、文案交接、外部查證、基準及引用；明列主 owner／前置與 send-site 口徑。 |
| Opus Minor 9 | 不立即拆 G0e：保留已定六個 seam MR 與一次檔案交接；若實作審查要求再拆，須先補獨立可建置依賴與驗收，不臨時平行改 shared 檔。 |

基準日期：2026-10-27；分支 `docs/mr6b3g-breakdown`；產品基準／v1 父提交為 `b242a9dc0db1c5e791dc83b2e701f11b3f347227`；v1 docs commit／本次修訂前 HEAD 為 `ccd92d12cd696bdbdfc3ae6af062f00d0d026da5`。下列既有檔案與行號均對本 checkout 重新查核，不沿用 MR6b-3 舊行號。`docs/PLAN_STATUS.md` 仍把 P15／3t 寫成審查中；產品基準已含 3t，應以原始碼及 git 合併紀錄判定前置，不在這份文件順手更新狀態頁。

拘束來源：完整閱讀 `mr6b3-breakdown.md`（尤其 §3–§7、附錄 B/C）、`mr6b3-decisions.md`（D1、D16、D20、D25、D26）、`ai-writes-plan-v6.md` §2、§3、§7、§15，以及 `AGENTS.md`、`CLAUDE.md`、`docs/PLAN_STATUS.md`；亦讀取契約要求的 README、CI、ROADMAP。後決定優先；D16 的群組 deny 是本次要以完整綁定取代的基線，並非先刪 deny 即完成。

v1 已以一個 docs commit 新增本文件；本次 v2 只修訂本文件，不改產品、測試、父計畫或狀態頁，不新增 commit。以下實作指令與驗收案例全部 **NOT_RUN**；現碼查核與公開文件查閱不是群組產品驗收。

## 本 breakdown 交付內容

- 原 §7 九項的當前證據、最小契約與封包 owner；已存在的 helper／adapter 明確重用。
- 18 個已交付 graph operation／具名方法逐列評估：15 個 WI 操作可條件式擴展、2 個 accountTodo 操作可增加群組 target、1 個 project incident 排除。18 是 operation 數，不冒稱 18 個不同領域家族。
- 六個依序合併的 shared-seam 小 MR、家族前的 lead-owned U0 labels/l10n、十三個家族小 MR、完整 UI、可見度與同意升版、最後跨家族驗收。每階段每檔只有一名 owner。
- D20 每列重新列出 F、P、Mpre、Mrb、L、固定 httpCap；群組路徑的數字是待實作契約，不能拿既有 project 測試宣稱已證明。

## §0 與 MR6b-3 舊規劃的差異

1. 3t 的 content、activity edit、labels 已在 HEAD，三列都在本次群組候選內。`lib/core/ai/tools/write_ledger.dart:308` 已聚合三族；`tool/tests/test_ai_boundaries.py:63` 已精確放行四個 opening/candidate reads 與三個 writes。
2. 文字順序已修正：`lib/core/ai/tools/write_coordinator.dart:737` 先 opening、合併 `prepared.currentFields`，才 `_prepareText`；dispatch 亦在 `lib/core/ai/tools/write_coordinator.dart:1088` 重做。沿用此順序，不回到「port 後讀無法補救」的舊缺口，也不省略群組 provenance 接線。
3. `projectIssueFromGroupPage` 已存在；shared registry adapter 也已存在。缺口是入口與 group 身份貫穿，以及可驗證的群組接線，不另造第二套 registry。
4. 新群組 WI 工具採**獨立 operation ID、相同 namedMethod**：例如 `updateGroupWorkItemState` → `updateWorkItemState`，`scopeClass:groupWorkItem`。保留現有 project schema／cap／operation；不把 `projectId` 改成可省略後讓兩種 owner 混用。十五個新 group rows 初始 `modelVisible:false`；既有 snooze 兩列保留 ID，由明確的 group-target gate 分階段開放。

## §1 原 §7 九項：今日證據與應交付契約

| 項 | 當前 file:line 證據 | MR6b-3g 契約／owner | 主 owner／前置 |
|---|---|---|---|
| 1 origin／run key | `lib/features/ai/ai_chat_session.dart:60` 的 `AiWorkItemOrigin` 必須有 Project，`:79` key 為 project/kind/iid；`lib/features/ai/ai_run_registry.dart:122`、`:145` 用 origin.key；`lib/core/ai/tools/write_ledger.dart:181` 已有 projectIssueFromGroupPage grant helper | G0c 加 group WI origin 與 project-from-group-page origin；兩者與普通 project origin 使用不同 run key。帳號／generation 仍由 registry 隔離；parent group 頁不決定實際資源 owner。 | G0c；前置 G0b |
| 2 `_writeScope` | `lib/features/ai/ai_chat_controller.dart:1175` 至 `:1201` 只有 inbox/accountGlobal 與 project/workItem/MR；`:1259` 至 `:1260` fingerprint 已包含 grant.groupId／groupFullPath | G0d 接單一 `(groupId,iid)` grant；project descendant 呼叫既有 helper，只授權該 WI／子資源。scope revision 隨 grant 改變，group grant 不授權 project／兄弟 WI。 | G0d；前置 G0c |
| 3 coordinator 四處與子資源 | `lib/core/ai/tools/write_coordinator.dart:2136` target 有 group kind 但 bound 判斷只有 project；`:2440` arguments 只驗 projectId/iid；`:2618` summary 跳過 projectId:null；`:2634` schema 只收 projectIds；`:2271` todo target 只產 project side | G0e 補 target、summary、schema、arguments 及 todo/group side；note／emoji／todo 以 group side＋parentIid 帶 owner。模型只填 groupId+iid／數字 noteId，不填 GID、path、revision、confirmName。 | G0e；前置 G0d |
| 4 target binding／單一數字 Group helper | `lib/core/ai/tools/target_binding.dart:153` 與 `:263` group deny；`:250` accountGlobal todo 直接准入；`:483` resourceBound 要 projectId；`:538` groupBound 目前只比 path+iid，`:544` app assertion 可提早通過 | G0a 的唯一 `groupKeyNumericId` 驗精確 Group GID；G0e 在 app assertion、URL 及 group subresource 前都核對數字 Group ID。URL 僅提供定位候選，不能以 path-only 產生身份。 | G0e；前置 G0a helper、G0b 嚴格 reader |
| 5 key／WI GID alias | `lib/core/ai/tools/write_ledger.dart:163` 的 scope key，在 `:173` 仍用 groupFullPath；`lib/core/ai/tools/gitlab_write_port_graphql_content.dart:56` 是現有 project WI key 範例 | G0a 定義數字 group canonical key；G0e 改 scope key，家族用 `(account,group:<id>,workItem,iid)`，WI GID 僅作該 key 的已驗別名。group:<7> 與 project:<7> 永不相等。 | G0e；前置 G0a；家族接 key |
| 6 最小固定 read tool／allowlist | `lib/core/work_item_graphql_api.dart:841` 已有 namespaceWorkItem，`:844` 是 optional expectedNamespaceId；`:1428` 區分 project-null Group／project namespace。`lib/core/ai/tools/gitlab_read_port.dart:44` 介面及 `:75` constructor 仍 project-only；`tool/tests/test_ai_boundaries.py:11` 為 read allowlist，`:285` 明禁 write port 的 namespaceWorkItem；`test/ai/mr6b3_guard_test.dart:193` 另有負面 guard | G0d 同時新增窄 group read contract、`get_group_work_item` schema／執行／計數／projection／provenance，G0d 僅加入 group read class 白名單；write 定點 allowlist 與呼叫由 G0e 同包新增，順序更新舊負面 guard。不能只加 write allowlist。 | G0d；前置 G0b/G0c；write 定點接線 G0e |
| 7 tier deny → 同源綁定 | `lib/core/ai/tools/write_tier.dart:152` 一律 group deny；`lib/core/ai/tools/write_ledger.dart:391` 不 offer group class | G0e 僅在完整 group scope／target 同源且 family hidden gate 成立時准入；G14 才對模型開放。foreign Group、無 grant、唯讀、混合座標仍拒。 | G0e；前置 G0d；production 開啟 G14 |
| 8 group／no-project snooze | `lib/core/todo_snooze_api.dart:54`、`:76` 的固定 query 已讀 WI id/project/namespace；`:250` parser 在 `:296`、`:301` 把 project-null 丟入 unsupported。`lib/core/ai/tools/gitlab_write_port_graphql_snooze.dart:43` 至 `:47` 回 todoUnsupportedTarget，先於 scope；`test/ai/mr6b3_snooze_port_test.dart:603` 有 accountGlobal 反例 | G0b 保留有型別 group ownership；G-P13 接 port 與 group todo binding。未知／無法驗證的無 project target 繼續 todoUnsupportedTarget；只有已證實 Group-owned WI 得例外。G14 前 production group-target gate 關閉。 | G-P13；前置 G0b/G0e；production 開啟 G14 |
| 9 group-page registry adapter | `lib/features/workspace/graph_work_items_page.dart:2140` 至 `:2215` 已有 account/API/instance/generation-bound adapter；`lib/features/ai/ai_chat_controller.dart:1609` 至 `:1617` 已注入；group detail 在 `lib/features/workspace/graph_work_items_page.dart:3199` 呼叫 namespaceWorkItem | G0f 由 Claude 在同一 adapter／registries 證明 group UI↔AI 互斥與 terminal/revision floor；沒有額外全域 GID registry。只有介面能表示 GID，不能當群組接線已驗收。 | G0f；前置 G0e |

補充文字／可見度缺口：`lib/features/ai/ai_chat_controller.dart:1285` 對無 projectId 直接回空 freshness；`:1432` 至 `:1468` provenance 是 project identity。`lib/core/ai/write_text.dart:72` 已可表示 groupId/groupFullPath，但 `:101` gitLab factory 要 projectId。G0d 要補 group provenance 與 freshness；不能以現有型別有欄位就宣稱內容安全接線完成。

## §2 波次 A：shared seams（六個小 MR，順序合併）

順序固定 `G0a → G0b → G0c → G0d → G0e → G0f`；每包獨立 analyze／targeted tests／guard 綠後合併，不讓家族補 shared 檔。以下「新」均是未來要建立的檔案。本次不建立它們。

### §2.1 G0a：純身份、canonical key、欄位 provenance

唯一 owner：`lib/core/group_work_item_identity.dart`（新）、`lib/core/ai/write_text.dart`、`test/ai/mr6b3g_identity_test.dart`（新）、`test/ai/write_text_test.dart` 的 group factory 測試。純 helper 放在 core 共用層，不 import API／AI／ledger，讓 core parser 與 AI binding 共用而不形成反向相依。

- `groupKeyNumericId(String gid)` 只接受 `gid://gitlab/Group/<正整數>`，拒 WorkItem／Project／Namespaces::ProjectNamespace／Epic GID、零、負數、前導零、溢位、尾端字元。全案不再各自 split('/') 抽數字；從 numeric grant 建 Group GID 也用同一組驗證，禁止把 numeric Work Item ID 當 Group ID。
- verified group identity 為 account（完整 instance＋numeric user）、groupId、fullPath、iid、WI GID、API owner/read epoch；identity 建構需 server evidence，不接受模型宣告「verified」。path 作查找與顯示，canonical key 只用數字 owner。
- group field factory 用同一 canonical group resource 身份與欄位名；description／note body 可標完整值，note 數字 ID 與 GID alias 對到同一來源。placeholder table 自身仍 account/conversation-bound；跨 group／iid／note／field 永不能還原。改名不改 key；resourceWeb 以當前已驗證 path 與 instance installation prefix 組成。
- 不遷移不存在的群組成功寫入。若升級時發現舊版／未知格式的 path-key journal entry，保守保留隔離，不能丟棄或自動解除；任何必要遷移另列小 MR，不能把兩把鎖當兩個可寫資源。

### §2.2 G0b：嚴格 namespace reader、群組固定候選與 todo ownership

唯一 owner：`lib/core/gitlab_api.dart` 的 helper import、`lib/core/work_item_graphql_api.dart` 的 AI 嚴格 namespace reader/parser 段、`lib/core/work_item_labels_api.dart`、`lib/core/todo_snooze_api.dart`、`test/work_item_graphql_api_test.dart`、`test/work_item_labels_api_test.dart`、`test/todo_snooze_test.dart`、`test/todo_snooze_api_ack_test.dart`、`test/ai/mr6b3g_core_reads_test.dart`（新）。不新增 mutation 通道；其他 core 缺口走下列具名 follow-up lane。

- `lib/core/work_item_graphql_api.dart:871` 先 parse detail，`:1160` 讀 `node['project']`，`:1495` 將缺欄／null 都變成 null，`:1437` 不能再區分。G0b 為既有 `namespaceWorkItem` 增 AI 專用顯式 strict identity 選項（預設 off，保留一般 UI 相容性），在解析前以原始 node 的 key presence 驗 `project` 與 `namespace`；Group 分支必須是**存在的** `project:null` 與有效 Group namespace。G0c context、G0d read tool、G0e resolver 一律啟用 strict 選項且必填 expectedNamespaceId；不能只在 summary 下游檢查 nullable 值。仍是同一固定文件、同一 response／一個 logical read，沒有補證據查詢。
- core 測試分開覆蓋明確 null 的合法 Group、缺 project／namespace 欄位、合法非 null project namespace、非法 project 物件／namespace；合法 project 不誤判 Group，缺欄／非法必拒，全部 reader 測試 mutation0。G0c/G0e 再測嚴格拒絕不產生 proposal／write；default-off UI 行為另保留回歸。
- labels／todo／namespace API 都是 `gitlab_api.dart` 的 part，不能自行 import。G0b 在主 library 引入 G0a helper 並在 todo parser 實際使用；不提前放 unused import。後續讀 port 主 library 由 G0d、寫 port 主 library 與 binding／ledger 由 G0e 各於實際引用時 import。

- `workItemLabelCandidates` 目前 `lib/core/work_item_labels_api.dart:266` 明拒 group；增加固定 group(fullPath) labels query，驗回傳 Group GID/path，禁止 project labels、descendant group/project labels 混入。允許的 ancestor 行為與現有 UI／GitLab schema 一致，未證明的繼承來源拒絕；一頁100、`maxPages:1`、hasNextPage 即拒；沿用 known-candidate registration、scoped label 規則與 set-delta mutation。
- snooze 兩個固定 query 已有足夠身份欄位，先保留 query，不增加隱藏 namespace 查詢。parser 新增明確 group variant：outer project:null、target WorkItem、own project:null、精確 WI GID/iid、Group namespace GID/fullPath；數字 Group ID 統一呼 G0a helper。project variant 仍逐一核對 outer/own project，不能因 namespace 是 Group 就誤判專案 WI。
- todo 的 outer project 與 target own project 也須在 raw node 分別驗 key presence，只有兩欄均明確 null 才可為 group variant；不能用 map 下標的 null 代替缺欄檢查。ownership result 帶 group namespace，不能只回 iid；未知型別、欄位省略、冒用 Group GID、不一致 project、重複 Todo、cursor 異常全拒。讀完整終頁，每輪最多4頁／400筆；到上限仍未完整就是 todoUnverifiable，不能當查無。
- `pendingTodosForSnooze`／`snoozedTodosForUnsnooze` 新增顯式 `allowGroupTargets:false` 預設參數，預設仍將 group ID 放在 unsupportedIds，不把 group-shaped item 交給仍會讀 project 的舊 port。另測 opt-in 保留 group ownership；G-P13 才由 production gate 決定是否傳 true，G14 前為 false。公開 UI 已有的普通 snooze 行為不變。
- **core follow-up 唯一 owner 仍是 G0b seam owner**：家族若發現 `lib/core/work_item_activity_api.dart` 或其他具名 core 方法的 group parent 證據不足，回報此 owner，由其在該方法及對應 `test/work_item_*_api_test.dart` 開獨立小 MR；先列明實際檔案、身份契約與 targeted command，再交接，合併後該家族才繼續。新增 read/probe 必須先重算 §4 cap；不能由家族越權改 core 或把缺口拖到 G15。

### §2.3 G0c：origin／context 的 group 身份通道

本 MR 每檔唯一 owner：G0c seam owner 負責 `lib/features/ai/ai_chat_session.dart`、`lib/features/ai/ai_chat_context.dart`、`lib/features/ai/ai_run_registry.dart`、`lib/core/ai/tools/tool_scope.dart`、`test/ai/ai_chat_context_test.dart`、`test/ai/ai_run_registry_test.dart`、`test/ai/mr6b3g_origin_test.dart`（新）；Claude 負責 `lib/features/ai/ai_chat_page.dart` 與 `lib/features/ai/ai_chat_controller.dart` 的同包 exhaustive-switch 相容段。此時不加入口 widget 或新 UI 文案；兩檔到 G0d／§6.1 才順序交接後續責任。

- 新 `AiGroupWorkItemOrigin` key：`group-item:<groupId>:<iid>`；新 project-from-group-page origin key：`group-page:<viewGroupId>:project:<projectId>:workItem:<iid>`；普通 project key 保留。registry 本身 account/generation-bound，不把 path/title 放身份 key。
- group origin 帶 Group GID 的數字 ID、canonical fullPath、iid；載入 context 重新呼 namespaceWorkItem，必填 expectedNamespaceId，啟用 G0b strict identity，驗明確 project:null 與直接 owner，不能用 includeDescendants 根群組代替 item.namespace。
- project 不為 null 的 descendant 依 item.project 建 project key/grant；viewGroupId 只區分 run 入口，不授權該 group 或整個 project。`AiWorkItemOrigin` 現為 final，不用繼承解題：G0c 的 controller 相容段先顯式攔截兩種新 origin，使它們在 G0d 前回無 write grant，不能落入 `lib/features/ai/ai_chat_controller.dart:1193` 至 `:1200` 的 project-wide fallback；G0d 再改用既有 `projectIssueFromGroupPage`。G0c 測兩新 origin 在此階段無 grant，G0d 測最終只有單一 WI／子資源、兄弟與全 project 拒。重新進入同一入口可找回 run；兩種入口不合併 consent/scope。
- 在現有 `AiChatContext` 增加獨立 group read scope（例如 `AiGroupResourceScope`），保留原 project scope 強型別；group 不偽造 projectId:0／dummy Project。新增 sealed 子類時同包補齊 context、`lib/features/ai/ai_chat_page.dart:70`／`:79`／`:90` 與 `lib/features/ai/ai_chat_controller.dart:2176` 的 exhaustive switches；同檔 `:1231`／`:1235` 的 wildcard 也明示新 origin 的保守語意，完整 currentResource/grant 到 G0d 接線。新 group origin 暫無入口且寫入拒絕，不能讓 G0c 單獨合併後無法 analyze。
- 群組 context 新增獨立、可表示 unknown 的 metadata，保存經 account/API/generation 驗證的 source group visibility 與可證 WI confidential；不把現有 bool readConfidential 的預設 false 當成已證實非機密，不能因 `projectForAiChatOrigin` 回 null 就永遠把 source 視為 unknown，也不能把 unknown 當 public。重用 `group(id)` 一次讀 source metadata，與 strict namespace read 一起納入 context 自己的 budget；缺 visibility/confidential 證據保留 unknown。G0c 負責 `AiChatContext` metadata；G0d 順序接 controller 的 source rank／`_readVisibilityRank`／`_readConfidential` 與 group tool 結果傳播，保留已讀資料最嚴限制，跨 segment 不消除污染。
- context 身份讀取有自己的 budget；不列入下方單次 write cap，也不從 write cap 偷扣 context 費用。正式送出前仍重新 reserve 全部 write allowance。

### §2.4 G0d：最小 group read 工具、freshness、allowlist

唯一 owner：`lib/core/ai/tools/gitlab_read_port.dart`、`lib/core/ai/tools/tool_catalogue.dart`、`lib/features/ai/ai_chat_controller.dart` 的 group context／scope／freshness／read injection 段、`tool/tests/test_ai_boundaries.py` 的 read/importer/member guard 段、`test/ai/mr6b3_guard_test.dart` 的 read class guard／write 掃描基線段、`test/ai/mr6b3g_read_tool_test.dart`（新）、`test/ai/mr6b3g_freshness_test.dart`（新）。controller 在 G0c 後接線；G14 再接手版本段。

- 在既有 read port 檔內加入窄 `AiGitLabGroupReadPort` 與 concrete `GitLabAiGroupReadPort`；G0d 在主 library 加 helper import 並實際用於 Group 身份驗證，只暴露固定 WI read。`AiToolCatalogue` 增 group constructor/branch，保留 project constructor 與既有工具行為；group-only catalogue 不需要 project port，direct call project tool 也先拒，不可用一個假的 project port 填 constructor。
- `get_group_work_item(groupId:integer,iid:integer)` 只讀已授權那一筆；path 來自 grant，傳 `_api.namespaceWorkItem(path,iid,expectedNamespaceId:..., <G0b strict identity 選項>:true)`。未知引數、query／operationName／variables／URL／GID 參數全拒。單次固定 read 最多1 logical／2 OAuth 資源請求，沒有 schema fallback、GET/HEAD-only guard 全域豁免或任意 GraphQL channel。
- projection 最小含 id、iid、title、type、state、updatedAt、project、namespace、完整 description（有 widget 時），沒有活動列表／候選全集。缺描述與截斷都明示；只有完整未截斷 description 發同欄 group provenance，其餘一般遮蔽。活動編輯可使用 port opening 的 currentFields；本批讀工具不承諾提供活動歷史，沒有可證來源的 note upload token 一律拒。
- 保留既有安全 importer 數量：core AI tools 只有既有 read/write port 可 import GitLab API。Python 與 Dart **按 concrete class 驗證**：`GitLabAiReadPort` 的既有11個 member 精確集合不變，`GitLabAiGroupReadPort` 只准 `{namespaceWorkItem}`，整檔 API 呼叫聯集也須精確等於兩者聯集。未知 class、檔案游離 helper 的 API 呼叫也拒；不能只擴整檔白名單。G0d 加負面 guard fixture，將 namespaceWorkItem 搬入 project class 或偷偷增 group member 都必失敗。
- G0d 同包 HTTP 層測試保留 project port 原 GET/HEAD-only 測試，另測 group reader 的每個資源請求都是 POST 到本 instance GraphQL，`graphQuery:true`、無 `graphMutation`，query 字串與 core 的固定 `_namespaceWorkItemQuery` 完全一致（由 `test/work_item_graphql_api_test.dart` 的固定文件 fixture 鎖定，不從被測 request 複製 expected），variables **恰為** `{path,iid}`（iid String），path 只取 grant；OAuth replay 只能重播同一份讀取文件。拒模型 query/variables、外部 endpoint 與 mutation，不能對整個 port 豁免 HTTP guard。
- write 白名單在 G0d **維持原集合**且仍禁 namespaceWorkItem。G0d 先將 Dart guard 的掃描範圍補到主 port＋由 `part of` 找出的全部 write parts，保留原 graphql_ 35＋3t七個成員的 exact 集合；主檔／非 graph parts 另按既有固定集合檢查，group parts 此時預期空集合。主 port 現有 API 呼叫不能混入原 graph 集合計數。G0e 接手後才同包增加主 port resolver 的單一 namespaceWorkItem 定點呼叫及 exact delta；G0d 不提前要求不存在的 write 呼叫。全檔仍受通用通道禁詞及既有安全 guard 約束。
- `_writeScope` group 分支只從新 origin 或可信 UI 新增的 verified identity 建 grant；新增 UI 流程的唯一 owner 見 §6.1，現碼 enum 不代表流程已存在。模型 URL/GID 不能創 grant，已授權 target 的 URL 仍須 fresh 驗 owner。
- `_freshWrite` 先按 ledger row 的 `scopeClass:groupWorkItem` 分流，插在 `lib/features/ai/ai_chat_controller.dart:1284` 至 `:1288` 的無 project early return **之前**，不靠 args 中有沒有 groupId 猜類型。群組每輪重用 `lib/core/workspace_api.dart:483` 的 `_api.group(groupId)` 恰一次（固定 GET groups/numeric id、既有 `with_projects:false`），驗 id/full_path/visibility；不用 cachedRecord，不另呼 record 重讀。snooze 的 accountTodo 不走此分支（F=0）。身份不符／無法證實則拒；缺可見度保留 unreadable 並改確認，不可回空 freshness。
- source rank 使用 G0c 已驗 group metadata 與 `_readVisibilityRank` 最嚴值；G0d 尚未交付 group prepared metadata 時，target confidential 一律為 unknown，透過現有 freshness unreadable 路徑保持確認，不引用 G0e 才新增的欄位。G0d 以 synthetic metadata 測 private/internal/public／unknown source rank及 group→project 污染；G0e 才在其擁有的 port/coordinator 接同輪 opening 已有的可證 target confidential metadata，未知仍確認，不增加 N 以外的讀取。整合的 confidential→public／有完整證據的 T1與低風險可達性由 G15 依 §9 前置證據驗，不能把 fixture 成功當現有固定query已提供 confidential。
- group description/title/labels/note 的 provenance 用 G0a factory，無 project upload 替換；content/edit/labels 的 currentFields 由已交付 port opening 提供，保留 prepare→合併 fields→text scan 的 proposal/dispatch 次序。不要另讀一次欄位，否則重算 cap。
- controller 的 `lib/features/ai/ai_chat_controller.dart:1294` graphWriteBack 判斷、`:1453` 至 `:1468` 欄位 provenance 分支與 `:2691` `_writeBackOperations` 都明列三個 group text aliases；不能只補 coordinator 集合而漏 hidden-span／replacement 判斷。保留 group target 的 currentResource，與 G0c 的保守段順序交接。

### §2.5 G0e：group grant、coordinator、port resolver 與 hidden rows 骨架

唯一 owner：`lib/core/ai/tools/target_binding.dart`、`lib/core/ai/tools/write_tier.dart`、`lib/core/ai/tools/write_ledger.dart`、`lib/core/ai/tools/write_coordinator.dart`、`lib/core/ai/tools/gitlab_write_port.dart`、`lib/core/ai/tools/gitlab_write_port_graphql_locator.dart`、`lib/core/ai/tools/graphql_write_classify.dart`、`lib/core/ai/intent_lexicon.dart`、`test/ai/write_tier_test.dart` 的 group policy 斷言、`test/ai/mr6b3_binding_test.dart`、`test/ai/mr6b3_dispatch_test.dart`、`test/ai/write_call_site_ledger_test.dart` 的別名 mapping 段、`test/ai/mr6b3_guard_test.dart` 的 write exact guard／graph inventory 段、`tool/tests/test_ai_boundaries.py` 的 write delta／呼叫位置段、`test/ai/mr6b3_snooze_port_test.dart` 的 project 相容及 gate-off 測試接線、`test/ai/ai_write_port_test.dart` 的既有 markTodoDone null-owner 相容回歸、`test/ai/mr6b3g_seams_test.dart`／`test/ai/mr6b3g_support.dart`（新），以及 §5 所列全部 group port/row 與家族 T 測試骨架檔。G0d→G0e 對兩份 guard 為順序交接；G14 再接手 production visibility/gate 段。

helper import 盤點：`gitlab_api.dart` 已由 G0b 接；`gitlab_read_port.dart` 由 G0d 接；G0e 在 `gitlab_write_port.dart` 主 library、`target_binding.dart`、`write_ledger.dart` 的實際 helper 使用點各自 import，part 不自行 import；其餘獨立 library 如需要 helper，必在該檔既定 owner 的交付包加 import 並同包 analyze，沒有跨檔隱含 import。

- resolver 只用 grant 的 path＋groupId＋iid，user1 與 namespace WI1 分開計數；啟用 G0b strict identity，expectedNamespaceId 必填，驗 outer namespace、item.namespace、project:null、唯一 iid、WI GID 類型、actor/API/generation。URL 綁定是「同 instance／installation prefix 的已解析 URL＋fresh namespace read 驗數字 Group」雙階段，URL path 本身不授權。
- `_api.namespaceWorkItem` 的 write 端呼叫**唯一放在主 `gitlab_write_port.dart` 的 group resolver helper**；family 只呼此 helper，locator 維持 `readDetail` callback、零 `_api` 呼叫。G0e 同包把 namespaceWorkItem 精確加到 write allowance，保留原35＋3t七個集合。Dart/Python guard 均驗主檔指定 helper 的 exact `{namespaceWorkItem}` delta、全部 `gitlab_write_port_group_` parts 的封閉既有具名方法集合（按已交付家族驗）、原 graph parts 精確集合不變；任何 group part／project helper 直接呼 namespaceWorkItem 或新增 generic channel 都失敗。未交付空 part 不要求不存在的呼叫；實作家族同包更新其 test-stage expected，G14 驗最終完整聯集。主檔及所有 part 都必掃，不能只擴前綴後放寬成 subset。
- `_target`／`_scopeSummary`／`_schema`／`_arguments` 全補 group：schema groupId enum 只取當前 grant；arguments 要正整數且禁 projectId 混入。group row 只 accept group scope；project row 仍只 accept project。subresource side 用已存在的 `AiResourceSide.group`（`lib/core/ai/tools/target_binding.dart:30`），`parentIid` 與數字 noteId 不丟失。
- `_resourceBound`、`_groupBound`、`_grantAdmits`、accountTodo group branch 都先驗數字身份再考慮 currentResource/uiAdded；不能讓 `_appAsserts` 繞過 foreign Group。只有可信 UI、已驗 URL 或目前資源綁定；裸 #iid、group#iid 文字、tool result、歷史／模型 reason 不建立 group 綁定。
- 把 unconditional group tier deny 換成上述完整 scopeAdmits；工具 hidden gate 仍拒 production 調用。accountGlobal 僅可作用其自己的 exact Todo，永不衍生 group WI 一般寫入 grant。
- 新 group aliases 對 T1 intent 重用現有 reaction/notification 的方向鍵，映射是封閉 operation→intent operation 表，仍綁原始 entry、group target、實際 group operation 與引數；不把 project 意圖憑證直接搬到 group。UI／任何新翻譯詞不由本包寫。
- 主 port 在本包先建立所有新 group part 的具名 extension／最終 prepare 方法簽名、只回 null 的可編譯 stub，以及 rows 空清單，才加入 part/聚合與 dispatcher；不能讓 dispatcher 呼叫空檔中不存在的方法。家族未落地時無工具可見、stub 不送。todo owner 採增量：保留 `AiWritePrepared.todoTarget` 原 `({int projectId,String resource,int iid})?` record 與 project 建構式不變，另加純 typed `groupTodoTarget`（groupId/fullPath/iid/WI GID）；只有 snoozeTodo／unsnoozeTodo 的已驗證 target 要求恰一種 owner，非 todo 不帶 owner，兩種 owner 混填拒；`markTodoDone` 現有 accountGlobal 路徑可在無可辨識 project target 時保留 todoTarget:null（`lib/core/ai/tools/gitlab_write_port.dart:1145` 至 `:1184`），其授權／group offer 不隨本次擴張。coordinator `_todoTarget`／web link 顯式分支處理。`gitlab_write_port_graphql_snooze.dart:106` 的 project producer 與 `test/ai/mr6b3_snooze_port_test.dart:507` 的 record 比對因此繼續相容；G0e 跑該舊測試並測 group 欄位預設 null／雙 owner 拒，以及 ai_write_port_test 的 accountGlobal markTodoDone 未知target／null-owner舊行為，G-P13 才新增 group producer，不在 G0e 偷換原型別。
- `lib/core/ai/tools/graphql_write_classify.dart:31` 的 rules 以 operationId 查找，未知 accepted alias 目前只會 uncertain（`:62`）。本包為15 aliases 明列與對應原 operation 相同的 allowsNoop/readback 規則；33 rules、25 allowsNoop，snooze兩列仍 readback:false。同步改 `test/ai/mr6b3_dispatch_test.dart:116` 的精確集合／數量與逐列 accepted/noop/unknown 測試，不以移除計數遮掩缺 rule。
- `lib/core/ai/tools/write_ledger.dart:386` 的 accountTodo offer 目前不含 groupWorkItem。本檔定義唯一、預設 off 的 production group-target gate，ledger offer 與 G-P13 port 共用；G14 連同同意版本才翻 on。group-only scope 僅在 gate on 且 operationId 是 snoozeTodo／unsnoozeTodo 時 offer，不能讓 markTodoDone 或其他 accountTodo 工具一併進入。accountGlobal 及 project 既有 offer 不變；offer 不能繞過 port 的完整 ownership／exact group binding。
- **第一個 hidden row 前完成舊 graph inventory 遷移**：保留原18 operations 的精確集合、18個原 namedMethod=operationId、全部 visible；另用固定15筆 alias→原 method/site map 驗 group rows，拒未知／重複／漏配／incident alias。為十三家族先建立 §5 的 T 檔骨架，其中12個加 alias 的家族各保存獨立 test-stage expected operation set（初始空）；guard 內另存每家族完整允許 mapping，stage fixture 只能為空或該家族完整集合，**不從 production rows 反推 expected**。家族接手 T 後，同包填該固定集合並測完整 rows／API calls，故並行家族不需改 shared guard。每一階段 graphRows 精確等於原18＋各 test-stage expected 聯集，group hidden／visible 另驗；write member guard 亦用固定每族 API expected 聯集對應已交付 stage。G0e 無 group rows 時只驗原18；家族逐步增列仍嚴格；G14 強制12家族 stage 全交付、15 aliases 全 visible，總33 operations／18 unique methods。不能刪集合檢查或只改 hasLength。
- `mr6b3_binding_test.dart:512`、`write_tier_test.dart:666` 的 group deny 改為**明確注入 gate off**，另以測試用 gate on＋明確注入的 synthetic ledger／typed resolved target 驗純 binding／tier 的同源正面與 foreign／無 grant 拒；這些不是 group prepare 端到端通過。G0e 的 snooze 整合只驗 gate-off 拒，真實 gate-on group producer 正面留 G-P13，再由 G14 驗 production gate-on。production gate 保持 off；測試注入只走既有／本包受限測試 seam，不由模型參數控制。`mr6b3_snooze_port_test.dart` 的舊 group 反例先固定 gate off，G-P13 再測 gate-on 新分支，G14 接 production gate 的遷移。
- 同包新增 group prepared 的可證 target confidential metadata（允許 unknown），coordinator 與 G0d 的 freshness/text 判定只在有證據時收斂 unknown；缺欄不推定 false，接受前仍按確認政策。原 fixed WI query 未含此欄時保持 unknown，若需 schema/core 調整先走 §2.2 follow-up，不能為去除確認加未計數 read。
- graphWriteBack 操作集合增 group content/edit/labels ID，維持兩輪 opening-before-text；共同 locator仍總≤2次讀且禁止 legacy fallback。五態、唯一 mutation、journal／refund／accepted errors 一律 uncertain 沿用，不修改 journal 檔案。
- `lib/core/ai/tools/gitlab_write_port.dart:324` 的 `AiWritePrepared.bindPreparedText` 在 `:332` 只逐欄鎖 projectId/iid/noteId；本包加入 groupId 的「是否存在＋值」比對，已 opening 的 group text request 不可被移除／替換 groupId。seams 測試逐一注入換 group、刪 group、混入 project 座標，全部拒絕且 mutation0，正常文字掃描只改文字不得重定向。

### §2.6 G0f：group registry 與頁面接線（lead-owned：Claude）

唯一 owner：`lib/features/workspace/graph_work_items_page.dart` 的入口／adapter 段、`lib/features/workspace/work_item_status.dart` 的必要 adapter 段、`test/ai/mr6b3g_registry_test.dart`（新）。UI widgets、布局、頁面互動、可及性與一切新增 l10n 都屬 Claude；非 UI worker 只交結構契約。

重用 existing account/API/generation-bound adapter；group 源自 fresh detail，UI status/dates/health 在途時 AI prepare/tryStart 拒，AI lease 開始後 UI 看見在途；exception／cancel settle 一次，uncertain 不偽裝 confirmed、不清 revision floor。重開頁、換 API/account、同 GID 不同 instance、同 iid 不同 group 全測。此 MR 可加 group AI 入口，但 group 工具仍 hidden；project-from-group-page grant 不擴成 project scope。

## §3 18 個 delivered operations：群組適用性、引數與結果

下表 group operation 的模型座標為正整數 `groupId`＋`iid`；GID、revision、path、typed confirmation 皆由 app 決定。`G-` 名稱是封包名，不是 API。除 snooze 兩列保留原 ID，其餘以右欄的獨立 group ID 呼叫**相同具名 core 方法**，不再增加 mutation site。

| 已交付 namedMethod | 群組結論／差異與必驗項 | 新 group operation／包／Tier |
|---|---|---|
| updateWorkItemState | 可；close/reopen → CLOSE/REOPEN，不混自訂 status；fresh state/revision/permission | updateGroupWorkItemState／G-P2／T2 |
| updateWorkItemStatus | 可；candidateId 只能是 fresh allowedStatusIds；START/epoch/registry 同原契約 | updateGroupWorkItemStatus／G-P3／T2 |
| updateWorkItemDates | 可；manual/inherited，切 manual 兩欄各顯式 date 或 clear；省略保留 final snapshot；base/probe 都計費 | updateGroupWorkItemDates／G-P4／T2 |
| updateWorkItemHealthStatus | 可；own health，none→null，不寫 roll-up；缺 widget/permission 拒 | updateGroupWorkItemHealthStatus／G-P5／T2 |
| updateWorkItemAssignees | 可；group autocomplete，不是專案 members；原始≤5、至多4新 username 搜尋，已指派可保留；完整 snapshot與 multiplicity | updateGroupWorkItemAssignees／G-P6／T2 |
| updateWorkItemMilestone | 可；group＋可證 ancestor active candidates，一頁50；拒 project／descendant milestone；同名多筆拒，clear 不依賴候選成功 | updateGroupWorkItemMilestone／G-P8／T2 |
| updateWorkItemWeight | 可；own int32 weight／clearWeight，0≠null；不寫 rolled-up | updateGroupWorkItemWeight／G-P8／T2 |
| createWorkItemActivityComment | 可；新文字完整 (A) 規則、group parent identity；不允許 project attachment substitution | createGroupWorkItemActivityComment／G-P9／T2 |
| createWorkItemActivityReply | 可；anchorNoteId，locator 驗 discussion/replyId/note/createdAt/parent，≤2讀；controls不支援拒 | createGroupWorkItemActivityReply／G-P9／T2 |
| deleteWorkItemActivityNote | 可；數字 noteId、prepare/dispatch 都限自己作者；adminNote 不足以代替作者檢查 | deleteGroupWorkItemActivityNote／G-P10／T4 |
| setWorkItemActivityNoteReaction | 可；noteId/name/add，group side；opening/preflight/readback 各≤2頁；D25 readback 不比會被 reaction 改掉的 note.updatedAt | setGroupWorkItemActivityNoteReaction／G-P11／T1 |
| setWorkItemNotifications | 可；enabled 明確方向、自己的 subscription；缺 notifications widget 不當 false；不以 updateWorkItem 權限替代 | setGroupWorkItemNotifications／G-P11／T1 |
| setIncidentStatus | **排除**；現方法取 Project/Issue，無 group-owner 路徑。`lib/core/incident_api.dart:3`、`:60`、`:94`；不把 group WI state/status 當 escalationStatus | 無；G14/G15 要證明 group 不 offer、不 mutation |
| snoozeTodo | 可增加 group WI target；模型仍只有 todoId/until，currentUser 完整 ownership 證實後綁 group，不收 groupId | 原 ID／G-P13／T1 |
| unsnoozeTodo | 同上；使用 snoozed pending 查詢；ack 必須明含 snoozedUntil:null | 原 ID／G-P13／T1 |
| updateWorkItemContent | 可；title/description 至少一欄、opening currentFields 在 scan 前，完整 group field provenance、hidden-span removal 在 bypass 仍確認 | updateGroupWorkItemContent／G-P1／T2 |
| editWorkItemActivityNote | 可；body、數字 noteId、自己作者、完整 opening body＋group note provenance、原 revision，禁止他 note token | editGroupWorkItemActivityNote／G-P10e／T2 |
| updateWorkItemLabels | 可但先 G0b；labels≤10、完整 current與 candidate，各一頁100；同名不唯一、scoped conflict、foreign label 拒；[] 清除 | updateGroupWorkItemLabels／G-P7／T2 |

所有「可」都以 fresh widget／permission／schema 支援為條件，不能由 Epic/Task 名稱推測。activity 的 nullable project 相等不等於 group parent 已證實：`lib/core/work_item_activity_api.dart:161`／`:190` 選 noteable 身份，`:2006` 比 nullable project；家族須同時比 namespace GID、WI GID、discussion/parent tuple。現有 core 若不足，回 §2.2 明定的 G0b seam owner 補 core follow-up 小 MR，合併後家族才繼續，不在 family part 越權。

主要群組候選差異的現碼來源：`lib/core/work_item_assignee_api.dart:50` 的 group query、`:214` 至 `:251` 驗 owner；`lib/core/work_item_milestone_api.dart:89` 的 group query、`:307` 至 `:331` 驗 scope、`:738` 至 `:763` 依 server connection 接受非 null groupOwner，**不是獨立 ancestry 驗證**；祖先選取靠 `:89` 固定 query 的 includeAncestors:true，未傳 includeDescendants。省略該參數是否確實排除 descendant／以及 selection 可用性須於 G-P8 實作時查 schema／目標實例；不以 fullPath 前綴補作權限證據；labels 的 group search 在 `lib/core/work_item_labels_api.dart:113`，免 search AI query 現在仍 project-only（`:136`、`:259`）。不可用 search 的局部回應冒充可替換整欄的候選全集。

其他 project-only 家族不納入：REST issue/MR CRUD、board card move、project label/milestone 的 CRUD、檔案／ref／CI／Release／snippet／registry／project/fork／upload 都需要其原本 typed project 或 personal namespace grant。群組 WI 對 labels/milestone 的**指派**不授權建立、編輯、刪除 group labels/milestones；group scope 亦不授權 project descendants。`markTodoDone` 的一般擴展不隨 snooze 偷渡，另案設計。

### §3.1 全列共同結果分類／確認

保留 graph 五態：notHooked、hookFailed、hookReturned、mayStartFalse、pastAcceptance。合法未 hook noop 用 prepared→notExecuted、對外 succeeded/noChange；hookReturned 或 mayStartFalse 走既有 revert，flush 成功才稱退還 write hold／恢復 marker。HTTP 已開始的 allowance 不退款。beforeMutation 的 journal flush 失敗不 mutation；mayStart true 與唯一 mutation 之間無 await。

接受前身份、候選、頁數、revision、作者不可證實→notExecuted／mutation0；接受後只有 ack＋該方法的獨立 readback 符合才能 succeeded，其餘 errors／401／cancel／notApplied／readback 失敗→writeUncertain，fail-stop、不重送。snooze 是例外：成功等級只說 ack accepted，無獨立 readback 宣稱。群組單項手動解除名稱為 `<已讀取群組完整路徑>#<iid>`；todo 為 `@username`，在 prepared 固定保存，改名／重啟不解除鎖；刪 note 的 T4 確認名稱由 fresh 所屬 WI 生成，UI 顯完整 group owner 避免同 iid 混淆。

## §4 D20：群組每列重新推算固定 HTTP cap

`L = 2 × (F + P) + Mpre + Mrb`；資源 HTTP allowance `httpCap = 2L + M`，本表 M=1；PAT=`L+1`。proposal＋dispatch 各有 F/P，方法內 Mpre/Mrb 只發生一次；每個 logical read 最多一次 OAuth replay，mutation 絕不重播。OAuth credential-refresh endpoint 另行計數，不混為 GitLab resource mutation；adapter counter 分別列出資源請求與 refresh，不能聲稱表列包含 refresh token HTTP。靜態 **httpCap ≤40**，不只檢查 L≤40。

群組新路徑固定：F=1 是 G0d 的 fresh `GET groups/<numeric id>`，每輪恰一個且不走 cachedRecord 重讀；P 的 U=同帳號 currentUser1、N=必帶 Group GID 的 namespaceWorkItem1；O=家族 opening，C=候選，A=locator，全部如下。這些是實作必須守住的呼叫圖，未經 group counter 證明均 NOT_RUN。現有 project 的計數參考只作方法讀數依據：`test/ai/mr6b3_budget_test.dart:16`，3t 的 `test/ai/mr6b3_content_port_test.dart:49`、`test/ai/mr6b3_activity_edit_port_test.dart:453`、`test/ai/mr6b3_labels_port_test.dart:645`。

| 對應 namedMethod | F | P：每輪完整讀取 | Mpre | Mrb | L 的本次算式 | 固定 httpCap | PAT |
|---|---:|---|---:|---:|---|---:|---:|
| updateWorkItemState | 1 | U1+N1+O1=3 | 1 | 1 | 2×(1+3)+1+1=10 | 21 | 11 |
| updateWorkItemStatus | 1 | U1+N1+O1=3 | 1 | 1 | 2×(1+3)+1+1=10 | 21 | 11 |
| updateWorkItemDates | 1 | U1+N1+base1+probe1=4 | 2 | 2 | 2×(1+4)+2+2=14 | 29 | 15 |
| updateWorkItemHealthStatus | 1 | U1+N1+O1=3 | 1 | 1 | 2×(1+3)+1+1=10 | 21 | 11 |
| updateWorkItemAssignees | 1 | U1+N1+O1+新名搜尋4=7 | 1 | 1 | 2×(1+7)+1+1=18 | 37 | 19 |
| updateWorkItemMilestone | 1 | U1+N1+O1+C1=4 | 1 | 1 | 2×(1+4)+1+1=12 | 25 | 13 |
| updateWorkItemWeight | 1 | U1+N1+O1=3 | 1 | 1 | 2×(1+3)+1+1=10 | 21 | 11 |
| createWorkItemActivityComment | 1 | U1+N1+access1=3 | 1 | 1 | 2×(1+3)+1+1=10 | 21 | 11 |
| createWorkItemActivityReply | 1 | U1+N1+A2+access1=5 | 1 | 1 | 2×(1+5)+1+1=14 | 29 | 15 |
| deleteWorkItemActivityNote | 1 | U1+N1+A2+access1=5 | 1 | 1 | 2×(1+5)+1+1=14 | 29 | 15 |
| setWorkItemActivityNoteReaction | 1 | U1+N1+A2+access2=6 | 2 | 2 | 2×(1+6)+2+2=18 | 37 | 19 |
| setWorkItemNotifications | 1 | U1+N1+O1=3 | 1 | 1 | 2×(1+3)+1+1=10 | 21 | 11 |
| snoozeTodo（group target） | 0 | U1+pending ownership4=5 | 0 | 0 | 2×(0+5)+0+0=10 | 21 | 11 |
| unsnoozeTodo（group target） | 0 | U1+snoozed ownership4=5 | 0 | 0 | 2×(0+5)+0+0=10 | 21 | 11 |
| updateWorkItemContent | 1 | U1+N1+content opening1=3 | 1 | 1 | 2×(1+3)+1+1=10 | 21 | 11 |
| editWorkItemActivityNote | 1 | U1+N1+A2+edit access1=5 | 1 | 1 | 2×(1+5)+1+1=14 | 29 | 15 |
| updateWorkItemLabels | 1 | U1+N1+current1+fixed candidates1=4 | 1 | 1 | 2×(1+4)+1+1=12 | 25 | 13 |
| setIncidentStatus | — | 群組不提議，不分配虛構 cap | — | — | 不適用 | — | — |

雖然若干算式結果等於 project 數字，本表的 F/N/C 都已改成群組呼叫來源，不能直接複製 project expected。snooze F=0 是個人待辦排程、無整欄文字／可見度輸出；ownership 同一回應證實 group，**不再**額外 namespace read／觀察 snoozedTodos。若實作必須多讀一輪 group 身份，先重算，不悄悄沿用21。

### §4.1 有界條件及超限處理

- 指派原始總數≤5、新候選≤4；第五個全新 username 在搜尋前拒；這是明示工具契約，不是用動態拒絕掩蓋較小 static cap。opening/preflight/ack/readback 都 maxPages1；ack 有下一頁直接 uncertain。group autocomplete 固定一個 search/人，精確唯一 username，無第二次猜字／REST members fallback。
- labels current/opening/preflight/ack/readback、fixed candidate 各最多1頁100；名字≤10，一次 candidate list 精確唯一匹配，絕不每個 label 搜一次。完整但超界的集合不提議，[] clear 也不能把未知 current 當空。
- milestone 一頁50，完整且唯一；不得另呼 group ancestors list；祖先可用性須由已核實的固定 connection 範圍及同回應 owner/selection 證明；現有 groupOwner 非 null 檢查不等於 ancestry 證明。hasNextPage 即拒，clear 可跳 C 但仍保留固定25。
- locator 的 activity/next/discussionNotesNext 三 reader 共用總2 logical reads；AI allowLegacyFallback:false，缺 controls拒。reaction opening/preflight/獨立 readback 各≤2頁50，三階段不是共用兩頁；reaction 更新後 note.updatedAt 不再作 readback fence（D25），接受前仍比。
- 日期 base＋edition probe worst case 每次2，不假設 cache hit；status/weight/assignee 在 target 綁定後 OAuth refresh 可能進 read epoch，D26 指定該分支拒絕、mutation0，不要求每個 replay 都成功。
- 任何新增 group probe、candidate continuation、fallback、currentFields 重讀都先更新完整算式與靜態 ledger。maxPages1 後仍 >40 的列整列不 offer；家族不能改共享40預算、拿清除／noop 的短路徑代替 worst case。

## §5 波次 B：十三個家族 MR 與檔案交接

只有 G0a–G0f 及 §6.1 的 U0 labels/l10n 已各自合併才開始。G0e 先建立下表 group 可編譯 stub part／空 rows／T 測試與 stage fixture 骨架；之後按表**一次交接**給唯一家族 owner。十三包可並行，檔案互不重疊；對共用 harness／core／主 port／guard 的缺口一律交回 seam owner 小 MR，家族不自行擴 scope。

路徑縮寫：`P=` `lib/core/ai/tools/gitlab_write_port_group_`；`R=` `lib/core/ai/tools/ledger/rows_group_`；`T=` `test/ai/mr6b3g_`；下表尾名與前綴直接串接即完整檔案名。家族都只擁有自己的 P/R/T（含 G0e 交接的 test-stage expected），除最後一列明列的既有檔案；家族完成時在自己的 T 固定完整 alias 集合，不動共用 inventory map，維持並行可合併。

| 封包 | P 尾名 | R 尾名 | T 尾名 | 契約／定向驗收重點 |
|---|---|---|---|---|
| G-P2 | state.dart | state.dart | state_test.dart | close/reopen/noop、foreign group、同 iid 不同 owner、21 |
| G-P3 | status.dart | status.dart | status_test.dart | allowed candidate、START 第五態、registry、read epoch refusal、21 |
| G-P4 | dates.dart | dates.dart | dates_test.dart | manual/inherited/clear、兩個 probe、edition 漂移、29 |
| G-P5 | health.dart | health.dart | health_test.dart | own/null、registry failure、缺 widget、21 |
| G-P6 | assignees.dart | assignees.dart | assignees_test.dart | group autocomplete、5人含舊名/4新名、截斷、37 |
| G-P8 | milestone_weight.dart | milestone.dart、weight.dart | milestone_weight_test.dart | group/ancestor vs project milestone、clear、int32、25/21 |
| G-P9 | activity_create.dart | activity_create.dart | activity_create_test.dart | create/reply、group noteable parent、locked/controls、21/29 |
| G-P10 | activity_delete.dart | activity_delete.dart | activity_delete_test.dart | 限自己、missing 不當 noop、T4、readback parent＋note:null、29 |
| G-P11 | reactions_notifications.dart | reaction.dart、notifications.dart | t1_test.dart | add/enabled、group typed T1、反向意圖、reaction三階段與readback、37/21 |
| G-P1 | content.dart | content.dart | content_test.dart | opening-before-scan、bypass hidden-span 固定確認、跨 group placeholder拒、21 |
| G-P10e | activity_edit.dart | activity_edit.dart | activity_edit_test.dart | 兩輪限自己、原 body/revision、cross-note token拒、29 |
| G-P7 | labels.dart | labels.dart | labels_test.dart | G0b完整 group catalog、scoped labels、≤10、foreign/ambiguous拒、25 |
| G-P13 | 不新增 part | 不新增 group rows | snooze_test.dart | 唯一接手 `lib/core/ai/tools/gitlab_write_port_graphql_snooze.dart`；並從 G0e 順序接手 `test/ai/mr6b3_snooze_port_test.dart` 的 owner/gate 段。保留 todoTarget project record，group producer 只填 groupTodoTarget；兩既有 accountTodo operation 增 group variant，21/21；G14前 production gate仍關 |

G-P13 跑原 snooze port 測試及新 group 測試，以 test gate on 驗 group 成功、gate off 驗舊拒絕，保留 project record 相容；之後將 production gate 測試段順序交給 G14。G-P13 不改既有 `rows_graphql_snooze.dart` 的 cap／project 可見度；gate 接 seam 在 G0e 定義的 production flag，G14 才翻。group scope exact match `(groupId,parentIid)`；accountGlobal 可以操作自己的真實 group todo，但不能藉此擴出一般 WI grant。所謂 foreign Group 在 group scope 指不同 grant 的 Group；在 accountGlobal 指回應身份不一致／偽造 namespace，而不是任意禁止該使用者在另一群組的合法待辦。

每包都填 boundary:graph、group scopeClass、欄位白名單、§3 Tier／preview／journal／write/dependency keys、§4 靜態 cap。G-P9 建立 key 固定 parent＋notes 集合，不含 body/nonce；G-P10/10e/11 note key 用 numeric noteId，依賴 group WI parent。status/dates/health 必須取得 shared registry lease，不能在 family clone 新 registry。自己作者限制同樣適用管理者。

## §6 波次 C：lead UI → G14 可見度／同意 → G15 跨家族驗收

### §6.1 U0 提前 labels；UI／UX／l10n（全數 lead-owned：Claude）

**U0 在 G0f 後、第一個家族 group row 前合併**。唯一 owner：`lib/features/ai/ai_write_ui.dart` 的15個 group operation label 分支、所需 `lib/l10n/arb/*` 與 generated strings、`test/ai/ai_write_ui_test.dart` 的 label coverage 段。`test/ai/ai_write_ui_test.dart:1045` 對 hidden rows 也驗 label，不能等到完整 UI 波次或改成只測 visible。U0 先明列全部15個固定 alias 的非 fallback label 與必要翻譯，在 rows 尚空時也測每個 ID 的 label；之後每個家族 MR 都跑原 all-rows label coverage，守衛不放寬。

全家族後 Claude 再完成上述檔案剩餘 UI 段、`lib/features/ai/ai_chat_page.dart`、`lib/features/ai/ai_chat_controller.dart` 的 UI-added 入口／scope transition 段，以及 `test/ai/ai_chat_context_test.dart`、`test/ai/mr6b3g_origin_test.dart` 的 UI scope 測試（由 G0c/G0d 順序交接）；必要 workspace UI、全部 l10n 與 `test/ai/ai_consent_dialog_test.dart` 也由 Claude 擁有。包括 group owner／完整 path／#iid 提示、刪自己 note 確認、手動解除／todo @username、缺能力／未送／ack與readback區別、scope／停止／同意文案、布局與小螢幕／RTL／大字互動。既有 T1 詞可重用，operation aliases 仍需24語方向測試。

現碼只有 `AiTargetOrigin.uiAdded` 的 enum／binding 分支，沒有群組 WI 加入流程，不能聲稱已可重用。父 v6 §2 明列 UI 加入，所以不採「只准 origin、整個排除 UI-added」的建議：Claude 在完整 UI MR 交付明確的使用者加入動作，先以受預算限制的 strict identity read 驗 Group/iid/WI GID（沿 G0b/G0d 通道），才建單一 grant／記 trusted uiAdded／開新 segment／要求對應 consent，失敗不加入；模型／工具結果不能觸發。刪除範圍、換 account/generation、同 iid foreign Group／project descendant 都測，grant 不擴成整個 group/project。這些 scope 加入讀取計入 UI/context budget，正式 write 仍重新 reserve §4 全額。

### §6.2 G14：可見度、版本與同意（家族與 UI 全合後）

唯一 owner：全部 `rows_group_*.dart` 的可見度段、`lib/core/ai/tools/write_ledger.dart` 的 production group-target gate 段、`lib/core/ai/tools/tool_catalogue_version.dart`、`lib/core/ai/ai_provider.dart` 的 writePolicy 結構段、`lib/core/ai/prompts.dart`、`lib/features/ai/ai_chat_controller.dart` 的 production policy／read-tool offer 段、`tool/tests/test_ai_boundaries.py` 的版本段、`test/ai/mr6b3_guard_test.dart` 的最終 inventory/visibility 段、`test/ai/p17_policy_visibility_test.dart`、`test/ai/p1_port_seams_test.dart`、`test/ai/p1_ledger_data_test.dart`、`test/ai/mr6b3_snooze_port_test.dart` 與 `test/ai/write_tier_test.dart` 的 production gate 段、`test/ai/ai_write_consent_test.dart`、`test/ai/fx_coord_http_budget_test.dart`、`test/ai/write_call_site_ledger_test.dart`、`test/ai/mr6b3g_visibility_test.dart`（新）、`docs/PLAN_STATUS.md`／`docs/plans/ai-writes-plan-v6.md` 的已交付群組子項與版本記錄。版本段在 G0d/G0e 完成後順序交接，不與它們同時改 shared 檔；對 `lib/core/ai/prompts.dart` 明定同包順序：Claude 先單獨完成文案段並交接檔案，G14 owner 才改 production offer／版本相關接線並整體覆核；不並行寫同檔，也不把 Claude 覆核視為第二個同時 owner。上述既有文件的更新只在未來 G14 進行，本次不改。

G14 必須同步遷移現行 production 斷言：`p17_policy_visibility_test.dart:42` 的 policy、`p1_port_seams_test.dart:56` 的 catalogue、`p1_ledger_data_test.dart:108` 的完整 visible operation 集合，以及 `mr6b3_guard_test.dart:428` 的最終33列／18 methods 封閉 mapping；原 project 操作集合仍精確保留。`write_tier_test.dart:666` 保留顯式 gate-off group-only 拒，另測 production gate-on 僅新 group aliases／兩 snooze 可 offer，markTodoDone 不可。`mr6b3_snooze_port_test.dart:609` 的真 group fixture 由 production 拒改為 gate-on own group 接受，仍保留 gate-off 拒及 projectless／fakeOuter／commit／unknown／身份不一致 Group 負例，並跑 `mr6b3_binding_test.dart` 的兩種 gate 回歸。這些不能當歷史 fixture 不改，也不能留給只擁有新檔的 G15。

在父 v6 §15 第13列的 G14 修正記錄明列：依父 breakdown §7.6，僅 group concrete read class 新增固定 namespaceWorkItem GraphQL query POST 例外；project port 的11個成員與 GET/HEAD-only 不變，禁止任意 query、mutation 及全域 HTTP 豁免。

目前 catalogue=4（`lib/core/ai/tools/tool_catalogue_version.dart:1`）、policy=3（`lib/features/ai/ai_chat_controller.dart:2780`）、disclosure=2（`lib/core/ai/ai_provider.dart:346`）。本基準預定 catalogue **4→5**、policy **3→4**；disclosure 2 保留，沒有新增資料類別。若前置 main 已升版，取當前下一版、同步改所有現行斷言，歷史 fixture 不機械加一。group read tool 在 G0d 隨 plumbing 落地，但到本包才對 production model offer，避免先加工具不更新凍結 catalogue/同意。

所有15 group rows visible→true、snooze group-target gate→on 必須與 policy/hash 重同意一同交付；舊 consent（含唯讀）不能授權新工具。secret/provider/recipient/scope revision 變動使舊 proposal/segment 失效；toolsEnabled:false、唯讀 ceiling、無 scope 都不 offer。固定確認理由與硬底線不得因 group alias 遺失。

inventory 不再假設每個 namedMethod 只有一個 operation：固定 mapping 明列18個原 operation＋15個 group alias，仍是18個 unique named methods／17個實體 graph mutation send sites（計的是具名方法內的送出位置，不是 GraphQL 文件數；create/reply共用）。snooze兩列沒有重複新 alias；沒有新增 incident group alias。每個 group alias 恰映射到既有 namedMethod/site、未知 row/site 失敗。全部可見 write rows 的 budget expected 聯集要加群組獨立 counter，不只改 guard 常數使它綠。

### §6.3 G15：跨家族驗收（僅新測試）

唯一 owner：`test/ai/mr6b3g_injection_test.dart`、`mr6b3g_isolation_test.dart`、`mr6b3g_races_test.dart`、`mr6b3g_matrix_test.dart`、`mr6b3g_guard_test.dart`、`mr6b3g_binding_test.dart`、`mr6b3g_budget_test.dart`、`mr6b3g_boundary_test.dart`（八檔均在 `test/ai/`，新）。只讀既有 harness，不改 lib 或家族測試；缺陷退回 owner。

獨立 FakeAdapter 計數不得從 row.httpCap 算 expected。每列重做 proposal/dispatch、各 opening/preflight/readback、cold dates probe、完整最大頁、OAuth一重播與PAT、mutation0/1、cap−1拒/cap可保留、39/40/41邊界、所有 noop/flush/revert/late completion。status/assignee/weight 的每讀401分支依D26斷言精確 refusal與mutation0，另用不觸發 epoch drift 的可達路徑驗 success；不能為湊 worst-case 成功而關閉 core fence。

父計畫 §15 第10/24群組正負案例全部由本包整合重跑：foreign Group GID、URL path正確但numeric ID不符、UI assertion偽group、無project真group todo、accountGlobal＋無法驗證target、descendant project key與 REST/board相交、改名鎖保留、手動解除名稱；還要 group UI/AI registry 互斥、固定確認與硬底線五等級矩陣、source group→public project污染、所有文字/附件guard。

## §7 安全不變式與接受標準

1. **身份**：instance包含 scheme/host/port/installation subpath；account numeric user綁generation/API。fresh strict namespace同時驗 Group GID數字、fullPath、iid、WI GID與存在的project:null／namespace欄位；foreign scheme/host/port/base path、錯GID type、path-only、project/group同數字、grandparent冒直接owner全部拒。
2. **grant**：group grant只含一個WI及其子資源；project-from-group origin只含實際project WI，不含該project其他資源。模型讀到URL/GID不能新增grant；UI-added／verified URL後仍需fresh歸屬，確認不能放行foreign target。
3. **key**：帳號＋group數字ID為parent，WI GID只別名；notes/emoji/notifications/todo依賴parent。不同操作、nonce、run、入口、改名不繞隔離。project descendant與原REST/board既有numeric project key相交，group key永不與project key互認。
4. **文字**：G0a provenance＋已交付兩輪opening-before-scan；hiddenContentRemoved 在bypass仍固定確認；quick action中和、外部圖片(A)一律拒、known secrets、群組/大量提及、範圍外closing/cross-reference、upload redaction與位置約束都保留。`[[attachment:att-n]]` 在無project group WI拒；`[[upload:u-n]]` 只有同account/group/iid/note/field完整值可原處還原。
5. **政策**：T1仍要本次可信entry、原operation、方向與typed target；T4刪除仍照五等級矩陣（bypass可自動但固定確認／scope不豁免）。硬底線T5/CI設定／新variables／confidential降低／visibility提高／fork均維持需typed name；本批group工具不提供這些欄位或能力。
6. **送出與隔離**：不新增journal transition，accepted後不以failedCertain放寬；不重送mutation、不自動解鎖，觀察read不等於消除uncertain。flush後同步policy/consent/generation/API/scope/epoch/current/Retry-After重驗與唯一mutation間無await。

## §8 實作驗收指令、列責任與合併順序

所有命令工作目錄是 repo root，使用 pinned FVM及已提交lock；不以系統Flutter代替。首次準備先 `fvm flutter pub get --enforce-lockfile`。以下是**未來命令，NOT_RUN**；新測試檔由其owner於各MR建立，不能現在把缺檔測試當PASS。

每包共有閘門（targeted tests完成後）：

```sh
fvm flutter analyze --no-pub
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tool/tests -p 'test_ai_boundaries.py' -v
fvm flutter test --no-pub test/ai/write_call_site_ledger_test.dart test/ai/mr6b3_guard_test.dart test/ai/ai_write_ui_test.dart
git diff --check
```

| MR／前置 | 精確 targeted acceptance command | 父 §15 主責列／狀態 |
|---|---|---|
| G0a／本HEAD | `fvm flutter test --no-pub test/ai/mr6b3g_identity_test.dart test/ai/write_text_test.dart` | 10、16、24、32；NOT_RUN |
| G0b／G0a | `fvm flutter test --no-pub test/ai/mr6b3g_core_reads_test.dart test/work_item_graphql_api_test.dart test/work_item_labels_api_test.dart test/todo_snooze_test.dart test/todo_snooze_api_ack_test.dart` | 10、13、19、24、25；NOT_RUN |
| G0c／G0b，UI switch 由Claude | `fvm flutter test --no-pub test/ai/mr6b3g_origin_test.dart test/ai/ai_chat_context_test.dart test/ai/ai_run_registry_test.dart` | 4、10、12、16、24；NOT_RUN；同包 analyze 必含全部 sealed switches |
| G0d／G0c | `fvm flutter test --no-pub test/ai/mr6b3g_read_tool_test.dart test/ai/mr6b3g_freshness_test.dart test/ai/mr6b3_guard_test.dart test/ai/ai_tools_test.dart test/work_item_graphql_api_test.dart` | 10、13、14、16、19、24、32；NOT_RUN |
| G0e／G0d | `fvm flutter test --no-pub test/ai/mr6b3g_seams_test.dart test/ai/write_tier_test.dart test/ai/mr6b3_binding_test.dart test/ai/mr6b3_dispatch_test.dart test/ai/mr6b3_guard_test.dart test/ai/mr6b3_snooze_port_test.dart test/ai/ai_write_port_test.dart test/ai/fx_coord_todo_test.dart` | 8、10、13、16、21、24、25、29；NOT_RUN；舊group負面斷言由本包改驗未交付gate／foreign拒 |
| G0f／G0e，Claude | `fvm flutter test --no-pub test/ai/mr6b3g_registry_test.dart test/ai/p15_registry_rewire_test.dart` | 6、10、24、25；NOT_RUN |
| U0／G0f，Claude | `fvm flutter test --no-pub test/ai/ai_write_ui_test.dart`；`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tool/tests -p 'test_l10n*.py' -v` | 2、11、24；NOT_RUN；先覆蓋15個alias label，再放行家族 |
| 十三家族／G0f＋U0 | 下段十三條，一包一條＋共有閘門 | 1、5–8、10、13、16、19、24、25、29；文字族另14/23/32，T1另15；NOT_RUN |
| UI／全家族，Claude | `fvm flutter test --no-pub test/ai/ai_write_ui_test.dart test/ai/ai_consent_dialog_test.dart test/ai/ai_chat_context_test.dart test/ai/mr6b3g_origin_test.dart`；`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tool/tests -p 'test_l10n*.py' -v` | 2、7、11、15、24；NOT_RUN；24語與手機QA不得以host widget代替 |
| G14／家族＋UI | `fvm flutter test --no-pub test/ai/mr6b3g_visibility_test.dart test/ai/ai_write_consent_test.dart test/ai/fx_coord_http_budget_test.dart test/ai/write_call_site_ledger_test.dart test/ai/p17_policy_visibility_test.dart test/ai/p1_port_seams_test.dart test/ai/p1_ledger_data_test.dart test/ai/mr6b3_guard_test.dart test/ai/mr6b3_snooze_port_test.dart test/ai/write_tier_test.dart test/ai/mr6b3_binding_test.dart` | 8、11–13、15、19、21、24；NOT_RUN |
| G15／G14 | `fvm flutter test --no-pub test/ai/mr6b3g_injection_test.dart test/ai/mr6b3g_isolation_test.dart test/ai/mr6b3g_races_test.dart test/ai/mr6b3g_matrix_test.dart test/ai/mr6b3g_guard_test.dart test/ai/mr6b3g_binding_test.dart test/ai/mr6b3g_budget_test.dart test/ai/mr6b3g_boundary_test.dart` | 1、3–8、10、11、13–16、18、19、21、23–25、29、32跨家族子項；NOT_RUN |

十三家族的 exact command（名稱與§5一一對應）：

```sh
fvm flutter test --no-pub test/ai/mr6b3g_state_test.dart
fvm flutter test --no-pub test/ai/mr6b3g_status_test.dart
fvm flutter test --no-pub test/ai/mr6b3g_dates_test.dart
fvm flutter test --no-pub test/ai/mr6b3g_health_test.dart
fvm flutter test --no-pub test/ai/mr6b3g_assignees_test.dart
fvm flutter test --no-pub test/ai/mr6b3g_milestone_weight_test.dart
fvm flutter test --no-pub test/ai/mr6b3g_activity_create_test.dart
fvm flutter test --no-pub test/ai/mr6b3g_activity_delete_test.dart
fvm flutter test --no-pub test/ai/mr6b3g_t1_test.dart
fvm flutter test --no-pub test/ai/mr6b3g_content_test.dart
fvm flutter test --no-pub test/ai/mr6b3g_activity_edit_test.dart
fvm flutter test --no-pub test/ai/mr6b3g_labels_test.dart
fvm flutter test --no-pub test/ai/mr6b3g_snooze_test.dart test/ai/mr6b3_snooze_port_test.dart
```

G15正式整合再跑 `fvm flutter test --no-pub`、`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tool/tests -p 'test_*.py' -v` 與 `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s ci/tests -p '*_test.py' -v`；分析／測試／CI紀錄都綁最終提交，不累加舊測試數。Claude依專案規則在owned Android emulator用public資源提議並拒絕每筆寫入，記錄GitLab mutation0；真實成功群組CRUD另需受控整合證據，不以reject-only QA宣稱成功。

順序：`main → G0a → G0b → G0c → G0d → G0e → G0f → Claude U0 labels/l10n → 十三家族小MR → Claude 完整 UI/l10n → G14 → G15`。G15可預寫測試，但正式驗收必在可見度/consent後；每家族的cap、安全、精確inventory與all-rows labels測試不能等到G15；每個MR的完整flutter_checks也須綠才合，targeted PASS不代表pipeline成功。合併與mirror動作是未來lead流程，本次不執行。

## §9 風險、未解問題與保守預設

| 風險／待實作查證 | 保守預設與owner／關閉條件 |
|---|---|
| GitLab版本／edition／feature flag／group WI type 的widget差異 | 缺欄位／permission／widget即unsupported；不probe後改query重送，不用名字推測。G0b及各家族以固定schema fixture＋目標環境證據關閉；live目前NOT_RUN。 |
| Group GID/path／rename／直接owner與descendant混淆 | 數字ID為身份，fresh path需與grant一致；改名令舊proposal失效並要求重新開啟/加入，鎖不變。G0a/G0c/G15。 |
| group候選祖先繼承語意未被實例證實 | 只接受fixed回應中可證owner；不包含descendant/project。milestone先一頁50、label先一頁100，截斷拒；必要修core另小MR並重算。G0b/G-P7/G-P8。 |
| source group visibility／WI confidential 證據不完整 | G0c保存已驗metadata／unknown，G0d接最嚴source rank及污染；現有WI固定query未提供confidential，不能憑模型或缺欄推定false。若目標schema需新增欄位才能證實，先由G0b owner交付有測試的core follow-up、維持固定文件／同次read並驗一般UI相容性；未完成前相關自動路徑保持確認，live五等級可達性仍NOT_RUN。 |
| 先增加15 operation aliases會漏intent/text/inventory判斷 | G0e列封閉mapping、graphWriteBack兩輪接線；G14/G15要求每個alias的schema/label/tier/cap/method/site覆蓋，不符合保持hidden。 |
| group read tool不能提供完整活動note provenance | 最小工具只保證WI description；note無可證token則拒還原，普通安全body可編輯。擴活動read tool留另案，不放寬同欄規則。G0d/G-P10e。 |
| stale PLAN_STATUS／未來main版本已移動 | 每包開始重核HEAD、citations、已交付tests與版本；G14才在其MR更新狀態頁／父計畫相關項，不拿舊Building當缺實作。 |
| API無原子CAS、跨裝置外部寫入 | 保留revision/fence/readback及uncertain隔離，揭露最終preflight→mutation競態，不能聲稱原子保護。各家族＋Claude。 |
| group todo有身份但資源scope不是該群組／accountGlobal誤擴權 | exact Group+iid不符拒；accountGlobal僅own Todo，不衍生WI grant；其餘project-null目標仍unsupported。G-P13/G15。 |
| 舊path-key journal／未知schema資料 | 保留隔離，不自動改key/刪entry；若真有資料另做可驗證遷移小MR。G0a/G15；journal目前不修改。 |
| 超40的隱藏probe／重讀／OAuth refresh epoch | 先獨立計數，再調呼叫圖/有界頁數；仍超限就整列hidden。refresh後精確拒絕可以是正確結果；不拆第二個budget逃上限。G-P各族/G15。 |
| 自訂group read scope牽涉既有project工具 | 保留project scope/constructor，不用nullable/dummy project身份偷渡；group catalogue只列固定group工具，direct-call project工具mutation/read0。G0c/G0d。 |

以上無需額外使用者裁決；採自主、保守預設，無法證明的能力保持拒絕。擴大scope、上傳group附件、group labels/milestones CRUD、CAS新策略、提高頁數與接受後failedCertain均留後續計畫。

## 附錄 A：GitLab外部事實與可追溯來源

下表保留 v1 的 **2026-10-27 查閱**記錄；本次 v2 以 checkout 查證規劃缺口，未重新連線覆核官方URL內容。G0b／各家族開工先核對其使用的官方頁面／anchor並記錄日期、版本與適用界線；是移動中的官方reference，不是本實例pinned schema，更不是已完成live相容性驗收。

| 使用的事實 | 官方來源／使用界線 |
|---|---|
| namespace(fullPath).workItem(iid) 可查直接隸屬project/group namespace的WI | [Namespace GraphQL reference](https://docs.gitlab.com/api/graphql/reference/objects/#namespace)；欄位標experimental，iid在GraphQL為String；app正整數需安全轉字串，不以descendant搜尋結果當直接owner。 |
| WI id與iid不同；schema的namespace/project均nullable | [WorkItem reference](https://docs.gitlab.com/api/graphql/reference/objects/#workitem)、[Epic→Work Item遷移指南](https://docs.gitlab.com/api/graphql/epic_work_items_api_migration_guide/#query-epics)；Epic GID與WorkItem GID不可互換。這不保證所有版本的group WI必有project:null；本計畫僅接受實際回應project:null且namespace Group GID與授權一致的已驗證路徑，任一缺欄／不符即拒。 |
| Group有autocompleteUsers、labels、milestones；候選connection有不同ancestor/descendant參數 | [Group reference](https://docs.gitlab.com/api/graphql/reference/objects/#group)；用於固定group query，不推論對每個WI type的可用性／候選完整性。精確filters/欄位/owner chain **實作時查證**，查不到即拒。 |
| group WI web URL／relative upload base、group freshness與milestone查詢預設 | **實作時查證**：G0a/G0b owner 以目標版本官方文件／upstream route、UploadLinkFilter 與 fixture 核對群組WI URL（常見候選 `/groups/<path>/-/work_items/<iid>`，Epic歷史路由不可直接套）、installation subpath與 `./`/`../` upload解析；未證實resourceWeb不產生可還原token／可點連結，不以猜測URL建立身份。G0d核對 `group(id)` 的 `with_projects:false` HTTP fixture；G-P8核對省略includeDescendants的connection語意，未證實拒候選，不靠path前綴推授權。 |
| group/project labels與milestones是不同owner範圍 | [Labels types](https://docs.gitlab.com/user/project/labels/#types-of-labels)、[Milestones](https://docs.gitlab.com/user/project/milestones/)；group label可用於群組／子群組不等於候選query要納入全部descendants，ancestor可指派性仍需實例驗證。 |
| widget availability與mutation input必須逐一驗 | [WorkItemWidget reference](https://docs.gitlab.com/api/graphql/reference/interfaces/#workitemwidget)、[官方GraphQL reference](https://docs.gitlab.com/api/graphql/reference/)；現有core方法是重用依據，缺widget/permission不得從類型名稱推得可寫；所有目標版本行為 **實作時查證**。 |
| 現有incident操作處於project脈絡 | [Manage incidents](https://docs.gitlab.com/operations/incident_management/manage_incidents/#create-an-incident) 加本地incident_api證據；本計畫只排除現有project incident流程，不斷言所有GitLab未來版本永無群組incident。 |

snooze filter語意、ack、whole-second時間沿已交付D25及core固定文件；實例是否暴露group WI target fragments／namespace權限 **實作時查證**。未查證前保守拒絕，無REST排除法或額外未計數fallback。

## 附錄 B：群組拒絕基線與accountGlobal反例的遷移

舊group deny不整批刪除：G0d只改按class分隔的read allowlist、read plumbing及write掃描基線，write namespace仍禁；G0e同包新增write namespace定點／exact delta，將deny換成numeric scope/grant驗證、建立獨立test-stage inventory，並保持rows hidden。U0先補全部label；家族只填自己的stage fixture與rows。G-P13只完成group todo分支；G14才同時開模型可見度與group-target gate。每階段舊project功能仍可用，未交付group路徑direct-call拒。

必做負面fixture：同path+iid、foreign Group GID；Group GID被冒作WI GID；同numeric project/group；外層偽project、target.project:null；project WI的namespace是Group；ancestor root代替真正subgroup owner；accountGlobal＋未知無project；group grant＋另一group自己的todo；同instance不同installation prefix；UIAdded斷言但身份漂移。每個都驗API請求上限、mutation0、無一般grant擴張，不只看錯誤字串。

既有測試交接固定為 G0e→G-P13→G14（snooze owner/gate 段）與 G0e→G14（tier/binding gate 段；binding 如無需改動則G14只重跑）。`mr6b3_snooze_port_test.dart:609` 的 group fixture 不能永遠列在unsupported迴圈：保留顯式gate-off反例，另以gate-on走own真group正例；projectless／fakeOuter／commit／unknown及不一致Group仍拒，不能整段刪除。

正面fixture：明確存在project:null＋真Group namespace＋精確WI GID可以建proposal；project descendant保留project key；自己的真group todo在pending/non-snoozed清單內可snooze，不用snoozed:true查不到當todoNotFound；unsnooze用另一固定查詢；未知／截斷仍拒。成功、已接受、獨立readback、未執行、uncertain必須分別陳述。

## 附錄 C：父計畫 §15 第10／24列的逐子項owner

| 父列子項 | 主 owner；前置／協作交付 | 整合覆核／目前狀態 |
|---|---|---|
| 10：global ID/foreign target拒、白名單固定 | G0e；前置G0a/G0b身份、G0d read guard；家族逐列驗readback | G15 binding/guard；NOT_RUN |
| 10：群組頁開project WI只授權該WI/子資源、取得project key | G0d；前置G0c origin；G0f入口 | G15 binding/matrix，與REST/board對照；NOT_RUN |
| 24：無project群組WI正確proposal、grant不涵蓋projects/兄弟WI | G0e；各家族依該契約交付各列 | G15 matrix；NOT_RUN |
| 24：foreign Group GID拒、URL-only不綁身份 | G0e；前置G0a helper、G0b strict read | G15 binding；NOT_RUN |
| 24：REST/Graph/board同project key、group與project分離、rename鎖不變、WI GID alias | G0e；前置G0a key契約；家族交付write/dependency keys | G15 isolation；NOT_RUN |
| 24：group WI手動解除名稱 `<groupPath>#iid` | Claude完整UI；前置各家族prepared releaseName | G15 isolation/matrix；NOT_RUN |
| 24：descendant project來源origin與project key | G0f；前置G0c origin、G0d單WI grant | G15 binding/races；NOT_RUN |
| 24：group todo可延後、正確兩個查詢、截斷不當查無 | G-P13；前置G0b ownership、G0e typed seam；G14開gate | G15 budget/binding；NOT_RUN |
| 24：foreign account/Group target與unsupported型別拒 | G-P13；前置G0b parser、G0e binding；G14遷移舊反例 | G15 binding/boundary；NOT_RUN |

計畫停止條件：九項有今日證據；18 operations逐列有適用性；17條可擴展路徑有重新計算的cap；每stage有單檔owner、依賴、可執行acceptance與NOT_RUN；UI/l10n歸Claude；外部事實有URL/查閱日期或實作時查證；本次僅修訂本文件且HEAD維持v1 docs commit，不新增commit。產品analyze/tests、CI、Android/iOS、live group CRUD、私有帳號、G0與publication全部 **NOT_RUN**，不因規劃完成而關閉。
