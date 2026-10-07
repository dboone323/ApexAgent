import SwiftUI

// MARK: - VoiceOrbHUDView

public struct VoiceOrbHUDView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject var voiceSession: FullDuplexVoiceSession
    private let reduceMotionOverride: Bool?
    @State private var wavePhase: Double = 0.0

    public init(voiceSession: FullDuplexVoiceSession = .shared, reduceMotion: Bool? = nil) {
        self.voiceSession = voiceSession
        self.reduceMotionOverride = reduceMotion
    }

    public var effectiveReduceMotion: Bool {
        reduceMotionOverride ?? accessibilityReduceMotion
    }

    public static func orbScale(isSessionActive: Bool, normalizedPower: Float, reduceMotion: Bool) -> CGFloat {
        guard isSessionActive, !reduceMotion else { return 1.0 }
        return 1.0 + CGFloat(normalizedPower) * 0.4
    }

    public var orbAccessibilityLabel: String {
        "Voice status: \(statusTitle)"
    }

    public var toggleButtonAccessibilityLabel: String {
        voiceSession.isSessionActive ? "Stop full-duplex voice session" : "Start full-duplex voice session"
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Animated Voice Orb Indicator
            ZStack {
                Circle()
                    .fill(orbColor.opacity(0.2))
                    .frame(width: 32, height: 32)
                    .scaleEffect(
                        Self.orbScale(
                            isSessionActive: voiceSession.isSessionActive,
                            normalizedPower: normalizedPower,
                            reduceMotion: effectiveReduceMotion
                        )
                    )
                    .animation(
                        effectiveReduceMotion ? nil : .easeInOut(duration: 0.15),
                        value: voiceSession.currentDecibels
                    )

                Circle()
                    .fill(orbColor)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                    )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("voiceOrbIndicator")
            .accessibilityLabel(orbAccessibilityLabel)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                if !voiceSession.liveTranscript.isEmpty {
                    Text(voiceSession.liveTranscript)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(statusSubtitle)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Session Toggle Button
            Button(action: {
                if voiceSession.isSessionActive {
                    voiceSession.stopSession()
                } else {
                    voiceSession.startSession()
                }
            }) {
                Image(systemName: voiceSession.isSessionActive ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(voiceSession.isSessionActive ? Color.white : Color.primary)
                    .padding(7)
                    .background(voiceSession.isSessionActive ? Color.accentColor : Color.secondary.opacity(0.2))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voiceOrbToggleButton")
            .accessibilityLabel(toggleButtonAccessibilityLabel)
            .accessibilityHint("Toggles continuous full-duplex voice conversation")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .accessibilityIdentifier("voiceOrbHUD")
    }

    private var normalizedPower: Float {
        let minDb: Float = -80.0
        let maxDb: Float = 0.0
        let clamped = max(minDb, min(maxDb, voiceSession.currentDecibels))
        return (clamped - minDb) / (maxDb - minDb)
    }

    private var orbColor: Color {
        switch voiceSession.state {
        case .idle:
            return .gray
        case .userSpeaking:
            return .green
        case .modelThinking:
            return .orange
        case .modelSpeaking:
            return .blue
        case .userBargedIn:
            return .purple
        }
    }

    private var statusTitle: String {
        switch voiceSession.state {
        case .idle:
            return voiceSession.isSessionActive ? "Listening (Standby)" : "Voice Inactive"
        case .userSpeaking:
            return "Speaking..."
        case .modelThinking:
            return "Processing..."
        case .modelSpeaking:
            return "Responding..."
        case .userBargedIn:
            return "Interrupted (Listening)"
        }
    }

    private var statusSubtitle: String {
        voiceSession.isSessionActive ? "Full-duplex conversation active" : "Click mic to enable continuous voice"
    }
}
