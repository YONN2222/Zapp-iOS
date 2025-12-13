import SwiftUI
import Foundation
import UIKit

struct VideoThumbnailView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    var placeholderIcon: String? = "play.rectangle.fill"
    var quality: ThumbnailQuality = .standard

    @State private var image: Image?
    @State private var isLoading = false
    @State private var didFail = false

    private var isRunningInPreviews: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != nil
    }

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.25)
            if isLoading {
                ProgressView()
            } else if didFail {
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundColor(.secondary)
            } else if let placeholderIcon {
                Image(systemName: placeholderIcon)
                    .font(.title)
                    .foregroundColor(.white.opacity(0.85))
            }
        }
    }

    private func loadThumbnail() async {
        if isRunningInPreviews {
            await MainActor.run {
                isLoading = false
            }
            return
        }

        guard let url else {
            await MainActor.run {
                didFail = true
                image = nil
            }
            return
        }

        await MainActor.run {
            isLoading = true
            didFail = false
        }

        do {
            if let staticImage = loadStaticImageIfAvailable(at: url) {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        image = Image(uiImage: staticImage)
                    }
                    isLoading = false
                }
                return
            }

            let uiImage = try await VideoThumbnailService.shared.thumbnail(for: url, quality: quality)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    image = Image(uiImage: uiImage)
                }
                isLoading = false
            }
        } catch is CancellationError {
            await MainActor.run {
                isLoading = false
            }
        } catch {
            await MainActor.run {
                didFail = true
                image = nil
                isLoading = false
            }
        }
    }

    private func loadStaticImageIfAvailable(at url: URL) -> UIImage? {
        guard url.isFileURL else { return nil }
        let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp"]
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
