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

    private enum MediathekAPIError: Error {
        case requestFailed(statusCode: Int?)
    }

    /// Short-lived cache so a brief network drop can still be served from the last successful response.
    private actor ResponseCache {
        private struct Entry {
            let answer: MediathekAnswer
            let fetchedAt: Date
        }

        private let ttl: TimeInterval
        private var storage: [String: Entry] = [:]

        init(ttl: TimeInterval) {
            self.ttl = ttl
        }

        func answer(for key: String) -> MediathekAnswer? {
            guard let entry = storage[key], Date().timeIntervalSince(entry.fetchedAt) <= ttl else {
                return nil
            }
            return entry.answer
        }

        func store(_ answer: MediathekAnswer, for key: String) {
            storage[key] = Entry(answer: answer, fetchedAt: Date())
        }
    }

    private let baseURL = URL(string: "https://mediathekviewweb.de/api/")!
    private let session: URLSession
    private let cache = ResponseCache(ttl: 10)

    private init() {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }
    
    func search(request: MediathekQueryRequest) async throws -> MediathekAnswer {
        let url = baseURL.appendingPathComponent("query")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        urlRequest.httpBody = try encoder.encode(request)
        let cacheKey = String(data: urlRequest.httpBody ?? Data(), encoding: .utf8) ?? UUID().uuidString

        #if DEBUG
        print("🔍 MediathekAPI: Searching with query: \(request.queries.first?.query ?? "none")")
        print("🔍 MediathekAPI: Cache policy: \(urlRequest.cachePolicy.rawValue)")
        #endif

        do {
            let (data, response) = try await session.data(for: urlRequest)

            #if DEBUG
            print("📡 MediathekAPI: Response received, status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            #endif

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode
                #if DEBUG
                print("❌ MediathekAPI: HTTP error - status code: \(status ?? -1)")
                #endif
                throw MediathekAPIError.requestFailed(statusCode: status)
            }

            let decoder = JSONDecoder()
            let answer = try decoder.decode(MediathekAnswer.self, from: data)

            #if DEBUG
            print("✅ MediathekAPI: Received \(answer.result.results.count) results (total: \(answer.result.queryInfo.totalResults))")
            #endif

            await cache.store(answer, for: cacheKey)
            return answer
        } catch let decodingError as DecodingError {
            #if DEBUG
            print("❌ MediathekAPI: Decoding error: \(decodingError)")
            #endif
            throw decodingError
        } catch {
            if let cached = await cache.answer(for: cacheKey) {
                #if DEBUG
                print("♻️ MediathekAPI: Network error, serving cached response: \(error.localizedDescription)")
                #endif
                return cached
            }
            #if DEBUG
            print("❌ MediathekAPI: Network error: \(error.localizedDescription)")
            print("❌ MediathekAPI: Error details: \(error)")
            #endif
            throw error
        }
    }
}
