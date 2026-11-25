// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { ZtatAppDelegate() }
app.delegate = delegate
app.run()
