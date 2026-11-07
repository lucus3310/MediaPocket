import Foundation
import Testing
@testable import MediaPocketCore

private struct LinkedFixture {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var folder: URL { base.appending(path: "原片 source") }
    var movie: URL { folder.appending(path: "原片 001.mkv") }
    var catalog: URL { base.appending(path: "metadata") }
    func prepare() throws {
        try FileManager.default.createDirectory(at: folder.appending(path: "子資料夾"), withIntermediateDirectories: true)
        let handleURL = movie
        _ = FileManager.default.createFile(atPath: handleURL.path(percentEncoded: false), contents: Data("original media".utf8))
        let handle = try FileHandle(forWritingTo: handleURL)
        try handle.truncate(atOffset: 4 * 1024 * 1024)
        try handle.close()
        try Data("nested".utf8).write(to: folder.appending(path: "子資料夾/next.mp4"))
    }
    func clean() { try? FileManager.default.removeItem(at: base) }
}

@Test("File and folder bookmarks reopen originals from a newly constructed store without media copies")
func sourcePersistence() async throws {
    let f = LinkedFixture(); try f.prepare(); defer { f.clean() }
    let first = LinkedSourceStore(directory: f.catalog)
    let movie = try await first.add(f.movie)
    let folder = try await first.add(f.folder)
    let reopened = LinkedSourceStore(directory: f.catalog)
    #expect(try await reopened.sources().count == 2)
    let file = try await reopened.prepareOpen(SourceLocation(sourceID: movie.id, path: ""))
    #expect(file.url.resolvingSymlinksInPath() == f.movie.resolvingSymlinksInPath())
    #expect(file.accessRoot != nil && file.size == 4 * 1024 * 1024)
    let entries = try await reopened.items(at: SourceLocation(sourceID: folder.id, path: ""))
    #expect(Set(entries.map(\.name)) == ["原片 001.mkv", "子資料夾"])
    let nested = try await reopened.prepareOpen(SourceLocation(sourceID: folder.id, path: "子資料夾/next.mp4"))
    #expect(try Data(contentsOf: nested.url) == Data("nested".utf8))
    let saved = try FileManager.default.contentsOfDirectory(atPath: f.catalog.path(percentEncoded: false))
    #expect(saved == ["sources.json"])
    let size = try Data(contentsOf: f.catalog.appending(path: "sources.json")).count
    #expect(size < 64 * 1024)
}

@Test("Readding the same source preserves its identity, and forgetting preserves all originals")
func sourceForget() async throws {
    let f = LinkedFixture(); try f.prepare(); defer { f.clean() }
    let store = LinkedSourceStore(directory: f.catalog)
    let first = try await store.add(f.folder)
    let again = try await store.add(f.folder)
    #expect(first.id == again.id)
    #expect(try await store.sources().count == 1)
    try await store.forget(first.id)
    #expect(try await store.sources().isEmpty)
    #expect(FileManager.default.fileExists(atPath: f.movie.path(percentEncoded: false)))
    #expect(try Data(contentsOf: f.folder.appending(path: "子資料夾/next.mp4")) == Data("nested".utf8))
}

@Test("Linked folder reads reject traversal and symlinks outside the authorized root", arguments: ["../outside.mp4", "/etc/passwd", "子資料夾/../../outside.mp4", "child\\file", ".hidden/file"])
func sourceTraversal(path: String) async throws {
    let f = LinkedFixture(); try f.prepare(); defer { f.clean() }
    let store = LinkedSourceStore(directory: f.catalog)
    let source = try await store.add(f.folder)
    await #expect(throws: (any Error).self) { try await store.prepareOpen(SourceLocation(sourceID: source.id, path: path)) }
}

@Test("Symlinked files cannot escape a source, and listing does not include them")
func sourceSymlink() async throws {
    let f = LinkedFixture(); try f.prepare(); defer { f.clean() }
    let outside = f.base.appending(path: "outside.mp4")
    try Data("private".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: f.folder.appending(path: "link.mp4"), withDestinationURL: outside)
    let store = LinkedSourceStore(directory: f.catalog)
    let source = try await store.add(f.folder)
    let entries = try await store.items(at: SourceLocation(sourceID: source.id, path: ""))
    #expect(!entries.contains(where: { $0.name == "link.mp4" }))
    await #expect(throws: (any Error).self) { try await store.prepareOpen(SourceLocation(sourceID: source.id, path: "link.mp4")) }
}

private struct StaleBookmarkCodec: SourceBookmarkCodec {
    func create(_ url: URL) throws -> Data { Data(("fresh:" + url.path(percentEncoded: false)).utf8) }
    func resolve(_ data: Data) throws -> ResolvedSourceBookmark {
        let text = String(decoding: data, as: UTF8.self)
        let stale = text.hasPrefix("stale:")
        return ResolvedSourceBookmark(url: URL(fileURLWithPath: String(text.dropFirst(6))), stale: stale)
    }
}

@Test("Stale bookmarks refresh persistently; recovery changes only catalog metadata")
func sourceStaleBookmark() async throws {
    let f = LinkedFixture(); try f.prepare(); defer { f.clean() }
    let id = UUID()
    let record = LinkedSource(id: id, name: "source", kind: .folder, bookmark: Data(("stale:" + f.folder.path(percentEncoded: false)).utf8), added: .now)
    struct Envelope: Encodable { let version = 1; let sources: [LinkedSource] }
    try FileManager.default.createDirectory(at: f.catalog, withIntermediateDirectories: true)
    try JSONEncoder().encode(Envelope(sources: [record])).write(to: f.catalog.appending(path: "sources.json"))
    let store = LinkedSourceStore(directory: f.catalog, codec: StaleBookmarkCodec())
    _ = try await store.items(at: SourceLocation(sourceID: id, path: ""))
    let reopened = LinkedSourceStore(directory: f.catalog, codec: StaleBookmarkCodec())
    let saved = try #require(try await reopened.sources().first)
    #expect(String(decoding: saved.bookmark, as: UTF8.self).hasPrefix("fresh:"))
    #expect(saved.id == id)
}

@Test("Malformed catalogs are retained and are never replaced by an empty catalog")
func sourceCorruptCatalog() async throws {
    let f = LinkedFixture(); try f.prepare(); defer { f.clean() }
    try FileManager.default.createDirectory(at: f.catalog, withIntermediateDirectories: true)
    let data = Data("broken catalog".utf8)
    let path = f.catalog.appending(path: "sources.json")
    try data.write(to: path)
    let store = LinkedSourceStore(directory: f.catalog)
    await #expect(throws: (any Error).self) { try await store.add(f.movie) }
    #expect(try Data(contentsOf: path) == data)
}

@Test("An unavailable original remains registered so the user can reconnect it")
func sourceMissingOriginal() async throws {
    let f = LinkedFixture(); try f.prepare(); defer { f.clean() }
    let store = LinkedSourceStore(directory: f.catalog)
    let source = try await store.add(f.movie)
    try FileManager.default.removeItem(at: f.movie)
    await #expect(throws: (any Error).self) { try await store.prepareOpen(SourceLocation(sourceID: source.id, path: "")) }
    #expect(try await store.sources().first?.id == source.id)
    let replacement = f.folder.appending(path: "replacement.mp4")
    try Data("replacement".utf8).write(to: replacement)
    let reconnected = try await store.add(replacement, replacing: source.id)
    #expect(reconnected.id == source.id)
    let opened = try await store.prepareOpen(SourceLocation(sourceID: source.id, path: ""))
    #expect(opened.url.resolvingSymlinksInPath() == replacement.resolvingSymlinksInPath())
}
