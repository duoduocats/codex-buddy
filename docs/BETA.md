# Codex Buddy 2.5 Beta 历史说明 / Beta history

[正式版说明 / Stable guide](../README.md) · [English](#english)

## 中文

本页保留 **2.5.0-beta.4** 的历史说明。这些功能现已进入正式版 **2.5.0**，当前安装与使用说明见 [README](../README.md)。

### 安装与更新

- 从 [2.5.0-beta.4 Release](https://github.com/duoduocats/codex-buddy/releases/tag/v2.5.0-beta.4) 下载 arm64 DMG，支持 Apple Silicon、macOS 13+。
- 从旧版 2.4.x 开启 Beta 时，该选项位于设置的 **通用与更新**；2.5 中位于 **通用 → 更新**。当前正式版无需开启 Beta 即可升级。
- Beta 接收默认关闭；开启后会检查正式版和 Beta。关闭后不再接收新的 Beta，也不会自动降级已安装的测试版。
- 首次安装步骤和 macOS 开发者验证说明见 [正式版安装指南](../README.md#下载与首次安装)。

### 新主面板与预览

主窗口分为 **用量、宠物、消息、通用**。在 **用量 → 用量助手** 中，围绕中央的顶栏和展开面板样例调整主题、显示内容、消息、重置明细和每日 Token 用量等选项。

中央区域标有 **模拟数据预览**。调整设置会同步改变预览，顶栏和实际展开面板继续显示当前账号的真实用量。

### 用量趋势与预测

在 **用量趋势** 查看日历及日／周／累计曲线。年度日历与下方曲线的时间范围独立。日／周曲线中的空白日期以零值呈现，累计模式延续已知累计量；原始缺失记录保持未提供，部分合计显示“≥”。悬停日历或曲线可联动定位日期并查看精确 Token 数。

**用量预测** 展示已记录的额度历史及常规曲线；开启“额外重置（模拟）”并选择日期后，可同图比较假设情景。样本不足时的曲线标为预算参考。只有实际观察到的历史才会保存；无法补回过去未记录的数据。

**通用** 可管理开机启动、系统提醒和 Beta 接收，查看应用数据、缓存与分类流量。清理缓存保留额度历史及个人数据。

### 消息与特别活动

**消息** 页按时间排列公告，可滚动查看。已在展开面板临时隐藏或结束展示的消息仍保留在列表中；接收消息总开关与类别选择继续生效。

标题区的 **特别活动** 悬浮台历打开 Tibo 的 28 天挑战。活动结束后，入口变为 **历史活动**，记录保留供回看。

### Codex 宠物

**宠物** 页可切换 **发现、收藏、已安装、来源**，浏览和搜索社区主题、保存本机收藏、预览动作并管理兼容的公开 HTTPS 来源。v2 主题支持环视预览。

选择 **安装到本机**，核对作者、授权和目标目录后确认。安装后在 Codex 设置中手动进入 **虚拟宠物**，刷新并选择使用。已安装主题可移到废纸篓；覆盖安装会保留恢复副本。

已安装列表也会展示当前账号可读取的 Codex 云端宠物，可见缩略图会自动加载；删除云端宠物需确认。内置来源现为 11 个，Petdex 已移除，已有宠物保留。标签筛选已暂时移除，搜索、来源筛选和排序继续可用；已有标签说明与本地数据保留。

Buddy 与独立 Codex Pets 的收藏、来源设置和缓存各自保存，两边可识别同一个 Codex 宠物目录。社区素材按需加载，不包含在应用包中。

## English

This page preserves the **2.5.0-beta.4** guide. These features are now included in stable **2.5.0**. See [README.en.md](../README.en.md) for current installation and usage.

### Install and update

- Download the arm64 DMG from the [2.5.0-beta.4 release](https://github.com/duoduocats/codex-buddy/releases/tag/v2.5.0-beta.4). For Apple Silicon and macOS 13+.
- In older 2.4.x versions, Beta reception is under **General & updates**; in 2.5 it is under **General → Updates**. The current stable upgrade does not require enabling Beta reception.
- Beta reception is off by default. Enabling it checks stable and Beta releases. Disabling it stops new Beta updates and does not automatically downgrade an installed Beta.
- See the [stable installation guide](../README.en.md#download-and-install) for first installation and macOS developer-verification steps.

### Main window and preview

The main window has **Usage, Pets, Messages, and General**. In **Usage → Usage assistant**, adjust the theme, display, messages, reset details and daily token chart around a combined menu-bar and panel sample.

The central area is labelled **Sample data preview**. Settings update that preview immediately; the actual menu bar and panel continue to show your account usage.

### Trends and forecast

In **Usage trends**, explore the calendar and daily, weekly or cumulative curves. The annual calendar and chart ranges are independent. Daily and weekly curves render missing buckets at zero; cumulative curves carry known totals forward. Raw missing readings remain unavailable, and partial totals show “≥”. Hover the calendar or chart to link dates and inspect exact token values.

**Usage forecast** shows recorded quota history and a regular curve. Enable **Extra reset (simulation)** and choose a date to compare a hypothetical scenario on the same chart. Limited observations use a labelled budget reference. Only observed history can be saved; past unrecorded readings cannot be recovered.

**General** includes login, alert and Beta preferences, storage, cache cleanup and categorized app traffic. Cache cleanup preserves quota history and personal data.

### Messages and special activity

**Messages** lists announcements by time. Scroll through notices, including those temporarily dismissed or no longer shown in the expanded panel. The reception master switch and category choices still apply.

The floating **Special activity** calendar opens Tibo’s 28-day challenge. After the challenge ends, it becomes **Past activity** and keeps the records available.

### Codex pets

Use **Discover, Favorites, Installed, Sources** within **Pets** to browse and search community themes, keep local favorites, preview animations and manage compatible public HTTPS sources. v2 themes support look-direction previews.

Choose **Install locally**, review the author, license and destination, then confirm. In Codex settings, manually open **Pets**, refresh, and choose the companion. Installed themes can be moved to Trash; replacing a package keeps a recovery copy.

Installed also lists readable Codex cloud pets for the current account. Visible thumbnails load automatically; deleting a cloud pet requires confirmation. There are eleven built-in sources after removing Petdex, and existing pets are preserved. Tag filters are temporarily removed. Search, source filters and sorting remain available; existing tag descriptions and local metadata are retained.

Buddy and the standalone Codex Pets app keep separate favorites, source preferences and caches while recognizing the same Codex pet directory. Artwork loads on demand and is not bundled.
