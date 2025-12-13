import Foundation
import Combine
import SwiftUI
import UIKit

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    private let defaults = UserDefaults.standard
    private let initialSystemInterfaceStyle: UIUserInterfaceStyle
    
    // Keys
    private let streamQualityWifiKey = "streamQualityWifi"
    private let streamQualityCellularKey = "streamQualityCellular"
    private let downloadOverWifiOnlyKey = "downloadOverWifiOnly"
    private let detailLandscapeKey = "detailLandscape"
    private let colorSchemePreferenceKey = "colorSchemePreference"
    private let streamHostKey = "streamHost"
    
    @Published var streamQualityWifi: MediathekShow.Quality {
        didSet { defaults.set(streamQualityWifi.rawValue, forKey: streamQualityWifiKey) }
    }
    
    @Published var streamQualityCellular: MediathekShow.Quality {
        didSet { defaults.set(streamQualityCellular.rawValue, forKey: streamQualityCellularKey) }
    }
    
    @Published var downloadOverWifiOnly: Bool {
        didSet { defaults.set(downloadOverWifiOnly, forKey: downloadOverWifiOnlyKey) }
    }
    
    @Published var detailLandscape: Bool {
        didSet { defaults.set(detailLandscape, forKey: detailLandscapeKey) }
    }

    @Published var colorSchemePreference: ColorSchemePreference {
        didSet {
            defaults.set(colorSchemePreference.rawValue, forKey: colorSchemePreferenceKey)
            applyColorSchemePreference()
        }
    }

    @Published var streamHost: String {
        didSet { defaults.set(streamHost, forKey: streamHostKey) }
    }

    
    private init() {
        self.initialSystemInterfaceStyle = UIScreen.main.traitCollection.userInterfaceStyle
        self.streamQualityWifi = MediathekShow.Quality(rawValue: defaults.string(forKey: streamQualityWifiKey) ?? "High") ?? .high
        self.streamQualityCellular = MediathekShow.Quality(rawValue: defaults.string(forKey: streamQualityCellularKey) ?? "Medium") ?? .medium
        self.downloadOverWifiOnly = defaults.bool(forKey: downloadOverWifiOnlyKey)
        self.detailLandscape = defaults.bool(forKey: detailLandscapeKey)
        self.colorSchemePreference = ColorSchemePreference(rawValue: defaults.string(forKey: colorSchemePreferenceKey) ?? ColorSchemePreference.light.rawValue) ?? .light
        self.streamHost = defaults.string(forKey: streamHostKey) ?? ""
        applyColorSchemePreference()
    }
    
    func preferredQuality(available qualities: [MediathekShow.Quality]) -> MediathekShow.Quality {
        let supported = qualities.isEmpty ? MediathekShow.Quality.allCases : qualities
        let prefersWifi = NetworkMonitor.shared.isOnWiFi
        let desired = prefersWifi ? streamQualityWifi : streamQualityCellular

        if supported.contains(desired) {
            return desired
        }

        if prefersWifi {
            return supported.last ?? .high
        } else {
            return supported.first ?? .low
        }
    }

    func preferredQuality() -> MediathekShow.Quality {
        preferredQuality(available: MediathekShow.Quality.allCases)
    }
}

private extension AppSettings {
    func applyColorSchemePreference() {
        let style = colorSchemePreference.userInterfaceStyle

        let applyStyle = {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .forEach { $0.overrideUserInterfaceStyle = style }
        }

        if Thread.isMainThread {
            applyStyle()
        } else {
            DispatchQueue.main.async(execute: applyStyle)
        }
    }
}

extension AppSettings {
    enum ColorSchemePreference: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return String(localized: "settings_appearance_system")
            case .light: return String(localized: "settings_appearance_light")
            case .dark: return String(localized: "settings_appearance_dark")
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }

        var userInterfaceStyle: UIUserInterfaceStyle {
            switch self {
            case .system: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    var preferredColorScheme: ColorScheme? {
        colorSchemePreference.colorScheme
    }

    var shouldUseSystemDarkLaunchStyling: Bool {
        colorSchemePreference == .light && initialSystemInterfaceStyle == .dark
    }
}
