//
// CredentialMigration.swift
// Startup adapter for the v1 UserDefaults → v2 Keychain migration.
//

import Foundation

/// Coordinates the one-way credential migration at a process entry point.
///
/// Migration is intentionally safe to call on every launch: Keychain values
/// take precedence, and legacy values are removed only after the destination
/// is confirmed or successfully written.
public enum CredentialMigration {
    public enum Outcome: Sendable, Equatable {
        case notNeeded
        case migrated(count: Int)
    }

    @discardableResult
    public static func runIfNeeded(
        store: KeychainStore = .shared,
        defaults: UserDefaults = .standard,
        logger: ((String) -> Void)? = nil
    ) -> Outcome {
        guard store.hasUserDefaultsCredentials(defaults: defaults) else {
            return .notNeeded
        }

        do {
            let count = try store.migrateFromUserDefaults(defaults: defaults)
            logger?("Credential migration completed: \(count) credential(s) moved to Keychain.")
            return .migrated(count: count)
        } catch {
            // Do not abort startup. The legacy value remains available for a
            // later retry, and the error description contains no secret data.
            logger?("Credential migration deferred: \(error.localizedDescription)")
            return .notNeeded
        }
    }
}
