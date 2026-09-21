import Foundation

let usageThresholds = [25, 50, 75, 90]

/// The highest threshold newly crossed, or nil when no new one was reached.
/// Reporting only the highest is what keeps a fresh install already at 95%
/// from firing four notifications in a row.
func highestCrossedThreshold(percentage: Int,
                             lastNotified: Int,
                             thresholds: [Int] = usageThresholds) -> Int? {
    thresholds.filter { percentage >= $0 && lastNotified < $0 }.max()
}

/// The threshold to persist after a reading. Usage falling below the last
/// notified threshold means the session reset, which rearms the lower bands.
func rearmedThreshold(percentage: Int,
                      lastNotified: Int,
                      thresholds: [Int] = usageThresholds) -> Int {
    if let crossed = highestCrossedThreshold(percentage: percentage,
                                             lastNotified: lastNotified,
                                             thresholds: thresholds) {
        return crossed
    }
    if percentage < lastNotified {
        return thresholds.filter { $0 <= percentage }.max() ?? 0
    }
    return lastNotified
}

// MARK: - Notification text
//
// Kept as pure functions, called from UsageManager.sendNotification and
// .sendTestNotification rather than built inline, so the wording can be
// asserted directly — the test harness cannot observe NSUserNotificationCenter.

/// Text of a usage-threshold alert. Empty prefix is the single-account case:
/// the exact 1.3.x wording, since there is nothing to disambiguate. A
/// non-empty prefix lower-cases the body's lead word so "Work — you've
/// reached..." reads as one sentence naming the account that crossed it.
func notificationBody(percentage: Int, prefix: String) -> String {
    let body = "You've reached \(percentage)% of your 5-hour session limit"
    guard !prefix.isEmpty else { return body }
    return "\(prefix) — \(body.prefix(1).lowercased() + body.dropFirst())"
}

/// Text of the Settings "Test Notification" button. No-prefix form is the
/// exact string ClaudeUsageBar has shipped since 1.3.x, byte for byte.
///
/// The prefixed form can't just stitch the account prefix onto that string:
/// the body's own " - " already reads fine standing alone, but putting the
/// prefix's em dash in front of it stacks two competing dashes into one line
/// ("Personal — Test notification - You've reached..."). Instead, "test
/// notification" becomes a lower-cased clause after a comma — the same
/// lead-word lowering notificationBody does after its own em dash — so the
/// whole thing reads as one sentence: "Personal — test notification, you've
/// reached...".
func testNotificationBody(prefix: String) -> String {
    let announcement = "You've reached 75% of your 5-hour session limit"
    let body = "Test notification - \(announcement)"
    guard !prefix.isEmpty else { return body }
    let loweredAnnouncement = announcement.prefix(1).lowercased() + announcement.dropFirst()
    return "\(prefix) — test notification, \(loweredAnnouncement)"
}

struct UsageSnapshot: Equatable {
    // "Bucket absent" and "bucket present with usage 0" must stay distinct
    // states all the way up to the manager: a partial/malformed payload that
    // collapsed a real reading to 0 would rearm every notification threshold
    // on the next healthy poll (see checkNotificationThresholds).
    struct Bucket: Equatable {
        var usage: Int
        var resetsAt: Date?
    }
    var session: Bucket?
    var weekly: Bucket?
    var sonnet: Bucket?
    var fable: Bucket?
}

func parseUsagePayload(_ data: Data) -> UsageSnapshot? {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return nil
    }

    var snapshot = UsageSnapshot()
    snapshot.session = bucket(from: json["five_hour"] as? [String: Any], usageKey: "utilization")
    snapshot.weekly = bucket(from: json["seven_day"] as? [String: Any], usageKey: "utilization")
    snapshot.sonnet = bucket(from: json["seven_day_sonnet"] as? [String: Any], usageKey: "utilization")

    // Fable is not a top-level key like seven_day_sonnet: it arrives as a
    // model-scoped weekly limit inside `limits`.
    if let limits = json["limits"] as? [[String: Any]],
       let fable = limits.first(where: { entry in
           let scope = entry["scope"] as? [String: Any]
           let model = scope?["model"] as? [String: Any]
           return (model?["display_name"] as? String) == "Fable"
       }) {
        snapshot.fable = bucket(from: fable, usageKey: "percent")
    }

    return snapshot
}

/// Builds a bucket only when its usage value is present and parses; a
/// present-but-unparseable value (or a missing top-level key) yields nil
/// rather than a 0-usage bucket, so the manager leaves the previous reading
/// in place instead of writing a value that reads as "usage just dropped to
/// zero" and rearms notification thresholds.
///
/// A bucket that IS present clears resetsAt to nil when its own resets_at is
/// missing/unparseable, rather than keeping a stale date — showing an
/// outdated reset time indefinitely is worse than showing none.
private func bucket(from dict: [String: Any]?, usageKey: String) -> UsageSnapshot.Bucket? {
    guard let dict = dict, let usage = intValue(dict[usageKey]) else { return nil }
    return UsageSnapshot.Bucket(usage: usage, resetsAt: isoDate(dict["resets_at"] as? String))
}

/// `utilization` and `percent` decode as Int or Double depending on the
/// payload, so neither cast alone is enough.
private func intValue(_ raw: Any?) -> Int? {
    if let int = raw as? Int { return int }
    if let double = raw as? Double { return Int(double) }
    return nil
}

