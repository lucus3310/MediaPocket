import Foundation

enum LinkedSourceKind: String, Codable, Sendable { case file, folder }

struct LinkedSource: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let kind: LinkedSourceKind
    var bookmark: Data
    let added: Date
}

struct SourceLocation: Hashable, Sendable {
    let sourceID: UUID
    let path: String
}

struct ResolvedSourceBookmark: Sendable {
    let url: URL
    let stale: Bool
}

protocol SourceBookmarkCodec: Sendable {
    func create(_ url: URL) throws -> Data
    func resolve(_ data: Data) throws -> ResolvedSourceBookmark
}

struct SystemSourceBookmarkCodec: SourceBookmarkCodec {
    func create(_ url: URL) throws -> Data {
        // iOS document-picker URLs carry the security scope. The macOS-only
        // .withSecurityScope creation option is deliberately not used on iOS.
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func resolve(_ data: Data) throws -> ResolvedSourceBookmark {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return ResolvedSourceBookmark(url: url, stale: stale)
    }
}

enum LinkedSourceError: LocalizedError {
    case invalidPath, missingSource, permission, wrongKind, invalidCatalog, futureVersion
    var errorDescription: String? {
        switch self {
        case .invalidPath: "無法讀取授權來源以外或符號連結的項目。"
        case .missingSource: "找不到這個來源紀錄，請重新加入。"
        case .permission: "來源已移動、離線或授權失效。請在來源清單長按此來源，選擇「重新授權」。"
        case .wrongKind: "請選擇與原來源相同類型的檔案或資料夾。"
        case .invalidCatalog: "無法讀取來源紀錄；已保留紀錄檔，沒有重設或改動原檔。"
        case .futureVersion: "來源紀錄來自較新版本，請更新 App 後再開啟。"
        }
    }
}

// A lease owns exactly one balanced security-scope acquisition. It stays with
// the decoder/Quick Look, rather than ending when a directory listing returns.
// Instances are confined to their owning actor/UI session; never transferred.
final class ScopedFileAccess {
    private let url: URL
    private var acquired: Bool

    init(url: URL) throws {
        self.url = url
        acquired = url.startAccessingSecurityScopedResource()
        // Own-container URLs and non-sandboxed unit-test URLs need no extension.
        if !acquired && !FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) {
            throw LinkedSourceError.permission
        }
    }
    func close() {
        if acquired { acquired = false; url.stopAccessingSecurityScopedResource() }
    }
    deinit { close() }
}

private struct SourceCatalog: Codable {
    let version: Int
    var sources: [LinkedSource]
}

