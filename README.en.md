<p align="center">
  <img src="docs/images/app-icon.png" width="88" alt="Codex Buddy app icon" />
</p>

# Codex Buddy — macOS menu bar ChatGPT / Codex usage monitor

English · [简体中文](README.md) · [Download stable](https://github.com/duoduocats/codex-buddy/releases/latest) · [Beta guide](docs/BETA.md#english)

See your **remaining ChatGPT / Codex quota, reset countdown, and daily token usage** in the Mac menu bar. Click the icon to open quota details and a usage chart.

A native macOS utility for **Apple Silicon · macOS 13+**. It uses your existing local ChatGPT / Codex login; no separate API key is needed.

This page describes the current [stable release, 2.5.0](https://github.com/duoduocats/codex-buddy/releases/tag/v2.5.0), including the redesigned main window, live preview, usage trends and forecast, and integrated pet store.

## DuoDuoCat

Choose **DuoDuoCat** or the classic Ring. See quota, a reset countdown, and available resets in one small icon. Switch themes in Settings at any time.

<img src="docs/images/overview-en.png" width="420" alt="Codex Buddy English interface: DuoDuoCat menu bar icon and expanded panel with remaining quota, next reset time, daily token chart, and usage statistics" />

## Features

- **Quota at a glance:** choose Ring or DuoDuoCat, with a reset countdown or remaining percentage in the center. Four dots represent available resets when the service provides them.
- **Daily token chart:** view daily usage over 7, 14, or 30 days. If today’s record is not available yet, the chart ends yesterday; a reported zero still appears.
- **Five usage statistics:** lifetime tokens, peak daily tokens, longest task, longest streak, and current streak.
- **Trends and forecast:** annual token activity, linked daily, weekly and cumulative charts, and comparisons between recorded quota history and extra-reset scenarios.
- **Pet themes:** browse eleven community sources, search and save favorites, preview animations, install locally and manage added pets.
- **Share usage images:** turn the selected date range and statistics into an image to share, save, or copy through the system menu.
- **Messages and reset reminders:** receive announcements in the panel, with countdowns when an exact reset time is announced and optional system notifications.
- **Messages and special activity:** browse announcements and open Tibo’s 28-day challenge from the floating calendar, with records retained after the activity ends.
- **In-app updates:** see your installed version and release notes, then download and install new versions within the app.
- **Your choice of display:** hide the daily usage section or sharing button, or enable launch at login.
- **English and Simplified Chinese:** the interface follows macOS preferred languages; reset dates follow your system time zone and 12 / 24-hour preferences.

Enable **Reset details** under **Usage → Usage assistant → Panel** to see when your available resets expire. Choose **All** or **Upcoming**; upcoming details default to the next 7 days, with 1 / 3 / 7 / 14 / 30-day windows. Resets with the same expiration time are grouped together.

## Main window and usage

The main window has **Usage, Pets, Messages, and General**. The Dock icon appears while the main or activity window is open; closing all windows keeps the app running in the menu bar.

**Usage assistant** places display options around a combined menu-bar and expanded-panel sample. Settings update the preview immediately. The sample is labelled **Sample data preview**; the real menu bar and panel continue to show your account usage. macOS 26 uses native Liquid Glass bottom navigation with dragging; older systems use a compatible style. System motion and transparency preferences are respected.

In **Usage trends**, the annual token calendar is independent of the chart's 30-day, 90-day or one-year range. Hover either view to link dates and inspect exact token counts. Daily and weekly curves render missing buckets at zero, while cumulative curves carry known totals forward. Missing source records are not rewritten, and partial totals show “≥”.

**Usage forecast** shows recorded quota history and a regular curve. Enable **Extra reset (simulation)** and choose a date to compare a hypothetical scenario on the same chart. Limited observations use a labelled budget reference. Simulations do not alter real quota or promise an official reset; past unrecorded readings cannot be recovered.

## Pet themes

Use **Discover, Favorites, Installed, Sources** within **Pets** to browse community themes, search and filter by source, sort by name or popularity, and keep local favorites. Animation previews and v2 look-direction previews are supported. Tag filters are temporarily removed; existing tag descriptions and local metadata are retained.

Choose **Install locally**, review the author, license and destination, then confirm. In Codex settings, open **Pets**, refresh, and choose the companion. Installed themes can be moved to Trash, and replacing a package keeps a recovery copy.

Installed also lists readable Codex cloud pets for the current account. Visible thumbnails load automatically; deleting a cloud pet requires confirmation. Eleven sources are built in after retiring Petdex, with existing pets preserved. Artwork loads on demand and is not bundled.

Buddy and the standalone Codex Pets app keep separate favorites, sources and caches while recognizing the same Codex pet directory.

**General** separates app preferences, updates, app data and traffic statistics. Manage launch at login, system alerts and Beta reception there. Cache cleanup preserves quota history and personal data.

## Messages and updates

See quota-reset notices and other messages in the expanded panel, with times following your Mac’s time zone and regional format. When an exact reset time is officially announced, the message shows that time and a countdown; other messages show their publication time, or a clearly labelled collection time when the original time cannot be verified. Expired messages disappear. Click **×** to dismiss a message temporarily; it returns when you reopen the app if it is still valid.

**Messages** retains a scrollable list of recent announcements, with past notices marked in their time row.

Under **Usage → Usage assistant → Panel**, **Messages** controls receipt and display, with separate Reset reminders and Activity messages choices. **System alerts** in **General** independently pushes the same selected message types to macOS Notification Center. Turning off Messages stops receiving and push alerts, hides activity entries and closes the activity window.

The panel shows messages, quota, reset expiry details and daily tokens in that order. Use **View activity** on an activity message or the **Special activity** calendar in **Messages** to open **Tibo’s 28-day challenge**. Challenge dates follow Pacific time; message timestamps follow your Mac’s time zone. After the challenge ends, its entry leaves the expanded panel, while **Past activity** in **Messages** retains the records. System alerts follow your selected message types; disabling push keeps messages available in the panel.

Under **Messages**, turn **Reset reminders** and **Activity messages** on or off independently. Each type controls receiving, displaying and pushing its content. Turning off Activity messages also closes the activity window. Turning off the master disables both child controls while preserving their choices.

During the campaign, messages and activity records check for updates every five minutes. Opening the activity window or recovering the network triggers a follow-up check. Failed reads retry automatically while keeping saved records.

<img src="docs/images/challenge-en.png" width="720" alt="Tibo’s 28-day challenge: day-by-day progress, improvement details and original-post links" />

Use **Check for updates** under **General → Updates** to see new versions and release notes. Download updates there or from the expanded panel. This stable release uses the notify policy: detection shows a download prompt, and installation requires confirmation.

Beta updates are off by default. Enable **Receive Beta updates** under **General → Updates** to receive Beta releases. With it off, both automatic and manual checks use stable releases only. Turning Beta off does not downgrade the app; a newer installed Beta waits for a later stable release.

Settings shows the last successful update check. Temporary connection failures retry automatically, and failed updates preserve a working version.

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
| Menu bar theme | DuoDuoCat; Ring is available |
| Menu bar display | Reset countdown; percentage is available |
| Daily token usage | On |
| Show sharing button | On |
| Messages | On |
| Reset reminders / Activity messages | Both on; each can be disabled |
| Show reset details | Off; choose All or Upcoming |
| System alerts | Off; enabling requests system notification permission |
| Launch at login | Off |
| Receive Beta updates | Off |

Upgrades preserve your settings. Turning off daily token usage hides the chart and statistics in the lower part of the panel.

## Lightweight and private

A native macOS app with a current download of about **4 MB**. It uses your existing local login to check quota, without reading conversations or project code. Usage images are created on your Mac; you choose when to save or share them.

See the [privacy policy](docs/PRIVACY.md).

## Frequently asked questions

### Which ChatGPT / Codex limits can I see?

Codex usage limits, remaining quota, the next reset time, and available resets provided for your signed-in account. If multiple quota windows are available, choose one in the expanded panel. Missing metrics show “—”. Token counts and quota percentages measure different things.

### Why is data unavailable after signing in?

Check that ChatGPT / Codex is signed in on your Mac, then click the panel's refresh button. If data is still unavailable, check your connection and try updating to the latest version.

### Why did I not receive a message notification?

Enable Messages and the desired types under Panel, enable System alerts and check **System Settings → Notifications → Codex Buddy**. Focus settings, an unavailable connection, quitting the app, or device sleep may affect notifications.

### Are Intel Macs supported?

The current release artifact supports Apple Silicon (arm64) only and requires macOS 13 or later.

### How do I change the interface language?

English and Simplified Chinese follow your macOS preferred language. You can also set an app-specific language in System Settings; relaunch the app to apply it.

## Feedback

Report a problem or suggest a feature in [GitHub Issues](https://github.com/duoduocats/codex-buddy/issues). For security concerns, see [Security reporting](SECURITY.md).

## License

[GPL-3.0-only](LICENSE).
