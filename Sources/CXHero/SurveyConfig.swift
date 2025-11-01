import Foundation

public struct SurveyConfig: Codable, Equatable, Sendable {
    public let surveys: [SurveyRule]
}

public struct SurveyRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String { ruleId }
    public let ruleId: String
    public let title: String
    public let message: String
    public let response: SurveyResponse
    public let trigger: TriggerCondition
    public let oncePerSession: Bool?
    public let oncePerUser: Bool?
    public let cooldownSeconds: TimeInterval?

    public var options: [String] {
        if case .options(let opts) = response { return opts }
        return []
    }

    enum CodingKeys: String, CodingKey { case ruleId = "id", title, message, options, trigger, oncePerSession, oncePerUser, cooldownSeconds, response }

    public init(ruleId: String, title: String, message: String, response: SurveyResponse, trigger: TriggerCondition, oncePerSession: Bool? = nil, oncePerUser: Bool? = nil, cooldownSeconds: TimeInterval? = nil) {
        self.ruleId = ruleId
        self.title = title
        self.message = message
        self.response = response
        self.trigger = trigger
        self.oncePerSession = oncePerSession
        self.oncePerUser = oncePerUser
        self.cooldownSeconds = cooldownSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ruleId = try container.decode(String.self, forKey: .ruleId)
        self.title = try container.decode(String.self, forKey: .title)
        self.message = try container.decode(String.self, forKey: .message)
        self.trigger = try container.decode(TriggerCondition.self, forKey: .trigger)
        if let response = try container.decodeIfPresent(SurveyResponse.self, forKey: .response) {
            self.response = response
        } else if let options = try container.decodeIfPresent([String].self, forKey: .options) {
            self.response = .options(options)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .response, in: container, debugDescription: "SurveyRule requires either response or options")
        }
        self.oncePerSession = try container.decodeIfPresent(Bool.self, forKey: .oncePerSession)
        self.oncePerUser = try container.decodeIfPresent(Bool.self, forKey: .oncePerUser)
        self.cooldownSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .cooldownSeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ruleId, forKey: .ruleId)
        try container.encode(title, forKey: .title)
        try container.encode(message, forKey: .message)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(response, forKey: .response)
        try container.encodeIfPresent(oncePerSession, forKey: .oncePerSession)
        try container.encodeIfPresent(oncePerUser, forKey: .oncePerUser)
        try container.encodeIfPresent(cooldownSeconds, forKey: .cooldownSeconds)
    }
}

public enum SurveyResponse: Equatable, Sendable {
    case options([String])
    case text(TextResponseConfig)
}

public struct TextResponseConfig: Codable, Equatable, Sendable {
    public let placeholder: String?
    public let submitLabel: String?
    public let allowEmpty: Bool
    public let minLength: Int?
    public let maxLength: Int?

    public init(placeholder: String? = nil, submitLabel: String? = nil, allowEmpty: Bool = false, minLength: Int? = nil, maxLength: Int? = nil) {
        self.placeholder = placeholder
        self.submitLabel = submitLabel
        self.allowEmpty = allowEmpty
        self.minLength = minLength
        self.maxLength = maxLength
    }
}

extension SurveyResponse: Codable {
    private enum CodingKeys: String, CodingKey { case type, options, placeholder, submitLabel, allowEmpty, minLength, maxLength }
    private enum ResponseType: String, Codable { case options, text }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ResponseType.self, forKey: .type)
        switch type {
        case .options:
            let options = try container.decode([String].self, forKey: .options)
            self = .options(options)
        case .text:
            let config = TextResponseConfig(
                placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder),
                submitLabel: try container.decodeIfPresent(String.self, forKey: .submitLabel),
                allowEmpty: try container.decodeIfPresent(Bool.self, forKey: .allowEmpty) ?? false,
                minLength: try container.decodeIfPresent(Int.self, forKey: .minLength),
                maxLength: try container.decodeIfPresent(Int.self, forKey: .maxLength)
            )
            self = .text(config)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .options(let options):
            try container.encode(ResponseType.options, forKey: .type)
            try container.encode(options, forKey: .options)
        case .text(let config):
            try container.encode(ResponseType.text, forKey: .type)
            try container.encodeIfPresent(config.placeholder, forKey: .placeholder)
            try container.encodeIfPresent(config.submitLabel, forKey: .submitLabel)
            if config.allowEmpty { try container.encode(true, forKey: .allowEmpty) }
            try container.encodeIfPresent(config.minLength, forKey: .minLength)
            try container.encodeIfPresent(config.maxLength, forKey: .maxLength)
        }
    }
}

