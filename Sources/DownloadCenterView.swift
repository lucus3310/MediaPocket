import SwiftUI
import UIKit

@MainActor @Observable
final class DownloadCenterModel {
    var link = ""
    var quality = "1080"
    var audioOnly = false
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

    func enqueue() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let request = try await store.create(url: link, quality: quality, audioOnly: audioOnly)
            link = ""
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSetup = false

    var body: some View {
        List {
            Section {
                TextField("貼上影片或貼文的 HTTPS 連結", text: $model.link, axis: .vertical)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .lineLimit(2...4)
                Picker("最高畫質", selection: $model.quality) {
                    Text("原畫質").tag("best")
                    Text("1080p").tag("1080")
                    Text("720p").tag("720")
                }.disabled(model.audioOnly)
                Toggle("只下載音訊", isOn: $model.audioOnly)
                Button {
                    Task { await model.enqueue() }
                } label: {
                    Label("交給 a-Shell 下載", systemImage: "arrow.down.circle.fill")
                }.disabled(model.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.working || model.setup?.phase != "ready")
            } header: { Text("新增下載") }
              footer: { Text("YouTube、Instagram 影片貼文／Reels、Threads 影片、Bilibili。解析後以 FFmpeg 下載並保留原編碼；原畫質受來源、登入與格式供應限制。") }
            Section {
                Button { showSetup = true } label: {
                    Label(model.setup?.phase == "ready" ? "a-Shell 已就緒・設定與更新" : "首次使用：設定免費下載工具", systemImage: "terminal")
                }
                if let setup = model.setup { Text(setup.message).font(.footnote).foregroundStyle(.secondary) }
            }
            Section("下載任務") {
                if model.jobs.isEmpty {
                    Text("完成的影片會整批匯入「檔案庫 → Downloads」。").foregroundStyle(.secondary)
                }
                ForEach(model.jobs) { job in DownloadJobRow(job: job, model: model) }
            }
        }
        .navigationTitle("下載")
        .toolbar { Button("重新整理", systemImage: "arrow.clockwise") { Task { await model.refresh() } } }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.status?.title ?? job.request.platform.title).font(.headline).lineLimit(2)
            Text(job.request.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let path = job.libraryPath {
                Label("已匯入檔案庫", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(path).font(.caption).textSelection(.enabled)
            } else {
                Text(job.status?.message ?? "尚未執行，請在 a-Shell 完成下載。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let progress = job.status?.progress, progress.isFinite {
                    ProgressView(value: min(1, max(0, progress)))
                }
                if job.status == nil || job.status?.terminal == true {
                    Button(job.status == nil ? "在 a-Shell 執行" : "建立重試任務") {
                        Task {
                            if job.status == nil { await model.launch(DownloadStore.command(for: job.id)) }
                            else {
                                model.link = job.request.url
                                model.quality = job.request.quality
                                model.audioOnly = job.request.audioOnly
                                await model.enqueue()
                            }
                        }
                    }
                } else {
                    Button("要求取消", role: .destructive) { Task { await model.cancel(job.id) } }
                    Text("下載時請保持 a-Shell 在前景。若已停止，可在 a-Shell 按 Ctrl+C，再返回重試。取消會在安全檢查點生效。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("再次開啟任務／檢查中斷") { Task { await model.launch(DownloadStore.command(for: job.id)) } }
                }
            }
        }.padding(.vertical, 5)
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
                    Text("在選擇器中選「瀏覽 → 我的 iPhone → MediaPocket → MediaPocketBridge」，進入後按開啟。請選這個子資料夾，書籤名稱才會是 MediaPocketBridge。這個步驟也會重設舊的同名書籤。")
                    Button("2. 安裝／更新解析元件並檢查 FFmpeg") {
                        Task { await model.launch("jump MediaPocketBridge\npython3 runner.py --setup") }
                    }
                    Text("允許下載免費 Python 套件。看到檢查完成後返回本 App；若書籤失效，重新執行步驟 1。")
                }
                Section("選填：需要登入的影片") {
                    Text("將 Netscape 格式的 Cookie 檔放進「MediaPocket → MediaPocketBridge → cookies」，命名為 youtube.txt、instagram.txt、threads.txt 或 bilibili.txt。Cookie 留在手機，不會上傳 GitHub。Threads 目前只支援可公開取得的影片貼文。")
                    Text("沒有可用來源、權限不足、限流或需要額外驗證時，任務會顯示失敗原因。這個版本不處理 DRM 內容。")
                }
                Section("下載與匯入") {
                    Text("下載會切換到 a-Shell，完成後嘗試返回 MediaPocket。也可手動返回並重新整理。未完成的檔案留在任務資料夾，不會混入檔案庫。影片為 MKV、音訊為 MKA，由 VLC 播放；不會為了換副檔名重新壓縮。")
                }
            }.navigationTitle("免費下載設定")
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}
