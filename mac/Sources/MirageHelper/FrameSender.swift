import Foundation

public final class FrameSender: @unchecked Sendable {
    private let maxQueued: Int
    private let lock = NSLock()
    private var count = 0
    private var waiting = false

    public init(maxQueued: Int = 3) {
        self.maxQueued = maxQueued
    }

    public var queuedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    public var isWaitingForKeyframe: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting
    }

    public func enqueue(_ frame: EncodedFrame) -> Bool {
        let isKeyframe = frame.header.flags & 1 == 1
        lock.lock()
        defer { lock.unlock() }

        if waiting {
            guard isKeyframe else { return false }
            waiting = false
            count += 1
            return true
        }

        if count >= maxQueued {
            guard isKeyframe else {
                waiting = true
                return false
            }
            count += 1
            return true
        }

        count += 1
        return true
    }

    public func completeOne() {
        lock.lock()
        if count > 0 {
            count -= 1
        }
        lock.unlock()
    }
}