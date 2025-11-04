import Foundation

/// Represents a JSON-encodable primitive value for event properties.
public enum EventValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        throw DecodingError.typeMismatch(EventValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported EventValue type"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        }
    }
    
    // MARK: - Convenience accessors
    
    /// Extract string value if this is a .string case
    public var asString: String? {
        if case let .string(s) = self { return s }
        return nil
    }
    
    /// Extract int value if this is an .int case
    public var asInt: Int? {
        if case let .int(i) = self { return i }
        return nil
    }
    
    /// Extract double value if this is a .double case, or convert int to double
    public var asDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    
    /// Extract bool value if this is a .bool case
    public var asBool: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }
}

