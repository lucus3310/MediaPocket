import Foundation
import Testing
@testable import MediaPocketCore

private struct Fixture {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var root: URL { base.appending(path: "Media") }
    var library: MediaLibrary { MediaLibrary(directory: root) }

    func prepare() throws { try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true) }
    func clean() { try? FileManager.default.removeItem(at: base) }
    func source(_ text: String = "original") throws -> URL {
        let url = base.appending(path: "sample.mp4")
        try Data(text.utf8).write(to: url)
        return url
    }
}

@Test("Importing the same filename preserves both copies")
func importCollision() async throws {
    let f = Fixture(); try f.prepare(); defer { f.clean() }
    let library = f.library
    let source = try f.source()
    try await library.importFile(from: source)
    try await library.importFile(from: source)
    try await library.importFile(from: source)
    let items = try await library.items()
    #expect(Set(items.map(\.name)) == ["sample.mp4", "sample (2).mp4", "sample (3).mp4"])
    #expect(try Data(contentsOf: source) == Data("original".utf8))
}

@Test("Trash and restore preserve a folder and do not overwrite a replacement")
func trashRestoreCollision() async throws {
    let f = Fixture(); try f.prepare(); defer { f.clean() }
    let library = f.library
    try await library.createFolder(named: "Trips")
    try await library.importFile(from: f.source(), into: "Trips")
    try await library.moveToTrash("Trips")
    #expect(try await library.items().isEmpty)
    try await library.createFolder(named: "Trips")
    let entry = try #require(try await library.trashItems().first)
    try await library.restore(entry)
    #expect(try await library.trashItems().isEmpty)
    let restored = try await library.items(in: "Trips (2)")
    #expect(restored.map(\.name) == ["sample.mp4"])
}

@Test("Moving a folder into its own descendant is rejected")
func folderCycle() async throws {
    let f = Fixture(); try f.prepare(); defer { f.clean() }
    let library = f.library
    try await library.createFolder(named: "Parent")
    try await library.createFolder(named: "Child", in: "Parent")
    await #expect(throws: LibraryError.folderIntoItself) {
        try await library.move("Parent", into: "Parent/Child")
    }
    #expect(try await library.items(in: "Parent").count == 1)
}

@Test("Unsafe paths cannot mutate files outside the library", arguments: ["../outside.mp4", "/tmp/outside.mp4", ".Trash", "folder/../outside.mp4", "folder\\file"])
func unsafePath(_ path: String) async throws {
    let f = Fixture(); try f.prepare(); defer { f.clean() }
    let library = f.library
    _ = try await library.items()
    await #expect(throws: LibraryError.invalidPath) { try await library.moveToTrash(path) }
}

@Test("A symlink to an external directory is hidden and cannot be written through")
func symbolicLinkEscape() async throws {
    let f = Fixture(); try f.prepare(); defer { f.clean() }
    let library = f.library
    _ = try await library.items()
    let outside = f.base.appending(path: "outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: f.root.appending(path: "link"), withDestinationURL: outside)
    #expect(try await library.items().isEmpty)
    await #expect(throws: LibraryError.invalidPath) { try await library.createFolder(named: "bad", in: "link") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path(percentEncoded: false)).isEmpty)
}

@Test("Move and rename collisions never overwrite files")
func moveAndRename() async throws {
    let f = Fixture(); try f.prepare(); defer { f.clean() }
    let library = f.library
    try await library.createFolder(named: "Destination")
    let source = try f.source()
    try await library.importFile(from: source)
    try await library.importFile(from: source, into: "Destination")
    try await library.move("sample.mp4", into: "Destination")
    await #expect(throws: (any Error).self) {
        try await library.rename("Destination/sample (2).mp4", to: "sample.mp4")
    }
    #expect(try await library.items(in: "Destination").count == 2)
}

@Test("Unicode folder names and spaces survive import, move and restore")
func unicodePaths() async throws {
    let f = Fixture(); try f.prepare(); defer { f.clean() }
    let library = f.library
    try await library.createFolder(named: "旅行 影片")
    try await library.importFile(from: f.source(), into: "旅行 影片")
    try await library.importFile(from: f.source(), into: "旅行 影片")
    try await library.moveToTrash("旅行 影片/sample (2).mp4")
    let item = try #require(try await library.trashItems().first)
    try await library.restore(item)
    #expect(try await library.items(in: "旅行 影片").count == 2)
}
