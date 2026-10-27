# MR6c 實作封包：背景工作（規劃，尚未實作）

基準：2026-10-27，分支 `docs/mr6c-breakdown`，HEAD `85e9309e64efeeea0820da0c9dde750a182f23e0`。本文現有檔案路徑均相對 repository，`file:line` 已依此 checkout 查核；標「新」的檔案與介面是交付要求，尚不存在。實作前各 owner 必須對自己的合併基準重新定錨，不能沿抄舊 breakdown 的行號。

本次只新增本計畫；沒有修改產品、依賴、其他計畫或 native 生成物，沒有 commit，也沒有執行測試、bootstrap、建置、模擬器或 live API。下列驗收命令全部是未來要求，**不是本次 PASS**。`docs/PLAN_STATUS.md:44` 的 MR6c 仍為 Not started；本次不改狀態。

拘束來源：父計畫 `docs/plans/ai-writes-plan-v6.md` §12.1–12.7、§14 MR6c、§15 第 22／27／28 列及相關送出邊界；§24 修正優先於舊正文。結構沿用 MR6b-2／MR6b-3 的「現況、共同契約、分波所有權、逐封包驗收、主導者畫面、未解問題」。決定風格沿用 `docs/plans/mr6b3-decisions.md:7` 的自主、保守、小 MR；本文 D1–D12 是**建議預設**，不冒稱 lead 已確認。

## §0 交付範圍與停止條件

- Android 主 isolate runner ＋ bootstrap 生成的原生 `AgentRunService`；服務不執行 Dart、不建立第二個 engine。
- 原生執行許可、一次性 continuation ticket、最後同步送出檢查；REST／GraphQL／模型三條邊界都接上。
- 原生擁有前景通知與「全部停止」；鎖定穩定版的 `flutter_local_notifications` 只投遞一般通知與開啟 app。
- 沒有服務時的安全暫停、前景明確續跑、啟動被拒降級、app lock 後通知導頁、根頁返回、移除工作與日誌恢復。
- 每個小 MR 都可獨立 analyze／執行自己的測試；最後在專案的 Pixel_9 與受控 API 34／35／36 AVD 矩陣驗收。缺少的環境或未跑的案例逐項標 `NOT_RUN`。

MR6c 完成條件為 §15 第 22／27 列、實際服務下的第 28 列，以及 §12.5／§12.7 對應證據全部有明確結果；未執行的系統 timeout 不得用合成回呼填 PASS。iOS 實作、建置與裝置驗證維持 `NOT_RUN`，不藉本批宣稱跨平台背景能力完成。AI release gate 保持關閉，Play 申報 G6／沙箱真實寫入／開 gate 仍由 MR7 承接（父計畫 `docs/plans/ai-writes-plan-v6.md:493`、`docs/plans/ai-writes-plan-v6.md:526`）。

## §1 現況與缺口（目前原始碼證據）

| 項目 | 已存在 | MR6c 還缺什麼 |
|---|---|---|
| 帳號範圍 registry | `lib/features/ai/ai_chat_session.dart:364` 定義頁面之外的生命週期、`lib/features/ai/ai_chat_session.dart:367` 上限 3；真正實作在 `lib/features/ai/ai_run_registry.dart:73`，`lib/features/ai/ai_run_registry.dart:114` 驗 account／generation／API，`lib/features/ai/ai_run_registry.dart:152` 計 running／stopping。`lib/features/shell/authenticated_app.dart:289` 把 registry／AiScope 包在 MaterialApp 上方。 | 背景執行 owner、原生許可綁定、可觀察的暫停原因、服務活動計數與通知事件；不是重建另一套 registry。 |
| 頁面結束與停止 | registry 的 release／保留邏輯在 `lib/features/ai/ai_run_registry.dart:202`；`lib/features/ai/ai_run_registry.dart:168` 的現有方法是 `stopAndSnapshotWrites()`，不是 `stopAll()`。`lib/features/ai/ai_chat_controller.dart:2550` 停止 runner。 | 通知 stopAll adapter、許可先失效的 native 協定；頁面關閉不能被誤判為停止服務的唯一依據。 |
| runner | `lib/core/ai/runner.dart:247` 的 stop 只 cancel active provider request，settings stop 才 close transport；`lib/core/ai/runner.dart:644` 持有底層 GitLab Future 直到結算，`lib/core/ai/runner.dart:678` 寫入不套 read soft timeout。`lib/core/ai/runner.dart:653` 與 `lib/core/ai/runner.dart:1179` 已暫停等待核准期間的主動時限。 | `lib/core/ai/runner.dart:476` 到 `lib/core/ai/runner.dart:485` 的模型送出前沒有原生取票；`AiRunGuard`（`lib/core/ai/runner.dart:19`）只處理帳號／API／recipient／consent，不是 native 許可。模型也需要無服務時的背景關卡。 |
| 既有 foreground gate | `lib/features/ai/ai_run_registry.dart:54` 的 predicate 把 resumed／inactive 當可見；`lib/features/ai/ai_chat_controller.dart:1207` 與 `lib/features/ai/ai_chat_controller.dart:1240` 分別讀 send gate／snapshot；`lib/core/ai/tools/write_coordinator.dart:1443` 拒絕背景寫入。 | 加獨立 execution authorization，不可把 `appInForeground` 偽造為 true。取得 native 許可不能繞過 app lock、帳號、policy、consent、removal 或 429。 |
| mutation 接受點 | `lib/core/ai/tools/write_coordinator.dart:1121` 為 Graph beforeMutation，`lib/core/ai/tools/write_coordinator.dart:1142` 為 REST markDispatching，`lib/core/ai/tools/write_coordinator.dart:1148` 最後同步 mayStart，`lib/core/ai/tools/write_coordinator.dart:1169` 才 accepted；`lib/core/ai/tools/gitlab_write_port.dart:281` 的 GraphHooks 與 `lib/core/ai/tools/gitlab_write_port.dart:916` 的 REST 防重已存在。 | flush 前取得 native ticket，mayStart 同步消耗；不能把取票放在 Graph 方法前置讀取之前，不能在 mayStart 裡 await。 |
| 續跑與日誌 | `lib/core/ai/tools/write_coordinator.dart:573` 已有 `resumeRun()`，`lib/core/ai/tools/write_coordinator.dart:588` 的 resume 只讀摘要；`test/ai/packet7_runner_test.dart:198` 測一行投影，`test/ai/followup12_gate_duplicates_test.dart:126` 測同 run 重複確認。 | `lib/core/ai/runner.dart:383` 每次 run 都 beginRun，而 coordinator 的 beginRun（`lib/core/ai/tools/write_coordinator.dart:559`）重設 run ID。不能把背景續跑直接接成一般 send；要保留邏輯 run／額度／結果，真正串到 resumeRun。 |
| 在途寫入／移除帳號 | `lib/core/ai/tools/write_coordinator.dart:1390` 停止後仍持有 settlement；`lib/features/ai/ai_account_removal.dart:525` 的 activity stop／wait 與 `lib/features/shell/authenticated_app.dart:848` 的移除流程已存在。 | native 停止不得 close GitLab client 或清掉 journal；帳號切換／移除維持原 fence、typed name、等待上限。此處只是回歸，並非重新設計移除帳號。 |
| app lock | `lib/features/security/app_lock.dart:54` 是裝置級設定；`lib/features/security/app_lock.dart:174` 處理離開／回前景，`lib/features/security/app_lock.dart:194` 攔 back；`lib/features/security/app_lock.dart:210` 的 AppLockGate 初始遮罩、`lib/features/security/app_lock.dart:273` 隱藏內容的觸控與 semantics。`lib/features/shell/authenticated_app.dart:243` 已包 Navigator。 | 通知入口必須等待 gate 真正放行後才導向；不能只因 route 在遮罩下面就當通知驗證完成。不新增第二套 app lock。 |
| shell back | `lib/features/shell/authenticated_app.dart:1285` 首頁且無 detail 時 canPop=true；`lib/features/shell/authenticated_app.dart:1288` 先處理 detail，`lib/features/shell/authenticated_app.dart:1291` 非首頁改回首頁。 | live run 時阻止 Activity 被 back 結束，最後才 moveTaskToBack；保留 detail／分頁返回次序與無 run 行為。 |
| bootstrap | `tool/bootstrap.py:174` 禁 backup／cleartext、排除五種備份域；`tool/bootstrap.py:285` 保留 local_auth 所需 FlutterFragmentActivity 與 update／link channels；`tool/bootstrap.py:523` 嚴格驗 MainActivity／managed Gradle，`tool/bootstrap.py:553` 組合生成。`tool/bootstrap.py:758` 遇既有 native 目錄拒絕覆寫。 | service／channel／manifest／Java 17／desugaring 生成；未知、漂移、半套模板仍 fail closed。管理函式冪等與 CLI 可重跑是兩件事。 |
| bootstrap 測試 | `tool/tests/test_bootstrap.py:225` 現只允許一個 permission；`tool/tests/test_bootstrap.py:240` 測 signing／managed blocks 冪等；`tool/tests/test_bootstrap.py:384` 測雙 flavor／local_auth／links，`tool/tests/test_bootstrap.py:424` 拒絕未知 Activity。 | permission 改成明確集合且不得重複；新增 service、許可、失效次序、timeout、雙 flavor merged manifest 測項。Python 字串測試不能證明 Kotlin 編譯與 OS 行為。 |

