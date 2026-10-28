# MR7 breakdown v1（AI 開閘、交付 commit 證據、隔離 sandbox、Play 聲明；僅規劃）

核對日期：2026-10-28。工作樹：`docs/mr7-breakdown`，HEAD `652215b07dd2a1bfdfd990d872d02eb0d77df182`。本次只新增本文件，不改程式、不提交、不啟動 workflow，不執行寫入、打包、裝置或上架操作。以下新增檔名、指令與驗收皆是**未來實作契約**，不是本次通過紀錄。

## §0 目標、範圍與停止條件

MR7 把已合併的 AI 功能收斂為「實際交付 commit、實際 flavor、實際可見能力」的證據，再開啟有證據的能力。範圍是父計畫 `docs/plans/ai-writes-plan-v6.md:510` 的 §13、`:526` 的 MR7、`:532` 的隔離寫入要求、`:536` 起 §15 全 32 列，以及 `:915` 的 §22.3。MR6c 的 FGS 判斷沿 `:491` 的 §12.4。

- 入口：§1 的完整前置清單全部 **merged and green**，再於新 HEAD 重讀實作。本文中的目前行號只描述本次 checkout，不要求其他分支採特定類別、版本號、函式或檔案布局。
- 出口：§15 每列有證據類型、SHA、範圍、結果與缺口；每個 production-visible operation 都有自己的合格證據；交付 SHA 的完整檢查及 artifact 反讀完成。未過能力關閉。Play 聲明／素材交接與 Play Console 核准分別記錄。
- UI/UX、所有 l10n 字串（含通知／同意／測試引導）、24 語系與 store copy 均由 **lead／Claude** 擁有。Codex 擁有下列非 UI 實作與證據；不得讓實作者順手代寫產品文案。
- 結果詞彙：`SYNTHETIC_BASELINE` 表示 merged source 有對應合成測試／歷史紀錄，**本次未重跑，也不表示整列通過**；`PASS` 必須附當次輸出；`NOT_RUN` 是尚未執行；`NOT_VERIFIED` 是查詢／反讀不足；`writeUncertain` 保留隔離，不變成失敗重試或成功。依 `AGENTS.md:21`、`:25`，compile、合成、live、裝置與 publication 不互相替代。
- 一旦身份不符、事件範圍無法證明、未知寫入、憑證外洩疑慮、來源 SHA 漂移或 artifact 不符，停止該 live 執行；後續案例標 `NOT_RUN`。修正後建立新證據批次，不覆寫失敗紀錄。

## §1 入口 gate：現況與必備依賴

本次以 `git log`／checkout 與 `glab api` 交叉讀取。GitLab 專案為 `aa22396584/gitlab-mobile`（86648389）；線上快照日期 2026-10-28。`main` 指向同一 `652215b0`，push pipeline [2998468607](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2998468607) 當時 **running**，不能寫成已綠。查詢後遇 HTTP 429，停止追查；下表未知項不推定未建立或未合併。

