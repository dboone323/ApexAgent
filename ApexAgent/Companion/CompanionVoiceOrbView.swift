import SwiftUI

// MARK: - Companion Voice Orb View (iOS Full-Duplex Talk Mode)

public struct CompanionVoiceOrbView: View {
    public let isSpeaking: Bool
    public let decibelLevel: Float
    public let onDismiss: () -> Void

    public init(isSpeaking: Bool = false, decibelLevel: Float = -40.0, onDismiss: @escaping () -> Void = {}) {
        self.isSpeaking = isSpeaking
        self.decibelLevel = decibelLevel
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 28) {
            HStack {
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 20)

            Spacer()

            // Animated Voice Orb
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: isSpeaking ? [Color.blue.opacity(0.8), Color.purple.opacity(0.5), Color.clear] : [Color.teal.opacity(0.7), Color.blue.opacity(0.3), Color.clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 120
                        )
                    )
                    .frame(width: orbScale * 220, height: orbScale * 220)
                    .blur(radius: 12)

                Circle()
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 2)
                    .frame(width: 140, height: 140)

                Image(systemName: isSpeaking ? "waveform" : "mic.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .animation(.easeInOut(duration: 0.25), value: decibelLevel)

            Text(isSpeaking ? "Apex is speaking..." : "Listening (Talk Mode)...")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(.primary)

            Text("Speak naturally. Apex will automatically detect your voice and respond in real-time.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
    }

    private var orbScale: CGFloat {
        let normalized = max(0.0, min(1.0, (Double(decibelLevel) + 60.0) / 60.0))
        return CGFloat(0.8 + normalized * 0.5)
    }
}
