import Combine
import Foundation

final class AccountsStore: ObservableObject {
    // Adding a slot here also means adding its digit to `badgeGlyphs` in
    // MenuBarIcon.swift. `badgeGlyphs` only defines 1 and 2; a slot missing
    // from it still renders — menuBarIcon(badge:) falls back to the plain,
    // unbadged spark for an unknown digit — so a third account would degrade
    // silently instead of failing loudly.
    static let slots = [1, 2]

    let accounts: [UsageManager]
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        // First statement in the body, before any UsageManager exists: each
        // manager reads its cookie in its own init, so a migration that ran
        // after them would leave an upgrading user looking unconfigured and
        // asking for a cookie they already gave us.
        migrateAccounts(defaults)
        accounts = Self.slots.map { UsageManager(slot: $0, defaults: defaults) }

        // A nested ObservableObject does not notify its parent. Without this
        // republish, pasting a cookie into account 2 would not make its menu
        // bar item or its popover section appear — no error, no log, the UI
        // simply would not update.
        //
        // The same signal also drives the notification prefixes: saving a
        // cookie, clearing one, or renaming an account can all change whether
        // there is something to disambiguate, or what name to use.
        for account in accounts {
            account.objectWillChange
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    // Republish synchronously: SwiftUI expects willChange to
                    // arrive before the render pass, and deferring it can drop
                    // an update.
                    self.objectWillChange.send()
                    // The prefix, on the other hand, depends on the NEW value,
                    // and objectWillChange fires before the property is written.
                    DispatchQueue.main.async { self.refreshNotificationPrefixes() }
                }
                .store(in: &cancellables)
        }
        refreshNotificationPrefixes()
    }

    /// Configured means "has a cookie" — one fact, nothing to desynchronise.
    var configured: [UsageManager] { accounts.filter { $0.hasCookie } }

    var showsBadges: Bool { configured.count > 1 }

    /// Only prefix when there is something to disambiguate.
    private func refreshNotificationPrefixes() {
        let multiple = configured.count > 1
        for account in accounts {
            account.notificationPrefix = multiple ? account.displayName : ""
        }
    }

    func refreshAll() {
        for account in configured { account.fetchUsage() }
    }
}