本次搜尋 bootstrap、其測試、`pubspec.yaml`／`pubspec.lock`，尚無 `AgentRunService`、`acquireContinuation`、`onTimeout`、`flutter_local_notifications` 實作；不是把父計畫的描述當成已交付。`CLAUDE.md:31` 明定 android／ios 不提交；`.gitlab-ci.yml:75` 的 native_templates 遇既有目錄只 check SDK，因此驗新生成器要乾淨隔離目錄，不能拿舊 android build 冒充。

## §2 共同契約與建議決定

### §2.1 D1–D6：native、ticket 與接受點

**D1 — 一個 native service owner。** `tool/bootstrap.py` 在 shared main source set 生成 AgentRunService／channel，兩 flavor 共用同一實作，沿既有 flavor applicationId 隔離。manifest 為 `exported=false`、`foregroundServiceType=dataSync`、`stopWithTask=true`；`START_NOT_STICKY`，不採 cached engine、開機 receiver、背景 isolate、外掛 FGS、電池最佳化豁免。服務狀態只存記憶體；程序重啟從無許可開始。不得以父計畫「約 50 行」限制安全狀態機的必要大小。

**D2 — 許可狀態與 channel v1。** 新 `io.gitlabmobile/agent_runs` channel 與既有 links／update 分開。固定方法為 `startRuns`（可見 UI 的 send／resume／approve 觸發，回 active permit）、`updateProgress`（僅安全的工作數與步驟）、`releaseRuns`（正常無 active work）、`stopAll`（使用者停止）、`acquireContinuation(permitId, kind, nonce)`、`moveTaskToBack`。回呼為 `permitInvalidated(reason)`，僅供加速 UI 更新，不是安全權限依據。start 的 Future 只有 startForeground 成功後才回許可；失敗回 typed reason，沒有半有效許可。

許可狀態是 starting → active → released 或 invalidated；每次真正重啟建立隨機新 ID，重複 start active service 回同一 ID。registry 綁 account／generation／conversation／邏輯 run；服務已 active 時，新 run 用同一張有效 permit。失效 run 不能因另一段新 run 啟服務而自動重綁。正常 release（全部結束或只剩等待確認）與 timeout／stop／destroy 的 invalidated 必須分開，前者不把未到期的等待提議當使用者拒絕。

**D3 — 票只有一次機會。** kind 僅 `model`／`mutation`；nonce 為每次續點的新值。native 在同一序列化狀態機內檢查 active permit、kind、nonce 重放，再一次核發回覆；回覆綁 permit／kind／nonce／ticketId。Dart bridge 檢查回覆形狀、當前 run 綁定、請求未取消，回傳具同步 consumeOnce 的記憶體物件。不同 run／kind、舊 permit、重放、異常回覆、channel unavailable 與 **1 秒逾時**都拒絕；晚到回覆永不復活暫停的 run。票不落盤、不進 notification payload／log／history，不以第二次 channel consume（會 await）作最後關卡。native nonce 記錄與 Dart 票都有生命週期界限；飽和即暫停，不清表後接受舊 nonce。

**D4 — 三個送出位置。** core 只依賴新純 Dart execution-gate 介面（不 import Flutter／MethodChannel），feature bridge 實作它。

1. 模型：完成 redaction、payload encoding、secret 與 owner 檢查後，取票；await 回來再同步重驗 guard／stop／deadline／run 綁定並 consume，緊接 `_complete`，中間無 await。取票等待不算模型 HTTP 次數，未送不計費；既有六次模型／十二次工具／12 分鐘主動時限不能因續跑重置。
2. REST：現有 client precheck → 取票 → journal markDispatching／flush → 同步重驗所有既有 guard＋票與背景條件 → consume → 唯一 mutation，中間無 await。
3. Graph：先保留方法原有 preflight／noop；在 beforeMutation 裡才 precheck／取票／flush；方法的 mayStart 同步重驗並 consume，再唯一 mutation。不得在呼叫整個 Graph 方法前先取票冒充最終授權。

無 permit 的 foreground-only run 不要求 native 票，但最後同步重驗仍須可見；進背景不得開始新模型／mutation。已綁 permit 的 run 即使回前景也不能以 foreground shortcut 繞過取票失敗或失效 latch。

**現有 foreground gate 必須真的拆開。** `lib/core/ai/tools/write_coordinator.dart:1439` 的 `_pauseOf` 目前由實際 foreground 一律拒絕背景，且 `_policyFailure`、`_requirePending` 與核准共用它；只插取票而不改此處，合法背景工作仍完全不能前進。C2a 分成 execution eligibility 與 approval eligibility：前者在實際可見、或該 run 綁定未失效 active permit 時允許準備／自動等級的執行，最終送出仍照上段逐次取票；後者始終要求實際可見。permit 快取狀態只供準備與呈現，不是最後授權。`lib/core/ai/tools/write_coordinator.dart:958` 的 `_approve` 必須保留獨立 foreground-only hold，不能因有 permit 在背景接受核准；proposal 的 waiting／paused 呈現亦依核准條件。`lib/features/ai/ai_chat_controller.dart:1207` 的 execution gate 與 `lib/features/ai/ai_chat_controller.dart:1240` 的 snapshot 採一致 execution eligibility，`appInForeground` 仍存真實值；UI send／approve 另外維持實際可見與既有鎖／policy 條件。removal hold、clientMayStart／429、owner、consent 等其他拒絕條件完全保留。

**D5 — 失效競態的誠實界限。** native 失效先於取票判定：不核票、零新呼叫。有效回覆已核發／排入 channel 才失效：該一次票可能成為在途；若 Dart 已收到失效或其他 guard 失效則仍拒絕，否則按已核發票的契約處理，後續不再發票。不能宣稱能撤回已核發票或已接受的 HTTP。Graph preflight 中失效則 hook 取不到票，mutation=0。票使用後不能供另一個 mutation 或模型用。

**D6 — 日誌分類不放寬。** 取不到票且尚 prepared → notExecuted／退款；flush 後同步關卡不通過 → 既有 dispatching→notExecuted 原子 rollback／退款／恢復待確認標記；rollback 失敗維持隔離。安全暫停只能發生在送出邊界之前；已進 flush 後拒絕的那張 approval 不得續跑重送（`docs/plans/mr6b1-breakdown.md:667`）。已接受者沿原 settle；停止、timeout 不關 GitLab client，晚到確定結果由 journal 收尾，client close／程序死亡仍照未知恢復。native 不聲稱已寫 Dart 的加密日誌（父計畫 `docs/plans/ai-writes-plan-v6.md:298`、`docs/plans/ai-writes-plan-v6.md:301`、`docs/plans/ai-writes-plan-v6.md:333`、`docs/plans/ai-writes-plan-v6.md:472`）。

### §2.2 D7–D12：生命週期、通知與恢復

**D7 — 分開三種計數。** 保留 maxRunning=3；新增 serviceWorkCount（執行中及仍有在途 settlement 的工作，不含純等待核准／已暫停），與 backProtectedCount（尚未結束的邏輯工作，包含 awaitingApproval／待使用者續跑）。registry 的現有 runningCount 不足以表達這三者。最後 active work 結束或全部僅等待確認即 release service；不能提早截斷已接受 mutation 的 readback。失效許可立刻停止服務不受 settlement 阻擋。

**D8 — 無服務即安全暫停。** start 被拒允許該 run 在可見前景繼續；hidden／paused 起，在下一安全續點暫停，不啟新模型、mutation，保守預設也不發起新的工具讀取。在途請求仍擁有原 Future／settlement。resume 事件本身不重啟服務、不自動續跑；使用者前景明確續跑／核准才重新啟動。`inactive` 沿用目前可見 predicate，但不得僅憑它從未有使用者動作的背景路徑啟動 FGS。

**D9 — 邏輯續跑。** 新一般 send 才 beginRun；背景暫停的 resume 保存邏輯 run ID、剩餘主動時間、模型／工具／HTTP 額度、已記錄 call／execution IDs，呼叫既有 resumeRun，projection 只含每筆寫入的一行結果。dispatching 或任何終態的既有 execution 都不得再 mutation。新的同 operation＋conflict keys 提議按既有成功／uncertain 重複規則要求確認（含 bypass）；uncertain 隔離不因確認解除。舊 approval／死亡 Future 不復活；30 分鐘 approval 牆鐘到期不因暫停重置。程序死亡後只允許從安全 display/history 建新對話續聊，不復原可執行 run、票、附件或核准。

