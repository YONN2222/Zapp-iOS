import SwiftUI

struct OptionalPreferredColorSchemeModifier: ViewModifier {
    let scheme: ColorScheme?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let scheme {
            content.preferredColorScheme(scheme)
        } else {
            content
        }
    }
}

extension View {
    func optionalPreferredColorScheme(_ scheme: ColorScheme?) -> some View {
        modifier(OptionalPreferredColorSchemeModifier(scheme: scheme))
    }
}
