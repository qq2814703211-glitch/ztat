// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Bundle.module-first resource lookup helper for SwiftPM VorssaintToolbox library.

import Foundation

enum VorssaintResources {
    /// Looks up a bundled resource in `Bundle.module` first (both root and `Resources/`),
    /// then falls back to `Bundle.main`.
    static func url(forResource name: String,
                    withExtension ext: String?,
                    subdirectory: String? = nil) -> URL? {
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return url
        }
        if subdirectory == nil,
           let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }

    /// Resolves the dynamic Now Playing adapter library loaded by `/usr/bin/perl`.
    /// Checks `ZtatApp`'s `Contents/Frameworks` first (`libZtatNowPlayingAdapter.dylib` or legacy
    /// `libVorssaintNowPlaying.dylib`), then falls back to sibling directories of the executable for dev runs.
    static func nowPlayingAdapterLibraryURL() -> URL? {
        let fm = FileManager.default
        let names = ["libZtatNowPlayingAdapter.dylib", "libVorssaintNowPlaying.dylib"]
        var searchDirs: [URL] = []
        if let frameworks = Bundle.main.privateFrameworksURL {
            searchDirs.append(frameworks)
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            searchDirs.append(execDir)
            searchDirs.append(execDir.appendingPathComponent("../Frameworks", isDirectory: true).standardizedFileURL)
        }
        for dir in searchDirs {
            for name in names {
                let candidate = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
