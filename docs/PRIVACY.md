# 隐私 / Privacy

## 简体中文

- **登录与额度**：使用本机已有的 ChatGPT / Codex 登录状态查询额度。登录信息不会发送给 GitHub 或社区宠物来源；不读取聊天内容、项目代码或浏览器数据。
- **本机数据**：保存设置、额度采样与预测记录、用量统计缓存、消息与活动缓存，以及宠物收藏、来源选择和缓存。流量统计保存在本机，不另行上报用量历史、收藏或安装记录。可在 **通用** 查看应用数据和清理缓存；清理缓存保留额度历史和个人数据。
- **网络连接**：额度和云端宠物请求连接 ChatGPT；消息、活动、更新检查及安装包下载连接 GitHub。社区目录和素材连接已启用的 HTTPS 来源及其素材地址。相关服务会收到 IP 地址、请求时间和请求路径等必要连接信息。
- **社区宠物**：公开来源读取请求不携带 ChatGPT 登录信息。素材按需加载，不包含在应用包中。Buddy 与独立 Codex Pets 的收藏、来源和缓存分别保存。本机安装和卸载需确认，不读取或修改 Codex 的内部选中状态。
- **云端宠物**：打开已安装页面时，可使用当前登录状态读取云端宠物列表；可见缩略图通过服务提供的临时图片地址加载。列表、临时地址和缩略图缓存在内存中。删除云端宠物需单独确认后，才向官方服务发送删除请求。
- **用量图片**：图片在本机生成，包含所选日期范围的曲线和使用统计，不包含账号或登录信息。保存、复制或分享由你主动操作，分享对象和服务由你选择。
- **通知**：面板消息默认开启，可在用量助手中关闭接收。macOS 系统提醒默认关闭，需主动开启并获得系统通知权限；系统提醒与面板消息的选择分别管理。

反馈问题时，请先检查截图或日志，避免公开账号信息和登录令牌。安全问题请参阅 [安全反馈](../SECURITY.md)。

## English

- **Login and quota**: Your existing local ChatGPT / Codex login is used to check quota. Login information is not sent to GitHub or community pet sources. The app does not read conversations, project code or browser data.
- **Local data**: Settings, quota observations and forecast records, usage-statistics caches, messages, activity records, pet favorites, source choices and caches are stored locally. Traffic counters remain local; usage history, favorites and installation records are not separately reported. **General** shows app data and cache cleanup; cache cleanup preserves quota history and personal data.
- **Connections**: Quota and cloud-pet requests connect to ChatGPT. Messages, activities, update checks and installer downloads connect to GitHub. Community catalogs and artwork connect to enabled HTTPS sources and their asset addresses. These services receive necessary connection information such as IP address, request time and requested path.
- **Community pets**: Public-source requests do not carry ChatGPT login information. Artwork loads on demand and is not bundled. Buddy and the standalone Codex Pets app keep separate favorites, sources and caches. Local installation and removal require confirmation and do not read or change Codex's internal selected-pet state.
- **Cloud pets**: Opening Installed can use your current login to read cloud pets. Visible thumbnails load through temporary image addresses provided by the service. Lists, temporary addresses and thumbnails are cached in memory. A cloud pet is deleted through the official service only after a separate confirmation.
- **Usage images**: Images are generated on your Mac and contain the selected chart range and usage statistics, without account or login information. You choose when to save, copy, or share, and which service or recipient to use.
- **Notifications**: Panel messages are on by default and can be disabled in Usage assistant. macOS system alerts are off by default and require explicit enablement and notification permission. System alerts and panel-message choices are managed separately.

Before reporting a problem, check screenshots or logs for account information and login tokens. For security concerns, see [Security reporting](../SECURITY.md).
