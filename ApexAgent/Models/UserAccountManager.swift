import Foundation
import SwiftUI
import AuthenticationServices

public enum UserAccountType: String, Codable, Sendable {
    case apple = "apple"
    case localGuest = "localGuest"
}

@MainActor
public final class UserAccountManager: ObservableObject {
    public static let shared = UserAccountManager()

    public static let accountTypeKey = "apex.accountType"
    public static let displayNameKey = "apex.userDisplayName"
    public static let userEmailKey = "apex.userEmail"
    public static let appleUserIdKey = "apex.appleUserId"
    public static let syncSettingsKey = "apex.syncSettingsAcrossInstances"
    public static let onboardingCompletedKey = "apex.hasCompletedOnboarding"

    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var accountType: UserAccountType = .localGuest
    @Published public private(set) var appleUserId: String?
    @Published public private(set) var displayName: String = "Local User"
    @Published public private(set) var email: String?
    @Published public var syncSettingsAcrossInstances: Bool {
        didSet {
            UserDefaults.standard.set(syncSettingsAcrossInstances, forKey: Self.syncSettingsKey)
            if syncSettingsAcrossInstances {
                syncSettings()
            }
        }
    }

    private init() {
        self.syncSettingsAcrossInstances = UserDefaults.standard.bool(forKey: Self.syncSettingsKey)
        loadSavedAccount()
    }

    private func loadSavedAccount() {
        let hasCompleted = UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
        if let savedTypeRaw = UserDefaults.standard.string(forKey: Self.accountTypeKey),
           let savedType = UserAccountType(rawValue: savedTypeRaw) {
            self.accountType = savedType
            self.displayName = UserDefaults.standard.string(forKey: Self.displayNameKey) ?? "User"
            self.email = UserDefaults.standard.string(forKey: Self.userEmailKey)
            self.appleUserId = KeychainManager.get(key: Self.appleUserIdKey)
            self.isAuthenticated = hasCompleted
        } else if hasCompleted {
            self.isAuthenticated = true
            self.accountType = .localGuest
            self.displayName = UserDefaults.standard.string(forKey: Self.displayNameKey) ?? "Local User"
        }
    }

    public func handleAppleSignIn(result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                return
            }

            let userId = appleIDCredential.user
            self.appleUserId = userId
            self.accountType = .apple
            self.isAuthenticated = true

            if let fullName = appleIDCredential.fullName {
                let formatted = [fullName.givenName, fullName.familyName]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !formatted.isEmpty {
                    self.displayName = formatted
                }
            } else if self.displayName.isEmpty || self.displayName == "Local User" {
                self.displayName = "Apple ID User"
            }

            if let email = appleIDCredential.email, !email.isEmpty {
                self.email = email
            }

            _ = KeychainManager.save(key: Self.appleUserIdKey, value: userId)
            saveAccountMetadata()
            UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)

            if syncSettingsAcrossInstances {
                syncSettings()
            }
            AppLog.info(.security, "Sign in with Apple completed successfully for \(displayName)")

        case .failure(let error):
            AppLog.notice(.security, "Sign in with Apple cancelled or failed: \(error.localizedDescription)")
        }
    }

    public func continueAsLocalProfile(name: String = "Local User") {
        self.accountType = .localGuest
        self.displayName = name.isEmpty ? "Local User" : name
        self.isAuthenticated = true
        saveAccountMetadata()
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        AppLog.info(.security, "Proceeding with local guest profile: \(displayName)")
    }

    private func saveAccountMetadata() {
        UserDefaults.standard.set(accountType.rawValue, forKey: Self.accountTypeKey)
        UserDefaults.standard.set(displayName, forKey: Self.displayNameKey)
        if let email {
            UserDefaults.standard.set(email, forKey: Self.userEmailKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.userEmailKey)
        }
    }

    public func signOut() {
        self.isAuthenticated = false
        self.appleUserId = nil
        self.email = nil
        self.displayName = "Local User"
        self.accountType = .localGuest
        _ = KeychainManager.delete(key: Self.appleUserIdKey)
        UserDefaults.standard.removeObject(forKey: Self.accountTypeKey)
        UserDefaults.standard.removeObject(forKey: Self.displayNameKey)
        UserDefaults.standard.removeObject(forKey: Self.userEmailKey)
        UserDefaults.standard.set(false, forKey: Self.onboardingCompletedKey)
    }

    /// Synchronize settings across instances using NSUbiquitousKeyValueStore (iCloud)
    public func syncSettings() {
        guard syncSettingsAcrossInstances else { return }
        let store = NSUbiquitousKeyValueStore.default
        let defaults = UserDefaults.standard

        let keysToSync = [
            "apex.userDisplayName",
            "apex.showActivityLog",
            "apex.showTerminal",
            "apex.showPlanDashboard",
            "apex.collaborativeServerPort"
        ]

        for key in keysToSync {
            if let val = defaults.object(forKey: key) {
                store.set(val, forKey: key)
            }
        }
        store.synchronize()
    }

    /// Import synced settings from iCloud into local UserDefaults
    public func pullSyncedSettings() {
        guard syncSettingsAcrossInstances else { return }
        let store = NSUbiquitousKeyValueStore.default
        let defaults = UserDefaults.standard

        let keysToSync = [
            "apex.userDisplayName",
            "apex.showActivityLog",
            "apex.showTerminal",
            "apex.showPlanDashboard",
            "apex.collaborativeServerPort"
        ]

        for key in keysToSync {
            if let val = store.object(forKey: key) {
                defaults.set(val, forKey: key)
            }
        }
    }
}
