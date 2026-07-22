import Foundation

enum UsagePaceStatus: Equatable {
    case underPace
    case onPace
    case overPace
}

enum UsagePace {
    static func remainingText(until resetDate: Date, now: Date = Date()) -> String {
        guard resetDate > now else { return "Resetting now" }
        let totalMinutes = max(0, Int(ceil(resetDate.timeIntervalSince(now) / 60)))
        if totalMinutes >= 24 * 60 {
            let days = totalMinutes / (24 * 60)
            let hours = (totalMinutes % (24 * 60)) / 60
            return "\(days)d \(hours)h remaining"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours)h \(minutes)m remaining"
    }

    static func elapsedFraction(
        until resetDate: Date,
        window: TimeInterval,
        now: Date = Date()
    ) -> Double {
        min(max(1 - (resetDate.timeIntervalSince(now) / window), 0), 1)
    }

    static func status(usageFraction: Double, elapsedFraction: Double) -> UsagePaceStatus {
        if usageFraction > elapsedFraction + 0.05 { return .overPace }
        if usageFraction < elapsedFraction - 0.05 { return .underPace }
        return .onPace
    }
}
