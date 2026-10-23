# C2 加密磁碟快取封包拆分 v3（僅規劃）

## Changes from v2

依 `PACKET-v3.md` 採保守答案；本表涵蓋兩份 round-2 review 的每項新 finding。v2 已解決的 round-1 安全契約完整保留；原五包的 d 改為三個**各自獨立 MR**，不是同一 MR 的三段 commit。

| Round-2 finding | v3 變更 | 落點 |
|---|---|---|
| Opus N-1 | a 定義 `FailureKind.readCacheCleanup`／結構化 state；c 保存 notice；d1/d2 回報精確型別，e 獨占新文案及呈現；逐路徑定義回傳與 timeout。 | §2、§4.0、§4.2、§4.6、§6a/c/d1/d2/e |
| Opus N-2 | `labels` 同質字串或物件陣列；只留 LabelDetail 四欄；實際 `with_labels_details=true` issue/MR fixtures（含合法 null actor/metadata）可投影並真的寫盤。 | §1、§3.2、§6a/d1 |
| Opus N-3 | d1 寫刪／hydration、d2 session/startup、d3 typed pinned API；各自檔案＋區段 ownership、cap、前置與驗收。 | §2、§6d1–d3、§7 |
| Opus m-1 | observer 原時點安裝、journal 納入互斥；5 秒限制呼叫者等待。不可取消 I/O 的 AI 清理活性保留 F1，不宣稱已完全解決。 | §5.2、§6d2、§8.3 F1 |
| Opus m-2 | 先同步 `write(starting:true)` 再等 barrier；等待有 5 秒上限；close 精確回 cancelled，finally 配對。 | §4.2、§4.6、§6d1 |
| Opus m-3；GLM Minor 2/5 | 同帳號 single-flight＋marker revision/reason 所有權；同批 intent 重用，scope 收尾不能刪除 account-clear marker。成本量測列 follow-up。 | §4.2、§5.1、§6c、§8.3 F2 |
| Opus m-4 | 補 `references.{short,relative,full}`、`merge_user:Actor?` 及實際顯示需要的 auto-merge 狀態；白名單仍封閉。 | §3.2、§6a/d1 |
| Opus m-5 | 「我的」入口修正為 `_MobileShellState` build 約 1070–1170；不存在的類別名稱不沿用。 | §2、§6e |
| Opus m-6 | inventory、目錄與待寫工作都確認為空才 no-op，不寫 marker；未知／configure 失敗不能 no-op。 | §5.3、§6c/d2 |
| Opus m-7 | e 可再拆為設定／啟用及 diff/log 採用，記為非阻擋 follow-up；本輪不另擴包數。 | §8.3 F3 |
| Opus m-8 | 本地只跑有界集合；每包實作合併仍須該 MR 實際 HEAD 的完整 `ci/check.sh` pipeline 結果。 | §6 共通驗收 |
| GLM Minor 1 | 原三階段升為 d1/d2/d3 三個 MR，各有受影響既有 suites，未完成後包也可合併。 | §2、§6d1–d3 |
| GLM Minor 3 | 拒絕表的 group 只指 group 物件／專案列表，issues/MR 明確回 E02/E09。 | §3.4 |
| GLM Minor 4 | d1 開工前從已合併 C1b-2c manifest 鎖定實際 V5 suite；檔名 not found 就不放行；d3/e 必跑同集合。 | §6 前置閘門、§8.2 Q10 |
| GLM Minor 6 | glob 零匹配是集合定義錯誤，fail hard；不以空集合通過驗收。 | §6 共通驗收 |
| GLM Minor 7 | 保留「原始 12 列外部報告 not found」，不捏造；本次逐列覆蓋父計畫可見矩陣。 | §7 |

## §1 範圍、基準與現況證據

基準為本次唯讀 checkout `cdcf4e9a5f0fdd0d236646af2770d9090a83dcbc`。原始碼路徑相對於 `repo/`；`plan:L` 指 `docs/plans/cache-plan-v3.md:L`。CRA＝`lib/core/cached_read_api.dart`；GA＝`lib/core/gitlab_api.dart`；SC＝`lib/features/auth/session_controller.dart`；MAIN＝`lib/main.dart`；AAR＝`lib/features/ai/ai_account_removal.dart`；AIS＝`lib/features/ai/ai_stores.dart`。

只做規劃，不修改 repo、git 狀態或產品；不連網、不讀秘密、不啟動 workflow modes。所有產品 analyze／Flutter tests／build／裝置／CI 驗收在本次均為 **NOT_RUN**；下文命令是未來封包的要求。

父計畫後補條款優先於正文（plan:3、449）：V11、V12、V13、V14、V16、V17、V18、V19 m-9、V20 m-10/m-11、V21 全部適用。範圍是 §4.1 白名單資料及 §4.7 明列 pinned 內容；不包含 C3 冷啟動離線模式。先 currentUser 網路驗證，才顯示 disk 值（plan:653）。

| 現有接縫／缺口 | 本次原始碼證據 | C2 落點 |
|---|---|---|
| 目前只有讀盤 callback | CRA:58–74；GA:150–191；呼叫在 CRA:998–1011；publication 寫入只有 memory，CRA:1166–1193 | d1 補 backend；a 先定義純契約。正式 disk store／projection／開關目前 **not found**。 |
| 隱私及 mutation/revoke | CRA:515–594、1275–1308、1310–1367；GA:324–326、368–402、460–477 | d1 接讀、寫、刪；c 負責 durable I/O。 |
| labels／列表顯示欄 | `my_work_page.dart:58–63`、`inbox_page.dart:102–107,214–217`、`groups_page.dart:253–268`、`board_queries.dart:235` 帶 detailed labels；`workspace_ui.dart:229–248` 同時讀字串/物件；`work_item_page.dart:2281–2285` 讀 merge_user | a 定義兩種 labels、References/Actor；d1 用 E02/E09 實檔證據，e 不補投影。 |
| 既有 fixture 的落差 | `test/cache_c1b2a_test.dart:396–413,450–460` 的 detailed query 仍用字串 labels；`test/support/workspace_fixture.dart:42–45,87–105` 有物件 label 字典但 issue/MR seeds 為空 | a/d1 在各自測試檔內建物件/字串 fixture；不把舊 fixture 綠燈當真實形狀證明。`tool/live_smoke.dart:188–200` 的物件斷言只讀，不執行網路 smoke。 |
| 清除 failure 尚無型別 | `failure.dart:9–13,22–30,64–105` 無 read-cache kind；`workspace_ui.dart:593–714,789–793` 是集中呈現接縫；`app_en.arb:43,403` 已有通用鍵 | a 新增 kind/state/fallback，c 保存結構 notice，d1/d2 產生，e 才增加所有新文案。 |
| Accept 與 generation | CRA:403–415 的 memory key 含 generation/Accept；CRA:70–74 source 收 caller URI | 新 durable key 去 generation，保留 representation；別名只能 project detail。 |
| 啟動與 bind | SC:107–112 先 accountsLoaded，119–138 才 marker/lastActive；146–157 currentUser；496–507 generation++/bind | d2 建立 startup decision 及 activation 會合；不從 accountsLoaded 推論。 |
| sign-out／移除 | SC:603–624 _commitSignOut、651–690 remove；AAR:305–313 drafts→artifacts→recent；336–347 失敗 notRemoved | c 插 clearReadCacheDisk；d2 加 session 內第二道 clear。 |
| 啟動掃描尚未保證 C2 次序 | MAIN:51–60 的兩個 recovery 是 unawaited；112–157 journal 只等 accountsLoaded；`ai_history.dart:822–888` 先裝 observer 才 recover | d2 保留 observer 時點，注入僅包住 recovery 工作的共用 gate，含 journal。 |
| 現成 crypto／storage 模式 | `ai_history_files.dart:29–30` 帳號 hash；`ai_history_codec.dart:497–554`；AIS:1039–1044 storage options；`pubspec.yaml:15,23–24,32` 既有依賴 | b 重用既有套件與安全模式，自己組 read_cache AAD；不從 core import AI。 |
| stale 目前按 age 算 | CRA:958–970；`record_controller.dart:144–161`；`records_feed.dart:202–232` | d1 修 disk mutable stale；e 重用呈現並測最後更新。 |
| pinned 畫面尚未走快取 | `diff_page.dart:379–395` 用 records/record；`ci_page.dart:1791–1802` 用 jobTraceChunk；GA:1596–1613 直接 _read | d3 提供 opt-in typed API；e 換最小畫面呼叫。generic record(s) 不變。 |
| 硬性外部前置仍有缺口 | `docs/PLAN_STATUS.md:50–61`；`lib/core/ai/tools/gitlab_read_port.dart:154,165` 及 `lib/features/ai/ai_chat_context.dart` 現無完整 V5 的 allowDisk:false 接線 | 計畫狀態頁與 PROMPT 的已合併描述有時差；不重做已在 checkout 的前置，但 d1 必須等待 C1b-1b、完整 C1b-2（含 2b/2c）實際 source 與驗收。 |

## §2 七包順序、檔案＋區段單一擁有權

順序固定為 **P-C2a → P-C2b → P-C2c → P-C2d1 → P-C2d2 → P-C2d3 → P-C2e**；一包一 MR，各自在前包合併後才開工／驗收。原 PROMPT 的 3–5 包是目標，本輪 N-3 的明確拆包要求優先，故為七包。a–d3 為 Codex；e 的 UI/UX、l10n 與正式啟用由 lead Claude（plan:16、362；PLAN_STATUS:32）。不啟動任何 workflow mode。

N＝新增、E＝修改。下表是封閉 manifest；同一列有多個精確路徑時，各檔由同一 owner 獨占。**同一檔案在同一 MR 只有一 owner；跨 MR 的區段交接只能在前包合併後發生**。GA 由 d1 先交共用 helper，d3 只新增 typed API 區段，不能回頭重寫 d1；a 的 contract、c 的 coordinator 後包只呼叫。區段行號皆指本次 baseline，落地 rebase 後以具名方法重定位。

| 檔案／區段 | owner | 類別／允許範圍 |
|---|---|---|
| `lib/core/read_cache_disk_contract.dart` | a | N；純 DTO、backend、lease、clear/startup/terminal proof、cleanup state 契約。 |
| `lib/core/read_cache_projection.dart` | a | N；§3 封閉投影、canonical durable key。 |
| `lib/core/failure.dart` | a | E；9–13 enum、23–30 欄／typed constructor、64–105 通用 fallback，並在同檔新增 ReadCacheNotice/sink；不增文案，不改既有 kinds。 |
| `test/read_cache_disk_contract_test.dart`、`test/read_cache_projection_test.dart`、`test/read_cache_failure_test.dart` | a | N；含真實 request/query 形狀的本地合成 fixtures。 |
| `lib/core/read_cache_cipher.dart`、`lib/core/read_cache_files.dart` | b | N；純 crypto／有界檔案原語，root 注入。 |
| `lib/features/cache/read_cache_key_store.dart` | b | N；secure-storage key／marker 原語、獨立 inventory；不自動建鍵。 |
| `test/read_cache_cipher_test.dart`、`test/read_cache_files_test.dart`、`test/read_cache_key_store_test.dart` | b | N |
| `lib/features/cache/read_cache_disk_coordinator.dart`、`lib/features/cache/read_cache_settings_store.dart` | c | N；§5.1/5.3，含 controls gate、notice snapshot/訂閱、marker owner、retry、單帳號 queue。 |
| `lib/features/ai/ai_account_removal.dart` | c | E；197–214 optional clear hook、305–313 recent 之後加步驟；保持 catch/notRemoved。 |
| `test/read_cache_disk_coordinator_test.dart`、`test/read_cache_settings_store_test.dart` | c | N |
| `test/ai_account_removal_test.dart` | c | E；清除排序／失敗門檻。 |
| `lib/features/cache/read_cache_disk_backend.dart` | d1 | N；a→c adapter，無 UI import。 |
| `lib/core/gitlab_api.dart` 的 imports、attach、傳輸及 observation 段 | d1 | E；150–234、310–477、590–614、954–960、1197–1223、1372–1375；backend、begin/end barrier、bound terminal 401、OAuth/raw、隱私讀取。 |
| `lib/core/cached_read_api.dart` | d1 | E；58–84、305–374、515–680、729–753、958–1205、1275–1367；bind/lease、walker、stale、source、publication、write/privacy/revoke/close。 |
| `test/read_cache_disk_source_test.dart`、`test/read_cache_disk_integration_test.dart` | d1 | N；實際普通 endpoint／file/tree 的 disk 寫讀及 N-1/N-2。 |
| `test/cache_c2_prereq_test.dart`、`test/cache_hydration_test.dart`、`test/cache_oauth_test.dart`、`test/cache_privacy_test.dart`、`test/cache_c1b2a_test.dart` | d1 | E；exact failure、privacy、OAuth、詳細 labels 回歸；不改 shared fixture。 |
| `lib/features/auth/session_controller.dart` | d2 | E；87–189、select、371–395、496–507、603–690；startup decision、candidate 401、attach、D1、remove commit fence、結構 notice。 |
| `lib/main.dart` | d2 | E；51–158、165 起 app lifecycle；configure、掃描 gate、journal 串行、listener/dispose。 |
| `lib/features/ai/ai_history.dart` 的 recovery gate 注入段 | d2 | E；851–888 的 `startRecovery` 保留 observer 安裝，僅加預設相容的刪除階段 gate；822–849 的語意及 AI stores/codec/key/file 規則不改。 |
| `test/read_cache_startup_test.dart`、`test/read_cache_recovery_order_test.dart` | d2 | N；controlled Futures、三種 recovery 的序列與失敗／timeout。 |
| `test/cache_session_binding_test.dart`、`test/session_test.dart`、`test/account_switch_resume_test.dart`、`test/account_switch_resume_adversarial_test.dart`、`test/ai_startup_fix1_test.dart` | d2 | E；session/recovery 契約，無 UI 文案新增。 |
| `lib/core/gitlab_api.dart` 的 typed pinned 段 | d3 | E；1586–1700 附近新增 `cachedMergeRequestVersion`／`cachedTerminalJobTrace` 及專用 Range helper；用 d1 已存在的 publication helper。GA imports 區段只准引用此前已存在的 core 型別；無新 part。 |
| `test/read_cache_pinned_api_test.dart`、`test/read_cache_ai_boundary_test.dart` | d3 | N；E18/E19 實檔＋實際 AI port/context 邊界。 |
| `lib/features/cache/read_cache_settings_page.dart` | e | N；開關／大小／清除，消費 c snapshot。 |
| `lib/features/shell/authenticated_app.dart` | e | E；`_MobileShellState` build 約 1070–1170 的「我的」入口、shell notice 及最後 `installUserControls()`。 |
| `lib/features/auth/login_screen.dart` | e | E；signed-out 清除失敗的結構 notice／重試入口；不改 session 語意。 |
| `lib/shared/workspace_ui.dart` | e | E；593 起 `FailureNotice`、789 起 `showFailure` 對新 kind 的集中呈現；原 outcomes 不改。 |
| `lib/features/workspace/records_feed.dart` | e | E；202–232 必要的 fetchedAt 呈現；優先直接重用 strip。 |
| `lib/features/workspace/diff_page.dart`、`lib/features/workspace/ci_page.dart` | e | E；379–395 version detail、1791–1818 terminal trace 採用；generic discovery/polling 保留。 |
| `test/read_cache_settings_test.dart`、`test/read_cache_pinned_ui_test.dart` | e | N |
| `test/failure_notice_test.dart`、`test/login_widget_test.dart`、`test/authenticated_app_test.dart` | e | E；新 cleanup kind/notice、語系與重試呈現。 |
| `lib/l10n/arb/app_*.arb`、`lib/l10n/strings*.g.dart` | e | E；所有 locale 同鍵／placeholders；g.dart 只由 `tool/l10n.py` 產生。 |
| `AGENTS.md`、`CLAUDE.md`、`docs/PLAN_STATUS.md`、`docs/STORE_LISTING.md` | e | E；Persistence/keys/marker/inventory、殘留、移除順序、平台與實際 gates。 |

