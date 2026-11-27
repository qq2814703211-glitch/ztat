// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Lightweight CoreGraphics fullscreen window detector replacing MacroVisionKit package.

import AppKit
import CoreGraphics
import Foundation

final class ZtatFullscreenDetector {
    struct Configuration {
        var includeSystemApps: Bool = true
    }

    struct FullscreenWindowInfo {
        let screen: NSScreen
        let bundleIdentifier: String?
        let processId: pid_t
    }

    static let shared = ZtatFullscreenDetector()
    var configuration = Configuration()

    private init() {}

    func detectFullscreenApps(debug: Bool = false) -> [FullscreenWindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        let primaryMaxY = screens.first?.frame.maxY ?? 0
        let selfPID = ProcessInfo.processInfo.processIdentifier

        var results: [FullscreenWindowInfo] = []
        var seenPairs: Set<String> = []

        for entry in windowList {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }

            // Convert CG top-left origin rect to AppKit bottom-left origin rect
            let appKitRect = NSRect(
                x: cgRect.origin.x,
                y: primaryMaxY - cgRect.origin.y - cgRect.height,
                width: cgRect.width,
                height: cgRect.height
            )

            let tolerance: CGFloat = 6
            guard let matchedScreen = screens.first(where: { screen in
                abs(appKitRect.origin.x - screen.frame.origin.x) <= tolerance &&
                abs(appKitRect.width - screen.frame.width) <= tolerance &&
                appKitRect.height >= screen.frame.height - (screen.safeAreaInsets.top + 12)
            }) else {
                continue
            }

            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = app?.bundleIdentifier
            if !configuration.includeSystemApps, let bundleID, bundleID.hasPrefix("com.apple.") {
                continue
            }

            let key = "\(matchedScreen.localizedName):\(pid)"
            if seenPairs.insert(key).inserted {
                results.append(FullscreenWindowInfo(
                    screen: matchedScreen,
                    bundleIdentifier: bundleID,
                    processId: pid
                ))
            }
        }

        return results
    }
}
