import Foundation

struct Channel: Identifiable, Codable {
    let id: String
    var name: String
    var stream_url: String?
    let logo_name: String?
    let color: String?
    let subtitle: String?
    let defaultName: String

    var streamUrl: URL? { URL(string: stream_url ?? "") }
}

extension Channel {
    init(
        id: String,
        name: String,
        stream_url: String? = nil,
        logo_name: String? = nil,
        color: String? = nil,
        subtitle: String? = nil
    ) {
        self.id = id
        self.name = name
        self.stream_url = stream_url
        self.logo_name = logo_name
        self.color = color
        self.subtitle = subtitle
        self.defaultName = name
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case stream_url
        case logo_name
        case color
        case subtitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let decodedName = try container.decode(String.self, forKey: .name)
        name = decodedName
        defaultName = decodedName
        stream_url = try container.decodeIfPresent(String.self, forKey: .stream_url)
        logo_name = try container.decodeIfPresent(String.self, forKey: .logo_name)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(stream_url, forKey: .stream_url)
        try container.encodeIfPresent(logo_name, forKey: .logo_name)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
    }
}
