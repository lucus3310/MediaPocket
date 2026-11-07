import AVKit
import SwiftUI

private enum PlaybackEngine: String { case system, vlc }

struct PlayerView: View {
    let item: LibraryItem
    @Environment(\.dismiss) private var dismiss
    @State private var chosenEngine: PlaybackEngine?

    private var engine: PlaybackEngine {
        chosenEngine ?? (["mp4", "mov", "m4v", "m4a", "mp3", "aac", "wav"].contains(item.url.pathExtension.lowercased()) ? .system : .vlc)
    }

    var body: some View {
        NavigationStack {
            Group {
                if engine == .vlc { VLCFrameView(item: item) }
                else { SystemFrameView(item: item, fallback: chosenEngine == nil ? { chosenEngine = .vlc } : nil) }
            }
            .background(.black)
            .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("系統播放器", systemImage: engine == .system ? "checkmark" : "play.rectangle") { chosenEngine = .system }
                        Button("多格式 VLC", systemImage: engine == .vlc ? "checkmark" : "play.rectangle") { chosenEngine = .vlc }
                    } label: { Label("播放引擎", systemImage: "slider.horizontal.3") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }.preferredColorScheme(.dark).tint(.white)
    }
}

private struct SystemFrameView: View {
    let item: LibraryItem
    let fallback: (() -> Void)?
    @State private var session = SystemPlaybackSession()
    @State private var zoom = 1.0
    @State private var requestedZoom = 1.0
    @State private var zoomRequest = 0
    @AppStorage("playbackRate") private var rate = 1.0

    var body: some View {
        ZoomableVideoSurface(scale: $zoom, requestedScale: requestedZoom, requestID: zoomRequest,
            makeCanvas: { SystemVideoCanvas(player: session.player) }, cleanup: { session.stop() })
            .overlay(alignment: .topTrailing) {
                ZoomMenu(scale: zoom) { requestedZoom = $0; zoomRequest += 1 }.padding(12)
            }
            .overlay { if let error = session.errorMessage { Text(error).foregroundStyle(.white).padding() } }
            .overlay(alignment: .bottom) {
                FrameTransport(
                    position: session.position, seconds: session.seconds, duration: session.duration,
                    playing: session.playing, ready: session.ready, busy: session.stepping || session.traversing,
                    forward: session.canStepForward, backward: session.canStepBackward,
                    message: session.stepMessage, range: session.range, rate: $rate,
                    toggle: { session.toggle(rate: Float(rate)) }, pause: { session.pause() },
                    seek: { value in Task { await session.seek(value) } },
                    step: { count in Task { _ = await session.stepFrames(count) } },
                    mark: { session.markRange($0) }, toggleRange: { session.toggleRange() }, clearRange: { session.clearRange() }
                ).padding(.horizontal, 12).padding(.bottom, 8)
            }
            .task {
                await session.prepare(item)
                if session.playing { session.player.rate = Float(rate) }
                while !Task.isCancelled {
                    session.refresh()
                    if session.unsupported { fallback?(); break }
                    await session.serviceRange()
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
            }
            .onChange(of: rate) { if session.playing { session.player.rate = Float(rate) } }
            .onDisappear { session.stop() }
    }
}

private struct VLCFrameView: View {
    let item: LibraryItem
    @State private var session = VLCPlaybackSession()
    @State private var zoom = 1.0
    @State private var requestedZoom = 1.0
    @State private var zoomRequest = 0
    @AppStorage("playbackRate") private var rate = 1.0

