# 质量与发布审计 / Quality and release audit

## 自动门禁 / Automated gates

| Area | Gate |
| --- | --- |
| Availability | Quota decoding, missing data, extreme timestamps; synthetic success/401/403/429/500/timeout/offline/malformed-response/missing-credentials tests; version comparison and update notification policy |
| Recovery | Disposable installer tests for success, replacement failure, and launch-command failure |
| Update package | Real DMG fixture download, SHA-256, read-only mount, app identity/version, signature, tamper rejection |
| Resource use | Single-flight requests, bounded timeouts, failure backoff (60–960 seconds), timer tolerance, cached menu image |
| Size | App < 4,000,000 bytes; DMG < 5,000,000 bytes; exactly seven shipping files; arm64; no bundled CLI/runtime |
| Privacy | Working files + all reachable Git history scan; secret/path patterns; PNG metadata; decoded PDF streams/text/metadata; credential/log/database filenames; symlinks |
| Scanner regression | Synthetic secrets only; checks detection and prevents printing secret values |
| Native UI | Demo-only status item, panel open/close, settings smoke test on a GUI Mac |

Run `bash scripts/test.sh`, `python3 scripts/check-source.py --history`, then `bash scripts/package.sh`. GitHub CI builds and audits the actual app; Release also stages the real DMG in an isolated temporary directory. Never publish the parent workspace.

## 本机性能复核 / Local performance check

Launch the built executable with `--performance-check` for a 60-second synthetic idle sample. It does not load local credentials or check updates. Output contains CPU and peak resident memory only. Use `--ui-check` for native UI smoke tests; screenshots use `--snapshot` with synthetic data.

A short idle sample is not a long-running soak test or a measurement of every Mac. Investigate sustained idle CPU above 1%, repeated memory growth, unexpected child processes, and repeated requests. Repeat after significant drawing, timer, or networking changes. Timer tolerance follows [Apple energy guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html).

## 发布前仍需人工验证 / Manual release matrix

- macOS 13 fallback material and macOS 26+ Liquid Glass on real systems; multiple displays, scale factors, full-screen spaces, light/dark appearance.
- System locale, timezone, 12/24-hour format, accessibility/VoiceOver, login-item registration and approval.
- Sleep/wake, Wi-Fi loss/recovery, expired authentication, GitHub throttling/outages, long-running memory stability.
- Real published-release download/relaunch, read-only installation, insufficient storage, user cancellation. Fixtures do not prove live GitHub connectivity.
- Installer rollback covers a failing launch command. `open` success does not prove the relaunched application remains healthy; post-launch crash recovery is not yet implemented.
- Current releases are ad hoc signed, not Apple-notarized. Digest and ad hoc verification do not authenticate an independent publisher. A future Developer ID/notarization workflow needs separate setup.
- ChatGPT quota endpoint behavior is an external dependency and can change. No absolute availability or zero-leak guarantee is claimed.

## 公开内容 / Public content

Use only synthetic screenshots. Review README, release notes, package contents, commit author/committer addresses, and metadata before publishing. Automated pattern scans cannot identify every possible personal detail. The chosen public GitHub account and noreply identity are intentional. English and Simplified Chinese documentation and UI are available; the UI follows macOS preferred languages.

## 2.0.0 本机结果 / Local results (2026-10-01)

Apple Silicon, macOS 27.0. Tests use synthetic data and do not load credentials. CPU values are process CPU time divided by elapsed wall time, with 100% representing one fully occupied core. Native layout/display is forced during pressure tests even while the desktop is locked.

| 场景 / Scenario | Duration | Average CPU | Operations |
| --- | ---: | ---: | ---: |
| 关闭面板 / Idle, panel closed | 62.3 s | 0.107% | 0 |
| 面板展开静置 / Idle, panel open | 60.9 s | 0.093% | 0 |
| 日期悬停压力 / Selection changes at 20 Hz | 30.2 s | 7.298% | 604 |
| 日期范围切换 / Range changes at 2 Hz | 30.0 s | 4.353% | 60 |
| 面板开关 / Panel toggles at 2 Hz | 30.0 s | 2.624% | 60 |

The same 20 Hz selection workload used 22.135% CPU before isolating hover state, and 7.298% afterward: about 67% less. The chart remains smooth; selection updates only its overlay. Peak resident memory across the final scenarios was 90.6 MiB. A separate check of the actual shipping executable (`--performance-check`) measured 0.24% average CPU over 61.6 seconds and 86.5 MiB peak RSS; its startup costs are not warmed out in the same way as the harness.

- Local signed app: **1,886,047 bytes (1.89 MB)**, seven files. Final local DMG: **1,689,504 bytes (1.69 MB)** including a 160,580-byte bilingual illustrated guide and a 42,710-byte Retina background. Compiler versions can slightly change CI artifact sizes.
- `-Osize`, removal of nonessential local symbols and lossless icon PNG compression reduced size while retaining every icon resolution and pixel. No CLI, runtime, font files or packaging dependencies are bundled.
- Native unit/integration/export tests, endpoint tooltip fixtures, installed-bundle checks, real DMG staging/tamper rejection and replacement/rollback scenarios passed.
- Source and reachable Git history passed known secret/home-path checks; commit identities use the chosen public GitHub account and noreply address. All new PNG metadata was removed. Extended file attributes are scanned too; copying excludes inherited source URLs, and public assets are rebuilt on GitHub runners. macOS may still add its protected system provenance marker. Seven PDF streams, decoded Unicode text and metadata passed bounded privacy decoding; compressed-secret regression cases passed.

[Reproducible native benchmark](../scripts/benchmark-native.sh) · [Machine-readable measurements](results/performance-2.0.0.json)

```sh
BENCHMARK_BUILD_DIR="$(mktemp -d /private/tmp/buddy-benchmark.XXXXXX)" \
  bash scripts/benchmark-native.sh --idle-seconds 60 --stress-seconds 30 --output /tmp/buddy-performance.json
```

These short runs exclude live requests, real pointer input and WindowServer/GPU costs. They do not prove long-term reliability or identical performance on every Mac. The desktop was subsequently unlocked: the revised 2.0.1 installer background and filename layout, and both installation-guide pages, were reviewed in Finder. Ordinary pointer hover remains a manual check; mounted-DMG layout checks and native component/window tests passed. Other manual gates above remain applicable.
