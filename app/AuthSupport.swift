import Foundation
import AppKit
import WebKit
import Security

enum ISO8601Parser {
    static func parse(_ string: String?) -> Date? {
        guard let string = string, !string.isEmpty else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let basicFormatter = ISO8601DateFormatter()
        basicFormatter.formatOptions = [.withInternetDateTime]
        return basicFormatter.date(from: string)
    }
}

enum CookieNormalizer {
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefixRange = value.range(of: "Cookie:", options: [.anchored, .caseInsensitive]) {
            value = String(value[prefixRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty else {
            return ""
        }
        if !value.contains("=") {
            return "sessionKey=\(value)"
        }
        return value
    }

    static func extractOrgId(from cookie: String) -> String? {
        for component in cookie.components(separatedBy: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("lastActiveOrg=") {
                let orgId = String(trimmed.dropFirst("lastActiveOrg=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !orgId.isEmpty {
                    return orgId
                }
            }
        }
        return nil
    }
}

struct ClaudeCodeCredentials {
    let accessToken: String
    let expiresAt: Date?
    let scopes: [String]
    let subscriptionType: String?

    var isExpired: Bool {
        guard let expiresAt = expiresAt else {
            return false
        }
        return expiresAt <= Date().addingTimeInterval(30)
    }
}

enum ClaudeCodeReadResult {
    case found(ClaudeCodeCredentials)
    case notFound
    case accessDenied
    case invalidData
}

enum KeychainStore {
    private static let webCookieService = "com.claude.usagebar"
    private static let webCookieAccount = "claude_web_cookie"
    private static let legacyCookieDefaultsKey = "claude_session_cookie"
    private static let claudeCodeService = "Claude Code-credentials"

    @discardableResult
    static func saveWebCookie(_ cookie: String) -> Bool {
        guard let data = cookie.data(using: .utf8) else {
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webCookieService,
            kSecAttrAccount as String: webCookieAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func loadWebCookie() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webCookieService,
            kSecAttrAccount as String: webCookieAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let cookie = String(data: data, encoding: .utf8),
              !cookie.isEmpty else {
            return nil
        }
        return cookie
    }

    @discardableResult
    static func deleteWebCookie() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webCookieService,
            kSecAttrAccount as String: webCookieAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    static func migrateLegacyCookieIfNeeded() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: legacyCookieDefaultsKey) else {
            return nil
        }
        let normalized = CookieNormalizer.normalize(raw)
        if !normalized.isEmpty {
            _ = saveWebCookie(normalized)
        }
        UserDefaults.standard.removeObject(forKey: legacyCookieDefaultsKey)
        return normalized.isEmpty ? nil : normalized
    }

    static func hasClaudeCodeCredentials() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess
    }

    static func readClaudeCodeCredentials() -> ClaudeCodeReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return .invalidData
            }
            return parseClaudeCodeCredentials(from: data)
        case errSecItemNotFound:
            return .notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .accessDenied
        default:
            return .accessDenied
        }
    }

    private static func parseClaudeCodeCredentials(from data: Data) -> ClaudeCodeReadResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty else {
            return .invalidData
        }

        let expiresAt: Date?
        if let number = oauth["expiresAt"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            expiresAt = Date(timeIntervalSince1970: number.doubleValue / 1000.0)
        } else if let isoString = oauth["expiresAt"] as? String {
            expiresAt = ISO8601Parser.parse(isoString)
        } else {
            expiresAt = nil
        }

        let scopes = oauth["scopes"] as? [String] ?? []
        let subscriptionType = oauth["subscriptionType"] as? String

        let credentials = ClaudeCodeCredentials(
            accessToken: accessToken,
            expiresAt: expiresAt,
            scopes: scopes,
            subscriptionType: subscriptionType
        )
        return .found(credentials)
    }
}

