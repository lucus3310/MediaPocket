import AVKit
import Observation
import VLCKit

@MainActor
func configurePlaybackAudio() throws {
    let audio = AVAudioSession.sharedInstance()
    try audio.setCategory(.playback, mode: .moviePlayback)
    try audio.setActive(true)
}

@MainActor
@Observable
final class SystemPlaybackSession {
    @ObservationIgnored let player = AVPlayer()
    private(set) var position = 0.0
    private(set) var seconds = 0.0
    private(set) var duration = 0.0
    private(set) var playing = false
    private(set) var ready = false
    private(set) var canStepForward = false
    private(set) var canStepBackward = false
    private(set) var stepping = false
    private(set) var unsupported = false
    private(set) var errorMessage: String?
    private(set) var stepMessage: String?
    private var resumeKey = ""
    private var stopped = true
    private var mutedTracks: [AVPlayerItemTrack] = []

    func prepare(_ item: LibraryItem, autoplay: Bool = true, resume: Bool = true) async {
        stopped = false
        resumeKey = "resumeSeconds:\(item.relativePath)"
        do {
            let asset = AVURLAsset(url: item.url)
            guard try await asset.load(.isPlayable) else {
                unsupported = true
                errorMessage = "系統播放器無法播放這個媒體，可由左上角切換 VLC。"
                return
            }
            duration = try await asset.load(.duration).seconds
            guard !Task.isCancelled, !stopped else { return }
            try configurePlaybackAudio()
            let current = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: current)
            let saved = resume ? UserDefaults.standard.double(forKey: resumeKey) : 0
            if saved > 2, duration.isFinite, saved < duration - 3 {
                await player.seek(to: CMTime(seconds: saved, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            guard !Task.isCancelled, !stopped else { return }
            if autoplay { player.play() }
            refresh()
        } catch { if !Task.isCancelled, !stopped { errorMessage = error.localizedDescription } }
    }

    func refresh() {
        guard let current = player.currentItem else { return }
        ready = current.status == .readyToPlay
        unsupported = current.status == .failed
        if unsupported { errorMessage = "系統播放器無法解碼這個媒體，可由左上角切換 VLC。" }
        let time = current.currentTime().seconds
        seconds = time.isFinite ? max(time, 0) : 0
        if duration.isFinite, duration > 0 { position = min(max(seconds / duration, 0), 1) }
        playing = player.rate != 0
        canStepForward = ready && current.canStepForward
        canStepBackward = ready && current.canStepBackward && seconds > 0
    }

    func toggle(rate: Float) {
        guard !stepping else { return }
        restoreAudioTracks()
        if player.rate != 0 { player.pause() } else { player.playImmediately(atRate: rate) }
        refresh()
    }

    func seek(_ position: Double) async {
        guard !stepping, duration.isFinite, duration > 0 else { return }
        restoreAudioTracks()
        await player.seek(to: CMTime(seconds: min(max(position, 0), 1) * duration, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
        refresh()
    }

    // AVPlayerItem chooses the adjacent video sample. No 1/fps estimate is used,
    // so variable-frame-rate clips retain their actual sample spacing.
    func stepFrame(_ direction: Int) async -> Bool {
        guard !stepping, !stopped, let current = player.currentItem,
              current.status == .readyToPlay,
              (direction == 1 || direction == -1),
              (direction == 1 ? current.canStepForward : current.canStepBackward) else { return false }
        stepping = true
        defer { stepping = false }
        player.pause()
        if mutedTracks.isEmpty {
            mutedTracks = current.tracks.filter { $0.isEnabled && $0.assetTrack?.mediaType != .video }
            mutedTracks.forEach { $0.isEnabled = false }
        }
        let before = current.currentTime()
        current.step(byCount: direction)
        for _ in 0..<200 {
            guard !Task.isCancelled, !stopped else { return false }
            if CMTimeCompare(current.currentTime(), before) != 0 {
                refresh()
                stepMessage = direction > 0 ? "下一幀" : "上一幀"
                return true
            }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        refresh()
        stepMessage = "已到邊界，或此來源無法完成這次逐幀。"
        return false
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        let time = player.currentTime().seconds
        if time.isFinite, time > 0 { UserDefaults.standard.set(time, forKey: resumeKey) }
        player.pause()
        restoreAudioTracks()
        player.replaceCurrentItem(with: nil)
        ready = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restoreAudioTracks() {
        mutedTracks.forEach { $0.isEnabled = true }
        mutedTracks.removeAll()
    }
}

// The ObjC delegate can arrive outside the UI actor. Only its integer result is
// transferred; the player object itself never crosses into the Task.
private final class VLCFrameDelegate: NSObject, VLCMediaPlayerDelegate {
    let receive: @Sendable (Int) -> Void
    init(receive: @escaping @Sendable (Int) -> Void) { self.receive = receive }
    func mediaPlayer(_ player: VLCMediaPlayer, nextFrameSteppedWith result: VLCMediaPlayerFrameStepResult) { receive(result.rawValue) }
    func mediaPlayer(_ player: VLCMediaPlayer, previousFrameSteppedWith result: VLCMediaPlayerFrameStepResult) { receive(result.rawValue) }
}

@MainActor
@Observable
final class VLCPlaybackSession {
    // VLC's Apple decoder module is tried first; `any` preserves a software
    // fallback for codecs or devices without a usable hardware decoder.
    @ObservationIgnored let player = VLCMediaPlayer(options: ["--codec=videotoolbox,any"])
    @ObservationIgnored private var frameDelegate: VLCFrameDelegate?
    private(set) var position = 0.0
    private(set) var seconds = 0.0
    private(set) var duration = 0.0
    private(set) var playing = false
    private(set) var seekable = false
    private(set) var ready = false
    private(set) var stepping = false
    private(set) var errorMessage: String?
    private(set) var stepMessage: String?
    private var resumeKey = ""
    private var pendingResume: Double?
    private var started = false
    private var generation = UUID()
    private var frameResult: Int?

    func start(_ item: LibraryItem, resume: Bool = true) {
        guard !started else { return }
        do {
            try configurePlaybackAudio()
            guard let media = VLCMedia(url: item.url) else { errorMessage = "無法開啟這個檔案。"; return }
            resumeKey = "resumeSeconds:\(item.relativePath)"
            pendingResume = resume ? UserDefaults.standard.double(forKey: resumeKey) : 0
            generation = UUID()
            let token = generation
            frameDelegate = VLCFrameDelegate { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.started else { return }
                    self.frameResult = result
                }
            }
            player.delegate = frameDelegate
            player.media = media
            started = true
            player.play()
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() {
        position = min(max(Double(player.position), 0), 1)
        seconds = max(Double(player.time.intValue) / 1000, 0)
        duration = max(Double(player.media?.length.intValue ?? 0) / 1000, 0)
        playing = player.isPlaying
        seekable = player.isSeekable
        ready = started && (player.state == .playing || player.state == .paused)
        if seekable, duration > 0, let saved = pendingResume {
            pendingResume = nil
            if saved > 2, saved < duration - 3 { player.position = .init(saved / duration) }
        }
        if player.state == .error { errorMessage = "VLC 無法解碼這個媒體，請確認檔案完整性或改用系統播放器。" }
    }

    func seek(_ value: Double) { guard !stepping else { return }; player.position = .init(min(max(value, 0), 1)) }
    func toggle(rate: Float = 1) {
        guard !stepping else { return }
        if player.isPlaying { player.pause() } else { player.play(); player.rate = rate }
        refresh()
    }

    func stepFrame(_ direction: Int) async -> Bool {
        guard started, ready, !stepping, direction > 0 || seekable else { return false }
        stepping = true
        defer { stepping = false }
        let token = generation
        if player.isPlaying { player.pause() }
        // Wait for a paused decoder before requesting a frame. A request sent
        // while playing can otherwise be consumed only to pause the stream.
        for _ in 0..<200 {
            guard !Task.isCancelled, started, generation == token else { return false }
            if player.state == .paused { break }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        guard player.state == .paused else { stepMessage = "無法暫停此來源進行逐幀。"; return false }
        frameResult = nil
        if direction > 0 { player.gotoNextFrame() } else { player.gotoPreviousFrame() }
        for _ in 0..<300 {
            guard !Task.isCancelled, started, generation == token else { return false }
            if let result = frameResult, result != 1 {
                refresh()
                if result == 0 { stepMessage = direction > 0 ? "下一幀" : "上一幀"; return true }
                stepMessage = result == 5 ? "此來源目前不支援向後逐幀。" : "引擎未能完成這次逐幀（\(result)）。"
                return false
            }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        stepMessage = "逐幀尚未完成，請稍後再試。"
        return false
    }

    func stop() {
        guard started else { return }
        if pendingResume == nil, seconds.isFinite { UserDefaults.standard.set(seconds, forKey: resumeKey) }
        started = false
        generation = UUID()
        player.delegate = nil
        frameDelegate = nil
        player.stop()
        ready = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
