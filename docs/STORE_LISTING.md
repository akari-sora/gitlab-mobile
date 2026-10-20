# Store listing

Decided on 2026-10-19. Nothing here has been submitted to a store yet
(`NOT_RUN`).

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

## Rules for the listing

- Use no GitLab logo (the tanuki) or GitLab colours as branding, in the icon,
  screenshots or feature graphic.
- Mention GitLab only to say what the app works with ("client for GitLab®"),
  always with the notice above.
- The in-app 我的 page carries the same notice (`appIndependence` in
  `lib/core/brand.dart`).
