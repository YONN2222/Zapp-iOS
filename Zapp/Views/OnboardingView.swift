import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0
    
    private let pages: [OnboardingPage] = [
        .welcome,
        .features,
        .geoRestriction,
        .disclaimer,
        .finish
    ]
    
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        pages[index].view
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { index in
                            Circle()
                                .fill(currentPage == index ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(width: 8, height: 8)
                                .animation(.easeInOut(duration: 0.2), value: currentPage)
                        }
                    }
                    .padding(.bottom, 8)
                    
                    Button {
                        if currentPage < pages.count - 1 {
                            withAnimation {
                                currentPage += 1
                            }
                        } else {
                            isPresented = false
                        }
                    } label: {
                        Text(currentPage == pages.count - 1 ? String(localized: "onboarding_get_started") : String(localized: "onboarding_continue"))
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
    }
}

enum OnboardingPage {
    case welcome
    case features
    case geoRestriction
    case disclaimer
    case finish
    
    @ViewBuilder
    var view: some View {
        switch self {
        case .welcome:
            OnboardingWelcomeView()
        case .features:
            OnboardingFeaturesView()
        case .geoRestriction:
            OnboardingGeoRestrictionView()
        case .disclaimer:
            OnboardingDisclaimerView()
        case .finish:
            OnboardingFinishView()
        }
    }
}

struct OnboardingWelcomeView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image("ZappIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 26.4, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
            
            VStack(spacing: 12) {
                Text(String(localized: "onboarding_welcome_title"))
                    .font(.system(size: 48, weight: .bold))
                
                Text(String(localized: "onboarding_welcome_subtitle"))
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

struct OnboardingFeaturesView: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 16) {
                Text(String(localized: "onboarding_features_title"))
                    .font(.system(size: 34, weight: .bold))
                
                Text(String(localized: "onboarding_features_subtitle"))
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 24) {
                FeatureRow(
                    icon: "dot.radiowaves.left.and.right",
                    title: String(localized: "onboarding_feature_live_title"),
                    description: String(localized: "onboarding_feature_live_description")
                )
                
                FeatureRow(
                    icon: "film",
                    title: String(localized: "onboarding_feature_mediathek_title"),
                    description: String(localized: "onboarding_feature_mediathek_description")
                )
                
                FeatureRow(
                    icon: "play.circle",
                    title: String(localized: "onboarding_feature_continue_title"),
                    description: String(localized: "onboarding_feature_continue_description")
                )
                
                FeatureRow(
                    icon: "bookmark",
                    title: String(localized: "onboarding_feature_bookmarks_title"),
                    description: String(localized: "onboarding_feature_bookmarks_description")
                )
                
                FeatureRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: String(localized: "onboarding_feature_opensource_title"),
                    description: String(localized: "onboarding_feature_opensource_description")
                )
            }
            
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 44)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

struct OnboardingGeoRestrictionView: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            Image(systemName: "globe.europe.africa.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
            
            VStack(spacing: 16) {
                Text(String(localized: "onboarding_geo_title"))
                    .font(.system(size: 34, weight: .bold))
                    .multilineTextAlignment(.center)
                
                VStack(spacing: 12) {
                    Text(String(localized: "onboarding_geo_message_1"))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.primary)
                    
                    Text(String(localized: "onboarding_geo_message_2"))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

struct OnboardingDisclaimerView: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            Image(systemName: "info.circle.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            
            VStack(spacing: 16) {
                Text(String(localized: "onboarding_disclaimer_title"))
                    .font(.system(size: 34, weight: .bold))
                
                VStack(spacing: 12) {
                    Text(String(localized: "onboarding_disclaimer_message_1"))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.primary)
                    
                    Text(String(localized: "onboarding_disclaimer_message_2"))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

struct OnboardingFinishView: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
            
            VStack(spacing: 16) {
                Text(String(localized: "onboarding_finish_title"))
                    .font(.system(size: 40, weight: .bold))
                
                Text(String(localized: "onboarding_finish_subtitle"))
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}
