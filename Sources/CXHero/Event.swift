import Foundation

public struct Event: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let timestamp: Date
    public let properties: [String: EventValue]?
    public let sessionId: UUID
    public let userId: String?

    public init(
        id: UUID = UUID(),
        name: String,
        timestamp: Date = Date(),
        properties: [String: EventValue]? = nil,
        sessionId: UUID,
        userId: String?
    ) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.properties = properties
        self.sessionId = sessionId
        self.userId = userId
    }
}
