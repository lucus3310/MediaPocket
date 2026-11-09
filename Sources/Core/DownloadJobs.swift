import Foundation

enum DownloadPlatform: String, Codable, CaseIterable, Sendable {
    case youtube, instagram, threads, bilibili, tiktok, x, vimeo, dailymotion
    var title: String {
        switch self {
        case .youtube: "YouTube"
        case .instagram: "Instagram"
        case .threads: "Threads"
        case .bilibili: "Bilibili"
        case .tiktok: "TikTok"
        case .x: "X／Twitter"
        case .vimeo: "Vimeo"
        case .dailymotion: "Dailymotion"
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
        case "tiktok.com", "www.tiktok.com":
            guard path.range(of: #"^/(?:@[^/]+/video/[0-9]+|t/[A-Za-z0-9_-]+)/?$"#, options: .regularExpression) != nil else { throw DownloadError.invalidURL }; platform = .tiktok
        case "vm.tiktok.com", "vt.tiktok.com":
            guard path.range(of: #"^/[A-Za-z0-9_-]+/?$"#, options: .regularExpression) != nil else { throw DownloadError.invalidURL }; platform = .tiktok
        case "x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com":
            guard path.range(of: #"^/[^/]+/status/[0-9]+/?$"#, options: .regularExpression) != nil else { throw DownloadError.invalidURL }; platform = .x
        case "vimeo.com", "www.vimeo.com", "player.vimeo.com":
            guard path.range(of: #"^/(?:video/)?[0-9]+(?:/[A-Za-z0-9]+)?/?$"#, options: .regularExpression) != nil else { throw DownloadError.invalidURL }; platform = .vimeo
        case "dailymotion.com", "www.dailymotion.com":
            guard path.range(of: #"^/video/[A-Za-z0-9]+/?$"#, options: .regularExpression) != nil else { throw DownloadError.invalidURL }; platform = .dailymotion
        case "dai.ly":
            guard path.range(of: #"^/[A-Za-z0-9]+/?$"#, options: .regularExpression) != nil else { throw DownloadError.invalidURL }; platform = .dailymotion
        default: throw DownloadError.invalidURL
        }
        return (url, platform)
    }
}

enum DownloadError: LocalizedError {
    case invalidURL, invalidResult, missingRunner, invalidSelection
    var errorDescription: String? {
        switch self {
        case .invalidURL: "請貼上支援平台的 HTTPS 單一影片或貼文連結。頻道與整份播放清單暫不支援。"
        case .invalidResult: "下載結果尚未完成或不符合預期，已保留原始檔，請查看任務狀態。"
        case .missingRunner: "找不到隨 App 附帶的下載程式，請重新安裝這個版本。"
        case .invalidSelection: "畫質清單或任務狀態已變更，請重新取得可用畫質。"
        }
    }
}

// External methods are decode-only compatibility; all new jobs run in-process.
enum DownloadMethod: String, Codable, Sendable { case native, smgShortcut, ashell }

struct DownloadOption: Codable, Identifiable, Sendable {
    let id: String
    let label: String
    let audioOnly: Bool
    var height: Int? = nil
    var fps: Double? = nil
    var videoCodec: String? = nil
    var audioCodec: String? = nil
    var container: String? = nil
    var dynamicRange: String? = nil
    var estimatedBytes: Int64? = nil
}

struct DownloadCatalog: Codable, Sendable {
    let schema: Int
    let token: String
    let title: String
    let options: [DownloadOption]
}

struct DownloadRequest: Codable, Identifiable, Sendable {
    let id: UUID
    let token: String
    let url: String
    let platform: DownloadPlatform
    let quality: String
    var audioOnly: Bool
    let created: Double
    let method: DownloadMethod?
    var requiresSelection: Bool? = nil
    var selection: String? = nil
    var outputProfile: String? = nil
    var transferMode: String? = nil
    var connections: Int? = nil
    var attempt: Int? = nil

    var executionMethod: DownloadMethod { method ?? .ashell }
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
    let catalog: DownloadCatalog?
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

    func prepare() throws {
        try files.createDirectory(at: directory.appending(path: "jobs"), withIntermediateDirectories: true)
        try files.createDirectory(at: directory.appending(path: "cookies"), withIntermediateDirectories: true)
    }

    // Called once after a process launch, before any engine work is scheduled.
    // Killed/suspended processes leave resumable tracks, never a live worker.
    func recoverInterrupted() throws {
        let root = directory.appending(path: "jobs")
        for slot in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            guard try slot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  let data = try? Data(contentsOf: slot.appending(path: "request.json")),
                  let request = try? JSONDecoder().decode(DownloadRequest.self, from: data),
                  request.executionMethod == .native else { continue }
            let path = slot.appending(path: "status.json")
            guard let previous = try? Data(contentsOf: path),
                  var status = try? JSONDecoder().decode(DownloadStatus.self, from: previous),
                  status.token == request.token, !status.terminal, status.phase != "awaitingSelection" else { continue }
            status.phase = "failed"
            status.message = "上次任務已中斷，可重試／續傳；已保留軌道暫存。"
            status.progress = nil
            status.updated = Date().timeIntervalSince1970
            try JSONEncoder().encode(status).write(to: path, options: .atomic)
        }
    }

    func create(url: String, quality: String = "best", audioOnly: Bool = false, requiresSelection: Bool = false, fast: Bool = false) throws -> DownloadRequest {
        let (source, platform) = try DownloadPlatform.identify(url)
        let request = DownloadRequest(id: UUID(), token: UUID().uuidString,
                                      url: source.absoluteString, platform: platform,
                                      quality: ["best", "1080", "720"].contains(quality) ? quality : "1080",
                                      audioOnly: audioOnly, created: Date().timeIntervalSince1970, method: .native, requiresSelection: requiresSelection,
                                      transferMode: fast ? "fast" : nil, connections: fast ? 4 : nil)
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
            if request.executionMethod != .smgShortcut, path == nil, let current = status, current.phase == "complete", let outputs = current.outputs {
                do {
                    path = try await library.acceptDownload(from: slot.appending(path: "output"), id: id, outputs: outputs)
                    try JSONEncoder().encode(path!).write(to: receipt, options: .atomic)
                } catch {
                    status?.message = "匯入未完成：\(error.localizedDescription)；可重新整理重試。"
                }
            }
            let catalog = try? readCatalog(slot: slot, token: request.token)
            result.append(DownloadJob(request: request, status: status, libraryPath: path, catalog: catalog))
        }
        return result.sorted { $0.request.created > $1.request.created }
    }

    func cancel(_ id: UUID) throws {
        try Data("cancel".utf8).write(to: jobDirectory(id).appending(path: "cancel"), options: .atomic)
    }

    func select(_ id: UUID, optionID: String, outputProfile: String = "original", fast: Bool? = nil, connections: Int = 4) throws -> DownloadRequest {
        let slot = jobDirectory(id)
        var request = try JSONDecoder().decode(DownloadRequest.self, from: Data(contentsOf: slot.appending(path: "request.json")))
        let status = try JSONDecoder().decode(DownloadStatus.self, from: Data(contentsOf: slot.appending(path: "status.json")))
        guard request.id == id, request.executionMethod == .native, request.requiresSelection == true,
              status.phase == "awaitingSelection", status.token == request.token,
              !files.fileExists(atPath: slot.appending(path: "cancel").path),
              !files.fileExists(atPath: slot.appending(path: "imported.json").path) else { throw DownloadError.invalidSelection }
        let catalog = try readCatalog(slot: slot, token: request.token)
        guard let option = catalog.options.first(where: { $0.id == optionID }) else { throw DownloadError.invalidSelection }
        let allowed = option.audioOnly ? ["original", "m4a", "mp3", "flac", "wav"] : ["original", "auto", "mp4", "h264", "hevc", "webm"]
        guard allowed.contains(outputProfile), [1, 2, 4, 8].contains(connections) else { throw DownloadError.invalidSelection }
        request.selection = option.id
        request.audioOnly = option.audioOnly
        request.outputProfile = outputProfile
        if let fast { request.transferMode = fast ? "fast" : nil }
        request.connections = connections
        try JSONEncoder().encode(request).write(to: slot.appending(path: "request.json"), options: .atomic)
        let queued = DownloadStatus(phase: "queued", message: "已選擇 \(option.label)，準備在 App 內下載。", token: request.token, updated: Date().timeIntervalSince1970)
        try JSONEncoder().encode(queued).write(to: slot.appending(path: "status.json"), options: .atomic)
        return request
    }

    func retry(_ id: UUID, original: Bool = false, fast: Bool? = nil) throws -> DownloadRequest {
        let slot = jobDirectory(id)
        var request = try JSONDecoder().decode(DownloadRequest.self, from: Data(contentsOf: slot.appending(path: "request.json")))
        let status = try JSONDecoder().decode(DownloadStatus.self, from: Data(contentsOf: slot.appending(path: "status.json")))
        guard request.id == id, request.executionMethod == .native, request.selection != nil,
              status.token == request.token, ["failed", "cancelled"].contains(status.phase),
              !files.fileExists(atPath: slot.appending(path: "imported.json").path) else { throw DownloadError.invalidSelection }
        request.attempt = (request.attempt ?? 0) + 1
        if original { request.outputProfile = "original" }
        if let fast { request.transferMode = fast ? "fast" : nil }
        if files.fileExists(atPath: slot.appending(path: "cancel").path) { try files.removeItem(at: slot.appending(path: "cancel")) }
        try JSONEncoder().encode(request).write(to: slot.appending(path: "request.json"), options: .atomic)
        let queued = DownloadStatus(phase: "queued", message: request.transferMode == "fast" ? "正在重試；相同來源格式的暫存會嘗試續傳。" : "FFmpeg 將重新讀取來源下載。", token: request.token, updated: Date().timeIntervalSince1970)
        try JSONEncoder().encode(queued).write(to: slot.appending(path: "status.json"), options: .atomic)
        return request
    }

    private func readCatalog(slot: URL, token: String) throws -> DownloadCatalog {
        let url = slot.appending(path: "catalog.json")
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 524288 else { throw DownloadError.invalidSelection }
        let catalog = try JSONDecoder().decode(DownloadCatalog.self, from: Data(contentsOf: url))
        guard [1, 2].contains(catalog.schema), catalog.token == token, !catalog.options.isEmpty, catalog.options.count <= 160,
              Set(catalog.options.map(\.id)).count == catalog.options.count,
              catalog.options.allSatisfy({ $0.id.range(of: #"^(video:(best|[0-9]{1,5})|audio:best|[va]:[a-f0-9]{16})$"#, options: .regularExpression) != nil && $0.audioOnly == ($0.id == "audio:best" || $0.id.hasPrefix("a:")) && !$0.label.isEmpty && $0.label.count <= 200 }) else { throw DownloadError.invalidSelection }
        return catalog
    }

    func setupStatus() -> DownloadStatus? {
        guard let data = try? Data(contentsOf: directory.appending(path: "native-engine.json")) else { return nil }
        return try? JSONDecoder().decode(DownloadStatus.self, from: data)
    }

    private func jobDirectory(_ id: UUID) -> URL {
        directory.appending(path: "jobs").appending(path: id.uuidString)
    }
}
