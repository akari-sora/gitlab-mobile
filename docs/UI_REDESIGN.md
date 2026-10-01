# Mobile UX redesign — v0.2

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

- **Scroll-aware chrome.** `ScrollChromeController` hides page headers and the bottom navigation while the user scrolls toward the end of a list and shows them on any scroll back, within 56 dp of the top, when the content cannot scroll, and when a detail opens or closes. Programmatic scrolling (follow-tail logs, restored offsets) never moves it, and it never hides while a screen reader drives navigation. Tab bars stay pinned. The gesture-bar inset stays reserved when the navigation is tucked away, and the status bar keeps an opaque strip so rows never slide under the system icons.
- **One app bar on phones.** An issue or MR opened in place inside a project reports itself through `DetailFocus`; the project page removes its header and tab bar and locks horizontal tab swipes until the detail closes. Resize continuity, the back chain and two-pane behaviour are unchanged. Re-selecting the active destination scrolls to the top and never closes an open detail.
- **Density.** Lists use grouped rows inside one rounded surface instead of one card per item. Status keeps icon plus label (compact `StatusBadge`). Code rows are text height: the line-number column is 48 dp wide and at least 24 dp tall (the WCAG 2.5.8 minimum) instead of 48 dp per line, which showed about a third as much code.
- **Headers scroll away.** Search fields and filter chips are the first rows of their list (`RecordsFeed.leading`) or live in a floating app bar; they are not pinned above the list.

## Explicit remaining UX work

Physical-device keyboard/IME and back-gesture checks, screen-reader validation, a full navigation/permission matrix, native attachments/artifact downloads, OAuth, and installed APK upgrade/signing continuity are not claimed complete. The 840-pixel layout currently remains a mobile single-column experience rather than a desktop client.