// This actor writes only its small Application Support catalog. Listing,
// opening, reconnecting and forgetting a source never copy/move/delete media.
actor LinkedSourceStore {
    let directory: URL
    private let codec: any SourceBookmarkCodec
    private let files = FileManager.default
    private var catalog: SourceCatalog?

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "LinkedSources"),
         codec: any SourceBookmarkCodec = SystemSourceBookmarkCodec()) {
        self.directory = directory
        self.codec = codec
    }

    func sources() throws -> [LinkedSource] {
        try load().sources.sorted { $0.added > $1.added }
    }

    func add(_ url: URL, replacing id: UUID? = nil) throws -> LinkedSource {
        var current = try load()
        let access = try ScopedFileAccess(url: url)
        defer { access.close() }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .localizedNameKey])
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw LinkedSourceError.invalidPath }
        let kind: LinkedSourceKind = values.isDirectory == true ? .folder : .file
        var index: Int?
        if let id {
            guard let oldIndex = current.sources.firstIndex(where: { $0.id == id }) else { throw LinkedSourceError.missingSource }
            guard current.sources[oldIndex].kind == kind else { throw LinkedSourceError.wrongKind }
            index = oldIndex
        } else {
            index = current.sources.firstIndex { source in
                guard source.kind == kind, let old = try? codec.resolve(source.bookmark).url else { return false }
                return old.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        let old = index.map { current.sources[$0] }
        let record = LinkedSource(id: old?.id ?? UUID(), name: values.localizedName ?? url.lastPathComponent,
                                  kind: kind, bookmark: try codec.create(url), added: old?.added ?? .now)
        if let index { current.sources[index] = record } else { current.sources.append(record) }
        try save(current)
        return record
    }

    func forget(_ id: UUID) throws {
        var current = try load()
        current.sources.removeAll { $0.id == id }
        try save(current)
    }

    func items(at location: SourceLocation) throws -> [LibraryItem] {
        let source = try resolved(location.sourceID)
        let access = try ScopedFileAccess(url: source.url)
        defer { access.close() }
        if source.record.kind == .file {
            guard location.path.isEmpty else { throw LinkedSourceError.invalidPath }
            return [try item(url: source.url, root: source.url, source: source.record, path: "")]
        }
        let folder = try child(location.path, of: source.url)
        // Metadata-only coordination avoids requesting every video's payload.
        return try coordinate(folder, options: [.immediatelyAvailableMetadataOnly]) { [self] readable in
            try validate(readable, inside: source.url)
            return try files.contentsOfDirectory(at: readable,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]).compactMap { url in
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { return nil }
                    try validate(url, inside: source.url)
                    let path = location.path.isEmpty ? url.lastPathComponent : location.path + "/" + url.lastPathComponent
                    return try item(url: url, root: source.url, source: source.record, path: path)
                }
        }
    }

    func prepareOpen(_ location: SourceLocation) throws -> LibraryItem {
        let source = try resolved(location.sourceID)
        let access = try ScopedFileAccess(url: source.url)
        defer { access.close() }
        let target: URL
        if source.record.kind == .file {
            guard location.path.isEmpty else { throw LinkedSourceError.invalidPath }
            target = source.url
        } else { target = try child(location.path, of: source.url) }
        // Coordinate only the explicitly selected file. A cloud provider may
        // materialize its original here; no App-owned media copy is created.
        return try coordinate(target) { [self] readable in
            if source.record.kind == .folder { try validate(readable, inside: source.url) }
            let result = try item(url: readable, root: source.url, source: source.record, path: location.path)
            guard !result.isDirectory else { throw LinkedSourceError.wrongKind }
            return result
        }
    }

    private func resolved(_ id: UUID) throws -> (record: LinkedSource, url: URL) {
        var current = try load()
        guard let index = current.sources.firstIndex(where: { $0.id == id }) else { throw LinkedSourceError.missingSource }
        let resolution: ResolvedSourceBookmark
        do { resolution = try codec.resolve(current.sources[index].bookmark) }
        catch { throw LinkedSourceError.permission }
        let access = try ScopedFileAccess(url: resolution.url)
        defer { access.close() }
        if resolution.stale {
            current.sources[index].bookmark = try codec.create(resolution.url)
            try save(current)
        }
        return (current.sources[index], resolution.url)
    }

    private func item(url: URL, root: URL, source: LinkedSource, path: String) throws -> LibraryItem {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw LinkedSourceError.invalidPath }
        return LibraryItem(url: url, relativePath: "source:\(source.id.uuidString)/\(path)",
                           isDirectory: values.isDirectory == true, size: Int64(values.fileSize ?? 0),
                           modified: values.contentModificationDate ?? .distantPast, accessRoot: root)
    }

    private func child(_ path: String, of root: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { throw LinkedSourceError.invalidPath }
        if path.isEmpty { return root }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { throw LinkedSourceError.invalidPath }
        let candidate = root.appending(path: path)
        try validate(candidate, inside: root)
        return candidate
    }

    private func validate(_ url: URL, inside root: URL) throws {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard candidate.starts(with: base) else { throw LinkedSourceError.invalidPath }
    }

    private func coordinate<T>(_ url: URL, options: NSFileCoordinator.ReadingOptions = [], _ body: @escaping (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: options, error: &coordinationError) { readable in
            result = Result { try body(readable) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw LinkedSourceError.permission }
        return try result.get()
    }

    private func load() throws -> SourceCatalog {
        if let catalog { return catalog }
        let url = directory.appending(path: "sources.json")
        guard files.fileExists(atPath: url.path(percentEncoded: false)) else {
            let empty = SourceCatalog(version: 1, sources: [])
            catalog = empty
            return empty
        }
        let decoded: SourceCatalog
        do { decoded = try JSONDecoder().decode(SourceCatalog.self, from: Data(contentsOf: url)) }
        catch { throw LinkedSourceError.invalidCatalog }
        guard decoded.version == 1 else { throw LinkedSourceError.futureVersion }
        guard Set(decoded.sources.map(\.id)).count == decoded.sources.count else { throw LinkedSourceError.invalidCatalog }
        catalog = decoded
        return decoded
    }

    private func save(_ value: SourceCatalog) throws {
        let data = try JSONEncoder().encode(value)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "sources.json"), options: .atomic)
        catalog = value
    }
}
