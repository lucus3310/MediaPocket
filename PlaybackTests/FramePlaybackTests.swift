import AVFoundation
import CoreVideo
import SwiftUI
import Testing
import UIKit
@testable import MediaPocket

private enum PlaybackTestError: Error { case timeout, writer, pixelBuffer }

@MainActor
private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw PlaybackTestError.timeout
}

@MainActor
private func makeClip(variable: Bool) async throws -> (URL, [Double]) {
    let url = FileManager.default.temporaryDirectory.appending(path: "frame-test-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 12, AVVideoAllowFrameReorderingKey: true]
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? PlaybackTestError.writer }
    writer.startSession(atSourceTime: .zero)
    var ticks: Int64 = 0
    var times: [Double] = []
    for index in 0..<50 {
        try await waitFor { input.isReadyForMoreMediaData }
        var pixel: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
              let pixel else { throw PlaybackTestError.pixelBuffer }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let address = CVPixelBufferGetBaseAddress(pixel) {
            address.initializeMemory(as: UInt8.self, repeating: UInt8((index * 23) % 255), count: CVPixelBufferGetBytesPerRow(pixel) * 180)
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let time = CMTime(value: ticks, timescale: 600)
        times.append(time.seconds)
        guard adaptor.append(pixel, withPresentationTime: time) else { throw writer.error ?? PlaybackTestError.writer }
        ticks += variable ? [20, 40, 10, 30][index % 4] : 20
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? PlaybackTestError.writer }
    return (url, times)
}

// Both engines share the process audio session and a real on-screen video
// output. Serialize these integration tests, while filesystem tests stay parallel.
@Suite(.serialized)
@MainActor
struct FramePlaybackTests {
    @Test("Native frame steps follow actual CFR and VFR timestamps", arguments: [false, true])
    func nativeSamples(variable: Bool) async throws {
        let (url, times) = try await makeClip(variable: variable)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = SystemPlaybackSession()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let canvas = SystemVideoCanvas(player: session.player)
        controller.view.addSubview(canvas)
        canvas.frame = controller.view.bounds
        defer { session.stop(); window.isHidden = true }
        let item = LibraryItem(url: url, relativePath: url.lastPathComponent, isDirectory: false, size: 0, modified: .now)
        await session.prepare(item, autoplay: false, resume: false)
        try await waitFor { session.refresh(); return session.ready }
        #expect(session.canStepForward)
        await session.seek(times[10] / session.duration)
        #expect(abs(session.seconds - times[10]) < 0.003)
        for index in 11...15 {
            let stepped = await session.stepFrame(1)
            #expect(stepped)
            #expect(abs(session.seconds - times[index]) < 0.003)
            #expect(!session.playing)
        }
        for index in stride(from: 14, through: 11, by: -1) {
            let stepped = await session.stepFrame(-1)
            #expect(stepped)
            #expect(abs(session.seconds - times[index]) < 0.003)
        }
    }

    @Test("VLC confirms both forward and backward single-frame requests")
    func vlcFrames() async throws {
        let (url, _) = try await makeClip(variable: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = VLCPlaybackSession()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let canvas = UIView(frame: window.bounds)
        controller.view.addSubview(canvas)
        session.player.drawable = canvas
        defer { session.stop(); session.player.drawable = nil; window.isHidden = true }
        session.start(LibraryItem(url: url, relativePath: url.lastPathComponent, isDirectory: false, size: 0, modified: .now), resume: false)
        try await waitFor { session.refresh(); return session.ready && session.seekable && session.player.hasVideoOut }
        session.seek(0.25)
        for _ in 0..<3 {
            let stepped = await session.stepFrame(1)
            #expect(stepped, "VLC next-frame result: \(session.stepMessage ?? "none")")
        }
        let backward = await session.stepFrame(-1)
        #expect(backward, "VLC previous-frame result: \(session.stepMessage ?? "none")")
        #expect(!session.playing)
    }

    @Test("8x renderer zoom preserves the player and supports panning and rotation reset")
    func rendererZoom() {
        let player = AVPlayer()
        let canvas = SystemVideoCanvas(player: player)
        let viewport = VideoViewport(canvas: canvas)
        let delegate = ZoomDelegate(canvas: canvas)
        viewport.delegate = delegate
        viewport.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        viewport.layoutIfNeeded()
        viewport.setZoomScale(8, animated: false)
        viewport.layoutIfNeeded()
        #expect(abs(canvas.transform.a - 8) < 0.01)
        #expect(canvas.playerLayer.player === player)
        viewport.setContentOffset(CGPoint(x: 300, y: 200), animated: false)
        #expect(viewport.contentOffset.x > 0 && viewport.contentOffset.y > 0)
        viewport.frame = CGRect(x: 0, y: 0, width: 600, height: 240)
        viewport.layoutIfNeeded()
        #expect(viewport.zoomScale == 1)
        #expect(canvas.playerLayer.player === player)
    }
}

@MainActor
private final class ZoomDelegate: NSObject, UIScrollViewDelegate {
    let canvas: UIView
    init(canvas: UIView) { self.canvas = canvas }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
}
