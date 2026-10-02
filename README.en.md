<img src="Resources/AppIcon.iconset/icon_128x128@2x.png" width="88" alt="Codex Buddy app icon: a white DuoDuoCat on blue" />

# Codex Buddy — macOS menu bar ChatGPT / Codex usage monitor

English · [简体中文](README.md) · [Download latest release](https://github.com/duoduocats/codex-buddy/releases/latest)

See your **remaining ChatGPT / Codex quota, reset countdown, and daily token usage** in the Mac menu bar. Click the icon to open quota details and a usage chart.

A native macOS utility for **Apple Silicon · macOS 13+**. It uses your existing local ChatGPT / Codex login; no separate API key is needed.

## New in 2.1: message reminders

The expanded panel shows maintainer messages in one row, such as a ChatGPT / Codex global-reset notice. Time-sensitive messages include a countdown. × hides a message for this run only; valid messages return after restart, while elapsed deadlines and expired messages stay hidden.

Settings contains one **Message reminders** switch. Enable it and allow macOS notifications to receive new messages. There are no early or deadline alerts. The app reads this repository's public message file about every 15 minutes while running; notifications follow system permission and Focus settings.

**No version telemetry is added.** Maintainers can view public GitHub package download counts, which do not identify people or measure the distribution of active versions. See [release download counts](docs/VERSION-STATS.md).

Important updates show a circular **Download update** button beside Settings, without automatic dialogs. Release notes and download status stay in Settings.

## New in 2.0: DuoDuoCat

Choose the new **DuoDuoCat** menu bar theme or keep the classic Ring. A rounded cat outline and four dots along a flattened lower curve combine quota and reset status in one small icon. Switch themes in Settings at any time.

<img src="docs/images/overview-en.png" width="420" alt="Codex Buddy 2.0 English interface: DuoDuoCat menu bar icon and expanded panel with remaining quota, next reset time, daily token chart, and five usage statistics" />

The visual design takes inspiration from the **iPhone Duo signal indicator**, combining quota, a countdown, and reset dots in one menu bar icon.

## Features

- **Quota at a glance:** choose Ring or DuoDuoCat, with a reset countdown or remaining percentage in the center. Four dots represent available resets when the service provides them.
- **Daily token chart:** view 7, 14, or 30 days with a smooth curve. Missing dates within available daily history are plotted as zero.
- **Five usage statistics:** lifetime tokens, peak daily tokens, longest task, longest streak, and current streak align in one row.
- **Share usage images:** turn the selected date range and statistics into an image to share, save, or copy through the system menu.
- **Message reminders:** one-row messages with an optional countdown and temporary dismissal; system notifications are opt-in.
- **Optional extras:** hide the daily usage section or sharing button, enable launch at login, and check for updates in the app.
- **English and Simplified Chinese:** the interface follows macOS preferred languages; reset dates follow your system time zone and 12 / 24-hour preferences. macOS 26+ uses a Liquid Glass panel.

## Download and install

1. Download and open the **arm64 DMG** from [GitHub Releases](https://github.com/duoduocats/codex-buddy/releases/latest).
2. Drag **Codex Buddy.app** into **Applications** on the right.
3. Open Codex Buddy from Applications and look for its menu bar icon. Make sure ChatGPT / Codex is already signed in on your Mac.

The DMG includes a drag-to-install background and an **[illustrated English and Chinese installation guide](docs/install/Installation-Guide.pdf)** for first-time users.

### If macOS cannot verify the developer

Current releases are ad hoc signed and are not Apple notarized. After confirming that the download came from this repository:

1. Try opening the app once, then dismiss the blocked-launch alert.
2. Open **System Settings → Privacy & Security**, scroll to the Codex Buddy notice, and click **Open Anyway**.
3. Complete the system confirmation, then click **Open**.

macOS saves the app as a security exception. These steps apply to developer-verification or notarization alerts. If macOS reports malware or a damaged file, stop and check the download. See [Apple's instructions](https://support.apple.com/en-us/102445).

## Default settings

| Setting | First-install default |
| --- | --- |
| Menu bar theme | Ring; DuoDuoCat is available |
| Menu bar display | Reset countdown; percentage is available |
| Daily token usage | On |
| Usage sharing button | On |
| Message reminders | Off; enabling requests system notification permission |
| Launch at login | Off |

Upgrades preserve your settings. Turning off daily token usage hides the chart and statistics in the lower part of the panel.

## Native footprint and privacy

**Version 2.0 local measurements**: **0.09–0.24% average CPU at idle**, a **1.89 MB app** and a **1.69 MB DMG**, including the bilingual guide. These use synthetic data; see the [methods and stress results](docs/QUALITY.md).

Built with **AppKit, SwiftUI, Charts, and URLSession**, without a bundled Codex CLI, Electron runtime, or persistent query subprocess. Quota is checked approximately once per minute, with longer intervals after failures. Offline results remain visible with an out-of-date indicator. Daily statistics are polled only while the usage section is visible, with a five-minute memory cache.

Local credentials are used only for authenticated quota and usage-statistics requests to ChatGPT. They are neither bundled with the app nor sent to GitHub. The app does not read conversations, project code, or browser data, and includes no analytics or advertising SDK. Results stay in memory; usage images are generated locally on demand.

GitHub handles update checks, downloads and public announcements; ChatGPT handles quota requests. Announcement requests include no login credentials, cookies, device identifier or version-measurement parameter. These services still receive the network information needed for the connection. See the [privacy policy](docs/PRIVACY.md) and [quality and performance checks](docs/QUALITY.md).

## Frequently asked questions

### Which ChatGPT / Codex limits can I see?

Codex usage limits, remaining quota, the next reset time, and available resets provided for your signed-in account. If multiple quota windows are available, choose one in the expanded panel. Missing metrics show “—”. Token counts and quota percentages measure different things.

### Why is data unavailable after signing in?

Refresh your login in ChatGPT / Codex on your Mac, then click the panel's refresh button. Unavailable daily history is shown as unavailable. The service endpoint can change independently of this project and may require a client update.

### Why did I not receive a message notification?

Enable Message reminders in the app, then check System Settings → Notifications → Codex Buddy. Focus settings, connectivity, quitting the app and device sleep can affect discovery or display. The message row stays hidden when no valid message is available. Each revision of a message sends at most one notification.

### Are Intel Macs supported?

The current release artifact supports Apple Silicon (arm64) only and requires macOS 13 or later.

### How do I change the interface language?

English and Simplified Chinese follow your macOS preferred language. You can also set an app-specific language in System Settings; relaunch the app to apply it.

## Build and test

Use macOS with Xcode Command Line Tools and an SDK supporting `NSGlassEffectView` (Xcode 26+ recommended).

Set up the test and build-only Python dependencies in the [installer build guide](docs/install/README.md) first. They are not bundled with the app.

```sh
bash scripts/test.sh
BUILD_DIR="$(mktemp -d /private/tmp/codex-buddy-build.XXXXXX)" bash build.sh
bash scripts/package.sh
```

[Development and releases](docs/WORKFLOW.md) · [Security reporting](SECURITY.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)

## License

[GPL-3.0-only](LICENSE). Bundle identifier: `com.duoduocat.codexbuddy`.
