import Foundation

public struct ModelConfiguration: Codable, Equatable, Sendable {
    public var provider: String
    public var name: String
    public var options: [String: JSONValue]

    public init(provider: String, name: String, options: [String: JSONValue] = [:]) {
        self.provider = provider
        self.name = name
        self.options = options
    }

    public init(from decoder: any Decoder) throws {
        var object = try decoder.singleValueContainer().decode([String: JSONValue].self)
        guard let provider = object.removeValue(forKey: "provider")?.string,
              let name = object.removeValue(forKey: "name")?.string else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Model requires provider and name."))
        }
        self.init(provider: provider, name: name, options: object)
    }

    public func encode(to encoder: any Encoder) throws {
        var object = options
        object["provider"] = .string(provider)
        object["name"] = .string(name)
        var container = encoder.singleValueContainer()
        try container.encode(object)
    }
}

extension ModelConfiguration {
    /// The requested reasoning effort in Edit Agent's words, such as "Extra High", or nil when unset.
    public var reasoningLabel: String? {
        guard let effort = options["reasoningEffort"]?.string, !effort.isEmpty else { return nil }
        return Self.reasoningLabel(effort)
    }

    /// A reasoning effort or context tier name in Edit Agent's words.
    package static func reasoningLabel(_ value: String) -> String {
        let value = value.lowercased() == "xhigh" ? "Extra High" : value
        return value.split { $0.isWhitespace || $0 == "_" || $0 == "-" }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
