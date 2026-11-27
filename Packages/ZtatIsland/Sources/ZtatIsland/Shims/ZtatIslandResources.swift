// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Unified resource & flat-asset resolver for ZtatIsland under pure SwiftPM (no actool).

import AppKit
import Foundation
import SwiftUI

enum ZtatIslandResources {
    static var bundle: Bundle {
        Bundle.module
    }

    static func imageURL(named name: String) -> URL? {
        let extensions = ["png", "jpeg", "jpg", "svg", "pdf"]
        for ext in extensions {
            if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Images") {
                return url
            }
            if let url = Bundle.module.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    static func nsImage(named name: String) -> NSImage? {
        if let url = imageURL(named: name), let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: name)
    }

    static func swiftUIImage(named name: String) -> Image {
        if let ns = nsImage(named: name) {
            return Image(nsImage: ns)
        }
        return Image(name)
    }

    static func audioURL(named name: String, ext: String) -> URL? {
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Audio") {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    static func lottieURL(named name: String) -> URL? {
        let clean = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        if let url = Bundle.module.url(forResource: clean, withExtension: "json", subdirectory: "Lottie") {
            return url
        }
        if let url = Bundle.module.url(forResource: clean, withExtension: "json") {
            return url
        }
        return Bundle.main.url(forResource: clean, withExtension: "json")
    }

    /// Resolves local Lottie file URLs, transparently migrating stale `/Applications/Atoll.app`
    /// or non-active `ztat.app` bundle URLs into `ZtatIsland`'s active SwiftPM resource bundle.
    static func resolveLottieURL(_ url: URL) -> URL {
        if url.isFileURL {
            let currentBundlePrefix = Bundle.main.bundleURL.standardizedFileURL.path
            let isStaleBundlePath = url.path.contains("/Atoll.app/")
                || (url.path.contains("ZtatIsland_ZtatIsland.bundle") && !url.standardizedFileURL.path.hasPrefix(currentBundlePrefix))
            if isStaleBundlePath || !FileManager.default.fileExists(atPath: url.path) {
                let fileName = url.lastPathComponent
                if let bundled = lottieURL(named: fileName) {
                    return bundled
                }
            }
        }
        return url
    }

    static func pricingJSONURL() -> URL? {
        Bundle.module.url(forResource: "pricing", withExtension: "json")
            ?? Bundle.main.url(forResource: "pricing", withExtension: "json")
    }

    static func mediaRemoteAdapterScriptURL() -> URL? {
        Bundle.module.url(forResource: "mediaremote-adapter", withExtension: "pl")
            ?? Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
    }

    static func mediaRemoteAdapterFrameworkURL() -> URL? {
        if let mainRes = Bundle.main.resourceURL {
            let candidate = mainRes.appendingPathComponent("MediaRemoteAdapter.framework")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        if let modRes = Bundle.module.resourceURL {
            let candidate = modRes.appendingPathComponent("MediaRemoteAdapter.framework")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func nowPlayingTestClientURL() -> URL? {
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/NowPlayingTestClient", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }
}
