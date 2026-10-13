import XCTest
@testable import NativeReader

@MainActor
final class ReadingSaveCoordinatorTests: XCTestCase {
    func testDiscardRetiresPendingCallbacksAndAllowsAnotherBook() {
        var completions: [(ReadingSaveOutcome) -> Void] = []
        var failures = 0
        let coordinator = ReadingSaveCoordinator { _, _, completion in completions.append(completion) }
        coordinator.onFailure = { _ in failures += 1 }
        coordinator.displayed(token: "old", offset: 10)
        var oldNavigation = false
        coordinator.finish { oldNavigation = true }
        coordinator.discard()
        XCTAssertFalse(coordinator.hasPosition)
        coordinator.displayed(token: "new", offset: 20)
        completions[0](.failed("Stale token"))
        XCTAssertEqual(failures, 0)
        XCTAssertFalse(oldNavigation)
        completions[1](.saved)
        var newNavigation = false
        coordinator.finish { newNavigation = true }
        completions[2](.saved)
        XCTAssertTrue(newNavigation)
        XCTAssertFalse(coordinator.hasPosition)
    }

    func testNavigationWaitsForAcceptedWriteThenFinishesNewestPosition() {
        var samples: [ReadingPositionSample] = []
        var finishes: [Bool] = []
        var completions: [(ReadingSaveOutcome) -> Void] = []
        let coordinator = ReadingSaveCoordinator { sample, finishing, completion in
            samples.append(sample); finishes.append(finishing); completions.append(completion)
        }
        coordinator.displayed(token: "first", offset: 0)
        coordinator.sample(token: "first", offset: 42)
        var navigated = false
        coordinator.finish { navigated = true }
        XCTAssertEqual(samples.count, 1)
        XCTAssertFalse(navigated)
        completions[0](.saved)
        XCTAssertEqual(samples.map(\.offset), [0, 42])
        XCTAssertEqual(finishes, [false, true])
        XCTAssertGreaterThan(samples[1].sequence, samples[0].sequence)
        XCTAssertFalse(navigated)
        completions[1](.saved)
        XCTAssertTrue(navigated)
        coordinator.displayed(token: "second", offset: 12)
        XCTAssertEqual(samples.last?.token, "second")
        completions[2](.saved)
    }

    func testFailureRetainsPositionForRetryAndDoesNotNavigate() {
        var samples: [ReadingPositionSample] = []
        var completions: [(ReadingSaveOutcome) -> Void] = []
        let coordinator = ReadingSaveCoordinator { sample, _, completion in
            samples.append(sample); completions.append(completion)
        }
        var failure: String?
        coordinator.onFailure = { failure = $0 }
        coordinator.displayed(token: "book", offset: 18)
        var navigated = false
        coordinator.finish { navigated = true }
        completions[0](.failed("Disk unavailable"))
        XCTAssertFalse(navigated)
        XCTAssertEqual(failure, "Disk unavailable")
        coordinator.finish { navigated = true }
        XCTAssertEqual(samples.last?.offset, 18)
        completions[1](.saved)
        XCTAssertTrue(navigated)
    }

    func testBackgroundFlushKeepsTokenAndRejectsForeignSamples() {
        var samples: [ReadingPositionSample] = []
        let coordinator = ReadingSaveCoordinator { sample, _, completion in
            samples.append(sample); completion(.saved)
        }
        coordinator.displayed(token: "book", offset: 0)
        coordinator.sample(token: "other", offset: 999)
        coordinator.sample(token: "book", offset: 24)
        coordinator.flush()
        XCTAssertEqual(samples.map(\.offset), [0, 24])
        coordinator.sample(token: "book", offset: 48)
        coordinator.flush()
        XCTAssertEqual(samples.last?.offset, 48)
    }
    func testRecreatedViewDisplayCannotResetNewerSample() {
        var samples: [ReadingPositionSample] = []
        let coordinator = ReadingSaveCoordinator { sample, _, completion in
            samples.append(sample); completion(.saved)
        }
        coordinator.displayed(token: "book", offset: 0)
        coordinator.sample(token: "book", offset: 44)
        coordinator.displayed(token: "book", offset: 0)
        coordinator.flush()
        XCTAssertEqual(samples.map(\.offset), [0, 44])
    }

    func testContinuousScrollRearmsDeadlineAfterSlowWriteFailure() async throws {
        var samples: [ReadingPositionSample] = []
        var completions: [(ReadingSaveOutcome) -> Void] = []
        let coordinator = ReadingSaveCoordinator { sample, _, completion in
            samples.append(sample); completions.append(completion)
        }
        coordinator.displayed(token: "book", offset: 0)
        for offset in 1...55 {
            coordinator.sample(token: "book", offset: offset)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(samples.count, 1, "No concurrent writer while the initial write is pending")
        completions[0](.failed("Temporary write failure"))
        for offset in 56...110 {
            coordinator.sample(token: "book", offset: offset)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(samples.count, 2, "Continuous scroll must re-arm the five-second save deadline")
        XCTAssertGreaterThan(samples.last?.offset ?? 0, 55)
        completions[1](.saved)
    }

    @MainActor
    private final class Clock {
        struct Event {
            let at: UInt64
            let timer: ReadingSaveTimer
            let action: () -> Void
        }
        var now: UInt64 = 0
        var events: [Event] = []
        func schedule(_ delay: UInt64, _ action: @escaping () -> Void) -> ReadingSaveTimer {
            let timer = ReadingSaveTimer()
            events.append(Event(at: now + delay, timer: timer, action: action))
            return timer
        }
        func advance(_ delta: UInt64) {
            let target = now + delta
            while let event = events.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
                events.removeAll { $0.timer === event.timer }
                now = event.at
                if !event.timer.isCancelled { event.action() }
            }
            now = target
        }
    }

    func testControlledIdleDeadlineSavesLatestOnlyAfterOneSecond() {
        let clock = Clock()
        var offsets: [Int] = []
        let coordinator = ReadingSaveCoordinator(schedule: clock.schedule) { sample, _, completion in
            offsets.append(sample.offset); completion(.saved)
        }
        coordinator.displayed(token: "book", offset: 0)
        coordinator.sample(token: "book", offset: 10)
        clock.advance(900_000_000)
        coordinator.sample(token: "book", offset: 20)
        clock.advance(999_999_999)
        XCTAssertEqual(offsets, [0])
        clock.advance(1)
        XCTAssertEqual(offsets, [0, 20])
        clock.advance(10_000_000_000)
        XCTAssertEqual(offsets, [0, 20], "Cancelled deadline must not duplicate an acknowledged save")
    }

    func testControlledContinuousScrollSavesAtFiveSecondBoundary() {
        let clock = Clock()
        var times: [UInt64] = []
        var offsets: [Int] = []
        let coordinator = ReadingSaveCoordinator(schedule: clock.schedule) { sample, _, completion in
            times.append(clock.now); offsets.append(sample.offset); completion(.saved)
        }
        coordinator.displayed(token: "book", offset: 0)
        for offset in 1...9 {
            coordinator.sample(token: "book", offset: offset)
            clock.advance(500_000_000)
        }
        coordinator.sample(token: "book", offset: 10)
        clock.advance(499_999_999)
        XCTAssertEqual(offsets, [0])
        clock.advance(1)
        XCTAssertEqual(offsets, [0, 10])
        XCTAssertEqual(times, [0, 5_000_000_000])
    }

}
