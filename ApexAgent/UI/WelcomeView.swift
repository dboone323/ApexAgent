import SwiftUI
import AuthenticationServices

public struct WelcomeView: View {
    @ObservedObject var accountManager: UserAccountManager
    @ObservedObject var workspaceManager = WorkspaceSecurityManager.shared
    var onComplete: () -> Void

    @State private var localNameInput: String = ""
    @State private var showWorkspaceSuccess = false

    public init(accountManager: UserAccountManager, onComplete: @escaping () -> Void) {
        self.accountManager = accountManager
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.8), Color.purple.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 10, x: 0, y: 4)

                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.top, 24)

                Text("Welcome to ApexAgent")
                    .font(.system(size: 24, weight: .bold))

                Text("Autonomous multi-agent orchestration, native on-device intelligence, and persistent sandboxed execution.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .padding(.horizontal, 32)

            Divider()
                .padding(.vertical, 20)

            // MARK: - Feature Pillars
            HStack(alignment: .top, spacing: 20) {
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
            .padding(.horizontal, 32)

            Spacer()

            // MARK: - Onboarding Action Card
            VStack(spacing: 16) {
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
                .padding(.top, 4)
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal, 32)

            Spacer()

            // MARK: - Footer / Get Started
            HStack {
                Text("You can change accounts and folder permissions anytime in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Get Started") {
                    if !accountManager.isAuthenticated {
                        accountManager.continueAsLocalProfile()
                    }
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 640, height: 530)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    @ViewBuilder
    private func featureCard(icon: String, color: Color, title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .cornerRadius(10)
    }
}