`ai_stores.dart`／`AiSecureInventory`、`workspace_api.dart`、`lib/core/ai/`、`ai_chat_context.dart`、`record_controller.dart`、`lib/shared/cache_freshness.dart`、`test/support/workspace_fixture.dart` 只讀／重用。唯一 AI source 例外是 d2 明列的 history recovery gate；不是讀寫內容或 policy 改造。V5 的 AI production 變更仍由前置 C1b-2c 完成，C2 不偷改。表外檔若確有必要，先修 manifest/cap 再實作，不能由後包默默修前包。

| 封包 | 新檔 cap | 既有檔 cap | 責任章節／中間 main |
|---|---:|---:|---|
| a | 5 | 1 | §3、§4.0/4.6 型別；無 I/O，fallback 用已存在 l10n。 |
| b | 6 | 0 | §6b 原語；不 auto-ensureKey。 |
| c | 4 | 2 | §5.1/5.3；無 production writer、AI 孤兒掃描不動。 |
| d1 | 3 | 7（2 source＋5 tests） | §4.1–4.4、§4.6 傳輸；無 SC/MAIN/typed API/UI 依賴。 |
| d2 | 2 | 8（3 source＋5 tests） | §5.2、candidate401/D1；不改 d1 core 或新文案。 |
| d3 | 2 | 1 | §4.5；只改 GA pinned 區段，不等 e。 |
| e | 3 | 6 UI＋3 tests＋4 docs＋現有全部 ARB/g.dart | §6e 呈現、畫面採用／文件／最後啟用。 |

每個 cap 是上限，不是必須多造檔案。GA 的兩次 E 在不同 MR、不同主要區段，前包已合併才交接；不得平行工作。

| consumer | 可 import 的新檔提供者 | 禁止依賴 |
|---|---|---|
| a | a 與既有 Dart／套件／l10n | b/c/d1/d2/d3/e；contract 不 import failure，failure 可 import contract。 |
| b | a、b | c/d1/d2/d3/e |
| c | a、b、c | d1/d2/d3/e；不 import GA 新 adapter 或 UI。 |
| d1 | a、b、c、d1 | d2/d3/e；不引用未來 SC accessor、typed API 或新 l10n。 |
| d2 | a、b、c、d1、d2 | d3/e；recovery hook 型別使用既有／a 純型別，不指向 MAIN。 |
| d3 | a、b、c、d1、d2、d3 | e；GA 不 import features/cache。 |
| e | 全部已合併包及 e | 無後包。 |

production 與 test 的 imports/part/fixture/accessor 都受此表約束。a 使用純 DTO／Object；c 收已投影 entry；d1 將 CRA 私有 policy/context 轉成 DTO，feature backend 才轉到 c。GA 只 import core 契約。d2 的 `ai_history.dart` 只收注入的 async runner，不 import MAIN/read-cache feature，既有呼叫不給參數行為不變。後包不靠不存在的 stub 建置。d1/d2/d3 全程 `controlsInstalled=false`，安全恢復／清除可跑，業務讀盤、寫入、建鍵都關閉。

## §3 附上的封閉 endpoint → projection 表（a）

### §3.1 共通資格、key、schema

所有列先符合：驗證過的帳號／instance；明確選用的 cacheable GET；第一頁（request 無 `paginationKeys`，`cachedRecords` 的 request `next == null`，不是要求 response 沒有下一頁連結）；非 search；`no-store == false`；合法 URI／query；可有界投影。所有 `:p/:g/:u/:i/:n/:j/:v` 為正規正整數；`:discussion`／`:file` 為該 API 經驗證的單一編碼 path segment。檔名不能直接採 server path。

durable canonicalKey＝`jsonEncode([accountKey, "GET", instanceValidatedCanonicalPath, sortedSemanticQueryPairs, logicalAccept])`；**不含 generation**。accountKey 保留 scheme/host/port/subpath/userId；query 保留全部已允許語意、含 per_page/filter/ref/path。拒絕 duplicate query keys、敏感 query key 與不確定表示；不任意省略 filter。project detail 使用 `license=true` 超集合；full-path detail 只有在 caller path 與網路驗證的 path/id 一致後才寫數字 id key。冷啟動未知別名回 miss，不能靠磁碟 alias 重用冒認新專案。其他 full-path 子資源依 V21 直接網路。

JSON 的 optional 白名單欄缺席可省略；只有 §3.2 明列的 nullable 欄可為 null，原樣保留 null；其他出現而型別錯，整份 null。mandatory identity/shape/guard 缺失一律 null，不能插入 false/空列表「修好」。所有未列 key 均剔除，巢狀物件也逐欄。陣列不做合格列過濾：一列不合格整份 null。不得保存原始 response、headers、request options、credentials、token 欄位、`runners_token`、**任何 import_url**、簽名下載 URL。

只有表內明列的 URL 欄可存；只接受與目前 instance 同源、安裝路徑內的 HTTPS URL，禁止 userinfo、fragment、任何 query；不安全 optional URL 整欄省略，不落原值。所有其他 URL 欄省略。Markdown body/description/diff 是父計畫接受的內容殘留，不以 regex 假裝已消除其中的引用或秘密。

頁面磁碟格式是 `{items, next}`；`next` 僅為驗證過同 endpoint/原 filter 的 pagination URI，hydrate 仍跑 `_validateContinuation`，不把 next 頁內容存盤。若 cursor 含敏感 query，整份不存。`fetchedAt` 永遠是原始網路取得時間。

純 `ReadCacheProjectionContext` 由 a 定義，d1 從同一 `_ReadCache` 建立：now、network-lineage fresh public issue identities、confirmed SHAs、目前範圍／privacy epoch、trusted terminal-job proof。子資源 `freshPublicIssue(p,i)` 必須同 client 的**單筆** memory 值、network lineage、明確 false、未到30秒 detail freshness、versions有效、最新 marker非 true；disk 單筆／列表列不提供資格。前置與 commit 前都重驗；a 不自行存取 client 或發 request。

### §3.2 精確巢狀投影字典

下列欄位全集就是 schema；沒有「其餘 UI 欄位」逃生口。`T?` 表示可為 null，非 null 仍須符合 T；其他欄位不得以 optional 當成接受 null。所有 id 為 int、字串為 String、旗標為 bool、時間為可驗證 ISO 字串。必要 id／iid／title 依列驗證。identity 不一致一律 null。投影及原始 walker 採同一組保守上限：root 容器深度算1，最多32層、每個陣列最多4096項、整份最多32768個值節點（含容器）；超一者整份 null。a 測每個上限及上限+1；byte cap 仍另外適用，不能拿節點上限放寬 §4.0。

| 名稱 | 精確允許 key／子欄位 |
|---|---|
| Actor | `id, username, name, avatar_url, web_url`；不含 email、state、token。 |
| LabelDetail | 只准 `id:int, name:String, color:String, text_color:String`；name/color 必要，id/text_color 可缺席但出現就驗型別；兩個 color 若出現都必須符合 `^#[0-9A-Fa-f]{6}$`。description 與其餘 key 剔除。 |
| Labels | 同質 `[String]` **或** `[LabelDetail]`；空陣列可接受；混型、null 列、錯色碼／錯型別整份 null；不把物件轉字串或靜默剔列。 |
| References | 只准 `short, relative, full`，每個出現者均 String；不保存其他 refs/url 欄。 |
| Project | **僅 plan:252**：`id, name, path_with_namespace, description, visibility, default_branch, star_count, forks_count, open_issues_count, last_activity_at, license.{name,key}, web_url, avatar_url, archived, namespace.{id,name,full_path,kind}`。 |
| Milestone | `id, iid, title, state, due_date`；僅 issue/MR 的子欄位，不授權 milestone endpoint。 |
| Issue | `id, iid, project_id, title, description, references:References, state, confidential, created_at, updated_at, closed_at, due_date, web_url, author:Actor, assignee:Actor?, assignees:[Actor], labels:Labels, milestone:Milestone?, user_notes_count, upvotes, downvotes, task_completion_status.{count,completed_count}, time_stats.{time_estimate,total_time_spent,human_time_estimate,human_total_time_spent}`。`confidential` 必須明確 false；project_id/iid 必須可驗證。 |
| MR | `id, iid, project_id, title, description, references:References, merge_user:Actor?, merge_when_pipeline_succeeds, auto_merge_enabled, state, created_at, updated_at, merged_at, closed_at, web_url, source_branch, target_branch, source_project_id, target_project_id, sha, diff_refs.{base_sha,head_sha,start_sha}, draft, work_in_progress, merge_status, detailed_merge_status, changes_count, diverged_commits_count, rebase_in_progress, has_conflicts, author:Actor, assignee:Actor?, assignees:[Actor], reviewers:[Actor], labels:Labels, milestone:Milestone?, user_notes_count, upvotes, downvotes, head_pipeline.{id,status}, time_stats.{time_estimate,total_time_spent,human_time_estimate,human_total_time_spent}`。不存泛用 merge params／permissions。 |
| Note | `id, body, created_at, updated_at, system, internal, confidential, noteable_id, noteable_iid, noteable_type, author:Actor, resolvable, resolved, resolved_by:Actor?, position:Position?`。留言資格見下。 |
| Position | `position_type, base_sha, start_sha, head_sha, old_path, new_path, old_line, new_line, line_range.{start.{type,old_line,new_line,line_code},end.{type,old_line,new_line,line_code}}`；行號 int，line_code String；不授權回放或寫入。 |
| Discussion | `id, individual_note, notes:[Note]`；notes 必須完整、逐則合格。 |
| Emoji | `id, name, user:Actor, created_at, updated_at`。 |
| LinkedIssue | `Issue` 加 `issue_link_id, link_type`；其 project_id/iid 是被連結議題，不可從外層父 issue 猜。 |
| RelatedMR | `MR` 加 `issues:[Issue]`、`closes_issues:[Issue]`、`related_issues:[Issue]`（僅出現時）；出現其他議題形狀仍須先通過原始 walker，不得藉剔欄繞過 V11。 |
| Approvals | `id, iid, project_id, approvals_required, approvals_left, approved_by:[{user:Actor}]`；不存 rules/request options。 |
| Pipeline | `id, iid, project_id, name, status, source, ref, sha, web_url, created_at, updated_at, started_at, finished_at, duration, queued_duration, user:Actor`；僅單筆。 |
| Job | `id, name, status, stage, ref, created_at, started_at, finished_at, erased_at, duration, queued_duration, failure_reason, web_url, user:Actor, pipeline.{id,iid,project_id,status,ref,sha}, artifacts_file.{filename,size}`；不存 artifacts 路徑／下載 URL、runner、variables、token、credentials；僅單筆。 |
| TreeEntry | `id, name, type, path, mode`；只接受現有 TreeEntry.fromJson 可還原的 shape。 |
| FileMetadata | `file_name, file_path, size, encoding, content, content_sha256, ref, blob_id, commit_id, last_commit_id, execute_filemode`；encoding只接受已支援的base64，解碼後與整個明文都須有界。不存任意 links。 |
| MRVersion | `id, created_at, base_commit_sha, start_commit_sha, head_commit_sha, state, real_size, diffs:[Diff]`。 |
| Diff | `old_path, new_path, a_mode, b_mode, new_file, renamed_file, deleted_file, generated_file, collapsed, too_large, diff`；未提供／collapsed 的內容不製造。 |
| TerminalLog | `projectId, jobId, finishedAt, startOffset, nextOffset, totalBytes, isEof, truncated` 的技術 metadata＋有界 raw UTF-8 tail bytes；不存本地化前綴、headers、任意 chunk。 |

