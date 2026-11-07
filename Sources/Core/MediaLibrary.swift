import Foundation

struct LibraryItem: Identifiable, Sendable {
    let url: URL
    let relativePath: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    var accessRoot: URL? = nil

    var id: String { relativePath }
    var name: String { url.lastPathComponent }
    var isMedia: Bool {
        let extensions = ["mp4", "mkv", "mka", "avi", "webm", "flv", "wmv", "ts", "m2ts", "mov", "m4v", "mpg", "mpeg", "3gp", "mp3", "m4a", "aac", "ogg", "opus", "flac", "wav", "aiff", "ac3", "dts"]
        return !isDirectory && extensions.contains(url.pathExtension.lowercased())
    }
}

struct TrashItem: Codable, Identifiable, Sendable {
    let id: UUID
    let originalPath: String
    let deletedAt: Date
    var name: String { (originalPath as NSString).lastPathComponent }
}

enum LibraryError: LocalizedError, Equatable {
    case invalidPath, invalidName, folderIntoItself, missingItem

    var errorDescription: String? {
        switch self {
        case .invalidPath: "無法存取檔案庫以外或保留的目錄。"
        case .invalidName: "名稱不能留空、以句點開頭，或包含斜線。"
        case .folderIntoItself: "無法將資料夾移到自己或自己的子資料夾。"
        case .missingItem: "找不到這個檔案，請重新整理。"
        }
    }
}

