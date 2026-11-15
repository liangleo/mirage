import Foundation

public final class KeyframeController: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = true
    private var lastKeyframeMicros: UInt64 = 0
    private let intervalMicros: UInt64 = 5_000_000

    public init() {}

    public func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    /// Requests a keyframe only when the last one is older than the interval,
    /// so a lossy link cannot turn every feedback report into an IDR.
    @discardableResult
    public func requestIfDue(nowMicros: UInt64, minIntervalMicros: UInt64 = 2_000_000) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard nowMicros >= lastKeyframeMicros &+ minIntervalMicros else { return false }
        requested = true
        return true
    }

    public func shouldForce(nowMicros: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if requested {
            requested = false
            return true
        }
        return nowMicros >= lastKeyframeMicros &+ intervalMicros
    }

    public func noteKeyframe(nowMicros: UInt64) {
        lock.lock()
        lastKeyframeMicros = nowMicros
        lock.unlock()
    }
}