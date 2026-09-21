import Foundation

print("highestCrossedThreshold")
// The bug this replaces: a fresh install already at 95% walked [25,50,75,90]
// and fired one notification per crossed threshold — four at once, eight with
// two accounts.
checkEqual(highestCrossedThreshold(percentage: 95, lastNotified: 0), 90,
           "fresh install at 95% reports one threshold, not four")
checkEqual(highestCrossedThreshold(percentage: 55, lastNotified: 25), 50,
           "crossing 50 after 25 reports 50")
checkEqual(highestCrossedThreshold(percentage: 26, lastNotified: 25), nil,
           "staying inside the same band reports nothing")
checkEqual(highestCrossedThreshold(percentage: 24, lastNotified: 0), nil,
           "below the first threshold reports nothing")
checkEqual(highestCrossedThreshold(percentage: 100, lastNotified: 90), nil,
           "already notified at the top band reports nothing")

print("rearmedThreshold")
checkEqual(rearmedThreshold(percentage: 95, lastNotified: 0), 90,
           "remembers the highest crossed threshold")
checkEqual(rearmedThreshold(percentage: 5, lastNotified: 90), 0,
           "a session reset rearms from zero")
checkEqual(rearmedThreshold(percentage: 30, lastNotified: 90), 25,
           "a drop to 30% rearms at 25, not at 0")
checkEqual(rearmedThreshold(percentage: 26, lastNotified: 25), 25,
           "no movement leaves the threshold alone")

print("parseUsagePayload")

func payload(_ json: String) -> Data { json.data(using: .utf8)! }

// Free plan: five_hour and seven_day only.
let free = payload("""
{"five_hour": {"utilization": 45.0, "resets_at": "2026-09-21T18:30:00.000000Z"},
 "seven_day": {"utilization": 22.0, "resets_at": "2026-09-27T09:00:00.000000Z"}}
""")
let freeSnapshot = parseUsagePayload(free)
checkEqual(freeSnapshot?.session?.usage, 45, "free: session utilization")
checkEqual(freeSnapshot?.weekly?.usage, 22, "free: weekly utilization")
checkEqual(freeSnapshot?.sonnet != nil, false, "free: no sonnet bucket")
checkEqual(freeSnapshot?.fable != nil, false, "free: no fable bucket")
check(freeSnapshot?.session?.resetsAt != nil, "free: session reset parsed")

// Pro plan: adds the seven_day_sonnet bucket.
let pro = payload("""
{"five_hour": {"utilization": 10.0},
 "seven_day": {"utilization": 30.0},
 "seven_day_sonnet": {"utilization": 12.0, "resets_at": "2026-09-27T09:00:00.000000Z"}}
""")
let proSnapshot = parseUsagePayload(pro)
checkEqual(proSnapshot?.sonnet != nil, true, "pro: sonnet bucket detected")
checkEqual(proSnapshot?.sonnet?.usage, 12, "pro: sonnet utilization")

// Fable is not a top-level key: it is a model-scoped entry in `limits`.
let fableInt = payload("""
{"five_hour": {"utilization": 5.0},
 "seven_day": {"utilization": 5.0},
 "limits": [{"scope": {"model": {"display_name": "Fable"}}, "percent": 7,
             "resets_at": "2026-09-27T09:00:00.000000Z"}]}
""")
checkEqual(parseUsagePayload(fableInt)?.fable != nil, true, "fable: detected in limits")
checkEqual(parseUsagePayload(fableInt)?.fable?.usage, 7, "fable: percent as Int")

// The same field comes back as a Double on other payloads, so neither
// `as? Int` nor `as? Double` alone is enough.
let fableDouble = payload("""
{"five_hour": {"utilization": 5.0},
 "seven_day": {"utilization": 5.0},
 "limits": [{"scope": {"model": {"display_name": "Fable"}}, "percent": 7.8}]}
""")
checkEqual(parseUsagePayload(fableDouble)?.fable?.usage, 7, "fable: percent as Double")

// A limits array without Fable must not turn the bar on.
let otherModel = payload("""
{"five_hour": {"utilization": 5.0},
 "seven_day": {"utilization": 5.0},
 "limits": [{"scope": {"model": {"display_name": "Opus"}}, "percent": 50}]}
""")
checkEqual(parseUsagePayload(otherModel)?.fable != nil, false, "fable: other models ignored")

// claude.ai does not send fractional seconds on every field. The pre-1.4
// parser only accepted the fractional form and silently dropped the rest.
let noFraction = payload("""
{"five_hour": {"utilization": 5.0, "resets_at": "2026-09-21T18:30:00Z"},
 "seven_day": {"utilization": 5.0}}
""")
check(parseUsagePayload(noFraction)?.session?.resetsAt != nil,
      "dates without fractional seconds still parse")

