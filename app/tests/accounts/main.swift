import AppKit
import Combine
import Foundation

// The invariants that only exist once UsageManager and AccountsStore are
// compiled in. They are in a second target because the logic-only target
// cannot observe them: every assertion there stays green if the migration
// call moves below the `accounts` assignment, and that move is precisely what
// loses an upgrading user their cookie.

print("AccountsStore migration ordering")

func freshDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Pumps the main run loop briefly so a `DispatchQueue.main.async` block
/// scheduled moments ago gets a chance to run. A plain command-line
/// executable never drives its own run loop (no NSApplication, no
/// dispatchMain()), so without this the deferred prefix recompute in
/// AccountsStore's objectWillChange sink would never execute during a test.
/// The timer just gives the run loop a reason not to return immediately.
func flushMainQueue(for seconds: TimeInterval = 0.05) {
    let timer = Timer(timeInterval: seconds, repeats: false) { _ in }
    RunLoop.main.add(timer, forMode: .default)
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    timer.invalidate()
}

// A 1.3.x install: the legacy keys, nothing under the slot keys.
let legacy = freshDefaults("cub.test.store.legacy")
legacy.set("legacy-cookie-value", forKey: "claude_session_cookie")
legacy.set(50, forKey: "last_notified_threshold")

// Control first: a manager built with no migration ahead of it genuinely
// cannot see the legacy cookie. Without this, the next assertion could pass
// for the wrong reason and prove nothing.
checkEqual(UsageManager(slot: 1, defaults: legacy).hasCookie, false,
           "control: a manager on its own does not read the legacy cookie")

// So slot 1 seeing a cookie here is only explicable by the migration having
// already run when that manager's init read its key.
let store = AccountsStore(defaults: legacy)
checkEqual(store.accounts[0].hasCookie, true,
           "the migration runs before any manager reads its cookie")
checkEqual(legacy.string(forKey: "account_1_cookie"), "legacy-cookie-value",
           "slot 1 holds the copied cookie")
checkEqual(legacy.integer(forKey: "account_1_threshold"), 50,
           "slot 1 holds the copied threshold")
checkEqual(store.accounts[1].hasCookie, false, "slot 2 stays unconfigured")
checkEqual(store.configured.count, 1, "an upgrade yields exactly one configured account")
checkEqual(store.showsBadges, false, "one account shows no badges")
checkEqual(store.accounts.map { $0.displayName }, ["Account 1", "Account 2"],
           "unnamed accounts fall back to their slot names")

print("per-slot isolation")

// Two configured accounts, already migrated.
let pair = freshDefaults("cub.test.store.pair")
pair.set("cookie-1", forKey: "account_1_cookie")
pair.set("cookie-2", forKey: "account_2_cookie")
pair.set(75, forKey: "account_1_threshold")
pair.set(90, forKey: "account_2_threshold")
pair.set(accountsSchemaVersion, forKey: "accounts_schema_version")
let two = AccountsStore(defaults: pair)
checkEqual(two.configured.count, 2, "both accounts are configured")
checkEqual(two.showsBadges, true, "two accounts show badges")

// hasCookie has to announce itself: configured/showsBadges are derived from
// it, so a save that publishes nothing leaves the UI showing a stale account
// list. saveSessionCookie writes no other published property, so this fails
// unless the cookie itself is the thing that publishes.
var republishes = 0
let subscription = two.objectWillChange.sink { _ in republishes += 1 }
two.accounts[1].saveSessionCookie("cookie-2-renewed")
check(republishes > 0, "saving a cookie republishes through the store")
subscription.cancel()

checkEqual(pair.string(forKey: "account_2_cookie"), "cookie-2-renewed",
           "slot 2 saves onto its own key")
checkEqual(pair.string(forKey: "account_1_cookie"), "cookie-1",
           "saving slot 2 leaves slot 1's cookie alone")

// Clearing one account must not touch the other's notification state: a
// shared threshold key would rearm account 1 and re-fire every band it had
// already notified, with nothing on screen to explain it.
two.accounts[1].clearSessionCookie()
checkEqual(pair.integer(forKey: "account_1_threshold"), 75,
           "clearing slot 2 leaves slot 1's notification threshold alone")
checkEqual(pair.integer(forKey: "account_2_threshold"), 0,
           "clearing slot 2 resets its own threshold")
checkEqual(pair.string(forKey: "account_2_cookie"), nil, "clearing slot 2 drops its own cookie")
checkEqual(two.accounts[0].hasCookie, true, "slot 1 stays configured")
checkEqual(two.accounts[1].hasCookie, false, "slot 2 is no longer configured")
checkEqual(two.configured.count, 1, "configured tracks the clear")
checkEqual(two.showsBadges, false, "badges turn off once one account is left")

