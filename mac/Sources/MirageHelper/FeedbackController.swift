import Foundation
import MirageCore

/// Adjusts the encoder bitrate from client feedback with hysteresis.
public final class FeedbackController {
    public static let defaultMinBitrate = 5_000_000
    public static let defaultMaxBitrate = 30_000_000

    private let minBitrate: Int
    private let maxBitrate: Int
    private var currentBitrate: Int
    private var lastAdjustMicros: UInt64 = 0
    private var healthySinceMicros: UInt64?

    public init(
        initialBitrate: Int,
        min: Int = FeedbackController.defaultMinBitrate,
        max: Int = FeedbackController.defaultMaxBitrate
    ) {
        self.minBitrate = min
        self.maxBitrate = max
        self.currentBitrate = Swift.min(max, Swift.max(min, initialBitrate))
    }

    public var bitrate: Int { currentBitrate }

    /// Returns a new bitrate when the feedback justifies a change, otherwise nil.
    public func update(_ feedback: Feedback, nowMicros: UInt64) -> Int? {
        let degraded = feedback.arrivalDelayMS > 100
            || feedback.queueDepth > 2
            || feedback.lossPermille > 20

        if degraded {
            healthySinceMicros = nil
            guard elapsed(nowMicros, since: lastAdjustMicros) >= 500_000 else { return nil }
            return apply(Int(Double(currentBitrate) * 0.75), nowMicros: nowMicros)
        }

        if healthySinceMicros == nil {
            healthySinceMicros = nowMicros
            return nil
        }
        guard elapsed(nowMicros, since: healthySinceMicros ?? nowMicros) >= 2_000_000 else {
            return nil
        }
        guard elapsed(nowMicros, since: lastAdjustMicros) >= 500_000 else { return nil }
        return apply(Int(Double(currentBitrate) * 1.10), nowMicros: nowMicros)
    }

    /// Called on a timer; a feedback timeout keeps the current bitrate.
    public func tick(nowMicros: UInt64) -> Int? {
        if elapsed(nowMicros, since: lastAdjustMicros) > 1_000_000 {
            healthySinceMicros = nil
        }
        return nil
    }

    private func apply(_ target: Int, nowMicros: UInt64) -> Int? {
        let clamped = min(maxBitrate, max(minBitrate, target))
        let change = abs(clamped - currentBitrate)
        let atBound = clamped == minBitrate || clamped == maxBitrate
        guard (atBound && change > 0) || change >= max(1, currentBitrate / 10) else { return nil }
        currentBitrate = clamped
        lastAdjustMicros = nowMicros
        healthySinceMicros = nil
        return clamped
    }

    private func elapsed(_ nowMicros: UInt64, since then: UInt64) -> UInt64 {
        nowMicros >= then ? nowMicros - then : 0
    }
}