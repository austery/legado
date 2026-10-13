import Foundation

struct ReadingPositionSample: Equatable {
    let token: String
    let sequence: Int64
    let offset: Int
}

enum ReadingSaveOutcome {
    case saved
    case failed(String)
}

/// Coalesces positions without tying accepted writes to cancellable navigation requests.
@MainActor
final class ReadingSaveCoordinator {
    typealias Writer = (ReadingPositionSample, Bool, @escaping (ReadingSaveOutcome) -> Void) -> Void
    private let write: Writer
    var onFailure: ((String) -> Void)?
    private var latest: ReadingPositionSample?
    private var acknowledgedSequence: Int64 = 0
    private var inFlight = false
    private var flushPending = false
    private var finishAction: (() -> Void)?
    private var debounce: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    init(write: @escaping Writer) { self.write = write }

    func displayed(token: String, offset: Int) {
        if latest?.token == token { return }
        guard latest == nil || latest?.token == token else {
            onFailure?("Previous reading position is still pending.")
            return
        }
        sample(token: token, offset: offset)
        flush()
    }

    func sample(token: String, offset: Int) {
        guard offset >= 0, latest == nil || latest?.token == token, finishAction == nil else { return }
        let sequence = (latest?.sequence ?? 0) + 1
        latest = ReadingPositionSample(token: token, sequence: sequence, offset: offset)
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            self?.flush()
        }
        if deadline == nil {
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                self?.flush()
            }
        }
    }

    /// Background flushes retain the token; transitions finish it after an acknowledged write.
    var hasPosition: Bool { latest != nil }

    func flush() { drain() }

    func finish(then action: @escaping () -> Void) {
        guard latest != nil else { action(); return }
        if finishAction == nil, let sample = latest {
            latest = ReadingPositionSample(token: sample.token, sequence: sample.sequence + 1, offset: sample.offset)
        }
        finishAction = action
        drain()
    }

    private func drain() {
        if inFlight { flushPending = true; return }
        guard let sample = latest else { return }
        let finishing = finishAction != nil
        guard finishing || sample.sequence > acknowledgedSequence else { return }
        debounce?.cancel(); debounce = nil
        deadline?.cancel(); deadline = nil
        inFlight = true
        flushPending = false
        write(sample, finishing) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            switch result {
            case .failed(let message):
                self.deadline?.cancel(); self.deadline = nil
                self.flushPending = false
                if let latest = self.latest {
                    self.latest = ReadingPositionSample(token: latest.token, sequence: latest.sequence + 1, offset: latest.offset)
                }
                self.finishAction = nil
                self.onFailure?(message)
            case .saved:
                self.acknowledgedSequence = sample.sequence
                if finishing {
                    let action = self.finishAction
                    self.finishAction = nil
                    self.latest = nil
                    self.acknowledgedSequence = 0
                    self.debounce?.cancel(); self.debounce = nil
                    self.deadline?.cancel(); self.deadline = nil
                    action?()
                } else if self.finishAction != nil {
                    self.drain()
                } else if self.flushPending {
                    // A timer fired while this write was pending; persist its latest sample.
                    self.drain()
                }
            }
        }
    }
}
