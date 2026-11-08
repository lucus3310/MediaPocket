import Foundation
import Testing
import UIKit
@testable import MediaPocket

@MainActor
struct NativeDownloadTests {
    @Test("YouTube's bundled WebKit provider delivers console results inside iOS")
    func javaScriptMessageChannel() async throws {
        let previousBlocks = ResolverWebViewPolicy.shared.blockedNavigations
        let root = URL.documentsDirectory.appending(path: "NativeEngineTests")
        try await NativeDownloadEngine.run("js-smoke", directory: root)
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "native-js-tests.json"))) as? [String: Any])
        #expect(report["passed"] as? Bool == true)
        #expect(report["consoleResult"] as? Int == 3)
        #expect(ResolverWebViewPolicy.shared.blockedNavigations > previousBlocks)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        #expect(scene?.windows.contains(where: { $0.rootViewController?.presentedViewController != nil }) != true)
    }

    @Test("Bundled CPython, HTTP download, FFmpeg merge/transcode and ffprobe run inside iOS")
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