| 必備入口項目（逐項勾選，不縮寫成「MR6 完成」） | 本次讀取 | 進 MR7 的要求 |
|---|---|---|
| MR6b-3g full group UI [!212](https://gitlab.com/aa22396584/gitlab-mobile/-/merge_requests/212) | opened；HEAD `61848f57`；[pipeline 2998579428](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2998579428) pending | merge + 合併結果及 exact-head 檢查綠；不能以「approved／landing」代替 |
| **G14-pre**：stringList policy + accountGlobal epoch | 對應 MR／pipeline 本次 `NOT_VERIFIED` | 找到實際 MR，merged and green |
| **G14**：visibility／consent，正式開 group-target production gate | 對應 MR／pipeline 本次 `NOT_VERIFIED` | merged and green；保留其 consent／scope 安全契約 |
| **G15**：G14 之後的跨 family 正式驗收 | [!208](https://gitlab.com/aa22396584/gitlab-mobile/-/merge_requests/208) 的預寫跨 family 測試已合併（本地 merge `1cfa1bbf`）；**G14 後正式驗收仍 NOT_RUN** | 記錄 G14 後整合 SHA、命令及結果；!208 合併本身不能關閉此項 |
| MR6c **C7** [!209](https://gitlab.com/aa22396584/gitlab-mobile/-/merge_requests/209) | opened；HEAD `6b393129`；[pipeline 2998569804](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2998569804) pending | merged and green |
| MR6c **C8** [!213](https://gitlab.com/aa22396584/gitlab-mobile/-/merge_requests/213) | opened；HEAD `bfe10eeb`；[pipeline 2998566058](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2998566058) pending；host tooling，不是 device 驗收 | merged and green；**每個 device row 仍 NOT_RUN**，直到真跑與反讀 |
| Cache **C3a** [!211](https://gitlab.com/aa22396584/gitlab-mobile/-/merge_requests/211) | opened；HEAD `bf0257df`；[pipeline 2998568551](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2998568551) pending | merged and green |
| Cache **C3b**（依 C3a） | 本次 `NOT_VERIFIED` | merged and green |
| Cache **C3c**（依 C3b） | 本次 `NOT_VERIFIED` | merged and green |

因此 **MR7 目前不能開始實作／開閘**；本文件可先規劃。入口不包含 optional C3d。入口綠只證明可開始整合，不會把 C8 未跑的裝置列變成 PASS。

基線已合併：MR6a（!96–!100）、MR6b-1（!102）、MR6b-2（!104）、MR6b-3 及 13 個 group families（!186–!196、!198、!200）；checkout 與 `docs/PLAN_STATUS.md:40`–`:45` 相符。另 [!207](https://gitlab.com/aa22396584/gitlab-mobile/-/merge_requests/207) 的 #32/#37/#39/#40/#43 follow-ups 當時 opened、HEAD `5519eee4`、[pipeline 2998569534](https://gitlab.com/aa22396584/gitlab-mobile/-/pipelines/2998569534) pending；7A 對影響開放能力的缺陷逐項處置，未解決就關閉對應能力。API 的 `approved:true`、`approvals_required:0`、零 approver 不當成人工審核證據。

未來入口反讀（只輸出白名單欄位；實際 G14-pre／G14／C3b／C3c IID 由 lead 填入，不猜）：

```sh
git status --short
git rev-parse HEAD
git log --first-parent --oneline -35
for iid in 209 211 212 213; do
  glab api "projects/86648389/merge_requests/$iid" |
    jq '{iid,state,sha,merged_at,merge_commit_sha,web_url,head_pipeline:(.head_pipeline|{id,sha,status,web_url})}'
done
# 對補齊的其餘 IID 使用同一查詢；再讀 merge_commit_sha 的整合 pipeline/jobs。
```

不得保存 raw project API response、CI variables 或憑證。遇 429 記錄時間與 NOT_VERIFIED，依 Retry-After 後再查，不輪詢轟炸。

## §2 現有實作證據：開哪個 gate 會發生甚麼

| 邊界 | 本次 source evidence | MR7 必須處理的意義 |
|---|---|---|
| 整體 assistant | `lib/features/ai/ai_gate.dart:2` 的 `bool.fromEnvironment('MERGELINE_AI_ASSISTANT')`，未傳 define 預設 false；`lib/main.dart:467` 才建立 AI controller | CI 目前沒有這個 define，故一般 release 關閉。只傳 true 不代表任何 operation 已驗收 |
| CI build define | `ci/build_android.sh:77` 固定 gitlab；`:89`–`:90` 只傳 `GITLAB_MOBILE_COMMIT` | 沒有現成「Play 自動開 AI」；不得只改本機 flutter run 就稱 release 已開 |
| flavor | `docs/CI.md:116`–`:130`：gitlab=`io.gitlabmobile.gitlab_mobile`、play=`app.mergeline`，CI 只建 gitlab | flavor 目前決定更新渠道，**沒有獨立 AI 開關**。開閘必須按每個 artifact 的 define 記錄；Play 未過政策時不傳 AI=true |
| group gate | `lib/core/ai/tools/write_ledger.dart:49` false；`:54` testing override getter；`:445`、`:449` 卡 group grant；`lib/core/ai/tools/target_binding.dart:276`、`:299` 卡 binding | G14 會改這一帶；入口後重讀。testing override 不得成為 production 開閘捷徑 |
| write 逐項可見性 | `lib/core/ai/tools/write_ledger.dart:294` 預設 modelVisible=true；`:381` 篩選；`:396` scope offers；`lib/core/ai/tools/write_coordinator.dart:975` 拒絕 hidden／unknown | 已有逐 operation 關閉開關，但新 row 預設 true，尚不是 default deny。7A 補最小 release allowlist。group rows 如 `lib/core/ai/tools/ledger/rows_group_state.dart:10` 為 false；`lib/core/ai/tools/ledger/rows_files.dart:90` 的 batchApplySuggestions 亦未開 |
| 不能誤判 T3/T4 都隱藏 | `lib/core/ai/tools/ledger/rows_refs.dart:28` deleteBranch、`lib/core/ai/tools/ledger/rows_project.dart:54` createProject、`lib/core/ai/tools/ledger/rows_deletes.dart:81` markAllTodosDone 已列入 ledger | `write_ledger.dart:307` 的舊 T1/T2 註解不是現況。global gate 一開可能暴露高 tier／全帳號能力，7R 必須先收斂可見集 |
| read 工具 | `lib/core/ai/tools/tool_catalogue.dart:182`、`:255`、`:278` 靜態 specs；`:287` getter；`:609` dispatch | 目前沒有逐 read-tool release switch；7A 補最小名稱 allowlist，specs 與 dispatch 同時檢查，hidden call 必須零 request |
| consent／catalogue | `lib/core/ai/tools/tool_catalogue_version.dart:1` 目前 4；`lib/features/ai/ai_chat_controller.dart:3903` 的 policyVersion 目前 3、operationIds 取自 visible ledger；`lib/core/ai/ai_provider.dart:321` hash 含 tools／catalogue／categories／policy，`:346` disclosureVersion 2 | visibility／scope／policy 改變須使舊 consent 失效。這些版本不是「開 AI」的 bool；入口後用當時版本遞增，不硬寫回 4／3 |
| provider／scope／執行邊界 | `lib/features/ai/ai_provider_editor.dart:136` 新 provider toolsEnabled=false；`lib/core/ai/tools/write_coordinator.dart:318`、`:734` 檢查 runtime policy／scope／consent | 整體 flag 開啟仍需使用者選 provider、同意實際接收者及個別 write scope；不得為 smoke 靜默開 production consent |
| native 服務 | `tool/bootstrap.py:399`–`:408` 宣告 FGS、DATA_SYNC、POST_NOTIFICATIONS、non-exported dataSync service／stopWithTask | 現況沒有另一個 production background bool；assistant 開啟會走 MR6c bridge。device 未驗時需 7A 的獨立背景封鎖，不能假設 host tests 足夠 |
| manifest 其他限制 | `tool/bootstrap.py:182` INTERNET、`:186` backup／cleartext false；`:1301` 只有 gitlab REQUEST_INSTALL_PACKAGES | bootstrap 宣告不等於 merged manifest／APK。Play 必須反讀權限且不含自更新安裝權限 |
| 本地簽名與 Play | `AGENTS.md:29`–`:43`；`docs/ANDROID_SIGNING.md:444`–`:455` 已記錄 PLAY_UPLOAD 建立／備份回報，Console 註冊及首 bundle NOT_RUN；`docs/ANDROID_RELEASE_INVENTORY.json:133`、`:749`–`:750` 同樣註記 | 本次未讀 private key，不能說 fresh verified／重新簽名；禁止 init、旋轉、刪 app data。Play upload key ≠ Google 保管的 app signing key |

### §2.1 CI／發布路徑與證據上限

1. `.gitlab-ci.yml:51` 的 `python_checks` 跑兩組 Python unittest、compileall、bash -n；`:62` 的 `flutter_checks` 跑 `ci/check.sh`。後者 `ci/check.sh:7` 固定 lockfile，`:10` analyze，`:12` **全套** tests（單案 60s、整體 12m、machine／coverage），`:38` 任一失敗退出。
2. `.gitlab-ci.yml:75` 的 native_templates 是生成／SDK 檢查與 tar，不是 iOS build。`:87` 名為 android_debug 的 job 依 `ci/build_android.sh:31` 的 protected lane 建 release，其他 lane 建 debug；不要從 job 名猜 variant。
3. `ci/build_android.sh:84`–`:93` 刻意不用 build --no-pub，確保 GeneratedPluginRegistrant 重生且 lockfile bytes 不變。`:95`–`:121` 產 APK、build-metadata、SHA256SUMS，metadata 明寫 development-preview 與 device_acceptance=NOT_RUN；目前尚未記 AI defines，7A 補上。
4. `.gitlab-ci.yml:118` 的 publish_preview 僅 default branch；`ci/deliver_preview.sh:5`–`:14` 檢 hash，再上傳 generic package `gitlab-mobile-preview/<full SHA>`。它不建立 GitLab Release、不送 Play。普通 job artifacts 14 天到期，必須留下精簡可長存 receipt／package 連結。
5. `.gitlab-ci.yml:19` 讓 LIVE_SMOKE／PUBLIC_SMOKE 等專用 pipeline **跳過 regular jobs**。`:134` LIVE_SMOKE=1 僅 API 觸發 authenticated CRUD，retry=0、resource_group 隔離；`:151` PUBLIC_SMOKE=1 僅 API／schedule／web 的匿名讀。兩者都不是 release 的完整 CI；push/tag 不自動替你跑 public live read，tag 本身不發布 release。
6. `docs/CI.md:65` 要 release commit 在 tag 前至少一次 public smoke 或明列 NOT_RUN；401／429 是限制或失敗，不能改成 PASS。MR7 預設 public smoke 未合格時不交付受影響 read capability。

### §2.2 現有 smoke 能重用甚麼

`tool/run_live_smoke.py:25` 隱藏輸入 PAT，`:29`–`:38` 0600 暫存檔，子程序 env 只有 token file 路徑；不把 token 放 argv／環境值／報告。`tool/live_smoke.dart:60` 驗 /user，`:69`–`:79` 建 private suffix project 並以 ID/path 反查，`:421`–`:435` finally 只清自己建立且名稱符合的 project、排除 86648389。這是可重用的**credential／sandbox pattern**。

它沒有逐 operation 的 AI proposal／confirm 證據、每次 mutation 前 numeric ID + full path 的雙查、全時間窗 `GET /users/:id/events` 非 sandbox 事件證明，也沒有 MR7 的能力結果映射。故 `python3 tool/run_live_smoke.py --expected-user-id <numeric-id>` 即使成功，仍只是既有 CRUD，不可填 MR7 live-write PASS。刪除回 202／marked_for_deletion 與獨立確認已消失分開；404 依 `AGENTS.md:11` 仍有權限歧義。

`tool/run_ai_live_smoke.py:30` 的 anthropic-direct／opencode-responses／opencode-chat／opencode-messages／ollama-chat／ollama-responses 是 provider 協定 smoke；`:40`–`:70` 讀本機已核准 op:// reference，secret 走 stdin。`tool/ai_live_smoke.dart:1` 及 `docs/plans/mr6c-decisions.md:33` 的 host 明示 always-visible，不能冒充 Android lifecycle，也沒有 GitLab 寫入。保留這兩種 smoke 各自的原有證據名稱。

## §3 保守決策（本版預設直接採用）

| 決策 | 實作／驗收契約 |
|---|---|
| 7-D1 開閘順序 | 7A–7D 期間 production global 預設仍 false；測試候選在隔離 host／owned emulator 明確傳 true。7R 在未合併候選 SHA 收齊證據後才改 CI release define，通過 merge-result CI 才合併；merge 後對最終 SHA 再跑、再反讀，才可 tag／交付。AI-on publisher 必須等待 source commit 外、綁 exact SHA 的 attestation，沒有就不 upload |
| 7-D2 單一能力最小 switch | 既有 AiCapability.modelVisible 關閉已知 row；另在既有 ledger 加一份 immutable `aiReleasedWriteTargets`（operationId → 明確允許的 target kinds），未知／未列入一律拒絕。visible ledger、toolsForScope、production consent 與 coordinator 綁定後的直接呼叫／最終送出共用此來源。某 row 任一必要 variant、tier escalation、readback、isolation 或平台前提不過，**移出 allowlist 且 row false**。例如 jobAction 的 play 未過就連 cancel 也隱藏，先不增 action 細分框架。新 row 預設 modelVisible=true 也不能通過 release allowlist；測試必驗零 port／mutation |
| 7-D3 read 同樣關閉 | 7A 在既有 tool_catalogue 加一個 immutable release name allowlist，default deny 新名字；specs 與 execute／dispatch 共用。未驗 get_group_work_item 等不因 write row 關閉而繼續裸露。若不做此最小補口，該 provider tools 整體維持關閉 |
| 7-D4 不讓 project sandbox 越界 | createProject／forkProject（personal namespace）、markAllTodosDone（account-wide）不在本計畫 live 授權內；group WI 全部及 group-target todo 不由 project sandbox 證明。預設 production hidden／NOT_RUN，不為湊覆蓋而另建 group、寫別人的 project 或清全帳號 todo |
| 7-D5 共用 operation 的保守關閉 | snoozeTodo／unsnoozeTodo、其他 accountTodo 能從 accountGlobal／group 選到外部資源時，僅 project fixture 的成功不足；沒有完整 target-bound 驗證就**整個 operation 關閉**。7A 檢查入口後 G14-pre 的實作，不假設其形狀；若已有 final-target allowlist，需負例證明所有出界路徑被拒，才可縮小關閉範圍 |
| 7-D6 背景獨立能力 | C8 device rows 未過，增加最小 compile-time `MERGELINE_AI_BACKGROUND`（預設 false）在現有 bridge 的 start／permit 接縫，禁止取服務／背景票，foreground 仍走真可見性檢查。不得用 host always-visible 或拿掉最終 gate 來補。若入口後已有等價 gate，重用；若無法安全獨立關閉，整體 assistant 保持 false。manifest 仍有 FGS 時照實聲明，不能因 flag=false 省略政策檢查 |
| 7-D7 不改核心結果定義 | group todo 的 ack-only／無 core independent readback 沿 `docs/plans/mr6b3-decisions.md:205` 的 D30；觀察不把 uncertainty 解鎖。MR7 額外 observer 若無法證明 scope／結果，live row 不過且關閉。不能為驗收把 ack 改稱 readback |
| 7-D8 樣本與 scope | owner 本人帳號、一次一個 disposable private project、synthetic content、無 fork／外部 webhook／部署／secret／其他成員。repo CI 僅 synthetic echo，不用 private runners／schedule variables。測試保護分支、fork、授權等建立不足時該 variant NOT_RUN，整個相關 tool 不開 |
| 7-D9 憑證與輸出 | lead 提供 GitLab owner PAT（足夠 sandbox api 權限）、expected numeric user、允許 namespace、provider endpoint／format／model／key 與費用上限；隱藏輸入或事先安全注入 env，不把值寫 shell command、log、MR、prompt、receipt。wrapper 優先沿現有 0600 temp-file／stdin，禁止 shell tracing／原始 HTTP dump；GitLab token 永不送 provider |
| 7-D10 iOS／Play | iOS build、native roundtrip、device／TestFlight 仍獨立 NOT_RUN；Android emulator 不補 iOS。Play AI 預設關閉，直到聲明、AI content policy、reporting、flavor artifact 都有證據；gitlab 有限能力開閘不自動替 Play 開 |
| 7-D11 精確 SHA | release evidence tuple = full SHA + lock hash + Flutter/Dart + defines + flavor/variant + catalogue/policy + capability set digest + artifact hash/signer + pipeline/jobs。任一影響結果的項變動，只重用未受影響證據並說明，其餘重跑；不把祖先 commit 綠燈搬到新 release |
| 7-D12 保留既有決策 | MR6c C-D4 本地 foreground ticket 無 total TTL、native ticket 才有 1000ms；C-D5 正常 release 可顯式 rebind，invalidation 不可；C-D10 late task-back reply 不重試且原 native movement 仍 unknown。沿 `docs/plans/mr6c-decisions.md:39`、`:46`、`:92`，不從舊 breakdown 再引入相反契約 |

### §3.1 失敗列到「保持關閉」的可執行映射

7A 定義 evidence manifest，每個 operationId（read 用 tool name）至少有：候選 tier／variants、允許的 target kinds、API instance/version、synthetic tests、live scenario IDs、independent readback、events isolation、emulator／native 前提、狀態與未過理由。候選清單由當時 ledger/specs **枚舉後逐項對照**；production manifest 的可見集合由 runtime release allowlists 匯出，避免另抄一份可見工具清單。allowlists 在 7A 初始為空，7R 只加入有證據者。

7B 的 PASS 只產生證據，不自行修改產品 gate。7R 唯一 owner 將缺證據的 write operation 移出 runtime allowlist 並設 row modelVisible=false、read name 移出 allowlist，對照 manifest 寫出相等性測試；不存在的／新增未登記能力在 runtime default closed。例：`upload_attachment` 的 GitLab multipart 成功但 bytes 不外送 provider 未驗，整個 upload tool 關閉；jobAction(retry) 結果 uncertain，整個 jobAction 關閉；group family 即使 G15 合成綠，沒有獨立 group live 授權與觀察仍關閉。

7A 為 read 與 write 共用一個可注入的 release-policy view（read names／write operation+target kinds），production 預設只用上述 immutable allowlists。host sandbox 明確注入候選測試 view，仍執行同一 production runner／catalogue／coordinator／port 與其他所有安全檢查；候選 view 的建立與選擇只存在 `tool/mr7/`，app entrypoint 不匯入，也沒有 app CLI／env／QA runtime override。測試鎖住 release dependency graph 不含 candidate adapter，直接 forged calls 也走相同 view。family 合成 tests 以明確 fixture view 保留正向覆蓋，不刪掉原安全斷言來求綠。

emulator 一律用該 source SHA 實際 production allowlists；7D 先交付素材規格，7R 候選 allowlist 準備後由 Claude 依原 ownership 補跑畫面與確認，不透過 debug QA 放寬工具。7R 正式 live 必須用 `--policy production`（wrapper 預設亦為 production）、禁止 candidate injection，檢查 full release SHA／actual flags／allowlist digest／有效 consent 與原 gates；候選模式的 PASS 只供選擇 7R 候選清單，不能當 final evidence。

全能力或共享安全前提（journal／consent／account fences／最後同步送出）不過時，關閉 global assistant，不把跨工具的缺陷偽裝成單一 row 失敗。關閉後再驗 spec 不出現、forged invocation 零 request、舊 consent 失效、同名 alias／scope 不可繞過；不能只把 UI 按鈕藏起來。

## §4 小 MR 切分、依賴與唯一 owner

以下是未來檔案分工。**每個 stage 每個檔案只有一位 writer**；shared file 交棒前先合併／重讀／更新 line evidence。其他人可審查，不並寫。先完成入口 E0；7B0 依 7A，7B1→7B2→7B3 共用同一 session 的 sandbox 串行；7C 與 7B 可讀取並行；7D 依 7C 素材契約，7R 依全部 disposition。裝置列沿 C8 的既有案號，不重造另一份測試矩陣。

| Packet／owner | 唯一 owned files／section（未來） | 契約、§15 主責列、NOT_RUN |
|---|---|---|
| **7A gate／evidence contract，Codex** | `lib/features/ai/ai_gate.dart`、`lib/features/ai/ai_background_execution.dart`、`lib/core/ai/tools/tool_catalogue.dart`、`lib/core/ai/tools/write_coordinator.dart`、`write_ledger.dart` 及需要的 ledger rows、`tool_catalogue_version.dart`；`ai_chat_controller.dart` 僅 policy 接線；`.gitlab-ci.yml`、`ci/check.sh`、`ci/build_android.sh`、`ci/deliver_preview.sh`、對應 `ci/tests/ci_pipeline_config_test.py`／`tool/tests/test_ai_boundaries.py`；新增 `ci/mr7_attestation.py`（stdlib JSON／digest 檢查）、`test/ai/mr7_release_gate_test.dart`、`mr7_background_gate_test.dart`、`tool/tests/test_mr7_release_flags.py`、`ci/tests/mr7_delivery_gate_test.py`；現有 `test/ai/ai_failure_test.dart` 僅更新過時 default-off 單一路徑斷言 | 建立 §3 runtime default-deny／manifest、雙編譯模式完整檢查、metadata flags／digest；AI-on publisher 加 §8 的 exact-SHA 外部 attestation 與 release artifact 檢查。建置仍 off 到 7R。主責 2/8/10/11/12/13/16/21/29，32 共用安全列全部重跑。host/live/device/Play 一律 NOT_RUN |
| **7B0 isolation／runner，Codex** | 新增 `tool/run_mr7_sandbox.py`、`tool/mr7_sandbox.dart`、`tool/mr7/sandbox_contract.dart`、`tool/tests/test_mr7_sandbox_runner.py`、`test/ai/mr7_sandbox_contract_test.dart`、`docs/MR7_SANDBOX.md`；既有 runner 只讀／重用可用邏輯，需改動由本 owner 明確接手 | §5 的 identity／per-write guard／human confirm／observer／events／cleanup／fail-stop，host 明示 foreground。主責 3/4/5/6/10/16/18/19/21/29/31；此包先合成，任何 live PASS 仍 NOT_RUN |
| **7B1 REST T1/T2，Codex** | 新增 `tool/mr7/rest_scenarios.dart`、`test/ai/mr7_sandbox_rest_test.dart`；只交付自己的 case definitions，不改 7B0 shared runner | §5.2 REST／upload／draft cases；主責 8/9/14/19/20/23/32；每個 operation 全鏈證據，實例缺功能的個別 variant NOT_RUN，所屬 tool closed；手機實際 picker／確認 UI 未跑仍 NOT_RUN |
| **7B2 project GraphQL，Codex** | 新增 `tool/mr7/graphql_scenarios.dart`、`test/ai/mr7_sandbox_graphql_test.dart` | project WI widgets／activity／incident 等；主責 10/16/24/25/29；group fixtures 只做拒絕負例，不 live 寫 group；無 server feature／權限即 NOT_RUN／closed |
| **7B3 advanced T3/T4，Codex** | 新增 `tool/mr7/advanced_scenarios.dart`、`test/ai/mr7_sandbox_advanced_test.dart` | refs/files/MR/CI/snippets/registry/project settings 的 sandbox-only variants；主責 8/9/18/20/26/30/31/32；personal/account-global、不可造出的 registry 或 schedule variant 保持 NOT_RUN／closed，不縮短 tier 契約 |
| **7C Play 聲明，Codex 技術表／lead 提交** | 新增 `docs/MR7_PLAY_DECLARATIONS.md`；`tool/bootstrap.py`／`tool/tests/test_bootstrap.py` 在本包才取得 ownership，只有確定需要的 permission／flavor 修正；不並改 7A 檔案。所有對外文字交 Claude | §6 的 FGS／data safety／權限／AI policy／privacy-policy mapping。主責 11/15/22/23/27/28（政策與 artifact 子列），device V1–V12（依本包相關功能列適用子集）、R8 最佳化／QA 接縫缺席的 artifact 檢查與 Console 提交／核准 NOT_RUN，不能用表單草稿升格 |
| **7D listing／UI 交接，lead／Claude** | `docs/STORE_LISTING.md`、新增 `docs/MR7_LISTING_HANDOFF.md`；所有 UI widget／`lib/l10n/`（含產生檔）、通知及 reporting 體驗由 lead 分派的單一 Claude owner 修改 | §7 的素材／語意／320dp/2×/RTL／24 locale；主責 2/7/11/12/14/15/16/27/28/31 的 UI。Codex 可執行非文案驗證。未實測 screenshot／report receipt／Play device 一律 NOT_RUN |
| **7R final closure／release receipt，Codex；merge／publication 由 lead** | 7A 檔案整批串行交棒給 7R；`docs/V0_6_AI_VERIFICATION.md`、`docs/PLAN_STATUS.md`、`docs/CI.md`、`docs/ANDROID_RELEASE_INVENTORY.json`、必要的 `docs/ANDROID_SIGNING.md` 公開狀態；新增 `docs/MR7_RELEASE_EVIDENCE.md` | §8 收斂所有 32 列及 operation manifest、關閉失敗能力、final-SHA CI／package 反讀。只有合格 gitlab release build 加 AI=true；background 預設 false。Play AI／iOS／未跑 device 列不代勾；不自動 tag 或發布 |

涉及 consent 對話、開關入口或錯誤文案的程式變動由 7D Claude 接手；7A 與 7R 僅改核心 policy／接線，不同時編輯 widget。若 7C 發現必須新增 reporting 接收服務，另開具體 scope 的 follow-up；本計畫先保留 Play AI=false，不默認新增 backend 或 dependency。

7A 本身依序拆為 **7A1 runtime capability gates → 7A2 background-only gate → 7A3 CI／attestation／publisher** 三個小 MR：A1 擁有 ledger/catalogue/coordinator/policy 及 gate tests，A2 擁有 ai_gate/background bridge 及 background tests，A3 擁有 ci/、.gitlab-ci.yml、metadata 與對應 Python tests；ai_gate 的全域 default-off 契約不變。跨組測試檔依 A1→A2→A3 串行交棒；7B0 等三者都 merged and green 才開始。表內 7B scenario 包以 fixtures／case definitions 為單位，發現單包過大再沿表中的 operation families 拆，shared runner 仍只有 7B0 owner。

### §4.1 每包精確驗收指令

下列命令**本次皆 NOT_RUN**；新增測試／flags／CLI 要由對應包實作後才存在。使用 `.fvmrc` 的 Flutter **3.47.2**、已提交 lock。`MR7_EVIDENCE` 由實作者指向 session scratch／小型 git-ignored 目錄，不含 secret、不提交大型輸出。每包先跑共通區塊，再只跑該包區塊；累積整合須等所列各包全部交付。全套檢查沿 `ci/check.sh:12` 的 GNU `timeout`（每模式 12 分鐘、TERM 後 15 秒 KILL）與 `ci/test_report.py:86` 的完成事件檢查，禁止拿被中斷的計數當總數；缺少同款 timeout 的環境不執行無總期限的替代命令。

```sh
# 共通（每包至少跑受影響測試，再由 7R 跑完整組合）
set -euo pipefail
: "${MR7_EVIDENCE:?set a session scratch evidence directory}"
mkdir -p "$MR7_EVIDENCE"
fvm flutter pub get --enforce-lockfile
fvm flutter analyze --no-pub
python3 -m unittest discover -s ci/tests -p '*_test.py' -v
python3 -m unittest discover -s tool/tests -p 'test_*.py' -v
python3 -m compileall -q ci tool
for script in ci/*.sh; do bash -n "$script"; done
```

```sh
# 7A1：runtime gate；未配置預設 off 與明確 on，不引用 A2 的 background test
fvm flutter test --no-pub test/ai/mr7_release_gate_test.dart test/ai/ai_failure_test.dart
fvm flutter test --no-pub --dart-define=MERGELINE_AI_ASSISTANT=true --dart-define=MERGELINE_AI_BACKGROUND=false test/ai/mr7_release_gate_test.dart test/ai/ai_failure_test.dart
```

```sh
# 7A2（依 A1）：background gate，兩種編譯模式
fvm flutter test --no-pub test/ai/mr7_background_gate_test.dart
fvm flutter test --no-pub --dart-define=MERGELINE_AI_ASSISTANT=true --dart-define=MERGELINE_AI_BACKGROUND=false test/ai/mr7_background_gate_test.dart
```

```sh
# 7A3（依 A2）：CI／flags／attestation／publisher
python3 -m unittest discover -s tool/tests -p test_mr7_release_flags.py -v
python3 -m unittest discover -s ci/tests -p mr7_delivery_gate_test.py -v
```

```sh
# 7B0（依 A3）：runner／contract，僅 synthetic transport
python3 -m unittest discover -s tool/tests -p test_mr7_sandbox_runner.py -v
fvm flutter test --no-pub test/ai/mr7_sandbox_contract_test.dart
```

```sh
# 7B1（依 B0）：REST cases，僅 synthetic transport
fvm flutter test --no-pub test/ai/mr7_sandbox_rest_test.dart
```

```sh
# 7B2（依 B1）：project GraphQL cases，僅 synthetic transport
fvm flutter test --no-pub test/ai/mr7_sandbox_graphql_test.dart
```

```sh
# 7B3（依 B2）：advanced cases，僅 synthetic transport
fvm flutter test --no-pub test/ai/mr7_sandbox_advanced_test.dart
```

```sh
# 累積整合：僅在 7A1–7A3、7B0–7B3 全部交付後執行，另跑共通 Python checks
fvm flutter test --no-pub --dart-define=MERGELINE_AI_ASSISTANT=true --dart-define=MERGELINE_AI_BACKGROUND=false test/ai/mr7_release_gate_test.dart test/ai/mr7_background_gate_test.dart test/ai/ai_failure_test.dart test/ai/mr7_sandbox_contract_test.dart test/ai/mr7_sandbox_rest_test.dart test/ai/mr7_sandbox_graphql_test.dart test/ai/mr7_sandbox_advanced_test.dart
```

```sh
# 7C：manifest／flavor／QA 邊界合成守衛，並另做 §6 artifact 反讀
python3 -m unittest discover -s tool/tests -p test_bootstrap.py -v
python3 -m unittest discover -s tool/tests -p test_ai_boundaries.py -v
```

```sh
# 7D：實際改動相應 widget tests；完整語意／視覺矩陣另按 §7
python3 tool/l10n.py
python3 tool/l10n.py --check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tool/tests -p 'test_l10n.py' -v
git diff --check
fvm flutter test --no-pub test/ai/ai_entry_points_test.dart test/ai/ai_consent_dialog_test.dart test/ai/ai_write_ui_test.dart test/ai/ai_report_sender_test.dart
```

```sh
# 7R：完整 default-off 與 release-on tests，不能只跑 test/ai
mr7_default_test_status=0
timeout --signal=TERM --kill-after=15s 12m fvm flutter test --no-pub --coverage --timeout=60s --machine > "$MR7_EVIDENCE/default-tests.jsonl" 2> "$MR7_EVIDENCE/default-stderr.txt" || mr7_default_test_status=$?
mr7_default_report_status=0
python3 ci/test_report.py "$MR7_EVIDENCE/default-tests.jsonl" "$MR7_EVIDENCE/default-junit.xml" || mr7_default_report_status=$?
mr7_release_test_status=0
timeout --signal=TERM --kill-after=15s 12m fvm flutter test --no-pub --coverage --timeout=60s --machine --dart-define=MERGELINE_AI_ASSISTANT=true --dart-define=MERGELINE_AI_BACKGROUND=false > "$MR7_EVIDENCE/release-tests.jsonl" 2> "$MR7_EVIDENCE/release-stderr.txt" || mr7_release_test_status=$?
mr7_release_report_status=0
python3 ci/test_report.py "$MR7_EVIDENCE/release-tests.jsonl" "$MR7_EVIDENCE/release-junit.xml" || mr7_release_report_status=$?
printf 'default_test_exit=%s\ndefault_report_exit=%s\nrelease_test_exit=%s\nrelease_report_exit=%s\n' "$mr7_default_test_status" "$mr7_default_report_status" "$mr7_release_test_status" "$mr7_release_report_status" | tee "$MR7_EVIDENCE/check-status.txt"
test "$mr7_default_test_status" -eq 0
test "$mr7_default_report_status" -eq 0
test "$mr7_release_test_status" -eq 0
test "$mr7_release_report_status" -eq 0
```

7A 的 CI 接線要讓 `ci/check.sh --ai-enabled`（**新增的受限 option**，只轉成上列兩個 literal defines）跑同樣完整 suite／timeout／report。現有無參數模式仍測 default-off；新 regular `flutter_ai_checks` job 跑 on，android build 必須 needs 兩者及 Python／native jobs。不得以一個 selected gate test 替代全套 release-on suite；兩種模式的 counts 各自完整，不能混加。

7D 命令中 `python3 tool/l10n.py` 產生的 ARB／`*.g.dart` diff 由 Claude 檢查；不是要求 Codex 在本規劃任務改 l10n。文案完整性不只比 key 數，還須人工查 §15 第 15 列的方向、否定與條件。

## §5 Sandbox live-write 的完整合約

### §5.1 7B0 runner、每次 API→confirm→write→獨立 readback

新 wrapper 的 CLI 契約（**尚未存在、未執行**）：

```sh
python3 tool/run_mr7_sandbox.py --expected-user-id "$MR7_EXPECTED_USER_ID" --namespace "$MR7_OWNER_NAMESPACE" --provider-config "$MR7_PROVIDER_CONFIG" --policy production --expect-release-sha "$release_sha" --suite all --output "$MR7_EVIDENCE/sandbox.json"
# 開發時可指定 --suite rest、graphql 或 advanced；每次各建立／清理自己的新 sandbox。
# 正式 acceptance 用 --suite all：同一程序依序 rest→graphql→advanced，最後才 cleanup。
# 7B 探索候選時明確 --policy candidate，receipt 必帶 CANDIDATE_ONLY；7R 不接受它作 final PASS。
```

上述 MR7_EXPECTED_USER_ID、MR7_OWNER_NAMESPACE、MR7_PROVIDER_CONFIG 由 lead 提供，分別是 numeric user ID、owner full path 與 nonsecret JSON 路徑；release_sha 是本批完整來源 SHA。wrapper 不支援 token／API-key argv，也不支援任意 existing-project／resume 參數；程序中斷一律留下 quarantine receipt，另批重跑用新 sandbox，不因 rest 結束提前刪掉後兩 suite 的 fixtures。nonsecret JSON 僅有 endpoint、format（Responses／Chat Completions／Anthropic Messages）、model ID、caps、最大費用／次數與**環境變數名稱**，沒有秘密。lead 在 hidden prompt 輸入 owner PAT 與 provider key，或由既有安全 session 提供 env；wrapper 消費後以 stdin／0600 temp file 交給無 shell 子程序，清掉子程序不需要的 env。endpoint／model 不自動猜測、不查私有模型列表；自訂／router provider 的實際 recipient 與 retention 顯示 unknown，不冒用另一家政策。未配置真 provider 時只有合成結果，live AI 全鏈 NOT_RUN。

1. **身份與 setup。** 固定完整 instance（scheme/host/port/subpath）、`GET /user` 比對 expected numeric ID；驗 user 個人 namespace ownership，確認 unique run nonce 與費用上限。建立只含 synthetic seed 的 private sandbox；setup POST /projects 是 harness 管理操作，**不算 AI createProject 通過**。紀錄 server UTC、完整 numeric ID + path_with_namespace + namespace ID + owner ID，拒絕 86648389、現有專案、group namespace、fork、mirror、真實變數／外部 integration。若 sandbox ID/path 無法雙查對上，零測試寫入。
2. **每次送出前重新雙查。** uncached GET project-by-ID 及 URL-encoded full path，兩邊必須是同一 numeric ID／完整 path／owner／private 狀態，resource 的 project_id 亦相符。所有 follow-up、async job、retry、readback 先綁定同一 instance/account generation；禁止 redirect 帶憑證。rename／transfer／權限漂移立即停。groupId、其他 projectId、personal snippet、全帳號 target 在 final transport 再拒絕，不只靠模型 prompt。
3. **API 預讀。** 真實 API 取得版本／SHA／resource ID／現況，凍結 proposal 及副作用（預設／保護分支、source-branch removal、pipeline／stored parameters、mentions／attachment ownership）。記 payload digest、operation、tier、budget，不保留本文或 auth。模型只見 synthetic fixture；不得匯入 owner 真專案／events body 當 context。
4. **confirm。** 真 provider 經 production runner、catalogue、coordinator 產生 proposal；host adapter 顯示相同 policy 的 bounded target／diff／tier，**sandbox 額外要求 owner 明確確認才寫入**，不改產品 retry/play 的 bypass 自動執行政策；hardLine／固定確認／typed target 不減免。outer harness 的案例授權不代替產品所需確認。readOnly 或拒絕／修改後取消案例證明 mutation=0；auto/bypass 的安全規則優先在 fake transport 矩陣驗，不向模型開無限 sandbox 自主迴圈。host adapter 是 host-confirm 證據，app 卡片／鍵盤／RTL 另需 emulator。
5. **write。** production named wrapper／sealed GraphQL document 實送一次；嚴格量 account HTTP budget、lease、最後同步 epoch／consent／visibility／429 gate。外層 transport 只能在綁定的 sandbox 內發 mutation，連 mutation 的前置副作用也不可越界。禁止 general REST/GraphQL executor、任意 field/path、直接 port 呼叫繞過 AI 的成功宣稱。
6. **independent readback。** 另建 uncached read-only observer client（可同 owner 身份，獨立 transport／request，不用 mutation response、UI cache、假 port 或同一內存模型作 oracle）；以 exact returned ID 及 sandbox owner 重讀 server field／SHA／notes／refs／job state。刪除同時記父列表／身份驗證、時間窗與 server ack；看見 404 不能獨自推出已刪。eventual consistency 有固定短上限，未收斂就 uncertain／NOT_VERIFIED，不重送 mutation。核心 ack-only 的 todo 不竄改核心語義；額外 observer 不能證明則不開該 tool。
7. **events 範圍。** baseline 在 setup 建 project **之前**取得；場景中持續檢查，finalizer 的 cleanup DELETE／終止 deleteProject／最後任何 mutation 之後，再取 server end time，以 clock margin 的完整 UTC window 對 `GET /users/:id/events` 做最後一次完整分頁；after/before 日期只是粗篩，再精確比 created_at／event ID。讀完 pagination、待 bounded 延遲後補查，保存 scrubbed event ID/time/action/project_id 集合與頁數，window 涵蓋管理用 setup／cleanup 寫入。所有 project events 必須屬 sandbox；非 project／無 project_id、不可讀頁、429、時間窗缺口或其他專案事件均標 isolation 未證明並停止，不能靠忽略事件達成零外部事件。cleanup 後讀取失敗即整批 isolation NOT_VERIFIED，不能宣稱已通過；已刪的 sandbox 記刪除狀態，尚在的保留 quarantine，不再發新寫入。先請 owner 在該 window 暫停同帳號其他寫入，避免混入工作事件；若不能隔離，該批 NOT_RUN。events 未涵蓋所有 API 效果，所以另以 request ledger（全部 mutation 的 path／target ID）與獨立 readback 補強；不宣稱 GitLab events 是全域不可漏的 audit log。
8. **fail-stop。** `writeUncertain`、late success、無法驗 scope／readback，立即停止全 session 新寫入，後續 scenario 全標 NOT_RUN；只允許綁定目標的觀察，不解 journal isolation、不 reset／重試／換 nonce。`failedCertainly`／拒絕亦停止該 scenario 的其餘 writes，no-op 可按原契約繼續。保留 fail receipt；人工 typed-name 解鎖是獨立 synthetic／受限案例，不是消除真 uncertain 的捷徑。
9. **cleanup。** 所選 suite 全部終止後才進單一 finalizer；正常或確定未執行的失敗皆先重驗 numeric ID + full path + nonce + owner + 非 86648389，僅刪本 runner 建立的 sandbox。無 glob／刪 namespace／刪其他 project／全帳號 todo。若 in-flight／uncertain 未釐清、身份不符、程序中斷或 owner 明確保留調查，**不發 cleanup DELETE**，標 cleanup NOT_RUN／sandbox quarantined，列出私有 receipt locator 交 lead；lead 後續核對原 receipt、journal 與當前身份後單獨處置，runner 不自動重入／重試。刪除請求被接受與 actual deletion verified 分欄；受保留期限制可記 accepted/pending，不能寫已刪。錯誤不可因 finally cleanup 覆蓋。若 AI deleteProject 終止案例已完成，finalizer 僅記錄其結果，不能再次 DELETE。

每個 scenario 輸出：SHA／suite／operation／variant／tier／scope、synthetic fixture digest、預讀 ID/version、proposal/confirm timestamps（無內容）、mutation count、outcome、獨立 readback request/result 摘要、events window／page completeness、後續 stopped count、cleanup 狀態、provider protocol/model/capability 與 secret-leak scan。機密 locator 與帳號／sandbox path 不放公開 repo；公開文件只放不可反推敏感內容的摘要、hash、精簡 result 與 lead 保管的 receipt 位置。

### §5.2 operation／tier 全列枚舉與 live 範圍

下表名稱核對自 `lib/core/ai/tools/ledger/`；7A 仍須從入口後 ledger 重新枚舉，新增 operation 未對上即 closed。T3/T4／hardLine 不能因早期 T1/T2 文句而跳過。多 action、protected/default branch、公開 visibility、typed reset 等是同一 row 的必要 variants，不是挑容易的一種當全過。

| 包／tier | 候選 operations（每個各自一列 receipt） | 限制與預設 |
|---|---|---|
| 7B1 T1 | addAwardEmoji、removeAwardEmoji、setStar、setSubscribed、markTodoDone | fixture 必須綁 sandbox 資源；accountTodo 出界負例必過，做不到就整 row 關閉 |
| 7B1 T2 討論／work | createNote、updateNote、createIssue、updateIssue、createMergeRequest、updateMergeRequest、unapproveMergeRequest、createTodo、createDiscussion、createDiscussionNote、updateDiscussionNote、setDiscussionResolved、createDraftNote、updateDraftNote | synthetic users／mentions，Mergeline 主專案不寫；confirmation edit／CAS／internal/confidential／降級污染按原規則；缺可造出的 variant 不放行該 row |
| 7B1 T2 組織／上傳 | createLabel、updateLabel、createMilestone、updateMilestone、setMilestoneState、createBoard、renameBoard、setBoardSystemListHidden、createBoardList、moveBoardList、moveBoardCard、upload_attachment | upload bytes 僅 synthetic memory fixture，provider 只送允許 metadata；multipart／slow timeout／placeholder provenance 各自判定。`rows_t12.dart:596` 是 tool row，`:611` 只是 filename argument 的 modelVisible=false，不可誤認整個 upload 隱藏 |
| 7B2 project GraphQL T1/T2/T4 | updateWorkItemState、updateWorkItemStatus、updateWorkItemDates、updateWorkItemHealthStatus、updateWorkItemAssignees、updateWorkItemMilestone、updateWorkItemWeight、updateWorkItemContent、updateWorkItemLabels、createWorkItemActivityComment、createWorkItemActivityReply、editWorkItemActivityNote、deleteWorkItemActivityNote、setWorkItemActivityNoteReaction、setWorkItemNotifications、setIncidentStatus；snoozeTodo、unsnoozeTodo 另依 7-D5 | project WI／incident 的可用版本與付費功能要實查；reaction/notifications 為 T1，delete activity 為 T4，其餘主要 T2；snooze 共享多 scope，缺 group/accountGlobal 證據預設整 row closed |
| 7B3 files／refs／MR T3/T4 | edit_file、createFile、deleteFile、applySuggestion、createBranch、deleteBranch、createTag、deleteTag、createRelease、updateRelease、deleteRelease、mergeRequest、approveMergeRequest、rebaseMergeRequest、cancelAutoMerge、publishDraftNotes、deleteDraftNote | default/protected ref、CAS、merge snapshot／CI config／closing issues、whole draft batch scan、source branch removal、approval／protected branch escalation全驗；batchApplySuggestions 目前 hidden，保持 closed／NOT_RUN |
| 7B3 CI T3→T4／T4 | createPipeline、pipelineAction、jobAction、playPipelineSchedule、deletePipeline | retry/play 為 T4，一般等級需確認（不輸入名稱）；bypass 在目標綁定成立且未命中其他固定確認規則時可自動執行（`docs/plans/ai-writes-plan-v6.md:20`、`:543`；`lib/core/ai/tools/write_ledger.dart:108`）。§5.1 的 sandbox owner 確認是額外限制。既有 variables／inputs 不重讀、不新增；僅 sandbox synthetic echo CI、無部署／外部 runner。未證 server 重試參數行為則保留 §22.3 gap，相關 operation closed |
| 7B3 snippets T2→高 tier／T4 | createSnippet、updateSnippetMetadata、updateSnippet、updateSnippetFiles、deleteSnippetFile、deleteSnippet | 僅 sandbox project snippet；visibility／provenance／file-set CAS、刪除與新非私有內容 escalation 各驗；不碰 personal snippets |
| 7B3 deletes T4 | deleteNote、deleteDiscussionNote、deleteIssue、deleteMergeRequest、deleteLabel、deleteMilestone、deleteBoard、deleteBoardList、deletePackage、deletePackageFile、deleteContainerRepository、deleteContainerTag | 只刪本 run synthetic fixtures；registry fixture 不可建立／觀察就 NOT_RUN／closed，不拿 owner 現存 package 當耗材 |
| 7B3 project hardLine | editProject、deleteProject | edit 限 synthetic sandbox；deleteProject 是全 suite 最後的終止案例，先雙查 ID/path/owner，之後不再寫。獨立 observer 記 deletion request／retention／父 namespace 列表及可用 server 狀態；不要求已刪專案再成功雙查，也不把單獨 404 當刪除證明。未能獨立確認結果就 NOT_VERIFIED／closed。harness cleanup 不算 AI deleteProject 通過，finalizer 不再重刪。保護／轉移等越界欄位拒絕 |
| 保持 closed | createProject、forkProject、markAllTodosDone、batchApplySuggestions；15 個 group-specific aliases 及未能安全縮小 scope 的共享 todo；未通過 read name | project-only 授權不覆蓋 personal namespace／account-wide／group。未來要另定 isolated owner group／account 方案，不在本次 scope 偷增 |

最終合格的是實際 server 上的 operation／variants，不保證所有 GitLab 版本／tier 皆有能力。拒絕 403／不可用 feature、無 runner、無 package fixture 是 NOT_RUN／capability closed，不是用 mocked PASS 補 live。負面破壞／secret／race／injection 等主要在合成 transport 執行，live 只放 synthetic 且明確綁定 sandbox 的可控子案。

## §6 7C Play 聲明與官方政策（查閱 2026-10-28）

以下官方資料已在線查閱；實作／提交當日須再讀並記日期、當時表單與變更。頁面證明政策內容，**不證明 Mergeline 已獲核准**。表內 DRAFT／NOT_RUN 是目前狀態。

### §6.1 FGS／permissions

target Android 14/API 34+ 的 app 需要為使用的 FGS 宣告 manifest type、適用時的 type-specific permission 與 Play App content declaration；本案 dataSync 有專屬 permission（不能概括所有 type 都有）。表單要求功能、延後／中斷影響及使用者觸發示範影片。[官方 FGS 聲明說明](https://support.google.com/googleplay/android-developer/answer/13392821?hl=en)（查閱 2026-10-28）。7C 草稿描述「使用者主動開始的一次 AI／GitLab 網路工作」，附 notification／停止／回前景確認的實錄；不得稱永駐 agent、排程背景自動工作或承諾 Play 接受 dataSync。

既有 dataSync 是申報候選，不是適用性結論。若被拒，保守預設背景關閉、foreground-only；specialUse 需要自己的 permission、subtype 說明與審核，不可只改字串當 fallback；UIDT 僅在實際工作符合傳輸契約時另評估。target 35+ 不可由 BOOT_COMPLETED 啟動 dataSync。[Android FGS types](https://developer.android.com/develop/background-work/services/fgs/service-types)（查閱 2026-10-28）。target 35+ 的 background dataSync 有共享 24 小時窗總額 6 小時與 onTimeout 停止要求，不能以本 app 12 分鐘 active limit 取代系統行為驗證。[FGS timeout](https://developer.android.com/develop/background-work/services/fgs/timeout)（查閱 2026-10-28）。

| permission／manifest element | 目前來源／預期用途 | 7C 必驗的兩 flavor artifact |
|---|---|---|
| INTERNET | bootstrap.py:182，GitLab／provider 網路 | gitlab／play 都有；HTTP LAN 能否送出由真網路與 Dart policy 另外驗 |
| FOREGROUND_SERVICE、FOREGROUND_SERVICE_DATA_SYNC、POST_NOTIFICATIONS | bootstrap.py:399；AgentRunService=dataSync／nonexported／stopWithTask=true | manifest 唯一且正確 type；權限 allow/deny、停用 channel、泛用鎖屏內容、停止、真 timeout 等仍由 C8 V1–V12 中的相關列真跑；未跑 NOT_RUN |
| VIBRATE | flutter_local_notifications 的預期 merged 權限，`docs/plans/mr6c-breakdown.md:152` 要求反讀 | 以當時釘版外掛 merged manifest 為準；不能只引用 plan 就稱有／無 |
| USE_BIOMETRIC、USE_FINGERPRINT、ACCESS_NETWORK_STATE、WAKE_LOCK | 歷史 release inventory `docs/ANDROID_RELEASE_INVENTORY.json:705` 已見，分別關聯 app lock／媒體等現有功能 | 逐權限標來源／功能；不是 MR7 新增的假設，也不能抄歷史 APK 當新 APK 清單 |
| REQUEST_INSTALL_PACKAGES＋UpdateFileProvider | bootstrap.py:1298，gitlab 自更新 | gitlab 有，play **無**；Play 由 Play update API，不能將 gitlab APK 當 Play proof |
| `${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` 等外掛自訂權限 | 歷史 inventory:705；依最終 merge | 列出 protectionLevel／來源與兩 flavor 實際名字；若有新增危險權限須追查，未解不得提交 |
| 無 boot／exact alarm／全螢幕 intent／新增廣域 storage／camera／mic 要求 | 本功能不需要這些 | 最終 manifest 搜查並讀值，不把「source 沒看到」當 artifact absence；不得為 picker 偷加廣域權限 |

未來 artifact 反讀命令（不含新產 key／卸載；SDK 工具路徑由 lead 的既有 SDK 提供）：

```sh
# APK 路徑分別指定 gitlab、play 的實際候選，不用 wildcard 選最新。
apkanalyzer manifest print "$MR7_APK"
aapt2 dump permissions "$MR7_APK"
apksigner verify --verbose --print-certs "$MR7_APK"
shasum -a 256 "$MR7_APK"
# AAB 與 APK 各記 SHA／package／versionCode／signer。BUNDLETOOL_JAR 是現有已驗工具，不新增依賴。
java -jar "$BUNDLETOOL_JAR" dump manifest --bundle="$MR7_AAB" --module=base
jarsigner -verify -verbose -certs "$MR7_AAB"
```

7C 列出 merged permissions 的完整集合差異、min/target/compile SDK、FGS type、backup／cleartext／exported、QA/benchmark channel 是否缺席；release QA absence 必須沿 C8 的 R8／artifact 檢查，source grep 只能輔助。Linux 生成 iOS 不是 OS 驗證。7C 不操作實體手機；只使用專案 owned emulator（`AGENTS.md:45`）。

### §6.2 Data safety：依真資料流逐欄填表

離開裝置到使用者指定 provider 的內容仍需評估 collection；可選、ephemeral、service-provider／user-initiated sharing 例外各有條件，不能因 BYO key 全免填。同一 data type 只有在所有地區／裝置的所有使用者均可不提供／opt-out 且仍能使用 app，其他 flow 也無強制收集時，才勾 optional。transport encryption 的全域 Yes 需要全部相關 off-device 傳輸成立。[官方 Data safety 指南](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en)（查閱 2026-10-28）。7C 按 §13 與實際網路輸出建立以下 draft；不把 local history 30 天當第三方 retention。

| 資料／接收者 | categories／目的候選（以當日 Console 選項映射） | optionality／retention／encryption 的保守答案 |
|---|---|---|
| prompt、chat、selected project code、issues/MR/discussions、diff/job log 的允許片段 → 選定 AI endpoint／router 下游 | Other in-app messages、Other user-generated content、Files and docs；若實送姓名／user ID／email，另列 Personal info／User IDs；目的 App functionality | AI 是 opt-in，核心 GitLab client 可不開 AI；個別必送欄不假稱可選。逐 provider/model 查實際 terms、地區／training／retention；unknown 就 unknown，不宣稱零保留 |
| API key → 自己的 provider；GitLab PAT/OAuth → 該 GitLab instance | 認證資料的實際類型與接收者／安全用途逐項對照，不能在報告重現值 | 不把 GitLab token 放 model context；本機 secure storage 不等於對方零保存；auth／token／refresh 日誌遮蔽需真驗 |
| attachment bytes → 使用者指定 GitLab project | 真實 picker 內容依 Photos／Videos／Files and docs；目的 App functionality | MR7 live 只 synthetic bytes；對產品全部可能類型申報。此 upload flow 可由使用者不選，但整個 data type 能否勾 optional 仍須符合上方全 flow／全使用者條件；GitLab 管理員保留／刪除機制照實，不用本機記憶體清除代表 server 刪除 |
| filename／size／MIME／upload placeholder metadata → AI provider | Files and docs／相關 user content metadata，按當日欄位映射；目的生成可確認的 GitLab 內容 | **metadata 也離開裝置**。bytes 不傳 AI 的契約沿父 §13；用 multipart／provider request counters 各自驗，不宣稱「附件完全不送第三方」 |
| AI report → 實際 report recipient；可由使用者挑選的已遮蔽內容 | 訊息／user content、必要的診斷資料；目的安全／濫用處理及功能維護 | 預設不附私有內容，明示接收者與送出內容；真正提交／receipt／retention 要證明，share sheet 開啟不等於 developer 收到 |
| 本機 history／journal／encrypted read cache／notification | 未離裝置的儲存與 OS 顯示分開；不因本機加密說 provider 看不到 | 依 `AGENTS.md:15`、`:17` 的期限／容量／清理；journal metadata only。analytics/crash SDK 若不存在不可亂填有；若合併後新增，重新盤點其 off-device flows |

provider 清單需涵蓋 checkout 的 OpenAI、OpenRouter、Azure OpenAI、Gemini、DeepSeek、xAI、Anthropic、OpenCode Go／Zen、Ollama、LM Studio、Custom（`lib/core/ai/ai_provider.dart:568` 起）。router 的 recipient 依實際 routed model；Custom／未知模型不繼承 preset 的 no-training／retention。**本次沒有重新驗各 provider terms**，7C 逐一補官方 URL、查閱日、方案／model 限制與 unknown；不得照程式 preset 表的日期當最新政策。

LAN HTTP：真 loopback 與另一台 LAN 主機分開。LAN 主機是 off-device，cleartext 不能填全程加密；保守 form 答 No，除非 Play artifact 實際禁止所有 off-device HTTP 或官方適用例外有明確證據。`usesCleartextTraffic=false` 只是一項 manifest 設定，不證明 Dart/native socket 均拒絕。若為取得 Yes 改 Play build 強制 HTTPS，必須另由 lead 定義 UI／l10n 與驗證後才改，不能只在文件勾 Yes。privacy policy、data deletion／帳號功能適用性、資料接收者及聯絡資訊要與本表一致，提供公開可讀 URL 與留存版本。

### §6.3 2026 generative-AI policy 與 reporting gate

目前官方總政策頁標示 2026-09-30 生效（除另註），不能只沿舊文章假定 2026 無變動。[Developer Program Policy](https://support.google.com/googleplay/android-developer/answer/18258653?hl=en)（查閱 2026-10-28）。AI 章要求防止受限內容，且讓使用者**不離開 app**回報／標記不當生成內容給 developer，回報要進入改善流程。[AI-Generated Content](https://support.google.com/googleplay/android-developer/answer/13985936?hl=en)（查閱 2026-10-28）。

政策解釋另列有限 productivity assist 等不在預期範圍的例子；Mergeline 有對話與 agent，是否屬例外不能從 Productivity 分類推論。保守按適用處理，保留 scope 判斷與 reviewer access。[AI policy 解釋](https://support.google.com/googleplay/android-developer/answer/14094294?hl=en)（查閱 2026-10-28）。這是目前政策查證，不宣稱 AI reporting 要求是 2026 才新增。

既有 MR6a report 使用 `lib/features/ai/ai_report_sender.dart:16` 的 mailto、`:26` share fallback、`:31` externalApplication。這不能直接證明符合不離 app 的條件。7C 開一列 reporting compliance **NOT_VERIFIED**；7D Claude 擁有入口／內容選擇／同意／回執體驗，lead 決定合法接收與處理途徑，未證明前 **Play AI=false**。安全合成測試覆蓋兒少／欺騙／危險內容等拒絕與 report 路徑，不在 live provider 產生真違規內容；留 reviewer 可安全使用的合成帳號／步驟及費用限制，不交私人 GitLab 資料／常用 key。

## §7 7D store listing／screenshots hand-off

`docs/STORE_LISTING.md:3` 的 listing 從未提交，`:28`–`:35` 的 package／分類／長度與目前無 AI 的 copy 仍是基線，不能先改成所有工具可用。`:59`–`:71` 的本機 cache 聲明也不涵蓋 AI off-device flow。

Claude 取得 7R 候選 capability manifest、7C data-flow／policy draft 後，交付：各語系實際可用功能文字、provider/費用及 opt-in 說明、confirmation／unknown／stop／foreground-only 限制、不支援／未過能力不出現的截圖清單、隱私政策與 support/report URL、Play reviewer 的 synthetic access 步驟。只用 synthetic repos／帳號顯示資料；不含 PAT、私有 project path、通知私有內容或真 provider key。品牌用 Mergeline，沿現有 trademark／圖示限制。

父計畫 `docs/plans/ai-writes-plan-v6.md:515` 的三項主打素材由 Claude 逐項交接；每項綁實際 **Play flavor** 的 full SHA／artifact hash／AI 與 background flags／production capability digest、所需 read/write 能力的合格證據與該畫面的實錄。Play AI=false 或任一所需能力未過時，該項 **NOT_RUN／不展示**，不得挪用 gitlab flavor 或 candidate-only 成功；目前三項皆 NOT_RUN：

| 條件式主打素材 | 必須對上的能力／證據（source 僅定位，不代表通過） |
|---|---|
| AI 讀 Job log → 提議修正 | `get_job_log`（`lib/core/ai/tools/tool_catalogue.dart:226`）的 P／read scope、真 provider 提議與 app proposal 畫面；若素材包含套用修正，另需該 write operation 的 W／E |
| AI 建立 MR | `createMergeRequest`（`lib/core/ai/tools/ledger/rows_t12.dart:273`）的 sandbox W、獨立 readback 與 app E；未建立成功不能以草稿畫面宣稱完成 |
| 在確認卡核准合併 | `mergeRequest`（`lib/core/ai/tools/ledger/rows_merge.dart:10`）的確認前 mutation=0、確認後 sandbox W／獨立 readback 與 app E；素材若另呈現 MR approval，另綁 `approveMergeRequest`（同檔 `:25`）的證據 |

驗收：owned emulator 上實際候選 flavor 的入口→provider consent→scope→proposal→編輯／拒絕／確認→readback／unknown→停止；320dp、2× text、RTL、24 locale 的 key 與意圖方向／否定／條件；FGS 未開就不拍「背景工作已支援」。app screenshot、widget/golden 與 Play listing screenshot 分類記錄，生成圖不稱真裝置截圖。使用公有 repo 的 emulator smoke 繼續**拒絕所有寫入**；authenticated approve 只限 §5 的 sandbox 且須明確標註，兩套證據不混用。

handoff 包含 full SHA／artifact hash／flavor／flags、圖片尺寸與語系、copy revision、資料安全／權限矩陣、known NOT_RUN、Claude 審稿結果、Console 項目與 next owner。下一步才是 Play listing／internal track 上傳、Console FGS/video/data safety 儲存反讀及審核。價格 US$3.99 沿 `docs/PLAN_STATUS.md:19` 的既定方向，實際各地定價／商品頁由 lead 在 listing 階段處理。本規劃不提交 Console／發布。

## §8 7R release commit：完整檢查、live 與 artifact 分別留證

1. **Freeze。** 在所有包與缺陷 disposition 完成後凍結未合併候選，記 full SHA、tree clean、lock hash、SDK、capability digest、catalogue／policy／disclosure、兩 flavor flags。移除不合格 tools；CI 預設 gitlab release AI=true／background=false，Play 維持 AI=false，除非 7C/7D/該 flavor 證據完整。default 未定義仍 off，不能把 const 預設 true 當作 release plan。
2. **完整 checks。** 執行 §4.1 全套 analyze／兩模式 tests／Python／static checks；release-on 不只選幾個 ai tests。取得同 SHA 的 regular pipeline：python_checks、flutter_checks、flutter_ai_checks（7A 新增）、native_templates、android_debug 各 job URL／status／SHA，protected branch 真 release 才能用來交付；MR debug artifact 只作候選證據。
3. **實際 live。** final candidate SHA 重跑 §5 對全部欲開 operations 的案例及 isolation／events；server 不支援／quota／uncertain 的 row 關閉後產生新 SHA，再跑受影響 cases 與完整 checks。public read、provider protocol、authenticated write 各 receipt 分開；不能以祖先的 5962 tests／舊 smoke 擋住新缺口。
4. **merge 後再驗，先不 publish。** merge commit SHA 如不同，記整合差異、在該 SHA 跑完整 regular CI、至少一次 PUBLIC_SMOKE，及欲宣稱之 live 全鏈（或保持相應工具關閉）。在這些步驟完成前不建立對外 release/tag。7A 先將 AI-on `publish_preview` 設為獨立手動觸發的 delivery，並在 `ci/deliver_preview.sh` 強制讀取受信任 protected lane 提供的、**source commit 外**的 exact-SHA attestation；未帶／stale／缺必要 row／digest 不符就不 upload，不提供 env bypass。merge 後產好 attestation 才執行該 delivery job；off 路徑沿原 preview 規則，不由 untrusted MR 取得 delivery 或 credentials。
5. **artifact 與 attestation。** 精確從該 pipeline 的 protected release lane 取得 APK／metadata／checksums，反讀 SHA256、package、versionCode、debuggable=false、entrypoint、defines、expected signer、manifest、QA absence。attestation 包含 release SHA/tree、lock／capability digest、每個 required check／live／emulator receipt digest、pipeline/job URLs、exact APK／metadata hashes、flavor／build_type／cert、產生時間與有權提供者。7A 新增 protected 的 `mr7_release_attestation` job（manual、只供本專案 protected release ref），驗必備 receipts／digest 後產出不可原地修改的 job artifact。delivery 只接受該 job 的 ID：經已認證 GitLab API 驗 project=86648389、job name、success、protected ref／pipeline SHA、同一 artifact 的 immutable digest，再由固定 GitLab job-artifact URL 取得 attestation 並驗 hash；拒絕任意 env 提供的 file／URL、其他 job／專案／未保護 ref、過期或缺 artifact。不把本地 JSON 的自報 identity 當 authority，也不新增簽名服務／dependency。publisher 自己檢查 AI-on 時 build_type=release、gitlab package/flavor、debuggable=false、expected stable CI cert 及 artifact hash；ephemeral debug fallback 不得上傳為 AI-on 合格包。單有 SHA256SUMS 不足。普通 artifacts 14 天過期，精簡 receipt 留長存位置，binary 留既有 package registry，不在 repo 累積 GB。
6. **receipt 不改被驗 SHA。** 7R source commit 先放證據 schema／pending locators；post-merge 產出的 attestation／最終 inventory receipt 放 source commit 外。如再把公開結果補進 docs，另建明示 docs-only commit，記錄 tested release SHA，不把該新 docs SHA 稱作已驗 release，也不自動改 tag 指向它；publisher 選擇 original pipeline/artifact，而非最新 main。
7. **publication handoff。** glab tag/release 或 Play 上傳是後續 lead 動作。發布後需獨立匿名下載 checksum／metadata／APK、app updater 選中正確版本的讀回；tag successful／pipeline green 都不能代替 published bytes。Play signing／internal-track／審核／iOS 的未跑列繼續 NOT_RUN。

未來 pipeline 讀取／觸發命令（lead 提供非 secret 的 release_ref／release_sha／pipeline_id；本次不執行）：

```sh
# 一般 pipeline：不得帶 LIVE_SMOKE／PUBLIC_SMOKE，否則完整 jobs 會被 skip。
glab ci run --branch "$release_ref"
# 單獨匿名 public live reads；不是上面完整 CI 的替代品。
glab ci run --branch "$release_ref" --variables 'PUBLIC_SMOKE:1'
glab api "projects/86648389/pipelines/$pipeline_id" |
  jq '{id,sha,ref,status,source,web_url}'
glab api --paginate "projects/86648389/pipelines/$pipeline_id/jobs?per_page=100" |
  jq '.[]|{id,name,status,web_url,commit_sha:.commit.id}'
git rev-parse "$release_ref^{commit}"
git rev-parse HEAD
shasum -a 256 pubspec.lock
```

ref 在 API trigger 到回讀期間可能前進，必須 assert pipeline.sha==release_sha；不相等就此批不可用。每個 job link 形如 `https://gitlab.com/aa22396584/gitlab-mobile/-/jobs/<id>`，連同 pipeline URL 原樣記錄。trace 只擷取已遮蔽的完成摘要，不下載／公開 secrets。既有 LIVE_SMOKE 需要 file-type token variable 且只跑 CRUD；MR7 新 runner 不自動掛每次 push，不給模型／未受信任 MR provider/GitLab 憑證。

未來 Play 候選打包沿已存在的 upload signer，**先按 signing inventory lookup**，不執行 init：

```sh
GITLAB_MOBILE_SIGNING_PROPERTIES="$PLAY_SIGNING_PROPERTIES" fvm flutter build appbundle --release --flavor play --build-number "$PLAY_VERSION_CODE" --dart-define=MERGELINE_AI_ASSISTANT=false --dart-define=MERGELINE_AI_BACKGROUND=false
```

`PLAY_SIGNING_PROPERTIES` 僅為本機私有檔案路徑；不用 --no-pub，前後比 lock bytes。若將 AI 改 true，這就是新的候選組合，須先通過 Play-specific 全套安全／UI／policy gates 與同 SHA tests，不能重用 false bundle 的收據。AAB upload cert 與下載的 Play-distributed APK app-signing cert 分別記錄；本次都沒有新 build／sign／transfer。

## §9 父 §15 全 32 列覆蓋與目前狀態

**型別：S=synthetic、P=public live read、W=authenticated sandbox live write、E=owned emulator／native、N=NOT_RUN。**「S 基線」僅指 merged source 有對應 test／歷史驗證，並非本次重跑、不是整列 PASS。`docs/V0_6_AI_VERIFICATION.md:1906` 的歷史 tests 與 `:1917` 的 public-repo emulator 零寫入不充當 MR7 release 證據；`:1958` 明列 approved-write／upload／重新讀取／OAuth／iOS gaps。每列都需 7R 在 exact release SHA 重跑 S；下表額外標出不可由 S 替代的類型。

| 父 §15 row／source | 要求與證據型別 | merged 基線／MR7 主責 | 今日狀態與缺口 |
|---|---|---|---|
| 1／`ai-writes-plan-v6.md:536` | injection／hardLine／固定確認；S＋E，P 只讀 hostile synthetic 公有 fixture | MR6a、6b-1/2/3；7A、7D、7R | S 基線（ai_injection／mr6b2_injection／mr6b3_injection tests）；release S、E 及 group 整合 NOT_RUN |
| 2／`:537` | 點擊前不外送／顯示邊界；S＋E，provider request counter | MR6a；7A、7D | S 基線 ai_display；release artifact／E NOT_RUN |
| 3／`:538` | journal/key/death/reset/recovery；S＋W＋E | MR6b-1、MR6c；7B0、7R／C8 | S 基線 ai_write_journal／packet11；真 journal death／key cleanup 與 W NOT_RUN |
| 4／`:539` | stop／帳號切換／remove／consent late-success；S＋W＋E | MR6b-1、MR6c；7B0、7D／C8 | S 基線 consent_race／runner_lifecycle；late-success live 與 OS NOT_RUN |
| 5／`:540` | uncertain／401 分類、相交 key、no retry；S＋W（僅可控 sandbox） | MR6b-1/2/3；7B0 | S 基線 coordinator／races；W NOT_RUN，遇未知留隔離，不能硬造真網路重複 writes |
| 6／`:541` | double-click／雙 conversation／stale approval；S＋E，W 有限子案 | MR6b-1/2/3；7B0、7D | S 基線 mr6b2_races／mr6b3_races；release/E/W NOT_RUN |
| 7／`:542` | 29/31min expiry／scope/head drift／edited card；S fake clock＋E | MR6a/6b-1；7A、7D | S 基線 ai_draft_deadline；真 UI NOT_RUN，不用 live 等 31 分鐘代替 clock 邊界 |
| 8／`:543` | 五 autonomy×tier／escalation／固定確認；S 全矩陣＋W 每個可開 tool | MR6b-1/2；7A、7B1/3 | S 基線 write_tier／mr6b2_matrix；W NOT_RUN，hardLine／CI retries 不能跳過 |
| 9／`:544` | exact edit/version/CAS／snippets／labels／delete；S＋W | MR6b-1/2；7B1/3 | S 基線 exact_edit／p10_snippets／files tests；每 tool W NOT_RUN |
| 10／`:545` | global ID／scope／whitelist／group-page project grant；S＋W，E 選 scope | MR6b-2/3/g；7A、7B0/2、7D | S 基線 binding／isolation；group W NOT_RUN，project sandbox 不補 |
| 11／`:546` | 每 provider consent/version／ceiling／tools off；S＋E＋provider live 協定 | MR6a/6b；7A、7C、7D | S 基線 ai_write_consent／fix1_consent；release 新版本及各 recipient 最新政策 NOT_RUN／待核 |
| 12／`:547` | readonly frozen prefix／write新 segment／tool pairing；S＋E | MR6a/6b；7A、7D | S 基線 transcript／write_history；release 與 E NOT_RUN |
| 13／`:548` | importer／固定 GraphQL document／OAuth refresh；S＋W | MR6b-1/2/3；7A、7B2 | S 基線 boundary／guard tests；真 OAuth 只可專用帳號授權後做，預設 NOT_RUN，不用 PAT 結果冒充 |
| 14／`:549` | quick action／text role／mentions／secret／visibility；S＋E＋synthetic-content W | MR6a/6b-1/2；7B1、7D | S 基線 quick_actions／plain_text／redaction；W、24 locale 畫面 NOT_RUN |
| 15／`:550` | 24 locale 語意／否定／條件：S key checks＋E＋Claude 人審；`aiReadOnlyPromise` 移除：S 全 `lib/`（含 24 ARB／產生檔）零引用掃描＋新寫入揭露（`lib/features/ai/ai_consent_dialog.dart:297`），依父計畫 `:442`；history 格式版本 +1 往返：S，`lib/features/ai/ai_history_codec.dart:12` 的 1→2 與既有 `test/ai/packet7_write_history_test.dart:28` | 24 語與舊 key 移除：7D（Claude），7C 對外一致性；格式往返：7R（Codex）重跑既有測試 | 24 語：歷史 UI 基線，本批語意／E NOT_RUN；舊 key：本次 source 掃描無引用，release SHA 掃描／揭露 E NOT_RUN；格式：既有 S 基線，本批 round trip NOT_RUN |
| 16／`:551` | target intent／URL/UI／同 iid／引用否定；S＋W＋E | MR6b-2/3/g；7A、7B0/2、7D | S 基線 binding／origin／locator；group 正式 G14/G15 未關 gate，W/E NOT_RUN |
| 17／`:552` | soft20s/write21s／active12min／wall30min；S fake clock＋E | MR6b-1、MR6c；7A、7R／C8 | S 基線 timeout／execution gate；真 OS／latency NOT_RUN，native TTL 沿 C-D4 |
| 18／`:553` | fail-stop 後續 mutation=0／no-op 繼續；S＋W | MR6b-1/2/3；7B0/3 | S 基線 coordinator；真 W NOT_RUN，後續標 NOT_RUN，不自動重試 |
| 19／`:554` | 39/40/41 budget／account60min／restart；S＋W request meter | MR6b／cache；7B0/1 | S 基線 budget tests；跨重啟／live requests NOT_RUN，API quota 不是預算測試 PASS |
| 20／`:555` | publish 全 batch／external drafts／max20；S＋W | MR6b-2；7B1/3 | S 基線 p12／merge tests；外部 draft 只造在 sandbox，無 fixture 即 closed |
| 21／`:556` | callsite ledger／named wrappers／沒有未登記 writes；S static＋W request ledger | MR6b；7A、7B0、7R | S 基線 test_ai_boundaries／ledger；release 全枚舉與 events proof NOT_RUN |
| 22／`:557` | native／雙 flavor／manifest／SDK／signing；S＋artifact＋E | MR6c；7C、7R／C8 | generator S 基線；C8 host tooling 尚未合併且每 device row NOT_RUN；Play AAB 亦 NOT_RUN |
| 23／`:558` | bytes memory／picker cleanup／metadata only／multipart／provenance；S＋W＋E | MR6b-1/2；7B1、7C、7D | S 基線 attachment_session／upload_scope／packet10；真 upload＋picker／process cleanup NOT_RUN |
| 24／`:559` | group WI aliases／rename／foreign／descendants／group todo 完整性；S＋group W＋E | MR6b-3g 13 families；G14/G15→7B2 | S 基線 family tests；G15 預寫已合併≠正式驗收，group live 全 NOT_RUN／closed |
| 25／`:560` | GraphQL hooks／before/after accept／no-op／registry／ack-only；S＋W | MR6b-3/g；7B2 | S 基線 core_hooks／dispatch／todo；server 版本與獨立觀察 NOT_RUN；D30 不改 |
| 26／`:561` | merge diff／CI custom path／closes issues／snapshot；S＋W＋E | MR6b-2；7B3、7D | S 基線 merge／snapshot tests；每副作用 W NOT_RUN，不能只合一次 MR |
| 27／`:562` | engine/permit／callback loss／one-use native ticket／resume；S＋E | MR6c C1–C8；7A、7C、7D | S 基線 mr6c_ticket_boundary／stop_protocol；全部真 OS rows NOT_RUN，background=false |
| 28／`:563` | same-run resume／不重複 billing/dispatch／summary；S＋E；iOS N | MR6c；7C、7D／C8 | S 基線 mr6c_pause_resume；Android OS NOT_RUN；iOS roundtrip NOT_RUN |
| 29／`:564` | final flush barrier／epoch／429／close／rollback uncertain0；S＋W＋E | MR6b、cache C2、MR6c；7A、7B0/2／C8 | S 基線 seam／barrier tests；exact release account/cache 重整及真 W/E NOT_RUN |
| 30／`:565` | cancelAutoMerge／schedule HMAC／retry/play storedvars；S＋W | MR6b-2；7B3 | S 基線 p5_schedule_params／merge_endpoints；§22.3 真 server 行為仍 NOT_RUN，不聲稱保證複製變數 |
| 31／`:566` | typed unlock/reset/remove／tombstone／cleanup death；S＋E，受限 W | MR6b-1／MR6c；7B0/3、7D／C8 | S 基線 packet9/11／journal；真 key／death／解除 UI NOT_RUN，不 reset 真未知操作 |
| 32／`:567` | upload same-field roundtrip／crossnonce／history／hiddenSpan；S＋W＋E | MR6b-1/2；7B1/3、7D | S 基線 provenance／hidden_spans；live provider→GitLab roundtrip 及 UI NOT_RUN |

P 的責任是 public API 相容性／匿名 reads／無 credentials：7R 在同 release SHA 單獨跑 `tool/public_smoke.dart`，逐 read tool 對照其覆蓋，沒覆蓋的工具另對「含合成內容的實際 public project」送出匿名 live request，記 endpoint/tool/SHA/window，或保持 closed。FakeAdapter 的合成測試只能算 S。**P 不證任何 W、provider privacy 或 native E**。既有驗證文件止於較早的 MR6a/6b-1 歷史章，7R 必須追加當批證據，不能用一個總 PASS 蓋掉 32 列子缺口。

## §10 風險／開放問題與可直接採用的預設

| 風險／待確認項 | 本版保守預設／owner |
|---|---|
| 入口分支變形、G14-pre／G14／C3b/c 狀態查不全 | E0 不開；lead 補 actual MR/pipeline，7A 重讀，不借 MR 標題推論結果 |
| G15 預寫測試與正式驗收混淆 | !208 只記 merged tests；G14 後整合結果獨立一項，7R 不提前打勾 |
| 新帳號或 provider key／方案未供應 | 不存取 owner 既有 secret；7B live NOT_RUN，相關能力 closed，保留合成可做部分 |
| owner account 同時別處活動、events scope／延遲／分頁不足 | 該 window 停止；不刪其他資料、不忽略事件；新隔離時間窗另跑，不能宣稱「零外部寫入」 |
| group／personal／account-wide 無安全 sandbox | 保持 hidden；另立授權範圍才能 live；不為 MR7 完整度擴權 |
| 權限／GitLab tier／版本／CI runner／package fixture 不足 | 個別 operation NOT_RUN／closed；不能用 fallback 到真 owner resource 補測 |
| raw response、錯誤 trace／provider replay 洩漏內容 | runner allowlist 輸出、關 HTTP debug／shell xtrace；先用假 secret 做 leak tests，失敗不啟 live |
| 未知寫入與 cleanup 衝突 | 留 sandbox quarantined，零新寫入，保留隔離與調查 receipt；cleanup NOT_RUN，不在 finally 強刪 |
| MR7 final define 一合併就 preview 上傳／結果補 docs 又改 SHA | 7A 先建 AI-on 手動 delivery＋受控外部 exact-SHA attestation；7R 合併後驗完才放行；docs-only receipt commit 不冒充 tested release。無法保護則 AI define 繼續 false |
| C8 全是 host 工具、背景真 OS 未跑 | 7A background false；無安全 foreground-only 接縫就 global false；C8 V1–V12 與 R8（release 最佳化與產物檢查，非 V 系列案號）繼續列 NOT_RUN |
| §22.3 retry/play 參數及 channel 延遲未知 | 不加讀 variables 權限；不得承諾 server 參數安全複製；未實證關 tool。native latency 由 C8 量，不用 host VM 取代 |
| FGS dataSync／specialUse 未核准 | foreground-only；type 不自動切換。7C 準備真影片與時限行為，Console acceptance NOT_RUN |
| AI policy 是否適用、mailto/share 不足 | 預設適用且 reporting gap 未過；Play AI off，7D/lead 補合法 in-app 報告流程／收件證據再開 |
| BYO／custom／LAN data safety 難以一個答案涵蓋 | 如實列所有可能流向，unknown retention、LAN off-device HTTP 不能填全加密；不縮減表單來配文案 |
| PLAY_UPLOAD 歷史回報被誤認 fresh key／app signing proof | 沿 inventory lookup，僅 public cert 比對，無新 key／旋轉／卸載；Console app-signing cert／first upload NOT_RUN |
| UI 文案與程式 gate 不一致 | 全交 Claude；7D 以實際 manifest／capability set 出 copy／screenshots，未過功能不宣稱可用 |
| 測試 output／artifacts 膨脹 | session scratch、精簡公開 receipts、既有 registry 單份 binary；不搬出第二 clone、不放 Documents/Codex、定期清已驗 scratch |

## §11 對其他計畫的最小修正建議（本次不修改）

1. 父 v6 §14 MR7（`:526`）補入口**完整清單**及 operation 逐項閉鎖；「full CI」明寫 actual release SHA、off/on 兩模式、pipeline/jobs 與 artifact，不以 LIVE_SMOKE/PUBLIC_SMOKE 專用 pipeline 代替。§14 舊分工 `:530` 以本 packet 新指示覆蓋：**所有 l10n／copy 都 lead／Claude**。
2. v6 §15 的合成／server／device 子列分開。§22.3 `:917` 的 native roundtrip／`:918` server retry variables 維持未證明，採 MR6c decisions C-D4/5/10 的後續修正，不再要求所有 foreground tickets 都有 1000ms TTL。
3. `docs/PLAN_STATUS.md:44`–`:47` 補 G14-pre、G15 formal acceptance、C7/C8 與本 MR7 gate；`:57` 的 C3「not started」已被 !211 opened 快照超越，`:60` 還把已合併 !166/!168 放 next steps，應重讀後更新；cache 原「parallel」不豁免本 packet 要求 C3a/b/c 先 merged and green。
4. `docs/CI.md:111`–`:130` 的 Play unconfigured／signing NOT_RUN 要區分「upload key 已有歷史建立回報」與「Console app signing／bundle／publication 未跑」。7R 補 actual AI defines／new regular on-job／delivery gate；不把 preview package 或 tag 改叫 production acceptance。
5. `docs/STORE_LISTING.md` 的無 AI／cache 本機 copy 保留到 Claude 根據新能力與 §13 data flows 改稿；新增 AI provider／metadata／LAN／reporting 描述，不能延用「無 off-device」到 AI。
6. `docs/V0_6_AI_VERIFICATION.md` 追加新批次及 32-row ledger、逐 operation receipts／未跑項，不覆寫先前失敗或用舊 synthetic totals 當 final release。`write_ledger.dart:307` 的 T1/T2-only comment 與 `ai_chat_controller.dart:3922` 的舊 v2 comment 由未來檔案 owner 隨契約修正；本次只指出，不動碼。

本規劃完成的停止條件：入口狀態有來源與未知範圍、當前 gate／CI／smoke 有行號、每包唯一 owner／命令／依賴／NOT_RUN、32 列都有去處、官方政策有查閱日期。實作停止條件另依 §0／§8：沒有證據的能力保持關閉，不能以完成本計畫文件宣稱 MR7、裝置或 Play 已驗收。
