import Foundation

actor ParseTaskLimiter {
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func withPermit<T>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        if inFlight < limit {
            inFlight += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        inFlight += 1
    }

    private func release() {
        inFlight = max(0, inFlight - 1)
        guard !waiters.isEmpty else {
            return
        }
        let waiter = waiters.removeFirst()
        waiter.resume()
    }
}
