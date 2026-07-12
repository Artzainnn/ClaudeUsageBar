// PR 10a — TCCState + LocalProviderAccessGuide (shared local-provider
// infrastructure).
//
// Local-file providers need to distinguish three failure modes so the
// popover can render the right onboarding UI:
//
//   1. `.granted` — the process can read the target directory. Normal
//      operation; render the usage tile.
//   2. `.denied` — the process cannot read the target directory. Could
//      be a TCC denial ("Full Disk Access" not granted), classic UNIX
//      permission denial, or an ambiguous error. macOS's TCC API does
//      not expose "was I denied vs never asked" — Codex round-1 finding
//      #6. Rather than expose a `.needsRequest` state that is
//      indistinguishable from `.denied` in every empirical test, we
//      collapse both into `.denied` and let the tile copy point the
//      user at System Settings regardless.
//   3. `.pathMissing` — the target directory does not exist AND the
//      process can prove it does not exist. Local providers surface
//      this as a "not installed / never launched" state.
//
// Codex round-1 finding #5: `fileExists() == false` alone is not a
// reliable "pathMissing" signal — a TCC-denied containing directory
// causes stat to return false, and we'd send the user to a "not
// installed" tile when the real problem is access. `probe()` cross-
// checks the containing directory's readability before returning
// pathMissing; if the containing directory itself is unreadable, we
// surface `.denied` and let the user grant access first.

import Foundation

/// Outcome of a probe against a local-provider directory. Every local
/// provider maps its target path through `TCCProbe.probe(path:)` on the
/// first fetch and each time the flag toggles back on, then renders the
/// resulting state as its tile.
public enum TCCState: Equatable, Sendable {
    /// Access confirmed — the store can read the target files.
    case granted
    /// The store cannot read the target files. Covers both TCC denial
    /// and classic UNIX permission denial; we cannot reliably distinguish
    /// them on macOS, so the tile treats them the same way (both send
    /// the user to System Settings → Privacy & Security → Full Disk
    /// Access).
    case denied
    /// The target path does not exist AND we can prove that from the
    /// containing directory (which we CAN read). Distinct from `.denied`
    /// so the user isn't sent to Settings for the wrong reason.
    case pathMissing
}

/// Probe a local path and classify the outcome. Static, no state — the
/// caller caches the result if it wants to avoid repeated probes.
public enum TCCProbe {
    /// Probe a single directory or file path.
    ///
    /// The macOS TCC API is deliberately opaque:
    ///   - `fileExists` returns true even when we can't read the file.
    ///   - `isReadableFile` returns false for both "denied" and "missing".
    ///   - The only reliable way to distinguish "denied" from "missing"
    ///     is to test the CONTAINING directory: if we can read the
    ///     parent and the target isn't there, it's missing; if we can't
    ///     read the parent, the target might exist but we can't tell.
    public static func probe(path: String) -> TCCState {
        let fm = FileManager.default

        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)

        if !exists {
            // Codex round-1 finding #5: cross-check the containing
            // directory. If we cannot read it, "not found" might be a
            // TCC lie — surface `.denied` and let the user grant access,
            // rather than steering them to a "not installed" tile.
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty && parent != path {
                do {
                    _ = try fm.contentsOfDirectory(atPath: parent)
                    // Parent readable AND target absent → really missing.
                    return .pathMissing
                } catch {
                    // Parent unreadable → we can't distinguish. Assume
                    // denial (the safer of the two — sends the user to
                    // Settings, and a genuine missing case will surface
                    // as .pathMissing on the next probe once access is
                    // granted).
                    return classify(error: error)
                }
            }
            // No parent (e.g. path == "/"). Surface missing.
            return .pathMissing
        }

        // Path exists. Attempt to read.
        if isDir.boolValue {
            do {
                _ = try fm.contentsOfDirectory(atPath: path)
                return .granted
            } catch {
                return classify(error: error)
            }
        } else {
            if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.close()
                return .granted
            }
            do {
                _ = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
                return .granted
            } catch {
                return classify(error: error)
            }
        }
    }

    /// Map a foundation error into a TCC classification. Every error we
    /// don't recognise defaults to `.denied` on the "safer to prompt for
    /// Settings than to silently fail" theory — a false `.denied` tile
    /// is annoying, a false `.granted` tile makes the provider useless.
    private static func classify(error: Error) -> TCCState {
        let ns = error as NSError
        // NSFileReadNoPermissionError = TCC denial or classic UNIX perms.
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError {
            return .denied
        }
        // Various Cocoa read errors we should treat as denial rather than
        // silently ignoring.
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadUnknownError,
                 NSFileReadInapplicableStringEncodingError,
                 NSFileReadCorruptFileError,
                 NSFileReadInvalidFileNameError:
                return .denied
            case NSFileReadNoSuchFileError:
                return .pathMissing
            default:
                break
            }
        }
        // POSIX EACCES / EPERM through the Foundation bridge.
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case Int(EACCES), Int(EPERM):
                return .denied
            case Int(ENOENT):
                return .pathMissing
            default:
                break
            }
        }
        return .denied
    }
}

/// Localised guidance strings for the `.needsAccess` tile when a local
/// provider requests Full Disk Access. Held in the library (not the app
/// view file) so the strings are unit-testable — user-facing copy must
/// not silently change.
public enum LocalProviderAccessGuide {

    /// Guidance for the `.needsAccess` tile keyed by the current TCC
    /// state. Return value is the (title, guidance) pair the tile renders.
    public static func copy(for state: TCCState, appName: String) -> (title: String, guidance: String) {
        switch state {
        case .granted:
            // Should not be shown — callers guard with `if state != .granted`.
            return (appName, "Access granted.")
        case .denied:
            return (
                "\(appName) — needs Full Disk Access",
                "\(appName) tracking reads a file managed by another app on your Mac. Grant ClaudeUsageBar Full Disk Access in System Settings → Privacy & Security → Full Disk Access. If you previously denied access, macOS will not prompt again — you must enable it manually here."
            )
        case .pathMissing:
            return (
                "\(appName) — not installed",
                "No data found for \(appName) on this Mac. If you use \(appName), launch it once and then click Refresh."
            )
        }
    }

    /// Deep-link URL for System Settings → Privacy → Full Disk Access.
    /// The pane identifier `Privacy_AllFiles` is stable across Ventura /
    /// Sonoma / Sequoia. Callers open this via NSWorkspace when the user
    /// clicks the tile's "Open Settings" button (added in PR 10b onward).
    public static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
}
