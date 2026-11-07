import QuickLook
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class SourceLibraryModel {
    let store: LinkedSourceStore
    var sources: [LinkedSource] = []
    var issues: [UUID: String] = [:]
    var error: String?
    var preparing = false
    var selecting = false
    var playing: LibraryItem?
    var previewURL: URL?
    private var previewAccess: ScopedFileAccess?

    init(store: LinkedSourceStore = LinkedSourceStore()) { self.store = store }

    func refresh() async {
        do { sources = try await store.sources() }
        catch { self.error = error.localizedDescription }
    }

    func add(_ urls: [URL], replacing id: UUID? = nil) async -> LinkedSource? {
        guard !preparing else { return nil }
        preparing = true
        defer { preparing = false }
        var first: LinkedSource?
        var failures: [String] = []
        for url in urls {
            do {
                let record = try await store.add(url, replacing: id)
                if first == nil { first = record }
                issues[record.id] = nil
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        await refresh()
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
        return first
    }

    func forget(_ source: LinkedSource) async {
        do { try await store.forget(source.id); issues[source.id] = nil; await refresh() }
        catch { self.error = error.localizedDescription }
    }

    func open(_ location: SourceLocation) async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        do {
            let item = try await store.prepareOpen(location)
            guard !Task.isCancelled else { return }
            issues[location.sourceID] = nil
            if item.isMedia { playing = item }
            else {
                closePreviewAccess()
                if let root = item.accessRoot { previewAccess = try ScopedFileAccess(url: root) }
                previewURL = item.url
            }
        } catch {
            issues[location.sourceID] = error.localizedDescription
            self.error = error.localizedDescription
        }
    }

    func closePreviewAccess() { previewAccess?.close(); previewAccess = nil }
}

struct SourcePresentations: ViewModifier {
    @Bindable var model: SourceLibraryModel
    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $model.playing) { item in PlayerView(item: item) }
            .quickLookPreview($model.previewURL)
            .onChange(of: model.previewURL) { _, url in if url == nil { model.closePreviewAccess() } }
            .overlay {
                if model.preparing {
                    ProgressView("正在準備原檔…")
                        .padding(24).background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
            .alert("來源提示", isPresented: Binding(get: { model.error != nil && !model.selecting }, set: { if !$0 { model.error = nil } })) {
                Button("知道了") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}

private enum SourcePickerMode: Equatable { case files, folder }
private struct SourcePickerRequest: Identifiable {
    let id = UUID()
    let mode: SourcePickerMode
    var replacing: UUID? = nil
}

// `.open`, never `.import`: providers return the selected original URL.
private struct OriginalSourcePicker: UIViewControllerRepresentable {
    let mode: SourcePickerMode
    let completed: @MainActor (Result<[URL], any Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completed: completed) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: mode == .folder ? [.folder] : [.data], asCopy: false)
        picker.delegate = context.coordinator
        // Use the default single selection, including on iOS 26/27 where some
        // providers have issues changing allowsMultipleSelection for folders.
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completed: @MainActor (Result<[URL], any Error>) -> Void
        init(completed: @escaping @MainActor (Result<[URL], any Error>) -> Void) { self.completed = completed }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completed(.success(urls)) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completed(.success([])) }
    }
}

