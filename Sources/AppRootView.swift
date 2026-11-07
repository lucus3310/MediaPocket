import SwiftUI

struct RootView: View {
    @State private var library: MediaLibrary
    @State private var downloads: DownloadCenterModel
    @State private var sources = SourceLibraryModel()
    @State private var selectedTab = 0

    init() {
        let library = MediaLibrary()
        _library = State(initialValue: library)
        _downloads = State(initialValue: DownloadCenterModel(store: DownloadStore(library: library)))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("檔案庫", systemImage: "folder", value: 0) {
                NavigationStack {
                    SourceLibraryView(library: library, model: sources)
                        .navigationDestination(for: String.self) { path in
                            LibraryFolderView(library: library, path: path)
                        }
                        .navigationDestination(for: SourceLocation.self) { location in
                            LinkedFolderView(model: sources, location: location)
                        }
                }
                .modifier(SourcePresentations(model: sources))
            }
            Tab("下載", systemImage: "arrow.down.circle", value: 1) {
                NavigationStack {
                    DownloadCenterView(model: downloads)
                }
            }
            Tab("設定", systemImage: "gearshape", value: 2) { SettingsView() }
        }.tint(Color(red: 0.73, green: 0.85, blue: 0.98))
            .preferredColorScheme(.dark)
            .toolbarBackground(.black, for: .tabBar)
            .onOpenURL { url in
                guard url.scheme == "mediapocket" else { return }
                selectedTab = 1
                if url.host == "download",
                   let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value {
                    downloads.link = source
                }
                Task { await downloads.refresh() }
            }
    }
}

private struct SettingsView: View {
    @AppStorage("installationNote") private var installationNote = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("MediaPocket") {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    LabeledContent("播放引擎", value: "系統播放器 + VLC")
                    LabeledContent("影片縮放", value: "雙指 1–8 倍")
                    LabeledContent("解碼偏好", value: "硬體優先，自動回退")
                }
                Section {
                    TextField("記下這次試用心得", text: $installationNote, axis: .vertical)
                } header: { Text("試用備註") }
                  footer: { Text("沿用相同 Bundle ID 覆蓋安裝。更新前請保留重要媒體的備份。") }
                Section("儲存與來源") {
                    Text("預設從原位置開啟，只記住已授權的檔案／資料夾，不另外複製影片。來源失效時可重新授權。")
                    Text("App 內檔案保存下載成品與先前匯入的副本：")
                    Text("檔案 → 我的 iPhone → MediaPocket → Media")
                    Text("刪除項目會移入 App 的垃圾桶，可由檔案庫右上角選單還原。")
                        .foregroundStyle(.secondary)
                }
                Section("開源元件") {
                    NavigationLink("VideoLAN VLCKit 與授權") { AcknowledgementsView() }
                }
            }.navigationTitle("設定")
        }
    }
}

private struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("VLCKit 與 libVLC 來自 VideoLAN，用於多格式影音播放。本 App 使用未修改的官方二進位發行版本。")
                Link("VLCKit 原始碼與建置方式", destination: URL(string: "https://github.com/videolan/vlckit/tree/6629ecb91e7e05e6b3fcbf77b17d0421cff37923")!)
                Link("VLC 原始碼", destination: URL(string: "https://code.videolan.org/videolan/vlc")!)
                Text("可依適用授權取得、修改與重新建置這些元件。MediaPocket 原始碼與建置流程公開，可用相容且自行修改的函式庫重新編譯供個人使用。")
                Text(licenseText).font(.caption.monospaced())
            }.padding().textSelection(.enabled)
        }.navigationTitle("開源授權")
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "VLCKit-COPYING", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "LGPL v2.1 or later — VideoLAN VLCKit" }
        return text
    }
}
