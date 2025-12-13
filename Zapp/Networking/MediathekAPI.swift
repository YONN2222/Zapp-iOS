import Foundation

enum MediathekChannel: String, CaseIterable, Codable {
    case ard = "ARD"
    case zdf = "ZDF"
    case arte = "ARTE.DE"
    case dreiSat = "3Sat"
    case kika = "KiKA"
    case phoenix = "PHOENIX"
    case tagesschau24 = "tagesschau24"
    case ardAlpha = "ARD-alpha"
    case zdfInfo = "ZDFinfo"
    case zdfNeo = "ZDFneo"
    case one = "ONE"
    case br = "BR"
    case hr = "HR"
    case mdr = "MDR"
    case ndr = "NDR"
    case rbb = "RBB"
    case sr = "SR"
    case swr = "SWR"
    case wdr = "WDR"
}

struct MediathekQueryRequest: Codable {
    var queries: [Query]
    var sortBy: String = "timestamp"
    var sortOrder: String = "desc"
    var future: Bool = false
    var offset: Int = 0
    var size: Int = 30
    var duration_min: Int? = nil
    var duration_max: Int? = nil
    
    struct Query: Codable {
        let fields: [String]
        let query: String
    }
    
    static func search(
        query: String,
        channels: [MediathekChannel] = [],
        minDurationSeconds: Int? = nil,
        maxDurationSeconds: Int? = nil,
        offset: Int = 0,
        size: Int = 30,
        includeFuture: Bool = false
    ) -> MediathekQueryRequest {
        var queries: [Query] = []
        
        if !query.isEmpty {
            queries.append(Query(fields: ["title", "topic"], query: query))
        }
        
        let channelsToUse = channels.isEmpty ? MediathekChannel.allCases : channels
        for channel in channelsToUse {
            queries.append(Query(fields: ["channel"], query: channel.rawValue))
        }
        
        return MediathekQueryRequest(
            queries: queries,
            future: includeFuture,
            offset: offset,
            size: size,
            duration_min: minDurationSeconds,
            duration_max: maxDurationSeconds
        )
    }
}

struct MediathekAnswer: Codable {
    let result: MediathekResult
    
    struct MediathekResult: Codable {
        let results: [MediathekShow]
        let queryInfo: QueryInfo
        
        struct QueryInfo: Codable {
            let resultCount: Int
            let totalResults: Int
            let filmlisteTimestamp: TimeInterval

            private enum CodingKeys: String, CodingKey {
                case resultCount
                case totalResults
                case filmlisteTimestamp
            }

            private static let isoFormatter: ISO8601DateFormatter = {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter
            }()

            init(resultCount: Int, totalResults: Int, filmlisteTimestamp: TimeInterval) {
                self.resultCount = resultCount
                self.totalResults = totalResults
                self.filmlisteTimestamp = filmlisteTimestamp
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                resultCount = try container.decode(Int.self, forKey: .resultCount)
                totalResults = try container.decode(Int.self, forKey: .totalResults)

                if let numericValue = try? container.decode(TimeInterval.self, forKey: .filmlisteTimestamp) {
                    filmlisteTimestamp = numericValue
                } else {
                    let stringValue = try container.decode(String.self, forKey: .filmlisteTimestamp)
                    if let numericFromString = TimeInterval(stringValue) {
                        filmlisteTimestamp = numericFromString
                    } else if let date = Self.isoFormatter.date(from: stringValue) {
                        filmlisteTimestamp = date.timeIntervalSince1970
                    } else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .filmlisteTimestamp,
                            in: container,
                            debugDescription: "Unsupported filmlisteTimestamp format: \(stringValue)"
                        )
                    }
                }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(resultCount, forKey: .resultCount)
                try container.encode(totalResults, forKey: .totalResults)
                try container.encode(filmlisteTimestamp, forKey: .filmlisteTimestamp)
            }
        }
    }
}

final class MediathekAPI {
    static let shared = MediathekAPI()
    
    private let baseURL = URL(string: "https://mediathekviewweb.de/api/")!
    private let session: URLSession
    
    init(session: URLSession = .shared) {
        self.session = session
    }
    
    func search(request: MediathekQueryRequest) async throws -> MediathekAnswer {
        let url = baseURL.appendingPathComponent("query")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ZappAPIError.requestFailed
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(MediathekAnswer.self, from: data)
    }
}
