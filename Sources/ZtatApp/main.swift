// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import VorssaintToolbox

// CRITICAL: Handle detached cleanup helper arguments (e.g. `--mouse-acceleration-cleanup`)
// BEFORE launching NSApplication so cleanup helpers restore state and exit cleanly.
ZtatVorssaintHost.handleStartupHelperArgumentsIfNeeded()

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { ZtatAppDelegate() }
app.delegate = delegate
app.run()