    var body: some View {
        ZoomableVideoSurface(scale: $zoom, requestedScale: requestedZoom, requestID: zoomRequest,
            makeCanvas: {
                let canvas = UIView()
                canvas.backgroundColor = .black
                session.player.drawable = canvas
                return canvas
            }, cleanup: { session.stop(); session.player.drawable = nil })
            .overlay(alignment: .topTrailing) {
                ZoomMenu(scale: zoom) { requestedZoom = $0; zoomRequest += 1 }.padding(12)
            }
            .overlay { if let error = session.errorMessage { Text(error).foregroundStyle(.white).padding() } }
            .overlay(alignment: .bottom) {
                FrameTransport(
                    position: session.position, seconds: session.seconds, duration: session.duration,
                    playing: session.playing, ready: session.ready, busy: session.stepping || session.traversing,
                    forward: session.ready && session.player.hasVideoOut,
                    backward: session.ready && session.seekable && session.player.hasVideoOut && session.seconds > 0,
                    message: session.stepMessage, range: session.range, rate: $rate,
                    toggle: { session.toggle(rate: Float(rate)) }, pause: { session.pause() }, seek: { session.seek($0) },
                    step: { count in Task { _ = await session.stepFrames(count) } },
                    mark: { session.markRange($0) }, toggleRange: { session.toggleRange() }, clearRange: { session.clearRange() }
                ).padding(.horizontal, 12).padding(.bottom, 8)
            }
            .task {
                session.start(item)
                var appliedRate = false
                while !Task.isCancelled {
                    session.refresh()
                    if session.ready, !appliedRate { session.player.rate = Float(rate); appliedRate = true }
                    await session.serviceRange()
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
            }
            .onChange(of: rate) { if session.playing { session.player.rate = Float(rate) } }
            .onDisappear { session.stop() }
    }
}

private struct ZoomMenu: View {
    let scale: Double
    let setZoom: (Double) -> Void
    var body: some View {
        Menu {
            ForEach([1.0, 2, 4, 8], id: \.self) { value in
                Button(value == 1 ? "重置為 1×" : "\(Int(value))×") { setZoom(value) }
            }
        } label: {
            Text("\(scale.formatted(.number.precision(.fractionLength(1))))×")
                .font(.caption.monospacedDigit()).frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(.white).background(.black.opacity(0.65), in: Capsule())
        }.accessibilityLabel("影片縮放，目前 \(scale.formatted()) 倍，最高八倍")
    }
}

// The small dock follows the supplied FramePocket references. Less-used tools
// live in menus/sheets; collapsing the timeline keeps frame transport available.
struct FrameTransport: View {
    let position: Double
    let seconds: Double
    let duration: Double
    let playing: Bool
    let ready: Bool
    let busy: Bool
    let forward: Bool
    let backward: Bool
    let message: String?
    let range: PlaybackRange
    @Binding var rate: Double
    let toggle: () -> Void
    let pause: () -> Void
    let seek: (Double) -> Void
    let step: (Int) -> Void
    let mark: (PlaybackRangePoint) -> Void
    let toggleRange: () -> Void
    let clearRange: () -> Void
    @AppStorage("frameJump") private var frameJump = 10
    @State private var collapsed = false
    @State private var showRange = false
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var jumpCount: Int { [5, 10, 30, 60].contains(frameJump) ? frameJump : 10 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showRange = true } label: {
                    Text("A–B").font(.caption.weight(.semibold)).foregroundStyle(range.enabled ? .cyan : .primary)
                        .frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel(range.enabled ? "A–B 循環已開啟，編輯範圍" : "編輯 A–B 片段")
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { collapsed.toggle() }
                } label: {
                    Capsule().fill(.secondary).frame(width: 32, height: 4).frame(maxWidth: .infinity, minHeight: 44)
                }.accessibilityLabel(collapsed ? "展開時間軸" : "收起時間軸")
                Menu {
                    Picker("播放速度", selection: $rate) {
                        ForEach([0.1, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text("\($0.formatted())×").tag($0) }
                    }
                    Picker("跨幀步長", selection: $frameJump) {
                        ForEach([5, 10, 30, 60], id: \.self) { Text("\($0) 幀").tag($0) }
                    }
                    Button("定位與 A–B 片段") { showRange = true }
                    Text("硬體優先 · 雙指 1–8× · 雙擊重置")
                } label: {
                    Text("\(rate.formatted())×").font(.caption.monospacedDigit()).frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("播放速度 \(rate.formatted()) 倍與跨幀設定")
            }
            if !collapsed {
                VStack(spacing: 0) {
                    HStack {
                        Text(timestamp(scrubbing ? scrubPosition * duration : seconds))
                        Spacer()
                        if range.enabled { Image(systemName: "repeat").foregroundStyle(.cyan) }
                        Text(timestamp(duration))
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { scrubbing ? scrubPosition : position }, set: { scrubPosition = $0 }), in: 0...1) { editing in
                        if editing { scrubPosition = position; scrubbing = true }
                        else { seek(scrubPosition); scrubbing = false }
                    }.disabled(!ready || busy || !duration.isFinite || duration <= 0).accessibilityLabel("播放進度")
                }.padding(.horizontal, 8)
            }
            HStack(spacing: 4) {
                frameButton(-jumpCount, available: backward)
                frameButton(-1, available: backward)
                Button(action: toggle) {
                    Group {
                        if busy { ProgressView().tint(.black) }
                        else { Image(systemName: playing ? "pause.fill" : "play.fill").font(.title3) }
                    }.foregroundStyle(.black).frame(width: 50, height: 50)
                        .background(.white, in: Circle())
                }.accessibilityLabel(busy ? "正在移動畫格" : (playing ? "暫停" : "播放")).disabled(!ready || busy)
                frameButton(1, available: forward)
                frameButton(jumpCount, available: forward)
            }.padding(.bottom, 6)
            if let message, !["上一幀", "下一幀"].contains(message) {
                Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2).padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false) }
        .sheet(isPresented: $showRange) { rangeEditor }
    }

    private func frameButton(_ count: Int, available: Bool) -> some View {
        Button { step(count) } label: {
            VStack(spacing: 1) {
                Text(count > 0 ? "+\(count)" : "−\(abs(count))").font(.callout.monospacedDigit().weight(.medium))
                Text("幀").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 48)
        }.disabled(!available || busy).accessibilityLabel("\(count > 0 ? "前進" : "後退") \(abs(count)) 幀")
    }

    private var rangeEditor: some View {
        NavigationStack {
            Form {
                Section("目前位置") {
                    Text(timestamp(seconds)).monospacedDigit()
                    HStack {
                        Button("後退 5 秒") { pause(); jump(-5) }
                        Spacer()
                        Button("前進 5 秒") { pause(); jump(5) }
                    }.disabled(!ready || busy)
                }
                Section("A–B 片段") {
                    LabeledContent("A 起點", value: range.start.map(timestamp) ?? "尚未設定")
                    LabeledContent("B 終點", value: range.end.map(timestamp) ?? "尚未設定")
                    HStack {
                        Button("將目前位置設為 A") { mark(.a) }
                        Spacer()
                        Button("設為 B") { mark(.b) }
                    }.disabled(!ready || busy)
                    HStack {
                        Button("跳至 A") { if let start = range.start { pause(); seek(start / duration) } }.disabled(range.start == nil || busy)
                        Spacer()
                        Button("跳至 B") { if let end = range.end { pause(); seek(end / duration) } }.disabled(range.end == nil || busy)
                    }
                    Button(range.enabled ? "關閉循環" : "啟用循環", systemImage: "repeat", action: toggleRange)
                        .disabled(!range.isValid || !ready || busy)
                    Button("清除範圍", role: .destructive, action: clearRange)
                }
                Section {
                    Text("設定 A、B 時會暫停；啟用循環後按播放。手動移到範圍外會關閉循環，換片時清除範圍。")
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
            }.navigationTitle("定位與片段").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { showRange = false } }
        }.presentationDetents([.medium, .large])
    }

    private func jump(_ delta: Double) { if duration.isFinite, duration > 0 { seek((seconds + delta) / duration) } }
    private func timestamp(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "--:--.---" }
        let whole = Int(value)
        return String(format: "%02d:%02d:%06.3f", whole / 3600, (whole / 60) % 60, value.truncatingRemainder(dividingBy: 60))
    }
}
