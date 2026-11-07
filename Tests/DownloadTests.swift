import Foundation
import Testing
@testable import MediaPocketCore

@Test("SMG handoff round-trips literal URL text without injecting callback parameters")
func shortcutInputEncoding() throws {
    let source = "https://www.youtube.com/watch?v=abc&x=a+b%26c#clip=00:10-00:30"
    let url = try SMGShortcutHandoff.url(name: " SMG YouTube + 測試 ", source: source)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "shortcuts")
    #expect(components.host == "run-shortcut")
    #expect(components.queryItems?.count == 3)
    #expect(components.queryItems?.first(where: { $0.name == "name" })?.value == "SMG YouTube + 測試")
    #expect(components.queryItems?.first(where: { $0.name == "text" })?.value == source)
    #expect(components.queryItems?.first(where: { $0.name == "input" })?.value == "text")
    #expect(throws: (any Error).self) { try SMGShortcutHandoff.url(name: "", source: source) }
    #expect(throws: (any Error).self) { try SMGShortcutHandoff.url(name: "SMG YouTube", source: "https://www.instagram.com/reel/abc/") }
}

@Test("Legacy requests keep their native route; Shortcut handoff never imports or claims completion")
func shortcutJobPersistence() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let library = MediaLibrary(directory: base.appending(path: "Media"))
    let store = DownloadStore(directory: base.appending(path: "Bridge"), library: library)
    let request = try await store.create(url: "https://b23.tv/abc", quality: "best", audioOnly: false, method: .smgShortcut)
    try await store.markShortcutHandoff(request)
    let restored = try #require(try await store.jobs().first)
    #expect(restored.request.executionMethod == .smgShortcut)
    #expect(restored.status?.phase == "shortcut")
    #expect(restored.status?.terminal == false)
    #expect(restored.libraryPath == nil)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    legacy.removeValue(forKey: "method")
    let decoded = try JSONDecoder().decode(DownloadRequest.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.executionMethod == .ashell)
}

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
    #expect(command.split(separator: "\n").count == 2)
    #expect(!command.contains(";"))
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
