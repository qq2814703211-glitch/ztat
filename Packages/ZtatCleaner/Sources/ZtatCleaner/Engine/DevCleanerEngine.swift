// SPDX-License-Identifier: GPL-3.0-or-later
// Developer Environment Cleaner: 26 toolchain cache presets, Delete Folder vs Delete Contents,
// IDE Orphaned Workspace Storage scanner (VS Code / Cursor / Zed), and Pip package manager.

import Foundation
import ZtatCore

public final class DevCleanerEngine: @unchecked Sendable {
    public static let shared = DevCleanerEngine()

    private init() {}

    private struct ToolchainSpec {
        let id: String
        let name: String
        let symbol: String
        let patterns: [(label: String, pattern: String)]
    }

    private static let specs: [ToolchainSpec] = [
        ToolchainSpec(id: "xcode", name: "Xcode & Simulators", symbol: "hammer.fill", patterns: [
            ("DerivedData", "~/Library/Developer/Xcode/DerivedData"),
            ("Archives", "~/Library/Developer/Xcode/Archives"),
            ("iOS DeviceSupport", "~/Library/Developer/Xcode/iOS DeviceSupport"),
            ("watchOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport"),
            ("tvOS DeviceSupport", "~/Library/Developer/Xcode/tvOS DeviceSupport"),
            ("macOS DeviceSupport", "~/Library/Developer/Xcode/macOS DeviceSupport"),
            ("Documentation Cache", "~/Library/Developer/Xcode/DocumentationCache"),
            ("Developer Disk Images", "~/Library/Developer/DeveloperDiskImages"),
            ("CoreSimulator Caches", "~/Library/Developer/CoreSimulator/Caches"),
            ("CoreSimulator Devices", "~/Library/Developer/CoreSimulator/Devices"),
            ("xcodebuild Cache", "~/Library/Caches/com.apple.dt.xcodebuild"),
            ("Xcode Cache", "~/Library/Caches/com.apple.dt.Xcode")
        ]),
        ToolchainSpec(id: "swiftpm", name: "Swift / SwiftPM", symbol: "swift", patterns: [
            ("SwiftPM Cache", "~/Library/Caches/org.swift.swiftpm"),
            ("SwiftPM Config & State", "~/.swiftpm")
        ]),
        ToolchainSpec(id: "cocoapods", name: "CocoaPods", symbol: "shippingbox", patterns: [
            ("CocoaPods Cache", "~/Library/Caches/CocoaPods"),
            ("CocoaPods Repos", "~/.cocoapods/repos")
        ]),
        ToolchainSpec(id: "carthage", name: "Carthage", symbol: "cube", patterns: [
            ("Carthage Cache", "~/Library/Caches/org.carthage.CarthageKit"),
            ("Carthage Root", "~/Carthage")
        ]),
        ToolchainSpec(id: "homebrew", name: "Homebrew Cache", symbol: "mug.fill", patterns: [
            ("Homebrew Download Cache", "~/Library/Caches/Homebrew")
        ]),
        ToolchainSpec(id: "cargo", name: "Rust / Cargo", symbol: "gearshape.2", patterns: [
            ("Cargo Registry Cache", "~/.cargo/registry"),
            ("Cargo Git Checkouts", "~/.cargo/git")
        ]),
        ToolchainSpec(id: "node", name: "Node / npm / pnpm / Bun", symbol: "terminal.fill", patterns: [
            ("npm Cache", "~/.npm"),
            ("pnpm Store", "~/Library/pnpm/store"),
            ("pnpm Cache", "~/Library/Caches/pnpm"),
            ("Bun Install Cache", "~/.bun/install/cache"),
            ("NVM Node Versions", "~/.nvm/versions/node/*")
        ]),
        ToolchainSpec(id: "yarn", name: "Yarn", symbol: "tray.full", patterns: [
            ("Yarn Cache", "~/Library/Caches/Yarn"),
            ("Yarn Dot Cache", "~/.cache/yarn"),
            ("Yarn Legacy Cache", "~/.yarn-cache")
        ]),
        ToolchainSpec(id: "deno", name: "Deno", symbol: "bolt.horizontal", patterns: [
            ("Deno Cache", "~/Library/Caches/deno")
        ]),
        ToolchainSpec(id: "pip", name: "Python / pip", symbol: "chevron.left.forwardslash.chevron.right", patterns: [
            ("pip Cache", "~/Library/Caches/pip")
        ]),
        ToolchainSpec(id: "uv", name: "Python / uv", symbol: "hare", patterns: [
            ("uv Cache", "~/.cache/uv"),
            ("uv Local Share", "~/.local/share/uv")
        ]),
        ToolchainSpec(id: "poetry", name: "Python / Poetry", symbol: "book", patterns: [
            ("Poetry Cache", "~/Library/Caches/pypoetry"),
            ("Poetry Support", "~/Library/Application Support/pypoetry")
        ]),
        ToolchainSpec(id: "conda", name: "Conda / Anaconda", symbol: "circle.hexagongrid", patterns: [
            ("Conda Packages Cache", "~/.conda/pkgs"),
            ("Anaconda3 Pkgs", "~/anaconda3/pkgs"),
            ("Miniconda3 Pkgs", "~/miniconda3/pkgs")
        ]),
        ToolchainSpec(id: "pyenv", name: "Pyenv", symbol: "slider.vertical.3", patterns: [
            ("Pyenv Cache", "~/.pyenv/cache"),
            ("Pyenv Versions", "~/.pyenv/versions/*")
        ]),
        ToolchainSpec(id: "go", name: "Go Modules", symbol: "hare.fill", patterns: [
            ("Go Module Cache", "~/go/pkg/mod"),
            ("Go Build Cache", "~/Library/Caches/go-build")
        ]),
        ToolchainSpec(id: "gradle", name: "Gradle", symbol: "wrench.and.screwdriver", patterns: [
            ("Gradle Caches", "~/.gradle/caches"),
            ("Gradle Wrapper Dists", "~/.gradle/wrapper/dists")
        ]),
        ToolchainSpec(id: "maven", name: "Maven", symbol: "archivebox", patterns: [
            ("Maven Repository", "~/.m2/repository")
        ]),
        ToolchainSpec(id: "android", name: "Android Studio", symbol: "iphone", patterns: [
            ("Android Studio Cache", "~/Library/Caches/Google/AndroidStudio*"),
            ("Android Studio Logs", "~/Library/Logs/Google/AndroidStudio*"),
            ("Android Build Cache", "~/.android/build-cache"),
            ("Android Cache", "~/.android/cache")
        ]),
        ToolchainSpec(id: "jetbrains", name: "JetBrains IDEs", symbol: "macwindow.on.rectangle", patterns: [
            ("JetBrains Caches", "~/Library/Caches/JetBrains/*"),
            ("JetBrains Logs", "~/Library/Logs/JetBrains/*")
        ]),
        ToolchainSpec(id: "vscode", name: "VS Code", symbol: "doc.text.magnifyingglass", patterns: [
            ("VS Code Cache", "~/Library/Application Support/Code/Cache"),
            ("VS Code CachedData", "~/Library/Application Support/Code/CachedData"),
            ("VS Code CachedExtensionVSIXs", "~/Library/Application Support/Code/CachedExtensionVSIXs"),
            ("VS Code Code Cache", "~/Library/Application Support/Code/Code Cache"),
            ("VS Code GPUCache", "~/Library/Application Support/Code/GPUCache")
        ]),
        ToolchainSpec(id: "cursor", name: "Cursor", symbol: "cursorarrow.rays", patterns: [
            ("Cursor Cache", "~/Library/Application Support/Cursor/Cache"),
            ("Cursor CachedData", "~/Library/Application Support/Cursor/CachedData"),
            ("Cursor CachedExtensionVSIXs", "~/Library/Application Support/Cursor/CachedExtensionVSIXs"),
            ("Cursor Code Cache", "~/Library/Application Support/Cursor/Code Cache"),
            ("Cursor GPUCache", "~/Library/Application Support/Cursor/GPUCache")
        ]),
        ToolchainSpec(id: "zed", name: "Zed", symbol: "bolt", patterns: [
            ("Zed Cache", "~/Library/Caches/Zed"),
            ("Zed Node Cache", "~/Library/Application Support/Zed/node/cache")
        ]),
        ToolchainSpec(id: "flutter", name: "Flutter / Dart Pub", symbol: "wind", patterns: [
            ("Pub Cache", "~/.pub-cache"),
            ("Flutter Engine Cache", "~/Library/Caches/flutter_engine")
        ]),
        ToolchainSpec(id: "ruby", name: "Ruby Gems", symbol: "diamond", patterns: [
            ("Ruby Gems Cache", "~/.gem/ruby/*")
        ]),
        ToolchainSpec(id: "composer", name: "PHP Composer", symbol: "music.note.list", patterns: [
            ("Composer Cache", "~/.composer/cache"),
            ("Composer Library Cache", "~/Library/Caches/composer")
        ]),
        ToolchainSpec(id: "stack", name: "Haskell Stack & Nix", symbol: "function", patterns: [
            ("Haskell Stack Snapshots", "~/.stack/snapshots"),
            ("Nix User Cache", "~/.cache/nix")
        ]),
        ToolchainSpec(id: "docker", name: "Docker & Containers", symbol: "shippingbox.fill", patterns: [
            ("Docker BuildX Cache", "~/.docker/buildx")
        ])
    ]