struct SourceLibraryView: View {
    let library: MediaLibrary
    @Bindable var model: SourceLibraryModel
    @State private var picker: SourcePickerRequest?
    @State private var pickerDismissed = true
    @State private var pendingOpen: SourceLocation?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                if model.sources.isEmpty {
                    ContentUnavailableView("從原位置開始", systemImage: "folder.badge.plus",
                        description: Text("選取影片或加入整個資料夾，保留原檔，不另外複製。下次開啟 App 仍會保留來源。"))
                    Button("原位置開啟影片／檔案", systemImage: "play.rectangle") { choose(.files) }
                    Button("加入整個資料夾", systemImage: "folder.badge.plus") { choose(.folder) }
                }
                ForEach(model.sources) { source in
                    Group {
                        if source.kind == .folder {
                            NavigationLink(value: SourceLocation(sourceID: source.id, path: "")) { sourceRow(source) }
                        } else {
                            Button { Task { await model.open(SourceLocation(sourceID: source.id, path: "")) } } label: { sourceRow(source) }
                        }
                    }
                    .contextMenu {
                        Button("重新授權／選擇位置", systemImage: "folder.badge.gearshape") {
                            choose(source.kind == .folder ? .folder : .files, replacing: source.id)
                        }
                        Button("移除來源・保留原檔", systemImage: "minus.circle", role: .destructive) {
                            Task { await model.forget(source) }
                        }
                    }
                }
            } header: { Text("原位置來源") }
              footer: { Text("只保存來源位置與授權紀錄。播放雲端影片時，檔案提供者可能先下載原檔。來源失效時可長按重新授權。") }
            Section {
                NavigationLink {
                    LibraryFolderView(library: library, path: "")
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("App 內檔案")
                            Text("下載成品與先前複製的匯入檔").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "internaldrive") }
                }
            }
        }
        .navigationTitle("檔案庫")
        .toolbar {
            Menu {
                Button("原位置開啟影片／檔案", systemImage: "play.rectangle") { choose(.files) }
                Button("加入整個資料夾", systemImage: "folder.badge.plus") { choose(.folder) }
            } label: { Label("加入原位置來源", systemImage: "plus") }.disabled(model.preparing)
        }
        .sheet(item: $picker, onDismiss: { pickerDismissed = true; model.selecting = false; openWhenDismissed() }) { request in
            OriginalSourcePicker(mode: request.mode) { result in
                picker = nil
                switch result {
                case .success(let urls):
                    Task {
                        if let added = await model.add(urls, replacing: request.replacing), added.kind == .file {
                            pendingOpen = SourceLocation(sourceID: added.id, path: "")
                            openWhenDismissed()
                        }
                    }
                case .failure(let error): model.error = error.localizedDescription
                }
            }.ignoresSafeArea()
        }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refresh() } } }
    }

    private func choose(_ mode: SourcePickerMode, replacing id: UUID? = nil) {
        pickerDismissed = false
        model.selecting = true
        picker = SourcePickerRequest(mode: mode, replacing: id)
    }
    private func openWhenDismissed() {
        guard pickerDismissed, let location = pendingOpen else { return }
        pendingOpen = nil
        Task { await model.open(location) }
    }
    private func sourceRow(_ source: LinkedSource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.kind == .folder ? "folder.fill" : "play.rectangle.fill")
                .font(.title2).frame(width: 32).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name).foregroundStyle(.primary).lineLimit(2)
                Text(model.issues[source.id] == nil ? "原位置 · \(source.kind == .folder ? "資料夾" : "檔案")" : "請長按重新授權")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

struct LinkedFolderView: View {
    @Bindable var model: SourceLibraryModel
    let location: SourceLocation
    @State private var entries: [LibraryItem] = []
    @State private var query = ""
    @State private var mediaOnly = true
    @State private var loading = false
    @State private var problem: String?
    @Environment(\.scenePhase) private var scenePhase

    private var visible: [LibraryItem] {
        entries.filter { item in
            (item.isDirectory || !mediaOnly || item.isMedia) && (query.isEmpty || item.name.localizedStandardContains(query))
        }.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
    private var title: String {
        location.path.isEmpty ? model.sources.first(where: { $0.id == location.sourceID })?.name ?? "來源資料夾" : (location.path as NSString).lastPathComponent
    }

    var body: some View {
        List {
            if let problem {
                Section {
                    Text(problem).foregroundStyle(.secondary)
                    Button("重新讀取") { Task { await reload() } }
                    Text("若授權失效，請返回來源清單，長按來源重新授權。")
                }
            } else if !loading && visible.isEmpty {
                ContentUnavailableView("沒有符合的項目", systemImage: "folder",
                    description: Text(mediaOnly ? "可從右上角選單改為顯示所有檔案。" : "這個資料夾目前沒有可顯示的檔案。"))
            }
            ForEach(visible) { item in
                if item.isDirectory {
                    NavigationLink(value: SourceLocation(sourceID: location.sourceID, path: childPath(item))) { row(item) }
                } else {
                    Button { Task { await model.open(SourceLocation(sourceID: location.sourceID, path: childPath(item))) } } label: { row(item) }
                }
            }
            Section {
                Label("從原位置讀取", systemImage: "link").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "搜尋此資料夾")
        .toolbar { Menu { Toggle("只顯示影音", isOn: $mediaOnly) } label: { Label("顯示選項", systemImage: "line.3.horizontal.decrease") } }
        .overlay { if loading { ProgressView("讀取清單…").padding(20).background(.regularMaterial, in: .rect(cornerRadius: 16)) } }
        .task(id: location) { await reload() }
        .refreshable { await reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await reload() } } }
    }

    private func childPath(_ item: LibraryItem) -> String {
        location.path.isEmpty ? item.name : location.path + "/" + item.name
    }
    private func row(_ item: LibraryItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : item.isMedia ? "play.rectangle.fill" : "doc.fill")
                .font(.title2).frame(width: 32).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).foregroundStyle(.primary).lineLimit(2)
                if !item.isDirectory { Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 4)
    }
    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await model.store.items(at: location)
            guard !Task.isCancelled else { return }
            entries = result; problem = nil
        } catch {
            guard !Task.isCancelled else { return }
            problem = error.localizedDescription
            model.issues[location.sourceID] = error.localizedDescription
        }
    }
}
