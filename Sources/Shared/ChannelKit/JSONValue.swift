import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

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
