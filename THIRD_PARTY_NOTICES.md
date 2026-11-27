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

## 5. Atoll (`Ebullioscopic/Atoll`)
- **Repository**: https://github.com/Ebullioscopic/Atoll
- **License**: GNU General Public License v3.0 (`Copyright (C) 2024-2026 Atoll Contributors`; includes software derived from `boring.notch` GPL-3.0 and `rtaudio` audio DSP)
- **Modifications in `ztat`**: Ported to pure Swift Package Manager (`Packages/ZtatIsland`) for Xcode-free Apple CLT compilation, replacing Vorssaint's Dynamic Island implementation (`notch*`). Rebranded for `ztat`, isolated to `dev.ztat.app.island` UserDefaults suite, embedded natively into `ztat`'s unified Settings & Hub without a separate menu bar icon or Sparkle updater, bridged Keep-Awake controls to `ZtatPowerGuardRegistry`, and optimized idle observers/subprocesses/teardown.
- **Included / Resolved Third-Party Packages**:
  - `Defaults` & `KeyboardShortcuts` (Sindre Sorhus): MIT License.
  - `SwiftTerm` (Miguel de Icaza): MIT License.
  - `lottie-ios` (Airbnb): Apache License 2.0.
  - `AtollExtensionKit` (Ebullioscopic): Upstream open-source license.
  - `FingerprintScan.json` animation by Eddy Gann: Lottie Simple License.

## 6. Pearcleaner Feature Inspiration (`alienator88/Pearcleaner`)
- **Repository**: https://github.com/alienator88/Pearcleaner
- **License Note**: Upstream v5.x is licensed under Apache 2.0 with Commons Clause v1.0, which is incompatible with `GPL-3.0-or-later`.
- **Implementation**: **No source code or assets from `Pearcleaner` are copied into `ztat`.** `Packages/ZtatCleaner` is an original clean-room GPL-3.0-or-later implementation inspired by Pearcleaner's macOS app uninstaller, orphan finder, Mach-O universal binary slimmer, translation pruner, developer environment cleaner, PKG/receipts, plugins, launch services, file search, delete history, and trash-sentinel workflows, built strictly on public macOS frameworks (`AppKit`, `SwiftUI`, `CoreServices`, `Security`, `SQLite3`).

## 7. Vitals Telemetry & Activity Monitor Feature Inspiration
- **Implementation**: **No proprietary code or assets are copied.** `Packages/ZtatStats/Sources/ZtatStatsHost/Vitals*.swift`, `ZtatTaskManagerView.swift`, and `Sources/ZtatApp/ZtatTaskManagerWindow.swift` are original clean-room GPL-3.0-or-later implementations built on public macOS / Darwin / IOKit / Mach telemetry APIs.
