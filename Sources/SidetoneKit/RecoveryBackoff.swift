import Foundation

struct RecoveryBackoff {
    private var failures = 0
    private var nextAttempt = Date.distantPast

    mutating func recordFailure(now: Date) {
        let delay = min(30, pow(2.0, Double(min(failures, 5))))
        nextAttempt = now.addingTimeInterval(delay)
        failures += 1
    }

    mutating func reset() {
        failures = 0
        nextAttempt = .distantPast
    }

    func canAttempt(now: Date) -> Bool { now >= nextAttempt }
}
