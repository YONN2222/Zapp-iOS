import SwiftUI
import SVGView
import UIKit

struct ChannelLogoView: View {
    let channel: Channel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundColor)
                .frame(width: 96, height: 56)

            if let logoURL {
                SVGView(contentsOf: logoURL)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: LogoSizing.maxWidth, height: LogoSizing.maxHeight)
                    .padding(.horizontal, 8)
                    .applyIf(shouldInvertLogoColors) { view in
                        view.colorInvert()
                    }
                    .accessibilityHidden(true)
            } else {
                placeholder
            }
        }
        .accessibilityLabel(channel.name)
    }

    private var logoURL: URL? {
        guard let baseName = channel.logo_name else { return nil }
        if shouldUseDarkVariant, let darkURL = url(forLogoNamed: "\(baseName)_dark") {
            return darkURL
        }
        return url(forLogoNamed: baseName)
    }

    private var shouldUseDarkVariant: Bool {
        colorScheme == .dark && !Self.forceLightLogoChannelIds.contains(channel.id)
    }

    private var shouldInvertLogoColors: Bool {
        colorScheme == .dark && Self.forceInvertLogoChannelIds.contains(channel.id)
    }

    private static let forceLightLogoChannelIds: Set<String> = [
        "kika",
        "parlamentsfernsehen_1",
        "parlamentsfernsehen_2",
    ]

    private static let forceInvertLogoChannelIds: Set<String> = [
        "parlamentsfernsehen_1",
        "parlamentsfernsehen_2",
    ]

    private func url(forLogoNamed name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "ChannelLogos") {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: "svg")
    }

    private var backgroundColor: Color {
        if let hex = channel.color, let base = UIColor(hex: hex) {
            if colorScheme == .dark {
                return Color(uiColor: base.shadedForDarkModeBackground())
            }
            return Color(uiColor: base).opacity(0.08)
        }

        if colorScheme == .dark {
            return Color.black.opacity(0.35)
        }

        return Color.gray.opacity(0.15)
    }

    private var placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "wave.3.forward.circle")
                .font(.title2)
                .foregroundColor(.secondary)
            Text(channel.initials)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

private extension Channel {
    var initials: String {
        name.split(separator: " ")
            .prefix(2)
            .map { String($0.prefix(1)).uppercased() }
            .joined()
    }
}

private enum LogoSizing {
    static let maxWidth: CGFloat = 72
    static let maxHeight: CGFloat = 40
}

private extension View {
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

private extension UIColor {
    convenience init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }

    func shadedForDarkModeBackground() -> UIColor {
        blended(with: .black, fraction: 0.75)
    }

    private func blended(with target: UIColor, fraction: CGFloat) -> UIColor {
        let clamped = max(0, min(1, fraction))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)

        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        target.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)

        let interpolate: (CGFloat, CGFloat) -> CGFloat = { start, end in
            start + (end - start) * clamped
        }

        return UIColor(
            red: interpolate(r, tr),
            green: interpolate(g, tg),
            blue: interpolate(b, tb),
            alpha: a
        )
    }
}

#Preview(traits: .sizeThatFitsLayout) {
    VStack(spacing: 16) {
        ChannelLogoView(channel: Channel(id: "zdf", name: "ZDF", stream_url: nil, logo_name: "channel_logo_zdf", color: "#FA7D19", subtitle: nil))
        ChannelLogoView(channel: Channel(id: "x", name: "Test Channel", stream_url: nil, logo_name: nil, color: nil, subtitle: nil))
    }
    .padding()
}