**合法 null 的封閉補表**：除了上列 `?`，以下 optional 顯示 metadata 允許原樣 null；這是 schema 的一部分，不是任何錯型別都當缺席。空陣列與 null 不互換。`workspace_ui.dart:29–37` 的 valueText/valueObject 及 `work_item_page.dart:459,2281–2285` 已按缺值呈現，不讓普通未指派／未合併列表因 null 被整份拒絕。

| schema | 允許 null 的既有白名單欄位（不增加其他欄） |
|---|---|
| Actor | avatar_url、web_url。 |
| Project | description、default_branch、last_activity_at、license、avatar_url、web_url。 |
| Issue | description、assignee、milestone、closed_at、due_date。 |
| MR | description、assignee、milestone、merge_user、merged_at、closed_at、head_pipeline、diff_refs。 |
| Milestone／Issue/MR time_stats | Milestone.due_date；time_stats.human_time_estimate/human_total_time_spent。 |
| Note | resolved_by、position。 |
| Pipeline／Job | started_at、finished_at、duration、queued_duration；Job 另允許 erased_at、failure_reason。 |

`confidential/internal`、identity、LabelDetail.name/color/出現的text_color、陣列及其元素、fresh-public/confirmedSHA/terminal proof **不適用 null 例外**。例如 merge_user:null 可保存；merge_user:17、labels:null、label色碼null、confidential:null 仍整份拒絕。Job.finished_at:null 可存中繼資料，但絕不能產生 terminal proof/E19。

Project 消費端會讀 `marked_for_deletion_on`（`models.dart:181–206`），但 plan:252 沒允許。採保守修復：若原始值非空，整個 Project/含該列的頁不落盤；不增加此欄、不把刪除中專案呈現成普通磁碟專案。其他無允許欄位的控制能力不可由 disk 資料授權，操作前仍用原本 fresh preflight。`project_overview.dart` 用的 `namespace.name` 已在父表內。

### §3.3 允許的完整 endpoint 表

前綴均為當前 instance 的 REST `/api/v4/`。`[]` 表示一頁陣列；單筆為 object。除了表列 shape，所有其他路徑／後綴都 null。JSON logical Accept 為 `application/json`；raw/text 為 `text/plain`，兩者不同 key。

| ID | 精確 endpoint pattern／shape | 投影及額外必要守衛 | issue index |
|---|---|---|---|
| E01 | `projects` → [Project]；`projects/:p` → Project | Project；path detail 可依 §3.1 已驗 alias轉數字ID；只留 plan:252。 | 原始 walker 的全部議題；通常空。 |
| E02 | `issues`、`groups/:g/issues`、`projects/:p/issues` → [Issue] | Issue；每列明確 false；專案列表的 project_id 與路徑一致。 | 每列 `(project_id,iid)`。 |
| E03 | `projects/:p/issues/:i` → Issue | Issue；identity 精確比對，false。 | 自己＋所有巢狀議題。 |
| E04 | `projects/:p/issues/:i/notes[/:n]` → [Note]/Note | freshPublicIssue(p,i)；每則 Note 合格。 | 父 issue＋所有巢狀議題。 |
| E05 | `projects/:p/issues/:i/discussions[/:discussion]` → [Discussion]/Discussion | freshPublicIssue；全部 notes 合格，無不明／部分 notes shape。 | 同上。 |
| E06 | `projects/:p/issues/:i/award_emoji` → [Emoji] | freshPublicIssue；Emoji。 | 父 issue＋巢狀。 |
| E07 | `projects/:p/issues/:i/related_merge_requests` → [RelatedMR] | freshPublicIssue；MR 與全部內嵌 Issue 合格。 | 父 issue＋跨專案內嵌 identities。 |
| E08 | `projects/:p/issues/:i/links` → [LinkedIssue] | freshPublicIssue；每個 linked issue 自己明確 false。 | 父 issue＋每個 linked identity。 |
| E09 | `merge_requests`、`groups/:g/merge_requests`、`projects/:p/merge_requests` → [MR] | MR；原始巢狀 issue 全部合格。 | 所有巢狀 issue。 |
| E10 | `projects/:p/merge_requests/:i` → MR | MR identity 精確比對；原始 walker 合格。 | 同上。 |
| E11 | `projects/:p/merge_requests/:i/approvals` → Approvals | Approvals；id/iid/project_id若提供必須匹配。 | 原始 walker 集合。 |
| E12 | `projects/:p/merge_requests/:i/notes[/:n]` → [Note]/Note | 每則 Note 合格；不套 issue parent guard。 | 原始 walker 集合。 |
| E13 | `projects/:p/merge_requests/:i/discussions[/:discussion]` → [Discussion]/Discussion | 全部 notes 合格。 | 原始 walker 集合。 |
| E14 | `projects/:p/pipelines/:n` → Pipeline | Pipeline 單筆，id/project 匹配；不是 pipelines 列表或 jobs 子列表。 | 原始 walker 集合。 |
| E15 | `projects/:p/jobs/:j` → Job | Job 單筆，id及pipeline.project_id若存在須匹配；只是中繼資料。 | 原始 walker 集合。 |
| E16 | `projects/:p/repository/tree?ref=:sha` → [TreeEntry] | confirmed 完整40/64位小寫SHA；語意query全保留；只第一頁。pinned。 | 空。 |
| E17 | `projects/:p/repository/files/:file?ref=:sha` → FileMetadata；同路徑 `/raw` → text | confirmed SHA；FileMetadata 或有界 UTF-8 原文；README 走同 raw/text 路徑，不另給 branch 特權。pinned。 | 空。 |
| E18 | `projects/:p/merge_requests/:i/versions/:v` → MRVersion | d3 的明確 typed API，版本id匹配，diff SHA/shape有效；versions discovery 不落盤。pinned。 | 原始 walker 集合。 |
| E19 | `projects/:p/jobs/:j/trace` → TerminalLog | 僅 d3 的 terminal-tail API；同 client 新鮮網路終局 Job proof、finishedAt/attempt identity、完整且可驗的尾段；offset/query chunk API 不在此列。pinned。 | 空。 |

E16–E19 只源自 §4.7（plan:344–350），不把 §4.1 白名單擴成所有 cacheable endpoint。專案清單採 E01 的最窄路徑；`groups/:g/projects`、`users/:u/starred_projects` 此版留記憶體，不能以同 Project schema 自動加進表。

**留言規則**：若有 internal 欄，必須是 bool false；不得用 confidential:false 覆蓋 internal:true/錯型別。只有 internal **缺席**才接受明確 confidential:false；兩者缺席／null／錯型別均不合格。若兩者均存在而 confidential:true，也拒絕。任一 discussion note 不合格，整份 response 不存；不提示被剔除列數（plan:259–261、594–595）。

**原始 V11 walker** 在投影前遍歷整份 raw JSON：endpoint 定義的 Issue、links、任何巢狀 issue/issue target 都檢查其自己的 project_id/iid/boolean confidential。identity 無法證明、疑似議題形狀卻不能分類、未知巢狀議題結構一律整份 null；不能先剔除欄位再掃。index 取完整原始議題集合，並加入 issue 子資源父 identity；type/identity 不確定不保存。讀回也重驗 schema、index identity 集與目前 privacy fence。

### §3.4 明確拒絕表（完整分類盤點）

| 現有分類／路徑族（CRA:596–679） | C2 判定 |
|---|---|
| `groups`、`groups/:g`、`group-path:`、subgroups、descendant_groups | 僅既有 memory；這裡只指 group 物件／子群組，無 Group disk schema；group issues/MR 分別依 E02/E09，不受此列排除。 |
| group projects、users starred_projects | 僅 memory；不在 E01。 |
| branches／tags／commits（單筆及列表） | 僅既有 memory；網路可確認 SHA，整份 commit／email 不落盤。 |
| pipelines／jobs 列表及 pipeline jobs、其他 pipeline/job 子資源 | 僅既有 memory 或 D3 網路；E14/E15 只授權單筆。 |
| members、starrers、forks、labels、milestones、releases（含 asset links） | 僅既有 memory；不存整份內嵌物件。 |
| MR award_emoji、versions 清單、未列名的 issue/MR 子資源 | 僅既有 memory／網路；不是泛用 thread 白名單。 |
| todos／events／users/:u/events／任何 search= 或 search 路徑 | volatile 僅 memory；永不 disk。 |
| GraphQL、HEAD、CDN、外部 URL、非GET | 永不 disk；GraphQL mutation 只發既有 mutation invalidation。 |
| 任何續頁、paginationKeys、非SHA或未確認SHA textFile/tree、full-path 子資源、未綁定 client、表外／未知路徑 | 不快取或依既有 D3；特別是未確認 textFile 每次走網路，不稱「只放記憶體」。 |

## §4 接縫契約及 d1/d3 的安全發布

### §4.0 a：純介面、failure home 與序列化契約

a 的 `read_cache_disk_contract.dart` 定義 `ReadCacheDiskBackend`、`DiskLookup`、`DiskWriteCandidate`、`ProjectedDiskEntry`、`DiskInvalidation`、`DiskInvalidationFence`、`DiskBinding`、`DiskClearResult`、startup/terminal-proof DTO 及 `ReadCacheCleanupState`。介面涵蓋 lookup、accepted candidate、可 await barrier、同步 fence/lease 撤銷、clear 結果及 `reportCleanup(state)`；不 import 後包或 `failure.dart`。純 TerminalLog DTO 定義 offsets/truncated，不含 UI 型別／文案。

`ReadCacheCleanupState` 的封閉欄位：`operation` enum（mutation/privacyRead/accountRemoval/signOut/settingsClear/startup）、`disposition` enum（requestBlockedBeforeSend/originalOutcomePreserved/legalNetworkValueReturned/accountRetained/signedOutCleanupPending/diskClosed）、`code` enum（cleanupFailed/barrierTimedOut）、`clearResult:DiskClearResult`。不含 exception、stack、URI、path、內容或帳號識別字串。`DiskClearResult` 固定四個 bool：keyGoneConfirmed、directoryGoneConfirmed、markerDurable、complete；未知是 false，不能從 unavailable 推論已清除。

a 同包修改既有 `failure.dart`：加 `FailureKind.readCacheCleanup`、`ApiFailure` 的 optional `ReadCacheCleanupState? cleanup` 與 `ApiFailure.readCacheCleanup(state)` 建構入口。新 kind 必須攜帶非null cleanup state（typed constructor與assert鎖住），其他 kinds 的既有建構相容；原 kind/status/retryAt 行為、`safeFailure(ApiFailure)` 的原物件保留不變。a 在該檔另定義非致命 `ReadCacheNotice`（內含 exact kind 為 readCacheCleanup 的 ApiFailure）及 sink 型別；contract 只傳 state，由 c 包裝 notice，避免循環 import。fatal 與 notice 使用同一 state，不能拿 network/cancelled/unsupported 冒充清除失敗。

此階段 `ApiFailure.title/detail` 對新 kind 僅用**既有** `l10n.tryAgainLater`／`l10n.retryAction` 作可建置的通用 fallback；a/b/c/d1/d2/d3 均不新增 ARB、accessor、使用者字串或 UI renderer。這不是正式啟用時的完整說明：e 在 `workspace_ui.dart` 集中依 kind/state、**當前語系**產生文案及安全 action；shell/login 呈現 c 的 pending notice，裝好才允許 controls gate。d1/d2 不 import e，也不等待後包字串。

entry 明文格式由 a 定義：4-byte metadata 長度＋UTF-8 metadata JSON＋body bytes。JSON/file 整筆≤1MiB；terminal log 整筆≤2MiB，含 canonicalKey/offset 等 metadata。tail budget＝2MiB−4−實際 metadata bytes；metadata 變長須重算，UTF-8 tail 起點移至合法邊界。queue 同樣計整個 serialized buffer，不以 base64 膨脹。b 實作純 codec/檔案格式，d1/d3 產生同 DTO，e 消費；無 b→d3 格式依賴。

### §4.1 network → disk write

d1 在 GA/CRA attach a 的實作；舊 `ReadCacheSource` 構造注入仍可作既有測試，但 production 統一 backend，不安裝兩個 writer。lookup delegate 每次動態查 coordinator，不把 closed 時的 null 永久固定進 client。

**唯一普通 publication 位置是 CRA:1166–1193 的 accepted 分支**：bound/account-generation current、canCache、未 invalid／timedOut／superseded／dropped、仍 ownsPublication，且 loaded.store、原始 bytes不超entryLimit。再要求非volatile、第一頁、§3投影成功、lineage network。這些條件全成立才送 projected candidate；不能由 source 重發網路取 body。typed pinned API 也須走同一 acceptance/lease helper，不另開繞過路徑。

