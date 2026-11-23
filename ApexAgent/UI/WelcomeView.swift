import SwiftUI
import AuthenticationServices

public struct WelcomeView: View {
    public enum OnboardingStep: String, CaseIterable, Identifiable, Sendable {
        case modelSelection
        case workspaceAndAccount

        public var id: String { rawValue }
    }

    @ObservedObject var accountManager: UserAccountManager
    @ObservedObject var workspaceManager = WorkspaceSecurityManager.shared
    var onComplete: () -> Void

    @State private var currentStep: OnboardingStep = .modelSelection
    @State private var selectedProvider: ModelProvider = ModelRegistry.activeProvider()
    @State private var localNameInput: String = ""
    @State private var showWorkspaceSuccess = false

    public init(accountManager: UserAccountManager, onComplete: @escaping () -> Void) {
        self.accountManager = accountManager
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.8), Color.purple.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 8, x: 0, y: 3)

                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.top, 16)

                Text("Welcome to ApexAgent")
                    .font(.system(size: 22, weight: .bold))

                HStack(spacing: 12) {
                    stepIndicator(
                        step: .modelSelection,
                        title: "1. Intelligence Engine",
                        isActive: currentStep == .modelSelection
                    )
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    stepIndicator(
                        step: .workspaceAndAccount,
                        title: "2. Workspace & Profile",
                        isActive: currentStep == .workspaceAndAccount
                    )
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 32)

            Divider()
                .padding(.vertical, 14)

            // MARK: - Step Content
            Group {
                switch currentStep {
                case .modelSelection:
                    modelSelectionStepView
                case .workspaceAndAccount:
                    workspaceAndAccountStepView
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            Divider()
                .padding(.vertical, 12)

            // MARK: - Footer
            HStack {
                if currentStep == .workspaceAndAccount {
                    Button("Back") {
                        currentStep = .modelSelection
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityIdentifier("onboardingBackButton")
                }

                Text(currentStep == .modelSelection
                     ? "Free-tier reality: zero required paid subscriptions or usage-based billing."
                     : "You can change accounts and folder permissions anytime in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                if currentStep == .modelSelection {
                    Button("Continue to Workspace") {
                        currentStep = .workspaceAndAccount
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboardingContinueButton")
                } else {
                    Button("Get Started") {
                        FreeTierModelManager.shared.applyProviderSelection(selectedProvider)
                        if !accountManager.isAuthenticated {
                            accountManager.continueAsLocalProfile()
                        }
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboardingGetStartedButton")
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 20)
        }
        .frame(width: 660, height: 570)
        .background(Color(NSColor.underPageBackgroundColor))
        .accessibilityIdentifier("onboardingWelcomeView")
    }

    // MARK: - Step 1: Model Selection
    private var modelSelectionStepView: some View {
        VStack(alignment: .leading, spacing: 10) {
            OnboardingModelPickerView(
                selectedProvider: $selectedProvider,
                onSelectionConfirmed: { provider in
                    selectedProvider = provider
                    currentStep = .workspaceAndAccount
                }
            )
        }
    }

    // MARK: - Step 2: Workspace & Account
    private var workspaceAndAccountStepView: some View {
        VStack(spacing: 14) {
            // Feature Pillars
            HStack(alignment: .top, spacing: 16) {
                featureCard(
                    icon: "person.3.sequence.fill",
                    color: .blue,
                    title: "Specialist Bots",
                    description: "Coordinated fleet of specialized AI agents for coding, architecture, and research."
                )

                featureCard(
                    icon: "lock.shield.fill",
                    color: .green,
                    title: "Privacy First",
                    description: "Native Apple Foundation Models and local sandboxing with zero data leakage."
                )

                featureCard(
                    icon: "folder.badge.gearshape",
                    color: .orange,
                    title: "Connected Workspace",
                    description: "Persistent security bookmarks remember your project directories without repeat prompts."
                )
            }

            // Summary of Chosen Engine
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(Color.accentColor)
                Text("Selected Engine: **\(selectedProvider.displayName)** (100% Free)")
                    .font(.system(size: 11))
                Spacer()
                Button("Change") {
                    currentStep = .modelSelection
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .cornerRadius(6)

            // Onboarding Action Card
            VStack(spacing: 12) {
                // Workspace Folder Selection
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Working Directory")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(workspaceManager.activeWorkspacePath ?? "No folder selected (optional)")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button(workspaceManager.hasWorkspaceConfigured ? "Change…" : "Choose Folder…") {
                        _ = workspaceManager.promptUserForWorkspace()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)

                // Sign in with Apple or Continue Locally
                if accountManager.isAuthenticated {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Signed in as **\(accountManager.displayName)**")
                            .font(.system(size: 13))
                        if let email = accountManager.email {
                            Text("(\(email))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign Out") {
                            accountManager.signOut()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack(spacing: 12) {
                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.fullName, .email]
                        } onCompletion: { result in
                            accountManager.handleAppleSignIn(result: result)
                        }
                        .signInWithAppleButtonStyle(.whiteOutline)
                        .frame(height: 34)

                        Button("Continue as Local User") {
                            accountManager.continueAsLocalProfile()
                        }
                        .buttonStyle(.bordered)
                        .frame(height: 34)
                    }
                }

                // Cross-Instance Sync Toggle
                Toggle(isOn: $accountManager.syncSettingsAcrossInstances) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync preferences across instances with iCloud")
                            .font(.system(size: 12, weight: .medium))
                        Text("Remembers your model selections, UI layouts, and tool rules.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.top, 2)
            }
            .padding(14)
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func stepIndicator(step: OnboardingStep, title: String, isActive: Bool) -> some View {
        Button {
            currentStep = step
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func featureCard(icon: String, color: Color, title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)

            Text(title)
                .font(.system(size: 12, weight: .semibold))

            Text(description)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .cornerRadius(8)
    }
}
