// PR 13-BE — Roo Code + Zoo Code path resolution + settings.json
// extraction (feature-flag off).
//
// Roo Code (github.com/RooCodeInc/Roo-Code, archived May 2026,
// marketplace id RooVeterinaryInc.roo-cline) and Zoo Code
// (github.com/Zoo-Code-Org/Zoo-Code, active fork, marketplace id
// ZooCodeOrganization.zoo-code) both write to VS Code globalStorage
// under their respective publisher.name folder, with the same
// `tasks/{taskId}/` layout Cline uses.
//
// We enumerate SIX VS Code family hosts times ONE extension id per
// resolveScanRoots call. Two call sites (one per extension) live in
// RooUsageStore and ZooUsageStore. Each scan root carries an id that
// names the host (for diagnostic tiles). Duplicates between hosts are
// impossible (each host has a distinct Application Support folder).
//
// Plus per-host customStoragePath discovery. Roo/Zoo let a user
// relocate task storage via a VS Code workspace setting
// `roo-cline.customStoragePath` or `zoo-code.customStoragePath` in the
// host's `settings.json`. We extract the value with a targeted
// state-machine key extractor (`JSONCKeyExtractor`) that respects
// string-vs-code context — NOT a naive regex or comment-stripping
// pre-pass, both of which corrupt real user settings.json files
// (3cc R3 F1).
//
// Extracted values are validated: expand `~`, standardise, resolve
// symlinks via realpath, verify the resolved path is inside `$HOME`
// (reject `/System`, `/Applications`, `/private/etc`, `/tmp`,
// `/var/tmp`), verify is-directory, reject any variable substitution
// (`$…`, `${…}`, `%…`) (3cc R3 F14).
//
// Filesystem-identity dedupe via stat() dev+inode (symlink-follow)
// so a baseline scan root and a matching customStoragePath do not
// double-count.
//
// Feature posture — `features.roo.enabled` and `features.zoo.enabled`
// both default false. Nothing registers a store into the live
// registry yet (that lands in PR 13-UI).

import Foundation

public enum RooZooExtension: String, Sendable, Equatable, CaseIterable {
    case roo = "RooVeterinaryInc.roo-cline"
    case zoo = "ZooCodeOrganization.zoo-code"

    /// Key in the VS Code host settings.json that redirects the per-
    /// workspace storage base.
    public var customStoragePathKey: String {
        switch self {
        case .roo: return "roo-cline.customStoragePath"
        case .zoo: return "zoo-code.customStoragePath"
        }
    }

    /// User-facing short display name (used in tile diagnostics).
    public var displayShortName: String {
        switch self {
        case .roo: return "Roo Code"
        case .zoo: return "Zoo Code"
        }
    }
}

/// Reader abstraction so tests can inject a fake `settings.json` body
/// per path without touching the real filesystem.
public protocol SettingsReader: Sendable {
    func read(atPath: String) -> String?
}

public struct FileSettingsReader: SettingsReader, Sendable {
    public init() {}
    public func read(atPath: String) -> String? {
        // Try UTF-8 first (VS Code writes UTF-8). Fall back to
        // encoding auto-detect for pathological hand-edited files
        // (Latin-1 / UTF-16 with BOM).
        if let s = try? String(contentsOfFile: atPath, encoding: .utf8) {
            return s
        }
        if let s = try? String(contentsOfFile: atPath) {
            return s
        }
        return nil
    }
}

public enum RooZooPathResolver {

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

    public struct ScanRoot: Equatable, Sendable {
        public var id: String
        public var tasksDirectoryPath: String
        public var extensionId: RooZooExtension
        public init(id: String, tasksDirectoryPath: String, extensionId: RooZooExtension) {
            self.id = id
            self.tasksDirectoryPath = tasksDirectoryPath
            self.extensionId = extensionId
        }
    }

    /// The six VS Code family hosts we scan. Same set as Cline
    /// (`ClinePathResolver`) plus Cursor Nightly (3cc R3 F19).
    static let hosts: [(String, String)] = [
        ("VS Code", "Code"),
        ("VS Code Insiders", "Code - Insiders"),
        ("VSCodium", "VSCodium"),
        ("Cursor", "Cursor"),
        ("Cursor Nightly", "Cursor Nightly"),
        ("Windsurf", "Windsurf"),
    ]