重複政策範圍維持同一 account／conversation／邏輯 run；保留既有 uploads 的跨 run 例外，不擴成掃所有帳號歷史。`lib/core/ai/tools/write_coordinator.dart:741` 與 `docs/V0_6_AI_VERIFICATION.md:2016` 把跨 run／conversation 的一般去重留給 MR6c 討論，並非已實作保證。保守選擇是續跑沿用同 run 而不新增全域去重；若 lead 要擴大範圍，另立明確 account／retention／privacy 契約的小 MR，不阻塞本批的同 run 防重驗收。

**D10 — 通知只是入口。** 原生 FGS 固定 ID=6100、channel=`ai_runs_v1`；一般通知保留範圍：需確認 6200–6299、結果／中斷摘要 6300–6399。小型 bounded ID allocator 與碰撞測試由 C3 擁有；不以任意 hash 當唯一 ID。啟動只取消需確認範圍的舊通知，不 cancelAll。兩種通知均 private，公開版本只有一般工作狀態，不含帳號、instance、專案、MR、原文／模型回應；一般通知只傳 `conversationId`＋generation，不傳 resource、URL、operation 或任何授權。冷啟動用 getNotificationAppLaunchDetails；熱啟動與冷啟動共用驗證佇列，等 AppLockGate 已載入且放行，再重驗目前 registry 的 ID／generation。冷啟動不信任可重複的 generation 數字：僅已存在於當前記憶體 registry 的 conversation 才可打開；否則首頁，不讀 history 來重建 approval、不切帳號。PendingIntent immutable、明確 component／不同 requestCode；通知永無核准、改等級、解鎖隔離動作。原生「全部停止」只降低權限，不等待解鎖或 Dart。

**D11 — back 與移除工作。** detail 先處理並 return；非首頁先回首頁並 return；只有已在根首頁、無 detail、backProtectedCount>0，才 canPop=false 並 moveTaskToBack。無工作維持原行為；app lock 未放行先遵守鎖的返回處理。recents 移除用 stopWithTask=true，不依賴 onTaskRemoved；MainActivity／Service destroy 先使 permit 無效，再 native stop／清 active 狀態；不等 Flutter、加密 I/O 或 callback。移除工作與 Android Task Manager Stop／settings force-stop 分開驗證，不承諾終止當下有通知。

**D12 — 文字與出貨權限。** Claude（lead）獨佔全部 UI／UX、通知文字／channel 名稱／步驟文案、ARB 與生成 l10n（`CLAUDE.md:130`），Codex 只交結構化事件／reason code／測試。native 所需一般字串由 lead-owned l10n 資料經 bootstrap 生成 Android resources，冷啟動缺資料仍有 lead 提供的泛用安全資源，不把中文硬寫 Kotlin。AI gate 不開。iOS 維持無 native permit 的保守背景拒絕與原測試，§12.6 beginBackgroundTask 另批處理並明列 NOT_RUN。

## §3 分波、MR 與唯一所有權

合併順序：`現有 main（MR6b-3 驗收基準重核） → C1 → C2a → C2b → C3 → C4 → C5 → C6 → C7 → C8`。每格是一個小 MR；可先並行準備不相交的測試／研究草稿，但共用檔依表交接，不能同時改。cache C2／3、MR6b-3g／3t 若仍改 controller／shell／main，等前 MR 合併後再接手，不雙方各寫一份 owner。

| 檔案／區段 | 唯一 owner 的交接順序 |
|---|---|
| `tool/bootstrap.py`、`tool/tests/test_bootstrap.py` | C1 生成／許可基本生命週期 → C3 外掛 Gradle／通知資源 → C4 停止協定 → C6 back channel；不得並行 |
| 新 `lib/core/ai/execution_gate.dart`、`lib/core/ai/runner.dart`、`lib/core/ai/tools/write_coordinator.dart` | C2a 建閉合介面／三個邊界 → C5 暫停／同 run 續跑完成；其他封包只使用 |
| 新 `lib/features/ai/ai_background_execution.dart`、`ai_run_registry.dart`、`ai_chat_controller.dart`、`ai_chat_session.dart` | C2b bridge／注入 → C4 stop 事件 → C5 pause／resume；C7 僅修正必要的 destroy／恢復接縫，先獨佔交接 |
| 新 `lib/features/ai/ai_run_notifications.dart` | C3 一般通知 adapter／payload 驗證；後續只用公開介面 |
| `lib/features/shell/authenticated_app.dart`、`lib/features/security/app_lock.dart` | Claude 在 C3 接入口與 unlock gating → C6 back → C7 恢復呈現；Codex 不改版面或這些檔案 |
| `lib/main.dart` | Claude 在 C3 初始化通知／啟動 payload → C7 恢復通知；避免與 cache startup owner 並行 |
| `lib/features/ai/ai_chat_page.dart`、`ai_write_ui.dart`、`ai_settings_page.dart`；`lib/l10n/arb/*.arb`、`lib/l10n/strings*.g.dart` | 全程 Claude 獨佔；C1 即交 native 第一張通知所需泛用翻譯資源，C3 擴充一般通知；各 MR 所需畫面／字串同 MR 合入 |
| `pubspec.yaml`、`pubspec.lock` | 僅 C3 鎖定外掛與必要相容性 metadata，不順便升其他依賴 |
| 新 `test/ai/mr6c_support.dart` | C2a 建所有後續 fake gate／barrier 的公開介面；之後其他測試只讀，缺陷交回 owner 小修 |
| 新各 `test/ai/mr6c_*_test.dart` | 下文各封包自己的檔；C8 不修改先前測試以掩蓋失敗 |
| 新 `integration_test/mr6c_background_test.dart`、`tool/mr6c_emulator_checks.py` | C8，非 UI synthetic harness；Claude 執行與驗收。只在明確 QA target／define 下可注入，不改 production fallback |

原生生成的 `.kt`、Manifest、Gradle、資源位於臨時生成目錄；**不提交 android／ios／.metadata**。測試新檔與 import 在各自 MR 同時建立；不得 C2a 先 import C2b／C5 尚未建立的檔案。

### 共用驗收 G0（每一實作 MR，於該 MR source 執行）

```sh
fvm flutter pub get --enforce-lockfile
fvm flutter analyze --no-pub
python3 -m unittest discover -s tool/tests -p 'test_ai_boundaries.py' -v
git diff --check
```

後文每包還要跑自己的命令；新檔名是該包必須交付的測試，不是今天可跑的既有命令。Python 使用 tempfile／禁寫 pycache 到交付目錄，證據放該 session scratch 或小型 git-ignored 目錄；不建立大型重複 checkout／SDK／AVD image。不跑 live writes；裝置 smoke 用 public read／拒絕所有提議，實際 mutation 計數用 synthetic adapter。

**共用原生驗收 GN：** 任何更動 generator 的 C1／C3／C4／C6，都必須在該 MR 跑 §4.1 的乾淨生成、雙 flavor debug APK 編譯與 merged manifest 反讀；不能把第一次 Kotlin 編譯延到 C8。使用既有 pinned SDK 與 stable signer，scratch 的 FVM 指向同一 SDK，不複製／重新下載 SDK。各 MR 保存自己 HEAD 的生成／編譯證據；C8 再驗最終合併版及 OS 行為。C1 起建立由 Python 測試呼叫的 merged-manifest 驗證 helper（置於該包既有測試檔），依當包已引入的權限集合檢查；C8 只重用，不另寫一套寬鬆判定。

### C1 — bootstrap 原生服務生成與 Python 基礎測試

**owner／檔案：** Codex，`tool/bootstrap.py`、`tool/tests/test_bootstrap.py`；Claude 擁有 C1 所需 l10n／泛用 notification resource 輸入。依賴：現有 native hardening。契約：D1–D3 的原生 v1 接縫先完整產生，包含最基本的失效先於 stop、safe onTimeout／destroy，即使尚無 Dart 呼叫者也不會留下可重啟許可。startForeground 所需 channel／安全泛用通知與 icon 在 C1 即完整可編譯，不能等 C3 才補必要資源；compileSdk 至少 35 以編譯 onTimeout。C4 再補通知停止整合與故障驗證。moveTaskToBack 方法先保留 typed unsupported 接縫，C6 完成；不能讓 C1 生成不安全暫存 stub。

工作：FGS 三個權限加現有 INTERNET（外掛 manifest 的 VIBRATE 在 C3 再驗）；非 exported dataSync service／stopWithTask=true；雙 flavor 皆可解析；MainActivity 註冊第三個 channel 且保留原兩個 channel／FragmentActivity。只接受已知舊 managed 模板的明確升級，未知／半套 markers／衝突 service／permission 不猜修。configure_android 重跑結果不變，CLI 遇既有 native 仍拒絕；所有新生成檔納入已知內容檢查。API 35 onTimeout 用已發布 SDK 編譯，不依賴 AOSP main 註解推斷可用性。

**驗收：** G0 加以下；Python 覆蓋全 permission 集合／唯一性、雙 flavor、許可 issuance／失效文字順序、START_NOT_STICKY、destroy、MainActivity 保留、無 boot receiver／RECEIVE_BOOT_COMPLETED、backup／cleartext／signing／iOS entitlements 回歸。