事件帶：verified binding、canonical URI、logical Accept、bodyKind/page shape、原 network fetchedAt/bytes、public disk class、pinned flag、scope tags/version snapshot、raw issue identities、可信 projection context，以及不可持久化的 commit lease。lease 不直接引用已被 finishPublication 移除的暫時 ticket；在 accepted 時轉成固定 publication revision，保留至 commit/drop，受新 publication、scope/privacy/revoke epoch、session fence 撤銷。每次回主 isolate、建立 temp、寫入、entry rename、index commit 前重驗；epoch 檢查與 rename 需在同一 I/O 序列取得 commit 許可，不能有「檢查完又 await」窗口。

`loaded.store == false`（GA:230–234 的 no-store）或超量、投影失去安全資格時，對仍有發布權的 exact durable key 發刪除，不能留下上一份舊 disk。no-store 判斷含所有逗號分隔 directives／大小寫。過時 request 不得刪新 request 已發布的同 key。記憶體命中／hydration 不回寫，不改 fetchedAt；fresh 網路可 write-through。

### §4.2 d1：delete/invalidation、有限等待與 durable barrier

| 事件來源（bound 傳輸／CRA 的唯一 owner d1） | c/backend 必須刪除／撤銷的集合 |
|---|---|
| CRA:1275–1308 write，開始及結束；GA:324–326/460–462 | 按 V2 affected scopes 清 mutable entries；global 也只清 mutable。pinned 不登記 scope version、不等待 mutation、不被一般/global write 刪（V17）。 |
| CRA:515–594 privacy true 或拒絕舊 public 的衝突 | iid 單筆/子樹、該專案全部 issue-list keys、**所有範圍**內 index 含該 identity 的項目；含 userLists、groupWorkItems、links、related-MR。首次 true 也刪，不要求 memory 曾見 false。 |
| CRA:1310–1358，REST 403/404 | V2：GET project detail 清該 project；issue/MR 單筆清 iid 子樹；其他子資源清該 key/path 子樹；collection 只清該 query。pinned 不豁免。**issue 403/404 同時走 V11 index 刪除（V19 m-9，plan:697）**。 |
| bound 終局401 | account fence＋key→directory 清除；candidate/D1/sign-out/remove caller 另由 d2，I/O 仍只有 c。 |
| non-REST GraphQL 403/404、OAuth 可恢復401、clear(revoke:false)、單純 close | 不刪 disk；GraphQL status 保留原 read epoch 行為。close 只撤 client lease；D1 另從 SC 觸發。 |

c 的**權威記憶體索引**包含 durable、pending、in-flight 及已 rename 尚未 flush index 的項目；每次 invalidation 同時提高 scope/issue/path epoch、篩掉 queue、撤銷 in-flight lease。isolated writer 不能在刪除後補 rename 或補 index。index 毀損／不完整／不能證明集合時，V11/V12 都退化成**清整帳號**，不猜相關檔名。

V12 是**可 await 的 durable barrier**：同步封鎖舊值與 queue，完成匹配刪除及 index 安全提交。I/O 在 background isolate。d1 把 GA 的同步 `_cache.write(affected, starting:true)` 保留在所有 await **之前**，且在 try/finally 保護內；先讓讀者看見 active(scope)，再等 begin barrier，成功後才進 RequestMeter/Dio 的第一次 send。begin 失敗／逾時不送 HTTP、不增加 meter。finally 同步 end 計數恰一次；即使 begin 失敗、close 或後續 end barrier 失敗都不得洩漏 active count。

**本版保守設計值**：begin/end/privacy/terminal 清除的呼叫者等待各最多 5 秒，用 fake clock 驗邊界；並監聽 client close。send 前 close 優先回 exact `ApiFailure(cancelled)`；未 close 的 timeout 回 §4.6 指定 state/code。這是呼叫者等待上限，不是聲稱 Keychain/native I/O 可被取消。逾時立即撤 lease、fence、留 pending；c 的 account queue 在底層操作停止／ack 之前不交給下一個會建鍵或 rename 的操作。晚完成不能發布、重開、刪除別人的 marker 或授權先前 mutation 補送。禁止只用 Future.timeout 就把仍在跑的作業視為結束。

刪除失敗升級 full-account clear；未確認 key 或 directory 至少一者消失，send 前不放行。begin barrier 成功須匹配刪除/index 安全提交，升級 full clear 則保守等 complete；僅達移除帳號的「至少一者消失」門檻不算 mutation barrier 已成功。send 已開始則保留既有成功／原 ApiFailure（含 writeUncertain）及 stack，另外記錄 notice；不得在 unguarded finally await 用清除錯覆蓋原 outcome，也不得自動重送。privacy read 的合法 fresh 網路值照常回傳，disk 保持 closed。逐路徑結果在 §4.6。

**crash 邊界**：durable 刪除前，先用 read_cache_clear_pending 寫/readback account-level intent；正常 scope 刪除/index 提交完成才按 §5.1 的 owner/revision 規則移除。crash 留 intent 就 startup 清全帳號，接受多刪。intent 無法持久化仍嘗試 key/dir 清除；未證明不可讀前不送 mutation。pinned 的 V17 保留適用正常 scope 清理；故障升級 full-account clear 是帳號清除例外。同一 fence 批次重用已確認 durable intent，不逐項重寫；不能拿舊 scope intent 完成來解除新 account clear。

marker/key/directory **三重失敗**時，四個 DiskClearResult flags 都為 false；只能保證本 process closed/pending。不能宣稱 durable intent、crypto-shred 或跨 process 清除成功。強制終止後新 process 無從辨識未記錄的失敗，D1 保留帳號/currentUser 成功不是刪除證據；該 fault 必須記清除驗收失敗，儲存恢復後明確重試，不能以安全文案掩蓋此限制。

### §4.3 terminal 401 與非快取讀取（bound d1；candidate d2）

兩條路分別落包：d1 的 bound client 的 revoke(401, terminal401:true) 發 account clear；d2 的 SC initialize/select unbound candidate 遇 unauthenticated 或 userId mismatch 對**已知目標 account**清除。PAT/OAuth 新登入沒有已知 account 時不猜身分；仍綁定前關盤。相同 account 新 PAT 再登入也須等舊 clear 結束；未清完不能建立新 key。

可恢復 OAuth 401 與換證成功只清 memory、不碰 disk；換證失敗才終局清除。GA 的一般、raw/stream 401 路徑都要納入，而不是只測 cachedRecord。D3 的 record/records/currentUser、所有人工/AI preflight及readback維持網路、不加入disk；不代表它們讀到明確機密時可跳過安全刪除。bound REST `_object`／`_page` 回應也以同 raw walker 發 privacy deletion，不把 body落盤。

### §4.4 hydration、Gate 1/2、stale

hydration 在最終 sourceAllowed/stable/store **之前**執行原始 issue walker 及 privacy conflict 判定。採 Opus I-2 的較保守答案：任一 issue observation 較舊且與現 marker矛盾、或撞上較新的true，**整份 disk response 丟棄**，不存、不回、不排寫盤，觸發 V11 刪除，再走網路。保留較新network marker，對特定 public→confidential 證據呼叫 invalidateIssuePrivacy；之後重驗 stable、publication、sourceAllowed及issue epoch。這同時保留 Codex/GLM 確認的轉移語義，補上 project列表及別的 issue links 不共 scope 的漏洞。涵蓋等時間 network優先、較新disk false也不能自動解除未被新network證實撤回的true fence。

正式 source 的缺檔、錯帳號/key/AAD、篡改、格式錯、未知schema/超量為 miss；在可安全修改檔案時清理該項。key unavailable不是缺檔，不做檔案操作。意外 escaping exception由 CRA Future.any外層`safeFailure()`包成ApiFailure；原ApiFailure的kind/status/retryAt保留，cancelled保留。把cache_c2_prereq_test寬斷言改exact type/kind；不要將非ApiFailure例外稱為「傳輸錯」，也不自動對source例外重試網路。

mutable disk hydration **及 disk-lineage memory hit 一律 stale:true**，即使fetchedAt只有10秒；原始 fetchedAt不變，controller依V4立刻排fresh/background重抓。離線／限流保留舊值與既有strip。pinned 依V17不以age freshness過期、不因mutable write重驗；仍驗證帳號、permission/confirmed SHA或version、7天、容量及撤銷。這採Opus I-3的pinned例外，不讓重驗流量破壞pinned契約；若收到REST權限拒絕仍刪除。`allowDisk:false`略過原始disk及已hydrate的memory disk lineage，不可從共享pending漏入。

### §4.5 §4.7 的真正公開路徑（API d3；畫面 e）

d3 在 GA 提供兩個明確選用方法，名稱在交付時固定為 `cachedMergeRequestVersion(projectId,iid,versionId,{allowDisk=true,fresh=false})` 與 `cachedTerminalJobTrace(projectId,jobId,{allowDisk=true,fresh=false})`；它們回`CachedRead<...>`、共用§4 lease/Accept/no-store/撤銷與RequestMeter。generic record(s)/jobTraceChunk行為不變；e的diff version discovery仍用records，選定version的detail才用第一個API。

terminal log必須由同client新鮮網路job metadata證明：id/project匹配，status為success/failed/canceled/skipped之一、有效finished_at、非erased、attempt identity固定；running/pending/manual等絕不持久化。不能拿任意poll chunk當終局完整log。透過有界suffix Range取得尾端；只接受可驗Content-Range/total/end及EOF的206，或完整且在上限內的200。server忽略range且內容超量／長度不明／EOF不確定就停止並不持久化；typed API 用既有 `ApiFailure(FailureKind.unsupported)` 表示此讀法不適用，不偽造 TerminalLog。e 的 CI 頁只在此 kind 明確回原 `jobTraceChunk` 有界網路／polling 路徑；d3 無 UI 依賴。網路、401/403 或清除失敗不可改成 unsupported 掩蓋。不無界下載。必要的metadata／range請求都按實際HTTP次數計量；不宣稱未查證的server相容性。

依 a 的 §4.0 格式與整筆 byte cap 產生 TerminalLog；不能用 replacement 字元掩蓋 UTF-8 切斷。`startOffset/nextOffset/totalBytes/isEof/truncated` 還原最後一段的絕對座標；尾段不足完整 log 時 truncated=true。d3 的 source/API 測實際 offsets，畫面適配唯一歸 e 的 §6e。

磁碟無語系文字。e才加入`readCacheLogTruncated`並在顯示時用當前語系呈現；d3 測 flag/offset/尾段，e測文案與語系切換。e的CI畫面不得把tail當offset=0的完整trace，也不得與舊attempt的_rawBytes混接。

### §4.6 N-1：結果、結構 notice 與唯一呈現 owner

c 在 coordinator 保存每個 binding 的最新 pending `ReadCacheNotice`，另保留 signed-out 清除項供 login 呈現；不寫盤、不存文案、不把帳號 key 放進 state/log。backend 的 `reportCleanup(state)` 委派 c 建立 exact kind 的 notice。sink 例外要隔離，沒有 subscriber 也必須保留 snapshot；subscriber 拋錯不得改變原網路結果。e 只呈現對應 active generation 或已退出的 cleanup 項，不向新帳號顯示舊帳號內容；清除成功或明確 supersede 才消掉 notice。

| 路徑／產生 owner | 呼叫端確切結果 | state／kind 與 side effect | e 的呈現與 action |
|---|---|---|---|
| mutation begin barrier 失敗／5 秒 timeout；d1 | throw `ApiFailure.readCacheCleanup(state)`；HTTP send=0、meter delta=0；finally end 配對 | kind=readCacheCleanup；operation=mutation、disposition=requestBlockedBeforeSend、code=cleanupFailed 或 barrierTimedOut；disk fenced | 說明請求尚未送出；可先重試清除，再由使用者重試原操作。不能聲稱已寫入。 |
| mutation 已進 HTTP，任何原成功／原失敗後 end 清除失敗／timeout；d1 | 回**相同成功值**或重拋**原 ApiFailure＋stack**，保留 status/retryAt/writeUncertain | **另發** kind=readCacheCleanup notice；mutation/originalOutcomePreserved；disk fenced；無補送 | 原操作結果照原 UI；另顯示清除待重試，只能 retry cleanup，不能把 notice 的 retry 接回 mutation。 |
| fresh 網路 privacy read 合法但 barrier 失敗／timeout；d1 | 回本次合法網路 value；沒有 miss/不丟 cleanup 覆蓋它；不 persist | notice kind=readCacheCleanup；privacyRead/legalNetworkValueReturned；disk closed。舊 disk 被 Gate1 拒絕後仍不能回傳 | 顯示內容並另提示磁碟暫停，可 retry cleanup。 |
| marker/key/dir 三重失敗；c 結果，由 caller 轉譯 | send 前依首列擋送；send 後依第二列；privacy 依第三列；移除依下列 | `clearResult=(false,false,false,false)`；exact kind=readCacheCleanup；不能標清除完成／durable | 說明仍待清除，依 disposition 限制 action，不保證跨 process 已清。 |
| AAR 清除／SC commit fence，兩種刪除都未確認；c/d2 | c throw 新 kind；AAR catch 保留該 error，結果 notRemoved；SC.remove 維持既有不 throw 契約、還原 account | accountRemoval/accountRetained；SC 額外發 exact kind notice，既有 `removeSecureStorageFailed` fallback 保留，無新 l10n | `presentAiRemovalResult` 既有 showFailure 接集中 mapper；帳號仍在，可 retry removal。 |
| sign-out 背景 clear 失敗／timeout；d2 | session 已結束、generation/UI 立即前進；不 throw 使退出回滾；不改既有 auth marker bool 語意 | signOut/signedOutCleanupPending notice；捕獲退出前 account key，不能從已 close/null 的 api 取；pending 留 c | login 顯示清除待處理，可 retry cleanup，不能重開 session 或聲稱帳號已移除。 |
| startup/settings clear 失敗；c/d2 | startup 維持 closed；settings 回 DiskClearResult/typed failure，由 e 呈現 | operation=startup/settingsClear、disposition=diskClosed、kind=readCacheCleanup | 重試清除；toggle 寫失敗不得顯示已成功 off。 |
| send 前等待時 client close；d1 | exact kind=cancelled，零 send；同步 end 恰一次 | close 撤 lease；若已有清除失敗仍保留 c pending，不能變成已成功清理 | 沿既有取消行為。已存在 HTTP outcome 的路徑仍用第二列，不能因 cache waiting 再改寫結果。 |

