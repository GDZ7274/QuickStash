import Foundation

@MainActor
final class TerminationDeadlineCoordinator {
    typealias DrainOperation = @MainActor @Sendable () async -> Void
    typealias ReplyOperation = @MainActor @Sendable (_ timedOut: Bool) -> Void
    typealias SleepOperation = @Sendable (_ nanoseconds: UInt64) async throws -> Void

    nonisolated static let defaultDeadlineNanoseconds: UInt64 = 8_000_000_000

    private let deadlineNanoseconds: UInt64
    private let sleepOperation: SleepOperation
    private var drainOperation: DrainOperation?
    private var replyOperation: ReplyOperation?
    private var drainTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    private(set) var didReply = false
    private(set) var didTimeOut = false

    init(
        deadlineNanoseconds: UInt64 = defaultDeadlineNanoseconds,
        sleepOperation: @escaping SleepOperation = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.deadlineNanoseconds = deadlineNanoseconds
        self.sleepOperation = sleepOperation
    }

    @discardableResult
    func start(
        drain: @escaping DrainOperation,
        reply: @escaping ReplyOperation
    ) -> Bool {
        guard drainTask == nil, deadlineTask == nil, !didReply else { return false }
        drainOperation = drain
        replyOperation = reply

        drainTask = Task { @MainActor [weak self] in
            await self?.runDrain()
        }
        deadlineTask = Task { @MainActor [weak self] in
            await self?.runDeadline()
        }
        return true
    }

    private func runDrain() async {
        guard let drainOperation else { return }
        await drainOperation()
        finish(timedOut: false)
    }

    private func runDeadline() async {
        do {
            try await sleepOperation(deadlineNanoseconds)
        } catch {
            guard !Task.isCancelled else { return }
        }
        guard !Task.isCancelled else { return }
        finish(timedOut: true)
    }

    private func finish(timedOut: Bool) {
        guard !didReply, let replyOperation else { return }
        didReply = true
        didTimeOut = timedOut

        let drainTask = drainTask
        let deadlineTask = deadlineTask
        self.drainTask = nil
        self.deadlineTask = nil
        self.drainOperation = nil
        self.replyOperation = nil

        drainTask?.cancel()
        deadlineTask?.cancel()
        replyOperation(timedOut)
    }
}
