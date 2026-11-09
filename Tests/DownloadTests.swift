import Foundation
import Testing
@testable import MediaPocketCore

@Test("Native process interruption becomes retryable while selection and track bytes survive")
func nativeInterruptionRecovery() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let store = DownloadStore(directory: base, library: MediaLibrary(directory: base.appending(path: "Media")))
    try await store.prepare()
    let request = try await store.create(url: "https://youtu.be/fixture", requiresSelection: true, fast: true)
    let slot = base.appending(path: "jobs/\(request.id.uuidString)")
    let catalog = DownloadCatalog(schema: 1, token: request.token, title: "Fixture", options: [DownloadOption(id: "video:720", label: "720p", audioOnly: false)])
    try JSONEncoder().encode(catalog).write(to: slot.appending(path: "catalog.json"))
    try JSONEncoder().encode(DownloadStatus(phase: "awaitingSelection", message: "Choose", token: request.token, updated: 1)).write(to: slot.appending(path: "status.json"))
    try await store.recoverInterrupted()
    #expect(try await store.jobs().first?.status?.phase == "awaitingSelection")
    _ = try await store.select(request.id, optionID: "video:720")
    let partial = slot.appending(path: "track.part")
    try Data("partial".utf8).write(to: partial)
    try await store.recoverInterrupted()
    #expect(try await store.jobs().first?.status?.phase == "failed")
    let retry = try await store.retry(request.id, fast: false)
    #expect(retry.selection == "video:720" && retry.attempt == 1 && retry.executionMethod == .native)
    #expect(retry.transferMode == nil)
    #expect(try Data(contentsOf: partial) == Data("partial".utf8))
}

@Test("Native completed output is moved into the existing library once")
func nativeCompletedJobImport() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let library = MediaLibrary(directory: base.appending(path: "Media"))
    let store = DownloadStore(directory: base.appending(path: "Jobs"), library: library)
    let request = try await store.create(url: "https://youtu.be/fixture")
    let slot = base.appending(path: "Jobs/jobs/\(request.id.uuidString)")
    let output = slot.appending(path: "output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try Data("validated fixture".utf8).write(to: output.appending(path: "001.mp4"))
    try JSONEncoder().encode(DownloadStatus(phase: "complete", message: "Done", outputs: ["001.mp4"], token: request.token, updated: 1)).write(to: slot.appending(path: "status.json"))
    let first = try #require(try await store.jobs().first?.libraryPath)
    #expect(try await store.jobs().first?.libraryPath == first)
    #expect(try await library.items(in: first).map(\.name) == ["001.mp4"])
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test("App selection survives restart, rejects unoffered options and queues without importing media")
func catalogSelectionPersistence() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let library = MediaLibrary(directory: base.appending(path: "Media"))
    let store = DownloadStore(directory: base.appending(path: "Bridge"), library: library)
    let request = try await store.create(url: "https://b23.tv/abc?x=a+b%26c", requiresSelection: true)
    let slot = base.appending(path: "Bridge/jobs/\(request.id.uuidString)")
    let catalog = DownloadCatalog(schema: 1, token: request.token, title: "Fixture", options: [
        DownloadOption(id: "video:1080", label: "1080p", audioOnly: false),
        DownloadOption(id: "audio:best", label: "只下載音訊", audioOnly: true)
    ])
    try JSONEncoder().encode(catalog).write(to: slot.appending(path: "catalog.json"))
    let status = DownloadStatus(phase: "awaitingSelection", message: "Choose", token: request.token, updated: 1)
    try JSONEncoder().encode(status).write(to: slot.appending(path: "status.json"))
    let restored = try #require(try await store.jobs().first)
    #expect(restored.request.executionMethod == .native)
    #expect(restored.catalog?.options.map(\.id) == ["video:1080", "audio:best"])
    #expect(restored.status?.phase == "awaitingSelection")
    #expect(restored.status?.terminal == false)
    #expect(restored.libraryPath == nil)
    await #expect(throws: (any Error).self) { try await store.select(request.id, optionID: "video:2160") }
    let selected = try await store.select(request.id, optionID: "audio:best")
    #expect(selected.selection == "audio:best" && selected.audioOnly)
    let queued = try #require(try await store.jobs().first)
    #expect(queued.status?.phase == "queued" && queued.libraryPath == nil)
    await #expect(throws: (any Error).self) { try await store.select(request.id, optionID: "video:1080") }
    #expect(selected.executionMethod == .native)
}

@Test("Pre-catalog and retired Shortcut jobs remain readable without executing a Shortcut")
func legacyDownloadDecoding() throws {
    let request = DownloadRequest(id: UUID(), token: UUID().uuidString, url: "https://youtu.be/abc", platform: .youtube,
                                  quality: "1080", audioOnly: false, created: 1, method: .ashell)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    legacy.removeValue(forKey: "method")
    legacy.removeValue(forKey: "requiresSelection")
    legacy.removeValue(forKey: "selection")
    let decoded = try JSONDecoder().decode(DownloadRequest.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.executionMethod == .ashell)
    #expect(decoded.requiresSelection == nil && decoded.selection == nil)
    legacy["method"] = "smgShortcut"
    #expect(try JSONDecoder().decode(DownloadRequest.self, from: JSONSerialization.data(withJSONObject: legacy)).executionMethod == .smgShortcut)
}

