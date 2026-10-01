# Codex Buddy 2.0.1 native UI review

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

The unlocked desktop was reviewed on macOS 27 after publication. Both installation guide pages were opened in Finder Quick Look and remained readable. The first DMG layout exposed a content-height issue: selecting the guide scrolled the background and obscured the title. The revised local installer uses a 720 × 600-point outer frame for the 720 × 540-point content canvas. Its title, app/Applications icons, and two-line bilingual guide filename fit with the user’s path bar visible; selecting the guide does not create a scroll bar. The revised installer was reviewed locally and approved for publication. The app and Applications filename labels fit within the enlarged white tiles with bottom padding.

A live window using the unchanged production chart was inspected with synthetic long endpoint values. Automated click/drag input did not establish ordinary pointer-hover behavior; the measured tooltip fixtures and placement tests remain the evidence for endpoint labels. Real pointer interaction, macOS 13 fallback material, multiple displays, sleep/wake and long-running network behavior remain in the manual matrix in [QUALITY](docs/QUALITY.md).