public enum TriggerCondition: Codable, Equatable, Sendable {
    case event(EventTrigger)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let obj = try container.decode([String: EventTrigger].self)
        if let evt = obj["event"] { self = .event(evt); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown trigger condition")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .event(let ev):
            try container.encode(["event": ev])
        }
    }
}

public struct EventTrigger: Codable, Equatable, Sendable {
    public let name: String
    public let properties: [String: PropertyMatcher]?
}

public enum PropertyMatcher: Equatable, Sendable {
    case equals(MatchAtom)
    case notEquals(MatchAtom)
    case greaterThan(Double)
    case greaterThanOrEqual(Double)
    case lessThan(Double)
    case lessThanOrEqual(Double)
    case contains(String)
    case notContains(String)
    case exists(Bool) // true -> must exist; false -> must not exist
}

public enum MatchAtom: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

extension PropertyMatcher: Codable {
    private enum Keys: String, CodingKey { case op, value }

    public init(from decoder: Decoder) throws {
        // Support shorthand equals: value directly
        if let single = try? MatchAtom(from: decoder) {
            self = .equals(single)
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "eq": self = .equals(try c.decode(MatchAtom.self, forKey: .value))
        case "ne": self = .notEquals(try c.decode(MatchAtom.self, forKey: .value))
        case "gt": self = .greaterThan(try c.decode(Double.self, forKey: .value))
        case "gte": self = .greaterThanOrEqual(try c.decode(Double.self, forKey: .value))
        case "lt": self = .lessThan(try c.decode(Double.self, forKey: .value))
        case "lte": self = .lessThanOrEqual(try c.decode(Double.self, forKey: .value))
        case "contains": self = .contains(try c.decode(String.self, forKey: .value))
        case "notContains": self = .notContains(try c.decode(String.self, forKey: .value))
        case "exists": self = .exists(true)
        case "notExists": self = .exists(false)
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "Unknown op: \(op)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .equals(let atom):
            try atom.encode(to: encoder)
        case .notEquals(let atom):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode("ne", forKey: .op)
            try c.encode(atom, forKey: .value)
        case .greaterThan(let v):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode("gt", forKey: .op)
            try c.encode(v, forKey: .value)
        case .greaterThanOrEqual(let v):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode("gte", forKey: .op)
            try c.encode(v, forKey: .value)
        case .lessThan(let v):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode("lt", forKey: .op)
            try c.encode(v, forKey: .value)
        case .lessThanOrEqual(let v):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode("lte", forKey: .op)
            try c.encode(v, forKey: .value)
        case .contains(let s):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode("contains", forKey: .op)
            try c.encode(s, forKey: .value)
        case .notContains(let s):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode("notContains", forKey: .op)
            try c.encode(s, forKey: .value)
        case .exists(let flag):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(flag ? "exists" : "notExists", forKey: .op)
        }
    }
}

extension MatchAtom: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        throw DecodingError.typeMismatch(MatchAtom.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported MatchAtom"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        }
    }
}

extension PropertyMatcher {
    func matches(_ value: EventValue) -> Bool {
        switch self {
        case .equals(let a): return a.matches(value)
        case .notEquals(let a): return !a.matches(value)
        case .greaterThan(let t): return value.asDouble.map { $0 > t } ?? false
        case .greaterThanOrEqual(let t): return value.asDouble.map { $0 >= t } ?? false
        case .lessThan(let t): return value.asDouble.map { $0 < t } ?? false
        case .lessThanOrEqual(let t): return value.asDouble.map { $0 <= t } ?? false
        case .contains(let s): return value.asString?.contains(s) ?? false
        case .notContains(let s): return !(value.asString?.contains(s) ?? false)
        case .exists:
            // handled by caller since it depends on presence of key not the value
            return true
        }
    }
}

extension MatchAtom {
    func matches(_ value: EventValue) -> Bool {
        switch (self, value) {
        case (.string(let a), .string(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .double(let b)): return Double(a) == b
        case (.double(let a), .int(let b)): return a == Double(b)
        default: return false
        }
    }
}

extension EventValue {
    var asDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    var asString: String? {
        if case let .string(s) = self { return s } else { return nil }
    }
}