```sh
python3 -m unittest discover -s tool/tests -p 'test_bootstrap.py' -v
python3 -m unittest discover -s tool/tests -p 'test_android_signing.py' -v
```

另跑 GN；乾淨生成、兩 flavor Kotlin／APK 編譯與 merged manifest 是 C1 合併必要條件，失敗先修不往下交接。**§15 所有權：** 22 的生成／管理函式／首次雙 flavor 編譯子項；27 的 native 許可基本狀態機。**NOT_RUN：** Python 與編譯不能替代原生取票／OS 行為，後者在 C8；iOS build／device 另列。

### C2a — 純 Dart 取票接縫與三條送出邊界

**owner／檔案：** Codex，§3 指定的三個 core 檔；新 `test/ai/mr6c_support.dart`、`mr6c_ticket_boundary_test.dart`。依賴 C1 固定 channel protocol，測試只注入 fake、不需 Flutter native。定義 ticket／run binding／pause reason 與 `acquire(kind)`＋同步 consume 介面；未注入／不支援平台的預設只允許可見前景，不能預設允許背景。C2a 不 import 未建立的 feature bridge。

契約 D3–D6；模型最後送出、REST flush 前、Graph hook 內各接一次。保存 owner／nonce／票的用一次性，mayStart 不 await；不改 REST／Graph 結果分類與 API preflight。fake barrier 分別卡住取票、journal flush、Graph preflight，測停止／generation／policy／consent／removal／429／無服務背景；fake 模型與 mutation counter 分別為 0。驗「有效回覆排隊後失效」的容許在途界限，不能把 callback 正常的測試當丟失 callback 證據。

必須有正向測試：真實 foreground=false、有合法 run binding／未失效 permit，fresh ticket 能讓模型與自動等級 REST／Graph 各前進一次；撤 permit 後下一次為零。同一情境在背景呼 approve 必須拒絕並保留待核准狀態，防止以放寬共用 `_pauseOf` 同時放寬核准。

```sh
fvm flutter test --no-pub test/ai/mr6c_ticket_boundary_test.dart test/ai/mr6b3_dispatch_test.dart test/ai/mr6b2_boundary_test.dart test/ai/mr6b3_boundary_test.dart test/ai/packet7_runner_test.dart
```

**§15 所有權：** 27 的票不重用／取票超時／失效交錯之 Dart 子項，29 只回歸不改其 owner。**NOT_RUN：** MethodChannel 往返、原生停止、Android 安裝均未由本包證明。

### C2b — MethodChannel bridge、registry 與 controller 注入

**owner／檔案：** Codex，新 `lib/features/ai/ai_background_execution.dart`；`ai_run_registry.dart`、`ai_chat_controller.dart`、`ai_chat_session.dart` 的非 UI 接線；新 `test/ai/mr6c_registry_execution_test.dart`。依賴 C2a；實作全部新介面，C2b 不能要求 C5 才有的 enum／檔案才能編譯。對 UI 暴露獨立的 typed execution status；如需既有 enum 新 case，其畫面映射與 l10n 由 Claude 在同 MR 完成。

契約 D2／D7；service owner 位於 registry 上方或同壽命 adapter，保持目前 account／generation／API 綁定；可測的 injection 預設 production bridge。服務已有 active permit 時新 run 綁同一張；最多 3，第四個拒絕不啟服務。serviceWorkCount 與 backProtectedCount 通知 listener，不靠 page visits。callback 丟失不能保持「可用許可」的樂觀判斷；每個續點仍 native 取票。feature 端保留真實 foreground predicate，writeGatesOpen 與 policy snapshot 讀同一 execution 狀態，client gate 仍獨立。

C2b 測 controller→coordinator 真接線的背景正向進展／撤權拒絕／背景核准拒絕，不只測 fake gate 回值。UI 的 canSend／approve 不跟 execution eligibility 一起放寬；snapshot 的實際 foreground=false 必須可觀察。

```sh
fvm flutter test --no-pub test/ai/mr6c_registry_execution_test.dart test/ai/ai_run_registry_test.dart test/ai/ai_write_gates_test.dart
```

**§15 所有權：** 27 的新 run 共用 active permit／registry 身分／bridge 失效；12.1 三段上限回歸。**NOT_RUN：** 真 native channel 與背景 latency，待 C8；UI 僅必要狀態映射，不在此宣稱整體 UX 完成。

### C3 — 穩定通知外掛鎖版、隱私與 app lock 後導頁

**owner／檔案：** Codex 獨佔 pubspec.yaml／lock、bootstrap／Python 測試的 Gradle 與 resource 生成段、新 `ai_run_notifications.dart`、新 `test/ai/mr6c_notification_test.dart`。Claude 獨佔 §3 UI／shell／main／app lock／所有 l10n，及 `test/app_lock_test.dart` 的必要新增案例。依賴 C2b；bootstrap 寫入權已由 C1 交接。

實作當天重查 §5 S1，選最新 **stable**，精確版本（無 `^`）與 lock 同提交；本次觀察 22.3.3 只是選版輸入。若新 stable 與 pinned SDK 不相容，停止該升版分支、列明不相容條件，保守保留相容 stable 並記偏離，不能偷換 Flutter 或採 dev。需要變更 pubspec SDK 下限以誠實表達外掛 Dart 要求時，同包明確收斂；不升無關依賴。

按該版 README 配置 desugaring（不排程也需要）、Java／Kotlin 17、compileSdk 要求；讀實際 minSdk／AGP／targetSdk 再決定，不因 README 範例加 multidex。無排程、無 exact-alarm、無 boot receiver；驗 plugin 合併 manifest，不用上游 master 猜釘版內容。

契約 D10／D12：四種一般通知事件、高優先 needsApproval、private＋不含名稱的 public version；冷／熱啟動同一 gate；ID 界限精確取消。native FGS 初始與更新同樣不能洩漏敏感名稱。通知權限請求由 Claude 在第一次前景使用者啟動背景工作前呈現；拒絕不阻止 FGS，但必須揭露一般提醒缺席與 30 分鐘到期。不得通知直接 approve 或註冊無 UI 背景 action handler。

```sh
fvm flutter pub get
fvm flutter pub get --enforce-lockfile
fvm flutter test --no-pub test/ai/mr6c_notification_test.dart test/app_lock_test.dart
python3 -m unittest discover -s tool/tests -p 'test_bootstrap.py' -v
python3 -m unittest discover -s tool/tests -p 'test_l10n.py' -v
```

第一個非 enforce 的 resolve **只在已選定精確依賴後於 C3** 使用；審查 lock diff，不為解鎖而整份重新生成。再跑 G0＋GN。**§15 所有權：** 22 的外掛／Gradle／合併 manifest；12.3 privacy／lock／點擊契約。**NOT_RUN：** Android 真通知抽屜／鎖屏／權限／Play 核可，待 C8 或 MR7；iOS notifications 不初始化為已支援能力。

### C4 — 全部停止、onTimeout 與不等 Dart 的停止協定

**owner／檔案：** Codex 接手 bootstrap／Python 測試、`ai_background_execution.dart`、registry／controller 的 stop 事件段；新 `test/ai/mr6c_stop_protocol_test.dart`。Claude 提供已翻譯 stop／timeout／interrupted 字串，不在 Kotlin 常數硬寫。依賴 C3。

四條路徑：onTimeout、通知 stopAll、MainActivity.onDestroy、Service.onDestroy，都以 native state machine 先 invalidated，再 stopForeground＋stopSelf／必要清 active state，最後才 best-effort channel。回呼與重入皆冪等，onDestroy 不再啟動服務；不等 channel result、journal flush 或 timer。MainActivity 拆離時移除 channel handler／engine 引用。stopAll 的 immutable explicit service PendingIntent 可在鎖定／Dart 不回應時運作；stop action 送達時服務若已不存在，只維持無許可，不為處理停止再升 FGS。

Dart 收到 stopAll 使用 registry adapter 停止所有 run／待核准；timeout／destroy 置失效與待明確續跑狀態；在途 writes 保留 settlement。為停止而 close GitLab API、取消日誌、清除 isolation 都不合法。分別測 callback 正常、丟棄 callback、channel 關閉，且 combined case 必須背景＋活 engine＋服務已停＋callback 丟棄，再推進模型與 mutation 續點。

C4 同時在 bootstrap 產生 debug source set 的 QA 故障 adapter（drop callback／delay reply／合成 timeout），供 C8 明確 QA 入口註冊使用；release source set 不包含它，普通 production Dart 入口不註冊、不提供 exported intent。release APK 反讀必須證明不存在 QA handler；debug adapter 只能控制測試服務事件，不讀／改帳號內容。合成 timeout 與真正系統回呼的事件標籤不同。

```sh
python3 -m unittest discover -s tool/tests -p 'test_bootstrap.py' -v
fvm flutter test --no-pub test/ai/mr6c_stop_protocol_test.dart test/ai/packet9_removal_test.dart test/ai/runner_lifecycle_test.dart
```

