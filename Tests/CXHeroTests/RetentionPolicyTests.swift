import Foundation
import Testing
@testable import CXHero

@Test("RetentionPolicy.none has no limits")
func retentionPolicyNone() {
    let policy = RetentionPolicy.none
    
    #expect(policy.maxAge == nil)
    #expect(policy.maxSessionsPerUser == nil)
    #expect(policy.automaticCleanupEnabled == false)
}

@Test("RetentionPolicy.standard has sensible defaults")
func retentionPolicyStandard() {
    let policy = RetentionPolicy.standard
    
    #expect(policy.maxAge == TimeInterval(30 * 24 * 3600)) // 30 days
    #expect(policy.maxSessionsPerUser == 50)
    #expect(policy.automaticCleanupEnabled == true)
}

@Test("RetentionPolicy.conservative keeps more data")
func retentionPolicyConservative() {
    let policy = RetentionPolicy.conservative
    
    #expect(policy.maxAge == TimeInterval(90 * 24 * 3600)) // 90 days
    #expect(policy.maxSessionsPerUser == 100)
    #expect(policy.automaticCleanupEnabled == true)
}

@Test("RetentionPolicy.aggressive removes data quickly")
func retentionPolicyAggressive() {
    let policy = RetentionPolicy.aggressive
    
    #expect(policy.maxAge == TimeInterval(7 * 24 * 3600)) // 7 days
    #expect(policy.maxSessionsPerUser == 20)
    #expect(policy.automaticCleanupEnabled == true)
}

@Test("Custom retention policy")
func customRetentionPolicy() {
    let policy = RetentionPolicy(
        maxAge: TimeInterval(60 * 24 * 3600), // 60 days
        maxSessionsPerUser: 75,
        automaticCleanupEnabled: false
    )
    
    #expect(policy.maxAge == TimeInterval(60 * 24 * 3600))
    #expect(policy.maxSessionsPerUser == 75)
    #expect(policy.automaticCleanupEnabled == false)
}

@Test("EventRecorder uses standard retention policy by default")
func eventRecorderDefaultRetentionPolicy() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let recorder = EventRecorder(directory: tmp)
    
    #expect(recorder.retentionPolicy.maxAge == TimeInterval(30 * 24 * 3600))
    #expect(recorder.retentionPolicy.maxSessionsPerUser == 50)
    #expect(recorder.retentionPolicy.automaticCleanupEnabled == true)
}

@Test("EventRecorder can use custom retention policy")
func eventRecorderCustomRetentionPolicy() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let customPolicy = RetentionPolicy(maxAge: TimeInterval(14 * 24 * 3600), maxSessionsPerUser: 25)
    let recorder = EventRecorder(directory: tmp, retentionPolicy: customPolicy)
    
    #expect(recorder.retentionPolicy.maxAge == TimeInterval(14 * 24 * 3600))
    #expect(recorder.retentionPolicy.maxSessionsPerUser == 25)
}

@Test("Age-based retention removes old sessions")
func ageBasedRetention() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let policy = RetentionPolicy(maxAge: 100, maxSessionsPerUser: nil, automaticCleanupEnabled: false)
    let recorder = EventRecorder(directory: tmp, retentionPolicy: policy)
    
    // Create an old session (manually) by creating the JSON directly
    let oldSessionId = UUID()
    let oldStartDate = Date().addingTimeInterval(-200) // 200s ago (older than 100s limit)
    
    let userFolder = "test-user"
    let oldSessionDir = tmp
        .appendingPathComponent("users")
        .appendingPathComponent(userFolder)
        .appendingPathComponent("sessions")
        .appendingPathComponent(oldSessionId.uuidString)
    
    try FileManager.default.createDirectory(at: oldSessionDir, withIntermediateDirectories: true)
    
    // Create session JSON with old date
    let iso8601Formatter = ISO8601DateFormatter()
    let sessionJSON = """
    {
        "id": "\(oldSessionId.uuidString)",
        "userId": "test-user",
        "startedAt": "\(iso8601Formatter.string(from: oldStartDate))",
        "metadata": {}
    }
    """
    try sessionJSON.write(to: oldSessionDir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
    
    // Create a recent session
    let recentSession = await recorder.startSession(userID: "test-user")
    
    // Act - apply retention policy
    await recorder.applyRetentionPolicy()
    
    // Assert - old session should be deleted
    #expect(FileManager.default.fileExists(atPath: oldSessionDir.path) == false)
    
    // Recent session should still exist
    let sessions = await recorder.listSessions(forUserID: "test-user")
    #expect(sessions.count == 1)
    #expect(sessions[0].id == recentSession.id)
}

@Test("Count-based retention keeps newest N sessions")
func countBasedRetention() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let policy = RetentionPolicy(maxAge: nil, maxSessionsPerUser: 3, automaticCleanupEnabled: false)
    let recorder = EventRecorder(directory: tmp, retentionPolicy: policy)
    
    // Create 5 sessions (all ended) with sufficient time between them
    var sessionIds: [UUID] = []
    for i in 0..<5 {
        let session = await recorder.startSession(userID: "test-user", metadata: ["index": .int(i)])
        sessionIds.append(session.id)
        recorder.record("test_event_\(i)") // Record an event to ensure session is saved
        try await Task.sleep(nanoseconds: 10_000_000) // 0.01s to ensure event is recorded
        await recorder.endSession()
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay to ensure different timestamps
    }
    
    // Act - apply retention policy
    await recorder.applyRetentionPolicy()
    
    // Assert - should only keep newest 3 sessions
    let sessions = await recorder.listSessions(forUserID: "test-user")
    #expect(sessions.count == 3)
    
    // The oldest 2 sessions should be deleted
    let sessionIdSet = Set(sessions.map { $0.id })
    #expect(!sessionIdSet.contains(sessionIds[0])) // Oldest
    #expect(!sessionIdSet.contains(sessionIds[1])) // Second oldest
    
    // Verify at least the newest is kept
    #expect(sessionIdSet.contains(sessionIds[4])) // Newest must be kept
}

