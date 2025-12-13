import Foundation

struct MediathekShow: Identifiable, Codable {
    let id: String
    let topic: String
    let title: String
    let description: String?
    let channel: String
    let timestamp: Int
    let size: Int
    let duration: Int?
    let filmlisteTimestamp: Int
    let url_website: String?
    let url_video: String
    let url_video_low: String?
    let url_video_hd: String?

    enum CodingKeys: String, CodingKey {
        case id
        case topic
        case title
        case description
        case channel
        case timestamp
        case size
        case duration
        case filmlisteTimestamp
        case url_website
        case url_video
        case url_video_low
        case url_video_hd
    }

    init(
        id: String,
        topic: String,
        title: String,
        description: String?,
        channel: String,
        timestamp: Int,
        size: Int,
        duration: Int?,
        filmlisteTimestamp: Int,
        url_website: String?,
        url_video: String,
        url_video_low: String?,
        url_video_hd: String?
    ) {
        self.id = id
        self.topic = topic
        self.title = title
        self.description = description
        self.channel = channel
        self.timestamp = timestamp
        self.size = size
        self.duration = duration
        self.filmlisteTimestamp = filmlisteTimestamp
        self.url_website = url_website
        self.url_video = url_video
        self.url_video_low = url_video_low
        self.url_video_hd = url_video_hd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        topic = try container.decode(String.self, forKey: .topic)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        channel = try container.decode(String.self, forKey: .channel)
        timestamp = try container.decode(Int.self, forKey: .timestamp)
        size = try container.decode(Int.self, forKey: .size)

        if let numericDuration = try? container.decodeIfPresent(Int.self, forKey: .duration) {
            duration = numericDuration
        } else if let stringDuration = try container.decodeIfPresent(String.self, forKey: .duration) {
            duration = Int(stringDuration)
        } else {
            duration = nil
        }

        filmlisteTimestamp = try container.decode(Int.self, forKey: .filmlisteTimestamp)
        url_website = try container.decodeIfPresent(String.self, forKey: .url_website)
        url_video = try container.decode(String.self, forKey: .url_video)
        url_video_low = try container.decodeIfPresent(String.self, forKey: .url_video_low)
        url_video_hd = try container.decodeIfPresent(String.self, forKey: .url_video_hd)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(topic, forKey: .topic)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(channel, forKey: .channel)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encode(filmlisteTimestamp, forKey: .filmlisteTimestamp)
        try container.encodeIfPresent(url_website, forKey: .url_website)
        try container.encode(url_video, forKey: .url_video)
        try container.encodeIfPresent(url_video_low, forKey: .url_video_low)
        try container.encodeIfPresent(url_video_hd, forKey: .url_video_hd)
    }
    
    // Computed properties
    var videoUrl: URL? { URL(string: url_video) }
    var videoUrlLow: URL? { url_video_low.flatMap { URL(string: $0) } }
    var videoUrlHd: URL? { url_video_hd.flatMap { URL(string: $0) } }
    var websiteUrl: URL? { url_website.flatMap { URL(string: $0) } }
    var preferredThumbnailURL: URL? {
        videoUrlLow ?? videoUrl ?? videoUrlHd
    }
    var hasWebsite: Bool { !(url_website?.isEmpty ?? true) }
    
    var formattedTimestamp: String {
        guard timestamp > 0 else { return "?" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    var formattedDuration: String {
    guard let duration, duration > 0 else { return "?" }
    let hours = duration / 3600
    let minutes = (duration % 3600) / 60
    let seconds = duration % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    enum Quality: String, CaseIterable {
        case low = "Low"
        case medium = "Medium"
        case high = "High"
        
        func url(from show: MediathekShow) -> URL? {
            switch self {
            case .low: return show.videoUrlLow ?? show.videoUrl
            case .medium: return show.videoUrl
            case .high: return show.videoUrlHd ?? show.videoUrl
            }
        }

        var localizedName: String {
            switch self {
            case .low:
                return NSLocalizedString("player_quality_low", comment: "Low quality option")
            case .medium:
                return NSLocalizedString("player_quality_medium", comment: "Medium quality option")
            case .high:
                return NSLocalizedString("player_quality_high", comment: "High quality option")
            }
        }
    }
    
    var supportedQualities: [Quality] {
        Quality.allCases.filter { url(for: $0) != nil }
    }
    
    func url(for quality: Quality) -> URL? {
        quality.url(from: self)
    }
}

// Persistence wrapper
struct PersistedMediathekShow: Identifiable, Codable {
    let id: Int
    let apiId: String
    let show: MediathekShow
    var bookmarked: Bool = false
    var bookmarkedAt: Date?
    var downloadStatus: DownloadStatus = .none
    var downloadProgress: Int = 0
    var downloadedVideoPath: String?
    var downloadedThumbnailPath: String?
    var downloadedBytes: Int64 = 0
    var expectedDownloadBytes: Int64?
    var playbackPosition: TimeInterval = 0
    var videoDuration: TimeInterval = 0
    var lastPlayedBackAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

enum DownloadStatus: String, Codable {
    case none = "NONE"
    case queued = "QUEUED"
    case downloading = "DOWNLOADING"
    case completed = "COMPLETED"
    case failed = "FAILED"
}

extension PersistedMediathekShow {
    var localVideoURL: URL? {
        guard let downloadedVideoPath else { return nil }
        return URL(fileURLWithPath: downloadedVideoPath)
    }

    var localThumbnailURL: URL? {
        guard let downloadedThumbnailPath else { return nil }
        return URL(fileURLWithPath: downloadedThumbnailPath)
    }

    var thumbnailSourceURL: URL? {
        localThumbnailURL ?? localVideoURL ?? show.preferredThumbnailURL
    }

    var resolvedExpectedDownloadBytes: Int64? {
        if let expectedDownloadBytes, expectedDownloadBytes > 0 {
            return expectedDownloadBytes
        }
        if show.size > 0 {
            return Int64(show.size)
        }
        return nil
    }
}