    public static func resolveScanRoots(
        _ env: Environment,
        for ext: RooZooExtension,
        settingsReader: SettingsReader = FileSettingsReader()
    ) -> [ScanRoot] {
        var out: [ScanRoot] = []
        var seenIdentity: Set<String> = []
        var seenPathKey: Set<String> = []

        func addPath(_ id: String, _ rawBase: String) {
            let tasks = (rawBase as NSString).appendingPathComponent("tasks")
            let normalized = (tasks as NSString).standardizingPath
            if let identity = fileIdentity(of: normalized) {
                if !seenIdentity.insert(identity).inserted { return }
                out.append(ScanRoot(id: id, tasksDirectoryPath: normalized, extensionId: ext))
                return
            }
            let caseFolded = normalized.lowercased()
            if !seenPathKey.insert(caseFolded).inserted { return }
            out.append(ScanRoot(id: id, tasksDirectoryPath: normalized, extensionId: ext))
        }

        for (label, folder) in hosts {
            guard !env.applicationSupportPath.isEmpty else { continue }
            let base = "\(env.applicationSupportPath)/\(folder)/User/globalStorage/\(ext.rawValue)"
            addPath(label, base)

            // customStoragePath extraction from this host's settings.json.
            let settingsPath = "\(env.applicationSupportPath)/\(folder)/User/settings.json"
            if let text = settingsReader.read(atPath: settingsPath),
               let extracted = JSONCKeyExtractor.extract(key: ext.customStoragePathKey, fromJSONC: text),
               let validated = validateCustomStoragePath(extracted, homeDirectoryPath: env.homeDirectoryPath) {
                addPath("\(label) (custom storage)", validated)
            }
        }
        return out
    }

    /// Validate a `customStoragePath` value. Returns the resolved
    /// absolute path on success, nil on failure.
    ///
    /// 3cc R3 F14: reject anything outside `$HOME` after realpath
    /// resolution, reject variable substitutions, verify is-directory.
    public static func validateCustomStoragePath(_ raw: String, homeDirectoryPath: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Reject variable substitutions — VS Code does NOT expand
        // shell variables in settings.json path values (per its own
        // docs), and neither should we. `$`, `${`, `%` all indicate
        // a variable-substitution attempt.
        if trimmed.contains("$") || trimmed.contains("${") || trimmed.contains("%") {
            return nil
        }
        // Expand `~/` if the value starts with it.
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        // Realpath resolution (follows symlinks). Falls back to the
        // standardised path when the leaf does not exist yet (fresh
        // customStoragePath configured but no data written).
        let resolved: String
        if let p = realpath(standardized, nil) {
            defer { free(p) }
            resolved = String(cString: p)
        } else {
            resolved = standardized
        }
        // Must be under home after realpath.
        let homeResolved: String
        if let p = realpath(homeDirectoryPath, nil) {
            defer { free(p) }
            homeResolved = String(cString: p)
        } else {
            homeResolved = homeDirectoryPath
        }
        guard resolved == homeResolved || resolved.hasPrefix(homeResolved + "/") else {
            return nil
        }
        // Verify is-directory when it exists. Non-existent leaf is
        // acceptable (see resolved-fallback above).
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) {
            if !isDir.boolValue { return nil }
        }
        return resolved
    }

    /// Filesystem identity via `stat()` dev+inode. Symlink-follow.
    /// Duplicates `ClinePathResolver.fileIdentity` (kept local rather
    /// than importing to avoid a cross-file dependency between two
    /// otherwise-independent providers).
    static func fileIdentity(of path: String) -> String? {
        var st = stat()
        if stat(path, &st) == 0 {
            return "\(UInt64(st.st_dev)):\(UInt64(st.st_ino))"
        }
        // Nonexistent leaf but existing parent still dedupes
        // (parent-dev:parent-ino:tail).
        let parent = (path as NSString).deletingLastPathComponent
        var ps = stat()
        if stat(parent, &ps) == 0 {
            let tail = (path as NSString).lastPathComponent
            return "\(UInt64(ps.st_dev)):\(UInt64(ps.st_ino)):\(tail)"
        }
        return nil
    }
}

