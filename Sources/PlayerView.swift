import AVKit
import SwiftUI

struct PlayerView: View {
    let item: LibraryItem
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage {
                    ContentUnavailableView(
                        "目前無法播放",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    VideoPlayer(player: player)
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                do {
                    let asset = AVURLAsset(url: item.url)
                    guard try await asset.load(.isPlayable) else {
                        errorMessage = "系統播放器不支援這個媒體。檔案仍保留在檔案庫。"
                        return
                    }
                    guard !Task.isCancelled else { return }
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .moviePlayback)
                    try session.setActive(true)
                    player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                    player.play()
                } catch {
                    if !Task.isCancelled { errorMessage = error.localizedDescription }
                }
            }
            .onDisappear {
                player.pause()
                player.replaceCurrentItem(with: nil)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}
