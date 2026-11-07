import AVFoundation
import CoreVideo
import SwiftUI
import Testing
import UIKit
@testable import MediaPocket

private enum PlaybackTestError: Error { case timeout, writer, pixelBuffer }

@MainActor
private func playbackWindow() throws -> UIWindow {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = scene.screen.bounds
    return window
}

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
    @Test("Original-file bookmarks play on both engines and leave only a small catalog")
    func linkedOriginalPlayback() async throws {
        let files = FileManager.default
        let (created, _) = try await makeClip(variable: false)
        let folder = SourceRestorationProbe.fixtureDirectory
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appending(path: "clip.mov")
        if files.fileExists(atPath: original.path(percentEncoded: false)) { try files.removeItem(at: original) }
        try files.moveItem(at: created, to: original)
        let bytes = try Data(contentsOf: original)
        if files.fileExists(atPath: SourceRestorationProbe.resultURL.path(percentEncoded: false)) {
            try files.removeItem(at: SourceRestorationProbe.resultURL)
        }
        let store = LinkedSourceStore(directory: SourceRestorationProbe.catalogDirectory)
        let file = try await store.add(original)
        let directory = try await store.add(folder)
        let restored = LinkedSourceStore(directory: SourceRestorationProbe.catalogDirectory)
        #expect(try await restored.sources().count == 2)
        let window = try playbackWindow()
        let controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let direct = try await restored.prepareOpen(SourceLocation(sourceID: file.id, path: ""))
        #expect(direct.url.resolvingSymlinksInPath() == original.resolvingSymlinksInPath() && direct.accessRoot != nil)
        let native = SystemPlaybackSession()
        let canvas = SystemVideoCanvas(player: native.player)
        canvas.frame = window.bounds; controller.view.addSubview(canvas)
        await native.prepare(direct, autoplay: false, resume: false)
        try await waitFor { native.refresh(); return native.ready }
        let nativeStep = await native.stepFrame(1)
        #expect(nativeStep)
        native.stop(); canvas.removeFromSuperview()

        let nested = try await restored.prepareOpen(SourceLocation(sourceID: directory.id, path: "clip.mov"))
        #expect(nested.url.resolvingSymlinksInPath() == original.resolvingSymlinksInPath() && nested.accessRoot != nil)
        let vlc = VLCPlaybackSession()
        let vlcCanvas = UIView(frame: window.bounds)
        controller.view.addSubview(vlcCanvas); vlc.player.drawable = vlcCanvas
        vlc.start(nested, resume: false)
        defer { vlc.stop(); vlc.player.drawable = nil }
        try await waitFor { vlc.refresh(); return vlc.ready && vlc.player.hasVideoOut }
        let vlcStep = await vlc.stepFrame(1)
        #expect(vlcStep)
        vlc.stop()
        #expect(try Data(contentsOf: original) == bytes)
        let catalogBytes = try Data(contentsOf: SourceRestorationProbe.catalogDirectory.appending(path: "sources.json")).count
        #expect(catalogBytes < 64 * 1024)
        let manifest = SourceRestorationProbe.Manifest(fileID: file.id, folderID: directory.id,
            originalURL: original, prefix: Data(bytes.prefix(32)), originalSize: Int64(bytes.count))
        try JSONEncoder().encode(manifest).write(to: SourceRestorationProbe.manifestURL, options: .atomic)
    }

    @Test("Native frame steps follow actual CFR and VFR timestamps", arguments: [false, true])
    func nativeSamples(variable: Bool) async throws {
        let (url, times) = try await makeClip(variable: variable)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = SystemPlaybackSession()
        let window = try playbackWindow()
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
        let forwardBatch = await session.stepFrames(4)
        #expect(forwardBatch && abs(session.seconds - times[15]) < 0.003)
        let backwardBatch = await session.stepFrames(-4)
        #expect(backwardBatch && abs(session.seconds - times[11]) < 0.003)
        #expect(!session.traversing && !session.playing)
    }

    @Test("VLC confirms both forward and backward single-frame requests")
    func vlcFrames() async throws {
        let (url, _) = try await makeClip(variable: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = VLCPlaybackSession()
        let window = try playbackWindow()
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
        let batch = await session.stepFrames(3)
        #expect(batch && !session.traversing)
        #expect(!session.playing)
    }

    @Test("A–B returns to A on both engines and manual seek disables it", arguments: [false, true])
    func rangePlayback(vlc: Bool) async throws {
        let (url, _) = try await makeClip(variable: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = LibraryItem(url: url, relativePath: url.lastPathComponent, isDirectory: false, size: 0, modified: .now)
        let window = try playbackWindow()
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        if vlc {
            let session = VLCPlaybackSession()
            let canvas = UIView(frame: window.bounds)
            controller.view.addSubview(canvas)
            session.player.drawable = canvas
            defer { session.stop(); session.player.drawable = nil }
            session.start(item, resume: false)
            try await waitFor { session.refresh(); return session.ready && session.seekable }
            session.seek(0.15)
            try await waitFor { session.refresh(); return abs(session.seconds - session.duration * 0.15) < 0.1 }
            session.markRange(.a)
            session.seek(0.5)
            try await waitFor { session.refresh(); return abs(session.seconds - session.duration * 0.5) < 0.1 }
            session.markRange(.b)
            session.toggleRange()
            session.seek(0.3)
            try await waitFor { session.refresh(); return abs(session.seconds - session.duration * 0.3) < 0.1 }
            session.toggle()
            var returned = false
            for _ in 0..<80 {
                session.refresh()
                if session.range.shouldRestart(at: session.seconds) {
                    await session.serviceRange()
                    returned = session.seconds < (session.range.end ?? 0) - 0.1
                    if returned { break }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(returned && session.range.enabled)
            session.pause(); session.seek(0.9)
            #expect(!session.range.enabled)
        } else {
            let session = SystemPlaybackSession()
            let canvas = SystemVideoCanvas(player: session.player)
            canvas.frame = window.bounds
            controller.view.addSubview(canvas)
            defer { session.stop() }
            await session.prepare(item, autoplay: false, resume: false)
            try await waitFor { session.refresh(); return session.ready }
            await session.seek(0.15); session.markRange(.a)
            await session.seek(0.5); session.markRange(.b)
            session.toggleRange()
            await session.seek(0.3)
            session.toggle(rate: 1)
            var returned = false
            for _ in 0..<80 {
                session.refresh()
                if session.range.shouldRestart(at: session.seconds) {
                    await session.serviceRange()
                    returned = session.seconds < (session.range.end ?? 0) - 0.1
                    if returned { break }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(returned && session.range.enabled)
            session.pause(); await session.seek(0.9)
            #expect(!session.range.enabled)
            try await saveDockReview()
        }
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
private func saveDockReview() async throws {
    var range = PlaybackRange()
    range.mark(.a, seconds: 15, duration: 90)
    range.mark(.b, seconds: 35, duration: 90)
    range.toggle()
    let folder = URL.documentsDirectory.appending(path: "InterfaceReview")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, size) in [("portrait", CGSize(width: 390, height: 844)), ("landscape", CGSize(width: 844, height: 390))] {
        let window = try playbackWindow()
        window.frame = CGRect(origin: .zero, size: size)
        let view = ZStack {
            Color.black
            Text("MediaPocket").font(.title2).foregroundStyle(.white.opacity(0.25))
            VStack {
                Spacer()
                FrameTransport(position: 1.0 / 3, seconds: 30, duration: 90,
                    playing: false, ready: true, busy: false, forward: true, backward: true,
                    message: nil, range: range, rate: .constant(0.5), toggle: {}, pause: {}, seek: { _ in },
                    step: { _ in }, mark: { _ in }, toggleRange: {}, clearRange: {})
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }.preferredColorScheme(.dark).tint(.white)
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
        let image = renderer.image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
        let data = try #require(image.pngData())
        try data.write(to: folder.appending(path: "PlayerDock-\(name).png"))
        window.isHidden = true
    }
}

@MainActor
private final class ZoomDelegate: NSObject, UIScrollViewDelegate {
    let canvas: UIView
    init(canvas: UIView) { self.canvas = canvas }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
}
