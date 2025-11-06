import Foundation

/// Configuration for automatic cleanup of old events and sessions
public struct RetentionPolicy: Sendable {
    /// Maximum age for events and sessions (older entries are deleted)
    public let maxAge: TimeInterval?
    
    /// Maximum number of sessions to keep per user (oldest are deleted)
    public let maxSessionsPerUser: Int?
    
    /// Whether to automatically cleanup on session start
    public let automaticCleanupEnabled: Bool
    
    public init(
        maxAge: TimeInterval? = nil,
        maxSessionsPerUser: Int? = nil,
        automaticCleanupEnabled: Bool = true
    ) {
        self.maxAge = maxAge
        self.maxSessionsPerUser = maxSessionsPerUser
        self.automaticCleanupEnabled = automaticCleanupEnabled
    }
    
    /// No retention - keep all data indefinitely
    public static let none = RetentionPolicy(
        maxAge: nil,
        maxSessionsPerUser: nil,
        automaticCleanupEnabled: false
    )
    
    /// Conservative retention - 90 days or 100 sessions per user
    public static let conservative = RetentionPolicy(
        maxAge: 90 * 24 * 3600,  // 90 days
        maxSessionsPerUser: 100,
        automaticCleanupEnabled: true
    )
    
    /// Standard retention - 30 days or 50 sessions per user
    public static let standard = RetentionPolicy(
        maxAge: 30 * 24 * 3600,  // 30 days
        maxSessionsPerUser: 50,
        automaticCleanupEnabled: true
    )
    
    /// Aggressive retention - 7 days or 20 sessions per user
    public static let aggressive = RetentionPolicy(
        maxAge: 7 * 24 * 3600,  // 7 days
        maxSessionsPerUser: 20,
        automaticCleanupEnabled: true
    )
}



