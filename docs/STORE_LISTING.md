# Store listing

Decided on 2026-10-19; updated 2026-10-31. In Google Play Console (`app.mergeline`,
CB Studio), the store listing (zh-TW), Demo-mode screenshots, App access
instructions, Data safety, privacy policy URL and policy declarations are
filled, content rating (IARC) and price (US$3.99) are set, the promo video
(https://www.youtube.com/watch?v=oXaaAxL1h_E) is attached, and the Play AAB
0.6.2 (versionCode 8, `c6919e52`; AI assistant on, background runs off, no
foreground-service declarations, upload key) was submitted for Google review on
2026-10-30 and is live since 2026-10-31 at
https://play.google.com/store/apps/details?id=app.mergeline; see [Plan and status](PLAN_STATUS.md).

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

- zh-TW: `非官方 GitLab® 客戶端：議題、合併請求、CI 與自備金鑰的 AI 助理`
- en: `Unofficial GitLab® client: issues, merge requests, CI and bring-your-own-key AI`

## Full description

### zh-TW (live)

Mergeline 讓你在手機上處理 GitLab® 的日常工作：議題、合併請求的審查與合併、Pipeline 與 Job 記錄、檔案與提交，以及待辦收件匣。支援 GitLab.com 與自架的 GitLab，可以同時登入多個帳號；Token 只存放在裝置的安全儲存區。

AI 助理（自備金鑰）
• 使用你自己的 AI 供應商與 API Key（OpenAI 相容、OpenAI Responses、Anthropic），對話直接送到你選的供應商，不經過開發者的伺服器。
• 請 AI 解釋檔案、整理議題與合併請求、看懂 CI 失敗的原因。
• AI 可以提議留言、建立議題、建立分支等修改；每一個修改都會先顯示確認卡片，由你核准。高風險操作需要輸入名稱確認。
• 可以隨時在 App 內檢舉不當的 AI 回答。

其他特色
• 清單先顯示快取，也能離線保存儲存庫
• 24 種語言、深色模式、大字體
• 無廣告、無追蹤

不用帳號也能先試：在登入畫面點「試用 Demo」，用內建的範例資料體驗完整功能。

Mergeline 是獨立的第三方客戶端，與 GitLab Inc. 無關，也未經其認可。GITLAB 是 GitLab Inc. 在美國及其他國家或地區的商標。

### en (live, default listing since 2026-10-31)

Mergeline brings your everyday GitLab® work to your phone: issues, reviewing and merging merge requests, pipelines and job logs, files and commits, and a to-do inbox. It works with GitLab.com and self-managed GitLab, signs in to several accounts, and keeps tokens in the device's secure storage.

AI assistant (bring your own key)
• Use your own AI provider and API key (OpenAI-compatible, OpenAI Responses, Anthropic). Conversations go straight to the provider you choose, never through the developer's servers.
• Ask the AI to explain files, summarize issues and merge requests, and work out why a CI job failed.
• The AI can propose changes such as comments, new issues and new branches. Every change shows a confirmation card first, and you approve it. High-risk actions require typing the name to confirm.
• Report an inappropriate AI answer from inside the app at any time.

Also
• Lists show cached data first, and repositories can be saved for offline use
• 24 languages, dark mode, large text
• No ads, no tracking

Try it without an account: tap "Try the demo" on the sign-in screen to explore every feature with built-in sample data.

Mergeline is an independent third-party client. It is not affiliated with or endorsed by GitLab Inc. GITLAB is a trademark of GitLab Inc. in the United States and other countries and regions.

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

The listing graphics were redone on 2026-10-31 and went to Google review the same day, together with the new promo video.
- **Order:** they introduce Mergeline as a third-party client for GitLab® first (home, review, approve and merge, CI, project). The AI assistant comes last, as the highlight (confirmation card, then the write read back).
- **Layout:** each screenshot shows a cropped window of a 1080×2424 Demo capture at about 89% of the canvas width. The rounded card and its border are a single box, so they cannot drift apart as the earlier phone-frame composites did.
- **Production:** they are rendered with Remotion from the same captures as the video.
- **AI asset declaration:** the Play Console's declaration is "not labelled". The assets are real app screens composed by code, not generated images.

**Languages (2026-10-31, in Google review).** English (en-US) is now the default listing, so every region without a translation sees English. Traditional Chinese (zh-TW) is a translation that keeps the Chinese text, graphics and video.

The English set is a separate capture:
- The screenshots and the four clips were recorded in the English UI. The app language was set with `cmd locale set-app-locales app.mergeline --locales en-US`, because Demo mode has no language picker.
- They were rendered with the same compositions (`Shot-*-en`, `Vertical-en`, `Horizontal-en`).
- The English promo video is https://www.youtube.com/watch?v=ikrNOT5f__I.

Known issue: the English CI screenshot shows "1 minutes 35 seconds". !282 fixes the plural, so re-take that screenshot after the next release.

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
Data safety form was filled on 2026-10-30, the app went live on Play on
2026-10-31, and iOS device evidence remains open.

## Rules for the listing

- Use no GitLab logo (the tanuki) or GitLab colours as branding, in the icon,
  screenshots or feature graphic.
- Mention GitLab only to say what the app works with ("client for GitLab®"),
  always with the notice above.
- The in-app 我的 page carries the same notice (`appIndependence` in
  `lib/core/brand.dart`).
