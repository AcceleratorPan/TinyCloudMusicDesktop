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

    var body: some View {
        CachedAsyncImage(url: artwork.remoteURL) { phase in
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
}

enum IOSDurationText {
    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
