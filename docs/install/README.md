# Installer assets

The DMG includes `安装指南 Installation Guide.pdf`, a two-page illustrated guide
in Chinese and English. Its diagrams are schematic and contain no user data.
The guide describes approving the first launch of this unnotarized release in
System Settings, following [Apple's instructions](https://support.apple.com/en-us/102445).

`dmg-background.png` is a Retina background for a 720 × 540 point Finder window.
Finder displays the actual app, the Applications shortcut, and the PDF over it.
`scripts/configure-dmg.py` writes their positions and background alias directly
to `.DS_Store`; packaging does not automate Finder or change security settings.

## Recreate the assets on macOS

Use a build-only Python environment:

```sh
python3 -m venv /tmp/codex-buddy-packaging
source /tmp/codex-buddy-packaging/bin/activate
python3 -m pip install -r scripts/requirements-installer-assets.txt
python3 scripts/create-installer-assets.py
bash scripts/package.sh
```

Packaging the committed assets only needs `scripts/requirements-packaging.txt`
(ds_store, mac_alias, pypdf). Pillow and ReportLab are needed only to regenerate
the assets.

The generator uses the existing app icon and macOS system fonts. The PDF embeds
only the glyphs it needs. Python, its packages, and font files are not bundled in
the application. The background PNG contains no user metadata.

`scripts/check-package.py` mounts the final DMG read-only and checks the install
destination, layout, PDF, package size, app identity/signature, exact app contents,
and sensitive patterns. The PDF gate parses every object, decodes its streams
with bounded ASCII85/Flate decoding, and scans Unicode text and metadata. Unknown
encodings fail the gate. Run `python3 scripts/test-pdf-privacy.py` to check its
compressed-data regression cases. Changing the installer also requires the staged install
and rollback tests in `scripts/test.sh`.
