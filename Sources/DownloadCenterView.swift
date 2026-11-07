import SwiftUI
import UIKit

@MainActor @Observable
final class DownloadCenterModel {
    var link = ""
    var jobs: [DownloadJob] = []
    var setup: DownloadStatus?
    var error: String?
    var working = false
    let store: DownloadStore

    init(store: DownloadStore) { self.store = store }

    func prepare() async {
        do {
            guard let runner = Bundle.main.url(forResource: "runner", withExtension: "py") else { throw DownloadError.missingRunner }
            try await store.prepare(runner: runner)
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
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let request = try await store.create(url: source ?? link, requiresSelection: true)
            if source == nil { link = "" }
            await refresh()
            await launch(DownloadStore.command(for: request.id, probe: true))
        } catch { self.error = error.localizedDescription }
    }

    func download(_ job: DownloadJob, optionID: String) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let request = try await store.select(job.id, optionID: optionID)
            await refresh()
            await launch(DownloadStore.command(for: request.id))
        } catch { self.error = error.localizedDescription }
    }

    func launch(_ command: String) async {
        guard let url = DownloadStore.shellURL(command: command),
              await UIApplication.shared.open(url, options: [:]) else {
            error = "無法開啟 a-Shell。請先安裝免費的完整版 a-Shell，再進行資料夾授權。"
            return
        }
    }

    func cancel(_ id: UUID) async {
        do { try await store.cancel(id); await refresh() }
        catch { self.error = error.localizedDescription }
    }
}

struct DownloadCenterView: View {
    @Bindable var model: DownloadCenterModel
    let sources: SourceLibraryModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSetup = false

    var body: some View {
        List {
            Section {
                TextField("貼上影片或貼文的 HTTPS 連結", text: $model.link, axis: .vertical)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .lineLimit(2...4)
                Button { Task { await model.scan() } } label: {
                    Label("取得可用畫質", systemImage: "list.bullet.rectangle")
                }.disabled(model.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.working || model.setup?.phase != "ready")
            } header: { Text("貼上連結") }
              footer: { Text("先切到 a-Shell 解析，再返回這裡選畫質；按下載後由 FFmpeg 下載與合併。支援 YouTube、Instagram、Threads、Bilibili，不需要捷徑。") }
            if model.setup?.phase != "ready" {
                Section {
                    Button { showSetup = true } label: {
                        Label("首次使用：設定免費下載工具", systemImage: "terminal")
                    }
                    if let setup = model.setup { Text(setup.message).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            Section("選畫質與下載任務") {
                if model.jobs.isEmpty {
                    Text("取得畫質後，選單會出現在這裡。只列出來源實際提供、可由 FFmpeg 下載的格式。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.jobs) { job in DownloadJobRow(job: job, model: model) }
            }
            Section { DownloadOutputFolderButton(sources: sources) }
        }
        .navigationTitle("下載")
        .toolbar {
            Button("下載設定", systemImage: "gearshape") { showSetup = true }
            Button("重新整理", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
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
    @State private var selected = ""

    private var selection: String {
        job.catalog?.options.contains(where: { $0.id == selected }) == true ? selected : job.catalog?.options.first?.id ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.status?.title ?? job.request.platform.title).font(.headline).lineLimit(2)
            Text(job.request.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if job.request.executionMethod == .smgShortcut {
                Text("舊版外部交接紀錄。可在 App 重新解析與選畫質，無須再執行捷徑。")
                    .font(.subheadline).foregroundStyle(.secondary)
                rescanButton
            } else if let path = job.libraryPath {
                Label("已匯入檔案庫", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(path).font(.caption).textSelection(.enabled)
            } else if job.status?.phase == "awaitingSelection", let catalog = job.catalog {
                Picker("畫質與音訊", selection: Binding(get: { selection }, set: { selected = $0 })) {
                    ForEach(catalog.options) { option in Text(option.label).tag(option.id) }
                }
                Button("交給 a-Shell 用 FFmpeg 下載", systemImage: "arrow.down.circle.fill") {
                    Task { await model.download(job, optionID: selection) }
                }.disabled(model.working || selection.isEmpty)
                Text("下載時保持 a-Shell 在前景。多影片貼文列出共同解析度；也可選各片最高可用畫質。")
                    .font(.caption).foregroundStyle(.secondary)
                rescanButton
            } else {
                Text(job.status?.message ?? "尚未執行；請開啟 a-Shell 取得畫質。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let progress = job.status?.progress, progress.isFinite {
                    ProgressView(value: min(1, max(0, progress)))
                }
                if job.status?.terminal == true || job.request.requiresSelection != true || job.status?.phase == "awaitingSelection" {
                    rescanButton
                } else {
                    Button(job.request.selection == nil ? "開啟 a-Shell 取得畫質" : "開啟 a-Shell 執行／檢查中斷") {
                        Task { await model.launch(DownloadStore.command(for: job.id, probe: job.request.selection == nil)) }
                    }
                    if job.status?.phase != "queued" {
                        Button("要求取消", role: .destructive) { Task { await model.cancel(job.id) } }
                        Text("取消在安全檢查點生效；如已中斷，可在 a-Shell 按 Ctrl+C，再重新解析。")
                            .font(.caption).foregroundStyle(.secondary)
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
    let model: DownloadCenterModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("一次設定，完全免費") {
                    Link("安裝免費完整版 a-Shell", destination: URL(string: "https://apps.apple.com/app/a-shell/id1473805438")!)
                    Button("1. 授權下載交接資料夾") {
                        Task { await model.launch("deletemark MediaPocketBridge\npickFolder") }
                    }
                    Text("選「瀏覽 → 我的 iPhone → MediaPocket → MediaPocketBridge」，進入這個子資料夾後按開啟。")
                    Button("2. 安裝／更新解析元件並檢查 FFmpeg") {
                        Task { await model.launch("jump MediaPocketBridge\npython3 runner.py --setup") }
                    }
                    Text("終端應先顯示「MediaPocket 下載程式已啟動」，再安裝 yt-dlp 與解析元件。若沒有第一行，請查看終端是否顯示資料夾或程式路徑錯誤；尚不能認定是 yt-dlp 安裝失敗。")
                }
                Section("貼連結 → 選畫質 → 下載") {
                    Text("在本 App 貼連結、按取得畫質。a-Shell 解析完成後嘗試返回 App，在任務卡片選畫質，再按 FFmpeg 下載。兩個階段均可手動返回 App 重新整理，不需要建立或執行捷徑。")
                    Text("畫質清單只保存選項，不保存會過期的影片來源網址。開始下載時重新解析，保留你選定的解析度；若來源已移除該畫質會顯示失敗，不自動降級。解析度未標示的來源仍可選最高可用畫質。")
                }
                Section("選填：需要登入的影片") {
                    Text("將 Netscape Cookie 檔放進「MediaPocket → MediaPocketBridge → cookies」，命名為 youtube.txt、instagram.txt、threads.txt 或 bilibili.txt。Cookie 留在手機。來源限制、登入驗證或限流可能導致解析失敗；不處理 DRM。")
                }
                Section("下載成品") {
                    Text("下載期間保持 a-Shell 在前景。FFmpeg 保留原編碼，影片為 MKV、音訊為 MKA。完成並驗證軌道後，返回 App 匯入「檔案庫 → App 內檔案 → Downloads」；未完成檔不匯入。也可加入其他成品資料夾，直接讀取原檔。")
                }
            }.navigationTitle("免費下載設定")
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
