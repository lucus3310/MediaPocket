import SwiftUI
import UIKit

@MainActor @Observable
final class DownloadCenterModel {
    var link = ""
    var jobs: [DownloadJob] = []
    var setup: DownloadStatus?
    var error: String?
    var working = false
    var fast = UserDefaults.standard.object(forKey: "fastDownloads") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fast, forKey: "fastDownloads") }
    }
    var connections = UserDefaults.standard.object(forKey: "downloadConnections") as? Int ?? 4 {
        didSet { UserDefaults.standard.set(connections, forKey: "downloadConnections") }
    }
    let store: DownloadStore

    init(store: DownloadStore) { self.store = store }

    private var prepared = false
    var initializing = false
    var ready: Bool { setup?.phase == "ready" && setup?.token == "native" }

    func prepare() async {
        guard !prepared else { return }
        prepared = true
        do { try await store.prepare(); try await store.recoverInterrupted() }
        catch { self.error = error.localizedDescription }
        await checkEngine()
    }

    func checkEngine() async {
        guard !working && !initializing else { return }
        initializing = true
        defer { initializing = false }
        do {
            try await store.prepare()
            setup = nil
            try await NativeDownloadEngine.run("health", directory: store.directory)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        do {
            jobs = try await store.jobs()
            setup = await store.setupStatus()
        } catch { self.error = error.localizedDescription }
    }

    func scan(_ source: String? = nil) async {
        guard ready && !working else { return }
        working = true
        defer { working = false }
        do {
            let request = try await store.create(url: source ?? link, requiresSelection: true, fast: fast)
            if source == nil { link = "" }
            await refresh()
            try await NativeDownloadEngine.run("probe", directory: store.directory, job: request.id)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func download(_ job: DownloadJob, optionID: String, profile: String) async {
        guard ready && !working else { return }
        working = true
        defer { working = false }
        do {
            let request = try await store.select(job.id, optionID: optionID, outputProfile: fast ? profile : "original", fast: fast, connections: connections)
            await refresh()
            try await NativeDownloadEngine.run("download", directory: store.directory, job: request.id)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func cancel(_ id: UUID) async {
        do {
            try await store.cancel(id)
            NativeDownloadEngine.cancel()
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func retry(_ id: UUID, original: Bool = false) async {
        guard ready && !working else { return }
        working = true
        defer { working = false }
        do {
            let request = try await store.retry(id, original: original)
            await refresh()
            try await NativeDownloadEngine.run("download", directory: store.directory, job: request.id)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
}

struct DownloadCenterView: View {
    @Bindable var model: DownloadCenterModel
    let sources: SourceLibraryModel
    let library: MediaLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSetup = false
    @FocusState private var linkFocused: Bool

    private var ready: Bool { model.ready }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("貼上影片或貼文的 HTTPS 連結", text: $model.link, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .lineLimit(2...4)
                        .focused($linkFocused)
                        .submitLabel(.done)
                        .onSubmit { linkFocused = false }
                        .accessibilityIdentifier("downloadLink")
                    if linkFocused {
                        HStack {
                            Spacer()
                            Button("收起鍵盤", systemImage: "keyboard.chevron.compact.down") { linkFocused = false }
                                .font(.subheadline)
                                .accessibilityIdentifier("dismissDownloadKeyboard")
                        }.buttonStyle(.borderless)
                    }
                }
                Button {
                    linkFocused = false
                    if ready { Task { await model.scan() } }
                    else { showSetup = true }
                } label: {
                    Label(ready ? "取得可用畫質" : model.initializing ? "內建引擎初始化中…" : "檢查內建引擎", systemImage: ready ? "list.bullet.rectangle" : "gearshape")
                }
                .accessibilityIdentifier("downloadPrimaryAction")
                .disabled(model.working || model.initializing || (ready && model.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            } header: { Text("貼上連結") }
              footer: { Text("貼連結 → 取得畫質 → 選擇來源與格式 → 開始下載與合併。FFmpeg 與解析器直接在 App 內執行。") }
            if !ready {
                Section {
                    if model.initializing { ProgressView("正在啟動 App 內建下載引擎…") }
                    else {
                        Text(model.setup?.message ?? "內建引擎尚未就緒").font(.subheadline)
                        Button("重新檢查內建引擎") { Task { await model.checkEngine() } }
                    }
                }
            }
            Section("選畫質與下載任務") {
                if model.jobs.isEmpty {
                    Text("取得畫質後，選單會出現在這裡。只列出來源實際提供、可由 FFmpeg 下載的格式。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.jobs) { job in DownloadJobRow(job: job, model: model, library: library) }
            }
            Section { DownloadOutputFolderButton(sources: sources) }
        }
        .navigationTitle("下載")
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(for: String.self) { LibraryFolderView(library: library, path: $0) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("下載設定", systemImage: "gearshape") { linkFocused = false; showSetup = true }
                Button("重新整理", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起鍵盤", systemImage: "keyboard.chevron.compact.down") { linkFocused = false }
                    .accessibilityIdentifier("dismissDownloadKeyboardAccessory")
            }
        }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $showSetup) { DownloadSetupView(model: model) }
        .alert("下載提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .task {
            await model.prepare()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                if scenePhase == .active { await model.refresh() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }
}

private struct DownloadJobRow: View {
    let job: DownloadJob
    let model: DownloadCenterModel
    let library: MediaLibrary
    @State private var selected = ""
    @State private var profile = "auto"
    @State private var showFormats = false

    private var selection: String {
        job.catalog?.options.contains(where: { $0.id == selected }) == true ? selected : job.catalog?.options.first?.id ?? ""
    }
    private var option: DownloadOption? { job.catalog?.options.first(where: { $0.id == selection }) }
    private var profiles: [(String, String)] {
        option?.audioOnly == true
        ? [("original", "原編碼 MKA"), ("m4a", "M4A・AAC"), ("mp3", "MP3・320 kb/s"), ("flac", "FLAC"), ("wav", "WAV")]
        : [("auto", "自動無損 MP4／MKV"), ("original", "原編碼 MKV"), ("mp4", "MP4・需要時自動轉碼"), ("h264", "MP4・H.264 相容轉碼"), ("hevc", "MP4・HEVC 轉碼"), ("webm", "WebM・原編碼")]
    }
    private var outputProfile: String { profiles.contains(where: { $0.0 == profile }) ? profile : "original" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.status?.title ?? job.request.platform.title).font(.headline).lineLimit(2)
            Text(job.request.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if job.request.executionMethod != .native && job.libraryPath == nil {
                Text("舊版外部交接紀錄。可在 App 重新解析與選畫質，無須再執行捷徑。")
                    .font(.subheadline).foregroundStyle(.secondary)
                rescanButton
            } else if let path = job.libraryPath {
                Label("已匯入檔案庫", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(path).font(.caption).textSelection(.enabled)
                NavigationLink {
                    LibraryFolderView(library: library, path: path)
                } label: {
                    Label("播放／管理下載成品", systemImage: "play.rectangle")
                }
            } else if job.status?.phase == "awaitingSelection", let catalog = job.catalog {
                Button { showFormats = true } label: {
                    HStack {
                        Text("來源畫質")
                        Spacer()
                        Text(option?.label ?? "選擇格式").foregroundStyle(.tint).multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                }.sheet(isPresented: $showFormats) { DownloadFormatSheet(catalog: catalog, selected: $selected) }
                if let size = option?.estimatedBytes {
                    Text("預估來源大小：約 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.fast {
                    Picker("儲存格式", selection: Binding(get: { outputProfile }, set: { profile = $0 })) {
                        ForEach(profiles, id: \.0) { entry in Text(entry.1).tag(entry.0) }
                    }
                    if ["mp4", "h264", "hevc", "m4a", "mp3", "flac", "wav"].contains(outputProfile) {
                        Text("需要轉碼時會耗時、耗電，且不會提升來源畫質／音質。HDR 建議保留原編碼。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("開始下載與合併", systemImage: "arrow.down.circle.fill") {
                    Task { await model.download(job, optionID: selection, profile: outputProfile) }
                }.disabled(model.working || selection.isEmpty)
                Text(model.fast ? "支援分段加速與失敗後續傳；FFmpeg 合併／轉碼完成後自動清理軌道暫存。請保持本 App 在前景。" : "FFmpeg 直接下載，保留 MKV／MKA 原編碼；分片來源請改用加速模式。")
                    .font(.caption).foregroundStyle(.secondary)
                rescanButton
            } else {
                Text(job.status?.message ?? "等待內建引擎處理任務。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let progress = job.status?.progress, progress.isFinite {
                    ProgressView(value: min(1, max(0, progress)))
                }
                if job.status?.terminal == true || job.request.requiresSelection != true || job.status?.phase == "awaitingSelection" {
                    if job.request.selection != nil && ["failed", "cancelled"].contains(job.status?.phase ?? "") {
                        Button("重試／續傳相同任務", systemImage: "arrow.clockwise") { Task { await model.retry(job.id) } }
                        if let output = job.request.outputProfile, !["original", "auto"].contains(output) {
                            Button("改用原編碼重試（沿用軌道暫存）") { Task { await model.retry(job.id, original: true) } }
                        }
                    }
                    rescanButton
                } else {
                    if model.working {
                        Button("取消任務", role: .destructive) { Task { await model.cancel(job.id) } }
                        Text("取消會保留可續傳的軌道暫存，不匯入未完成檔案。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        // A killed app cannot keep executing native FFmpeg. An
                        // interrupted record can be cancelled and resumed safely.
                        Button("標記中斷並重試") { Task { await model.cancel(job.id); await model.scan(job.request.url) } }
                    }
                }
            }
        }.padding(.vertical, 5).buttonStyle(.borderless)
    }

    private var rescanButton: some View {
        Button("重新取得可用畫質") { Task { await model.scan(job.request.url) } }.disabled(model.working)
    }
}

private struct DownloadSetupView: View {
    @Bindable var model: DownloadCenterModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("下載效能") {
                    Toggle("分段加速與續傳", isOn: $model.fast)
                    Picker("同時下載分段數", selection: $model.connections) {
                        ForEach([1, 2, 4, 8], id: \.self) { Text("\($0) 段").tag($0) }
                    }.disabled(!model.fast)
                    Text("預設 4 段，適用原生 HLS／DASH 分段下載；一般 HTTP 檔案不會強制分塊。網路或平台限流時可降為 1–2 段。關閉後使用直接 FFmpeg 原編碼下載。")
                }
                Section("App 內建引擎") {
                    Label(model.ready ? "內建 FFmpeg 已就緒" : "引擎檢查中／未就緒", systemImage: model.ready ? "checkmark.circle.fill" : "gearshape")
                    Text("FFmpeg、ffprobe、CPython 與 yt-dlp 隨 App 安裝。解析、下載、合併與轉檔均在本 App 執行，無須額外安裝工具或授權交接資料夾。")
                    Button("重新檢查內建引擎") { Task { await model.checkEngine() } }
                        .disabled(model.working || model.initializing)
                    if let status = model.setup { Text(status.message).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("貼連結 → 選畫質 → 下載") {
                    Text("在本 App 貼連結、按取得畫質，在任務卡片選畫質及輸出格式，按「開始下載與合併」。請保持 App 在前景，切到背景時 iOS 可能暫停下載。")
                    Text("支援 YouTube、Instagram、Threads、Bilibili、TikTok、X／Twitter、Vimeo、Dailymotion。實際格式受來源、地區及登入權限限制。清單保存解析度、fps、編碼等條件；下載時重新取得有效來源，不自動降級。")
                }
                Section("選填：需要登入的影片") {
                    Text("Netscape Cookie 檔放進「MediaPocket → MediaPocketBridge → cookies」，命名為 youtube.txt、instagram.txt、threads.txt、bilibili.txt、tiktok.txt、x.txt、vimeo.txt 或 dailymotion.txt。Cookie 留在手機；不處理 DRM。")
                }
                Section("下載成品") {
                    Text("完成並驗證軌道後，自動加入「檔案庫 → App 內檔案 → Downloads」，可直接管理和播放。分段模式在合併期間需要軌道暫存與成品空間；成功後清理暫存，失敗時保留供續傳。已加入來源資料夾仍從原位置讀取，不複製原影片。")
                }
            }.navigationTitle("下載設定")
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}

private struct DownloadOutputFolderButton: View {
    let sources: SourceLibraryModel
    @State private var showPicker = false
    @State private var message: String?
    var body: some View {
        Button("加入其他成品資料夾（原位置）", systemImage: "folder.badge.plus") { showPicker = true }
            .sheet(isPresented: $showPicker) {
                OriginalSourcePicker(mode: .folder) { result in
                    showPicker = false
                    Task {
                        do {
                            for url in try result.get() {
                                let added = try await sources.store.add(url)
                                await sources.refresh()
                                message = "已加入「\(added.name)」。到檔案庫開啟即可直接讀原檔。"
                            }
                        } catch { message = error.localizedDescription }
                    }
                }.ignoresSafeArea()
            }
            .alert("成品資料夾", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("知道了") { message = nil }
            } message: { Text(message ?? "") }
    }
}