加 G0＋GN。**§15 所有權：** 27 四種原生失效路徑及 combined case 的協定／fake 測試；22 的 destroy 生成回歸。**NOT_RUN：** 系統真正 timeout／ANR／程序終止證據直到 C8，合成回呼須另列；release 無 QA handler 的產物檢查也須 C8 實際 build，不能用 debug build 推定。

### C5 — 無服務暫停、拒啟降級與同邏輯 run 續跑

**owner／檔案：** Codex 接手 execution_gate／runner／coordinator、background bridge／registry／controller／session 非 UI 段；新 `test/ai/mr6c_pause_resume_test.dart`。Claude 獨佔 chat／settings／write UI 與 l10n，提供前景續跑、拒啟說明、可能重複／可能再次計費、通知關閉提示。依賴 C4。

完成 D8／D9：捕捉 ForegroundServiceStartNotAllowedException、SecurityException 或 channel 拒絕，清半成品許可／服務，typed failure 交前景降級，一次使用者動作最多啟動一次，不 timer／resume／background retry。沒有服務而進背景，在途工作於安全點結算／暫停；返回 foreground 自動 lifecycle 只更新狀態。等待 approval 不持 FGS、12 分鐘主動時間暫停而 30 分鐘牆鐘繼續；使用者明確核准才重啟服務並重驗 proposal。timeout／stop／destroy 造成的失效，即使 app 原已在前景也須明確續跑。

runner continuation 不能當普通 send 重建 run；補實際 resumeRun 呼叫，保留剩餘 counters／deadline／journal run ID，重新做 secret／scope／policy／consent／owner checks；未完成 tool call 要配對未執行或 recorded outcome，不能恢復死亡的 Future。新相同 operation／keys 的 proposal 必須確認，uncertain 仍隔離。既有 settled execution 僅摘要，mutation counter 不增加；停止後晚到成功只更新正確 conversation 的 display／journal，不寫進新帳號。

C5 重跑 C2a／C2b 的背景正向進展、撤權與背景核准拒絕三項，另驗無服務時同一續點會暫停；不能只證明所有背景工作都被擋下。

```sh
fvm flutter test --no-pub test/ai/mr6c_pause_resume_test.dart test/ai/followup12_gate_duplicates_test.dart test/ai/packet7_runner_test.dart test/ai/runner_projection_test.dart test/ai/ai_write_gates_test.dart
python3 -m unittest discover -s tool/tests -p 'test_l10n.py' -v
```

加 G0。**§15 所有權：** 27 的 foreground-only／失效後明確續跑／啟動拒絕；28 的 Android 暫停與同 run 不重複邏輯（全終態含 failedCertain／notExecuted 的舊 execution 不再送）；17／29 回歸。**NOT_RUN：** 真 Android 服務下第 28 列待 C8；iOS 第 28 列裝置測試仍 NOT_RUN。

### C6 — 根頁 back 與 moveTaskToBack

**owner／檔案：** Claude 獨佔 `authenticated_app.dart`、必要 `app_lock.dart`、`test/authenticated_app_shell_adaptive_test.dart` 與新 `test/ai/mr6c_root_back_test.dart`；Codex 僅接手 bootstrap／Python 測試的 moveTaskToBack channel 方法。依賴 C5，bridge 方法在 C2b 已存在，native 方法不得為普通返回啟動 service。

依 D11，shell 同時 listen detail dispatcher 與 registry 計數；有工作即 canPop=false，但 detail／非首頁仍先消費這次返回，不能第一下就把編輯／detail 藏到背景。根首頁才呼 native moveTaskToBack，無 run 原行為不變；awaitingApproval／背景暫停也保護未結束邏輯工作。鎖住時 back 不露底層畫面；鍵盤、dialog、detail、非首頁、首頁、無工作、旋轉／窄寬畫面各一案。native method 不適用平台回 typed unsupported，不強行結束 Activity。

```sh
fvm flutter test --no-pub test/ai/mr6c_root_back_test.dart test/authenticated_app_shell_adaptive_test.dart test/app_lock_test.dart
python3 -m unittest discover -s tool/tests -p 'test_bootstrap.py' -v
```

加 G0＋GN。**§15 所有權：** 27 的 Activity／engine 保留相關回歸，直接驗收來源為 §12.2 根頁返回與 §12.5。**NOT_RUN：** API 34–36 真 Activity back／predictive back 在 C8；Android 7–11 相容性裝置未有環境仍 NOT_RUN，不能由新版本推定。

### C7 — 移除工作、engine detach 與下次啟動恢復

**owner／檔案：** Codex 在完成交接後獨佔 background bridge／registry／controller 的 destroy／retired settlement 接縫、新 `test/ai/mr6c_task_recovery_test.dart`。Claude 獨佔 main／shell／chat／settings 的恢復呈現與 l10n。既有 `ai_write_journal.dart`、`ai_account_removal.dart` 不重寫；若測試發現缺陷，先開對應 owner 的小修，不在本包順便改清理流程。依賴 C6。

維持 stopWithTask=true；不新增 onTaskRemoved 通知承諾，不以 release run callback 取代 native destroy。測試 Activity detach（Dart 仍活）、程序死亡、recents swipe、Task Manager Stop 為四個不同案例。下次啟動按現有 journal recovery 將殘留 dispatching 視為 uncertain、隔離保留，needsApproval 舊通知精確清掉；journal unreadable 不刪資料／重建 key，顯示重試或既有 typed reset 入口。中斷通知只在下次啟動恢復後、權限允許且資料可安全判定時投遞，不宣稱在被殺瞬間成功通知。

再測帳號切換／登出／兩入口移除的 stop＋等待，持 removal hold 時不核新 dispatch、保留 tombstone／epoch／typed-name 規則；UI 卸載後已確認的清理不被 service stop 中斷。service 的無許可狀態不能解除 journal 隔離；Task Manager 無 callback 時也不可依賴 finally 已執行。

```sh
fvm flutter test --no-pub test/ai/mr6c_task_recovery_test.dart test/ai/ai_write_journal_test.dart test/ai/packet9_removal_test.dart test/ai/ai_run_registry_test.dart
```

加 G0。**§15 所有權：** 22 的 stopWithTask 生成配置由 C1 證明，本包擁有 27 的 destroy／恢復整合及 28 的恢復後不重複；4／31 只回歸。**NOT_RUN：** OS 實際 callback 送達／recents／Task Manager／force-stop 在 C8，各自記錄。

### C8 — 生成物反讀、真 Android 矩陣與獨立驗收

**owner／檔案：** Codex 只新增 `integration_test/mr6c_background_test.dart`、`tool/mr6c_emulator_checks.py`、`tool/tests/test_mr6c_emulator_checks.py`；harness 不改產品來保綠。Claude 自己執行／反讀結果，最後由未寫產品的 reviewer 查核證據與第 22／27／28 列映射。依賴 C1–C7 與 Claude UI／l10n 全部合併。缺陷回原 owner 小修再跑影響案例，不只採信 worker RESULT。

harness 只用合成帳號／provider stream／GitLab adapter，輸出 commit、flavor、SDK／target、AVD／API、APK digest／公用 signer digest、case、native stop 時序、call counters、ticket 交錯、延遲統計與 verdict。不輸出 token／許可值／私有內容；故障注入只由明確 QA target／`MR6C_QA=true` 開啟，不能從 exported intent 或 production UI 啟動。既有 integration_test SDK 依賴已在 pubspec，不新增測試套件。

**host／fixture 契約：** Python host 是唯一 case orchestrator；它逐案啟動仍存活的 Flutter integration-test 子程序，再等待 app 的 ready／指定 barrier，才執行 adb／AVD 操作。fixture 使用真 production controller、registry、native service 與 synthetic provider／GitLab ports；不得以假 registry 或 native state 替代。以 debug package 的 `run-as` app-private `files/mr6c_qa/` JSON mailbox 雙向 step／ack，命令綁 QA session nonce、case、phase、sequence，舊／重複命令拒絕；QA nonce 與 native permit 完全不同，mailbox 不存 permit、ticket、approval 或帳號內容，只存合成案例旗標／counter／安全時序。未取得 ready／barrier ack 不可操作或跳過成 PASS。C4 debug adapter 提供 native 注入，C8 不修改 generator。

對 V9 與任何會殺程序的案例，host 先保存 dispatch-accepted／journal-flushed barrier 與 baseline，再操作 recents／user-stop／force-stop；預期 app／Flutter test 子程序終止只記 expected termination，**不是測試通過**。host 另外反讀 service 已停，再以同 signer、同 package、不 uninstall／clear data 的 recover phase 啟動新 fixture，反讀真 journal 的 uncertain／隔離／無 permit 與零重送；兩階段各有 deadline 和完成標記才可判 PASS。host stdout／小型 evidence 在 app 外，死亡後仍可完成 verdict。非預期 runner 失敗、缺恢復標記、掛住一律 FAIL；無環境且未啟動才 NOT_RUN。Python 單測鎖定這些 exit／barrier／恢復規則，不把 kill 當成功。mailbox 僅清本 session 合成資料，不清整個 app。

