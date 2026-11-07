import AVKit
import Observation
import SwiftUI
import VLCKit

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
                if engine == .vlc {
                    VLCPlayerView(item: item)
                } else {
                    SystemPlayerView(item: item, fallback: chosenEngine == nil ? { chosenEngine = .vlc } : nil)
                }
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

private struct SystemPlayerView: View {
    let item: LibraryItem
    let fallback: (() -> Void)?
    @State private var player = AVPlayer()
    @State private var errorMessage: String?
    private var resumeKey: String { "resumeSeconds:\(item.relativePath)" }

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView("目前無法播放", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else { VideoPlayer(player: player) }
        }
        .task {
            do {
                let asset = AVURLAsset(url: item.url)
                guard try await asset.load(.isPlayable) else { unsupported(); return }
                guard !Task.isCancelled else { return }
                try configureAudio()
                let current = AVPlayerItem(asset: asset)
                player.replaceCurrentItem(with: current)
                let saved = UserDefaults.standard.double(forKey: resumeKey)
                let duration = try await asset.load(.duration).seconds
                if saved > 2, duration.isFinite, saved < duration - 3 {
                    await player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
                }
                guard !Task.isCancelled else { return }
                player.play()
                while !Task.isCancelled {
                    if current.status == .failed { unsupported(); return }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
        .onDisappear {
            let seconds = player.currentTime().seconds
            if seconds.isFinite, seconds > 0 { UserDefaults.standard.set(seconds, forKey: resumeKey) }
            player.pause()
            player.replaceCurrentItem(with: nil)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func unsupported() {
        if let fallback { fallback() }
        else { errorMessage = "系統播放器無法播放這個媒體，可由左上角切換到 VLC。" }
    }
}

@MainActor
private func configureAudio() throws {
    let audio = AVAudioSession.sharedInstance()
    try audio.setCategory(.playback, mode: .moviePlayback)
    try audio.setActive(true)
}

@MainActor
@Observable
private final class VLCSession {
    @ObservationIgnored let player = VLCMediaPlayer()
    private(set) var position = 0.0
    private(set) var playing = false
    private(set) var seekable = false
    private(set) var elapsed = "0:00"
    private(set) var duration = "0:00"
    private(set) var errorMessage: String?
    private var resumeKey = ""
    private var pendingResume: Double?
    private var started = false

    func start(_ item: LibraryItem) {
        guard !started else { return }
        do {
            try configureAudio()
            guard let media = VLCMedia(url: item.url) else { errorMessage = "無法開啟這個檔案。"; return }
            resumeKey = "resumeSeconds:\(item.relativePath)"
            pendingResume = UserDefaults.standard.double(forKey: resumeKey)
            player.media = media
            started = true
            player.play()
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() {
        position = min(max(Double(player.position), 0), 1)
        playing = player.isPlaying
        seekable = player.isSeekable
        elapsed = player.time.stringValue
        duration = player.media?.length.stringValue ?? "0:00"
        let total = Double(player.media?.length.intValue ?? 0) / 1000
        if seekable, total > 0, let saved = pendingResume {
            pendingResume = nil
            if saved > 2, saved < total - 3 { player.position = saved / total }
        }
        if player.state == .error { errorMessage = "VLC 無法解碼這個媒體，請確認檔案完整性或改用系統播放器。" }
    }

    func seek(_ value: Double) { player.position = min(max(value, 0), 1) }
    func toggle() { if player.isPlaying { player.pause() } else { player.play() }; refresh() }
    func stop() {
        guard started else { return }
        if pendingResume == nil {
            let seconds = Double(player.time.intValue) / 1000
            if seconds.isFinite, seconds >= 0 { UserDefaults.standard.set(seconds, forKey: resumeKey) }
        }
        started = false
        player.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private struct VLCPlayerView: View {
    let item: LibraryItem
    @State private var session = VLCSession()
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var rate: Float = 1

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                VLCSurface(session: session)
                if let error = session.errorMessage {
                    Text(error).foregroundStyle(.white).multilineTextAlignment(.center).padding()
                }
            }
            VStack(spacing: 12) {
                Slider(value: Binding(
                    get: { scrubbing ? scrubPosition : session.position },
                    set: { scrubPosition = $0 }
                ), in: 0...1) { editing in
                    if editing { scrubPosition = session.position; scrubbing = true }
                    else { session.seek(scrubPosition); scrubbing = false }
                }
                .disabled(!session.seekable)
                .accessibilityLabel("播放進度")
                HStack {
                    Text(session.elapsed)
                    Spacer()
                    Text(session.duration)
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack(spacing: 32) {
                    Button("倒退十秒", systemImage: "gobackward.10") { session.player.jumpBackward(10) }
                        .disabled(!session.seekable)
                    Button(session.playing ? "暫停" : "播放", systemImage: session.playing ? "pause.fill" : "play.fill") { session.toggle() }
                        .font(.title)
                    Button("快轉十秒", systemImage: "goforward.10") { session.player.jumpForward(10) }
                        .disabled(!session.seekable)
                }.labelStyle(.iconOnly).buttonStyle(.borderless)
                Picker("播放速度", selection: $rate) {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in
                        Text("\(value.formatted())×").tag(value)
                    }
                }.pickerStyle(.menu)
                .onChange(of: rate) { session.player.rate = rate }
            }.padding()
        }
        .task {
            session.start(item)
            while !Task.isCancelled {
                session.refresh()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
        .onDisappear { session.stop() }
    }
}

private struct VLCSurface: UIViewRepresentable {
    let session: VLCSession
    func makeCoordinator() -> VLCSession { session }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        session.player.drawable = view
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { }
    static func dismantleUIView(_ uiView: UIView, coordinator: VLCSession) {
        coordinator.stop()
        coordinator.player.drawable = nil
    }
}
