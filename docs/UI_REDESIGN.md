# Mobile UX redesign — v0.2

> The v0.6 section at the end supersedes the root destinations and the project
> landing described here; the rest of this document still applies.

## Structure

The root has Inbox / Projects / CI / Me. Each root retains its list state. Project, code, review and log screens are full-screen routes: the root navigation is not stacked beneath multiple levels of tabs. Project sections are Files / Issues / MR / CI / More. The CI root explicitly asks the user to choose a project; it does not claim a project feed is an all-account pipeline API.

## Visual system

- Quiet off-white or graphite surface, cobalt accent, understated borders, 16-pixel card radius.
- 48-logical-pixel minimum principal actions, clear heading/body hierarchy, compact account identity and namespace context.
- Search and contextual actions remain near their relevant list. Dense technical explanations no longer occupy the normal project page.
- Status uses a symbol and label, never only red/green. Errors show a short explanation and action; account/instance/status diagnostics are collapsed.
- 320 / 412 / 840 logical-pixel widths, 1x / 2x text, light/dark: 48 automated layout cases across project, MR, pipeline and editor screens. These are layout checks, not a complete accessibility audit or proof of visual preference.

## Interaction correctness

Project lists distinguish membership, server stars and accessible search. Search-all requires a query instead of retrieving all public GitLab projects. Project lookups use the selected account and instance, then numeric IDs.

Repository reads pin a commit SHA. File mutations target an explicit branch and verify the file's last commit; stale updates do not silently overwrite another change. Symlinks, submodules, LFS pointers, large and binary files are not represented as editable ordinary text.

Editors are full-screen and preserve account/resource-scoped drafts in platform secure storage. HTTP validation, permission and uncertain-write errors do not clear form contents. Successful saves clear drafts without replaying the remote write. Account removal clears that account's drafts before removing its saved credential.

MR review uses the selected diff version's base/start/head references. Hunk parsing validates old/new line counts. Truncated or unavailable server diffs cannot receive fabricated line anchors. Head changes stop inline submission; approve/merge carries the reviewed SHA.

Logs are bounded and virtualized. Polling is opt-in, foreground-only and stops on errors/terminal status. Scrolling away from the bottom does not force the user back down. A visible manual job can legitimately have no trace; the play action must still be available. Retry opens the new job attempt ID.

Destructive actions require explicit confirmation; project/file/resource deletion additionally identifies the target. The API remains authoritative for access and policy. A 404 is not automatically labelled a nonexistent project.

## Screenshot evidence

CI captures actual Flutter widgets with synthetic data and CJK fonts at 412 × 892: sign-in, projects, repository and MR, in light/dark. Full PNGs remain in the job artifacts. A reduced-colour thumbnail may be printed in the CI trace for inspection; it is a compressed derivative of the real rendered screenshot, not a design mock-up.

## v0.5 changes

- **Scroll-aware chrome.** `ScrollChromeController` hides page headers and the bottom navigation after 24 dp of dragging toward the end of a list that scrolls at least 200 dp (more once it has seen that hiding would make the content fit), and shows them after 24 dp back, within 56 dp of the top, when nothing scrolls any more, when a detail opens or closes, when a pushed page pops, and when the layout returns from the rail. Shorter content never hides it. Programmatic scrolling (follow-tail logs, restored offsets) never moves it, nor do lists kept alive out of sight (other destinations, the list behind an open detail: they run with tickers off). It never hides while a screen reader drives navigation, and reduced motion skips the slide. Tab bars stay pinned. The gesture-bar inset is reserved once, below the bar, and stays when the bar is tucked away; the status bar keeps an opaque strip so rows never slide under the system icons.
- **One app bar on phones.** An issue or MR opened in place inside a project reports itself through `DetailFocus`; the project page removes its header and tab bar and locks horizontal tab swipes until the detail closes. Resize continuity, the back chain and two-pane behaviour are unchanged. Re-selecting the active destination scrolls the visible list of that destination to the top (projects, inbox, CI and 我的) and never closes an open detail.
- **Density.** Lists use grouped rows inside one rounded surface instead of one card per item. Status keeps icon plus label (compact `StatusBadge`); project visibility is the GitLab lock or globe icon with the word in its tooltip and semantics label, as on GitLab's own lists. Code rows are text height: the line-number column is 48 dp wide and at least 24 dp tall (the WCAG 2.5.8 minimum) instead of 48 dp per line, which showed about a third as much code. Breadcrumb segments in the file tree are 40 dp tall, also above that minimum; principal actions keep 48 dp. Label text picks black or white by WCAG contrast and keeps GitLab's `text_color` only when it reaches 4.5:1. Tab bars turn scrollable at large text instead of fading labels.
- **Headers scroll away.** Search fields and filter chips are the first rows of their list (`RecordsFeed.leading`) or live in a floating app bar; they are not pinned above the list. A focused search field keeps its header in place.
- **Swipe actions are reversible.** Swiping a todo hides it behind a 4-second 復原 snack bar and writes only when the bar closes without 復原; the inbox does not page tabs sideways, so the gesture is never ambiguous. The check button on the row stays a direct action.
- **Search runs on submit.** GitLab rate-limits search and a 429 pauses every request of the client, so typing alone never queries; submitting or changing the scope does.

