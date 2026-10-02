<img src="Resources/AppIcon.iconset/icon_128x128@2x.png" width="88" alt="Codex Buddy app icon: a white DuoDuoCat on blue" />

# Codex Buddy — macOS menu bar ChatGPT / Codex usage monitor

English · [简体中文](README.md) · [Download latest release](https://github.com/duoduocats/codex-buddy/releases/latest)

See your **remaining ChatGPT / Codex quota, reset countdown, and daily token usage** in the Mac menu bar. Click the icon to open quota details and a usage chart.

A native macOS utility for **Apple Silicon · macOS 13+**. It uses your existing local ChatGPT / Codex login; no separate API key is needed.

## DuoDuoCat

Choose the rounded **DuoDuoCat** or the classic Ring. See quota, a reset countdown, and available resets in one small icon. Switch themes in Settings at any time.

<img src="docs/images/overview-en.png" width="420" alt="Codex Buddy English interface: DuoDuoCat menu bar icon and expanded panel with remaining quota, next reset time, daily token chart, and usage statistics" />

The visual design takes inspiration from the **iPhone Duo signal indicator**, combining quota, a countdown, and reset dots in one menu bar icon.

## Features

- **Quota at a glance:** choose Ring or DuoDuoCat, with a reset countdown or remaining percentage in the center. Four dots represent available resets when the service provides them.
- **Daily token chart:** view a smooth curve over 7, 14, or 30 days to see how your usage changes each day.
- **Five usage statistics:** lifetime tokens, peak daily tokens, longest task, longest streak, and current streak.
- **Share usage images:** turn the selected date range and statistics into an image to share, save, or copy through the system menu.
- **Message reminders:** one-row messages with an optional countdown and temporary dismissal; system notifications are opt-in.
- **Optional extras:** hide the daily usage section or sharing button, enable launch at login, and check for updates in the app.
- **English and Simplified Chinese:** the interface follows macOS preferred languages; reset dates follow your system time zone and 12 / 24-hour preferences. macOS 26+ uses a Liquid Glass panel.

## Messages and updates

See quota-reset notices and other messages in the expanded panel. Messages with a deadline show a countdown and disappear when they expire. Click **×** to dismiss a message temporarily; it returns when you reopen the app if it is still valid.

To receive system notifications, enable **Message reminders** in Settings and allow macOS notifications.

Click **Check for updates** in Settings to see new versions and release notes. When an update is available, use the circular **Download update** button beside Settings to upgrade within the app.

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

## Lightweight and private

A native macOS app with a current download of about **1.8 MB**. It uses your existing local login to check quota, without reading conversations or project code. Usage images are created on your Mac; you choose when to save or share them.

See the [privacy policy](docs/PRIVACY.md).

## Frequently asked questions

### Which ChatGPT / Codex limits can I see?

Codex usage limits, remaining quota, the next reset time, and available resets provided for your signed-in account. If multiple quota windows are available, choose one in the expanded panel. Missing metrics show “—”. Token counts and quota percentages measure different things.

### Why is data unavailable after signing in?

Check that ChatGPT / Codex is signed in on your Mac, then click the panel's refresh button. If data is still unavailable, check your connection and try updating to the latest version.

### Why did I not receive a message notification?

Enable Message reminders in the app, then check **System Settings → Notifications → Codex Buddy**. Focus settings, an unavailable connection, quitting the app, or device sleep may affect notifications.

### Are Intel Macs supported?

The current release artifact supports Apple Silicon (arm64) only and requires macOS 13 or later.

### How do I change the interface language?

English and Simplified Chinese follow your macOS preferred language. You can also set an app-specific language in System Settings; relaunch the app to apply it.

## Feedback

Report a problem or suggest a feature in [GitHub Issues](https://github.com/duoduocats/codex-buddy/issues). For security concerns, see [Security reporting](SECURITY.md).

## License

[GPL-3.0-only](LICENSE).
