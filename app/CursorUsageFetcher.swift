// PR 11-BE — Cursor usage fetcher (feature-flagged off).
//
// Fourth local+web hybrid provider. Reads Cursor's own state.vscdb for
// the WorkOS session token, then hits Cursor's web dashboard API for
// the authoritative usage numbers. Nothing except the session token
// leaves the machine — and only ever to cursor.com and api2.cursor.sh
// (Cursor's own hosts).
//
// Data sources
// ------------
// 1. `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
//    (SQLite `ItemTable`). Three keys:
//      - `cursorAuth/accessToken`    (JWT / WorkOS session — 400 bytes)
//      - `cursorAuth/refreshToken`   (JWT — 400 bytes)
//      - `cursorAuth/stripeMembershipType` (short string like "free",
//        "pro", "enterprise")
//
// 2. `GET https://cursor.com/api/usage-summary`
//    Auth: `Cookie: WorkosCursorSessionToken=<accessToken value>`.
//    Response shape (verified against Raycast's cursor-costs
//    extension, extensions/cursor-costs/src/types.ts on
//    github.com/raycast/extensions):
//
//      {
//        billingCycleStart: string, billingCycleEnd: string,
//        membershipType: string, limitType: string,
//        isUnlimited: bool,
//        individualUsage: {
//          plan: { enabled, used, limit, remaining,
//                  breakdown: {included, bonus, total},
//                  autoPercentUsed?, apiPercentUsed?, totalPercentUsed? },
//          onDemand: { enabled, used, limit?, remaining? }
//        },
//        teamUsage: { … }
//      }
//    `used`, `limit`, `remaining` and every `breakdown` value are in
//    CENTS (`1207` = `$12.07`).
//
// 3. `POST https://cursor.com/api/dashboard/get-aggregated-usage-events`
//    Auth: same cookie. Body: `{teamId: -1, startDate: <ms>,
//    endDate: <ms>}` (JS Date.now milliseconds).
//    Response: `{aggregations: [{modelIntent, inputTokens?, outputTokens?,
//    cacheWriteTokens?, cacheReadTokens?, totalCents}], totalCents, …}`.
//    NOTE: every token count is a STRING (Cursor sends them stringified
//    to avoid JavaScript-Number precision loss on large integers).
//
// 4. `POST https://api2.cursor.sh/oauth/token` (refresh flow).
//    Body: `{grant_type: "refresh_token", client_id: "…",
//    refresh_token: "<refreshToken value>"}`.
//    Response: `{access_token, id_token, shouldLogout}`.
//    IMPORTANT: `shouldLogout: true` with empty tokens is a valid
//    server signal — Cursor tells the client the refresh has expired
//    and the user must sign in again on cursor.com. We surface this as
//    `.sessionExpired`, NOT as a transient error.
//
// Client ID for the refresh flow: `KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB`.
// This is Cursor's own OAuth client id (the same the Cursor.app
// binary uses); it is not a secret and appears in every OSS Cursor
// tracker on GitHub. Cited in the plan and in Dwtexe's now-archived
// `cursor-stats` extension.
//
// Feature posture
// ---------------
// `features.cursor.enabled` defaults false. Nothing registers a
// `CursorUsageStore` into the live registry yet (that lands in PR
// 11-UI). This file compiles and unit-tests but is inert until enabled.

import Foundation

// MARK: - Credential shape

/// Auth blob Cursor stores in its own state.vscdb. `stripeMembershipType`
/// is an optional hint for the UI ("Pro", "Free") when the live fetch
/// hasn't run yet.
public struct CursorCredentials: Equatable, Sendable {
    public var accessToken: String        // WorkOS session token — cookie
                                          // value on live API calls
    public var refreshToken: String       // used only for the /oauth/token
                                          // refresh flow
    public var stripeMembershipType: String?

    public init(accessToken: String, refreshToken: String, stripeMembershipType: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.stripeMembershipType = stripeMembershipType
    }
}

// MARK: - Snapshot pieces

/// One line of Cursor's per-model aggregation. Token counts are
/// STRINGIFIED on the wire — Cursor sends them as strings to avoid
/// JavaScript-Number precision loss on cache-write counts that can
/// exceed 2^53. We keep them as Int64 after parsing.
public struct CursorModelUsage: Equatable, Sendable {
    public var modelIntent: String        // e.g. "claude-opus-4-7"
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheWriteTokens: Int64
    public var cacheReadTokens: Int64
    public var totalCents: Int?           // nil when Cursor omits it

    public init(
        modelIntent: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheWriteTokens: Int64,
        cacheReadTokens: Int64,
        totalCents: Int?
    ) {
        self.modelIntent = modelIntent
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalCents = totalCents
    }
}

