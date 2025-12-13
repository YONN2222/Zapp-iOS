import SwiftUI
import UIKit

struct LaunchAnimationView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: AppSettings
    @State private var pulse = false

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()

            VStack(spacing: 18) {
                iconPulseLayer

                Text("app_name")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(textColor)
                    .tracking(1.2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            pulse = true
        }
    }

    private var iconView: some View {
        Group {
            if let appIcon = AppIconProvider.appIconImage() {
                Image(uiImage: appIcon)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.93, green: 0.26, blue: 0.28), Color(red: 0.99, green: 0.56, blue: 0.23)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Image(systemName: "play.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.white)
                            .padding(28)
                    )
            }
        }
        .frame(width: 160, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    private var iconPulseLayer: some View {
        ZStack {
            Circle()
                .fill(pulseGlowColor)
                .frame(width: 240, height: 240)
                .scaleEffect(pulse ? 1.06 : 0.94)
                .blur(radius: 24)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)

            iconView
                .scaleEffect(pulse ? 1.0 : 0.92)
                .shadow(color: iconShadowColor, radius: 18, x: 0, y: 18)
                .animation(.spring(response: 0.9, dampingFraction: 0.8, blendDuration: 0.4).repeatForever(autoreverses: true), value: pulse)
        }
    }

    private var backgroundColor: Color {
        launchColorScheme == .dark
            ? Color(red: 0.04, green: 0.04, blue: 0.05)
            : .white
    }

    private var textColor: Color {
        launchColorScheme == .dark
            ? .white.opacity(0.92)
            : .black.opacity(0.9)
    }

    private var pulseGlowColor: Color {
        launchColorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.04)
    }

    private var iconShadowColor: Color {
        launchColorScheme == .dark
            ? Color.black.opacity(0.6)
            : Color.black.opacity(0.12)
    }

    private var launchColorScheme: ColorScheme {
        settings.shouldUseSystemDarkLaunchStyling ? .dark : colorScheme
    }
}

#if DEBUG
struct LaunchAnimationView_Previews: PreviewProvider {
    static var previews: some View {
        LaunchAnimationView()
            .environmentObject(AppSettings.shared)
    }
}
#endif
