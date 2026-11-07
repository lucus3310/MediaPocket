#if DEBUG
import Foundation

// CI-only cold-process check. Release builds contain no probe implementation;
// ordinary Debug launches do nothing without the explicit simctl environment.
enum SourceRestorationProbe {
    struct Manifest: Codable {
        let fileID: UUID
        let folderID: UUID
        let originalURL: URL
        let prefix: Data
        let originalSize: Int64
    }
    static var catalogDirectory: URL { URL.applicationSupportDirectory.appending(path: "SourceRestoreTestCatalog") }
    static var fixtureDirectory: URL { URL.documentsDirectory.appending(path: "SourceRestoreFixture") }
    static var manifestURL: URL { fixtureDirectory.appending(path: "manifest.json") }
    static var resultURL: URL { URL.documentsDirectory.appending(path: "SourceColdLaunchResult.json") }

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.environment["MEDIAPOCKET_SOURCE_PROBE"] == "1" else { return }
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            let store = LinkedSourceStore(directory: catalogDirectory)
            let sources = try await store.sources()
            guard sources.count == 2 else { throw LinkedSourceError.invalidCatalog }
            let file = try await store.prepareOpen(SourceLocation(sourceID: manifest.fileID, path: ""))
            let nested = try await store.prepareOpen(SourceLocation(sourceID: manifest.folderID, path: "clip.mov"))
            for item in [file, nested] {
                guard item.url.resolvingSymlinksInPath() == manifest.originalURL.resolvingSymlinksInPath(),
                      item.size == manifest.originalSize else { throw LinkedSourceError.invalidPath }
                let access = try item.accessRoot.map { try ScopedFileAccess(url: $0) }
                defer { access?.close() }
                let handle = try FileHandle(forReadingFrom: item.url)
                let prefix = try handle.read(upToCount: manifest.prefix.count)
                try handle.close()
                guard prefix == manifest.prefix else { throw LinkedSourceError.invalidPath }
            }
            let catalogBytes = try Data(contentsOf: catalogDirectory.appending(path: "sources.json")).count
            let report: [String: Any] = [
                "passed": true, "coldProcessLaunch": true, "sourcesRestored": sources.count,
                "sameOriginalURL": true, "originalBytesVerified": true, "catalogBytes": catalogBytes,
                "physicalIphone": false, "externalFileProviderGrantsVerified": false,
                "scope": "Real iOS bookmarks across process restart using App-owned test fixtures"
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: resultURL, options: .atomic)
        } catch {
            let report: [String: Any] = ["passed": false, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: resultURL, options: .atomic)
        }
    }
}
#endif