/// Aggregate parse result. Membership fields are strings the way Cursor
/// sends them — the UI is responsible for mapping them to friendly
/// labels.
public struct CursorSnapshot: Equatable, Sendable {
    public var membershipType: String            // "pro", "free", "enterprise", …
    public var limitType: String                 // e.g. "monthly"
    public var isUnlimited: Bool
    public var billingCycleStart: Date?
    public var billingCycleEnd: Date?
    /// Individual plan `used` in cents. e.g. 1207 = $12.07.
    public var planUsedCents: Int
    public var planLimitCents: Int
    public var planRemainingCents: Int
    /// Bonus + included cents from `individualUsage.plan.breakdown`.
    public var planIncludedCents: Int
    public var planBonusCents: Int
    /// On-demand usage. `limit`/`remaining` are nullable in Cursor's
    /// schema — nil when the plan does not enforce an on-demand cap.
    public var onDemandEnabled: Bool
    public var onDemandUsedCents: Int
    public var onDemandLimitCents: Int?
    public var onDemandRemainingCents: Int?
    /// Per-model aggregation from `/get-aggregated-usage-events`. Empty
    /// when the aggregation endpoint was skipped (e.g. summary-only
    /// mode) or produced no rows.
    public var perModel: [CursorModelUsage]

    public init(
        membershipType: String,
        limitType: String,
        isUnlimited: Bool,
        billingCycleStart: Date?,
        billingCycleEnd: Date?,
        planUsedCents: Int,
        planLimitCents: Int,
        planRemainingCents: Int,
        planIncludedCents: Int,
        planBonusCents: Int,
        onDemandEnabled: Bool,
        onDemandUsedCents: Int,
        onDemandLimitCents: Int?,
        onDemandRemainingCents: Int?,
        perModel: [CursorModelUsage]
    ) {
        self.membershipType = membershipType
        self.limitType = limitType
        self.isUnlimited = isUnlimited
        self.billingCycleStart = billingCycleStart
        self.billingCycleEnd = billingCycleEnd
        self.planUsedCents = planUsedCents
        self.planLimitCents = planLimitCents
        self.planRemainingCents = planRemainingCents
        self.planIncludedCents = planIncludedCents
        self.planBonusCents = planBonusCents
        self.onDemandEnabled = onDemandEnabled
        self.onDemandUsedCents = onDemandUsedCents
        self.onDemandLimitCents = onDemandLimitCents
        self.onDemandRemainingCents = onDemandRemainingCents
        self.perModel = perModel
    }
}

// MARK: - Path resolution + credential read

public enum CursorPathResolver {
    public struct Environment: Sendable {
        public var homeDirectoryPath: String
        public var applicationSupportPath: String
        public init(homeDirectoryPath: String, applicationSupportPath: String) {
            self.homeDirectoryPath = homeDirectoryPath
            self.applicationSupportPath = applicationSupportPath
        }
        public static func current() -> Environment {
            let home = NSHomeDirectory()
            return Environment(
                homeDirectoryPath: home,
                applicationSupportPath: (home as NSString).appendingPathComponent("Library/Application Support")
            )
        }
    }
    public static func stateDbPath(_ env: Environment) -> String? {
        guard !env.applicationSupportPath.isEmpty else { return nil }
        return "\(env.applicationSupportPath)/Cursor/User/globalStorage/state.vscdb"
    }
}

// MARK: - Response parsing

public enum CursorResponseParser {

    /// Parse a `/api/usage-summary` response into the summary-half of
    /// `CursorSnapshot` (per-model fields are empty; the caller merges
    /// the aggregation result into this record).
    ///
    /// Returns nil if the top-level JSON does not decode as an object
    /// or is missing the two required fields `membershipType` and
    /// `individualUsage`.
    public static func parseUsageSummary(_ data: Data) -> CursorSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let membershipType = dict["membershipType"] as? String,
              let individual = dict["individualUsage"] as? [String: Any] else {
            return nil
        }
        // Codex round-1 finding #3: `plan` MUST be a JSON object; if
        // Cursor's schema drifts and sends `plan: []`, `plan: null`,
        // or `plan: "…"` for the required section, the parser
        // previously fell through to zero cents and the UI rendered
        // the empty snapshot as success. Reject the whole response
        // instead so the store shows an error tile.
        guard let plan = individual["plan"] as? [String: Any] else {
            return nil
        }
        let limitType = dict["limitType"] as? String ?? "unknown"
        let isUnlimited = (dict["isUnlimited"] as? Bool) ?? false
        let cycleStart = parseISO8601(dict["billingCycleStart"])
        let cycleEnd = parseISO8601(dict["billingCycleEnd"])

