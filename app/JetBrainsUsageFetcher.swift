// PR 12-BE — JetBrains AI Assistant local quota reader (feature-flag off).
//
// Pure-local, XML-only. Reads
//   ~/Library/Application Support/JetBrains/{IDE}{Version}/options/AIAssistantQuotaManager2.xml
// plus the Android Studio path under
//   ~/Library/Application Support/Google/AndroidStudio{Version}/...
//
// CRITICAL — DMCA constraint (see .pr-bodies/RESUME.md's "Known caveats"):
// this fetcher NEVER contacts api.jetbrains.ai or grazie.aws.intellij.net.
// XML on disk only. A live-endpoint path is intentionally NOT provided.
//
// XML shape (verified against JetBrains-community IntelliJ Platform's
// PersistentStateComponent XML serialiser, and steipete/CodexBar's
// JetBrainsStatusProbe.swift which was reverse-engineered from live
// samples of the file):
//
//   <application>
//     <component name="AIAssistantQuotaManager2">
//       <option name="quotaInfo" value="&quot;type&quot;:&quot;Available&quot;,&quot;current&quot;:&quot;123&quot;,..." />
//       <option name="nextRefill" value="..." />
//     </component>
//   </application>
//
// Every value= attribute is an HTML-entity-encoded JSON string:
//   quotaInfo → { type, current, maximum, tariffQuota: { available }, until }
//   nextRefill → { type, next, tariff: { amount, duration } }
//
// Critical decoding notes:
//   * Every numeric field on the wire is a STRING, not a number
//     (JetBrains uses string-encoded values so their persisted-state
//     serialiser can round-trip them without losing precision).
//   * The correct reset date is `nextRefill.next`, NOT `quotaInfo.until`
//     (until is the subscription end, not the credit-window reset).
//   * `nextRefill.next` is ISO-8601 (fractional seconds sometimes
//     present, sometimes not — accept both).
//   * `tariff.duration` uses ISO-8601 durations like "PT720H" — we
//     surface this verbatim; the popover renders as-is.

import Foundation

// MARK: - IDE registry

/// One JetBrains-family IDE we recognise. `dirPrefix` is the folder
/// name JetBrains uses under `~/Library/Application Support/JetBrains`
/// (or `~/Library/Application Support/Google` for Android Studio) —
/// the version suffix is appended to this prefix (e.g. `IntelliJIdea2024.1`).
///
/// Prefix list verified against the JetBrains IntelliJ Platform SDK
/// docs and steipete/CodexBar's reverse-engineered detector (which
/// carries the same 15 entries). Two vendor roots are supported: the
/// classic `JetBrains` folder AND the `Google` folder used by Android
/// Studio (a JetBrains-derived IDE that ships under a different
/// vendor namespace).
public struct JetBrainsIDE: Sendable, Equatable, Hashable {
    public let dirPrefix: String
    public let displayName: String
    /// True when this IDE ships under `~/Library/Application Support/Google`
    /// instead of `~/Library/Application Support/JetBrains`. Only Android
    /// Studio qualifies today.
    public let underGoogleVendor: Bool

    public init(dirPrefix: String, displayName: String, underGoogleVendor: Bool = false) {
        self.dirPrefix = dirPrefix
        self.displayName = displayName
        self.underGoogleVendor = underGoogleVendor
    }
}