kind 的程式碼 home 與新 fallback 全屬 a；notice store／清除事實全屬 c；d1/d2 只依上述 state 呼叫既有前包 API。**全部新增使用者鍵／文案及集中 renderer 都屬 e**，包括 request-blocked、outcome-preserved、privacy-returned、account-retained、signed-out-pending、disk-closed 及 log-truncated，不拆給 d。e 在 `FailureNotice`／`showFailure` 即時映射，不預先把翻譯字串塞入 ApiFailure 或磁碟。§6a/c/d1/d2/e 分別測契約、snapshot、每條 exact outcome、UI/action；不以寬的「任一 Exception」通過。

## §5 coordinator 與 startup 的唯一契約

### §5.1 c：key、inventory、queue、狀態

b的key store只提供found/absent/unavailable（malformed解碼視absent但保留診斷）、write/readback/delete、marker原語及readAll inventory；**不提供自動ensureKey**。精確名稱為 `read_cache_key.v1.<base64url(account.key)>`、`read_cache_clear_pending.v1.<base64url(account.key)>`（plan:296、609）；編碼沿用 `ai_journal_key_store.dart:12–15` 的 `base64Url.encode(utf8.encode(accountKey))`，保留 Dart 標準 padding，不另創編碼。key 值為32B隨機值的base64url，marker 是非秘密、版本化 JSON `{version:1,intentId,reason,requestedAt}`，requestedAt 為 UTC ISO 時間，intentId 為不帶帳號/內容的 opaque operation id；reason 為 scopeInvalidation/accountClear/keyRepair/startup。b 只驗 schema 及讀回完全相符，c 持有 intent 的生命週期。未知／毀損 marker 一律當 pending-full-clear；不因 reason 放寬 startup 清除。不得把 account key/URI/raw error 放進 metadata 或診斷。

inventory的獨立集合為read-cache keys、pending markers、malformed names/values及read status，只認以上兩個前綴，不把AI key/tombstone放入。無法讀完整inventory不可視為空。名稱可可信解出account而值格式錯時，key走absent-with-files交易，marker視同pending-clear；清完前保持closed。名稱無法可信解碼時，保持closed，保守清整個trusted read_cache root並刪inventory列出的該前綴壞名稱，均須驗證成功才繼續；只刪exact secure-storage名稱，不拿該字串組路徑。任一步失敗保留closed與可重試錯誤，不忽略後開盤；一般unavailable不觸檔的規則仍適用。

**共用 marker 的唯一 owner 是 c 的 per-account intent manager**。scope barrier 記錄自己持有的 intentId/revision；同批、相同有效 fence 可重用已 readback 的 intent。accountClear/keyRepair/startup 一旦要求 full clear，就同步升級記憶體 revision 並接管 intent，舊 scope finally 不可刪它。scope 成功只能在 c 的 serialized section 中，同時確認沒有 account-clear pending、revision/持有者未變且 secure marker exact value readback 相等，才 remove/readback；無法證明就留 marker＋closed，startup 過刪。升級、讀回、移除與新入列均用同一 owner，不允許讀回後在 lock 外刪除。測 scope 收尾與 sign-out/full-clear 交錯、同批多 invalidations 只寫一次、三種 reason 的記錄不含秘密。成本量測 F2 不可省略 send 前 barrier。

c獨占每account queue/single-flight，序列化首次建鍵、一般I/O、失效及清除；single-flight跨所有呼叫者／store wrapper，不只某個key-store instance。absent或malformed且有舊檔：同步fence → marker write/readback → drain/revoke舊I/O → key/delete-directory原語 → 確認舊目錄消失 → 建32B新key → write/readback比對。清除失敗不建新key。沒有檔案才可直接首次建鍵；仍須startup/activation/settings/lease全通過。b不依賴c，也不先做無標記刪除再等後包補救。

前景正常運作時，index由c每2秒或32筆提交；b只提供atomic primitives。queue上限每account 2MiB，以**實際serialized明文buffer含metadata**計量，超額FIFO丟最舊；單筆超界直接drop。31/32筆、2秒前後、恰等/超過2MiB、LRU與32/96MiB容量皆測。stats只聚合bytes/entries/dropped count，不含URI/key/path/name/content。既有core的前景16個、背景4個／排隊32個讀取限制仍由d守住（plan:647–649），不是用寫盤queue取代。

背景／失去account-generation所有權：停新write、drop未持久queue，不flush；resume重新驗generation、key、settings與fence。已在途作業在安全commit點重驗，已撤銷不得rename。一般key unavailable不讀、不寫、不刪，含mtime cleanup；1/5/30秒及resume重試。**明示清除**按m-11仍嘗試刪目錄，不把V14套成禁止刪除。fence優先於unavailable狀態，key恢復不能自行解除cleaning。

初態closed；ready必須所有gate通過。cleaning拒所有新讀/寫/建鍵並丟queue；失敗維持cleaning或closed+pending，不回ready；disabled表示已成功儲存off；unavailable保留拒用原因與cleanup latch。非啟動closed→ready只由有效_activate request開放，或m-10允許的同session設定clear完成；不是一般retry完成就開盤。

### §5.2 d2：startup decision、activation 與 lifecycle caller

SC 在讀完**帳號清單、sign-out marker、lastActive 並決定 resume 目標後**公布不可變 `ReadCacheStartupDecision`：operation ticket、account-list revision、success/readability、signOutPending、resumeAccountKey。早於 candidate currentUser 完成也可發布，但 accountsLoaded 本身不算。marker/lastActive 讀取錯誤不能當 absent；disk closed。sign-out pending 的保留集為空。

啟動順序固定：

1. settings/inventory 可讀，startup decision 完整；設定0→保留集空；確認 absent→預設1；unavailable→本 session 關盤、不刪。
2. c 處理**全部** pending-clear，包括帳號清單外 marker。
3. c 執行 D1：刪除 resume 目標以外所有 read_cache 目錄／keys；signed-out 或設定0 則全刪。帳號清單載入失敗不掃孤兒、不刪。
4. 掃描完成、清單 revision 仍相符才設 startupRecovered。SC `_activate` 在 generation++、bindReadCache 後，對**任何** client（含 ApiFactory fake）呼叫 d1 已提供的 attach 並提交 verified account/generation activation request。
5. ready 會合 startupRecovered、有效 activation request、settings enabled、controls installed、無 cleanup/unavailable。activation 先到只留 request；scan 先到等驗證。request 過時、成員改變或 generation 切換即作廢／重掃，不能開舊帳號。

SC 不 await 清除才 generation++／離開 UI。`_commitSignOut` 在 active/api 清空前捕獲 account key 並同步 fence，之後 background 清除；失敗以 §4.6 pending notice 回報，既有 auth sign-out marker 流程保持獨立。candidate terminal401 由 d2 在 initialize/select 對已知 account 清除；新 session 等舊 clear。cold offline/currentUser 失敗不顯示 disk，不實作 C3。

**m-1 的最小修正**：MAIN 保留 `initializeSessionWithAiRecovery` 在 initialize 後**立刻呼叫** history.startRecovery 及 startAiWriteJournal 的時點。d2 只為 history.startRecovery 加 optional async runner：先照原來安裝 `_watchLifecycle`／`_trackAccountLifecycle`、等待 accountsLoaded，再經 runner 包住 `_recoverAccounts` 的每輪 recovery；未注入時原行為完全相同。journal 的 configure/listener 也照原時點，實際 `journal.recoverAfterAccountsLoaded` 則經同一 runner。runner/gate 私有實作在 MAIN，參數只用既有 Dart 或 a 純型別，history 不 import MAIN/cache feature。會員變動重跑與失敗移除後重開的 observer 不延後、不略過；AI 安全規則不改。

MAIN 的共用 FIFO gate 串行三者的 destructive recovery：read-cache pending→D1 為一段、history orphan recovery 一段、journal orphan recovery 一段；每段各自 catch/finally，throw 不會跳過下一段，1/5/30 秒 retry 在 gate 外排程。等待 startup decision/網路及安裝 observers 不持有 gate。read-cache 段呼叫者最多等 5 秒；成功／錯誤且底層已停止時 finally 釋放，逾時撤 lease/closed、要求停止並等 quiescence ack 才交接；**不得**以 timeout 包住 Future 後立刻釋放造成兩個掃描重疊。

若 native I/O 永不返回、不能確認停止，安全側保留 gate，可能讓 AI destructive recovery 等待；observer 仍已安裝，AI write 仍拒絕。這個極端 liveness 問題不在文件中假裝已解：F1 明列獨立 follow-up，需可取消 worker／可證 quiescence 才能同時保證「無重疊」及「AI 永不被卡住」。本包驗收證明正常、throw、可 ack timeout 均繼續 journal/history，無 ack 案例則明確 closed/pending、不得宣稱進度保證。

MAIN 的 AppLifecycleListener 同步通知 c background/resume；c 執行 §5.1 retry/drop。MAIN 負責 listener/dispose，runner 不遺留 session listeners。controlled Futures 分別卡住 accounts/marker/lastActive/settings/inventory/currentUser/pending/D1/rename；測 activation 先/scan 先、成員變更、retry 及任一 gate 停住時**零業務讀盤／快取寫入／建鍵**。安全掃描/marker I/O 另記錄，不誤算開盤。

### §5.3 c：clearReadCacheDisk 與移除失敗

所有clear採V20 m-10：**同步fence → await marker write/readback → drain → delete key → delete directory → 確認 → 最後處理marker**；先fence不等待storage，因此不擋generation++。marker寫失敗仍刪key/dir，記憶體pending+closed，不宣稱有durable marker。key刪失敗仍刪dir；marker讀/值錯/移除失敗、dir刪失敗皆有獨立fault injection。

`DiskClearResult`明列`keyGoneConfirmed`、`directoryGoneConfirmed`、`markerDurable`、`complete`，不是一個吞錯bool。刪除ack不足時需讀回；unavailable不是確認消失。一般clear只有key與dir**都**確認刪除、marker確認移除才可complete/reopen；remove理由的marker允許保留到startup掃描（plan:713），且account離開後不再開盤。

**採納Opus I-11的移除門檻**：`clearReadCacheDisk`僅在keyGoneConfirmed **或** directoryGoneConfirmed時可讓AAR繼續；這代表殘留已不能由該cache組合解密。若兩者皆未確認，throw，AAR既有catch→notRemoved、帳號保留且可從帳號頁重試。只有key刪失敗但dir已確認刪除可移除；保留marker/fence，startup清殘key。反向key已刪但dir殘留亦同。這與Codex「兩者都清完才移除marker/恢復ready」是不同門檻，後者完整保留，不讓移除成功暗示ready。

AAR順序為drafts → artifacts → recent → **read cache** → 既有journal mark／AI cleanup → session.remove。d2 的 SC.remove 在 commit fence 內再用同一 clear 門檻；維持 remove 不 throw 的契約，失敗保留帳號、沿用既有 removeSecureStorageFailed，並送 §4.6 結構 notice。AAR 清除 hook 的 typed error 由其既有 catch 保存在 notRemoved.error，不能吞成成功。多次clear冪等，account保存失敗後亦保持cache fence，不能因帳號仍存在就自動重建。AI history/journal keys/dirs/tombstones前後快照相同；read-cache清除絕不觸碰。

**no-op 只限可證空**：可讀完整 inventory 確認該帳號無 key/marker、trusted root 下無目錄/temp、無 queued/in-flight/晚完成作業，且目前沒有 writer 可新增，才 complete-empty 而不寫 marker。不能單憑 controlsInstalled=false、未 configure 或「本 process 從未寫過」推論磁碟空；以前版本仍可能留下資料。configure 失敗／inventory unreadable／unknown 必須回 unavailable/cleanup failure 並留 fence，不能默默移除帳號。前置 c 的未安裝 production hook 使用明確 disabled-by-construction adapter（該 MR 尚無任何 reader/writer/既存 C2 資料來源），不是日後 singleton 的泛用 no-op；d2 接線後一律用可證空條件。純 session 舊測試注入**可證空** fake，所有新增清除測試用 memory secure store/temp root，禁止碰真實 keychain。

## §6 每包交付、安全與有界驗收

