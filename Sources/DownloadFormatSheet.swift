import SwiftUI

struct DownloadFormatSheet: View {
    let catalog: DownloadCatalog
    @Binding var selected: String
    @Environment(\.dismiss) private var dismiss
    @State private var audioOnly = false
    @State private var height = 0
    @State private var codec = ""
    @State private var fps = 0.0
    @State private var query = ""

    private var kinds: [DownloadOption] { catalog.options.filter { $0.audioOnly == audioOnly } }
    private var heights: [Int] { Array(Set(kinds.compactMap(\.height))).sorted(by: >) }
    private var codecs: [String] { Array(Set(kinds.compactMap { $0.videoCodec ?? $0.audioCodec })).sorted() }
    private var frameRates: [Double] { Array(Set(kinds.compactMap(\.fps))).sorted(by: >) }
    private var visible: [DownloadOption] {
        kinds.filter { option in
            (height == 0 || option.height == height) && (codec.isEmpty || option.videoCodec == codec || option.audioCodec == codec)
            && (fps == 0 || option.fps == fps)
            && (query.isEmpty || option.label.localizedStandardContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("內容", selection: $audioOnly) {
                        Text("影片與音訊").tag(false)
                        Text("純音訊").tag(true)
                    }.pickerStyle(.segmented)
                    if !audioOnly {
                        Picker("解析度", selection: $height) {
                            Text("全部").tag(0)
                            ForEach(heights, id: \.self) { Text("\($0)p").tag($0) }
                        }
                        Picker("影格率", selection: $fps) {
                            Text("全部").tag(0.0)
                            ForEach(frameRates, id: \.self) { Text($0.formatted(.number.precision(.fractionLength(0...3))) + " fps").tag($0) }
                        }
                    }
                    Picker("編碼", selection: $codec) {
                        Text("全部").tag("")
                        ForEach(codecs, id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                }
                Section {
                    if visible.isEmpty { Text("沒有符合的格式，請調整篩選條件。").foregroundStyle(.secondary) }
                    ForEach(visible) { option in
                        Button {
                            selected = option.id
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(option.label).foregroundStyle(.primary)
                                    if let bytes = option.estimatedBytes {
                                        Text("約 " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if option.id == selected { Image(systemName: "checkmark") }
                            }.padding(.vertical, 4)
                        }
                    }
                } header: { Text("來源實際提供的格式") }
                  footer: { Text("4K／8K、60 fps、HDR 等只有來源提供時才會出現。多影片貼文列出共同選項；選各片最高畫質可分別取得最佳來源。") }
            }
            .navigationTitle("畫質與格式")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜尋 2160、60 fps、AV1、HDR…")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("重設篩選") { height = 0; codec = ""; fps = 0; query = "" } }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .onChange(of: audioOnly) { _, _ in height = 0; codec = ""; fps = 0 }
            .task {
                if selected.isEmpty { selected = catalog.options.first?.id ?? "" }
                audioOnly = catalog.options.first(where: { $0.id == selected })?.audioOnly ?? (catalog.options.allSatisfy(\.audioOnly))
            }
        }
    }
}