public enum JetBrainsIDECatalog {
    /// Every JetBrains IDE folder prefix we detect. Ordered
    /// alphabetically by folder prefix for stability. Adding a new IDE
    /// requires only extending this list — the resolver + fetcher use it
    /// generically. Android Studio is intentionally the only
    /// `underGoogleVendor: true` entry today.
    public static let all: [JetBrainsIDE] = [
        JetBrainsIDE(dirPrefix: "AndroidStudio", displayName: "Android Studio", underGoogleVendor: true),
        JetBrainsIDE(dirPrefix: "AppCode",       displayName: "AppCode"),
        JetBrainsIDE(dirPrefix: "Aqua",          displayName: "Aqua"),
        JetBrainsIDE(dirPrefix: "CLion",         displayName: "CLion"),
        JetBrainsIDE(dirPrefix: "DataGrip",      displayName: "DataGrip"),
        JetBrainsIDE(dirPrefix: "DataSpell",     displayName: "DataSpell"),
        JetBrainsIDE(dirPrefix: "Fleet",         displayName: "Fleet"),
        JetBrainsIDE(dirPrefix: "GoLand",        displayName: "GoLand"),
        JetBrainsIDE(dirPrefix: "IntelliJIdea",  displayName: "IntelliJ IDEA"),
        JetBrainsIDE(dirPrefix: "PhpStorm",      displayName: "PhpStorm"),
        JetBrainsIDE(dirPrefix: "PyCharm",       displayName: "PyCharm"),
        JetBrainsIDE(dirPrefix: "Rider",         displayName: "Rider"),
        JetBrainsIDE(dirPrefix: "RubyMine",      displayName: "RubyMine"),
        JetBrainsIDE(dirPrefix: "RustRover",     displayName: "RustRover"),
        JetBrainsIDE(dirPrefix: "WebStorm",      displayName: "WebStorm"),
    ]
}

// MARK: - Path resolution

/// Filesystem environment injected into the resolver so tests can
/// exercise the enumeration deterministically against a fixture tree.
/// A default `.current()` uses the real `~/Library/Application Support`.
public struct JetBrainsEnvironment: Sendable {
    public var jetbrainsVendorPath: String
    public var googleVendorPath: String
    public var fileExists: @Sendable (String) -> Bool
    public var contentsOfDirectory: @Sendable (String) -> [String]?
    public var attributes: @Sendable (String) -> [FileAttributeKey: Any]?

    public init(
        jetbrainsVendorPath: String,
        googleVendorPath: String,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        contentsOfDirectory: @escaping @Sendable (String) -> [String]? = { path in
            try? FileManager.default.contentsOfDirectory(atPath: path)
        },
        attributes: @escaping @Sendable (String) -> [FileAttributeKey: Any]? = { path in
            try? FileManager.default.attributesOfItem(atPath: path)
        }
    ) {
        self.jetbrainsVendorPath = jetbrainsVendorPath
        self.googleVendorPath = googleVendorPath
        self.fileExists = fileExists
        self.contentsOfDirectory = contentsOfDirectory
        self.attributes = attributes
    }

    public static func current() -> JetBrainsEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return JetBrainsEnvironment(
            jetbrainsVendorPath: "\(home)/Library/Application Support/JetBrains",
            googleVendorPath: "\(home)/Library/Application Support/Google"
        )
    }
}

/// A single detected IDE install with a candidate quota file. The
/// `version` is whatever suffix follows the folder prefix (e.g.
/// "2024.1", "2024.3.1"), preserved verbatim so we do not turn it into
/// a lossy `Int` — JetBrains uses build-style triple versions on some
/// IDEs, dotted-decimal on others.
public struct JetBrainsIDEInstall: Sendable, Equatable {
    public let ide: JetBrainsIDE
    public let version: String
    public let quotaFilePath: String

    public init(ide: JetBrainsIDE, version: String, quotaFilePath: String) {
        self.ide = ide
        self.version = version
        self.quotaFilePath = quotaFilePath
    }
}