**共通合併條件**：前包已合併；本包 fresh `fvm flutter analyze --no-pub`、新增測試及下列受影響既有 suites 全數通過。PROMPT 已核對，明文要求驗收命令永不 full suite；以下只給本地有界集合。另依 Opus m-8，**未來每個 MR 合併須讀回該 MR 實際 HEAD 的既有完整 `ci/check.sh` pipeline 成功結果**，記 source SHA／pipeline／必要 jobs，不以較舊 HEAD 或本地子集取代。此為既有 CI 合併 gate，本文不提供啟動全套命令，本次不連網、不啟動 CI。review/模擬器等父計畫既有 merge gate 仍適用；本次全為 NOT_RUN。

所有實作測試使用 synthetic account、memory secure storage、temporary root、fake clock/controlled Future，沒有 live API 或秘密。集合只展開**該合併階段已存在**的檔；zsh `NOMATCH` 保持開啟，glob 零匹配是集合錯誤，**fail hard**，不得用 NULL_GLOB/空集合繞過，也不把缺檔改成略過。下列 helper 只防無參數或不存在的測試呼叫，不是新增產品檔案：

```sh
# repo 根目錄；同一 zsh session 定義後，各包只跑自己下列命令。
setopt NOMATCH
run_suites() {
  (( $# > 0 )) || return 2
  local suite_path
  for suite_path in "$@"; do
    [[ -f "$suite_path" && "$suite_path" == test/*_test.dart ]] || return 2
  done
  fvm flutter test --no-pub "$@"
}
CACHE=(test/cache_*_test.dart test/read_cache_test.dart test/gitlab_api_test.dart test/workspace_api_contract_test.dart test/mutation_acknowledgement_test.dart)
SESSION=(test/session_test.dart test/account_switch_resume_test.dart test/account_switch_resume_adversarial_test.dart test/ai_startup_fix1_test.dart test/ai_session_integration_test.dart test/app_smoke_test.dart test/login_widget_test.dart test/authenticated_app_test.dart test/account_store_test.dart)
REMOVAL=(test/ai_account_removal_test.dart test/ai_authenticated_removal_fix1_test.dart test/ai_account_queue_lifecycle_fix1_test.dart test/markdown_media_session_removal_test.dart test/ai_stores*_test.dart test/ai/packet9_*_test.dart test/ai/packet11_*_test.dart test/ai/ai_write_journal_test.dart)
READ_UI=(test/record_controller*_test.dart test/records_feed_performance_test.dart test/cache_freshness_bar_test.dart test/project_overview_test.dart test/repository_controller_test.dart test/repository_file_page_test.dart test/repository_readme_test.dart)
LIST_UI=(test/v05_ui_test.dart test/inbox*_test.dart test/boards_page_test.dart test/board_mutations_test.dart test/emulator_group_list_fixture_test.dart test/group_graph_work_items_page_test.dart test/group_link_navigation_test.dart test/work_item_attributes_test.dart test/work_item_content_ui_test.dart)
PINNED_UI=(test/diff_page_test.dart test/diff_page_performance_test.dart test/diff_discussions_test.dart test/diff_draft_review_test.dart test/job_trace_test.dart test/job_sections_test.dart test/job_log_search_test.dart test/ci_overview_test.dart test/ci_action_cards_test.dart test/pipeline_generation_test.dart test/pipeline_list_actor_test.dart test/pipeline_graph_page_test.dart)
AI_READ=(test/ai/ai_tools_test.dart test/ai/ai_chat_context_test.dart test/ai/ai_context_builders_test.dart test/ai/mr6b2_read_tools_test.dart test/ai/mr6b2_budget_test.dart test/ai/mr6b2_matrix_test.dart)
WRITE_API=(test/work_item_*_api_test.dart test/mr_*_test.dart test/editor_*_test.dart test/incident_api_test.dart test/todo_snooze_test.dart test/ai/*reread*_test.dart test/ai/*port*_test.dart test/ai/ai_write_wrappers_test.dart test/ai/ai_write_previews_test.dart test/ai/packet7_controller_test.dart)
AI_RECOVERY=(test/ai_history*_test.dart test/ai/ai_write_journal_test.dart test/ai/packet11_*_test.dart)
```

**d1 開工前硬 gate（不擋 a/b/c）**：C1b-1b、完整 C1b-2（含2b/2c）的實際 source 已合併；V5 每條實際 AI port/context 讀取有 allowDisk:false、拒 disk-lineage memory、不 join disk pending。本 snapshot 完整 V5 與其專用 suite 確切檔名 **not found**。d1 owner 必須從已合併 C1b-2c MR manifest 把**實際路徑**鎖成 `V5_TESTS` 非空陣列並記 MR/SHA；缺 source、缺 manifest、任一缺檔或未執行即 gate FAIL，不能猜檔名、用 placeholder suite 或僅靠手傳 allowDisk:false 補過。d3/e 同一 gate/集合重跑，rebase 有變就重鎖。

```sh
# 只有已從上游已合併 manifest 鎖定 V5_TESTS 才可通過；此處沒有虛構檔名。
require_v5() {
  (( ${#V5_TESTS[@]} > 0 )) || return 2
  local suite_path
  for suite_path in "${V5_TESTS[@]}"; do
    [[ -f "$suite_path" && "$suite_path" == test/*_test.dart ]] || return 2
  done
}
# 後文使用 `require_v5 && run_suites ... "${V5_TESTS[@]}"`，缺集合不執行。
```

### §6a P-C2a：封閉投影、結構 failure 與跨包契約

目標：§3、§4.0/4.6 的 schema/DTO/kind 可獨立建置；無 I/O、無後包字串。owner／cap＝§2 的 a（N≤5/E≤1）；規則 plan:247–266、272、593–602、651、718–725。

新增測試：E01–E19 exact key set/子欄位；每個 classify 路徑族有允許或拒絕 fixture；token/import_url/敏感 URL 剔除；未知欄位、guard 缺/錯、notes internal/confidential 優先、跨專案 nested issue、整份拒絕不濾列；深度/陣列/節點上限與+1；fresh parent 的 network/stale/disk/identity；deleting project 拒存；Accept、durable key 去 generation。解密後驗收留 d1/d3，不拿純投影頂替。

**N-2/m-4 必測真形狀**：依 My Work/Inbox/group/board 的實際 URI/query，E02 issue list、E09 MR list 各以 `with_labels_details=true`＋非空 `{id,name,color,text_color,description,extra}` labels 呼叫 projector，均非 null；description/extra 消失，四欄正確。另測字串 labels、空列、混型/null/錯型別/兩種不合法 color 整份 null。E02/E09/E10 fixtures 保留 references 三字串、MR merge_user:Actor? 及 `merge_when_pipeline_succeeds`/`auto_merge_enabled` bool；`work_item_page.dart:2281–2285` 及 `core/merge_request_state.dart:1–4` 的顯示依賴不掉。這些 bool 只供顯示，不能用 disk 狀態授權寫入。另加未指派 issue 的 assignee/milestone/closed_at/due_date:null、未合併 E09/E10 MR 的 merge_user/assignee/milestone/merged_at/closed_at:null，明確斷言投影非null且保留這些null；與非null Actor fixture並列，不能只測已排程合併的MR。自己的測試內 fixture，不改 shared fixture。

failure test 逐項驗新 kind 的 typed constructor/state/four flags、fallback 正好使用既有兩鍵；無 raw error/PII 進 toString，safeFailure 保留原 ApiFailure identity/status/retryAt；所有舊 kind 行為不變。安全：輸出只為 projected DTO/null；失敗不暴露 raw body；contract 不 import 私有 _ReadClass/failure 或後包，不新增使用者字串。

```sh
fvm flutter analyze --no-pub
run_suites test/read_cache_disk_contract_test.dart test/read_cache_projection_test.dart test/read_cache_failure_test.dart test/gitlab_api_test.dart test/identity_test.dart test/failure_notice_test.dart "${LIST_UI[@]}"
```

### §6b P-C2b：key/inventory 原語、cipher 與檔案交易

目標：crypto/有界檔案/key/marker 原語可單獨驗收，不做 auto-ensureKey、single-flight、完整 absent 交易或政策。owner/cap＝b（N≤6/E=0）；規則 plan:268–303、632–635、642–652。使用既有 crypto/cryptography/flutter_secure_storage/path_provider，不增依賴；plugin options 同 AIS:1039–1044，由 feature adapter 自建，不 import AI 私有常數。

格式：`getApplicationSupportDirectory()/read_cache/<sha256(account.key) 前32個小寫hex>/`；項目 `e_<HMAC-SHA256(命名子金鑰,canonicalKey) 前32個小寫hex>.v1.bin`，HKDF-SHA256 info 固定 `read-cache-names`；`index.v1.bin` 同加密。32B key、fresh12B nonce、AES-256-GCM16B tag、version1B，envelope 最小 **29 bytes**；AAD 逐 byte＝`utf8.encode(jsonEncode(["read_cache",version,accountKey,fileName]))`。只重用算法/primitive，不用 AiHistoryCipher 的三元素 AAD/schema/exception。

plaintext 按 §4.0 整筆計量，ciphertext 上限＝該類 plaintext cap＋29。index 明文≤256KiB、≤2048 entries，任一先到由 c 按 LRU 淘汰，b 測2048/2049及256KiB邊界。帳號32MiB/裝置96MiB計 ciphertext+index+temp；讀前 stat、bounded decrypt/decode。entry-before-index、eviction-file-before-index；tmp exclusive create/flush/rename 同 background isolate。trusted root 至 account 每層拒 link/錯型別；刪遇 link 只 unlink 本身。age==7天或age<0過期，tmp age>1h才刪；mtime不代 authenticated expiry。

fault tests：wrong account/key/file/domain、AI history 改名互換、exact canonicalKey mismatch、fresh nonce、tamper/truncate/unknown version/schema/超量、symlink 讀寫刪掃；key absent/found/unavailable、malformed/inventory/readAll failure、write/readback mismatch/delete failure；marker JSON/reason/精確 readback、未知值判 pending。temp/rename/index/eviction各切點中斷，用全新 store 恢復無 phantom/路徑逃逸；固定 clock 測7天±1微秒/未來/1h。

安全：普通 unavailable 零檔案 I/O（含清理/mtime）；explicit-clear 原語例外由 c 呼叫。b 不自行掃孤兒/建鍵；key/明文/raw error 不進 stats/log。所有值 synthetic。

```sh
fvm flutter analyze --no-pub
run_suites test/read_cache_cipher_test.dart test/read_cache_files_test.dart test/read_cache_key_store_test.dart test/read_cache_disk_contract_test.dart test/read_cache_projection_test.dart test/read_cache_failure_test.dart test/ai_history_codec_fix1_test.dart test/ai_history_files_test.dart test/ai/packet11_journal_key_store_test.dart
```

### §6c P-C2c：coordinator、notice、清除與 account-removal step

目標：§5.1/5.3 全狀態機可由 fake binding 驗收；尚無 production writer。owner/cap＝c（N≤4/E≤2）；規則 plan:294–326、336、608–635、649、704–716。僅依 a/b。AAR optional hook 按 §5.3 加在 recent 後；disabled-by-construction 只限此中間 MR，configure 失敗不是 no-op。

fault tests：marker write/read/mismatch/remove 失敗；key delete、dir delete、兩者及三者同失敗；marker 失敗仍刪，四 flags 不虛構 durable。absent/malformed-with-files 完整交易；同帳號多 caller/store wrapper 首次建鍵只有一把；clear/readback/rename 競態不得重建；普通 unavailable 零檔案動作，explicit clear 仍刪 dir。完整 inventory/目錄/work queue 可證空才 complete-empty 且 marker writes=0；未知、不完整、configure failure 不可 no-op。

測 intent manager 同批重用、scope-finally 不刪 account-clear revision、malformed marker/root recovery、不重用失效 owner；queue31/32/2秒、2MiB FIFO/drop、32/96MiB及 LRU/index限額；background drop/resume；scope/issue epoch 撤 pending/in-flight/rename未index。timeout 呼叫者返回後 gate仍持到 quiescence，晚完成不得 reopen/rename；清除/marker/crash各階段新 store 不長回舊 key/file。

D1 fake decision 測保留集外全刪、signOutPending/設定0全刪、清單外 marker、unreadable不掃；AI history/journal key/dir/tombstone 前後 bytes 相同。AAR 排序、雙失敗留 account/notRemoved.error exact readCacheCleanup；任一 key/dir 確認消失允許移除但 complete/reopen 不成立；save失敗仍 fenced。notice 無 subscriber 保留 snapshot、故障 subscriber 不外拋；state 無秘密/翻譯字串、retries不擅自重開。

安全：只有 c 管 intent/queue/retry；清除只認 read-cache prefix/trusted root；AI stores 不改。移除成功與 cache ready 門檻分開，不能吞 cleanup failure。

```sh
fvm flutter analyze --no-pub
run_suites test/read_cache_*_test.dart "${REMOVAL[@]}" "${SESSION[@]}"
```

### §6d1 P-C2d1：backend、普通 publication／刪除、hydration 與 failure

目標：只交 §4.1–4.4、§4.6 的 bound transport/core 接線；不改 SC/MAIN，不提供 E18/E19 typed API，不碰 UI。owner/cap＝d1（N≤3/E≤7）；規則 plan:34–39、463–515、593–635、641–651、661–675、692–725。§6 的 C1b/V5 硬 gate 先過；a/b/c 已合併。

先 fake backend 證每種 accepted publication/delete 事件，再實際 b/c temporary files 跑公開 API：網路→投影→加密檔→新 client/new generation hydrate。E01–E17 所有允許 JSON 類及 file/tree 各有真實 write-path fixture；解密逐欄驗投影、identity index、Accept/no-store/超界。memory/hydrate 不回寫/fetchedAt不變；無權 publication不能排寫或刪新值，queue/rename/index各await點 lease 撤銷。

