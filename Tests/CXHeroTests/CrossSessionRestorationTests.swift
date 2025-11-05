import Foundation
import Testing
@testable import CXHero

@MainActor
@Test("Surveys scheduled in one session are restored in new session")
func crossSessionRestoration() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    let config = SurveyConfig(surveys: [
        SurveyRule(
            ruleId: "test-survey",
            title: "Test Survey",
            message: "Please rate",
            response: .options(["1", "2", "3"]),
            trigger: .event(EventTrigger(
                name: "member_checkin",
                scheduleAfterSeconds: 10
            ))
        )
    ])
    
    // Start first session
    let session1 = await recorder.startSession(userID: "test-user")
    
    let model1 = SurveyTriggerViewModel(
        config: config,
        recorder: recorder,
        debugConfig: .production
    )
    
    // Record event to trigger survey
    recorder.record("member_checkin")
    try await Task.sleep(nanoseconds: 200_000_000) // 0.2s - wait for processing
    
    // Verify survey is scheduled
    let store = ScheduledSurveyStore(baseDirectory: tmp)
    let scheduled1 = await store.getAllPendingSurveys(for: "test-user")
    #expect(scheduled1.count == 1)
    #expect(scheduled1[0].sessionId == session1.id.uuidString)
    
    // Act - End session and start new one (simulating app relaunch)
    await recorder.endSession()
    
    let session2 = await recorder.startSession(userID: "test-user")
    #expect(session2.id != session1.id) // Different session
    
    // Create new view model (simulating view recreation)
    let model2 = SurveyTriggerViewModel(
        config: config,
        recorder: recorder,
        debugConfig: .production
    )
    
    // Wait for restoration
    try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
    
    // Assert - Survey from old session should still exist in store
    let scheduled2 = await store.getAllPendingSurveys(for: "test-user")
    #expect(scheduled2.count == 1)
    
    // The scheduled survey should have the OLD session ID
    #expect(scheduled2[0].sessionId == session1.id.uuidString)
    
    // But restoration should still find it (cross-session query)
    let hasPending = await recorder.hasScheduledSurveys(for: "test-user")
    #expect(hasPending == true)
}

@MainActor
@Test("Triggered surveys from previous session are shown in new session")
func triggeredSurveysCrossSession() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    let config = SurveyConfig(surveys: [
        SurveyRule(
            ruleId: "test-survey",
            title: "Test Survey",
            message: "Please rate",
            response: .options(["1", "2", "3"]),
            trigger: .event(EventTrigger(
                name: "member_checkin",
                scheduleAfterSeconds: 1 // Short delay
            ))
        )
    ])
    
    // Start first session
    let session1 = await recorder.startSession(userID: "test-user")
    
    let model1 = SurveyTriggerViewModel(
        config: config,
        recorder: recorder,
        debugConfig: .production
    )
    
    // Record event to trigger survey
    recorder.record("member_checkin")
    try await Task.sleep(nanoseconds: 500_000_000) // 0.5s - wait for scheduling
    
    // Verify survey is scheduled
    let store = ScheduledSurveyStore(baseDirectory: tmp)
    let scheduled1 = await store.getAllPendingSurveys(for: "test-user")
    #expect(scheduled1.count == 1)
    
    // Immediately end session and start new one BEFORE trigger time passes
    // This prevents the survey from showing in the first session
    await recorder.endSession()
    
    // Manually advance the trigger time by updating the stored survey to be in the past
    // This simulates waiting for the trigger time to pass while app was closed
    let triggered1 = scheduled1[0]
    let pastTriggerSurvey = ScheduledSurveyStore.ScheduledSurvey(
        id: triggered1.id,
        userId: triggered1.userId,
        sessionId: triggered1.sessionId,
        scheduledAt: Date().addingTimeInterval(-10),
        triggerAt: Date().addingTimeInterval(-1) // Already triggered
    )
    // Manually update the store to have a triggered survey
    await store.removeScheduled(ruleId: triggered1.id, sessionId: triggered1.sessionId, userId: "test-user")
    await store.scheduleForLater(
        ruleId: pastTriggerSurvey.id,
        userId: pastTriggerSurvey.userId,
        sessionId: pastTriggerSurvey.sessionId,
        delaySeconds: -1 // In the past
    )
    
    // Act - Start new session
    let session2 = await recorder.startSession(userID: "test-user")
    #expect(session2.id != session1.id)
    
    // Verify trigger time has passed (survey is now "triggered")
    let triggered = await store.getAllTriggeredSurveys(for: "test-user")
    #expect(triggered.count == 1)
    
    // Create new view model - should restore and show the triggered survey
    let model2 = SurveyTriggerViewModel(
        config: config,
        recorder: recorder,
        debugConfig: .production
    )
    
    // Wait for restoration to run (triggered by sessionPublisher)
    try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
    
    // Assert - Survey should be presented
    #expect(model2.isPresented == true)
    #expect(model2.activeRule?.ruleId == "test-survey")
}

@MainActor
@Test("Anonymous user surveys persist across sessions")
func anonymousCrossSessionRestoration() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    let config = SurveyConfig(surveys: [
        SurveyRule(
            ruleId: "anon-survey",
            title: "Survey",
            message: "Message",
            response: .options(["A"]),
            trigger: .event(EventTrigger(name: "test_event", scheduleAfterSeconds: -5))
        )
    ])
    
    let store = ScheduledSurveyStore(baseDirectory: tmp)
    
    // Schedule for anonymous user
    await store.scheduleForLater(
        ruleId: "anon-survey",
        userId: nil,
        sessionId: "old-session",
        delaySeconds: -10 // Already triggered
    )
    
    // Act - Start new session (still anonymous)
    await recorder.startSession(userID: nil)
    
    // Assert - Should find the triggered survey
    let triggered = await store.getAllTriggeredSurveys(for: nil)
    #expect(triggered.count == 1)
    
    let hasSurveys = await recorder.hasScheduledSurveys(for: nil)
    #expect(hasSurveys == true)
}