public enum JetBrainsPathResolver {
    /// Enumerate every detected `AIAssistantQuotaManager2.xml` on the
    /// machine. Returns installs sorted by (name, descending version)
    /// so a deterministic tie-breaker exists — the store then picks
    /// the most-recently-modified one for the actual read (matching
    /// steipete/CodexBar's selection rule).
    public static func discover(_ env: JetBrainsEnvironment) -> [JetBrainsIDEInstall] {
        var out: [JetBrainsIDEInstall] = []
        for ide in JetBrainsIDECatalog.all {
            let vendor = ide.underGoogleVendor ? env.googleVendorPath : env.jetbrainsVendorPath
            guard env.fileExists(vendor) else { continue }
            guard let entries = env.contentsOfDirectory(vendor) else { continue }
            for entry in entries {
                // Case-sensitive prefix match — JetBrains's folder
                // casing is canonical (`IntelliJIdea` NOT `intellijidea`)
                // and a case-insensitive match would risk picking up a
                // similarly-named non-IDE folder (e.g. someone's own
                // `Fleets` folder under `~/Library/Application Support`).
                guard entry.hasPrefix(ide.dirPrefix) else { continue }
                let versionSuffix = String(entry.dropFirst(ide.dirPrefix.count))
                // Reject a bare prefix match — the version suffix must
                // start with a digit. This rules out an accidental
                // longer-prefix collision (e.g. `RustRover*` matching
                // some hypothetical `RustRoverExamples` folder).
                guard let firstChar = versionSuffix.first, firstChar.isNumber else { continue }
                let quotaPath = "\(vendor)/\(entry)/options/AIAssistantQuotaManager2.xml"
                if env.fileExists(quotaPath) {
                    out.append(JetBrainsIDEInstall(
                        ide: ide,
                        version: versionSuffix,
                        quotaFilePath: quotaPath
                    ))
                }
            }
        }
        return out.sorted { lhs, rhs in
            if lhs.ide.displayName != rhs.ide.displayName {
                return lhs.ide.displayName < rhs.ide.displayName
            }
            // Same IDE — newer version first.
            return compareVersions(lhs.version, rhs.version) > 0
        }
    }

    /// Pick the install whose quota XML was most recently written. This
    /// is the install the user has actually been running lately — its
    /// numbers are the ones they expect to see.
    public static func mostRecentlyModified(
        _ installs: [JetBrainsIDEInstall],
        env: JetBrainsEnvironment
    ) -> JetBrainsIDEInstall? {
        var best: (JetBrainsIDEInstall, Date)?
        for install in installs {
            guard let attrs = env.attributes(install.quotaFilePath),
                  let mod = attrs[.modificationDate] as? Date else { continue }
            if best == nil || mod > best!.1 {
                best = (install, mod)
            }
        }
        return best?.0 ?? installs.first
    }

    /// Compare two version strings by dotted numeric components. Missing
    /// components read as 0. Each component is parsed for its leading
    /// numeric prefix — so `2024.2-EAP` parses to `[2024, 2]`, not
    /// `[2024, 0]`. This matches the intent that an EAP build of a
    /// given minor version compares equal-major-minor to the release
    /// with the same minor.
    ///
    /// Public so tests can pin the numeric-comparison semantics. Not
    /// intended for downstream callers — the resolver uses it internally.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        let ap = a.split(separator: ".").map { leadingInt(String($0)) }
        let bp = b.split(separator: ".").map { leadingInt(String($0)) }
        let n = max(ap.count, bp.count)
        for i in 0..<n {
            let av = i < ap.count ? ap[i] : 0
            let bv = i < bp.count ? bp[i] : 0
            if av != bv { return av < bv ? -1 : 1 }
        }
        return 0
    }

    /// Parse the leading numeric prefix of `s` as an Int, returning 0
    /// if none. Used by `compareVersions` so JetBrains's suffixes
    /// (`-EAP`, `-RC1`) do not zero out the numeric component.
    static func leadingInt(_ s: String) -> Int {
        var buf = ""
        for ch in s {
            if ch.isNumber { buf.append(ch); continue }
            break
        }
        return Int(buf) ?? 0
    }
}

// MARK: - XML + JSON parsing

public struct JetBrainsQuotaSnapshot: Sendable, Equatable {
    /// Quota "type" string (e.g. "Available", "OverQuota"). Preserved
    /// verbatim from the JSON — the popover formats it via ProviderCopy.
    public let quotaType: String?
    /// Tokens (or generic units) used so far in the current window.
    public let used: Double
    /// Total tokens for the current window.
    public let maximum: Double
    /// Remaining tokens per `tariffQuota.available` if present, else
    /// `max(0, maximum - used)`.
    public let available: Double
    /// The subscription end date per `quotaInfo.until`. This is NOT the
    /// reset date — the reset is `refillNext` below.
    public let subscriptionUntil: Date?
    /// Refill window "type" (e.g. "Known", "Unknown") from `nextRefill.type`.
    public let refillType: String?
    /// The actual reset date the popover uses.
    public let refillNext: Date?
    /// The refill amount, if published (matches `nextRefill.tariff.amount`).
    public let refillAmount: Double?
    /// ISO-8601 duration string of the refill window (e.g. "PT720H").
    public let refillDuration: String?

