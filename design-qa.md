# Codex Buddy 2.0.0 native UI review

## Reviewed surfaces

- [Chinese menu bar and panel](docs/images/overview-zh.png), [English menu bar and panel](docs/images/overview-en.png): production views with fixed synthetic data, combined with a clean menu bar preview. These are native component renders, not captures of a user's account.
- [Chinese settings](docs/images/settings-zh.png), [English settings](docs/images/settings-en.png): production settings with native controls and the existing application icon.
- [Theme comparison](docs/images/themes.png): Ring and DuoDuoCat, countdown and percentage. Both themes use the same 21-point visible menu height, centered in a 24-point canvas.
- [Bilingual installation guide](docs/install/Installation-Guide.pdf): both rendered pages were inspected. Diagrams are explicitly schematic; buttons and routes follow Apple's current instructions.

## Visual findings

Labels, numbers, chart axes and five equal-width metrics fit in both languages. The panel retains the circular quota illustration and the app's smooth cat mascot. The menu bar cat outline and four dots share a common stroke/diameter and five equal edge gaps along a flattened lower curve. Settings retain equal-width segments and aligned switches.

The chart tooltip is measured and clamped inside the plot with a four-point margin. After the rendering optimization, native endpoint fixtures for 7/14/30 days retain complete long-value labels. Hover state is owned by a child overlay; chart marks and axes are static during selection changes.

## Functional evidence

The complete native test suite covers localization, defaults and retained preferences, geometry, missing-day zeros, range selection, image export/save/isolated clipboard, sixteen tooltip placement cases, network failures and updater/installer recovery. The shipping binary's native smoke check opened the status panel and settings and closed the panel successfully. Real DMG checksum, mount, identity/signature, staging and tamper rejection passed.

PNG metadata is removed by the reproducible screenshot generator. The installation PDF's seven streams, Unicode text and metadata are scanned with bounded decoding. All figures use synthetic data.

## Manual limits

The desktop was locked during the final review. Component renders and native window smoke tests do not establish real pointer interaction or Finder's final on-screen background scaling. The DMG background alias, icon positions, dimensions and install target were checked from the mounted image. macOS 13 fallback material, multiple displays, sleep/wake and long-running network behavior remain in the manual matrix in [QUALITY](docs/QUALITY.md).
