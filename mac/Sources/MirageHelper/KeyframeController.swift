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