    public init(
        quotaType: String?,
        used: Double,
        maximum: Double,
        available: Double,
        subscriptionUntil: Date?,
        refillType: String?,
        refillNext: Date?,
        refillAmount: Double?,
        refillDuration: String?
    ) {
        self.quotaType = quotaType
        self.used = used
        self.maximum = maximum
        self.available = available
        self.subscriptionUntil = subscriptionUntil
        self.refillType = refillType
        self.refillNext = refillNext
        self.refillAmount = refillAmount
        self.refillDuration = refillDuration
    }

    /// Fraction of the window consumed, clamped to [0, 1]. Falls back to
    /// `used / maximum` if `available` is absent; then to zero if
    /// maximum is zero (an unlimited or unknown-state quota).
    public var usedFraction: Double {
        guard maximum > 0 else { return 0 }
        // Prefer available-derived fraction (matches JetBrains's own
        // display in the IDE). If available is not populated, fall
        // back to used-derived.
        let usedFromAvailable = max(0.0, maximum - available)
        let raw = usedFromAvailable > 0 ? usedFromAvailable : used
        return min(1.0, max(0.0, raw / maximum))
    }
}

public enum JetBrainsReadOutcome: Sendable, Equatable {
    /// Successful parse — both `quotaInfo` and (optionally) `nextRefill`
    /// decoded cleanly.
    case success(JetBrainsQuotaSnapshot)
    /// File exists but the `<component name="AIAssistantQuotaManager2">`
    /// block is absent — happens on a fresh install where AI Assistant
    /// was never enabled.
    case componentMissing
    /// The component block exists but the `quotaInfo` option is absent
    /// or its JSON refused to parse. Surfaces as an update-app prompt.
    case malformedPayload
}