@Test("Automatic cleanup runs on session start")
func automaticCleanupOnSessionStart() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let policy = RetentionPolicy(maxAge: 50, maxSessionsPerUser: nil, automaticCleanupEnabled: true)
    let recorder = EventRecorder(directory: tmp, retentionPolicy: policy)
    
    // Create old session manually with JSON
    let oldSessionId = UUID()
    let oldStartDate = Date().addingTimeInterval(-100) // 100s ago
    
    let userFolder = "test-user"
    let oldSessionDir = tmp
        .appendingPathComponent("users")
        .appendingPathComponent(userFolder)
        .appendingPathComponent("sessions")
        .appendingPathComponent(oldSessionId.uuidString)
    
    try FileManager.default.createDirectory(at: oldSessionDir, withIntermediateDirectories: true)
    
    let iso8601Formatter = ISO8601DateFormatter()
    let sessionJSON = """
    {
        "id": "\(oldSessionId.uuidString)",
        "userId": "test-user",
        "startedAt": "\(iso8601Formatter.string(from: oldStartDate))",
        "metadata": {}
    }
    """
    try sessionJSON.write(to: oldSessionDir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
    
    // Verify old session exists
    #expect(FileManager.default.fileExists(atPath: oldSessionDir.path) == true)
    
    // Act - start new session (should trigger automatic cleanup)
    _ = await recorder.startSession(userID: "test-user")
    
    // Assert - old session should be deleted automatically
    #expect(FileManager.default.fileExists(atPath: oldSessionDir.path) == false)
}

@Test("Retention policy disabled when automaticCleanupEnabled is false")
func retentionDisabledWhenNotAutomatic() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let policy = RetentionPolicy(maxAge: 50, maxSessionsPerUser: 2, automaticCleanupEnabled: false)
    let recorder = EventRecorder(directory: tmp, retentionPolicy: policy)
    
    // Create old session with JSON
    let oldSessionId = UUID()
    let oldStartDate = Date().addingTimeInterval(-100)
    
    let userFolder = "test-user"
    let oldSessionDir = tmp
        .appendingPathComponent("users")
        .appendingPathComponent(userFolder)
        .appendingPathComponent("sessions")
        .appendingPathComponent(oldSessionId.uuidString)
    
    try FileManager.default.createDirectory(at: oldSessionDir, withIntermediateDirectories: true)
    
    let iso8601Formatter = ISO8601DateFormatter()
    let sessionJSON = """
    {
        "id": "\(oldSessionId.uuidString)",
        "userId": "test-user",
        "startedAt": "\(iso8601Formatter.string(from: oldStartDate))",
        "metadata": {}
    }
    """
    try sessionJSON.write(to: oldSessionDir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
    
    // Act - start new session (automatic cleanup is disabled)
    _ = await recorder.startSession(userID: "test-user")
    
    // Assert - old session should NOT be deleted (automatic cleanup disabled)
    #expect(FileManager.default.fileExists(atPath: oldSessionDir.path) == true)
    
    // But manual cleanup should work
    await recorder.applyRetentionPolicy()
    #expect(FileManager.default.fileExists(atPath: oldSessionDir.path) == false)
}

@Test("Multiple users retention is isolated")
func multipleUsersRetentionIsolated() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let policy = RetentionPolicy(maxAge: nil, maxSessionsPerUser: 2, automaticCleanupEnabled: false)
    let recorder = EventRecorder(directory: tmp, retentionPolicy: policy)
    
    // Create 3 sessions for user-1
    for i in 0..<3 {
        _ = await recorder.startSession(userID: "user-1", metadata: ["index": .int(i)])
        await recorder.endSession()
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    
    // Create 3 sessions for user-2
    for i in 0..<3 {
        _ = await recorder.startSession(userID: "user-2", metadata: ["index": .int(i)])
        await recorder.endSession()
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    
    // Act - apply retention (max 2 sessions per user)
    await recorder.applyRetentionPolicy()
    
    // Assert - each user should have 2 sessions
    let user1Sessions = await recorder.listSessions(forUserID: "user-1")
    let user2Sessions = await recorder.listSessions(forUserID: "user-2")
    
    #expect(user1Sessions.count == 2)
    #expect(user2Sessions.count == 2)
}

@Test("Current session is not deleted by retention policy")
func currentSessionNotDeleted() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let policy = RetentionPolicy(maxAge: nil, maxSessionsPerUser: 1, automaticCleanupEnabled: false)
    let recorder = EventRecorder(directory: tmp, retentionPolicy: policy)
    
    // Start session
    _ = await recorder.startSession(userID: "test-user")
    await recorder.endSession()
    
    let session2 = await recorder.startSession(userID: "test-user")
    // Keep session2 active
    
    // Act - apply retention
    await recorder.applyRetentionPolicy()
    
    // Assert - current session should still be accessible
    let current = await recorder.currentSession()
    #expect(current?.id == session2.id)
    
    // Old session should be deleted
    let sessions = await recorder.listSessions(forUserID: "test-user")
    #expect(sessions.count == 1)
    #expect(sessions[0].id == session2.id)
}

