import Foundation

enum ZappAPIError: Error {
    case invalidURL
    case requestFailed
}

struct ChannelInfo: Codable {
    let streamUrl: String

    enum CodingKeys: String, CodingKey {
        case streamUrl = "streamUrl"
    }
}

final class ZappAPI {
    static let shared = ZappAPI()

    private let baseURL = URL(string: "https://api.zapp.mediathekview.de/v1/")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchChannelInfoList() async throws -> [String: ChannelInfo] {
        let url = baseURL.appendingPathComponent("channelInfoList")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ZappAPIError.requestFailed
        }
        let decoder = JSONDecoder()
        return try decoder.decode([String: ChannelInfo].self, from: data)
    }

    func fetchShows(for channelName: String) async throws -> Show? {
        let url = baseURL.appendingPathComponent("shows/")
        let final = url.appendingPathComponent(channelName)
        let (data, response) = try await session.data(from: final)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ZappAPIError.requestFailed
        }
        let decoder = JSONDecoder()
        struct ShowResponse: Codable { let shows: [Show]? }
        let r = try decoder.decode(ShowResponse.self, from: data)
        return r.shows?.first
    }
}
