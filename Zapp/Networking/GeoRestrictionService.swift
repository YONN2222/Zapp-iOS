import Foundation

actor GeoRestrictionService {
    static let shared = GeoRestrictionService()

    private let session: URLSession
    private var cachedCode: String?
    private var lastFetch: Date?
    private let cacheDuration: TimeInterval = 3600
    private let endpoint = URL(string: "https://ipapi.co/json")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func currentCountryCode(forceRefresh: Bool = false) async -> String? {
        if !forceRefresh, let cachedCode, let lastFetch, Date().timeIntervalSince(lastFetch) < cacheDuration {
            return cachedCode
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 5

        do {
            let (data, response) = try await session.data(for: request)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else { return nil }

            let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let countryCode = (jsonObject?["country"] as? String)?.uppercased() ?? ""
            let uppercaseCode = countryCode
            guard !uppercaseCode.isEmpty else { return nil }

            cachedCode = uppercaseCode
            lastFetch = Date()
            return uppercaseCode
        } catch {
            return nil
        }
    }
}