## Explicit remaining UX work

Physical-device keyboard/IME and back-gesture checks, screen-reader validation, a full navigation/permission matrix, native attachments/artifact downloads, OAuth, and installed APK upgrade/signing continuity are not claimed complete. The 840-pixel layout currently remains a mobile single-column experience rather than a desktop client.

## v0.6 — GitHub Mobile–style layout

The look and navigation follow GitHub Mobile. Data paths, account binding, request guards and the persistence list are unchanged; nothing new is written to disk.

- **Palette.** `AppPalette` in `lib/shared/theme.dart`: dark is a near-black canvas (`#08090B`) under graphite bars, sections and cards (`#17181C`), hairlines `#2E2F34`, one blue accent (`#58A6FF`, dark text on it) and a deep-blue pill (`#1A2B3F`) for the selected destination; light is white sections on `#F2F4F7` with GitHub blue `#0969DA`. Primary text clears 7:1 and secondary text 4.5:1 on both canvas and surface. Status tints follow Primer (green success, blue running, amber pending) and keep icon plus label. Chips are filled stadium pills, cards and fields use a 12/10 dp radius, and `StatusBarInset` paints the status-bar strip in the header colour. Material You is now opt-in (我的 › 外觀) on every platform; a stored opt-in is honoured and still cleared on devices without a dynamic scheme.
- **Destinations.** 首頁 / 收件匣 / 探索 / 我的, with labels always shown and a pill indicator. 首頁 is the default and the back gesture from any other root returns to it. 探索 is the former project list (scope chips, sort, search, link/path locator, new project); it stays built so the launcher search shortcut and Home actions reach it. CI no longer has a root: it opens from 首頁 › 我的工作 › CI/CD.
- **首頁.** A pinned large title with search, refresh, a 新增 sheet (新增專案, 以連結或路徑開啟; both hand over to 探索) and the account avatar. 我的工作 rows carry coloured tiles: 議題 and 合併請求 (cross-project lists with 指派給我 / 我建立的 / 待我審查 pills and a state menu), CI/CD, 專案, 群組, 動態, 星標. Below come the projects opened recently on this device (the existing recent-project record), the account's starred projects (first five by activity, from the server; an empty list offers 瀏覽專案) and round 捷徑 for search, todos, review requests, the locator and project creation. Reads made for one account are dropped if the session moves on.
- **Project overview.** `ProjectPage` without `initialTab` lands on `ProjectOverview`: owner and namespace, the project name in a large title, description, the web link, star and fork counts with the visibility, then a wide star toggle and square Fork and share buttons. Rows lead to 議題 (open count), 合併請求, CI/CD and an expandable 更多 (成員, 專案動態, Wiki, Releases, 授權, 所有功能), then 目前分支, 檔案 and 提交紀錄, and the root README pinned to the default branch head. The app bar shows the name only after the overview header has scrolled away. A row opens the familiar 檔案 / 議題 / MR / CI / 更多 tabs; the dashboard button at the start of the tab bar returns to the overview. System back and the predictive gesture from a section opened this way also return to the overview, after anything open inside the section (an issue or MR, a folder level) has closed; the section's back button returns there too. Back on the overview, or from a section opened directly, leaves the project as before. Both halves are kept once visited; the hidden half runs with tickers off, ignores pointers and is excluded from semantics, so its back handling stays inactive. Links, search results and recent projects open the overview; resume targets and CI still open their section directly.
- **收件匣.** The tab bar became filter pills (待辦, 指派給我, 待我審查, 我建立的) over the same tab controller, and an empty todo list shows a drawn night scene with 全部處理完畢！.
- **我的.** A profile header with a round avatar, rows for 我的動態, 我的群組 and 全域搜尋, then accounts, appearance and the about block as full-width sections.

People are drawn as round monograms; projects and groups keep rounded squares. The redesign is checked by host-rendered screenshots (`test/visual_evidence_test.dart`: home, inbox, explore, me, repository overview, files and review in light and dark) and widget tests; physical-device review of the new layout is `NOT_RUN`.
