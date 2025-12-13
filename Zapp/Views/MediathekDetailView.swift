import SwiftUI

struct MediathekDetailView: View {
    let show: MediathekShow
    @EnvironmentObject var repo: MediathekRepository
    @State private var downloadError: String?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Thumbnail with play button
                ZStack {
                    VideoThumbnailView(
                        url: show.preferredThumbnailURL,
                        cornerRadius: 12,
                        placeholderIcon: nil,
                        quality: .high
                    )
                    .aspectRatio(16/9, contentMode: .fit)

                    Button(action: playVideo) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 72))
                            .foregroundColor(.white)
                            .shadow(radius: 6)
                    }
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    // Title & Topic
                    Text(show.title)
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text(show.topic)
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    // Metadata
                    HStack(spacing: 16) {
                        Label(show.channel, systemImage: "tv")
                        Label(show.formattedDuration, systemImage: "clock")
                        Label(show.formattedTimestamp, systemImage: "calendar")
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    
                    Divider()
                    
                    // Description
                    if let description = show.description {
                        Text(description)
                            .font(.body)
                    }
                    
                    Divider()
                    
                    // Action buttons
                    VStack(spacing: 12) {
                        Button(action: playVideo) {
                            Label("show_play", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        
                        HStack(spacing: 12) {
                            Button(action: { repo.toggleBookmark(show: show) }) {
                                Group {
                                    if repo.isBookmarked(apiId: show.id) {
                                        Label("show_remove_bookmark", systemImage: "bookmark.fill")
                                    } else {
                                        Label("show_bookmark", systemImage: "bookmark")
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            
                            Menu {
                                ForEach(show.supportedQualities, id: \.self) { quality in
                                    Button(action: { startDownload(quality: quality) }) {
                                        Label(quality.localizedName, systemImage: "arrow.down.circle")
                                    }
                                }
                            } label: {
                                Label("show_download", systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        if let websiteUrl = show.websiteUrl {
                            Link(destination: websiteUrl) {
                                Label("show_website", systemImage: "safari")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle("show_details")
        .navigationBarTitleDisplayMode(.inline)
        .alert(String(localized: "download_error_title"), isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button(String(localized: "ok"), role: .cancel) { downloadError = nil }
        } message: {
            Text(downloadError ?? String(localized: "error_unknown"))
        }
    }
    
    private func playVideo() {
        let preferredQuality = AppSettings.shared.preferredQuality(available: show.supportedQualities)
        PlayerPresentationManager.shared.presentShow(show, quality: preferredQuality)
    }
    
    private func startDownload(quality: MediathekShow.Quality) {
        let didStart = repo.startDownload(show: show, quality: quality)
        if !didStart {
            downloadError = String(localized: "download_error_wifi_only")
        }
    }
}

struct MediathekDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let previewUrl = AppSettings.shared.streamHost.isEmpty ? "" : "\(AppSettings.shared.streamHost)/video.m3u8"

        let show = MediathekShow(
            id: "1",
            topic: "Test Topic",
            title: "Test Title",
            description: "Test description",
            channel: "ARD",
            timestamp: 1234567890,
            size: 1000000,
            duration: 3600,
            filmlisteTimestamp: 1234567890,
            url_website: nil,
            url_video: previewUrl,
            url_video_low: nil,
            url_video_hd: nil
        )
        
        NavigationView {
            MediathekDetailView(show: show)
                .environmentObject(MediathekRepository())
        }
    }
}
