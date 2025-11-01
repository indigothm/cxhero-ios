import Foundation

public struct EventSession: Codable, Equatable, Sendable {
    public let id: UUID
    public let userId: String?
    public let metadata: [String: EventValue]?
    public let startedAt: Date
    public var endedAt: Date?

    public init(id: UUID = UUID(), userId: String?, metadata: [String: EventValue]?, startedAt: Date = Date(), endedAt: Date? = nil) {
        self.id = id
        self.userId = userId
        self.metadata = metadata
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

