import SwiftUI

extension Appearance {
    var iosColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension Accent {
    var iosColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .cyan: .cyan
        case .blue: .blue
        case .pink: .pink
        }
    }
}

struct IOSArtworkView: View {
    let artwork: Artwork
    var cornerRadius: CGFloat = 8
    var highResolution = false

    var body: some View {
        CachedAsyncImage(url: artworkURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    artwork.accent.iosColor.opacity(0.16)
                    Image(systemName: artwork.symbol)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(artwork.accent.iosColor)
                }
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var artworkURL: URL? {
        artwork.remoteURL.map { highResolution ? ArtworkURLPolicy.highResolutionURL(for: $0) : $0 }
    }
}

struct IOSInteractionToast: View {
    let message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().stroke(.primary.opacity(0.1), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: message)
        .allowsHitTesting(false)
    }
}

enum IOSDurationText {
    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
