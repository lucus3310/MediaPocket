import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    var body: some View {
        TabView {
            Tab("檔案庫", systemImage: "folder") {
                LibraryView()
            }
            Tab("下載", systemImage: "arrow.down.circle") {
                NavigationStack {
                    ContentUnavailableView(
                        "下載功能準備中",
                        systemImage: "arrow.down.circle",
                        description: Text("這個版本先驗證安裝、檔案匯入與播放。FFmpeg 與平台下載將分階段加入。")
                    )
                    .navigationTitle("下載")
                }
            }
            Tab("設定", systemImage: "gearshape") {
                InstallationView()
            }
        }
        .tint(.indigo)
    }
}

private struct LibraryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = LibraryModel()
    @State private var showingImporter = false
    @State private var selectedItem: LibraryItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("你的影音，放在一起", systemImage: "play.rectangle.on.rectangle")
                        .font(.headline)
                    Text("從「檔案」匯入影片或音訊，保存在這部 iPhone。")
                        .foregroundStyle(.secondary)
                }

                Section("本機媒體") {
                    if model.items.isEmpty {
                        ContentUnavailableView(
                            "加入第一個檔案",
                            systemImage: "folder.badge.plus",
                            description: Text("點右上角的加號匯入影片或音訊。")
                        )
                    } else {
                        ForEach(model.items) { item in
                            Button {
                                selectedItem = item
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "play.rectangle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.indigo)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name).foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .accessibilityHint("播放這個檔案")
                        }
                    }
                }

                Section {
                    Text("目前使用系統播放器。更多格式、音軌與字幕功能將於後續版本加入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("檔案庫")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("匯入媒體", systemImage: "plus") {
                        showingImporter = true
                    }
                    .disabled(model.isImporting)
                }
            }
            .overlay {
                if model.isImporting {
                    ProgressView("正在匯入…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.movie, .audio],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await model.importFiles(urls) }
                case .failure(let error):
                    model.errorMessage = error.localizedDescription
                }
            }
            .sheet(item: $selectedItem) { item in
                PlayerView(item: item)
            }
            .alert("無法完成操作", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .refreshable { await model.refresh() }
            .task { await model.refresh() }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task { await model.refresh() }
                }
            }
        }
    }
}

private struct InstallationView: View {
    @AppStorage("installationNote") private var installationNote = ""
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("MediaPocket") {
                    LabeledContent("版本", value: version)
                    LabeledContent("目前階段", value: "安裝驗證版")
                }
                Section {
                    TextField("例如：第一次安裝成功", text: $installationNote, axis: .vertical)
                } header: {
                    Text("更新驗證備註")
                } footer: {
                    Text("更新或刷新簽署後，確認這段備註與匯入的檔案仍保留。請使用相同 Bundle ID 更新，避免先刪除 App。")
                }
                Section("檔案位置") {
                    Text("在「檔案」App → 我的 iPhone → MediaPocket → Media，可找到匯入的檔案。")
                }
                Section("開發進度") {
                    Label("檔案匯入與系統播放", systemImage: "folder")
                    Text("接下來：FFmpeg、更多播放格式、平台連結下載。")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
        }
    }
}