final class WebSignInWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let shared = WebSignInWindowController()

    private static let loginURL = URL(string: "https://claude.ai/login")!
    private static let bootstrapURL = URL(string: "https://claude.ai/api/bootstrap")!

    private var window: NSWindow?
    private var webView: WKWebView?
    private var pollTimer: Timer?
    private var verificationTask: URLSessionDataTask?
    private var onSuccess: ((String, String) -> Void)?
    private var onCancel: (() -> Void)?
    private var isVerifyingBootstrap = false
    private var hasCompleted = false
    private var lastFailedSessionKey: String?
    private var lastFailedCheckDate: Date?

    private lazy var verificationSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private override init() {
        super.init()
    }

    func presentSignIn(
        onSuccess: @escaping (_ cookieString: String, _ orgId: String) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        if Thread.isMainThread {
            presentOnMainThread(onSuccess: onSuccess, onCancel: onCancel)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.presentOnMainThread(onSuccess: onSuccess, onCancel: onCancel)
            }
        }
    }

    func close() {
        if Thread.isMainThread {
            window?.close()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.window?.close()
            }
        }
    }

    static func clearWebSessionCookies(completion: @escaping () -> Void) {
        let performClear = {
            let store = WKWebsiteDataStore.default().httpCookieStore
            store.getAllCookies { cookies in
                let matching = cookies.filter { isClaudeCookieDomain($0.domain) }
                guard !matching.isEmpty else {
                    DispatchQueue.main.async {
                        completion()
                    }
                    return
                }

                let group = DispatchGroup()
                for cookie in matching {
                    group.enter()
                    store.delete(cookie) {
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    completion()
                }
            }
        }

        if Thread.isMainThread {
            performClear()
        } else {
            DispatchQueue.main.async(execute: performClear)
        }
    }

    private func presentOnMainThread(
        onSuccess: @escaping (String, String) -> Void,
        onCancel: (() -> Void)?
    ) {
        if let existingWindow = window {
            self.onSuccess = onSuccess
            self.onCancel = onCancel
            NSApp.activate(ignoringOtherApps: true)
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        self.onSuccess = onSuccess
        self.onCancel = onCancel
        self.hasCompleted = false
        self.isVerifyingBootstrap = false
        self.lastFailedSessionKey = nil
        self.lastFailedCheckDate = nil

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Claude"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 520)
        window.center()
        window.delegate = self

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 680))

        let bannerView = NSView()
        bannerView.translatesAutoresizingMaskIntoConstraints = false

        let infoLabel = NSTextField(
            labelWithString: "Sign in to your Claude account. This window closes automatically once connected."
        )
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byWordWrapping
        infoLabel.maximumNumberOfLines = 2
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        bannerView.addSubview(infoLabel)
        bannerView.addSubview(cancelButton)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(bannerView)
        containerView.addSubview(separator)
        containerView.addSubview(webView)

        NSLayoutConstraint.activate([
            bannerView.topAnchor.constraint(equalTo: containerView.topAnchor),
            bannerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            bannerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),

            infoLabel.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor, constant: 14),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -12),
            infoLabel.topAnchor.constraint(greaterThanOrEqualTo: bannerView.topAnchor, constant: 10),
            infoLabel.bottomAnchor.constraint(lessThanOrEqualTo: bannerView.bottomAnchor, constant: -10),
            infoLabel.centerYAnchor.constraint(equalTo: bannerView.centerYAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: bannerView.trailingAnchor, constant: -14),
            cancelButton.topAnchor.constraint(greaterThanOrEqualTo: bannerView.topAnchor, constant: 8),
            cancelButton.bottomAnchor.constraint(lessThanOrEqualTo: bannerView.bottomAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: bannerView.centerYAnchor),

            separator.topAnchor.constraint(equalTo: bannerView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            webView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        window.contentView = containerView
        self.window = window
        self.webView = webView

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkSessionCookies(forceRetry: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.pollTimer = timer

        webView.load(URLRequest(url: Self.loginURL))

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func cancelTapped() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        let cancelCallback = hasCompleted ? nil : onCancel
        cleanupResources()
        window = nil
        cancelCallback?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkSessionCookies(forceRetry: true)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func checkSessionCookies(forceRetry: Bool) {
        guard !hasCompleted, window != nil, !isVerifyingBootstrap else {
            return
        }

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            let work = {
                guard let self = self,
                      !self.hasCompleted,
                      self.window != nil,
                      !self.isVerifyingBootstrap else {
                    return
                }

                let claudeCookies = cookies.filter {
                    Self.isClaudeCookieDomain($0.domain) && !$0.value.isEmpty
                }
                guard let sessionCookie = claudeCookies.first(where: { $0.name == "sessionKey" }),
                      !sessionCookie.value.isEmpty else {
                    return
                }

                if !forceRetry,
                   self.lastFailedSessionKey == sessionCookie.value,
                   let failedAt = self.lastFailedCheckDate,
                   Date().timeIntervalSince(failedAt) < 5.0 {
                    return
                }

                let cookieString = Self.serializeCookies(claudeCookies)
                self.verifyBootstrap(cookieString: cookieString, sessionKey: sessionCookie.value)
            }

            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async(execute: work)
            }
        }
    }

    private func verifyBootstrap(cookieString: String, sessionKey: String) {
        isVerifyingBootstrap = true

        var request = URLRequest(url: Self.bootstrapURL)
        request.httpMethod = "GET"
        request.setValue(cookieString, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let task = verificationSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isVerifyingBootstrap = false
                self.verificationTask = nil

                guard !self.hasCompleted, self.window != nil else {
                    return
                }

                guard error == nil,
                      let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let account = json["account"] as? [String: Any],
                      let orgId = account["lastActiveOrgId"] as? String,
                      !orgId.isEmpty else {
                    self.lastFailedSessionKey = sessionKey
                    self.lastFailedCheckDate = Date()
                    return
                }

                self.completeSuccess(cookieString: cookieString, orgId: orgId)
            }
        }
        verificationTask = task
        task.resume()
    }

    private func completeSuccess(cookieString: String, orgId: String) {
        guard !hasCompleted else {
            return
        }
        hasCompleted = true

        let successCallback = onSuccess
        let activeWindow = window

        cleanupResources()
        window = nil
        activeWindow?.close()

        successCallback?(cookieString, orgId)
    }

    private func cleanupResources() {
        pollTimer?.invalidate()
        pollTimer = nil

        verificationTask?.cancel()
        verificationTask = nil
        isVerifyingBootstrap = false

        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil

        window?.delegate = nil
        onSuccess = nil
        onCancel = nil
    }

    private static func isClaudeCookieDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "claude.ai" || normalized.hasSuffix(".claude.ai")
    }

    private static func serializeCookies(_ cookies: [HTTPCookie]) -> String {
        let sorted = cookies.sorted { lhs, rhs in
            let lhsRoot = lhs.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "claude.ai"
            let rhsRoot = rhs.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "claude.ai"
            if lhsRoot != rhsRoot {
                return lhsRoot
            }
            return lhs.name < rhs.name
        }

        var seen = Set<String>()
        var pairs: [String] = []
        for cookie in sorted where !seen.contains(cookie.name) {
            seen.insert(cookie.name)
            pairs.append("\(cookie.name)=\(cookie.value)")
        }
        return pairs.joined(separator: "; ")
    }
}
