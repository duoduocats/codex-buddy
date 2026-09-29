# Codex Buddy development

- Repository: duoduocats/codex-buddy. Bundle identifier: com.duoduocat.codexbuddy.
- Native AppKit/SwiftUI/URLSession only. Keep package lightweight; no bundled Codex CLI.
- Never read/copy local credentials into source, tests, screenshots, fixtures, releases or logs. Tests use synthetic data.
- User approval gate: build and install locally first. Wait for the user to explicitly confirm the local result before pushing, opening a PR, merging, tagging, or publishing a Release. This applies to every future change.
- Ordinary changes: feature/fix branch → tests/build → PR → merge main → version tag → draft Release → review and publish.
- Release policy is maintainer-selected metadata: none (default), notify, or silent. Set notify/silent only when explicitly requested for that release; never infer from its version number.
- Silent releases install without confirmation. Honor previously ignored releases during background checks; verify origin, metadata digest and version, and package integrity before replacing. Never block continued use after failure.
- Run `bash scripts/test.sh` and `BUILD_DIR=<fresh-temp-directory> bash build.sh` for code changes. Installer changes require staged-install/rollback tests.
- `scripts/prepare-release.py VERSION` prepares ordinary releases; use `--mode notify` or `--mode silent` only when explicitly requested.
- Publish only this repository directory. Do not publish parent workspace, personal metadata, credential stores or local debug captures.
- Preserve GPL-3.0-only licensing and THIRD_PARTY_NOTICES.md.