**N-2 寫盤證明不是 projector 單測**：E02/E09 各用帶 `with_labels_details=true` 的實際 list request＋非空物件 labels 網路 response，等 commit，確認預期 encrypted entry 存在，解密只含四欄及 references/merge_user/bools；全新同帳號 verified client（測試注入 controls gate）從真 disk hydrate，零網路即可還原值、mutable stale=true。兩端再測 string labels、未合併MR merge_user:null及未指派issue nullable metadata，從disk還原仍保留null；color/混型 invalid 整份不落盤且刪 exact舊 key。不能只手塞 ReadCacheSource 當網路寫盤。

N-1 逐列 exact 驗收：begin failure/5秒 timeout **readCacheCleanup/requestBlockedBeforeSend**、zero HTTP/zero meter；close **cancelled**；讀者在 barrier wait 看見 active，end count恰一次。success/原ApiFailure/status/retryAt/writeUncertain＋end failure/timeout 均保原值/identity/stack，另 notice exact kind/state；listener拋錯也相同，沒有 retry原mutation。合法 privacy網路值＋failed barrier 照回、disk fenced/no write；三重失敗全false，無durable宣稱。不同 barrier late completion 不補 send/rename/reopen/刪新marker。§4.6 路徑均測 cleanupFailed/barrierTimedOut，不用寬 Exception 斷言。

其他具名整合：Gate1 project-list/links/userLists 舊disk observation 整份拒絕，pending→privacy、rename後index前privacy、跨group/project索引刪除、首次true、issue403/404 m-9、index毀損full-account清；V12 begin/end完成立即重啟不讀舊值；成功/failed/unknown mutation及無關project保留。Accept JSON/text同URI各跨client不互命中；full-path detail經網路alias，改名不冒認，其他子路徑直接網路。Gate2 意外 source error exact ApiFailure.invalidResponse、原 ApiFailure/cancelled不改；預期錯檔為miss。mutable disk-lineage一律stale、fresh背景讀／allowDisk:false不joindisk；GraphQL403404不刪disk，GraphQL mutation只撤mutable、已確認SHA保留；bound一般/raw/stream終局401真刪，recoverable OAuth成功不刪key/file。candidate401留d2。

另以 adapter 逐呼叫證六處 updated_at/currentUser/人工與AI write port/ai_write_reread/_freshWrite/readback 都網路、不disk、不join，既有 suites 配合 §7。**中間 main**：controlsInstalled=false，production lookup miss、writer不排隊/不建鍵，安全清除恢復仍可跑。測試只用前包既有注入 gate 打開；不讀未來 SC accessor、d3方法或e文案。

安全：唯一 publication/authoritative index 不雙寫；no-store/失去資格刪舊值、raw body只在有界投影前短暫使用不入DTO/log。terminal bound401從傳輸接線，非快取D3 privacy亦刪但不存。

```sh
fvm flutter analyze --no-pub
require_v5 && run_suites test/read_cache_*_test.dart "${CACHE[@]}" "${SESSION[@]}" "${READ_UI[@]}" "${LIST_UI[@]}" "${AI_READ[@]}" "${WRITE_API[@]}" "${V5_TESTS[@]}"
python3 -m unittest discover -s tool/tests -p 'test_ai_boundaries.py' -v
```

### §6d2 P-C2d2：startup／session fence、candidate401 與 recovery 排序

目標：§5.2＋session清除caller，不重寫 d1 接縫；controlsInstalled=false。owner/cap＝d2（N≤2/E≤8）；規則 plan:305–326、608–630、650–654、677–685、704–716；前置 d1 已驗收合併，source V5仍須存在。

新增 startup/recovery-order controlled Futures：accounts/marker/lastActive/settings/inventory/currentUser 各卡住不能開盤；activation先/scan先、A→B/A→B→A/同account新session，network/disk/isolate/rename/index晚完成不能發布。startup decision unreadable不是absent，currentUser 必網路；新 PAT已知帳號、candidate userId mismatch/terminal401真清，未識別帳號不猜key；ApiFactory fake走同attach。D1全部pending→保留集、設定0/signed-out全刪、清單外marker、成員變更重掃，普通unavailable不掃。

sign-out開始立即fence/generation/UI先前進，捕獲原 account 後清；故障exact readCacheCleanup/signOut/signedOutCleanupPending，session仍退出且auth marker bool語意不變；不拿close api做清除。SC.remove commit fence二次clear，雙失敗恢復帳號並notice exact accountRetained，任一確認消失可移除；AAR順序不回退，unknown/configure失敗不能no-op。重登等同帳號舊clear；明確空狀態不寫marker。timeout/三重failure沿§4.6，拒跨process成功宣稱。

**m-1 回歸**：history lifecycle/成員 observer及journal起動/listener均在原時點，read-cache尚卡住也已安裝；移除失敗恢復會員仍觸發原AI重開機制。read-cache/history/journal destructive段任兩者不重疊；三者的throw不跳下一段，retry不占gate；可ack timeout後AI兩段會執行，無ack timeout只證closed/pending（F1）。AppLifecycleListener background drop/resume與dispose/listener釋放；AI byte/key/tombstone隔離不變。

安全：不用accountsLoaded充當startup完成，所有新session attach在generation/bind之後；hist recovery僅注入runner，不改AI內容/隔離規則。

```sh
fvm flutter analyze --no-pub
run_suites test/read_cache_*_test.dart "${CACHE[@]}" "${SESSION[@]}" "${REMOVAL[@]}" "${AI_RECOVERY[@]}"
```

### §6d3 P-C2d3：typed pinned API 與實際 AI 邊界

目標：§4.5 的 E18/E19，重用 d1 publication/helper，不修改 transport/SC/MAIN；controlsInstalled=false。owner/cap＝d3（N≤2/E≤1）；規則 plan:338–350、517–521、584–591、645、654、661–675；前置 d2 合併、V5實際集合已鎖定。GA 的 pinned 區段接手前包已存在的型別，無前向依賴。

pinned tests 用實際 typed公開API 網路→加密檔→全新verified client hydrate，解密MRVersion/TerminalLog逐欄；MR版本id/diffSHA；同client fresh terminal job proof、project/id/attempt/finishedAt/erased，running等拒盤。整筆2MiB含metadata/UTF-8界、offset/truncated、suffix Range/Content-Range/EOF、忽略Range超量/錯範圍不存，exact unsupported交e選既有有界路徑，其他ApiFailure不吞。每次metadata/range HTTP都計RequestMeter；新client先以真網路取得currentUser及必要的terminal/confirmedSHA資格，這些請求照計，再斷言資格仍fresh時的純disk lookup增量=0，不能聲稱整次冷啟動零HTTP。permission/account/LRU/7天仍有效。普通／global mutation不撤pinned、不等待active scope，REST403404及accountclear仍刪。

`read_cache_ai_boundary_test.dart` 呼叫**實際** GitLabReadPort/AiChatContextBuilder已合併公開讀取（以V5 source為準），只在disk的pinned及已hydrate memory disk lineage都必發網路，不能共享pending繞過；AIwrite preflight/readback亦維持網路。重跑d1的E01–E17解密整合＋d3 E18/E19，M411於此包才全覆蓋。純手傳allowDisk:false不算實際AI證據。

安全：log不持久化語系文案、不把poll chunk當完整terminal log；不依賴e generated accessor。Range相容性實測NOT_RUN、不以server猜測放寬schema/上限。

```sh
fvm flutter analyze --no-pub
require_v5 && run_suites test/read_cache_*_test.dart "${CACHE[@]}" "${READ_UI[@]}" "${PINNED_UI[@]}" "${AI_READ[@]}" "${V5_TESTS[@]}"
python3 -m unittest discover -s tool/tests -p 'test_ai_boundaries.py' -v
```

### §6e P-C2e：Claude UI、集中 failure、pinned採用、文件及正式啟用

目標：最後交付§4.8/4.9及真正diff/log畫面；不回改core/SC/MAIN。owner/cap＝e（N≤3，E依§2）；規則 plan:16、328–365、650–654、661–675、709–713。設定入口在 `authenticated_app.dart` 的 `_MobileShellState` build 約1070–1170，settings page顯示device toggle/聚合bytes/clear。c已擁有store，精確key `gitlab_mobile_read_cache_v1` 只收字串1/0（plan:354–356）。重用CacheFreshnessBar/RecordController/現有strips。

關閉：同步fence→嘗試儲存0/readback→clear marker/key/dir；儲存失敗仍清且closed，不假稱off持久化。啟動0保留集空，absent預設on，unavailable關盤不刪。off→on只重建不復活舊檔，必須verified activation仍有效、無pending、settingsreadback成功；否則等_activate。同session設定clear完成才按m-10可重開，失敗不重開。

N-1新增鍵由e獨占，所有locale/placeholder一致；`workspace_ui.dart` 的 FailureNotice/showFailure集中以kind/state及當前l10n映射，AAR既有presentAiRemovalResult已呼叫showFailure，不需新AI字串。shell及login訂閱c snapshot，無subscriber時發生的sign-out故障仍能顯示；重複notice合併，舊generation不向新帳號串出。pre-send可明示安全重試；originalOutcomePreserved/合法privacy value維持原內容/原錯，notice只能retry cleanup；signed-out不重開session，removal失敗仍account-retained。不得把readCacheCleanup一律接既有onRetry而重送已開始的mutation。語系切換重新render，不存翻譯。

先完成設定/登入頁notice/集中renderer、白名單殘留文件、typed UI採用與log truncated當前語系提示，再由已安裝設定入口的authenticated shell呼叫c既有 `installUserControls()`；仍需startup/activation其他gates。e之前不保存repository資料；可證空no-op讓中間版本不為空帳號造marker，不保證未知舊殘留為空。gate不是身份證據。

文件四檔寫全 persistence allowlist、公開內文可能引用機密的殘留、key/inventory/marker reason及scope失效的Keychain開銷、D1/remove順序、no-store/Accept、7天/caps/iOS ThisDeviceOnly/startup清理。iOS預設CompleteUntilFirstUserAuthentication、app lock僅遮畫面仍可解密，isExcludedFromBackup後續；iOS實機NOT_RUN，Play資料安全表依plan:360不變。

新增/既有widget測toggle/clear各failure、bytes聚合；§4.6每個kind/disposition文案與action，fallback及language切換；10秒disk列表原fetchedAt/stale＋背景網路、離線保留/恢復刷新；diffversion真disk還原，terminal尾段正確offset/attempt不拼舊_rawBytes、僅unsupported才回原jobTraceChunk、running仍poll、hidden/dispose不發布。UI採用不能由API單測替代。

```sh
python3 tool/l10n.py
python3 -m unittest discover -s tool/tests -p 'test_l10n.py' -v
python3 -m unittest discover -s tool/tests -p 'test_bootstrap.py' -v
fvm flutter analyze --no-pub
require_v5 && run_suites test/read_cache_*_test.dart "${CACHE[@]}" "${SESSION[@]}" "${REMOVAL[@]}" "${READ_UI[@]}" "${LIST_UI[@]}" "${PINNED_UI[@]}" "${AI_READ[@]}" "${V5_TESTS[@]}" test/failure_notice_test.dart test/authenticated_app_shell_adaptive_test.dart test/app_lock_test.dart test/language_test.dart
```

**Android實際驗收owner=e**：按repo既有bootstrap/signing規則，用project-owned emulator/公用專案或syntheticfixture、拒絕所有AI寫入；debug且package debuggable的build用 `adb -s <project-emulator> shell run-as <verified-package> ...` 讀回Application Support/read_cache實際目錄。記source SHA/APKhash/package、預置後存在、clear/sign-out/switch/remove/terminal401後清除及resume不長回；key診斷只輸出found/absent/unavailable，不輸出key/token/完整帳號id。release不能run-as就另做debug驗收，不能把失敗命令算pass。**本次裝置NOT_RUN**；Android未跑不得宣稱C2整體接受，iOS照計畫NOT_RUN。

## §7 父計畫 §7 最低驗收矩陣：每列唯一主責

下表將plan:396–443每個可見驗收子項全部指派；V16:654/V5的AI磁碟禁讀另加一列。上游引用的外部「原始12列報告」本資料夾 **not found**，不捏造缺失原文。主責負責確保對應既有suite及新增案例被跑；基礎原語可依賴前包，但不以多人共同負責取代唯一owner。

