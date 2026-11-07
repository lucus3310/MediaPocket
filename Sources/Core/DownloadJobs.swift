import Foundation

enum DownloadPlatform: String, Codable, CaseIterable, Sendable {
    case youtube, instagram, threads, bilibili
    var title: String {
        switch self {
        case .youtube: "YouTube"
        case .instagram: "Instagram"
        case .threads: "Threads"
        case .bilibili: "Bilibili"
        }
    }

    static func identify(_ text: String) throws -> (URL, Self) {
        guard text.utf8.count < 8192,
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { throw DownloadError.invalidURL }
        let path = url.path
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let platform: Self
        switch host {
        case "youtu.be":
            guard path.count > 1 else { throw DownloadError.invalidURL }; platform = .youtube
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com":
            guard (path == "/watch" && components?.queryItems?.contains(where: { $0.name == "v" && !($0.value ?? "").isEmpty }) == true)
                    || ["/shorts/", "/live/", "/embed/"].contains(where: { path.hasPrefix($0) && path.count > $0.count })
            else { throw DownloadError.invalidURL }
            platform = .youtube
        case "instagram.com", "www.instagram.com":
            guard ["/p/", "/reel/", "/reels/", "/tv/"].contains(where: { path.hasPrefix($0) && path.count > $0.count }) else { throw DownloadError.invalidURL }
            platform = .instagram
        case "threads.net", "www.threads.net", "threads.com", "www.threads.com":
            guard path.range(of: #"^/(?:@[^/]+/post|t|share)/[A-Za-z0-9_-]+/?$"#, options: .regularExpression) != nil else { throw DownloadError.invalidURL }
            platform = .threads
        case "b23.tv":
            guard path.count > 1 else { throw DownloadError.invalidURL }; platform = .bilibili
        case "bilibili.com", "www.bilibili.com", "m.bilibili.com":
            guard path.range(of: #"^/video/(?:BV[A-Za-z0-9]+|av[0-9]+)/?$"#, options: .regularExpression) != nil else { throw DownloadError.invalidURL }
            platform = .bilibili
        default: throw DownloadError.invalidURL
        }
        return (url, platform)
    }
}

enum DownloadError: LocalizedError {
    case invalidURL, invalidResult, missingRunner
    var errorDescription: String? {
        switch self {
        case .invalidURL: "請貼上 HTTPS 影片或貼文連結：YouTube、Instagram、Threads 或 Bilibili。頻道與整份播放清單暫不支援。"
        case .invalidResult: "下載結果尚未完成或不符合預期，已保留原始檔，請查看任務狀態。"
        case .missingRunner: "找不到隨 App 附帶的下載程式，請重新安裝這個版本。"
        }
    }
}

struct DownloadRequest: Codable, Identifiable, Sendable {
    let id: UUID
    let token: String
    let url: String
    let platform: DownloadPlatform
    let quality: String
    let audioOnly: Bool
    let created: Double
}

struct DownloadStatus: Codable, Sendable {
    var phase: String
    var message: String
    var progress: Double?
    var title: String?
    var outputs: [String]?
    var token: String
    var updated: Double

    var terminal: Bool { ["complete", "failed", "cancelled"].contains(phase) }
}

struct DownloadJob: Identifiable, Sendable {
    let request: DownloadRequest
    let status: DownloadStatus?
    let libraryPath: String?
    var id: UUID { request.id }
}

// Disk files form the IPC boundary. A callback is only a wake-up hint; media is
// accepted from known local jobs after manifest and file validation.
actor DownloadStore {
    let directory: URL
    private let files = FileManager.default
    private let library: MediaLibrary

    init(directory: URL = URL.documentsDirectory.appending(path: "MediaPocketBridge"), library: MediaLibrary) {
        self.directory = directory
        self.library = library
    }

    func prepare(runner: URL) throws {
        try files.createDirectory(at: directory.appending(path: "jobs"), withIntermediateDirectories: true)
        try files.createDirectory(at: directory.appending(path: "cookies"), withIntermediateDirectories: true)
        let destination = directory.appending(path: "runner.py")
        let data = try Data(contentsOf: runner)
        if (try? Data(contentsOf: destination)) != data { try data.write(to: destination, options: .atomic) }
    }

    func create(url: String, quality: String, audioOnly: Bool) throws -> DownloadRequest {
        let (source, platform) = try DownloadPlatform.identify(url)
        let request = DownloadRequest(id: UUID(), token: UUID().uuidString,
                                      url: source.absoluteString, platform: platform,
                                      quality: ["best", "1080", "720"].contains(quality) ? quality : "1080",
                                      audioOnly: audioOnly, created: Date().timeIntervalSince1970)
        let slot = jobDirectory(request.id)
        try files.createDirectory(at: slot, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: slot.appending(path: "request.json"), options: .atomic)
        return request
    }

    func jobs() async throws -> [DownloadJob] {
        let root = directory.appending(path: "jobs")
        let slots = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        var result: [DownloadJob] = []
        for slot in slots {
            guard try slot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  let id = UUID(uuidString: slot.lastPathComponent),
                  let data = try? Data(contentsOf: slot.appending(path: "request.json")),
                  let request = try? JSONDecoder().decode(DownloadRequest.self, from: data), request.id == id else { continue }
            var status = (try? Data(contentsOf: slot.appending(path: "status.json")))
                .flatMap { try? JSONDecoder().decode(DownloadStatus.self, from: $0) }
            if status?.token != request.token { status = nil }
            let receipt = slot.appending(path: "imported.json")
            var path = (try? Data(contentsOf: receipt)).flatMap { try? JSONDecoder().decode(String.self, from: $0) }
            if path == nil, let current = status, current.phase == "complete", let outputs = current.outputs {
                do {
                    path = try await library.acceptDownload(from: slot.appending(path: "output"), id: id, outputs: outputs)
                    try JSONEncoder().encode(path!).write(to: receipt, options: .atomic)
                } catch {
                    status?.message = "匯入未完成：\(error.localizedDescription)；可重新整理重試。"
                }
            }
            result.append(DownloadJob(request: request, status: status, libraryPath: path))
        }
        return result.sorted { $0.request.created > $1.request.created }
    }

    func cancel(_ id: UUID) throws {
        try Data("cancel".utf8).write(to: jobDirectory(id).appending(path: "cancel"), options: .atomic)
    }

    func setupStatus() -> DownloadStatus? {
        guard let data = try? Data(contentsOf: directory.appending(path: "setup.json")) else { return nil }
        return try? JSONDecoder().decode(DownloadStatus.self, from: data)
    }

    static func shellURL(command: String) -> URL? {
        let encoded = command.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        return encoded.flatMap { URL(string: "ashell://" + $0) }
    }

    static func command(for id: UUID) -> String {
        // a-Shell's URL entry point splits commands on newlines, not semicolons.
        "jump MediaPocketBridge\npython3 runner.py --job \(id.uuidString)"
    }

    private func jobDirectory(_ id: UUID) -> URL {
        directory.appending(path: "jobs").appending(path: id.uuidString)
    }
}