// A single app-owned actor serializes mutations. Relative paths are validated
// against the resolved library root before any read, copy or move.
actor MediaLibrary {
    private let files = FileManager.default
    private let directory: URL

    init(directory: URL = URL.documentsDirectory.appending(path: "Media", directoryHint: .isDirectory)) {
        self.directory = directory.standardizedFileURL
    }

    func items(in path: String = "") throws -> [LibraryItem] {
        try prepare()
        let folder = try location(path)
        return try files.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else { return nil }
            let relative = path.isEmpty ? url.lastPathComponent : "\(path)/\(url.lastPathComponent)"
            _ = try location(relative)
            return LibraryItem(url: url, relativePath: relative, isDirectory: values.isDirectory == true,
                               size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
        }
    }

    func importFile(from source: URL, into path: String = "") throws {
        try prepare()
        let targetFolder = try location(path)
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let temporary = try stagingDirectory().appending(path: UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryError.invalidPath }
                try files.copyItem(at: readable, to: temporary)
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        try validName(source.lastPathComponent)
        try files.moveItem(at: temporary, to: availableDestination(name: source.lastPathComponent, in: targetFolder))
    }

    func createFolder(named name: String, in path: String = "") throws {
        try prepare()
        try validName(name)
        let destination = availableDestination(name: name, in: try location(path))
        try files.createDirectory(at: destination, withIntermediateDirectories: false)
    }

    // Commit a whole verified job in one rename. A receipt makes recovery after
    // an app interruption idempotent, without overwriting a user's folder.
    func acceptDownload(from source: URL, id: UUID, outputs: [String]) throws -> String {
        try prepare()
        let path = "Downloads/\(id.uuidString)"
        let parent = try location("Downloads")
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = try location(path)
        let receiptName = ".mediapocket-receipt"
        if files.fileExists(atPath: target.path(percentEncoded: false)) {
            guard (try? String(contentsOf: target.appending(path: receiptName), encoding: .utf8)) == id.uuidString else {
                throw CocoaError(.fileWriteFileExists)
            }
            return path
        }
        guard !outputs.isEmpty, outputs.count <= 20, Set(outputs).count == outputs.count,
              try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink != true else {
            throw DownloadError.invalidResult
        }
        let entries = try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        guard Set(entries.map(\.lastPathComponent)).subtracting([receiptName]) == Set(outputs) else { throw DownloadError.invalidResult }
        for name in outputs {
            guard name.range(of: #"^[0-9]{3}\.(?:mkv|mka)$"#, options: .regularExpression) != nil else { throw DownloadError.invalidResult }
            let values = try source.appending(path: name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else { throw DownloadError.invalidResult }
        }
        try Data(id.uuidString.utf8).write(to: source.appending(path: receiptName), options: .atomic)
        try files.moveItem(at: source, to: target)
        return path
    }

    func rename(_ path: String, to name: String) throws {
        try validName(name)
        let source = try location(path, allowRoot: false)
        guard name != source.lastPathComponent else { return }
        let destination = source.deletingLastPathComponent().appending(path: name)
        // Renaming is exact. Never silently overwrite or alter the requested name.
        if files.fileExists(atPath: destination.path(percentEncoded: false)) { throw CocoaError(.fileWriteFileExists) }
        try files.moveItem(at: source, to: destination)
    }

    func move(_ path: String, into destinationPath: String) throws {
        let source = try location(path, allowRoot: false)
        let folder = try location(destinationPath)
        if source.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents == folder.resolvingSymlinksInPath().pathComponents { return }
        let resolvedSource = source.resolvingSymlinksInPath().pathComponents
        let resolvedFolder = folder.resolvingSymlinksInPath().pathComponents
        guard !resolvedFolder.starts(with: resolvedSource) else {
            throw LibraryError.folderIntoItself
        }
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw LibraryError.invalidPath }
        try files.moveItem(at: source, to: availableDestination(name: source.lastPathComponent, in: folder))
    }

    func duplicate(_ path: String) throws {
        let source = try location(path, allowRoot: false)
        let temporary = try stagingDirectory().appending(path: UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        try files.copyItem(at: source, to: temporary)
        try files.moveItem(at: temporary, to: availableDestination(name: source.lastPathComponent, in: source.deletingLastPathComponent()))
    }

    func moveToTrash(_ path: String) throws {
        let source = try location(path, allowRoot: false)
        let entry = TrashItem(id: UUID(), originalPath: path, deletedAt: Date())
        let slot = try trashDirectory().appending(path: entry.id.uuidString, directoryHint: .isDirectory)
        try files.createDirectory(at: slot, withIntermediateDirectories: false)
        do {
            try JSONEncoder().encode(entry).write(to: slot.appending(path: "entry.json"), options: .atomic)
            try files.moveItem(at: source, to: slot.appending(path: "content"))
        } catch {
            // Roll back only the metadata if the original file was not moved.
            try? files.removeItem(at: slot)
            throw error
        }
    }

    func trashItems() throws -> [TrashItem] {
        let root = try trashDirectory()
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]).compactMap { slot in
            guard try slot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  let data = try? Data(contentsOf: slot.appending(path: "entry.json")),
                  let item = try? JSONDecoder().decode(TrashItem.self, from: data),
                  slot.lastPathComponent == item.id.uuidString,
                  files.fileExists(atPath: slot.appending(path: "content").path(percentEncoded: false)) else { return nil }
            return item
        }.sorted { $0.deletedAt > $1.deletedAt }
    }

    func restore(_ item: TrashItem) throws {
        let slot = try trashDirectory().appending(path: item.id.uuidString, directoryHint: .isDirectory)
        // Read our persisted metadata rather than trusting a caller-provided path.
        let data = try Data(contentsOf: slot.appending(path: "entry.json"))
        let stored = try JSONDecoder().decode(TrashItem.self, from: data)
        guard stored.id == item.id else { throw LibraryError.invalidPath }
        let original = try location(stored.originalPath, allowRoot: false)
        var folder = original.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !files.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory) || !isDirectory.boolValue { folder = directory }
        let content = slot.appending(path: "content")
        guard isWithinLibrary(content) else {
            throw LibraryError.invalidPath
        }
        try files.moveItem(at: content, to: availableDestination(name: original.lastPathComponent, in: folder))
        try? files.removeItem(at: slot)
    }

    private func prepare() throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func validName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"),
              !name.contains("\0"), name.utf8.count <= 240 else { throw LibraryError.invalidName }
    }

    private func location(_ path: String, allowRoot: Bool = true) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains("\\") else { throw LibraryError.invalidPath }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if path.isEmpty {
            guard allowRoot else { throw LibraryError.invalidPath }
            return directory.resolvingSymlinksInPath()
        }
        guard components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { throw LibraryError.invalidPath }
        // Resolve the existing root before appending a potentially nonexistent
        // child; macOS /var aliases and trailing directory separators must not
        // change the containment decision.
        let candidate = directory.resolvingSymlinksInPath().appending(path: path).standardizedFileURL
        guard isWithinLibrary(candidate) else { throw LibraryError.invalidPath }
        return candidate
    }

    private func stagingDirectory() throws -> URL { try internalDirectory(".imports") }
    private func trashDirectory() throws -> URL { try internalDirectory(".Trash") }

    private func internalDirectory(_ name: String) throws -> URL {
        try prepare()
        let url = directory.resolvingSymlinksInPath().appending(path: name, directoryHint: .isDirectory)
        guard isWithinLibrary(url) else {
            throw LibraryError.invalidPath
        }
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isWithinLibrary(_ url: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let child = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return child.count > root.count && child.starts(with: root)
    }

    private func availableDestination(name: String, in folder: URL) -> URL {
        let original = folder.appending(path: name)
        guard files.fileExists(atPath: original.path(percentEncoded: false)) else { return original }
        let stem = original.deletingPathExtension().lastPathComponent
        let suffix = original.pathExtension
        var count = 2
        while true {
            let filename = "\(stem) (\(count))" + (suffix.isEmpty ? "" : ".\(suffix)")
            let candidate = folder.appending(path: filename)
            if !files.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
            count += 1
        }
    }
}