    public func scanToolchains() async -> [DevToolchainGroup] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var groups: [DevToolchainGroup] = []

            for spec in Self.specs {
                if Task.isCancelled { break }
                var items: [DevPathItem] = []
                for entry in spec.patterns {
                    let expandedURLs = self.expandPattern(entry.pattern)
                    for url in expandedURLs {
                        guard fm.fileExists(atPath: url.path) else { continue }
                        if self.isEffectivelyEmpty(url) { continue }
                        let size = SafeDeletionEngine.logicalSize(of: url)
                        guard size > 0 else { continue }
                        let suffix = expandedURLs.count > 1 ? " (\(url.lastPathComponent))" : ""
                        items.append(DevPathItem(
                            id: url.standardizedFileURL.path,
                            toolchainID: spec.id,
                            label: entry.label + suffix,
                            url: url.standardizedFileURL,
                            size: size,
                            isSelected: false
                        ))
                    }
                }
                if !items.isEmpty {
                    items.sort { $0.size > $1.size }
                    groups.append(DevToolchainGroup(
                        id: spec.id,
                        name: spec.name,
                        symbolName: spec.symbol,
                        items: items
                    ))
                }
            }
            return groups.sorted { $0.totalSize > $1.totalSize }
        }.value
    }

    /// Expands trailing `/*` or wildcard directory names safely without invoking a shell.
    private func expandPattern(_ rawPattern: String) -> [URL] {
        let fm = FileManager.default
        let expanded = (rawPattern as NSString).expandingTildeInPath
        guard expanded.contains("*") else {
            return [URL(fileURLWithPath: expanded)]
        }
        let parentPath = (expanded as NSString).deletingLastPathComponent
        let globName = (expanded as NSString).lastPathComponent
        let parentURL = URL(fileURLWithPath: parentPath, isDirectory: true)
        guard let children = try? fm.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        if globName == "*" {
            return children
        }
        let prefix = globName.replacingOccurrences(of: "*", with: "")
        return children.filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private func isEffectivelyEmpty(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return true }
        if !isDir.boolValue { return false }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return true }
        return entries.filter { $0 != ".DS_Store" }.isEmpty
    }

    /// Deletes either the folders themselves or only their immediate children (preserving parent container).
    public func cleanDevItems(
        _ items: [DevPathItem],
        contentsOnly: Bool,
        onLog: (@Sendable (String, Bool) -> Void)? = nil
    ) async -> SafeDeletionOutcome {
        let fm = FileManager.default
        var targetURLs: [URL] = []
        if contentsOnly {
            for item in items {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.url.path, isDirectory: &isDir), isDir.boolValue,
                   let children = try? fm.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil, options: []) {
                    targetURLs.append(contentsOf: children.filter { $0.lastPathComponent != ".DS_Store" })
                } else {
                    targetURLs.append(item.url)
                }
            }
        } else {
            targetURLs = items.map(\.url)
        }
        return await SafeDeletionEngine.shared.trashItems(
            urls: targetURLs,
            bundleLabel: contentsOnly ? "DevCache_Contents" : "DevCache_Folders",
            sourceModule: "developer",
            onLog: onLog
        )
    }

    // MARK: - IDE Orphaned Workspace Storage Scanner (VS Code, Cursor, Zed)

    public func scanOrphanedIDEWorkspaces() async -> [OrphanedIDEWorkspace] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let home = NSHomeDirectory()
            let roots: [(ide: String, path: String)] = [
                ("VS Code", "\(home)/Library/Application Support/Code/User/workspaceStorage"),
                ("VS Code Insiders", "\(home)/Library/Application Support/Code - Insiders/User/workspaceStorage"),
                ("Cursor", "\(home)/Library/Application Support/Cursor/User/workspaceStorage"),
                ("Zed", "\(home)/Library/Application Support/Zed/workspaces")
            ]

            var found: [OrphanedIDEWorkspace] = []
            for entry in roots {
                let rootURL = URL(fileURLWithPath: entry.path, isDirectory: true)
                guard let subdirs = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                    continue
                }
                for dir in subdirs {
                    let wsJSON = dir.appendingPathComponent("workspace.json")
                    guard let data = try? Data(contentsOf: wsJSON),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let folderURI = obj["folder"] as? String,
                          folderURI.hasPrefix("file://"),
                          let targetURL = URL(string: folderURI) else {
                        continue
                    }
                    let targetPath = targetURL.path
                    if !fm.fileExists(atPath: targetPath) {
                        let size = SafeDeletionEngine.logicalSize(of: dir)
                        found.append(OrphanedIDEWorkspace(
                            id: dir.standardizedFileURL.path,
                            ideName: entry.ide,
                            storageURL: dir.standardizedFileURL,
                            missingProjectPath: targetPath.replacingOccurrences(of: home, with: "~"),
                            size: size,
                            isSelected: false
                        ))
                    }
                }
            }
            return found.sorted { $0.size > $1.size }
        }.value
    }

    // MARK: - Interactive Python Pip Package Manager

    /// Real interpreters, preferred over the `/usr/bin/python3` shim.
    private static let python3Candidates = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"
    ]

    public func resolvePython3Path() -> String? {
        let fm = FileManager.default
        if let real = Self.python3Candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return real
        }
        // `/usr/bin/python3` is only a shim: without Command Line Tools (or Xcode) it pops the
        // "install developer tools" dialog instead of running Python.
        return Self.developerToolsProvidePython3() ? "/usr/bin/python3" : nil
    }

    private static func developerToolsProvidePython3() -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: "/usr/bin/python3") else { return false }
        if fm.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/python3") { return true }
        guard let result = try? CleanerProcessRunner.run("/usr/bin/xcode-select", ["-p"]),
              result.succeeded else { return false }
        let developerDir = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !developerDir.isEmpty else { return false }
        return fm.isExecutableFile(atPath: (developerDir as NSString).appendingPathComponent("usr/bin/python3"))
    }

    private static var pythonNotFoundMessage: String {
        ZtatL10n.tr(
            "未找到可用的 python3。请用 Homebrew 安装 Python（brew install python），或运行 xcode-select --install 安装命令行工具。",
            "No usable python3 found. Install Python with Homebrew (brew install python), or install the Command Line Tools with xcode-select --install."
        )
    }

    /// Turns pip's stderr into a clear, localized reason for the common failure modes.
    private static func describePipFailure(_ output: CleanerProcessRunner.Output, python: String, operation: String) -> String {
        let text = output.combinedTrimmed
        let lower = text.lowercased()
        if lower.contains("externally-managed-environment") || lower.contains("externally managed") {
            // PEP 668: Homebrew Python 3.12+ marks its environment EXTERNALLY-MANAGED.
            return ZtatL10n.tr(
                "\(python) 是受外部管理的 Python 环境（PEP 668），pip 拒绝修改其中的包。请用 Homebrew 管理该解释器，或在虚拟环境（python3 -m venv）中操作。",
                "\(python) is an externally managed Python environment (PEP 668), so pip refuses to change its packages. Manage it with Homebrew, or work inside a virtual environment (python3 -m venv)."
            )
        }
        if lower.contains("no module named pip") {
            return ZtatL10n.tr("\(python) 未安装 pip。", "pip is not installed for \(python).")
        }
        if text.isEmpty {
            return ZtatL10n.tr("pip \(operation) 失败（退出码 \(output.status)）", "pip \(operation) failed (exit status \(output.status))")
        }
        return text
    }

    public func listPipPackages() async -> (pythonPath: String?, packages: [PipPackageItem], error: String?) {
        await Task.detached(priority: .userInitiated) {
            guard let python = self.resolvePython3Path() else {
                return (nil, [], Self.pythonNotFoundMessage)
            }
            do {
                let result = try CleanerProcessRunner.run(python, ["-m", "pip", "list", "--format=json", "--disable-pip-version-check"])
                guard result.succeeded else {
                    return (python, [], Self.describePipFailure(result, python: python, operation: "list"))
                }
                let data = result.stdout
                guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return (python, [], nil)
                }
                let items = arr.compactMap { dict -> PipPackageItem? in
                    guard let name = dict["name"] as? String,
                          let version = dict["version"] as? String else { return nil }
                    return PipPackageItem(id: name.lowercased(), name: name, version: version, size: 0, isSelected: false)
                }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return (python, items, nil)
            } catch {
                return (python, [], error.localizedDescription)
            }
        }.value
    }

    public func uninstallPipPackages(_ names: [String]) async -> (Bool, String) {
        await Task.detached(priority: .userInitiated) {
            guard let python = self.resolvePython3Path() else {
                return (false, Self.pythonNotFoundMessage)
            }
            guard !names.isEmpty else { return (true, "") }
            let protected: Set<String> = ["pip", "setuptools", "wheel"]
            let safeNames = names.filter { !protected.contains($0.lowercased()) }
            guard !safeNames.isEmpty else {
                return (false, ZtatL10n.tr("核心包 pip/setuptools/wheel 受保护", "Core pip/setuptools/wheel packages are protected"))
            }
            do {
                let result = try CleanerProcessRunner.run(
                    python,
                    ["-m", "pip", "uninstall", "-y", "--disable-pip-version-check", "--"] + safeNames
                )
                guard result.succeeded else {
                    return (false, Self.describePipFailure(result, python: python, operation: "uninstall"))
                }
                return (true, result.combinedTrimmed)
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }
}
