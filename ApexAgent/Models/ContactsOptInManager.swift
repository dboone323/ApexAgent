import Foundation
import Contacts

/// Manages explicit user opt-in and authorization for Contacts integration.
/// Under `APEX_TEST_MODE == "1"`, contacts access is safely disabled by default
/// to prevent `com.apple.contactsd.persistence` XPC store crashes in headless test runners.
public final class ContactsOptInManager: @unchecked Sendable {
    public static let shared = ContactsOptInManager()

    public static let contactsConnectedKey = "apex.contactsConnected"

    private let lock = NSLock()
    private var cachedOptIn: Bool?

    public init() {
        configureTestIsolationIfNeeded()
    }

    /// Configures in-memory test environment isolation for Contacts/AddressBook in test mode.
    /// This prevents background AddressBook / `contactsd.persistence` connection attempts
    /// and `CNAccountCollectionUpdateWatcher` failures under test runners.
    public func configureTestIsolationIfNeeded() {
        guard isTestMode else { return }
        if let envClass = NSClassFromString("CNContactsEnvironment") as? NSObject.Type {
            let unitEnv = envClass.perform(NSSelectorFromString("unitTestingEnvironment")).takeUnretainedValue()
            _ = unitEnv.perform(NSSelectorFromString("useInMemoryStores"))
            _ = unitEnv.perform(NSSelectorFromString("makeCurrentEnvironment"))
        }
    }

    /// Safely resolves the user full name without querying the Contacts Me-Card or AddressBook preferences in test mode.
    public var safeFullUserName: String {
        if isTestMode || !isOptedIn {
            let user = NSUserName()
            return user.isEmpty ? "User" : user
        }
        let full = NSFullUserName()
        return full.isEmpty ? (NSUserName().isEmpty ? "User" : NSUserName()) : full
    }

    /// Whether the user has explicitly opted into Contacts access.
    public var isOptedIn: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }

            if let cached = cachedOptIn {
                return cached
            }

            // In test mode, always default to false unless explicitly overridden in memory
            if isTestMode {
                return false
            }

            let value = UserDefaults.standard.bool(forKey: Self.contactsConnectedKey)
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            cachedOptIn = newValue
            if !isTestMode {
                UserDefaults.standard.set(newValue, forKey: Self.contactsConnectedKey)
            }
        }
    }

    /// Whether the current process is running in test mode.
    public var isTestMode: Bool {
        ProcessInfo.processInfo.environment["APEX_TEST_MODE"] == "1"
            || ProcessInfo.processInfo.arguments.contains { $0.contains("test") || $0.contains("xctest") }
            || NSClassFromString("XCTest") != nil
    }

    /// Resets memory cache (primarily for unit test isolation).
    public func resetForTesting(optedIn: Bool? = nil) {
        lock.lock()
        defer { lock.unlock() }
        cachedOptIn = optedIn
        configureTestIsolationIfNeeded()
    }

    /// Requests user authorization if opted in; returns false immediately if not opted in or in test mode.
    public func requestAccessIfNeeded() async -> Bool {
        guard isOptedIn else {
            return false
        }

        if isTestMode {
            return false
        }

        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            let store = CNContactStore()
            do {
                return try await store.requestAccess(for: .contacts)
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }
}
