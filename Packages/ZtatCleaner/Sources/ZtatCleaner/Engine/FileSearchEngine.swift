// SPDX-License-Identifier: GPL-3.0-or-later
// Multi-volume / custom-folder recursive file search engine with composable filters
// (Name/Regex, Extension, Size, Modified Date, Kind, Finder Tags, Finder Comments xattr)
// and safe inline rename.

import Darwin
import Foundation
import ZtatCore

public final class FileSearchEngine: @unchecked Sendable {
    public static let shared = FileSearchEngine()

    private init() {}

    private static let excludedSystemTopLevels: Set<String> = [
        "System", "private", "usr", "bin", "sbin", "cores", "dev", "etc", "Volumes"
    ]

    public func search(
        query: FileSearchQuery,
        onMatch: (@Sendable (FileSearchResultItem) -> Void)? = nil
    ) async -> [FileSearchResultItem] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let root = query.rootURL.standardizedFileURL
            guard fm.fileExists(atPath: root.path) else { return [] }

            let exts: Set<String> = Set(
                query.extensionsCSV
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                    .filter { !$0.isEmpty }
            )

            let regex: NSRegularExpression?
            if query.nameMatchMode == .regex && !query.nameText.isEmpty {
                let opts: NSRegularExpression.Options = query.caseSensitive ? [] : [.caseInsensitive]
                regex = try? NSRegularExpression(pattern: query.nameText, options: opts)
            } else {
                regex = nil
            }

            let tagQuery = query.finderTagFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let commentQuery = query.finderCommentFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .isPackageKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .totalFileAllocatedSizeKey,
                .contentModificationDateKey,
                .tagNamesKey
            ]

            var enumOpts: FileManager.DirectoryEnumerationOptions = []
            if !query.includeHidden { enumOpts.insert(.skipsHiddenFiles) }
            if !query.includeSubfolders { enumOpts.insert(.skipsSubdirectoryDescendants) }

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: enumOpts,
                errorHandler: { _, _ in true }
            ) else { return [] }

            let isSystemRoot = root.path == "/"
            var results: [FileSearchResultItem] = []

            while let obj = enumerator.nextObject() {
                if Task.isCancelled || results.count >= query.maxResults { break }
                guard let url = obj as? URL else { continue }

                if isSystemRoot && query.excludeSystemFolders {
                    let top = url.path.split(separator: "/").first.map(String.init) ?? ""
                    if Self.excludedSystemTopLevels.contains(top) {
                        enumerator.skipDescendants()
                        continue
                    }
                }

                guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if vals.isSymbolicLink == true { continue }

                let isDir = vals.isDirectory == true
                let isPkg = vals.isPackage == true
                if isPkg {
                    enumerator.skipDescendants()
                }

                // Kind filter
                switch query.kindFilter {
                case .any: break
                case .filesOnly: if isDir && !isPkg { continue }
                case .foldersOnly: if !isDir || isPkg { continue }
                case .packagesOnly: if !isPkg { continue }
                }

                let name = url.lastPathComponent

                // Name filter
                if !query.nameText.isEmpty {
                    let matched: Bool
                    let hay = query.caseSensitive ? name : name.lowercased()
                    let needle = query.caseSensitive ? query.nameText : query.nameText.lowercased()
                    switch query.nameMatchMode {
                    case .contains: matched = hay.contains(needle)
                    case .doesNotContain: matched = !hay.contains(needle)
                    case .startsWith: matched = hay.hasPrefix(needle)
                    case .endsWith: matched = hay.hasSuffix(needle)
                    case .exact: matched = hay == needle
                    case .regex:
                        if let regex {
                            let range = NSRange(name.startIndex..., in: name)
                            matched = regex.firstMatch(in: name, options: [], range: range) != nil
                        } else {
                            matched = false
                        }
                    }
                    if !matched { continue }
                }

                // Extension filter
                if !exts.isEmpty {
                    let ext = url.pathExtension.lowercased()
                    if !exts.contains(ext) { continue }
                }

                // Size filter
                let size = Int64(vals.totalFileAllocatedSize ?? vals.fileSize ?? 0)
                if let minB = query.minSizeBytes, size < minB { continue }
                if let maxB = query.maxSizeBytes, size > maxB { continue }

                // Date filter
                let modDate = vals.contentModificationDate
                if let after = query.modifiedAfter, let d = modDate, d < after { continue }
                if let before = query.modifiedBefore, let d = modDate, d > before { continue }

                // Finder Tags filter
                let tags = vals.tagNames ?? []
                if !tagQuery.isEmpty {
                    if !tags.contains(where: { $0.lowercased().contains(tagQuery) }) { continue }
                }

                // Finder Comment xattr filter (only read xattr if filter active)
                var comment: String? = nil
                if !commentQuery.isEmpty {
                    comment = Self.readFinderComment(at: url)
                    guard let c = comment, c.lowercased().contains(commentQuery) else { continue }
                }

                let item = FileSearchResultItem(
                    id: url.standardizedFileURL.path,
                    url: url.standardizedFileURL,
                    name: name,
                    isDirectory: isDir,
                    isPackage: isPkg,
                    size: size,
                    modifiedDate: modDate,
                    finderTags: tags,
                    finderComment: comment,
                    isSelected: false
                )
                results.append(item)
                onMatch?(item)
            }

            return results
        }.value
    }

    public func renameItem(at url: URL, newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw NSError(domain: "ZtatFileSearch", code: 1, userInfo: [NSLocalizedDescriptionKey: ZtatL10n.tr("无效文件名", "Invalid file name")])
        }
        let dest = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    public static func readFinderComment(at url: URL) -> String? {
        let attrName = "com.apple.metadata:kMDItemFinderComment"
        return url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let len = getxattr(path, attrName, nil, 0, 0, XATTR_NOFOLLOW)
            guard len > 0, len <= 16384 else { return nil }
            var data = Data(count: len)
            let readLen = data.withUnsafeMutableBytes {
                getxattr(path, attrName, $0.baseAddress, len, 0, XATTR_NOFOLLOW)
            }
            guard readLen == len else { return nil }
            if let str = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? String {
                return str
            }
            return String(data: data, encoding: .utf8)
        }
    }
}