| Matrix ID／plan 行 | 最低驗收項目 | 唯一主責 | 必跑證據／suite |
|---|---|---|---|
| M396／396 | A→B、A→B→A、同account新session；network/disk/isolate/rename晚完成不發布/落盤 | d2 | startup/integration＋CACHE/SESSION |
| M397／397 | 讀在寫入前中後；success/failed/unknown；無關project保留 | d1 | integration＋cache_races/contract＋mutation_acknowledgement |
| M400／400 | 六處updated_at前置讀取必網路、不join、不disk | d1 | d1 integration逐呼叫adapter＋WRITE_API/AI_READ/V5_TESTS |
| M401／401 | currentUser必網路 | d2 | startup＋session/cache binding |
| M402／402 | AI write port必網路 | d1 | integration＋WRITE_API/AI_READ/V5_TESTS |
| M403／403 | ai_write_reread必網路 | d1 | integration＋WRITE_API/AI_READ/V5_TESTS |
| M404／404 | _freshWrite必網路 | d1 | integration＋WRITE_API/AI_READ/packet7_controller |
| M405／405–406 | 其他人工preflight/readback必網路、不join、不disk | d1 | integration＋mutation_acknowledgement/WRITE_API |
| M408／408 | 未讀父issue先讀notes不得落盤 | a | projection；d1另驗實際key集合 |
| M409／409 | nested discussion notes逐則守衛 | a | projection；d1另驗解密結果 |
| M410／410 | public→confidential、跨範圍刪除 | d1 | integration＋cache_privacy/c2_prereq |
| M411／411 | 真實落盤後逐筆解密檢查欄位 | d3 | d1 E01–E17 integration＋d3 E18/E19 pinned；全套逐筆解密 |
| M413／413 | 401/403/404撤舊值與子樹，m-9/pinned/candidate | d2 | d1 bound/403404整合＋d2 candidate/startup；cache_oauth/privacy/c2_prereq |
| M414／414 | OAuth換證成功disk仍在 | d1 | cache_oauth＋實檔/key快照 |
| M416／416 | 錯key/account/file/AAD domain | b | cipher/files |
| M417／417 | ciphertext tamper/truncated | b | cipher/files |
| M418／418 | envelope version/schema不符 | b | cipher/files |
| M419／419 | 檔案過大、讀前拒絕 | b | files＋pinned API的尾段補充 |
| M420／420 | 三種key狀態、並行首次寫只一把 | c | coordinator；原語沿用b |
| M422／422 | temp/entry rename/index/eviction/clear逐階crash | c | coordinator整合b fault points後重建 |
| M423／423 | 啟動掃描恢復／D1／清單外marker | d2 | startup＋coordinator |
| M424／424 | clear後不長回file/key | c | coordinator所有在途/queued切點 |
| M425／425 | AI journal完好 | c | coordinator前後bytes/key快照＋REMOVAL |
| M427／427 | rate標頭大小寫 | d1 | cache_rate_observation/cache_prereq_rate |
| M428／428 | 缺少/格式錯rate標頭 | d1 | cache_rate_observation/cache_prereq_rate |
| M429／429 | 多bucket | d1 | cache_rate_budget/cache_rate_observation |
| M430／430 | 亂序回應 | d1 | cache_rate_observation/cache_prereq_rate |
| M431／431 | reset到期恢復 | d1 | cache_rate_budget/cache_rate_observation |
| M432／432 | small limit及formula caps | d1 | cache_prereq_rate/cache_rate_budget |
| M433／433 | clock skew | d1 | cache_rate_observation/cache_prereq_rate |
| M434／434 | Retry-After/Reset/ResetTime全缺 | d1 | cache_rate_observation/cache_prereq_rate |
| M435／435 | 連續429 | d1 | cache_rate_observation/cache_prereq_rate |
| M436／436 | Retry-After86400只封create | d1 | cache_rate_budget/cache_prereq_rate |
| M437／437 | CDN429不影響API | d1 | cache_rate_observation/cache_http_meter |
| M438／438 | 三個AI run預算分配 | d1 | cache_rate_budget＋AI_READ/mr6b2_budget |
| M439／439 | hit/coalescing/SWR/HEAD+GET/pages/OAuth replay/失敗取消/UI與多AI計量 | d3 | d1 CACHE/AI_READ既有證據＋d3 typed pinned實際adapter計數 |
| M440A／440 | 29/30/59/60秒及memory retention邊界 | d1 | cache_contract/cache_metadata/cache_fresh_retry＋READ_UI |
| M440B／440 | 7天±邊界/未來時間/tmp期限 | b | files固定clock |
| M442／442 | Android debug run-as實際清目錄／重開不長回 | e | §6e emulator/APK/source證據 |
| M443／443 | iOS NOT_RUN明列，不當成pass | e | AGENTS/CLAUDE/PLAN_STATUS/驗收報告 |
| M654／654、517–521、692 | 實際AI port/context禁disk含disk-lineage memory | d3 | read_cache_ai_boundary＋已合併C1b-2c V5 suite |

矩陣只記最終彙整主責，不改 source ownership：M396/M413 的 d2 重跑 d1 整合後補 session/candidate；M411/M439 的 d3 重跑 d1 全部普通 disk／計量測試再補 pinned。a 的 M408/M409 純契約之外，d1 仍須真實寫盤解密；b 的 byte cap之外，d3另證 log尾段。沒有要求前包執行尚不存在的後包suite。§6的WRITE_API及V5_TESTS是M400–405的明確集合；rate邏輯不屬C2重寫，d1既有CACHE回歸必跑。

## §8 #14 落點、審查歧見與已採用答案

### §8.1 #14逐項

| issue14 行 | 決定／owner |
|---|---|
| 23–28 的before-C2前置 | 以當前source核對，不重做已存在的remove/reinsert、獨立privacy source table、source/time比較、caller-form註解、publication cleanup；alias項依64撤回。d1驗收守住。 |
| 64 alias hydration ticket效能項 | 延後另issue/安全審查；d1保持path identity/publication防線，不恢復曾回錯project的reuse。 |
| 65 Gate1 | d1，§4.4；採Opus整份丟棄＋V11，再保留轉移/重驗，較Codex/GLM單獨stable更保守。 |
| 66 Gate2 | d1，§4.4；source預期壞檔miss，seam後備safeFailure，既有測試exact types。 |
| 67 privacy共用sequence table | 延後memory-only保守取消；不擴成帳號級disk revoke。 |
| 68 GraphQL403/404 | d1測不刪REST/pinned disk；mutation的global mutable invalidation仍保留。 |
| 71、76 Accept／representation | a定義durable key、b檔名/index、d1公開API跨client隔離；不支援任意interceptor事後改Accept的既知限制原樣列出。 |
| 54–57 D3/background/重送/marker eviction成本 | 非C2 redesign，維持follow-up；marker成本不是disk LRU完成證據。d1重跑受影響既有suite，不另擴scope。 |
| 77–80 caps/name/jitter/fail-fast Minor | 保持既有follow-up；若d1碰到那些測試，須按manifest歸屬補明確斷言，不能宣稱磁碟測試已代替。 |

### §8.2 v1 Q1–Q10及補充決策（均已給定答案）

| 問題／依據 | 本版採用答案 |
|---|---|
| Q1 V13順序衝突；plan:610–616、708–713；CRA clear，SC:603–624 | 採所有reviewer同意的m-10：同步fence先於marker；不再聲稱兩種順序的最早crash窗口不同。§5.3。 |
| Q2舊disk false；issue14:65、CRA:533–538/1059–1085 | 採較保守Opus I-2整份reject；加入Codex/GLM確認的特定轉移與stable重驗。§4.4。 |
| Q3 classify vs表；plan:247–264/599、CRA:596–679 | 採Codex/Opus封閉表，拒GLM僅加volatile例外就足夠的較寬措辭。§3逐端點/拒絕表。 |
| Q4 N；plan:277/336/649、CRA:1275–1308 | N=32、2秒、queue2MiB歸c；採Codex/Opus禁止background/generation flush，覆蓋GLM Q4的即刷答案。§5.1。 |
| Q5 iOS；plan:331–335/652、AIS:1039–1044 | 採共同答案：ThisDeviceOnly＋startup cleanup；不宣稱backup排除；實機NOT_RUN，isExcludedFromBackup後續。 |
| Q6 README；plan:347/584–590、CRA:446–464/1045–1047、GA:705–719 | 只confirmed SHA，key含SHA且經檔名綁AAD；未確認textFile不快取而非只memory。 |
| Q7截斷；plan:350/645、ci_page:1791–1818 | 採三方較安全答案：結構化truncated/offset，e顯示當前語言；d3不依賴e；§4.5明定整筆byte cap。 |
| Q8開關；plan:354–356/617–635/653、SC:119–138 | absent預設on；unavailable關且不刪；off啟動保留集空；off→on重建，§6e的持久關閉順序及有效binding不省略。 |
| Q9 dropped計量；plan:649、CRA admission | 聚合內部stats即可，不新增用戶警告、不含key/URI；byte budget計serialized envelope。 |
| Q10 C1b-2c；plan:517–521、PLAN_STATUS:50–61、實際AI port | 採d1前硬gate；完整C1b-2/C1b-1b依序完成，從已合併manifest鎖定非空V5_TESTS實際路徑，缺檔FAIL；d1/d3/e重跑實際port/context而非只手傳allowDisk:false。 |
| Q11 inventory方案；AIS:332–368/2613–2720；plan:323–326/624 | 採獨立read-cache inventory，不擴AI型別/decoder，不把partial/unreadable視空。§5.1。 |
| Q12 removal失敗；AAR:305–347、SC:651–690、plan:616/713 | 採Opus I-11：key或dir至少一項確認消失才可移除；兩項皆不明/失敗留account；兩項皆清完才解除完整fence。§5.3。 |
| Q13 MR/log缺路徑；plan:344–350、GA:1596–1613、diff_page:379–395 | 不延後父計畫能力：d3先交typed API，e（所有前置之後）交畫面；比在d1/d2暗改polling或移出C2保守，無共同檔案owner。 |
| Q14驗收廣度；PROMPT第2項、review Opus I-8 | 本地驗收命令遵守禁止full suite；§6/§7列受影響有界suites/analyze，未來每MR另讀回實際HEAD的完整ci/check.sh既有pipeline，不以子集/舊SHA代替。 |
| Q15中間持久化合約；repo AGENTS:15、CLAUDE Persistence、plan:352–365 | 惰性接線：d1/d2/d3不寫產品資料；c/d2可證空才no-op不造marker，unknown不是empty；e同MR補文件/控制入口並啟用。§5.3/§6d1–d3/§6e。 |

### §8.3 待辦／follow-ups（不冒充本次已驗證）

| ID／來源 | 保守答案／owner與驗證門檻 |
|---|---|
| F1／Opus m-1 未完全關閉 | d2 完成 observer 原時點、journal互斥、有限等待與可ack失敗的進度；native I/O 永不ack時保留gate/closed。另立 recovery cancellation/quiescence 工作，由 lead 指派後續 owner，先證停止後不再寫/刪才能釋gate，才可宣稱AI清理不被永久阻塞。不得用 timeout 當底層取消；本次不擴AI stores/codec/key實作。 |
| F2／Opus m-3、GLM Minor2 | c 已定同批重用及marker owner；實作後量測每次mutation增加的secure-storage write/readback/remove次數與p50/p95延遲（裝置/OS、冷暖、樣本數、synthetic帳號），e文件揭露。屬性能follow-up，不移除barrier/crash保證；不得把marker成本當LRU證據。 |
| F3／Opus m-7 | 若e落地仍過大，lead可在開工前修manifest拆e1設定/集中failure/文件/啟用、e2diff/log畫面採用，保持GA不回改、e2依e1；本版仍一包一owner，不默默拆後宣稱兩包都完成。 |
| F4／既有#14及Q5 | alias hydration效能、privacy共用sequence table、D3/background重送/marker eviction成本、caps/name/jitter/fail-fast follow-ups及iOS backup exclusion保留原另issue，不挪入C2安全結案。 |

沒有需等待使用者回答的設計選擇；保守答案已寫定。**仍未關閉的開工／驗收事實**：C1b-1b/完整C1b-2的實際合併及V5_TESTS未在本snapshot證明，故d1尚不能放行；GitLab terminal trace Range相容性、Android run-as/實際key刪除、CI與裝置均NOT_RUN。Range不足按§4.5拒持久化，不猜server行為。三重清除失敗無durable證據不能算跨process安全；F1 native I/O無ack沒有活性保證。以上不阻擋本次規劃交付，不能據此宣稱C2產品完成。

## §9 本次文件自檢及停止條件

文件自檢（非產品驗收）：

1. 比對§2 manifest/caps/consumer順序及§6七包：a→b→c→d1→d2→d3→e；kind/state在a、notice在c，d1/d2/d3不取e的文案/accessor或未來SC/typed API。GA兩段按MR順序交接，沒有同MR雙owner；history只d2的recovery runner例外。
2. 程式化核對§7固定 **41列**：M396/M397、M400–M405、M408–M411、M413/M414、M416–M420、M422–M425、M427–M439、M440A/M440B、M442/M443/M654；每列一次、恰一合法owner，無遺漏。逐列比對父計畫396–443，額外M654含V5。
3. Changes from v2包含Opus N-1/N-2/N-3/m-1至m-8及GLM Minor1–7全部finding，包含明示follow-ups；不把既有48項round-1重列為round-2 finding。每包含新增案例與受影響既有suites。以Python逐合併階段展開既有suite/glob及此前planned tests，核對caps/拓撲，並用zsh -n只查驗收片段語法；未來新檔只按manifest、V5_TESTS誠實not found/FAIL gate。沒有無參數Flutter test/full-suite本地命令。
4. 確認輸出僅本資料夾三個markdown檔；compare唯讀repo的檔案/目錄metadata（含git）前後snapshot、HEAD、porcelain；不執行本文的l10n/analyze/tests/build/裝置/CI命令。REPORT.md/RESULT.md一致，final逐字列RESULT。

停止條件：c2-breakdown-v3.md、REPORT.md、RESULT.md寫完，文件自檢完成、repo及git狀態不變。產品實作/merge/analyze/tests/build/Android/iOS/CI **NOT_RUN**，文件自檢不可替代那些證據。F1/F2/F3/F4及前置gate仍依§8保留。