checkEqual(parseUsagePayload(payload("not json")), nil, "garbage returns nil")

// --- Partial/malformed payloads must not corrupt previously-good state. ---
// A zeroed sessionUsage flows into checkNotificationThresholds, which rearms
// every notification threshold — so "bucket absent" must stay distinguishable
// from "bucket present with usage 0" all the way up to the manager, which
// only copies a bucket onto its @Published properties when it is non-nil.

// 1. A key that's entirely absent leaves that bucket nil (manager writes nothing).
let missingFiveHour = payload("""
{"seven_day": {"utilization": 5.0}}
""")
checkEqual(parseUsagePayload(missingFiveHour)?.session, nil,
           "missing five_hour key leaves session bucket nil")

// 2. An empty object is a successful read with no data, not a wipe: the
// snapshot itself must be non-nil (distinct from the "not json" case above)
// while every bucket stays nil.
let emptyPayload = payload("{}")
let emptySnapshot = parseUsagePayload(emptyPayload)
check(emptySnapshot != nil, "empty payload still parses (success with no data, not garbage)")
checkEqual(emptySnapshot?.session, nil, "empty payload: session bucket nil")
checkEqual(emptySnapshot?.weekly, nil, "empty payload: weekly bucket nil")
checkEqual(emptySnapshot?.sonnet, nil, "empty payload: sonnet bucket nil")
checkEqual(emptySnapshot?.fable, nil, "empty payload: fable bucket nil")

// 3. A bucket present with an unparseable usage value stays nil rather than
// collapsing to 0 — a zeroed session bucket is exactly the shape that would
// rearm notification thresholds on garbage data, which is the bug this
// struct exists to prevent. A sibling bucket in the same payload still
// parses on its own.
let malformedUtilization = payload("""
{"five_hour": {"utilization": "oops"}, "seven_day": {"utilization": 5}}
""")
let malformedSnapshot = parseUsagePayload(malformedUtilization)
checkEqual(malformedSnapshot?.session, nil,
           "unparseable utilization leaves the bucket nil, not zeroed")
checkEqual(malformedSnapshot?.weekly?.usage, 5,
           "a sibling bucket still parses independently of a malformed one")

// 4. Every existing fixture above uses a "45.0"-style Double; a bare Int
// must parse too, since Int-or-Double is authorized for `utilization`.
let bareIntUtilization = payload("""
{"five_hour": {"utilization": 45}}
""")
checkEqual(parseUsagePayload(bareIntUtilization)?.session?.usage, 45,
           "utilization as a bare Int parses")

// 5. Assert the actual Date value, not just non-nil — a timezone bug would
// still produce *a* Date and pass a `!= nil` check silently. Expected epoch
// seconds computed independently with `date -u -j -f "%Y-%m-%dT%H:%M:%SZ"`.
let dateValues = payload("""
{"five_hour": {"utilization": 1.0, "resets_at": "2026-09-21T18:30:00.250000Z"},
 "seven_day": {"utilization": 1.0, "resets_at": "2026-09-27T09:00:00Z"}}
""")
let dateSnapshot = parseUsagePayload(dateValues)
checkEqual(dateSnapshot?.session?.resetsAt?.timeIntervalSince1970, 1790015400.25,
           "fractional-seconds timestamp parses to the exact expected instant")
checkEqual(dateSnapshot?.weekly?.resetsAt?.timeIntervalSince1970, 1790499600.0,
           "plain (non-fractional) timestamp parses to the exact expected instant")


print("notificationBody / testNotificationBody")

checkEqual(notificationBody(percentage: 90, prefix: ""),
           "You've reached 90% of your 5-hour session limit",
           "no prefix keeps the exact 1.3.x wording")
checkEqual(notificationBody(percentage: 90, prefix: "Work"),
           "Work — you've reached 90% of your 5-hour session limit",
           "a prefix names the account and lower-cases the body's lead word")
checkEqual(testNotificationBody(prefix: ""),
           "Test notification - You've reached 75% of your 5-hour session limit",
           "the test notification keeps its own wording with no prefix")
checkEqual(testNotificationBody(prefix: "Personal"),
           "Personal — test notification, you've reached 75% of your 5-hour session limit",
           "the test notification is prefixed without stacking two dashes in one line")

print("migrateAccounts")

func freshDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// A 1.3.x user carries their cookie and threshold under the legacy keys.
let upgrading = freshDefaults("cub.test.upgrading")
upgrading.set("anthropic-device-id=abc; sessionKey=xyz", forKey: "claude_session_cookie")
upgrading.set(75, forKey: "last_notified_threshold")
migrateAccounts(upgrading)
checkEqual(upgrading.string(forKey: "account_1_cookie"),
           "anthropic-device-id=abc; sessionKey=xyz", "upgrade: cookie copied to slot 1")
