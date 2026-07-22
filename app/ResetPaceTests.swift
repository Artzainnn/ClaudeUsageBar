import Foundation

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message) — expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
struct ResetPaceTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval((3 * 60 * 60) + (12 * 60))

        expectEqual(
            UsagePace.remainingText(until: reset, now: now),
            "3h 12m remaining",
            "session countdown includes hours and minutes"
        )

        expectEqual(
            UsagePace.compactRemainingText(until: reset, now: now),
            "3h12m",
            "menu bar countdown stays compact"
        )

        let weeklyReset = now.addingTimeInterval((2 * 24 * 60 * 60) + (4 * 60 * 60))
        expectEqual(
            UsagePace.remainingText(until: weeklyReset, now: now),
            "2d 4h remaining",
            "weekly countdown uses compact days and hours"
        )

        expectEqual(
            UsagePace.remainingText(until: now.addingTimeInterval(-1), now: now),
            "Resetting now",
            "elapsed reset dates never show a negative countdown"
        )

        let fiveHours = TimeInterval(5 * 60 * 60)
        expectEqual(
            UsagePace.elapsedFraction(
                until: now.addingTimeInterval(fiveHours / 2),
                window: fiveHours,
                now: now
            ),
            0.5,
            "half of a reset window is represented proportionally"
        )

        expectEqual(
            UsagePace.elapsedFraction(
                until: now.addingTimeInterval(fiveHours * 2),
                window: fiveHours,
                now: now
            ),
            0,
            "elapsed proportion is clamped before the window begins"
        )
        expectEqual(
            UsagePace.elapsedFraction(
                until: now.addingTimeInterval(-60),
                window: fiveHours,
                now: now
            ),
            1,
            "elapsed proportion is clamped after the window ends"
        )

        expectEqual(
            UsagePace.status(usageFraction: 0.70, elapsedFraction: 0.50),
            .overPace,
            "usage materially ahead of elapsed time is over pace"
        )
        expectEqual(
            UsagePace.status(usageFraction: 0.30, elapsedFraction: 0.50),
            .underPace,
            "usage materially behind elapsed time is under pace"
        )
        expectEqual(
            UsagePace.status(usageFraction: 0.52, elapsedFraction: 0.50),
            .onPace,
            "small usage and time differences remain on pace"
        )
    }
}