/// State-machine JSONC key extractor.
///
/// Given the raw `settings.json` text and a target key, walk the file
/// while tracking whether we are inside a string, a line comment, or
/// a block comment. Return the string value associated with the LAST
/// occurrence of the exact key (top-level or nested — settings.json
/// is a flat object in practice).
///
/// This is deliberately NOT a full JSONC parser — it looks for the
/// key literally, respecting only the minimum lexical structure
/// needed to avoid comment / string / escape footguns.
///
/// Handled:
///   - `//` line comments (up to `\n` or `\r\n`)
///   - `/* … */` block comments (single-level; VS Code JSONC does not
///     nest block comments)
///   - `"…"` string literals with `\"`, `\\`, `\n`, `\t`, `\r`, `\/`
///     escapes
///   - CRLF line endings
///   - BOM at file start (U+FEFF)
///   - Comments that contain the target key are ignored
///   - The target key appearing inside a string value (e.g. as
///     documentation) is ignored — matching only fires from `normal`
///     state
///
/// Returns nil when the key is not present or when the value is not
/// a JSON string.
public enum JSONCKeyExtractor {

    public static func extract(key: String, fromJSONC text: String) -> String? {
        var scan = text
        // Strip UTF-8 BOM if present.
        if scan.hasPrefix("\u{FEFF}") {
            scan.removeFirst()
        }
        let bytes = Array(scan.utf8)
        var i = 0
        var lastMatchedValue: String? = nil
        let targetBytes = Array(("\"" + key + "\"").utf8)

        enum State { case normal; case inString; case inLineComment; case inBlockComment }
        var state: State = .normal

        while i < bytes.count {
            let c = bytes[i]
            switch state {
            case .normal:
                if c == UInt8(ascii: "/") && i + 1 < bytes.count {
                    let n = bytes[i + 1]
                    if n == UInt8(ascii: "/") { state = .inLineComment; i += 2; continue }
                    if n == UInt8(ascii: "*") { state = .inBlockComment; i += 2; continue }
                }
                if c == UInt8(ascii: "\"") {
                    // See if this "…" starts our target key.
                    if i + targetBytes.count <= bytes.count {
                        var match = true
                        for k in 0..<targetBytes.count {
                            if bytes[i + k] != targetBytes[k] { match = false; break }
                        }
                        if match {
                            // Advance past the key literal, then skip
                            // whitespace and the required `:`.
                            var j = i + targetBytes.count
                            while j < bytes.count && isWs(bytes[j]) { j += 1 }
                            if j < bytes.count && bytes[j] == UInt8(ascii: ":") {
                                j += 1
                                while j < bytes.count && isWs(bytes[j]) { j += 1 }
                                if j < bytes.count && bytes[j] == UInt8(ascii: "\"") {
                                    // Consume the string value up to
                                    // an unescaped closing quote.
                                    j += 1
                                    var valBytes: [UInt8] = []
                                    while j < bytes.count {
                                        let vc = bytes[j]
                                        if vc == UInt8(ascii: "\\") && j + 1 < bytes.count {
                                            let esc = bytes[j + 1]
                                            switch esc {
                                            case UInt8(ascii: "\""): valBytes.append(UInt8(ascii: "\""))
                                            case UInt8(ascii: "\\"): valBytes.append(UInt8(ascii: "\\"))
                                            case UInt8(ascii: "/"):  valBytes.append(UInt8(ascii: "/"))
                                            case UInt8(ascii: "n"):  valBytes.append(0x0A)
                                            case UInt8(ascii: "t"):  valBytes.append(0x09)
                                            case UInt8(ascii: "r"):  valBytes.append(0x0D)
                                            default:                 valBytes.append(esc)
                                            }
                                            j += 2
                                            continue
                                        }
                                        if vc == UInt8(ascii: "\"") { break }
                                        valBytes.append(vc)
                                        j += 1
                                    }
                                    lastMatchedValue = String(decoding: valBytes, as: UTF8.self)
                                    i = j + 1
                                    continue
                                }
                            }
                        }
                    }
                    // Not our key — enter string state to walk past
                    // this unrelated string literal.
                    state = .inString
                    i += 1
                    continue
                }
                i += 1
            case .inString:
                if c == UInt8(ascii: "\\") && i + 1 < bytes.count { i += 2; continue }
                if c == UInt8(ascii: "\"") { state = .normal }
                i += 1
            case .inLineComment:
                if c == 0x0A { state = .normal }
                i += 1
            case .inBlockComment:
                if c == UInt8(ascii: "*") && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "/") {
                    state = .normal
                    i += 2
                } else {
                    i += 1
                }
            }
        }
        return lastMatchedValue
    }

    private static func isWs(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }
}
