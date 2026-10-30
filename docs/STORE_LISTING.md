# Store listing

Decided on 2026-10-19; updated 2026-10-30. In Google Play Console (`app.mergeline`,
CB Studio), the store listing (zh-TW), Demo-mode screenshots, App access
instructions, Data safety, privacy policy URL and policy declarations are
filled, and the v0.6.1 Play AAB (`c39818e5`, versionCode 7, AI assistant on,
background runs off, upload key) is uploaded to the production track as a
**draft**. Submitting for review awaits the owner's content rating and price
(US$3.99) in Play Console; see [Plan and status](PLAN_STATUS.md).

## Name

**Mergeline**: the line a branch takes when it merges back. It names the app's
work (merge requests, branches and the commit graph) without borrowing a
trademark.

Why not "GitLab Mobile" or "… for GitLab":
- GitLab's [trademark guidelines](https://handbook.gitlab.com/handbook/marketing/brand-and-product-marketing/brand/brand-activation/trademark-guidelines/)
  do not allow the GitLab marks in the name of a third-party app or product.
  They allow plugins to use them only to say what they work with.
- Google Play's [impersonation policy](https://support.google.com/googleplay/android-developer/answer/9888374)
  removes apps whose title, icon or description suggests a link to another
  company. Unofficial clients named after the service they use have been
  suspended this way.
- Other independent clients take their own names, for example OctoLab, GitFox
  and Gitalchemy.

The name stays "Mergeline" in every language. The icon is the app's own
commit-graph mark and uses no GitLab logo.

| | Value |
|---|---|
| Play application ID | `app.mergeline` (the GitLab release channel keeps `io.gitlabmobile.gitlab_mobile`) |
| Category | Productivity |
| Title (≤ 30) | `Mergeline` |

## Short description (≤ 80)

- zh-TW: `隨身管理 GitLab® 議題、合併請求與 CI 的非官方客戶端`
- en: `Unofficial mobile client for GitLab®: issues, merge requests and CI`

## Full description

### zh-TW

Mergeline 讓你在手機上處理 GitLab® 的日常工作：議題、合併請求的審查與合併、
Pipeline 與 Job 記錄、檔案與提交，以及待辦收件匣。支援 GitLab.com 與自架的
GitLab，可以同時登入多個帳號；Token 只存放在裝置的安全儲存區。

Mergeline 是獨立的第三方客戶端，與 GitLab Inc. 無關，也未經其認可。
GITLAB 是 GitLab Inc. 在美國及其他國家或地區的商標。

### en

Mergeline brings your everyday GitLab® work to your phone: issues, reviewing
and merging merge requests, pipelines and job logs, files and commits, and a
to-do inbox. It works with GitLab.com and self-managed GitLab, signs in to
several accounts, and keeps tokens in the device's secure storage.

Mergeline is an independent third-party client. It is not affiliated with or
endorsed by GitLab Inc. GITLAB is a trademark of GitLab Inc. in the United
States and other countries and regions.

## App access (Play review)

Reviewers need no account or credentials. Text for the Play Console *App
access* form:

1. Open the app. On the sign-in screen tap **Try the demo (sample data, no
   account needed)** (試用 Demo（範例資料，不需帳號）).
2. The full app opens on built-in sample data, with a "Demo · sample data"
   banner on every page. The demo makes no network request except an AI
   content report you choose to send (step 4). 我的 (Me) › **Exit demo**
   returns to the sign-in screen and forgets every change.
3. AI assistant: open Pocket Planner › Files › any file › ⋮ › **Explain
   this file with AI**. Agree on the consent screen, which says that in the
   demo the conversation goes to no AI service and the answers are
   pre-written samples on the device. Tap a suggestion for a sample answer, then ask it to add a comment
   (for example "Add a comment to #1") to see the confirmation card, approve
   it, and find the comment on issue #1. With a real account the AI uses the
   provider and API key the user sets up; the app has no AI service of its
   own.
4. The **Report** (回報) action under an AI answer sends a real report in the
   app, to the developer's Google Form, as it does with a real account; in
   the demo it carries only sample data and what you type.

The Play build carries the AI assistant (the play flavor builds with
`--ai-assistant true`; background execution stays off), so step 3 is the Play
reviewer's path. The demo follows the build's AI gate
(`MERGELINE_AI_ASSISTANT`): a build without the assistant shows the demo
without it. In the demo the browser, sharing and downloads are refused, and
Markdown loads only the demo's own repository images; the one network request
the demo makes is an AI content report the user explicitly sends (to the
developer's Google Form). Store screenshots are
taken in the demo, so they show no real account.

## Read-cache data safety

The encrypted read cache stays on the device; it adds no off-device collection
or sharing. C2 leaves the Play Data safety declarations/table unchanged
([cache plan](plans/cache-plan-v3.md), line 360). Cache controls are Me ›
Storage & cache › Offline cache (toggle, aggregate size and clear). Turning it off fences disk
use before saving the preference and clearing cached data; a storage failure
keeps disk use closed and requires retry if cleanup is incomplete. Public text,
source, diffs and terminal-job logs may themselves quote secrets; encryption
does not redact that content. Sign-out, account switching, removal and terminal
401 clear the affected account's cache under the cleanup contract in
`CLAUDE.md`. Android emulator acceptance for the read cache and offline snapshots is
recorded in [Plan and status](PLAN_STATUS.md) (C2 and C3); the Play Console
Data safety form was filled on 2026-10-30, while Play review submission and
iOS device evidence remain open.

## Rules for the listing

- Use no GitLab logo (the tanuki) or GitLab colours as branding, in the icon,
  screenshots or feature graphic.
- Mention GitLab only to say what the app works with ("client for GitLab®"),
  always with the notice above.
- The in-app 我的 page carries the same notice (`appIndependence` in
  `lib/core/brand.dart`).
