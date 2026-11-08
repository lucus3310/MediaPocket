import Foundation
import ffmpegkit
import WebKit

private enum NativeEngineError: LocalizedError {
    case failure(String)
    var errorDescription: String? {
        switch self { case .failure(let message): message }
    }
}

// CPython and the FFmpeg CLI both retain process-global state. One dedicated
// queue owns all Python calls; UIKit/WebKit remain free on the main thread.
enum NativeDownloadEngine {
    private static let queue = DispatchQueue(label: "MediaPocket.embedded-download", qos: .userInitiated)

    static func run(_ action: String, directory: URL, job: UUID? = nil) async throws {
        let root = directory.path(percentEncoded: false)
        let identifier = job?.uuidString ?? ""
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    guard let resources = Bundle.main.resourcePath,
                          let executable = Bundle.main.executablePath else {
                        throw NativeEngineError.failure("找不到內建下載引擎。")
                    }
                    let initialized = mp_python_initialize(resources + "/python", resources,
                                                           resources + "/python-packages", executable,
                                                           nativeMediaCommand)
                    guard initialized == 0 else {
                        throw NativeEngineError.failure(String(cString: mp_python_error()))
                    }
                    guard mp_python_run(action, root, identifier) == 0 else {
                        throw NativeEngineError.failure(String(cString: mp_python_error()))
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // Cancellation is the library's thread-safe interrupt API, not another CLI
    // execution. Python also checks the job's persistent cancellation flag.
    static func cancel() { FFmpegKit.cancel() }
}

private func nativeMediaCommand(_ json: UnsafePointer<CChar>?, _ output: UnsafePointer<CChar>?,
                                _ error: UnsafePointer<CChar>?) -> Int32 {
    guard let json, let output, let error else { return -22 }
    let out = URL(fileURLWithPath: String(cString: output))
    let err = URL(fileURLWithPath: String(cString: error))
    do {
        let arguments = try JSONDecoder().decode([String].self, from: Data(String(cString: json).utf8))
        let command = arguments.first
        let session: any Session
        if command == "ffmpeg" {
            session = FFmpegKit.executeWithArguments(Array(arguments.dropFirst()))
        } else if command == "ffprobe" {
            // ffprobe's JSON writer writes stdout directly, outside av_log.
            // Its -o option gives each job a separate output without redirecting
            // the app process's stdout or affecting the player.
            session = FFprobeKit.executeWithArguments(Array(arguments.dropFirst()) + ["-o", out.path(percentEncoded: false)])
        } else { return -22 }
        let logs = session.getOutput()
        if command == "ffmpeg" { try logs.write(to: out, atomically: true, encoding: .utf8) }
        try logs.write(to: err, atomically: true, encoding: .utf8)
        return session.getReturnCode()?.getValue() ?? -127
    } catch {
        try? error.localizedDescription.write(to: err, atomically: true, encoding: .utf8)
        return -1
    }
}
