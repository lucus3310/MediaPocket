import Foundation
import Testing
@testable import MediaPocket

@MainActor
struct NativeDownloadTests {
    @Test("Bundled CPython, WebKit JS, HTTP download, FFmpeg merge/transcode and ffprobe run inside iOS")
    func inProcessPipeline() async throws {
        let root = URL.documentsDirectory.appending(path: "NativeEngineTests")
        try await NativeDownloadEngine.run("health", directory: root)
        let status = try JSONDecoder().decode(DownloadStatus.self, from: Data(contentsOf: root.appending(path: "native-engine.json")))
        try #require(status.phase == "ready", "\(status.message)")
        try await NativeDownloadEngine.run("smoke", directory: root)
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "native-engine-tests.json"))) as? [String: Any])
        #expect(report["passed"] as? Bool == true)
    }
}
