# Third-Party Notices & Attributions

`ztat` is licensed under the **GNU General Public License v3.0 or later** (`LICENSE`).
It integrates and builds upon the following open-source projects, with full respect for their licenses and trademarks.

---

## 1. Vorssaint (`vorssaint/vorssaint-utils`)
- **Repository**: https://github.com/vorssaint/vorssaint-utils
- **License**: GPL-3.0-or-later (`Copyright (C) 2026 Vorssaint`)
- **Trademark Compliance**: Per upstream `TRADEMARKS.md`, `ztat` uses its own distinct application name (`ztat`), bundle identifier (`dev.ztat.app`), application icon, branding, signing identity, and removes upstream update feeds and telemetry/feedback endpoints.
- **Included Nested Third-Party Code**:
  - `cgif` (`Packages/ZtatVorssaint/RecorderGIFCodec/vendor/cgif`): MIT License, Copyright (c) 2021 Daniel Löbl.

## 2. Status Trio (`lingyired/status-trio`)
- **Repository**: https://github.com/lingyired/status-trio
- **License**: Apache License 2.0 (`Copyright 2026 lingyired`)
- **Modifications in `ztat`**: Adapted as `ZtatStatusTrio` to provide `ztat`'s primary unified menu bar status icon and native Liquid Glass hub panel container (`ZtatHubPanelContentProviding`), with Sparkle and upstream telemetry removed and rendering/hover/charging-cache performance optimizations applied.
- **Included Nested Third-Party Code**:
  - `AppleSiliconDDC` (`Packages/ZtatStatusTrio/DDCPrivateAPI`): MIT License.
  - `AirPodsAudioContext` (`Packages/ZtatStatusTrio/AirPodsAudioContext`): Upstream license preserved in directory.

## 3. Stats (`exelban/stats`)
- **Repository**: https://github.com/exelban/stats
- **License**: MIT License (`Copyright (c) 2019-2026 Serhiy Mytrovtsiy`)
- **Modifications in `ztat`**: Ported to pure Swift Package Manager (`Packages/ZtatStats`) for Xcode-free Apple CLT compilation, with LevelDB replaced by lightweight pure-Swift storage, `Store` isolated to a dedicated `UserDefaults` suite, remote/cloud/updater stripped, and CPU/startup/redraw optimizations applied.

## 4. BudHold Feature Inspiration (`budwk/budhold`)
- **Repository**: https://github.com/budwk/budhold
- **License Note**: Upstream repository carries no open-source license file (`Copyright © 2026 BudWK. All rights reserved.`).
- **Implementation**: **No source code or assets from `budhold` are copied into `ztat`.** `Packages/ZtatPowerGuard` (including the `ztat-hold` CLI target) is an original clean-room GPL-3.0-or-later implementation inspired by the clamshell keep-awake / physical 0% blackout / framebuffer guard workflow, built on public macOS IOKit/CoreGraphics APIs and Vorssaint's GPL-3.0 keep-awake foundation.
