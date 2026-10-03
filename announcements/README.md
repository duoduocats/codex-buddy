# 消息源 / Message feed

`messages.json` 是独立于应用版本的公开消息文件。客户端通过 HTTPS 读取，不附带 ChatGPT 凭据、Cookie、设备标识或版本统计参数。

## 发布消息

1. 填写中英文标题和正文，确认适用范围与有效期；不要上传个人截图或私人信息。
2. 普通消息使用 `type: "message"`。填写唯一 `id`；更正同一条消息时保留 ID 并增加 `revision`。
3. `publishedAt`、`expiresAt` 使用带 `Z` 的 UTC ISO 8601 时间。有截止时间的消息可加 `scheduledAt`，面板显示倒计时，到点后隐藏。
4. `appliesTo` 和 `sourceURL` 可省略。来源链接只接受允许的官方网页或本仓库页面；客户端不自动打开链接。
5. 全球重置只是消息示例。发布具体时间前需核实官方原帖、发帖日期和时区，区分 PST / PDT；截图的观看时区不能代替原始来源。

消息时间在客户端按本机时区和日期格式显示。明确的预计时间应填写 `scheduledAt`；没有该字段时显示 `publishedAt`，它是公告发布时间，不能当作账号实际到账时间。

运行期间约每 15 分钟检查，启动和唤醒时补查，失败退避。同一条消息的同一修订版本只发一次通知，通知需用户主动开启；不安排提前提醒或到点提醒。× 只在本次运行隐藏消息，重启后未过期的消息恢复。公共消息不代表账号额度已经恢复。

当前消息仅包含公开公告的文字和原帖链接，不包含用户提供的 X 截图。PST / PDT 尚有歧义的消息不填写重置倒计时。

## Schema

- Root: `schemaVersion: 1`, `events: []`.
- Message: `id`, `revision`, `type: "message"`, `publishedAt`, `expiresAt`, `title`, `body`.
- `title` and `body`: objects containing `zh` and `en`.
- Optional: `scheduledAt` (UTC deadline), `appliesTo` (localized text), `sourceURL` (validated HTTPS URL).
- Existing `globalReset` events remain readable for compatibility, with their stricter official-source and deadline checks.

The feed is limited to 64 KB and 50 messages. Invalid data is rejected; a failed check retains the last valid cache. Expired messages and elapsed deadlines do not generate new notifications. Cache and deduplication records are bounded and contain no account identifiers or usage data.

## Publishing messages

Write bilingual titles and bodies, confirm eligibility and expiry, and avoid private screenshots or personal information. Use `type: "message"`, keep the same ID for corrections, and increment its revision. An optional UTC deadline adds a countdown; the message disappears at that time. Sources are optional and never opened automatically.

Global reset is one example of a message. Verify its original official post and absolute time before publishing; resolve relative dates and distinguish PST from PDT. The feed contains public text and an original-post link, without a user screenshot. No reset countdown is assigned while the original PST / PDT wording remains ambiguous.

The app checks about every 15 minutes while running, including startup and wake checks. User-authorized native notifications announce each active revision once. There are no early or deadline notifications. Dismissing the row hides it for the current run; a valid message returns after restart. Focus settings, connectivity, device sleep and app exit can affect discovery or display.