**驗收命令：** G0 加 §4.1 全部生成／build／反讀命令、§4.2 host 命令與 §4.3 每案操作；不得挑完容易案例就關包。**§15 所有權：** 22 最終生成物／雙 flavor 編譯、27 實際服務與丟 callback 交集、28 實際服務 Android 續跑。**NOT_RUN：** iOS 全部、未跑的預設六小時 timeout、缺 API／裝置環境與未取得完整證據的個別案例維持逐項 NOT_RUN；不得將其列成 PASS。

## §4 精確驗收步驟與執行位置

### §4.1 生成、編譯與靜態回歸（Claude 執行，專案 CI／本機 scratch）

先讀 `docs/ANDROID_SIGNING.md` 與 `docs/ANDROID_RELEASE_INVENTORY.json`；沿現有 stable development signer，不 init／rotate／uninstall／clear data。產出新 APK 時補公開 inventory receipt；只記公用 digest，不輸出私鑰／密碼。每條命令記 source HEAD；編譯前 rebase 後的測試必須重跑。

在一次性的乾淨生成目錄準備已 review 的同一 source（可用 tracked source 加本 MR 明確檔案清單複製；不可漏 untracked 新測試、也不可把另一個 dirty checkout 當基準），使用現有 pinned Flutter 的絕對路徑。下列 `MR6C_FLUTTER` 與 `MR6C_EVIDENCE` 由執行者設為既有 SDK 與 session scratch 絕對路徑；native 已存在時另外選乾淨生成目錄，不刪原目錄讓 CLI 過關。

```sh
python3 tool/bootstrap.py --flutter "$MR6C_FLUTTER" --check-sdk
python3 tool/bootstrap.py --flutter "$MR6C_FLUTTER"
fvm flutter pub get --enforce-lockfile
fvm flutter analyze --no-pub
python3 -m unittest discover -s tool/tests -p 'test_*.py' -v
python3 -m unittest discover -s ci/tests -p '*_test.py' -v
python3 -m compileall -q ci tool
fvm flutter test --no-pub test/ai test/app_lock_test.dart test/authenticated_app_shell_adaptive_test.dart
fvm flutter build apk --debug --flavor gitlab --no-pub
fvm flutter build apk --debug --flavor play --no-pub
MR6C_GENERATED_ROOT="$PWD" python3 -m unittest discover -s tool/tests -p 'test_bootstrap.py' -v
```

最後一條是 C1 必須新增的實際生成物驗收入口：設定 `MR6C_GENERATED_ROOT` 時，測試 helper 必須找到該根下兩個已建 flavor 的 merged manifest 並用 XML 驗證，缺少產物即 FAIL，不能退回合成 XML。未設此變數的 Python suite 仍為 tempfile 模板單測。在專案 CI 再跑標準完整 analyze／test／native_templates／android_debug 並保存 pipeline／job URL；本機 targeted 不代替整套。兩 flavor 的 merged manifest 實際路徑由 Gradle 版本決定，helper 反讀合併後的 main manifest 與兩 flavor package，不只 grep bootstrap 常數，並驗以下精確集合／限制：

- service 唯一、非 exported、stopWithTask=true、dataSync；三個 FGS／notification permissions 各一次，保留 INTERNET／plugin 所需 VIBRATE；只 gitlab 保留既有 REQUEST_INSTALL_PACKAGES，不讓 play 繼承。
- 無 BOOT_COMPLETED／LOCKED_BOOT_COMPLETED receiver、RECEIVE_BOOT_COMPLETED／exact alarm／電池豁免；主 Activity／link trampoline 的既有 exported 與 deeplink 設定不漂移。
- backup／cleartext／signing 限制、Java 17／desugaring／實際 minSdk、compileSdk、targetSdk／AGP；MainActivity 保留所有 channel，service onTimeout 與 destroy 進已編譯 APK。

生成、模板重跑、merged manifest、雙 flavor build 各一列證據；模板重跑限管理函式，測試 CLI 第二次拒覆寫。iOS 只生成 templates 也仍是 iOS build／device NOT_RUN。輸出完成後僅刪除本 session 自有且已確認無需保留的大型 build scratch，不碰原專案或 AVD 資料。

C8 另跑 `fvm flutter build apk --release --flavor gitlab --no-pub` 與 `fvm flutter build apk --release --flavor play --no-pub`，以同 SDK 的 APK／DEX 檢視工具反讀兩個 release APK 無 QA adapter／handler，再反讀 debug QA 版確實有測試接縫；只查 Dart define 或原始碼不算 release 產物證據。這是測試入口隔離驗收，不等同 release／Play 發布。

### §4.2 AVD 身分與固定命令（C8 script 必須實作後才可執行）

**指定環境是專案 Pixel_9，禁止實體手機。** 執行前 `adb devices -l`，再以明確 serial 核對：

```sh
adb devices -l
adb -s "$MR6C_SERIAL" shell getprop ro.kernel.qemu
adb -s "$MR6C_SERIAL" emu avd name
adb -s "$MR6C_SERIAL" shell getprop ro.build.version.sdk
```

qemu 必須 1，AVD 必須 Pixel_9 或本專案事先登記的 API 專用 Pixel_9_MR6c_API34／35／36。Pixel_9 本身一定要有一筆本次實跑；它目前使用哪個 API 由 readback 決定，不能從歷史 serial 猜。API 專用 AVD 只補缺少的版本、沿現有官方 system image，不複製大 image、不換別人的 emulator、不刪既有 Pixel_9 資料。沒有某 API image／空間時該列 NOT_RUN；建立額外 AVD 的成本由 lead 先核對空間再處理，不假裝一個 AVD snapshot 能切換 OS API。

下面工具由 C8 新建；它驗 serial／AVD／API 與安裝包身分，錯誤立即拒絕，不 fallback 第一台裝置。`--cases all` 對應 §4.3 的 case IDs，逐個報告；API 版本／AVD 必須與上面的當次 readback 相符。

```sh
python3 -m unittest discover -s tool/tests -p 'test_mr6c_emulator_checks.py' -v
python3 tool/mr6c_emulator_checks.py --serial "$MR6C_SERIAL" --avd Pixel_9 --api "$MR6C_API" --cases all --output "$MR6C_EVIDENCE"
```

不要先單獨跑完 integration test 再執行 host 檢查。上面 host 工具必須自行管理下列子程序（每 case／phase 帶不同值），等 ready 後與它並行操作；只有 host 能給出整案 verdict：

```sh
fvm flutter test --no-pub integration_test/mr6c_background_test.dart --flavor "$MR6C_FLAVOR" -d "$MR6C_SERIAL" --dart-define=MR6C_QA=true --dart-define=MR6C_CASE="$MR6C_CASE" --dart-define=MR6C_PHASE="$MR6C_PHASE" --timeout=30m
```

`MR6C_CASE` 為 V1–V12、`MR6C_PHASE` 為 prepare／recover，host 建立 mailbox session 並設定後才啟動；非終止案例用 prepare 完成，終止案例還須 recover。host 驗 Flutter 安裝流程只做相容更新並保持合成 journal，無法維持資料就 FAIL；不得卸載來迴避 signer 或用重建 fake journal 冒充恢復。

缺版本時分別以 `--avd Pixel_9_MR6c_API34 --api 34`、`--avd Pixel_9_MR6c_API35 --api 35`、`--avd Pixel_9_MR6c_API36 --api 36` 重跑同一命令，serial 取各自 readback，不盲抄。必要時 play flavor 重跑 service／notification／back smoke（`--flavor play` 與 package app.mergeline），gitlab 預設 package 是 io.gitlabmobile.gitlab_mobile；不得將兩個 package 的資料／票混用。

### §4.3 §12.5／§12.7 逐案矩陣（Claude 在 AVD 執行，獨立 reviewer 反讀）

以下**本次全為 NOT_RUN**；表中「通過證據」是未來條件。每案標明 flavor／API，baseline 計數先取再推進 barrier，避免把原有在途呼叫誤當失效後新呼叫。自然網路中斷與未達目標的串流測試不能改判成功。

