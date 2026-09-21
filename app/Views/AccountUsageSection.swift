import SwiftUI
import AppKit

/// One account's usage bars. Rendered once with a nil badge, or twice with
/// badges when a second account is configured.
struct AccountUsageSection: View {
    @ObservedObject var manager: UsageManager
    let badge: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let badge = badge {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.accentColor))
                    Text(manager.displayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    // A typed name says nothing about which claude.ai login it
                    // is, so the address sits beside it — but not when it IS
                    // the name, which is the unnamed-account case.
                    if !manager.email.isEmpty, manager.email != manager.displayName {
                        Text(manager.email)
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            // Inside the account block, not at the top of the popover: an error
            // with no owner does not say which account failed.
            if let error = manager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Session Usage
            if manager.hasFetchedData {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Session (5 hour)")
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = manager.sessionResetsAt {
                            Text("Resets \(formatResetTime(resetTime))")
                                .font(.caption)
                                .foregroundColor(Color.secondaryText)
                        }
                    }

                    UsageBar(value: manager.sessionPercentage,
                             color: colorForPercentage(manager.sessionPercentage))

                    Text("\(Int(manager.sessionPercentage * 100))% used")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                }

                // Weekly Usage
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Weekly (7 day)")
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = manager.weeklyResetsAt {
                            Text("Resets \(formatResetTime(resetTime, includeDate: true))")
                                .font(.caption)
                                .foregroundColor(Color.secondaryText)
                        }
                    }

                    UsageBar(value: manager.weeklyPercentage,
                             color: colorForPercentage(manager.weeklyPercentage))

                    Text("\(Int(manager.weeklyPercentage * 100))% used")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                }

                // Weekly Sonnet Usage (only show if available)
                if manager.hasWeeklySonnet && manager.hasFetchedData {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Weekly Sonnet (7 day)")
                                .font(.subheadline)
                            Spacer()
                            if let resetTime = manager.weeklySonnetResetsAt {
                                Text("Resets \(formatResetTime(resetTime, includeDate: true))")
                                    .font(.caption)
                                    .foregroundColor(Color.secondaryText)
                            }
                        }

                        UsageBar(value: manager.weeklySonnetPercentage,
                                 color: colorForPercentage(manager.weeklySonnetPercentage))

                        Text("\(Int(manager.weeklySonnetPercentage * 100))% used")
                            .font(.caption)
                            .foregroundColor(Color.secondaryText)
                    }
                }

                // Weekly Fable Usage — only surfaced once usage is above 1%
                // (new model, counted separately; hidden while idle to avoid clutter).
                if manager.hasWeeklyFable && manager.hasFetchedData && manager.weeklyFableUsage >= 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Weekly Fable (7 day)")
                                .font(.subheadline)
                            Spacer()
                            if let resetTime = manager.weeklyFableResetsAt {
                                Text("Resets \(formatResetTime(resetTime, includeDate: true))")
                                    .font(.caption)
                                    .foregroundColor(Color.secondaryText)
                            }
                        }

                        UsageBar(value: manager.weeklyFablePercentage,
                                 color: colorForPercentage(manager.weeklyFablePercentage))

                        Text("\(Int(manager.weeklyFablePercentage * 100))% used")
                            .font(.caption)
                            .foregroundColor(Color.secondaryText)
                    }
                }

                // Usage credits (pay-as-you-go). Only shown once credits are actually
                // used; links out to manage credits on claude.ai.
                if manager.hasCreditUsage || manager.freeCreditsMinor > 0 {
                    let spentMinor = manager.extraSpentMinor
                    let limitMinor = manager.extraLimitMinor
                    let pct = limitMinor > 0 ? Double(spentMinor) / Double(limitMinor) : 0
                    let pctInt = Int((pct * 100).rounded())
                    // Show the exact % up to the limit; once over, just say "over limit".
                    let pctLabel = pctInt > 100 ? "over limit" : "\(pctInt)%"
                    let fmt: (Int) -> String = { minor in
                        let v = Double(minor) / 100.0
                        return manager.creditCurrency == "USD"
                            ? String(format: "$%.2f", v)
                            : String(format: "%@ %.2f", manager.creditCurrency, v)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Extra usage")
                                .font(.subheadline)
                            Spacer()
                            Button(action: {
                                if let url = URL(string: "https://claude.ai/new#settings/usage") {
                                    NSWorkspace.shared.open(url)
                                }
                            }) {
                                Text("Manage →")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.borderless)
                        }

                        // Reset date, shortened (e.g. "Resets Aug 1") so it fits inline.
                        let shortReset: String? = manager.extraResetsAt.map { d in
                            let f = DateFormatter(); f.dateFormat = "MMM d"
                            return "Resets \(f.string(from: d))"
                        }

                        // Spend vs monthly limit — only when there's actual spend.
                        if manager.hasCreditUsage {
                            if limitMinor > 0 {
                                UsageBar(value: min(pct, 1.0),
                                         color: colorForPercentage(pct))
                            }
                            HStack {
                                Text(limitMinor > 0
                                     ? "\(fmt(spentMinor)) of \(fmt(limitMinor)) · \(pctLabel)"
                                     : "\(fmt(spentMinor)) spent")
                                    .font(.caption)
                                    .foregroundColor(Color.secondaryText)
                                Spacer()
                                if let r = shortReset {
                                    Text(r)
                                        .font(.caption)
                                        .foregroundColor(Color.secondaryText)
                                }
                            }
                        }

                        if manager.freeCreditsMinor > 0 {
                            Text("\(fmt(manager.freeCreditsMinor)) free credits left")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                                .opacity(0.85)
                        }
                    }
                }

                // With one account the line reassures; repeated under every
                // account it is just noise, so it hangs off the single-account
                // layout (badge == nil) rather than off the data.
                if badge == nil {
                    let fableActive = manager.hasWeeklyFable && manager.weeklyFableUsage >= 1
                    let extraActive = manager.hasCreditUsage || manager.freeCreditsMinor > 0
                    if !fableActive || !extraActive {
                        Text(
                            !fableActive && !extraActive ? "No Fable or extra usage"
                            : !extraActive ? "No extra usage"
                            : "No Fable usage"
                        )
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                        .opacity(0.6)
                    }
                }
            }
        }
    }

    func formatResetTime(_ date: Date, includeDate: Bool = false) -> String {
        let formatter = DateFormatter()

        if includeDate {
            // Format: "on 31 Jan 2026 at 7:59 AM"
            formatter.dateFormat = "d MMM yyyy 'at' h:mm a"
            return "on \(formatter.string(from: date))"
        } else {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "at \(formatter.string(from: date))"
        }
    }

    func colorForPercentage(_ percentage: Double) -> Color {
        if percentage < 0.7 {
            return .green
        } else if percentage < 0.9 {
            return .orange
        } else {
            return .red
        }
    }
}
