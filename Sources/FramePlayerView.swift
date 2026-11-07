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
            .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("系統播放器", systemImage: engine == .system ? "checkmark" : "play.rectangle") { chosenEngine = .system }
                        Button("多格式 VLC", systemImage: engine == .vlc ? "checkmark" : "play.rectangle") { chosenEngine = .vlc }
                    } label: { Label("播放引擎", systemImage: "slider.horizontal.3") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

private struct SystemFrameView: View {
    let item: LibraryItem
    let fallback: (() -> Void)?
    @State private var session = SystemPlaybackSession()
    @State private var zoom = 1.0
    @State private var requestedZoom = 1.0
    @State private var zoomRequest = 0
    @State private var rate: Float = 1

    var body: some View {
        VStack(spacing: 0) {
            ZoomableVideoSurface(scale: $zoom, requestedScale: requestedZoom, requestID: zoomRequest,
                makeCanvas: { SystemVideoCanvas(player: session.player) }, cleanup: { session.stop() })
                .overlay(alignment: .topTrailing) {
                    ZoomMenu(scale: zoom) { requestedZoom = $0; zoomRequest += 1 }.padding(12)
                }
                .overlay { if let error = session.errorMessage { Text(error).foregroundStyle(.white).padding() } }
            FrameTransport(
                position: session.position, seconds: session.seconds, duration: session.duration,
                playing: session.playing, ready: session.ready, busy: session.stepping,
                forward: session.canStepForward, backward: session.canStepBackward,
                message: session.stepMessage, rate: $rate,
                toggle: { session.toggle(rate: rate) },
                seek: { value in Task { await session.seek(value) } },
                step: { direction in Task { _ = await session.stepFrame(direction) } }
            )
        }
        .task {
            await session.prepare(item)
            while !Task.isCancelled {
                session.refresh()
                if session.unsupported {
                    if let fallback { fallback() }
                    break
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
        .onChange(of: rate) { if session.playing { session.player.rate = rate } }
        .onDisappear { session.stop() }
    }
}

private struct VLCFrameView: View {
    let item: LibraryItem
    @State private var session = VLCPlaybackSession()
    @State private var zoom = 1.0
    @State private var requestedZoom = 1.0
    @State private var zoomRequest = 0
    @State private var rate: Float = 1

    var body: some View {
        VStack(spacing: 0) {
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
            FrameTransport(
                position: session.position, seconds: session.seconds, duration: session.duration,
                playing: session.playing, ready: session.ready, busy: session.stepping,
                forward: session.ready && session.player.hasVideoOut,
                backward: session.ready && session.seekable && session.player.hasVideoOut && session.seconds > 0,
                message: session.stepMessage, rate: $rate,
                toggle: { session.toggle(rate: rate) }, seek: { session.seek($0) },
                step: { direction in Task { _ = await session.stepFrame(direction) } }
            )
        }
        .task {
            session.start(item)
            while !Task.isCancelled {
                session.refresh()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
        .onChange(of: rate) { if session.playing { session.player.rate = rate } }
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
            Label("\(scale.formatted(.number.precision(.fractionLength(1))))×", systemImage: "plus.magnifyingglass")
                .font(.caption.monospacedDigit()).padding(8)
                .foregroundStyle(.white).background(.black.opacity(0.65), in: Capsule())
        }
        .accessibilityLabel("影片縮放，目前 \(scale.formatted()) 倍，最高八倍")
    }
}

private struct FrameTransport: View {
    let position: Double
    let seconds: Double
    let duration: Double
    let playing: Bool
    let ready: Bool
    let busy: Bool
    let forward: Bool
    let backward: Bool
    let message: String?
    @Binding var rate: Float
    let toggle: () -> Void
    let seek: (Double) -> Void
    let step: (Int) -> Void
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0

    var body: some View {
        VStack(spacing: 10) {
            Slider(value: Binding(get: { scrubbing ? scrubPosition : position }, set: { scrubPosition = $0 }), in: 0...1) { editing in
                if editing { scrubPosition = position; scrubbing = true }
                else { seek(scrubPosition); scrubbing = false }
            }.disabled(!ready || busy || !duration.isFinite || duration <= 0).accessibilityLabel("播放進度")
            HStack {
                Text(timestamp(seconds))
                Spacer()
                Text(timestamp(duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack {
                Button("上一幀", systemImage: "backward.end") { step(-1) }
                    .disabled(!backward || busy).frame(maxWidth: .infinity, minHeight: 44)
                Button(playing ? "暫停" : "播放", systemImage: playing ? "pause.fill" : "play.fill", action: toggle)
                    .labelStyle(.iconOnly).font(.title).frame(width: 60, height: 44).disabled(!ready || busy)
                Button("下一幀", systemImage: "forward.end") { step(1) }
                    .disabled(!forward || busy).frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderless)
            HStack {
                Button("倒退十秒", systemImage: "gobackward.10") { jump(-10) }.labelStyle(.iconOnly)
                Spacer()
                Picker("速度", selection: $rate) {
                    ForEach([Float(0.25), 0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in Text("\(value.formatted())×").tag(value) }
                }.pickerStyle(.menu)
                Spacer()
                Button("快轉十秒", systemImage: "goforward.10") { jump(10) }.labelStyle(.iconOnly)
            }.disabled(!ready || busy)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Text("硬體優先 · 雙指最高 8× · 輕點兩下重置")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal).padding(.vertical, 10)
    }

    private func jump(_ delta: Double) { if duration.isFinite, duration > 0 { seek((seconds + delta) / duration) } }
    private func timestamp(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "--:--.---" }
        let whole = Int(value)
        return String(format: "%02d:%02d:%06.3f", whole / 3600, (whole / 60) % 60, value.truncatingRemainder(dividingBy: 60))
    }
}
