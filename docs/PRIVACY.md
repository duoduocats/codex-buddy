# 隐私 / Privacy

## 简体中文

- 本机登录凭据仅用于向 ChatGPT 查询额度与使用统计，不发送到 GitHub；不修改登录文件。
- 不读取聊天记录、项目代码、通讯录或浏览器数据，无分析、广告或崩溃上报服务。
- 额度与使用统计响应保留在内存。系统偏好保存更新检查时间、已通知/忽略版本和应用设置；消息提醒保存公开消息缓存、已通知消息和提醒设置，不保存账号或个人用量。
- 检查更新连接 GitHub API，下载连接 GitHub Releases 及其资源域名。服务端可见 IP、请求时间和客户端版本等网络信息。
- 更新暂存目录可能保留旧应用以供恢复，不含登录凭据或额度快照。
- 截图工具仅使用演示数据；提交问题前仍请检查截图、日志和路径。不要公开登录文件或令牌。
- 公开仓库保留维护者选择的 GitHub 账号、公开昵称和 noreply 提交邮箱，不包含个人联系方式。

## English

Local credentials are used only for authenticated ChatGPT quota and usage-statistics requests, never sent to GitHub or modified. The app does not read conversations, project files, contacts, or browser data and includes no analytics, advertising, or crash-reporting service.

Quota and usage-statistics results remain in memory. Preferences store update-check times, announced/ignored releases, and application settings. Message reminders store public message cache, announced message IDs and reminder settings, without account or personal usage data. GitHub handles update checks and release downloads; remote services receive connection metadata, including IP address, request time, and client version.

Update staging may retain the previous application for recovery, without credentials or usage snapshots. Screenshot tooling uses synthetic data. Review screenshots, paths, and logs before reporting issues; never publish credentials. The repository uses the maintainer's chosen public GitHub identity and a noreply commit email.

## 用量图片 / Usage images

分享按钮默认显示，可在设置关闭。点击时在本机生成当前日期范围的曲线和五项统计图片，不包含账号、凭据或额度面板。保存、复制和系统分享均由用户主动操作；分享服务及接收方由用户选择。

The sharing button is shown by default and can be hidden in settings. Images are generated locally on demand from the selected chart range and five statistics. They exclude accounts, credentials, and the quota panel. Saving, copying, and sharing require a user action; the user chooses the system service and recipient.

## 消息提醒与版本统计 / Message reminders and version counts

消息从本仓库的 GitHub 公共文件读取，使用独立的未登录请求，不附加本机 ChatGPT 登录凭据、Cookie、设备标识或版本统计参数。网络提供方仍能看到 IP 和请求时间等连接信息。公告请求不访问私有账号数据；推送由用户授权后的 macOS 本地通知完成，不注册远程推送设备令牌。

本版本不包含版本统计上报。维护者可在自己的电脑上读取 GitHub 公开安装包下载次数；这些不是活跃用户数量或实际安装版本分布，见 [版本下载统计](VERSION-STATS.md)。

Public announcements are fetched from this repository's GitHub file using a separate unauthenticated request with no ChatGPT credentials, cookies, device identifier or version-measurement parameter. The network provider still sees connection metadata such as IP address and request time. The announcement client does not request private account data. User-authorized macOS local notifications deliver reminders without registering remote-push device tokens.

This release includes no version telemetry. Maintainers may read public GitHub package download counts on their own computer; those counts do not measure active users or installed-version distribution. See [release download counts](VERSION-STATS.md).
