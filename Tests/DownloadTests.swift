import Foundation
import Testing
@testable import MediaPocketCore

@Test("Platform URLs are restricted to supported hosts and individual posts", arguments: [
    "https://youtube.com.evil.example/watch?v=abc", "https://youtube.com@evil.example/watch?v=abc",
    "https://www.youtube.com/playlist?list=all", "https://www.instagram.com/username/",
    "file:///etc/passwd", "https://bilibili.com:8080/video/BV123", "https://www.threads.com/@user"
])
func rejectedDownloadURL(_ url: String) {
    #expect(throws: (any Error).self) { try DownloadPlatform.identify(url) }
}

@Test("Four platforms and their short URLs are identified", arguments: [
    ("https://youtu.be/abc123", DownloadPlatform.youtube),
    ("https://www.youtube.com/shorts/abc123", .youtube),
    ("https://www.instagram.com/reel/abc123/", .instagram),
    ("https://www.threads.com/@user/post/Abc_123?x=1", .threads),
    ("https://www.threads.net/share/Abc_123/", .threads),
    ("https://www.bilibili.com/video/BV123/?p=2", .bilibili),
    ("https://b23.tv/abc123", .bilibili)
])
func acceptedDownloadURL(_ entry: (String, DownloadPlatform)) throws {
    #expect(try DownloadPlatform.identify(entry.0).1 == entry.1)
}

@Test("Bridge contains only a UUID in its shell command, and persists a safe request")
func persistedRequest() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let library = MediaLibrary(directory: base.appending(path: "Media"))
    let store = DownloadStore(directory: base.appending(path: "Bridge"), library: library)
    let runner = base.appending(path: "runner.py")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try Data("# test".utf8).write(to: runner)
    try await store.prepare(runner: runner)
    let request = try await store.create(url: "https://youtu.be/abc?x=%27%3B%20echo%20secret", quality: "720", audioOnly: true)
    let command = DownloadStore.command(for: request.id)
    #expect(!command.contains("secret"))
    #expect(command.hasSuffix(request.id.uuidString))
    #expect(DownloadStore.shellURL(command: command)?.absoluteString.contains(" ") == false)
    let jobs = try await store.jobs()
    #expect(jobs.count == 1)
    #expect(jobs.first?.request.audioOnly == true)
    #expect(jobs.first?.request.quality == "720")
    #expect(jobs.first?.status == nil)
}

@Test("Completed job import is atomic and idempotent across callback refreshes")
func downloadCommit() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appending(path: "output")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("verified video".utf8).write(to: source.appending(path: "001.mkv"))
    let library = MediaLibrary(directory: base.appending(path: "Media"))
    let id = UUID()
    let first = try await library.acceptDownload(from: source, id: id, outputs: ["001.mkv"])
    let second = try await library.acceptDownload(from: source, id: id, outputs: ["001.mkv"])
    #expect(first == second)
    #expect(try await library.items(in: first).map(\.name) == ["001.mkv"])
    #expect(!FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
}

@Test("Malformed download manifests cannot import files or replace user folders")
func rejectedDownloadManifest() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appending(path: "output")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let library = MediaLibrary(directory: base.appending(path: "Media"))
    try Data("unverified".utf8).write(to: source.appending(path: "001.mkv.part"))
    await #expect(throws: (any Error).self) {
        try await library.acceptDownload(from: source, id: UUID(), outputs: ["../001.mkv.part"])
    }
    await #expect(throws: (any Error).self) {
        try await library.acceptDownload(from: source, id: UUID(), outputs: ["001.mkv"])
    }
    let id = UUID()
    try await library.createFolder(named: "Downloads")
    try await library.createFolder(named: id.uuidString, in: "Downloads")
    await #expect(throws: (any Error).self) {
        try await library.acceptDownload(from: source, id: id, outputs: ["001.mkv"])
    }
    #expect(try Data(contentsOf: source.appending(path: "001.mkv.part")) == Data("unverified".utf8))
}