checkEqual(upgrading.integer(forKey: "account_1_threshold"), 75,
           "upgrade: threshold copied to slot 1")
checkEqual(upgrading.integer(forKey: "accounts_schema_version"), 2,
           "upgrade: schema version stamped")
// Copy, never delete: a rollback to 1.3.x must still find the cookie.
checkEqual(upgrading.string(forKey: "claude_session_cookie"),
           "anthropic-device-id=abc; sessionKey=xyz", "upgrade: legacy key survives")
checkEqual(upgrading.integer(forKey: "last_notified_threshold"), 75,
           "upgrade: legacy threshold survives")
// An upgrade inherits one account, never two.
checkEqual(upgrading.string(forKey: "account_2_cookie"), nil,
           "upgrade: slot 2 is left empty")

// A brand new install has nothing to carry over.
let fresh = freshDefaults("cub.test.fresh")
migrateAccounts(fresh)
checkEqual(fresh.string(forKey: "account_1_cookie"), nil, "fresh install: no cookie invented")
checkEqual(fresh.integer(forKey: "accounts_schema_version"), 2, "fresh install: schema stamped")

// Running twice must not clobber a cookie the user changed after migrating.
let rerun = freshDefaults("cub.test.rerun")
rerun.set("old-cookie", forKey: "claude_session_cookie")
migrateAccounts(rerun)
rerun.set("new-cookie", forKey: "account_1_cookie")
migrateAccounts(rerun)
checkEqual(rerun.string(forKey: "account_1_cookie"), "new-cookie",
           "idempotent: a post-migration cookie is not overwritten")

// An empty legacy cookie is not a cookie.
let empty = freshDefaults("cub.test.empty")
empty.set("", forKey: "claude_session_cookie")
migrateAccounts(empty)
checkEqual(empty.string(forKey: "account_1_cookie"), nil, "empty legacy cookie is ignored")

// A cookie with no notification history must land rearmed at 0, so the user
// gets the alerts they never saw rather than none.
let noThreshold = freshDefaults("cub.test.nothreshold")
noThreshold.set("cookie-only", forKey: "claude_session_cookie")
migrateAccounts(noThreshold)
checkEqual(noThreshold.integer(forKey: "account_1_threshold"), 0,
           "a legacy install with no threshold starts slot 1 rearmed")

// The settings both accounts share stay global: moving them per-slot would
// silently reset preferences the user already chose.
let globals = freshDefaults("cub.test.globals")
globals.set(false, forKey: "usage_notifications_enabled")
globals.set("dark", forKey: "appearance_mode")
migrateAccounts(globals)
checkEqual(globals.object(forKey: "usage_notifications_enabled") as? Bool, false,
           "migration leaves usage_notifications_enabled alone")
checkEqual(globals.string(forKey: "appearance_mode"), "dark",
           "migration leaves appearance_mode alone")

// An empty slot-1 cookie is not a configured account. No shipped 1.3.x build
// writes that state, but an intermediate build of this branch can, and the
// version guard means the copy gets exactly one attempt: skipping it here
// would put the user's cookie permanently out of reach.
let emptySlot = freshDefaults("cub.test.emptyslot")
emptySlot.set("legacy-cookie", forKey: "claude_session_cookie")
emptySlot.set("", forKey: "account_1_cookie")
emptySlot.set(60, forKey: "last_notified_threshold")
migrateAccounts(emptySlot)
checkEqual(emptySlot.string(forKey: "account_1_cookie"), "legacy-cookie",
           "an empty slot-1 cookie does not block the copy")
checkEqual(emptySlot.integer(forKey: "account_1_threshold"), 60,
           "the threshold rides along with an unblocked copy")

// The other side of that predicate: what the user deleted stays deleted. The
// version stamp is what guarantees it, since the cookie test alone would now
// read an absent slot-1 cookie as "copy it again".
let cleared = freshDefaults("cub.test.cleared")
cleared.set("legacy-cookie", forKey: "claude_session_cookie")
migrateAccounts(cleared)
cleared.removeObject(forKey: "account_1_cookie")
migrateAccounts(cleared)
checkEqual(cleared.string(forKey: "account_1_cookie"), nil,
           "a cookie the user cleared is not resurrected on the next launch")

// These suites are scratch space for the assertions above; drop them so a test
// run leaves nothing behind in the real preferences directory.
for name in ["cub.test.upgrading", "cub.test.fresh", "cub.test.rerun",
             "cub.test.empty", "cub.test.nothreshold", "cub.test.globals",
             "cub.test.emptyslot", "cub.test.cleared"] {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
}
print("")
print(failures == 0 ? "PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