/// Not every claude.ai timestamp carries fractional seconds; accepting only
/// the fractional form dropped the rest on the floor.
private func isoDate(_ raw: String?) -> Date? {
    guard let raw = raw else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
}

// MARK: - Account slots

let accountsSchemaVersion = 2

func accountKey(_ slot: Int, _ suffix: String) -> String { "account_\(slot)_\(suffix)" }

/// Moves a 1.3.x single-account install onto the per-slot keys. Runs once,
/// before any UsageManager reads its cookie.
///
/// Copies instead of moving: this runs exactly once on each user's machine and
/// has no undo, so leaving the legacy keys in place is what makes a rollback to
/// 1.3.x survivable. The cost is one orphan key. (Clearing account 1 in the UI
/// does delete that orphan — see UsageManager.clearSessionCookie, where the
/// reasoning for the exception lives.)
///
/// Known dead end, undocumented anywhere else: a user who rolls back to 1.3.x,
/// changes their cookie there and then returns to 1.4.0 still has
/// `accounts_schema_version` at 2, so this migration is skipped and their NEW
/// legacy cookie is silently ignored in favour of the stale `account_1_cookie`.
/// Nothing is lost — pasting the cookie again in Settings fixes it — but the
/// app gives no hint that the value it is using is not the one they just set.
///
/// ⚠️ WARNING FOR WHOEVER BUMPS `accountsSchemaVersion` NEXT: the guard below
/// is a range check (`storedVersion < accountsSchemaVersion`), but the copy in
/// the body is NOT separately versioned — it is the v1 -> v2 step and nothing
/// marks it as such. The day this constant becomes 3 for an unrelated v2 -> v3
/// migration, `2 < 3` is true for every user already sitting on schema 2, and
/// this block runs again for all of them: it reads the legacy
/// `claude_session_cookie` key (still there, deliberately never deleted above)
/// and writes it back into slot 1 for anyone who had cleared that account or
/// moved on to slot 2 alone. That resurrects a cookie the user deliberately
/// deleted, with no error and no log. The same replay happens if
/// `accounts_schema_version` is ever lost — a manual `defaults delete`, or a
/// pre-1.4 preferences restore — since the guard then reads it back as 0.
///
/// Assertions in tests/main.swift go red the moment this constant moves to 3.
/// They are doing their job when that happens — do not delete them as stale.
/// If that suite is ever removed, THIS COMMENT becomes the only thing left to
/// stop it. The structural fix, when a v2 -> v3 step is actually
/// needed: stop leaning on the outer range guard to scope this copy. Nest it
/// in its own `if storedVersion < 2 { ... }` step, the same way any v3 logic
/// must nest under `if storedVersion < 3 { ... }`, so each step only ever runs
/// for someone actually crossing that exact boundary.
func migrateAccounts(_ defaults: UserDefaults) {
    let storedVersion = defaults.integer(forKey: "accounts_schema_version")
    guard storedVersion < accountsSchemaVersion else {
        return
    }

    // "Configured" means a non-empty cookie everywhere else (UsageManager.hasCookie),
    // so it has to mean that here too. Treating an empty slot-1 string as
    // already-configured would skip the copy, stamp the version anyway, and put
    // the legacy cookie permanently out of reach: the version guard above means
    // there is no second pass.
    let legacyCookie = defaults.string(forKey: "claude_session_cookie") ?? ""
    let slotCookie = defaults.string(forKey: accountKey(1, "cookie")) ?? ""
    if !legacyCookie.isEmpty, slotCookie.isEmpty {
        defaults.set(legacyCookie, forKey: accountKey(1, "cookie"))
        // The notification threshold rides along with the cookie, inside this
        // same branch and never on its own: slot 1 has to resume where 1.3.x
        // left off, or an upgrading user sitting at 80% gets the 25/50/75
        // banners replayed at them on the first poll after updating. Hoisting
        // it out of the branch would be the mirror failure — stamping a stale
        // threshold onto a slot that never received the matching cookie, which
        // silently mutes that account's first alerts once one is pasted in.
        // A missing legacy threshold reads back as 0, which is the rearmed
        // state, so a 1.3.x install that never notified starts fully armed.
        defaults.set(defaults.integer(forKey: "last_notified_threshold"),
                     forKey: accountKey(1, "threshold"))
    }

    // Stamped unconditionally, OUTSIDE the branch above, and that placement is
    // load-bearing: it is what makes this a one-shot migration on EVERY
    // install, including one with nothing to copy. Moved inside the `if`, a
    // fresh install (no legacy cookie) would never be stamped, so this function
    // would re-arm on every single launch and the copy's own "slot 1 is empty"
    // test would become the only guard left. The moment a `claude_session_cookie`
    // value then appeared — a restored pre-1.4 preferences file, a trip back to
    // 1.3.x and forward again — it would land in slot 1 on the next launch,
    // configuring or resurrecting an account the user never asked for or had
    // deliberately cleared. One assertion ("fresh install: schema stamped", in
    // the now-deleted tests/main.swift) was all that pinned this; the comment
    // is the guard now.
    defaults.set(accountsSchemaVersion, forKey: "accounts_schema_version")
}
