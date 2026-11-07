import QuickLook
import SwiftUI
import UniformTypeIdentifiers

private enum LibrarySort: String, CaseIterable {
    case name = "名稱", newest = "最新", size = "大小"
}

struct LibraryFolderView: View {
    let library: MediaLibrary
    let path: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [LibraryItem] = []
    @State private var search = ""
    @State private var sort = LibrarySort.name
    @State private var busy = false
    @State private var importer = false
    @State private var showTrash = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var renaming: LibraryItem?
    @State private var renameText = ""
    @State private var moving: LibraryItem?
    @State private var playing: LibraryItem?
    @State private var previewURL: URL?
    @State private var errorMessage: String?

    private var visible: [LibraryItem] {
        entries.filter { search.isEmpty || $0.name.localizedStandardContains(search) }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sort {
            case .name: break
            case .newest: if a.modified != b.modified { return a.modified > b.modified }
            case .size: if a.size != b.size { return a.size > b.size }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            if visible.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "加入你的檔案" : "找不到符合的檔案",
                    systemImage: search.isEmpty ? "folder.badge.plus" : "magnifyingglass",
                    description: Text(search.isEmpty ? "使用右上角的加號匯入檔案或建立資料夾。" : "試試其他名稱。")
                )
            }
            ForEach(visible) { item in
                Group {
                    if item.isDirectory {
                        NavigationLink(value: item.relativePath) { row(item) }
                    } else {
                        Button {
                            if item.isMedia { playing = item } else { previewURL = item.url }
                        } label: { row(item) }
                    }
                }
                .contextMenu {
                    Button("重新命名", systemImage: "pencil") { renameText = item.name; renaming = item }
                    Button("移動", systemImage: "folder") { moving = item }
                    Button("製作副本", systemImage: "doc.on.doc") { perform { try await library.duplicate(item.relativePath) } }
                    if !item.isDirectory { ShareLink(item: item.url) { Label("分享", systemImage: "square.and.arrow.up") } }
                    Button("移到垃圾桶", systemImage: "trash", role: .destructive) {
                        perform { try await library.moveToTrash(item.relativePath) }
                    }
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button("垃圾桶", systemImage: "trash", role: .destructive) {
                        perform { try await library.moveToTrash(item.relativePath) }
                    }
                }
            }
        }
        .navigationTitle(path.isEmpty ? "檔案庫" : (path as NSString).lastPathComponent)
        .searchable(text: $search, prompt: "搜尋此資料夾")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: $sort) {
                        ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Button("垃圾桶", systemImage: "trash") { showTrash = true }
                } label: { Label("顯示選項", systemImage: "ellipsis.circle") }
                Menu {
                    Button("匯入檔案", systemImage: "square.and.arrow.down") { importer = true }
                    Button("新增資料夾", systemImage: "folder.badge.plus") { folderName = ""; newFolder = true }
                } label: { Label("新增", systemImage: "plus") }
                .disabled(busy)
            }
        }
        .overlay { if busy { ProgressView("處理中…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .disabled(busy)
        .fileImporter(isPresented: $importer, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(item: $playing) { item in PlayerView(item: item) }
        .quickLookPreview($previewURL)
        .sheet(item: $moving, onDismiss: { Task { await reload() } }) { item in MoveDestinationView(library: library, item: item) }
        .sheet(isPresented: $showTrash, onDismiss: { Task { await reload() } }) { TrashView(library: library) }
        .alert("新增資料夾", isPresented: $newFolder) {
            TextField("資料夾名稱", text: $folderName)
            Button("建立") { perform { try await library.createFolder(named: folderName, in: path) } }
            Button("取消", role: .cancel) { }
        }
        .alert("重新命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { item in
            TextField("名稱", text: $renameText)
            Button("儲存") {
                perform { try await library.rename(item.relativePath, to: renameText) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        } message: { _ in Text("變更副檔名可能影響檔案辨識。") }
        .alert("無法完成操作", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: scenePhase) { if scenePhase == .active { Task { await reload() } } }
    }

    private func row(_ item: LibraryItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : item.isMedia ? "play.rectangle.fill" : "doc.fill")
                .font(.title2).foregroundStyle(.indigo).frame(width: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).foregroundStyle(.primary).lineLimit(2)
                if !item.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 4)
    }

    private func reload() async {
        do { entries = try await library.items(in: path) } catch { errorMessage = error.localizedDescription }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await work() } catch { errorMessage = error.localizedDescription }
            await reload()
        }
    }

    private func importFiles(_ urls: [URL]) {
        perform {
            var failures: [String] = []
            for url in urls {
                do { try await library.importFile(from: url, into: path) }
                catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }
}

private struct MoveDestinationView: View {
    let library: MediaLibrary
    let item: LibraryItem
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var folders: [LibraryItem] = []
    @State private var errorMessage: String?
    @State private var moving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(path.isEmpty ? "檔案庫" : path).foregroundStyle(.secondary)
                    if !path.isEmpty {
                        Button("上一層", systemImage: "arrow.up") {
                            let parent = (path as NSString).deletingLastPathComponent
                            path = parent == "." ? "" : parent
                        }
                    }
                }
                ForEach(folders) { folder in Button(folder.name, systemImage: "folder") { path = folder.relativePath } }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("移動「\(item.name)」").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("移到這裡") {
                        moving = true
                        Task {
                            defer { moving = false }
                            do { try await library.move(item.relativePath, into: path); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }.disabled(moving)
                }
            }
            .task(id: path) {
                do {
                    folders = try await library.items(in: path).filter {
                        $0.isDirectory && $0.relativePath != item.relativePath && !$0.relativePath.hasPrefix(item.relativePath + "/")
                    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct TrashView: View {
    let library: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var items: [TrashItem] = []
    @State private var errorMessage: String?
    @State private var restoring = false

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty { ContentUnavailableView("垃圾桶是空的", systemImage: "trash") }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name)
                        Text(item.originalPath).font(.caption).foregroundStyle(.secondary)
                        Button("還原", systemImage: "arrow.uturn.backward") {
                            restoring = true
                            Task {
                                defer { restoring = false }
                                do { try await library.restore(item); await refresh() }
                                catch { errorMessage = error.localizedDescription }
                            }
                        }.disabled(restoring)
                    }.padding(.vertical, 4)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                Section { Text("垃圾桶中的檔案仍佔用手機空間。這個版本保留項目供還原，不會自動清空。").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("垃圾桶")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        do { items = try await library.trashItems() } catch { errorMessage = error.localizedDescription }
    }
}