// Names are per slot too, and drive displayName.
two.accounts[0].name = "Work"
two.accounts[0].saveSettings()
checkEqual(pair.string(forKey: "account_1_name"), "Work", "slot 1 saves its own name")
checkEqual(two.accounts[0].displayName, "Work", "a named account displays its name")
checkEqual(two.accounts[1].displayName, "Account 2", "an unnamed account displays its slot name")
checkEqual(pair.string(forKey: "account_2_name"), nil, "naming slot 1 does not write slot 2's name")

// A whitespace-only name (e.g. a stray leading space) must fall back exactly
// like an empty one, not surface as a blank prefix in a notification banner.
// The stored key is asserted alongside it because slot 2's displayName was
// already "Account 2" before the write: without this, the fallback assertion
// would pass just as happily if the name never reached UserDefaults at all.
two.accounts[1].name = "   "
two.accounts[1].saveSettings()
checkEqual(two.accounts[1].displayName, "Account 2",
           "a whitespace-only name falls back to the slot name too")
checkEqual(pair.string(forKey: "account_2_name"), "   ",
           "the whitespace-only name really was written (the fallback is not vacuous)")

// And the trim has to be in the value displayName RETURNS, not only in the
// emptiness test it runs: this string is read straight into the notification
// banner, the popover section header and the Settings label.
two.accounts[1].name = " Work "
two.accounts[1].saveSettings()
checkEqual(two.accounts[1].displayName, "Work", "displayName trims a padded name")
checkEqual(pair.string(forKey: "account_2_name"), " Work ",
           "what is stored keeps its spaces, so typing one mid-name is not undone")
checkEqual(notificationBody(percentage: 90, prefix: two.accounts[1].displayName),
           "Work — you've reached 90% of your 5-hour session limit",
           "a padded name reaches the notification banner trimmed")

// A pasted name can carry a newline, which would break the banner, the header
// and the label across two lines.
two.accounts[1].name = "\nWork"
checkEqual(two.accounts[1].displayName, "Work", "displayName strips a pasted newline")
two.accounts[1].name = ""
two.accounts[1].saveSettings()

print("app-wide preferences are shared, not copied")

// Notifications, login item and shortcut are settings of the app, not of an
// account. Kept as a @Published copy loaded in each manager's init, unticking
// "Enable Usage Notifications" wrote slot 1 and the shared key while slot 2
// held its stale `true` and went on notifying until the next launch. So the
// assertion that matters is that the *other* manager sees the change without
// being rebuilt.
two.accounts[0].usageNotificationsEnabled = false
checkEqual(two.accounts[1].usageNotificationsEnabled, false,
           "disabling usage notifications on slot 1 is visible from slot 2")
checkEqual(pair.bool(forKey: "usage_notifications_enabled"), false,
           "the flag lands on the one shared key")

// And the guard reads it at the point of use: a 95% reading on slot 2 must
// bail out before notifying, which shows up as its threshold never advancing.
// With an init-time snapshot this wrote 90 and fired an alert.
two.accounts[1].checkNotificationThresholds(percentage: 95)
checkEqual(pair.integer(forKey: "account_2_threshold"), 0,
           "a reading on a muted account announces nothing and records nothing")

two.accounts[0].usageNotificationsEnabled = true
checkEqual(two.accounts[1].usageNotificationsEnabled, true,
           "re-enabling on slot 1 is visible from slot 2")

two.accounts[1].statusNotificationsEnabled = false
checkEqual(two.accounts[0].statusNotificationsEnabled, false,
           "status notifications are shared in the other direction too")

two.accounts[1].shortcutEnabled = false
checkEqual(two.accounts[0].shortcutEnabled, false, "the shortcut flag is shared")

// An unwritten key must read back as the shipped default, not as false.
let virgin = freshDefaults("cub.test.store.virgin")
let solo = UsageManager(slot: 1, defaults: virgin)
checkEqual(solo.usageNotificationsEnabled, true, "usage notifications default to on")
checkEqual(solo.statusNotificationsEnabled, true, "status notifications default to on")
checkEqual(solo.shortcutEnabled, true, "the shortcut defaults to on")

// The popover shows this instead of the cookie: enough to tell two accounts
// apart, never enough to be pasted back as one.
solo.saveSessionCookie("anthropic-device-id=abc; sessionKey=sk-xyz123")
checkEqual(solo.cookieSuffix, "xyz123", "cookieSuffix is the last 6 characters")
solo.clearSessionCookie()
checkEqual(solo.cookieSuffix, "", "a cleared account has no suffix to show")

print("")
print("clearing an upgraded account")