public enum JetBrainsUsageFetcher {
    /// Read and parse the quota XML at `path`. Never touches the
    /// network. The reader is Sendable so it can be dispatched to a
    /// background queue.
    public static func read(from path: String) throws -> JetBrainsReadOutcome {
        // Bound the file size — the real XML is under 4 KiB in every
        // sample. If someone points us at a giant XML we refuse
        // rather than mmap-ing it.
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        if let size = attrs[.size] as? NSNumber, size.intValue > 1_048_576 {
            return .malformedPayload
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let text = String(data: data, encoding: .utf8) else {
            return .malformedPayload
        }
        return parseXMLText(text)
    }

    /// Parse the raw XML text. Split from `read(from:)` so unit tests
    /// exercise the parser directly without a file on disk.
    ///
    /// Codex R2 P3: iterate ALL matching `AIAssistantQuotaManager2`
    /// component blocks. IntelliJ's PersistentStateComponent
    /// serialiser has been observed to emit a stale duplicate
    /// component alongside a fresh write in some crash-recovery
    /// paths.
    ///
    /// chk1 audit Bug #5: iterate `bodies.reversed()` so a
    /// LATER-in-file component wins over an EARLIER stale duplicate.
    /// Rationale: PersistentStateComponent writes are effectively
    /// append-then-truncate — a partial crash-recovery scenario
    /// leaves the stale content BEFORE the fresh content in the
    /// file. Additionally, if two candidate parses succeed, we
    /// prefer the one whose `quotaInfo.until` is the LATEST — that
    /// is semantically the freshest snapshot regardless of file
    /// order.
    public static func parseXMLText(_ text: String) -> JetBrainsReadOutcome {
        // Find every AIAssistantQuotaManager2 component. Deliberately
        // regex-based rather than an XML DOM because IntelliJ's
        // PersistentStateComponent format writes `<option name="..." value="..."/>`
        // with HTML entities inside the value attribute — a full XML
        // decoder would double-decode the entities and mangle the JSON.
        let componentPattern = "<component[^>]*name\\s*=\\s*\"AIAssistantQuotaManager2\"[^>]*>([\\s\\S]*?)</component>"
        let bodies = allMatchBodies(componentPattern, in: text)
        if bodies.isEmpty { return .componentMissing }

        // First pass: collect every valid parse, tagged with its
        // file-order index so tie-breaks can prefer later-in-file
        // deterministically. Codex R1 P2 on chk1 audit Bug #5:
        // `max(by:)` keeps the FIRST element when the comparator
        // reports equal, so two components with identical `until`
        // would pick the earlier one — contradicting the
        // "append-then-truncate → later wins" rationale.
        var successes: [(snap: JetBrainsQuotaSnapshot, index: Int)] = []
        var sawAnyPayload = false
        for (index, body) in bodies.enumerated() {
            let outcome = parseComponentBody(body)
            switch outcome {
            case .success(let snap):
                successes.append((snap, index))
            case .malformedPayload:
                sawAnyPayload = true
            case .componentMissing:
                continue
            }
        }
        if successes.isEmpty {
            return sawAnyPayload ? .malformedPayload : .componentMissing
        }
        if successes.count == 1 {
            return .success(successes[0].snap)
        }
        // Multiple valid parses — pick the freshest by
        // `subscriptionUntil`. Codex R1 P2: on equal-`until`
        // ties, prefer the LATER-in-file candidate so the
        // append-then-truncate rationale still holds. A missing
        // `until` on ANY candidate means we cannot compare on
        // that axis; fall back to the LAST valid parse in
        // file-order.
        let allHaveUntil = successes.allSatisfy { $0.snap.subscriptionUntil != nil }
        if allHaveUntil {
            let freshest = successes.max(by: { lhs, rhs in
                let l = lhs.snap.subscriptionUntil ?? .distantPast
                let r = rhs.snap.subscriptionUntil ?? .distantPast
                if l != r { return l < r }
                // Equal `until` → higher file index wins.
                return lhs.index < rhs.index
            })!
            return .success(freshest.snap)
        }
        return .success(successes.last!.snap)
    }

    /// Parse a single `<component>` body. Extracted so
    /// `parseXMLText` can retry against a subsequent component when
    /// the first is a stale duplicate.
    private static func parseComponentBody(_ componentBody: String) -> JetBrainsReadOutcome {
        let quotaInfoRaw = optionValue(named: "quotaInfo", in: componentBody)
        let nextRefillRaw = optionValue(named: "nextRefill", in: componentBody)
        guard let quotaInfoRaw = quotaInfoRaw, !quotaInfoRaw.isEmpty else {
            return .malformedPayload
        }

        let quotaDecoded = decodeHTMLEntities(quotaInfoRaw)
        guard let quotaJSON = parseJSONObject(quotaDecoded) else {
            return .malformedPayload
        }

        let quotaType = quotaJSON["type"] as? String
        let currentStr = quotaJSON["current"] as? String
        let maximumStr = quotaJSON["maximum"] as? String
        let untilStr = quotaJSON["until"] as? String
        let tariffQuota = quotaJSON["tariffQuota"] as? [String: Any]
        let availableStr = tariffQuota?["available"] as? String

        let used = doubleFromString(currentStr)
        let maximum = doubleFromString(maximumStr)
        let parsedAvailable: Double? = availableStr.flatMap { s in
            guard let d = Double(s), d.isFinite else { return nil }
            return d
        }
        let available = parsedAvailable ?? max(0.0, maximum - used)
        let subscriptionUntil = untilStr.flatMap(parseISODate(_:))

        var refillType: String?
        var refillNext: Date?
        var refillAmount: Double?
        var refillDuration: String?
        if let nextRefillRaw = nextRefillRaw, !nextRefillRaw.isEmpty,
           let refillJSON = parseJSONObject(decodeHTMLEntities(nextRefillRaw)) {
            refillType = refillJSON["type"] as? String
            if let n = refillJSON["next"] as? String {
                refillNext = parseISODate(n)
            }
            let tariff = refillJSON["tariff"] as? [String: Any]
            let tariffAmountStr = tariff?["amount"] as? String
            let flatAmountStr = refillJSON["amount"] as? String
            refillAmount = doubleOrNilFromString(tariffAmountStr ?? flatAmountStr)
            refillDuration = (tariff?["duration"] as? String) ?? (refillJSON["duration"] as? String)
        }

        return .success(JetBrainsQuotaSnapshot(
            quotaType: quotaType,
            used: used,
            maximum: maximum,
            available: available,
            subscriptionUntil: subscriptionUntil,
            refillType: refillType,
            refillNext: refillNext,
            refillAmount: refillAmount,
            refillDuration: refillDuration
        ))
    }

    // MARK: - Helpers

    /// Extract the first regex capture-group-1 substring from `text`.
    static func firstMatchBody(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let bodyRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[bodyRange])
    }

