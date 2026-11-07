import Foundation
import Testing
@testable import MediaPocketCore

@Test("A–B requires ordered finite endpoints and waits for explicit enable")
func rangeEndpoints() {
    var range = PlaybackRange()
    let missingA = range.mark(.b, seconds: 3, duration: 10)
    let invalidA = range.mark(.a, seconds: .nan, duration: 10)
    let markedA = range.mark(.a, seconds: 2, duration: 10)
    let invalidB = range.mark(.b, seconds: 2, duration: 10)
    let markedB = range.mark(.b, seconds: 5, duration: 10)
    #expect(!missingA && !invalidA && markedA && !invalidB && markedB)
    #expect(range.isValid && !range.enabled)
    let enabled = range.toggle()
    #expect(enabled)
    #expect(!range.shouldRestart(at: 4.99))
    #expect(range.shouldRestart(at: 5))
    #expect(!range.shouldRestart(at: .infinity))
}

@Test("Seeking outside disables A–B while preserving editable endpoints")
func rangeSeekOutside() {
    var range = PlaybackRange()
    range.mark(.a, seconds: 2, duration: 10)
    range.mark(.b, seconds: 5, duration: 10)
    range.toggle()
    range.disableIfOutside(5)
    #expect(range.enabled)
    range.disableIfOutside(5.001)
    #expect(!range.enabled && range.start == 2 && range.end == 5)
}

@Test("Moving A beyond B clears B instead of constructing a reversed loop")
func rangeEditStart() {
    var range = PlaybackRange()
    range.mark(.a, seconds: 2, duration: 10)
    range.mark(.b, seconds: 5, duration: 10)
    range.toggle()
    range.mark(.a, seconds: 6, duration: 10)
    #expect(range.end == nil && !range.enabled && !range.isValid)
    let enabled = range.toggle()
    #expect(!enabled)
    range.mark(.b, seconds: 100, duration: 10)
    #expect(range.end == 10)
}
