import Foundation

enum PlaybackRangePoint: Sendable { case a, b }

struct PlaybackRange: Equatable, Sendable {
    private(set) var start: Double?
    private(set) var end: Double?
    private(set) var enabled = false

    var isValid: Bool {
        guard let start, let end else { return false }
        return start.isFinite && end.isFinite && start >= 0 && end > start
    }

    @discardableResult
    mutating func mark(_ point: PlaybackRangePoint, seconds: Double, duration: Double) -> Bool {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return false }
        let value = min(max(seconds, 0), duration)
        switch point {
        case .a:
            start = value
            if let end, end <= value { self.end = nil }
        case .b:
            guard let start, value > start else { return false }
            end = value
        }
        enabled = false
        return true
    }

    @discardableResult
    mutating func toggle() -> Bool {
        guard isValid else { return false }
        enabled.toggle()
        return true
    }

    mutating func disable() { enabled = false }

    mutating func disableIfOutside(_ seconds: Double) {
        guard let start, let end else { return }
        if !seconds.isFinite || seconds < start || seconds > end { enabled = false }
    }

    func shouldRestart(at seconds: Double) -> Bool {
        guard enabled, isValid, seconds.isFinite, let start, let end else { return false }
        return seconds >= end || seconds < start
    }
}