| ID／來源 | 環境與操作 | 通過證據／明確限制 |
|---|---|---|
| V1／12.5 | API 34、35、36，Pixel_9 矩陣；使用可見 UI 啟服務，熄屏；另一次進 Doze，12 分鐘串流＋GitLab synthetic 請求；三段並行，第四段拒絕 | 記主動時間與呼叫／stream heartbeat；不靠「服務顯示 running」推定請求持續。三 run 共用許可，最後活動結束停止服務；全部 awaitingApproval 也停止，核准前無模型／mutation。若 Doze 實際暫停網路如實 FAIL／限制，不增加 wake lock 或豁免解釋為通過。 |
| V2／12.7-1、22、27 | API 35、36；分開跑 QA 合成 onTimeout 與系統 dataSync 額度 timeout；官方縮短時限指令見下文 | native invalidate→stop 不等 Dart，停止在系統寬限內，無 RemoteServiceException／ANR；標明「直接合成」或「系統縮短額度」。未真的跑預設六小時額度另列 NOT_RUN，不把縮短額度稱實際六小時耗盡。API 34 的 dataSync 系統 timeout 為不適用，不填 PASS。 |
| V3／12.7-2、27 | API 34–36，Activity 在背景且 engine 活；三 run 持續取票；各種 idle／screen off／Doze，正常往返每種至少 100 次；另注入 >1 秒與晚到回覆 | 記 N／p50／p95／max／timeout 次數，每張已使用票只 consume 一次；正常測項記實際 ≤1 秒比例，逾時一律暫停、不得放寬 1 秒或默認放行。看不到穩定往返就報風險／降級，不能把 fail-closed 當 latency 過關。 |
| V4／12.5 交集、27 | API 34–36，先證明背景＋有效 permit 可前進模型／自動等級 REST／Graph；再在背景＋Dart／engine 活時 native 停服務，故意丟 callback／切斷 stop channel，推進下一續點 | 正向各一次、背景 approval 仍拒絕；native 不等 Dart；停止後下一次 acquire 不核票或超時，新增 model=0／mutation=0。必須同一交集案例；「callback 正常零 dispatch」＋「壞 channel 能停服務」兩份證據不足。 |
| V5／27、29 | API 34–36＋fake barrier：先失效再 acquire；有效回覆排 channel 後才失效；Graph preflight 中失效；flush 期間切背景／撤 guard；同票第二次 consume | 前者零送出，後者最多已核發的一次在途且不再發新票；Graph mutation=0／notExecuted 不上鎖；flush 後拒絕 rollback／退款按 D6；不能以後者證明「失效後絕無 HTTP」。 |
| V6／12.3 | API 34–36，通知權限允許／拒絕；鎖屏／解鎖；通知抽屜與 app 內提示 | 拒絕時 FGS 能運行，但一般提醒缺席、app 內揭露；每個事件 private＋無名稱公開版；冷／熱點擊先鎖後導頁，取消 unlock 不導頁；foreign／stale generation／未知 conversation 只首頁，不切帳號／核准。 |
| V7／12.7-4 | API 34–36（重點 34+），單獨滑掉原生前景通知後再 update；需確認與完成通知同時存在；重啟精確清 6200–6299 | 記 OS 是否重現／仍可見、service／permit 是否仍 active、6100 與一般範圍無衝突；滑掉不等於 stop。不能宣稱 notification 常駐。其他 ID 不被取消。 |
| V8／12.5、27 | API 34–36，notification stopAll；鎖住 app；另測 callback 丟棄／engine detach／MainActivity destroy | 先失效再停，無新票／新呼叫；在途 journal settle；無殭屍服務／僅剩通知；前景中被 stop 的 run 也不自動續跑。 |
| V9／12.7-3、12.5 | API 34–36，recents swipe，另案 Task Manager Stop，再冷啟動；另案 settings force-stop／冷啟動 | 反讀 service 已停、許可不存在；記 onDestroy 有／無送達，不依賴它發中斷通知；殘留 dispatching 恢復 uncertain、隔離保留；journal unreadable 提供安全重試；無 callback 時不要求有終止當下通知。三種操作分開，Android user-stop 指令不冒稱 force-stop。 |
| V10／12.2 back | API 34–36，detail／非首頁／首頁、awaitingApproval／paused／無工作、app lock、predictive back | 每次 back 次序 D11；根頁 live work moveTaskToBack，Activity／engine 未 destroy；無工作照舊。API 24–30 額外回歸未有環境即 NOT_RUN，不外推。 |
| V11／28 | API 34–36，正常無服務背景暫停、start 拒絕、fgsTimeout 三條，各以前景明確續跑；含 dispatching 與所有終態 | 舊 execution mutation 不增加、每筆投影一行；同 run 同 operation／keys 的新成功／uncertain 重複需確認（bypass 亦然），uncertain 不自動解鎖；計數與主動時間不歸零，沒有舊核准復活。 |
| V12／12.1 | API 34–36，背景服務執行中切帳號／登出／兩入口移除；等待／立即切換／取消；settlement 延遲 | 保留既有提示、等待上限、removal hold／tombstone／epoch；新帳號看不到舊結果，資料清理不被 native stop 越權執行；本案用 synthetic adapter，不作真私人帳號移除。 |

**官方系統 timeout 指令**（僅 API 35／36 的專案 AVD，`MR6C_PACKAGE` 由 flavor 決定並經 script 驗證）：

```sh
adb -s "$MR6C_SERIAL" shell am compat enable FGS_INTRODUCE_TIME_LIMITS "$MR6C_PACKAGE"
adb -s "$MR6C_SERIAL" shell device_config get activity_manager data_sync_fgs_timeout_duration
adb -s "$MR6C_SERIAL" shell device_config put activity_manager data_sync_fgs_timeout_duration 10000
```

script 在更動前保存原 device_config 值與 compat override 狀態，在 finally 及中斷後 recovery 恢復原值；原值 null 才 delete，不能無條件覆寫／清別人的設定。啟動後將 app 移到背景等待系統回呼，不從 QA 直接呼 onTimeout 充數；維持 debug trace 僅含安全時序。Doze 使用 `dumpsys battery unplug`、`dumpsys deviceidle force-idle` 前亦保存狀態，結束 `unforce`／恢復電源模擬，不留下全機測試設定。

Task Manager user stop 的官方測試命令為 `adb -s "$MR6C_SERIAL" shell cmd activity stop-app "$MR6C_PACKAGE"`；settings force-stop 另用 `adb -s "$MR6C_SERIAL" shell am force-stop "$MR6C_PACKAGE"`。recents swipe 必須實際操作專案 AVD 的 recents，並前後反讀 package／service；任何一種都不能替代其他兩種。

## §5 本次官方資料查核（查詢日期均為 2026-10-27）

下列是網頁公開事實，不是本專案執行結果。實作當天重讀 S1／S2，記當日 URL、版本、README 條件與實際 Gradle／target；不能從本文版本號跳過查核。

