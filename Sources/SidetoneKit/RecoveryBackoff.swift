import Foundation

struct RecoveryBackoff {
    private var delay: TimeInterval = 1
    private var nextAttempt = Date.distantPast

    mutating func recordFailure(now: Date) {
        nextAttempt = now.addingTimeInterval(delay)
        delay = min(30, delay * 2)
    }

    mutating func reset() {
        delay = 1
        nextAttempt = .distantPast
    }

    func canAttempt(now: Date) -> Bool { now >= nextAttempt }
}