    /// Extract every regex capture-group-1 substring from `text` in
    /// file-order. Used by `parseXMLText` to iterate all
    /// `<component>` blocks so a stale duplicate does not shadow a
    /// fresh one (Codex R2 P3).
    static func allMatchBodies(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        var out: [String] = []
        for match in matches {
            guard match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: text) else { continue }
            out.append(String(text[r]))
        }
        return out
    }

    /// Extract the `value="..."` (or `value='...'`) attribute from an
    /// `<option name="..." value="..."/>` element within a component
    /// body. Handles either attribute order (name-first or value-first).
    static func optionValue(named name: String, in componentBody: String) -> String? {
        let namePattern = NSRegularExpression.escapedPattern(for: name)
        // name-then-value
        let patternA = "<option[^>]*name\\s*=\\s*[\"']\(namePattern)[\"'][^>]*value\\s*=\\s*[\"']([^\"']*)[\"']"
        // value-then-name
        let patternB = "<option[^>]*value\\s*=\\s*[\"']([^\"']*)[\"'][^>]*name\\s*=\\s*[\"']\(namePattern)[\"']"
        for pattern in [patternA, patternB] {
            if let v = firstMatchBody(pattern, in: componentBody) {
                return v
            }
        }
        return nil
    }

    /// Reverse the six HTML entities IntelliJ's PersistentStateComponent
    /// serialiser writes into `value=` attributes. Order matters — decode
    /// `&amp;` LAST so a stray `&amp;quot;` decodes correctly. In
    /// practice IntelliJ escapes `&` inside JSON via `&amp;` and then
    /// escapes the quotes via `&quot;`, so decoding `&quot;` before
    /// `&amp;` is safe. Public so tests can pin the decoding order
    /// (a regression-critical invariant).
    public static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        // Decoding order: named entities first, then `&amp;` last so
        // `&amp;quot;` does NOT decode into `&quot;` and then to `"`.
        out = out.replacingOccurrences(of: "&#10;", with: "\n")
        out = out.replacingOccurrences(of: "&#13;", with: "\r")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&apos;", with: "'")
        out = out.replacingOccurrences(of: "&lt;", with: "<")
        out = out.replacingOccurrences(of: "&gt;", with: ">")
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        return out
    }

    /// Parse a JSON object payload. Accepts both a full `{...}` object
    /// AND a bare property list `key:value,key:value` — IntelliJ's
    /// serialiser has been observed to emit both. If a bare list, we
    /// wrap it in braces before decoding.
    static func parseJSONObject(_ raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrapped: String
        if trimmed.hasPrefix("{") {
            wrapped = trimmed
        } else {
            wrapped = "{" + trimmed + "}"
        }
        guard let data = wrapped.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// Decode an ISO-8601 date string. Accepts fractional seconds
    /// (`.withFractionalSeconds`) and the plain form; JetBrains has
    /// been seen emitting both across IDE versions.
    static func parseISODate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// String-to-Double with hostile-input clamping. `1e400` returns
    /// nil; a plain `"nan"` returns 0. Called on wire fields that are
    /// STRING-encoded numbers per JetBrains's serialiser.
    static func doubleFromString(_ raw: String?) -> Double {
        guard let raw = raw, let d = Double(raw), d.isFinite else { return 0 }
        return d
    }

    /// Optional variant — returns nil when the input is absent or
    /// non-finite. Used for `refillAmount` where "absent" is a valid
    /// distinct state.
    static func doubleOrNilFromString(_ raw: String?) -> Double? {
        guard let raw = raw, let d = Double(raw), d.isFinite else { return nil }
        return d
    }
}