| 來源 | 查得事實與實作影響 |
|---|---|
| S1 [pub.dev 版本表](https://pub.dev/packages/flutter_local_notifications/versions)、[22.3.3 README](https://pub.dev/packages/flutter_local_notifications/versions/22.3.3) | 最新 stable 22.3.3，prerelease 23.0.0-dev.5 不採；22.3.3 最低 Dart 3.10。README 要 compileSdk 至少 35、即使無排程也開 desugaring，範例 Java／Kotlin 17、desugar_jdk_libs 2.1.4，建議 AGP 8.11.1 或以上。與專案 pinned SDK／實際 AGP 相容性仍須 C3 實測；不把範例 multidex 當硬條件。一般無 UI action 會另啟 engine／isolate，本批不用。 |
| S2 [Android 16 全 app 變更](https://developer.android.com/about/versions/16/behavior-changes-all)、[target 36 變更](https://developer.android.com/about/versions/16/behavior-changes-16) | 全 app 頁說 JobScheduler／WorkManager／DownloadManager 工作即使與 FGS 並行仍受 job runtime quota；這與 dataSync FGS 六小時不是同一額度。本設計主 isolate＋直接 FGS，未因此改用排程工作。C1／C3／C8 各在採用當日確認 target／plugin 是否增加 jobs、重讀兩頁其他適用變更，記錄影響或有理由的無影響，不能只寫「已讀」。 |
| S3 [FGS timeout](https://developer.android.com/develop/background-work/services/fgs/timeout)、[Service API](https://developer.android.com/reference/android/app/Service) | target Android 15+ 的 dataSync 背景總額 6 小時／24 小時、同 type 共用；帶回前景重置。onTimeout(int,int) 為 API 35，之後只有數秒 stopSelf，未停會例外。Service 文件對 stopWithTask 說直接停止而不呼 onTaskRemoved，未保證本 app onDestroy／通知實測結果。縮短 timeout 的官方方法可用於 V2，不能取代預設六小時實跑。 |
| S4 [FGS types](https://developer.android.com/develop/background-work/services/fgs/service-types)、[背景啟動限制](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start) | Android 14+ 的 dataSync 需 type 與 FGS／DATA_SYNC 權限；Android 12+ target 的背景啟 FGS 受限，可能 ForegroundServiceStartNotAllowedException。只接受可見使用者動作，拒啟 foreground-only，不背景重試。 |
| S5 [通知權限](https://developer.android.com/develop/ui/compose/notifications/notification-permission)、[使用者停止 FGS](https://developer.android.com/develop/background-work/services/fgs/handle-user-stopping) | Android 13+ 拒通知權限不阻止啟 FGS，但仍必須提供 FGS notification，使用者在 Task Manager 可見而非 drawer；Task Manager Stop 終止 app、不送 callback。V6／V9 分別測，不承諾當下 notification 或 finally。 |
| S6 [Android 14 ongoing 通知變更](https://developer.android.com/about/versions/14/behavior-changes-all) | 一般 ongoing FGS 通知可被個別滑掉，鎖定／Clear all 有例外；滑掉後 update 的實際表現與 ID 碰撞仍為 V7，官方規則不等於本 app 已驗證。 |

§12.7 四個 NOT_VERIFIED 已逐一分派：onTimeout 發布版送達→V2／C8 API35、36；背景 channel 1 秒→V3／C8 API34–36；stopWithTask destroy 與通知→V9／C7、C8；通知滑掉後 update／ID→V7／C3、C8。Codex 建測試，Claude 在上述 AVD 真跑，獨立 reviewer 讀原始 bounded 證據；無可用環境時保留 NOT_RUN，不透過文獻宣布解除。

## §6 風險與未解問題（每項已有保守預設，不等 permission handoff）

| 問題／風險 | 建議預設／負責人與關閉條件 |
|---|---|
| 許可核發後 native 失效的時間窗 | 採 D5 的已核票在途界限；C2a／C8 分開驗兩種交錯，文案不宣稱撤銷已送 HTTP。 |
| bridge 超過 1 秒或 callback 遺失 | 不放寬 deadline、不快取成功放行；當次暫停且要 foreground explicit resume。C2b／C8 報 latency 與拒絕各自結果。 |
| 啟服務未及時升前景／半套 start | startRuns 只在 startForeground 成功後回 active；失敗清 permit／service，前景降級。C1／C5／C8 驗 denied／security failure，不自動 loop。 |
| normal release 與 stopAll 混淆 | released 只結束服務，waiting approval 保留原到期；invalidated 使所有該許可 run 待明確續跑。C2b／C4 測另一段 send 不復活失效 run。 |
| 首頁 back「進行中」是否包含 approval／paused | 採 D7 的 backProtectedCount，包含兩者；serviceWorkCount 不含它們。Claude C6 接受此定義即可實作，不把現有 runningCount 一值用到底。 |
| 冷啟動 generation 數字可能重用 | 只路由當前 registry 已知 ID；舊程序 payload 一律安全首頁。C3 不持久化 routing／approval map，不新增 repository-derived persistence。 |
| 系統 kill 無 callback／日誌 unavailable | C7 沿現有 recovery／隔離，不聲稱 native 寫日誌；沒有可靠資料就顯示無法讀取並重試，不刪 key 或自動清 uncertain。 |
| Doze 下 FGS 不等於網路永遠可用 | V1 真量請求／stream；不私加 wake lock／白名單、不中途延長預算以湊 12 分鐘；未達目標如實保留限制。 |
| stable plugin／AGP／minSdk 漂移 | C3 實作當日重查 S1，精確 pin 並編兩 flavor；不改 pinned Flutter 來追 dev，相容問題記具體 blocker／選相容 stable 的偏離。 |
| dataSync 在 Play 是否核可互動 agent | 維持父計畫 dataSync，G6 由 Claude／MR7 提交示範與申報；沒有政策實際回覆不自稱核可。specialUse／UIDT 是另案評估，不自動切換服務 type。 |
| 實際六小時 timeout 昂貴、API 矩陣不齊 | V2 必跑可縮短的系統 timeout，預設六小時與缺 API 各列 NOT_RUN；lead 決定出貨前是否補長跑，不能把這個決定包裝成已驗證。 |
| iOS 的 §12.6 尚未交付 | 本包不做 background task；既有無許可背景寫入 gate 不放寬，iOS 實作／build／真機／第28列一律 NOT_RUN，另留交付項。 |

## §7 對其他計畫的必要修正（本文只提出，不改檔）

1. 父計畫 §14 把 app lock 列在 MR6c（`docs/plans/ai-writes-plan-v6.md:525`），但 `AppLockGate` 與原生 FragmentActivity 已實作。改寫為「沿用既有鎖，新增通知入口在解鎖後驗證與導頁」，不是重新交付鎖。
2. §12.2 的 native「約 50 行」（父計畫 `docs/plans/ai-writes-plan-v6.md:460`）改為非限制性估計；permit／nonce／失效／onTimeout 必須可測，不能為符合行數省略 guard。§12.3 通知只帶 ID／generation 的規則補上冷啟動 registry membership，避免跨程序 generation 重用誤導頁。
3. §12.2／12.3 的 22.3.2 是歷史查詢，本文 S1 本日為 22.3.3；實作當天仍選最新 stable。`CLAUDE.md:31` native 不提交與 §15 第22列 bootstrap 生成一致；加註實際管理函式冪等而 CLI 仍拒覆寫，不放寬。
4. §7.7 的續跑不重複是契約，不是現況 runner 已完成；雖有 coordinator resumeRun（`lib/core/ai/tools/write_coordinator.dart:573`），runner 仍 beginRun（`lib/core/ai/runner.dart:383`）。在 MR6c 狀態／驗收連結中明列 C5／V11 真接線，不能引用舊單元測試關閉第28列。
5. 一般跨 run／conversation 去重的延後註記（`docs/V0_6_AI_VERIFICATION.md:2016`、`lib/core/ai/tools/write_coordinator.dart:741`）須改成 D9 的實際範圍決定：同邏輯 run 續跑不重複、uploads 原跨 run 規則保留；一般全域去重未交付，不宣稱那些歷史註解已被實作。
6. `docs/PLAN_STATUS.md:43` 仍記 MR6b-3 P15／3t 在 review，`docs/PLAN_STATUS.md:44` MR6c 未開始；每個實作 MR 只更新自己真正完成的子項，C8 證據齊全後才關 MR6c，MR7 gate／G6／iOS 仍分開。不要由歷史 breakdown 的舊行號或代理人「完成」訊息推定上游已合。

## 附錄 A：範圍搜尋與驗收列責任索引

本次搜尋 `MR6c|mr6c` 的父計畫命中：`docs/plans/ai-writes-plan-v6.md:34`、`docs/plans/ai-writes-plan-v6.md:469`、`docs/plans/ai-writes-plan-v6.md:478`、`docs/plans/ai-writes-plan-v6.md:495`、`docs/plans/ai-writes-plan-v6.md:503`、`docs/plans/ai-writes-plan-v6.md:525`、`docs/plans/ai-writes-plan-v6.md:557`、`docs/plans/ai-writes-plan-v6.md:562`、`docs/plans/ai-writes-plan-v6.md:614`、`docs/plans/ai-writes-plan-v6.md:620`、`docs/plans/ai-writes-plan-v6.md:689`、`docs/plans/ai-writes-plan-v6.md:724`、`docs/plans/ai-writes-plan-v6.md:741`。其中後五個歷史註記要求保留 minSdk／不加 multidex、原生先停、原生通知 owner、無 boot receiver、背景 channel 1 秒與實際服務重跑第28列，分別落到 C1／C3／C4／C8，沒有當成額外已完成能力。其餘現況註解與狀態提及在 `docs/PLAN_STATUS.md:25`、`docs/PLAN_STATUS.md:44`、`docs/PLAN_STATUS.md:61`，以及 `lib/features/ai/ai_run_registry.dart:54`／`lib/features/ai/ai_chat_controller.dart:464` 的既有前景限制註解；C5 完成後才更新對應註解，不提前放行。另有 `docs/plans/mr6b1-breakdown.md:466`、`docs/plans/mr6b1-breakdown.md:659` 的延後原生／通知所有權，以及 `docs/plans/mr6b1-breakdown.md:667` 的 flush 後 notExecuted／不重用核准，分別由 C1–C5 與 D6 承接；`docs/V0_6_AI_VERIFICATION.md:2016`、`lib/core/ai/tools/write_coordinator.dart:741` 的跨 run 去重延後註記由 D9 的保守範圍決定承接。以上是排除本文後的全 repository 命中索引。

| 父計畫驗收列 | 分包主責 | 最終接受者／證據 |
|---|---|---|
| 22 bootstrap／native | C1 生成與拒未知；C3 desugaring／pin／privacy resources；C4 destroy／timeout；C6 back method | Claude C8：乾淨生成反讀、managed 函式重跑、雙 flavor merged manifest／APK 編譯、V2／V8／V9；Python／compile／OS 分列 |
| 27 原生許可 | C2a 邊界；C2b 綁定；C4 四停止路徑；C5 no-service 暫停／明確續跑；C7 destroy 恢復 | Claude C8 V3–V5／V8–V9／V11，包含背景＋活 engine＋丟 callback 的交集；1 秒、票重用、新 run 同 permit、失效 run 不自動重綁逐項 |
| 28 續跑不重複 | C5 邏輯 run／projection；C7 程序死亡恢復；現有 journal／重複確認測試回歸 | Claude C8 V11 實際 service Android 三條路徑；已 dispatching／全終態零重送、一行摘要、新重複確認。iOS NOT_RUN |

本計畫可交付給零背景的實作者：先照 §3 拿唯一檔案 owner 與前置 MR，實作 §2 契約，跑該包命令及 G0；Claude 同 MR 完成 UI／l10n 並親跑 §4，reviewer 用 §5／附錄 A 核對證據。沒有取得實際輸出的 gate 保持 NOT_RUN。