        let planUsed = safeInt(plan["used"])
        let planLimit = safeInt(plan["limit"])
        let planRemaining = safeInt(plan["remaining"])
        let breakdown = plan["breakdown"] as? [String: Any] ?? [:]
        let planIncluded = safeInt(breakdown["included"])
        let planBonus = safeInt(breakdown["bonus"])

        let onDemand = individual["onDemand"] as? [String: Any] ?? [:]
        let onDemandEnabled = (onDemand["enabled"] as? Bool) ?? false
        let onDemandUsed = safeInt(onDemand["used"])
        let onDemandLimit = onDemand["limit"] as? NSNull == nil ? safeIntOptional(onDemand["limit"]) : nil
        let onDemandRemaining = onDemand["remaining"] as? NSNull == nil ? safeIntOptional(onDemand["remaining"]) : nil

        return CursorSnapshot(
            membershipType: membershipType,
            limitType: limitType,
            isUnlimited: isUnlimited,
            billingCycleStart: cycleStart,
            billingCycleEnd: cycleEnd,
            planUsedCents: planUsed,
            planLimitCents: planLimit,
            planRemainingCents: planRemaining,
            planIncludedCents: planIncluded,
            planBonusCents: planBonus,
            onDemandEnabled: onDemandEnabled,
            onDemandUsedCents: onDemandUsed,
            onDemandLimitCents: onDemandLimit,
            onDemandRemainingCents: onDemandRemaining,
            perModel: []
        )
    }

    /// Parse a `/api/dashboard/get-aggregated-usage-events` response
    /// into `[CursorModelUsage]`. Returns [] on any shape it does not
    /// recognise (the summary still renders).
    public static func parseAggregations(_ data: Data) -> [CursorModelUsage] {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let arr = dict["aggregations"] as? [[String: Any]] else {
            return []
        }
        var out: [CursorModelUsage] = []
        for row in arr {
            guard let intent = row["modelIntent"] as? String else { continue }
            out.append(CursorModelUsage(
                modelIntent: intent,
                inputTokens: safeInt64(row["inputTokens"]),
                outputTokens: safeInt64(row["outputTokens"]),
                cacheWriteTokens: safeInt64(row["cacheWriteTokens"]),
                cacheReadTokens: safeInt64(row["cacheReadTokens"]),
                totalCents: (row["totalCents"] as? NSNull) == nil ? safeIntOptional(row["totalCents"]) : nil
            ))
        }
        return out
    }

    /// Parse a `/oauth/token` refresh response. Empty tokens with
    /// `shouldLogout=true` are surfaced as `.sessionExpired`. Any other
    /// shape yields `.malformed`.
    public enum RefreshOutcome: Equatable, Sendable {
        case success(accessToken: String, idToken: String?)
        case sessionExpired            // shouldLogout=true with empty tokens
        case malformed
    }
    public static func parseRefresh(_ data: Data) -> RefreshOutcome {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return .malformed
        }
        let accessToken = (dict["access_token"] as? String) ?? ""
        let idToken = dict["id_token"] as? String
        let shouldLogout = (dict["shouldLogout"] as? Bool) ?? false
        if shouldLogout && accessToken.isEmpty {
            return .sessionExpired
        }
        if accessToken.isEmpty {
            return .malformed
        }
        return .success(accessToken: accessToken, idToken: idToken)
    }

    // MARK: - Field helpers

    /// True when the value is a Foundation-bridged JSON boolean.
    /// `JSONSerialization` bridges `true` / `false` into an NSNumber
    /// whose CFTypeID matches `CFBooleanGetTypeID()` — a plain
    /// `as? Int` succeeds and yields 0/1. Codex round-2 finding #3.
    private static func isJSONBoolean(_ raw: Any?) -> Bool {
        guard let n = raw as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Cursor sends token counts as stringified integers (avoiding
    /// JavaScript-Number precision loss on ≥ 2^53). Accept both Int and
    /// String forms. Clamps to Int64.max, rejects negatives. Rejects
    /// JSON booleans (round-2 finding #3). String forms above
    /// Int64.max clamp to Int64.max rather than silently returning 0
    /// (3cc round-3 finding #4).
    public static func safeInt64(_ raw: Any?) -> Int64 {
        if isJSONBoolean(raw) { return 0 }
        if let i = raw as? Int64 { return max(0, i) }
        if let i = raw as? Int { return max(0, Int64(i)) }
        if let d = raw as? Double, d.isFinite {
            let rounded = d.rounded()
            if rounded <= 0 { return 0 }
            if let n = Int64(exactly: rounded) { return n }
            return Int64.max
        }
        if let s = raw as? String {
            if let i = Int64(s) { return max(0, i) }
            // Above Int64.max as a positive string? Clamp instead of
            // returning 0. Rejects leading '-' (negative) and
            // non-numeric strings.
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty
                && !trimmed.hasPrefix("-")
                && trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return Int64.max
            }
        }
        return 0
    }

    /// Non-negative Int (0-clamped) used for the cents fields, which the
    /// Cursor schema always sends as bare JSON numbers. Rejects JSON
    /// booleans (round-2 finding #3).
    public static func safeInt(_ raw: Any?) -> Int {
        if isJSONBoolean(raw) { return 0 }
        if let i = raw as? Int { return max(0, i) }
        if let d = raw as? Double, d.isFinite {
            let rounded = d.rounded()
            if rounded <= 0 { return 0 }
            if let n = Int(exactly: rounded) { return n }
            return Int.max
        }
        if let s = raw as? String, let i = Int(s) { return max(0, i) }
        return 0
    }

    /// Cents fields that may legitimately be null (on-demand
    /// remaining/limit on an unlimited plan). Returns nil for null /
    /// missing / unparseable / boolean input; otherwise the
    /// non-negative Int. Rejects JSON booleans (round-2 finding #3).
    public static func safeIntOptional(_ raw: Any?) -> Int? {
        if raw == nil || raw is NSNull { return nil }
        if isJSONBoolean(raw) { return nil }
        if let i = raw as? Int { return max(0, i) }
        if let d = raw as? Double, d.isFinite {
            let rounded = d.rounded()
            if rounded <= 0 { return 0 }
            if let n = Int(exactly: rounded) { return n }
            return Int.max
        }
        if let s = raw as? String, let i = Int(s) { return max(0, i) }
        return nil
    }

    /// ISO 8601 with fractional-second tolerance — same shape as
    /// Claude Code timestamps.
    public static func parseISO8601(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Credential read

public enum CursorCredentialReader {

    /// Read the three `cursorAuth/*` rows from Cursor's state.vscdb.
    /// Throws every SQLiteReaderError variant; returns nil when the
    /// database opened cleanly but the three keys are absent (fresh
    /// Cursor install with no sign-in yet).
    public static func read(from stateDbPath: String) throws -> CursorCredentials? {
        let reader = try SQLiteReader(path: stateDbPath)
        defer { reader.close() }
        // One query per key — the ItemTable schema is `(key, value)`
        // with `ON CONFLICT REPLACE`, so a straight WHERE lookup is
        // O(index) and cheaper than a `WHERE key IN (…)` list.
        func read(_ key: String) throws -> String? {
            let rows = try reader.query(
                "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
                binds: [.text(key)]
            ) { $0.string("value") }
            return rows.first ?? nil
        }
        let access = try read("cursorAuth/accessToken")
        let refresh = try read("cursorAuth/refreshToken")
        let membership = try read("cursorAuth/stripeMembershipType")
        guard let access = access, let refresh = refresh else { return nil }
        return CursorCredentials(
            accessToken: access,
            refreshToken: refresh,
            stripeMembershipType: membership
        )
    }
}

// MARK: - Transport

/// Terminal outcomes the transport layer surfaces to the store. Every
/// live-fetch code path (summary, aggregation, refresh) maps to one of
/// these; keeping the enum flat means the store's apply hop is a
/// single switch.
public enum CursorTransportResult: Sendable {
    case success(Data)                   // 2xx with a body
    case unauthorized                    // 401/403 — trigger refresh
    case rateLimited(retryAfterSec: Int?) // 429
    case httpError(Int)                  // any other non-2xx
    case networkError                    // URLSession error
    case sessionExpired                  // Refresh flow returned
                                         // shouldLogout=true. Store shows
                                         // "sign in again in Cursor".
}

public protocol CursorTransport: Sendable {
    func fetchUsageSummary(
        cookieToken: String,
        completion: @escaping @Sendable (CursorTransportResult) -> Void
    )
    func fetchAggregations(
        cookieToken: String,
        startDateMs: Int64,
        endDateMs: Int64,
        completion: @escaping @Sendable (CursorTransportResult) -> Void
    )
    func refreshAccessToken(
        refreshToken: String,
        completion: @escaping @Sendable (CursorTransportResult) -> Void
    )
}

/// RFC 6265 §4.1.1 cookie-octet validator. Cursor's session tokens are
/// base64url-encoded WorkOS JWTs (letters, digits, `-`, `_`, `.`), all
/// of which are inside the cookie-octet range. A hostile token
/// containing `;`, `,`, `"`, `\`, space, or a control character would
/// splice a second cookie or split the header — this validator
/// rejects that before the header is composed. Codex round-1 finding #4.
public enum CursorTokenSafety {
    public static func isValidCookieValue(_ raw: String) -> Bool {
        guard !raw.isEmpty else { return false }
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            // %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E per RFC 6265.
            // Anything outside those ranges is a cookie-octet violation
            // (including CTLs, DQUOTE, comma, semicolon, whitespace,
            // backslash, and every non-ASCII character).
            let ok = v == 0x21
                || (v >= 0x23 && v <= 0x2B)
                || (v >= 0x2D && v <= 0x3A)
                || (v >= 0x3C && v <= 0x5B)
                || (v >= 0x5D && v <= 0x7E)
            if !ok { return false }
        }
        return true
    }
}

/// Production transport. Uses URLSession; all three endpoints share the
/// same cookie shape. The refresh endpoint uses POST with a JSON body.
public struct URLSessionCursorTransport: CursorTransport {
    private static let clientId = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    private static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let aggregationURL = URL(string: "https://cursor.com/api/dashboard/get-aggregated-usage-events")!
    private static let refreshURL = URL(string: "https://api2.cursor.sh/oauth/token")!

    public init() {}

    public func fetchUsageSummary(
        cookieToken: String,
        completion: @escaping @Sendable (CursorTransportResult) -> Void
    ) {
        var req = URLRequest(url: Self.summaryURL)
        req.httpMethod = "GET"
        applyStandardHeaders(&req, cookieToken: cookieToken)
        dispatch(req, completion: completion)
    }

    public func fetchAggregations(
        cookieToken: String,
        startDateMs: Int64,
        endDateMs: Int64,
        completion: @escaping @Sendable (CursorTransportResult) -> Void
    ) {
        var req = URLRequest(url: Self.aggregationURL)
        req.httpMethod = "POST"
        applyStandardHeaders(&req, cookieToken: cookieToken)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "teamId": -1,
            "startDate": startDateMs,
            "endDate": endDateMs,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        dispatch(req, completion: completion)
    }

    public func refreshAccessToken(
        refreshToken: String,
        completion: @escaping @Sendable (CursorTransportResult) -> Void
    ) {
        guard let safeRefresh = RequestSafety.headerValue(refreshToken) else {
            completion(.sessionExpired)
            return
        }
        var req = URLRequest(url: Self.refreshURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeUsageBar", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": Self.clientId,
            "refresh_token": safeRefresh,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        dispatch(req, completion: completion)
    }

    // MARK: - Helpers

    /// Standard headers Cursor's dashboard sends. Kept identical to the
    /// browser flow so a schema-level change (e.g. Referer-based auth
    /// enforcement) doesn't tomb-stone the endpoint for us.
    private func applyStandardHeaders(_ req: inout URLRequest, cookieToken: String) {
        // Cookie name is documented in the OSS Raycast extension and
        // matches Cursor's own web app. Value comes from
        // cursorAuth/accessToken.
        //
        // Codex round-1 finding #4: `RequestSafety.headerValue`
        // permits `;`, `,`, space, `\`, `"` — a compromised DB token
        // like `abc; WorkosCursorSessionToken=other` would splice a
        // second cookie into the header. Validate against RFC 6265
        // §4.1.1 cookie-octet set BEFORE composing the header.
        guard CursorTokenSafety.isValidCookieValue(cookieToken) else {
            return  // caller receives the unauthorized branch when
                    // Cursor rejects the missing/wrong cookie
        }
        req.setValue("WorkosCursorSessionToken=\(cookieToken)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeUsageBar", forHTTPHeaderField: "User-Agent")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        req.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "Referer")
    }

    private func dispatch(
        _ req: URLRequest,
        completion: @escaping @Sendable (CursorTransportResult) -> Void
    ) {
        let deliver: @Sendable (CursorTransportResult) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        URLSession.shared.dataTask(with: req) { data, response, error in
            if error != nil { deliver(.networkError); return }
            guard let http = response as? HTTPURLResponse else {
                deliver(.networkError); return
            }
            Log.info("Cursor API response", .count(http.statusCode))
            switch http.statusCode {
            case 200:
                if let data = data { deliver(.success(data)) }
                else { deliver(.networkError) }
            case 401, 403:
                deliver(.unauthorized)
            case 429:
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) }
                deliver(.rateLimited(retryAfterSec: retryAfter))
            default:
                deliver(.httpError(http.statusCode))
            }
        }.resume()
    }
}
