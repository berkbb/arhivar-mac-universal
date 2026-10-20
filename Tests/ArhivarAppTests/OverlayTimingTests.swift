import Foundation
import Testing
@testable import Arhivar
@testable import ArhivarCore

/// İlerleme penceresi hızlı işlemlerde göz kırpar gibi açılıp kapanmaz: en az gösterim süresini doldurur.
@MainActor @Suite struct OverlayTimingTests {
    let start = ContinuousClock.now

    @Test func quickOperationLingersForTheRestOfTheMinimum() {
        let remaining = OverlayTiming.remaining(shownAt: start, now: start + .milliseconds(100))
        #expect(remaining == OverlayTiming.minimumDuration - .milliseconds(100))
    }

    @Test func slowOperationClosesImmediately() {
        #expect(OverlayTiming.remaining(shownAt: start, now: start + OverlayTiming.minimumDuration) == nil)
        #expect(OverlayTiming.remaining(shownAt: start, now: start + .seconds(3)) == nil)
    }

    @Test func customMinimumIsRespected() {
        #expect(OverlayTiming.remaining(shownAt: start, now: start + .milliseconds(50), minimum: .milliseconds(200)) == .milliseconds(150))
    }

    @Test func finishedStateCompletesDeterminateProgressOnly() {
        let determinate = OperationState(titleKey: .progressExtracting, progress: 0.4)
        let finished = OverlayTiming.finished(determinate)
        #expect(finished.progress == 1)
        #expect(finished.id == determinate.id)
        #expect(finished.titleKey == .progressExtracting)

        let indeterminate = OperationState(titleKey: .progressReading, progress: nil)
        #expect(OverlayTiming.finished(indeterminate).progress == nil)
    }
}
