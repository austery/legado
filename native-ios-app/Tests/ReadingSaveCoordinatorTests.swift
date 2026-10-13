import XCTest
@testable import NativeReader

@MainActor
final class ReadingSaveCoordinatorTests: XCTestCase {
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

}