@Test("Catalog selection rejects another job's token and unsupported schema")
func rejectedCatalogIdentity() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let store = DownloadStore(directory: base.appending(path: "Bridge"), library: MediaLibrary(directory: base.appending(path: "Media")))
    let request = try await store.create(url: "https://youtu.be/abc", requiresSelection: true)
    let slot = base.appending(path: "Bridge/jobs/\(request.id.uuidString)")
    let status = DownloadStatus(phase: "awaitingSelection", message: "Choose", token: request.token, updated: 1)
    try JSONEncoder().encode(status).write(to: slot.appending(path: "status.json"))
    for (schema, token) in [(1, "another-job"), (3, request.token)] {
        let catalog = DownloadCatalog(schema: schema, token: token, title: "Fixture", options: [DownloadOption(id: "video:720", label: "720p", audioOnly: false)])
        try JSONEncoder().encode(catalog).write(to: slot.appending(path: "catalog.json"))
        await #expect(throws: (any Error).self) { try await store.select(request.id, optionID: "video:720") }
        #expect(try await store.jobs().first?.request.selection == nil)
    }
}

@Test("Detailed 8K60 catalog persists output policy and retry preserves partial track cache")
func advancedSelectionAndRetry() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let store = DownloadStore(directory: base.appending(path: "Bridge"), library: MediaLibrary(directory: base.appending(path: "Media")))
    let request = try await store.create(url: "https://youtu.be/fixture", requiresSelection: true, fast: true)
    let slot = base.appending(path: "Bridge/jobs/\(request.id.uuidString)")
    let option = DownloadOption(id: "v:0123456789abcdef", label: "4320p · 60 fps · AV1", audioOnly: false, height: 4320, fps: 60, videoCodec: "av1", container: "mp4", dynamicRange: "HDR10")
    let catalog = DownloadCatalog(schema: 2, token: request.token, title: "Fixture", options: [option])
    try JSONEncoder().encode(catalog).write(to: slot.appending(path: "catalog.json"))
    var status = DownloadStatus(phase: "awaitingSelection", message: "Choose", token: request.token, updated: 1)
    try JSONEncoder().encode(status).write(to: slot.appending(path: "status.json"))
    await #expect(throws: (any Error).self) { try await store.select(request.id, optionID: option.id, outputProfile: "mp3") }
    let selected = try await store.select(request.id, optionID: option.id, outputProfile: "auto", fast: true, connections: 8)
    #expect(selected.transferMode == "fast" && selected.connections == 8 && selected.outputProfile == "auto")
    #expect(try await store.jobs().first?.catalog?.options.first?.fps == 60)
    let cache = slot.appending(path: "tracks")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let partial = cache.appending(path: "track.media.part")
    try Data("partial bytes".utf8).write(to: partial)
    try Data().write(to: slot.appending(path: "cancel"))
    status.phase = "cancelled"
    try JSONEncoder().encode(status).write(to: slot.appending(path: "status.json"))
    let retry = try await store.retry(request.id)
    #expect(retry.id == request.id && retry.attempt == 1 && retry.selection == option.id)
    #expect(try Data(contentsOf: partial) == Data("partial bytes".utf8))
    #expect(!FileManager.default.fileExists(atPath: slot.appending(path: "cancel").path))
    await #expect(throws: (any Error).self) { try await store.retry(request.id) }
}

@Test("Validated output containers enter the existing library without duplicate copies", arguments: ["mp4", "webm", "m4a", "mp3", "flac", "wav"])
func advancedContainerImport(_ suffix: String) async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let output = base.appending(path: "output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: output.appending(path: "001.\(suffix)"))
    let library = MediaLibrary(directory: base.appending(path: "Media"))
    let imported = try await library.acceptDownload(from: output, id: UUID(), outputs: ["001.\(suffix)"])
    #expect(try await library.items(in: imported).first?.name == "001.\(suffix)")
    #expect(!FileManager.default.fileExists(atPath: output.path))
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
    ("https://b23.tv/abc123", .bilibili),
    ("https://www.tiktok.com/@user/video/123456", .tiktok),
    ("https://vm.tiktok.com/Abc123/", .tiktok),
    ("https://x.com/user/status/123456", .x),
    ("https://vimeo.com/123456", .vimeo),
    ("https://dai.ly/abc123", .dailymotion)
])
func acceptedDownloadURL(_ entry: (String, DownloadPlatform)) throws {
    #expect(try DownloadPlatform.identify(entry.0).1 == entry.1)
}

@Test("Native request persists safely without copying executable scripts into Documents")
func persistedRequest() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let store = DownloadStore(directory: base.appending(path: "Bridge"), library: MediaLibrary(directory: base.appending(path: "Media")))
    try await store.prepare()
    let request = try await store.create(url: "https://youtu.be/abc?x=%27%3B%20echo%20secret", quality: "720", audioOnly: true)
    #expect(request.executionMethod == .native)
    #expect(!FileManager.default.fileExists(atPath: base.appending(path: "Bridge/runner.py").path))
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
