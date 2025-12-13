import UIKit

enum AppIconProvider {
    static func appIconImage() -> UIImage? {
        guard
            let iconsDictionary = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
            let primaryIcon = iconsDictionary["CFBundlePrimaryIcon"] as? [String: Any],
            let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
            let iconName = iconFiles.last,
            let iconImage = UIImage(named: iconName)
        else {
            return nil
        }

        return iconImage
    }
}
