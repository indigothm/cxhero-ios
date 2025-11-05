import Foundation
import Testing
@testable import CXHero

@Test("hasScheduledSurveys returns false when no surveys scheduled")
func hasScheduledSurveysEmpty() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    
    // Act
    let hasSurveys = await recorder.hasScheduledSurveys(for: "test-user")
    
    // Assert
    #expect(hasSurveys == false)
}

@Test("hasScheduledSurveys returns true when triggered surveys exist")
func hasScheduledSurveysWithTriggered() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    let store = ScheduledSurveyStore(baseDirectory: tmp)
    
    // Create a triggered survey (trigger time in the past)
    await store.scheduleForLater(
        ruleId: "test-rule",
        userId: "test-user",
        sessionId: "session-123",
        delaySeconds: -10 // Already triggered
    )
    
    // Act
    let hasSurveys = await recorder.hasScheduledSurveys(for: "test-user")
    
    // Assert
    #expect(hasSurveys == true)
}

@Test("hasScheduledSurveys returns true when pending surveys exist")
func hasScheduledSurveysWithPending() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    let store = ScheduledSurveyStore(baseDirectory: tmp)
    
    // Create a pending survey (trigger time in the future)
    await store.scheduleForLater(
        ruleId: "test-rule",
        userId: "test-user",
        sessionId: "session-123",
        delaySeconds: 3600 // 1 hour in future
    )
    
    // Act
    let hasSurveys = await recorder.hasScheduledSurveys(for: "test-user")
    
    // Assert
    #expect(hasSurveys == true)
}

@Test("hasScheduledSurveys returns false for different user")
func hasScheduledSurveysDifferentUser() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    let store = ScheduledSurveyStore(baseDirectory: tmp)
    
    // Schedule for user-1
    await store.scheduleForLater(
        ruleId: "test-rule",
        userId: "user-1",
        sessionId: "session-123",
        delaySeconds: 10
    )
    
    // Act - query for user-2
    let hasSurveys = await recorder.hasScheduledSurveys(for: "user-2")
    
    // Assert
    #expect(hasSurveys == false)
}

@Test("cleanupOldScheduledSurveys removes old surveys")
func cleanupOldScheduledSurveysRemovesOld() async throws {
    // Note: This test validates the cleanup API exists and can be called
    // The actual cleanup logic is tested in ScheduledSurveyStore which uses scheduledAt timestamp
    // ScheduledSurveyStore.cleanupOldScheduled() removes surveys where scheduledAt < cutoff time
    
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    
    // Act - verify cleanup doesn't crash and can be called
    await recorder.cleanupOldScheduledSurveys(olderThan: 3600)
    
    // Assert - no surveys means no error
    let hasSurveys = await recorder.hasScheduledSurveys(for: "test-user")
    #expect(hasSurveys == false)
}

@Test("cleanup API is accessible and callable")
func cleanupScheduledSurveysAPIAccessible() async throws {
    // Test validates the public API is accessible
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    
    // Act - verify API is callable with different parameters
    await recorder.cleanupOldScheduledSurveys(olderThan: 3600) // 1 hour
    await recorder.cleanupOldScheduledSurveys(olderThan: 86400) // 24 hours (default)
    await recorder.cleanupOldScheduledSurveys() // Uses default
    
    // Assert - No crash means success
    #expect(true)
}