// Clear is the only revocation gesture the UI offers. migrateAccounts copies
// `claude_session_cookie` into slot 1 and deliberately never deletes it, and
// no other code path in the app deletes it either — so unless Clear does,
// every user upgraded from 1.3.x who pressed it kept a complete, valid session
// cookie sitting in plaintext in their preferences forever.
let upgraded = freshDefaults("cub.test.store.upgraded")
upgraded.set("legacy-cookie-value", forKey: "claude_session_cookie")
let upgradedStore = AccountsStore(defaults: upgraded)
checkEqual(upgradedStore.accounts[0].hasCookie, true,
           "the upgraded account starts out configured from the legacy key")

// Slot 2 has no claim on that key: clearing it must leave slot 1's origin alone.
upgradedStore.accounts[1].saveSessionCookie("cookie-2")
upgradedStore.accounts[1].clearSessionCookie()
checkEqual(upgraded.string(forKey: "claude_session_cookie"), "legacy-cookie-value",
           "clearing slot 2 leaves the legacy cookie alone")

upgradedStore.accounts[0].clearSessionCookie()
checkEqual(upgraded.string(forKey: "account_1_cookie"), nil,
           "clearing slot 1 drops its own cookie")
checkEqual(upgraded.string(forKey: "claude_session_cookie"), nil,
           "clearing slot 1 also drops the pre-1.4 cookie it was copied from")

// And the deletion sticks: the version stamp is already in place, so the next
// launch's migration cannot copy anything back.
migrateAccounts(upgraded)
checkEqual(upgraded.string(forKey: "account_1_cookie"), nil,
           "a cleared upgraded account is not resurrected on the next launch")

for name in ["cub.test.store.legacy", "cub.test.store.pair", "cub.test.store.virgin",
             "cub.test.store.upgraded"] {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
}

print("")
print("notification prefixes")

// One configured account: nothing to disambiguate, so the wording must stay
// exactly what 1.3.x users already know.
let soloPrefixDefaults = freshDefaults("cub.test.store.soloprefix")
soloPrefixDefaults.set(accountsSchemaVersion, forKey: "accounts_schema_version")
soloPrefixDefaults.set("cookie-1", forKey: "account_1_cookie")
let soloPrefixStore = AccountsStore(defaults: soloPrefixDefaults)
checkEqual(soloPrefixStore.accounts[0].notificationPrefix, "",
           "a single configured account carries no notification prefix")
checkEqual(notificationBody(percentage: 90, prefix: soloPrefixStore.accounts[0].notificationPrefix),
           "You've reached 90% of your 5-hour session limit",
           "single-account notification text matches the 1.3.x wording exactly")

// Two configured accounts: each carries its own name.
let pairPrefixDefaults = freshDefaults("cub.test.store.pairprefix")
pairPrefixDefaults.set(accountsSchemaVersion, forKey: "accounts_schema_version")
pairPrefixDefaults.set("cookie-1", forKey: "account_1_cookie")
pairPrefixDefaults.set("cookie-2", forKey: "account_2_cookie")
pairPrefixDefaults.set("Work", forKey: "account_1_name")
pairPrefixDefaults.set("Personal", forKey: "account_2_name")
let pairPrefixStore = AccountsStore(defaults: pairPrefixDefaults)
checkEqual(pairPrefixStore.accounts[0].notificationPrefix, "Work",
           "slot 1's prefix is its own name")
checkEqual(pairPrefixStore.accounts[1].notificationPrefix, "Personal",
           "slot 2's prefix is its own name")
checkEqual(notificationBody(percentage: 90, prefix: pairPrefixStore.accounts[0].notificationPrefix),
           "Work — you've reached 90% of your 5-hour session limit",
           "a threshold notification names the account that crossed it")

// Renaming an account updates the prefix it will use. objectWillChange fires
// BEFORE the property write, so recomputing the prefixes synchronously inside
// the sink would still see the OLD name; AccountsStore defers that recompute
// to the next runloop turn instead (see Accounts.swift), which is why this
// assertion needs a pumped run loop before it can observe the new value.
pairPrefixStore.accounts[0].name = "Renamed"
flushMainQueue()
checkEqual(pairPrefixStore.accounts[0].notificationPrefix, "Renamed",
           "renaming an account updates the prefix it will use")

for name in ["cub.test.store.soloprefix", "cub.test.store.pairprefix"] {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
}

// MARK: - Menu bar icon geometry
//
// The badge's clearances are hand-tuned constants — the spark's scale, the
// glyph grid's origin — and nothing else in the suite would notice them
// drifting. The icon is a pure function, so rasterising it offscreen and
// reading pixels back is the whole test.

print("")
print("menu bar icon")

