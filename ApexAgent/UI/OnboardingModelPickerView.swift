import SwiftUI
import AppKit

// MARK: - Onboarding Model Picker View (Issue #118, J5)

/// A first-run onboarding model picker that explains cost, privacy, and speed per provider
/// in plain language, with graceful degradation when a free tier is withdrawn (the Gemini CLI lesson).
///
/// Guaranteed invariants:
/// - Never pushes a paid model.
/// - Never offers usage-based billing or "Add Credits".
/// - Never presents a withdrawn free tier as available.
public struct OnboardingModelPickerView: View {
    @Binding public var selectedProvider: ModelProvider
    public var onSelectionConfirmed: ((ModelProvider) -> Void)?

    @State private var hoveredProvider: ModelProvider?

    private var options: [FreeTierModelOption] {
        FreeTierModelManager.shared.allOptions()
    }

    private var withdrawnProviders: [(option: FreeTierModelOption, reason: String)] {
        options.compactMap { opt in
            if case .withdrawn(let reason) = FreeTierModelManager.shared.status(for: opt.provider) {
                return (opt, reason)
            }
            return nil
        }
    }

    public init(
        selectedProvider: Binding<ModelProvider>,
        onSelectionConfirmed: ((ModelProvider) -> Void)? = nil
    ) {
        self._selectedProvider = selectedProvider
        self.onSelectionConfirmed = onSelectionConfirmed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "cpu")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                    Text("Choose Your Intelligence Engine")
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Text("100% Free / On-Device")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(Color.green)
                        .clipShape(Capsule())
                }

                Text("ApexAgent is built for free-tier reality: zero usage-based billing, no required paid subscriptions, and honest graceful degradation when cloud quotas change.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Withdrawn Free Tier Alert Banner (The Gemini CLI Lesson)
            if !withdrawnProviders.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                            .font(.system(size: 12))
                        Text("Free-Tier Availability Notice")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.orange)
                    }

                    ForEach(withdrawnProviders, id: \.option.provider) { item in
                        Text("• **\(item.option.displayName)**: \(item.reason) ApexAgent will not prompt for credit cards or credits — local models remain 100% free.")
                            .font(.system(size: 10))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(AppTheme.CornerRadius.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.CornerRadius.sm)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
                .accessibilityIdentifier("degradationNoticeBanner")
            }

            // Model Cards
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 8) {
                    ForEach(options) { option in
                        providerCard(option: option)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)

            // Reassurance Footer
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Color.green)
                    .font(.system(size: 13))

                Text("No paid models or usage billing. You can switch engines anytime in Settings.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                if let onSelectionConfirmed {
                    Button("Select & Continue") {
                        onSelectionConfirmed(selectedProvider)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("confirmModelSelectionButton")
                }
            }
            .padding(.top, 4)
        }
        .accessibilityIdentifier("onboardingModelPicker")
    }

    @ViewBuilder
    private func providerCard(option: FreeTierModelOption) -> some View {
        let isWithdrawn = FreeTierModelManager.shared.isWithdrawn(provider: option.provider)
        let isSelected = (selectedProvider == option.provider) && !isWithdrawn

        Button {
            guard !isWithdrawn else { return }
            selectedProvider = option.provider
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Card Header
                HStack(spacing: 8) {
                    Image(systemName: option.iconName)
                        .font(.system(size: 14))
                        .foregroundStyle(isWithdrawn ? Color.secondary : (isSelected ? Color.accentColor : Color.primary))
                        .frame(width: 18)

                    Text(option.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isWithdrawn ? Color.secondary : Color.primary)

                    if option.isDefault {
                        Text("Default")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15))
                            .foregroundStyle(Color.blue)
                            .cornerRadius(4)
                    }

                    Spacer()

                    if isWithdrawn {
                        Text("Withdrawn")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(Color.red)
                            .cornerRadius(4)
                            .accessibilityIdentifier("providerStatus_\(option.provider.rawValue)")
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.system(size: 14))
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .font(.system(size: 14))
                    }
                }

                // If Withdrawn, display explanation plainly
                if isWithdrawn, let reason = FreeTierModelManager.shared.withdrawalReason(provider: option.provider) {
                    Text("Unavailable: \(reason)")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.red.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 3 Plain-Language Fact Lines: Cost, Privacy, Speed
                VStack(alignment: .leading, spacing: 3) {
                    factRow(
                        icon: "dollarsign.circle",
                        label: "Cost",
                        detail: option.costFact,
                        identifier: "costFact_\(option.provider.rawValue)",
                        dimmed: isWithdrawn
                    )
                    factRow(
                        icon: "hand.raised.fill",
                        label: "Privacy",
                        detail: option.privacyFact,
                        identifier: "privacyFact_\(option.provider.rawValue)",
                        dimmed: isWithdrawn
                    )
                    factRow(
                        icon: "bolt.fill",
                        label: "Speed",
                        detail: option.speedFact,
                        identifier: "speedFact_\(option.provider.rawValue)",
                        dimmed: isWithdrawn
                    )
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor).opacity(0.4)
            )
            .cornerRadius(AppTheme.CornerRadius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.CornerRadius.sm)
                    .stroke(
                        isSelected ? Color.accentColor : (isWithdrawn ? Color.red.opacity(0.2) : Color.secondary.opacity(0.2)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isWithdrawn)
        .opacity(isWithdrawn ? 0.65 : 1.0)
        .accessibilityIdentifier("providerCard_\(option.provider.rawValue)")
    }

    @ViewBuilder
    private func factRow(
        icon: String,
        label: String,
        detail: String,
        identifier: String,
        dimmed: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(dimmed ? Color.secondary : Color.secondary)
                .frame(width: 12)
                .padding(.top, 1)

            Text("\(label):")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(dimmed ? Color.secondary : Color.primary.opacity(0.9))

            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(identifier)
    }
}