/// Renders at `scale` device pixels per point. Row 0 is the TOP row.
func raster(_ image: NSImage, scale: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(image.size.width) * scale,
                               pixelsHigh: Int(image.size.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
    rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
}

/// Ink, at the threshold below which a pixel is invisible against the menu bar.
func inked(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
    alpha(rep, x, y) > 0.15
}

/// Alpha at a point in icon coordinates (y up from the bottom edge).
func alphaAtPoint(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> CGFloat {
    let s = CGFloat(rep.pixelsWide) / rep.size.width
    return alpha(rep, Int(x * s), rep.pixelsHigh - 1 - Int(y * s))
}

let plain = raster(menuBarIcon(percentage: 50, badge: nil), scale: 2)
let badged1 = raster(menuBarIcon(percentage: 50, badge: 1), scale: 2)
let badged2 = raster(menuBarIcon(percentage: 50, badge: 2), scale: 2)
let badged2At1x = raster(menuBarIcon(percentage: 50, badge: 2), scale: 1)

checkEqual(menuBarIcon(percentage: 50, badge: nil).size, NSSize(width: 16, height: 16),
           "the icon is 16x16 whatever the badge")
checkEqual(menuBarIcon(percentage: 50, badge: 2).size, NSSize(width: 16, height: 16),
           "a badge does not resize the icon")

// (a) Nothing clipped: the badge keeps a point of margin at the bottom and the
// right, so no cell is lost off the edge and it never sits flush against the
// percentage the button draws beside it.
for (name, rep) in [("1", badged1), ("2", badged2)] {
    var bottomInk = false, rightInk = false
    for x in 0..<rep.pixelsWide where inked(rep, x, rep.pixelsHigh - 1) { bottomInk = true }
    for y in 0..<rep.pixelsHigh where inked(rep, rep.pixelsWide - 1, y) { rightInk = true }
    check(!bottomInk, "badge \(name) leaves the bottom edge clear")
    check(!rightInk, "badge \(name) leaves the right edge clear")
}

// (b) Spark and digit never touch. Same colour, so a single shared pixel column
// fuses them into one blob — the failure the 0.8 scale shipped with.
/// Narrowest run of clear pixels between the spark's ink and the digit's, over
/// the rows the glyph box occupies. Only those rows: higher up the spark's
/// right spike reaches x = 10.2, past the glyph box's left edge, which is
/// harmless because the digit is nowhere near that height.
func minimumGap(_ rep: NSBitmapImageRep) -> Int {
    let s = CGFloat(rep.pixelsWide) / rep.size.width
    let split = Int(9.5 * s)                       // spark tip 8.84 | glyph box 10
    let top = rep.pixelsHigh - 1 - Int(9 * s)      // a point above the glyph box
    var worst = Int.max
    for y in top..<rep.pixelsHigh {
        var sparkMax = -1, digitMin = -1
        for x in 0..<rep.pixelsWide where inked(rep, x, y) {
            if x < split { sparkMax = x } else if digitMin < 0 { digitMin = x }
        }
        guard sparkMax >= 0, digitMin >= 0 else { continue }
        worst = min(worst, digitMin - sparkMax - 1)
    }
    return worst == Int.max ? Int.max : worst
}

check(minimumGap(badged1) >= 2, "badge 1 keeps a clear column off the spark")
check(minimumGap(badged2) >= 2, "badge 2 keeps a clear column off the spark")
check(minimumGap(badged2At1x) >= 1, "badge 2 keeps a clear column off the spark at 1x too")

// (c) No badge means no badge. The full-size spark does reach into the badge's
// corner, so the test is a cell the glyph fills and the spark cannot: the "2"
// bottom bar runs the width of the box, where the spark only has its bottom
// tip, near the centre.
check(alphaAtPoint(plain, x: 12.5, y: 1.5) < 0.02,
      "the unbadged icon leaves the badge's corner empty")
check(alphaAtPoint(badged2, x: 12.5, y: 1.5) > 0.9,
      "the badged icon fills it")

// And the shrunk spark really is shrunk: the full-size spark's bottom and left
// tips are ink, the badged one's are not.
check(alphaAtPoint(plain, x: 8.0, y: 3.5) > 0.9, "the unbadged spark still reaches down the bottom")
check(alphaAtPoint(badged2, x: 8.0, y: 3.5) < 0.02, "the badged spark has pulled up off it")
check(alphaAtPoint(plain, x: 12.0, y: 8.0) > 0.9, "the unbadged spark still reaches out to the right")
check(alphaAtPoint(badged2, x: 12.0, y: 8.0) < 0.02, "the badged spark has pulled in from it")

// (d) The reason the badge is drawn on the grid rather than set in a font: at
// 16 physical pixels every cell has to be a whole pixel, or the digit greys out
// into the mush a 9pt glyph produced.
var partialCells = 0
for row in 0..<7 {
    for column in 0..<5 {
        let a = alphaAtPoint(badged2At1x, x: 10.5 + CGFloat(column), y: 1.5 + CGFloat(row))
        if a > 0.02 && a < 0.98 { partialCells += 1 }
    }
}
checkEqual(partialCells, 0, "every badge cell is fully on or fully off at 1x")

print("")
print(failures == 0 ? "PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
